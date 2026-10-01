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

第一版测量 `63 / 125 / 250 / 500 / 1000 / 2000 / 4000 / 8000 / 12000 Hz`。这组近似倍频程点能覆盖听力安全计算的重要频段，同时把完整测试控制在几十秒。点与点之间在 `log(frequency)` 空间插值，避免把低频的倍频关系和高频的线性 Hz 间隔错误地等同。**开放式大耳注意事项**：开放式设计会双向透声——环境噪声（风扇/空调/机箱嗡嗡）最容易混入 63/125/250 Hz 的低频测量，且这些低频点受单元频响跌落与探头位置影响最大；测量前应关闭噪声源，EM258 尽量贴近单元中心并保持稳定，必要时接受自动提高电平后的结果（提高上限 +9 dB，由 84 dBA 安全封顶约束）。

每个频点执行：

```text
静音测底噪 → 淡入 → 等待稳定 → 窄带测量 → 质量判断 → 淡出
```

目标频率能量不再从单个 1024-frame tap buffer 直接得出。正式测量会连续收集 PCM，切成 3 个各 1 秒的长窗口，每个窗口分别执行 Hann + Goertzel，再以三个窄带电平的标准差表示稳定度。这样 63 Hz 每个窗口包含约 63 个完整周期，125 Hz 包含约 125 个周期；实时 RMS/Peak UI 仍使用低延迟的 1024-frame buffer。输入峰值高于 `-3 dBFS` 时降低测试音并只重测当前点；SNR 低于 `12 dB` 时**把测试音直接提高到封顶电平并最多重测 2 次**（封顶 = 调用方按"当前音量"换算的 90 dBA 模型上限，数字电平再钳制在 -6 dBFS 且不低于初始电平；没有模型上限时退化为 初始+12 dB；削波保护仍会回退）；三个长窗口标准差高于 `0.5 dB` 时也只重测当前点，不清空已经通过的频点。8/12 kHz 高频点在封顶电平下仍不足 12 dB 时自动跳过（见上文开放大耳注意事项），主频段 63 Hz~4 kHz 仍是硬性要求。SNR 门槛从早期 15 dB 放宽到 12 dB：窄带正弦在 12 dB SNR 下的电平不确定度约 0.25 dB，配合 0.5 dB 稳定度门槛仍可接受，换来对环境的容忍度（无需风扇全关的"考古级"安静）。90 dBA 上限较早期 84 dBA 上调：校准音只在流程中出现、单点几秒、总计一两分钟，短时暴露安全；调高是为让开放式大耳的低频点与滚降高频点更容易达到信噪比门槛。**基准测试音从 -35 上调到 -25 dBFS**（默认 SNR 高 10 dB，动态提电平只在少数点才需要）。每个频点/音量点保存该点**实际播放的测试音电平 `signalRMSDBFS`**。

数据完整性三道闸门（2026-08-29 实测发现并修复）：

1. **频响归一化一致性审计**：每个有原始读数与信号电平的点，`relativeDB` 必须等于 `(本点原始dB − 参考原始dB) − (本点信号dB − 参考信号dB)`。不同频点可能因削波回退/提电平使用不同测试音——**裸麦克风电平不能直接互比**（"4 kHz 原始读数差 +1.81 dB 却存了 +5.81 dB"的正确解释：4 kHz 因削波用了比 1 kHz 低 4 dB 的测试音，归一化后 +5.81 dB 是对的；但此前数据未保存信号电平，无法当场验证——现已保存并加校验，不满足即判"数据不一致"）。
2. **音量曲线原始读数单调性**（测量时拦截 + 加载时校验）：系统音量升高，麦克风读数不应比上一档低 12 dB 以上；否则判定该点未真正以目标音量播放（外部改音量、输出路由切换、测试音未生效），拒绝保存并提示重测。此前 70% 点实测 `-31.12 dBFS` vs 50% `-10.41 dBFS` 的异常即属此类——当时该点测试音电平不同，relativeDB 仍呈单调，逃过了旧校验。
3. **EM258 个体校准**：`microphoneResponse` 默认 `em258NominalUncorrected`（标称频响、无个体修正、points 为空）——刻意设计：产品定位"趋势估算"，不做声级计；绝对 SPL 由耳机模型估算（±3~5 dB 量级）。绝对校准可用手机对标（向导第 6 步，约 ±2 dB）或 94 dB 声学校准器，见下文“绝对校准：手机对标”。

