# 动态音量监测开发方法论

本文记录本项目从“静态音量估算”改造成“实时系统音频电平 + 耳机参数换算”的过程中遇到的问题、根因和解决方法。目标不是只修某一个 bug，而是形成一套以后排查 macOS 音频采集、权限、签名和 UI 状态问题时可复用的方法。

## 目标边界

- 实时读取当前系统正在播放的音频电平，而不是读取麦克风。
- 保留耳机模型参数，用系统音量上限和实时 RMS 电平估算声压级。
- 授权一次后应用应稳定运行，不能反复弹权限请求。
- UI 要能区分“采集中”“无音频”“缺权限”“真实错误”，不能把正常状态误报成异常。

## 核心换算思路

原来的估算只使用系统音量百分比，所以音乐暂停、摘下耳机或播放内容变安静时，dB SPL 仍然显示固定高值。

现在使用两层模型：

1. 系统音量百分比换算成当前音量下的最大估算声压级。
2. 系统音频 tap 实时计算 RMS dBFS。
3. 最终估算：

```text
estimatedSPL = maxSPLAtSystemVolume + rmsDBFS
```

RMS 是负值，例如 `-20 dBFS` 表示当前内容比满刻度低 20 dB。这样播放内容变小、暂停或无音频时，声压级会随之变化，而不是一直固定。

## 问题 1：静态 dB 不随时间变化

现象：

- 系统音量固定时，界面上的 dB SPL 基本不动。
- 视频暂停后仍显示一个看起来很高的声压级。

根因：

- 只用了“系统音量百分比 → 固定 dB SPL”的静态映射。
- 没有采集系统实际播放音频的 RMS/Peak。

解决方法：

- 新增系统音频电平采集。
- 对音频 buffer 计算短窗口 RMS 和 Peak。
- RMS 上升响应快、下降响应稍慢，避免数字闪烁。
- 低于阈值或长时间没有 sample 时显示“无音频”，不展示误导性的固定高 dB。

验证方法：

- 播放视频或音乐，dB SPL 应随响度变化。
- 暂停播放后，应进入“无音频”状态。
- 调整系统音量后，声压级整体基线应同步升降。

## 问题 2：ScreenCaptureKit 权限体验不稳定

现象：

- 应用一直提示等待授权。
- 用户已经在系统设置里开关过权限，但应用仍然认为没有权限。
- TCC 日志里出现 ScreenCapture/AudioCapture 相关请求。

根因：

- 使用 ScreenCaptureKit 采集系统音频时，会进入 macOS 的屏幕/系统音频录制权限链路。
- 如果应用签名身份不稳定，macOS 会认为每次构建后的应用都是另一个主体。
- 旧实现还混入了 `osascript` 读取系统音量，额外触发自动化/辅助访问/音频等 TCC 判断，进一步放大权限混乱。

解决方法：

- 移除 ScreenCaptureKit 和 `osascript` 路径。
- 使用 CoreAudio process tap 读取系统输出音频。
- 系统音量改用 CoreAudio 默认输出设备音量属性读取。
- 默认排除当前 App 自己的音频，避免反馈。

验证方法：

```bash
rg -n "osascript|AppleScript|ScreenCaptureKit|SCStream|CGRequest|NSScreenCapture|Microphone|AVAudio" .
```

搜索结果应为空，说明旧权限触发路径已经清掉。

## 问题 3：授权一次后仍反复要权限

现象：

- 用户已经授权，但每次重新构建或运行后仍然弹权限。
- TCC 日志出现 code requirement 或 cdhash 不匹配。

根因：

- ad-hoc 签名或每次重新签名导致应用身份变化。
- macOS 隐私数据库不是只看 bundle id，也会看代码签名要求。
- 如果签名要求变了，用户之前给的授权不会稳定命中。

解决方法：

- 在 `run.sh` 中创建并复用本地固定代码签名证书。
- 将本地签名钥匙串加入用户 keychain search list，使 `codesign` 能稳定找到身份。
- 用固定证书签名 app bundle。
- 用构建产物 hash 判断是否真的需要复制二进制和重新签名，避免无意义改动。

关键验证：

