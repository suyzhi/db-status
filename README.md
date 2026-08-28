# VolumeMonitor

macOS 菜单栏听力暴露估算工具。它通过 CoreAudio process tap 读取系统正在播放的音频，计算 A 加权 RMS，再使用用户确认的设备档案估算 dBA 和过去 7 天的声暴露。

> 这是个人趋势估算工具，不是专业声级计、认证噪声剂量计或医疗设备。

## 为什么初次启动不显示 dBA

应用不会为未知设备套用默认耳机或扬声器模型。在“设置与档案”中为当前 CoreAudio 设备 UID 建立档案后，才会开始 dBA 估算：

- 有线耳机：输入 dB/V 或 dB/mW、阻抗、输出源最大 Vrms，可选填写音量衰减曲线和校准偏移。
- 蓝牙/DSP 耳机或扬声器：至少填写两个“系统音量%=dBA”声学校准点。
- 系统静音、读不到音量或档案不完整时，应用只显示 dBFS，不会沿用上一台设备的数值。

## 声暴露

默认使用 WHO 成人参考模式：`80 dBA × 40 小时/过去 7 天 = 100%`。设置中也可选择 `75 dBA × 40 小时`保守模式。数据按分钟聚合，仅保存在本机 `Application Support/VolumeMonitor` 中，保留 8 周。

## 构建和验证

```bash
swift build
swift test
swift run VolumeMonitor --self-test-logic
./run.sh
```

`--self-test-audio` 会在最多约 6 秒内检查 CoreAudio 采集；退出码 `4` 表示采集已启动，但当时没有可用播放音频。

测试套件使用 Swift Testing，并通过 SwiftPM 锁定依赖版本；只安装 Command Line Tools 也可以运行 `swift test`。

## EM258 相对校准

弹窗中的“校准…”会打开独立的五步向导，使用外接 EM258 实测耳机相对频响和系统音量曲线。没有 94 dB 声学校准器时，绝对 SPL 仍明确使用耳机灵敏度与输出模型估算。校准、降级和配置格式详见 [METHODOLOGY.md](METHODOLOGY.md)。