若安全控制或削波重测使某一点使用了更低的数字测试电平，保存相对结果前会先计算 `microphoneLevelDBFS - actualSignalRMSDBFS`。因此降低测试电平不会被误认为耳机响应变低，也不需要清空已经通过的点。

### 音量曲线：v1 只测 30/50/70%，v2 测 25%~100%

音量测试固定使用 1 kHz，记录各系统音量相对于 50% 的实测变化。v1（2026-08）只测 30%、50%、70%，50% 的绝对值仍要靠估算曲线换算到 100%（满音量才对应“最大输出 Vrms”），而估算曲线在 50% 处就差了 2.6 dB（见问题 11）。v2 测 25%、37.5%、50%、62.5%、75%、87.5%、100% 共 7 点（高音量点先用约 80 dB 的测试音），覆盖到 100% 后绝对值不再依赖估算曲线。测量范围内单调线性插值；25% 以下按模型曲线形状在边界连续对齐延伸。v1 档案仍可读取使用。

60% 独立验证误差不超过 `1 dB` 时通过，`1~2 dB` 时标记为可用但偏差较大，超过 `2 dB` 时禁止保存并只要求重测音量曲线。质量等级只综合最低 SNR、最大稳定度和这项相对验证误差，不代表绝对 SPL 精度。

绝对基准（数字 RMS 0 dBFS 的 1 kHz 信号在该音量下的声压）按优先级：

```text
1. 手机对标：fullScale(v) = measuredFullScaleAt50 + Δ(v) − Δ(50%)
2. v2 曲线：  fullScale(v) = sensitivity(→1 kHz) + 20·log10(maxVrms) + 3.01 + Δ(v) − Δ(100%)
3. v1 曲线：  fullScale(v) = headphoneModel(50%) + Δ(v) − Δ(50%)
estimatedSPL = fullScale(v) + calibratedAWeightedRMSDBFS
```

### FFT 如何应用耳机频响和 A weighting

运行时使用 4096 点 Hann 窗、50% overlap，并对左右声道分别做 Accelerate/vDSP FFT。每个频率 bin 的功率依次乘以：

```text
10^(headphoneResponseDB / 10)
×
10^(AWeightingDB / 10)
```

之后在功率域求和，再开平方得到 RMS。左右声道按能量平均（2026-10 起；普通音乐左右基本一致，取较响一侧会让偏声道内容虚高，且与标准 A 加权路径口径不一致）。FFT 归一化通过实际窗后时域能量和频域能量比完成，不使用硬编码 offset。零耳机频响曲线已用 100 Hz、1 kHz、4 kHz、10 kHz 正弦与原 `AWeightingMeter` 对照，误差门限为 `< 0.5 dB`。