```bash
./run.sh
./run.sh
```

第二次应出现：

```text
Signature unchanged
```

并且签名详情应包含：

```bash
codesign -d -vvv build/VolumeMonitor.app
codesign -d -r- build/VolumeMonitor.app
```

期望结果：

```text
Authority=VolumeMonitor Local Code Signing
designated => identifier "com.volumemonitor.app" and certificate leaf = H"..."
```

这说明权限主体是稳定的 bundle id + 固定证书，而不是每次变化的临时 cdhash。

## 问题 4：缺少系统音频采集用途说明

现象：

- 应用没有明显弹窗，但采集失败。
- TCC 日志明确提示：

```text
Refusing authorization request for service kTCCServiceAudioCapture ... without NSAudioCaptureUsageDescription key
```

根因：

- `Info.plist` 里缺少 `NSAudioCaptureUsageDescription`。
- macOS 会直接拒绝 AudioCapture 授权请求，而不是正常进入用户授权流程。

解决方法：

- 在 `Packaging/Info.plist` 中加入：

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>用于读取系统正在播放的音频电平，并按耳机参数估算实时声压；不会使用麦克风。</string>
```

验证方法：

```bash
plutil -p build/VolumeMonitor.app/Contents/Info.plist
```

确认打包后的 app 内也包含该 key。

## 问题 5：codesign 反复提示要使用钥匙串

现象：

- 运行构建脚本时，macOS 弹窗提示 `codesign` 想要使用 VolumeMonitor 的钥匙串。
- 用户会被要求输入钥匙串密码。

根因：

- 为了让 macOS 权限授权稳定，本项目使用固定的本地签名证书签名 app。
- 这个证书的私钥存放在项目内的专用钥匙串：

```text
build/codesign/VolumeMonitor.keychain-db
```

- `codesign` 每次需要重新签名时，都必须读取这个私钥。
- 如果钥匙串未解锁，或私钥访问控制没有明确允许 `/usr/bin/codesign`，macOS 就会弹窗确认。

钥匙串密码：

```text
volume-monitor
```

解决方法：

- 在 `run.sh` 中集中处理签名钥匙串准备工作：
  - 自动解锁本地签名钥匙串。
  - 延长钥匙串自动锁定时间。
  - 将钥匙串加入用户 keychain search list。
  - 使用 `security set-key-partition-list` 明确允许 `codesign` 使用私钥。
- 正常情况下，脚本会自动完成这些步骤，不需要用户反复输入密码。

关键脚本逻辑：

```bash
security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$SIGNING_PASSWORD" \
  "$SIGNING_KEYCHAIN"
