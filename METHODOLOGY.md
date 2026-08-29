# 动态音量监测开发方法论

本文记录本项目从“静态音量估算”改造成“实时系统音频电平 + 耳机参数换算”的过程中遇到的问题、根因和解决方法。目标不是只修某一个 bug，而是形成一套以后排查 macOS 音频采集、权限、签名和 UI 状态问题时可复用的方法。

## 目标边界

- 正常监测只读取当前系统正在播放的音频；麦克风仅在用户主动打开 EM258 校准窗口时按需使用。
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
rg -n "osascript|AppleScript|ScreenCaptureKit|SCStream|CGRequest|NSScreenCapture" Sources
```

搜索结果应为空，说明旧权限触发路径已经清掉。`AVAudioEngine` 现在会出现在独立的 EM258 校准模块中，这是预期行为；日常监测链路仍不打开麦克风。

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

## 问题 10：macOS 26 菜单栏图标不显示（Tahoe 宿主按 bundle id 卡死）

症状：App 正常运行、弹窗正常，但菜单栏里完全没有图标（看不到 🎧，也看不到数字）。

排查结论（2026-08-29 实测）：

- macOS 26 Tahoe 起，第三方 `NSStatusItem` 由 ControlCenter 的 StatusKit 架构统一托管，并
  **按 bundle id 记忆每个 App 的菜单栏状态**（System Settings → 菜单栏 → 每 App 开关，
  以及 App 自身 defaults 里的 `NSStatusItem Preferred Position Item-0`）。
- 某些历史状态（26.x 迁移、反复强杀等）会让某个 bundle id 卡在“屏外 22pt”的坏状态：
  item 窗口永远保持 `(0,0,16,0)`/`(x, 2014, 16..31, 22)`（正常应为 30/33pt 高），
  宿主侧不产生任何窗口，任何 App 内修复都无效。
- 判定方法：`button.window?.frame.height` 长期 < 25；或在菜单栏窗口列表里找不到
  该 bundle id 对应的宿主窗口。
- 已验证 **无效** 的修复：改图标/字体/tint、换 Info.plist 各键、删除 defaults 里的
  `NSStatusItem Preferred Position Item-0`、App 内销毁重建 statusItem ×4、
  系统设置里切换“菜单栏 → VolumeMonitor”开关、清 cfprefsd、`killall ControlCenter`、
  给 defaults 写回位置键。**唯一有效的是换一个新的 CFBundleIdentifier**（同二进制
  同 plist 仅改 id，图标立即上栏；社区 Stats 团队 issue #3120 也确认“按 bundle id
  卡死，换 id 即好”）。
- 第二个坑：宿主即使放了槽位，内容是按**创建时的快照**渲染的。旧代码
  “先设 attributedTitle 🎧 再立刻 `title = ""`”会让创建时内容为空，
  上栏后是空白槽位、后续改 title 也不更新。创建时就必须给非空内容
  （现在直接设置 `attributedTitle = "🎧 --"`，不再先设后清）。
- 本项目的处理：`CFBundleIdentifier` 由 `com.volumemonitor.app` 改为
  `com.volumemonitor.app2`（用户偏好已迁移；新 id 首次运行会重新弹出系统音频/麦克风
  授权，属一次性成本）。App 侧新增菜单栏宿主健康检查（2 秒后窗口高度 < 25 判定为
  未上栏），弹窗会提示去“系统设置 → 菜单栏”允许本应用，避免再次静默失败。

## 推荐排查流程

以后遇到 macOS 音频采集或权限异常，按这个顺序查：

1. 查代码路径，确认没有旧权限触发源。

```bash
rg -n "osascript|AppleScript|ScreenCaptureKit|SCStream|CGRequest|NSScreenCapture" Sources
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

## EM258 相对声学校准

### 校准能力的物理边界

EM258 的标称灵敏度（例如 `-32 dBV/Pa`）不能和 Mac 麦克风输入的 `dBFS` 直接相加后当作绝对 SPL。TRRS 转接链路、模拟前置放大器、输入增益、ADC 满刻度和设备自动增益都没有经过标定，同一个真实声压在不同输入链路上可能得到不同的 dBFS。

因此当前实现明确分工：

- EM258 实测耳机不同频率的相对响应，以及系统音量变化造成的相对声压变化。
- 耳机 `sensitivityDBV`、输出端 `maxOutputVRMS` 和既有输出模型继续提供绝对 SPL 基准。
- UI 始终显示“频响实测、音量曲线实测、绝对 SPL 参数估算”，不会把相对验证误差包装成绝对精度。

### 为什么以 1 kHz 归一化

一次扫频中的麦克风固定增益、前置增益和 ADC 比例对所有频点近似相同。把 1 kHz 的窄带测量设为 `0 dB`，其他频率只保存与它的差值，可以抵消这条未知的固定增益。1 kHz 同时位于常见耳机和麦克风工作带宽的中部，也适合作为音量曲线的固定测试频率。

### 为什么只测 9 个频率点