原 \`AWeightingMeter\` 没有删除。配置缺失、版本不兼容、设备 UID 不匹配、频点缺失、数值非有限或 FFT 尚未产出结果时，整条链路回退到原来的 A-weighting、经验音量曲线和耳机绝对参数模型。

**校准到底有没有生效，可以直接看弹出面板**：蓝色「EM258 校准生效」表示频响与实测音量曲线都在用；橙色「模型估算 · 原因」表示已整条回退，并会写出退回原因。需要更细的内部状态时用 \`VM_DIAG=1\` 启动，每秒会把 \`freqApplied / volApplied / rmsA / 音量 / offset\` 追加到 \`/tmp/vm_diag.log\`。

> 历史问题（已修）：早期 \`setCalibrationProfile\` 在调用线程读取 \`sampleRate\`，而启动时它通常仍为 \`nil\`，队列块因此把 \`configureCoreAudioTap\` 刚建好的校准引擎清成 \`nil\`；又因为 \`requestedCalibrationID\` 已更新，后续同参数调用会提前返回、**永不重试**。结果是同一次启动里"校准是否生效"取决于两个子系统的启动先后——实测同一二进制连续启动 4 次出现 1 次失效，失效时显示值比生效时低 5 dB 以上（25%~31% 音量下音量曲线差约 4~5 dB，另有频响修正 1~4 dB）。现已改为在采集队列内现读采样率，采集未就绪时保留请求、交由 \`configureCoreAudioTap\` 建引擎。

### 权限和生命周期

`NSAudioCaptureUsageDescription` 继续对应日常 CoreAudio 系统音频 tap。`NSMicrophoneUsageDescription` 只对应 EM258 校准：第一次进入校准窗口才申请，关闭窗口、取消、保存、报错或退出 App 时立即停止麦克风和测试音。校准开始时会记录输入设备 UID、采样率、声道数、PCM 格式以及设备支持时的输入 gain；测试期间每 100 ms 复核，任一项变化都会停止测试并恢复系统音量。校准结束后日常使用不需要连接 EM258。

### 配置文件

校准配置保存在：

```text
~/Library/Application Support/VolumeMonitor/calibration-profiles.json
```

文件为带 schema/version 的可读 JSON，可保存多套“耳机档案 ID + 输出设备 UID”组合。损坏文件不会使 App 崩溃。更换输出设备不会套用旧校准。

在“设置与档案”中的“EM258 校准”区域点击“删除当前校准并恢复标准估算”，即可回到未校准模式；这个操作不删除耳机参数档案和声暴露历史。

### 监测数据文件

实时电平与声暴露数据和校准配置分开存放：

```text
~/Library/Application Support/VolumeMonitor/profiles-v2.json
~/Library/Application Support/VolumeMonitor/exposure-buckets-v2.ndjson
```

档案内容小、变更少，整体原子重写；分钟桶按行追加，每个分钟桶只在文件末尾增加一行，不再每次整体重写。同一分钟的重复记录在载入时按“能量与时长相加、峰值取大”合并，因此 App 中途重启或某次写入被打断都不会丢数据；裁剪 8 周以前的数据时会整体压缩重写一次。

首次以新版启动时会自动读取旧文件并把其中内容写成上述 v2 文件：

```text
~/Library/Application Support/VolumeMonitor/monitoring-data-v1.json
```

v1 原文件不会被修改或删除，可直接回退到旧版本；迁移完成后新版只读写 v2 文件。

### 绝对校准：手机对标（已实现，2026-10）

`absoluteCalibrationMode.acousticReference` 已启用。校准向导第 6 步“手机对标”：耳机与 EM258 仍插在转接头上（保持输入链路不变），EM258 贴在 iPhone 底部麦克风旁，内置扬声器播放约 20 秒粉红噪声，软件测 EM258 的 A 计权 dBFS，用户输入手机（NIOSH SLM，A 计权）读数，得到 `EM258 dBFS → dB SPL` 换算常数，再乘到第 4 步 50% 音量的耳道口实测电平上，得到“50% 音量下数字 RMS 0 dBFS 的 1 kHz 信号在耳道口的声压”。运行时以此为绝对锚点，替代“灵敏度 × 最大输出 Vrms”。

手机参考精度约 ±2 dB。若有 94 dB 声校准器，可用同一数据结构（参考读数 + 同时刻 EM258 电平）替换手机读数。

## 问题 11：绝对值链路的系统误差（2026-10）

现象：用户反映显示 80 dBA 时已经很响，怀疑软件偏低；同时档案里有一个用手机 + EM258 + dBMeter 测出的 +10 dB 手动偏移。

逐项实测（`vmcal` 一次性测量工具，EM258 置于耳道口）得到的结论：

1. **CoreAudio 报告的音量 dB 不可信。** 内置耳机孔 `kAudioDevicePropertyVolumeScalarToDecibels` 声称 0~100% 线性对应 −63.5~0 dB，但实测 25%→100% 只有 32 dB（50% 实际 −18.8 dB，声称 −31.8 dB）。不能用它替代实测曲线。
2. **旧默认曲线 `−65·(1−v)^1.6` 太陡**：50% 处猜 −21.4 dB，实际 −18.8 dB；31% 处差 7.7 dB。现默认曲线按实测拟合为 `−42.5·(1−v)^1.14`（25%~87.5% 误差 ±1.4 dB）。
3. **满幅正弦约定少算 3 dB。** 最大输出 Vrms 按满幅正弦标称（数字 RMS −3.01 dBFS），旧模型把数字 RMS 0 dBFS 对应到标称电压。
4. **校准回退时整条链退回估算曲线**，在 31% 音量下偏低约 10 dB——这正是当时用手机看到的“差 10 dB”。
5. **手机 + EM258 + dBMeter 不是有效基准**：dBMeter 的刻度是按手机自带麦克风标定的。

修正：
- 音量曲线测 25%~100% 共 7 点（v2 校准），绝对值换算不再依赖估算曲线；
- 补上 3.01 dB；灵敏度可填测量频率（如 500 Hz），有频响校准时换算到 1 kHz；
- FFT 频响引擎没跑起来时，保留实测音量曲线，频响按粉红频谱的 A 加权差值做保守补偿（只往高估）；
- 手机对标得到的绝对值与“规格 × 实测曲线”推算值相差 0.3 dB，说明规格链路本身可信；
- 清零 +10/+4 dB 手动偏移，历史数据不改，用数据标记（`annotations-v1.json`）注明口径变化。

修正后，本机（DT 1990 Pro MK II + MacBook Air 耳机孔，31% 音量）比旧版“+10 dB 偏移 + 校准生效”约低 4.5 dB，比“无偏移”约高 5.5 dB。

## 声暴露积分（2026-10 重写）

旧实现每 0.1 秒用“显示用的平滑值”（快升慢降、按回调次数平滑）算能量，动态大的音乐会偏高，主线程定时器被 App Nap 推迟超过 2 秒时还会丢数据。

现在：
- 音频线程对每个块的 A 加权均方按真实时长积分（只计有声块，−80 dBFS 以下不计时长），主线程每次刷新取走并清零（`LoudnessIntegrator`，实时线程只 try-lock，不阻塞）；
- 声暴露时长来自音频帧数，不再依赖墙钟；
- 显示改为 IEC 61672 Fast（125 ms）时间计权；分钟桶的 `peakDBA` 现为 LAFmax；
- 两条测量路径都按左右声道能量平均；
- 纯静音块跳过滤波与 FFT；弹窗关闭时界面 1 Hz 刷新（打开时 10 Hz）。

## 按 App 统计、每周小结、档案导入导出

- **按 App**：每个正在出声的进程一个轻量 process tap（同一个聚合设备），只算未加权能量比例；总量仍以全局 tap 为准再按比例分摊，写入分钟桶的 `appEnergy`。Chrome/Edge/Electron 的 `*.helper*` 归并到主 App，WebKit 网页内容进程归为“Safari / 网页内容”，无法区分具体网站。
- **每周小结**：设置或弹窗“更多 → 每周小结…”。已结束的周写入 `weekly-summaries-v1.json` 永久保留；明细已被裁剪的周不会被残缺数据覆盖。周一为一周开始。
- **导入导出**：设置里“导出档案… / 导入档案…”，包含全部设备档案与 EM258 校准；导入时若设备 UID 不同，可选择绑定到当前输出设备（校准一并改绑）。