```

验证方法：

```bash
./run.sh
./run.sh
```

如果第二次显示：

```text
Signature unchanged
```

说明没有重新签名，也不会触发私钥读取。

如果 macOS 仍然弹出一次钥匙串确认框：

- 输入密码 `volume-monitor`。
- 选择“始终允许”。

这通常是系统对私钥访问控制的最后一次确认。之后脚本会继续自动刷新访问权限。

注意：

- 这个钥匙串不是用户登录钥匙串。
- 这个密码不是系统登录密码。
- 这个提示不是系统音频采集权限，也不是麦克风权限。
- 它只和本地构建签名有关。

## 问题 6：授权后仍卡在“等待授权”

现象：

- 第一次启动采集时权限未生效，UI 显示等待授权。
- 用户授权后，再打开弹窗仍然不重试采集。

根因：

- 内部 `hasStarted` / `shouldRun` 状态在启动失败后仍保持 true。
- 后续打开弹窗时逻辑以为采集已经启动，不会再次调用 start。

解决方法：

- 启动失败时清理 CoreAudio tap 和 aggregate device。
- 保留 UI 状态为 `noPermission` / `noAudio` / `failed`。
- 同时把 `shouldRun` 恢复为 false，让下一次打开弹窗能真正重试。

验证方法：

- 未授权时打开弹窗，应显示“需要系统音频权限”。
- 授权后再次打开弹窗，应重新尝试采集，而不是继续卡住旧状态。

## 问题 7：摘下耳机或无播放时误报“采集异常”

现象：

- 耳机摘下、暂停播放或系统当前没有输出音频时，UI 显示“采集异常”。

根因：

- 状态分类过粗，把权限、无音频、设备暂不可用和真实错误混在一起。

解决方法：

- 明确区分：
  - `capturing`：正在采集。
  - `noAudio`：没有可用音频或电平过低。
  - `noPermission`：系统音频权限未授权。
  - `failed`：真实启动或设备错误。
- 暂停播放、摘下耳机、无输出时优先显示“无音频”，不吓用户。

验证方法：

- 播放视频时显示实时电平。
- 暂停视频后显示“无音频”。
- 未授权时显示“需要系统音频权限”。
- 只有 CoreAudio tap 创建/启动失败时才显示“采集异常”。

## 问题 8：动画不够流畅

现象：

- 电平条和数值变化有卡顿感。

根因：

- UI 刷新频率偏低。
- RMS/Peak 平滑策略不够自然。

解决方法：

- UI timer 从 30 fps 提升到 60 fps。
- RMS 使用 attack/release 平滑：
  - 上升快，能跟上鼓点和人声。
  - 下降慢，避免数字和电平条抖动。
- Peak 使用较快衰减，保留瞬态反馈。

验证方法：

- 播放有明显动态的视频或音乐。
- 电平条应连续变化，不应一跳一跳。
- 暂停后应平滑回落到“无音频”。

## 问题 9：UI 重叠

现象：

- 参考刻度、状态文字和主读数区域高度不足，出现挤压或重叠。

根因：

- 弹窗使用手写坐标，原始高度不足。
- 参考刻度区域和状态区域没有足够垂直空间。

解决方法：

- 增大 popover 高度。
- 把主显示区、状态区、耳机信息、参考刻度分层摆放。
- 声压参考改成紧凑横向刻度，保留 85 dB 风险标记。
- 长状态文案放到 detail label，避免挤占主标签。

验证方法：

- 打开菜单栏弹窗，检查所有文字、刻度、电平条不重叠。
- 低音量、高音量、危险等级、无音频、缺权限等状态都要完整显示。

## 推荐排查流程

以后遇到 macOS 音频采集或权限异常，按这个顺序查：

1. 查代码路径，确认没有旧权限触发源。

```bash
rg -n "osascript|AppleScript|ScreenCaptureKit|SCStream|CGRequest|Microphone|AVAudio" .
```

2. 查打包后的 plist，而不是只看源码 plist。

```bash
plutil -p build/VolumeMonitor.app/Contents/Info.plist
```

3. 查签名是否固定。

```bash
codesign -d -vvv build/VolumeMonitor.app
codesign -d -r- build/VolumeMonitor.app
```

4. 连续运行两次启动脚本。

```bash
./run.sh
./run.sh
```

第二次必须是 `Signature unchanged`。

5. 查是否还有旧进程。

```bash
pgrep -fl "osascript|VolumeMonitor"
```

6. 查 TCC 日志，找真实拒绝原因。

```bash
/usr/bin/log show --last 30s --predicate "process == 'tccd' AND eventMessage CONTAINS 'com.volumemonitor.app'" --style compact
```

重点关注：

- `without NSAudioCaptureUsageDescription key`
- code requirement / cdhash mismatch
- service 是 `AudioCapture`、`ScreenCapture`、`Microphone` 还是别的权限

7. 只在确认是旧坏记录时，才定向重置本 app 权限。

```bash
tccutil reset AudioCapture com.volumemonitor.app
tccutil reset ScreenCapture com.volumemonitor.app
tccutil reset Microphone com.volumemonitor.app
```

不要随手全局重置 TCC，也不要反复让用户开关权限。先看日志，再动权限。

## 最终原则

- macOS 权限问题不要靠猜，优先看 TCC 日志。
- 授权是否稳定，关键看代码签名要求，不只看 bundle id。
- 采集失败不等于权限失败，要把无音频、无权限、设备不可用、真实错误分开。
- 系统音量和系统音频电平是两件事：音量决定上限，RMS 决定实时动态。
- UI 不应该用高 dB 固定值吓用户；没有音频时就明确显示没有音频。