第一版测量 `63 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 12000 Hz`。这组近似倍频程点能覆盖听力安全计算的重要频段，同时把完整测试控制在几十秒。点与点之间在 `log(frequency)` 空间插值，避免把低频的倍频关系和高频的线性 Hz 间隔错误地等同。

每个频点执行：

```text
静音测底噪 → 淡入 → 等待稳定 → 窄带测量 → 质量判断 → 淡出
```

目标频率能量不再从单个 1024-frame tap buffer 直接得出。正式测量会连续收集 PCM，切成 3 个各 1 秒的长窗口，每个窗口分别执行 Hann + Goertzel，再以三个窄带电平的标准差表示稳定度。这样 63 Hz 每个窗口包含约 63 个完整周期，125 Hz 包含约 125 个周期；实时 RMS/Peak UI 仍使用低延迟的 1024-frame buffer。输入峰值高于 `-3 dBFS` 时降低测试音并只重测当前点；SNR 低于 `15 dB` 时**自动提高测试音电平（每次 +3 dB，最多 +9 dB，受 84 dBA 安全上限与削波保护约束）**并重测当前点；三个长窗口标准差高于 `0.5 dB` 时也只重测当前点，最多三次，不清空已经通过的频点。

若安全控制或削波重测使某一点使用了更低的数字测试电平，保存相对结果前会先计算 `microphoneLevelDBFS - actualSignalRMSDBFS`。因此降低测试电平不会被误认为耳机响应变低，也不需要清空已经通过的点。

### 为什么音量曲线只测 30%、50%、70%

音量测试固定使用 1 kHz 和相同数字 RMS，记录三个系统音量相对于 50% 的实测变化。三点足以替换原先完全经验化的音量曲线，同时不会让用户执行冗长测试。30% 到 70% 内单调线性插值；范围外不盲目延伸实测边缘斜率，而是恢复原耳机/输出模型的曲线形状，并在 30% 或 70% 实测边界进行连续对齐。

60% 独立验证误差不超过 `1 dB` 时通过，`1~2 dB` 时标记为可用但偏差较大，超过 `2 dB` 时禁止保存并只要求重测音量曲线。质量等级只综合最低 SNR、最大稳定度和这项相对验证误差，不代表绝对 SPL 精度。

绝对基准仍按下式计算：

```text
referenceFullScaleSPLAt50 = existingHeadphoneModel(volume: 50%)
fullScaleSPL(v) = referenceFullScaleSPLAt50 + measuredVolumeDelta(v)
estimatedSPL = fullScaleSPL(v) + calibratedAWeightedRMSDBFS
```

### FFT 如何应用耳机频响和 A weighting

运行时使用 4096 点 Hann 窗、50% overlap，并对左右声道分别做 Accelerate/vDSP FFT。每个频率 bin 的功率依次乘以：

```text
10^(headphoneResponseDB / 10)
×
10^(AWeightingDB / 10)
```

之后在功率域求和，再开平方得到 RMS。左右声道取较响一侧，避免一个耳朵较响时被立体声平均掩盖。FFT 归一化通过实际窗后时域能量和频域能量比完成，不使用硬编码 offset。零耳机频响曲线已用 100 Hz、1 kHz、4 kHz、10 kHz 正弦与原 `AWeightingMeter` 对照，误差门限为 `< 0.5 dB`。

原 `AWeightingMeter` 没有删除。配置缺失、版本不兼容、设备 UID 不匹配、频点缺失、数值非有限或 FFT 尚未产出结果时，整条链路回退到原来的 A-weighting、经验音量曲线和耳机绝对参数模型。

### 权限和生命周期

`NSAudioCaptureUsageDescription` 继续对应日常 CoreAudio 系统音频 tap。`NSMicrophoneUsageDescription` 只对应 EM258 校准：第一次进入校准窗口才申请，关闭窗口、取消、保存、报错或退出 App 时立即停止麦克风和测试音。校准开始时会记录输入设备 UID、采样率、声道数、PCM 格式以及设备支持时的输入 gain；测试期间每 100 ms 复核，任一项变化都会停止测试并恢复系统音量。校准结束后日常使用不需要连接 EM258。

### 配置文件

校准配置保存在：

```text
~/Library/Application Support/VolumeMonitor/calibration-profiles.json
```

文件为带 schema/version 的可读 JSON，可保存多套“耳机档案 ID + 输出设备 UID”组合。损坏文件不会使 App 崩溃。更换输出设备不会套用旧校准。

在“设置与档案”中的“EM258 相对校准”区域点击“删除当前校准并恢复标准估算”，即可回到未校准模式；这个操作不删除耳机参数档案和声暴露历史。

### 将来加入 94 dB 声学校准器

数据模型已预留 `absoluteCalibrationMode.acousticReference`，但当前版本拒绝保存该模式，避免伪造绝对精度。将来需要新增一个独立的 94 dB 参考步骤：固定输入设备、输入增益和完整转接链路，测得 `94 dB SPL → microphone dBFS` 的绝对 offset，并把参考设备、日期和输入链路写入配置。随后才能让运行时用声学参考替换耳机参数绝对基准；频响、音量曲线和 FFT 管线本身无需重写。
