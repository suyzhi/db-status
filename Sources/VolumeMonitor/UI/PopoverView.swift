import SwiftUI

/// 弹窗里各按钮触发的动作，由 AppDelegate 提供。
struct PopoverActions {
    var toggleMonitoring: () -> Void
    var retry: () -> Void
    var quickSetup: () -> Void
    var showWeekly: () -> Void
    var showCalibration: () -> Void
    var showSettings: () -> Void
    var showOverview: () -> Void
    var showDevices: () -> Void
    var quit: () -> Void
}

/// 菜单栏弹窗：只回答“现在多响”和“这周用了多少”。
struct PopoverView: View {
    @ObservedObject var model: LiveMonitorModel
    let actions: PopoverActions

    var body: some View {
        VStack(spacing: 10) {
            header
            levelCard
            doseCard
            toolbar
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 340)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones")
                .font(.system(size: 18, weight: .regular))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.deviceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(model.isActive ? Theme.safe : Color.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.isActive && model.level != nil)
                Text(model.stateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: model.stateText)
        }
    }

    // MARK: - 当前声级

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.displayLevel.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: 52, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.displayLevel == nil ? .tertiary : .primary)
                        .contentTransition(.numericText(value: model.displayLevel ?? 0))
                        .animation(.easeOut(duration: 0.15), value: model.displayLevel.map { Int($0.rounded()) })
                    Text("dBA")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let zone = model.zone {
                        Text(zone.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(zone.chipColor, in: Capsule())
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .animation(.easeInOut(duration: 0.3), value: zone)
                    }
                    Text(todayText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.zone)
            }
            Sparkline(samples: model.samples)
                .frame(height: 24)
            LevelMeter(level: model.level)
            if let notice = model.notice {
                noticeRow(notice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.caution)
                    .transition(.opacity)
            }
        }
        .card(padding: 12)
        .animation(.easeInOut(duration: 0.25), value: model.notice)
        .animation(.easeInOut(duration: 0.25), value: model.warning)
    }

    private var todayText: String {
        var text = "今天 \(Formatters.hours(model.todaySeconds))"
        if let level = model.todayLevel { text += String(format: " · 平均 %.1f", level) }
        return text
    }

    private func noticeRow(_ notice: LiveMonitorModel.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action = notice.action {
                Button(actionTitle(action)) { perform(action) }
                    .controlSize(.small)
            }
        }
    }

    private func actionTitle(_ action: LiveMonitorModel.NoticeAction) -> String {
        switch action {
        case .quickSetup: "快速设置…"
        case .retry: "重试"
        case .resume: "继续监测"
        }
    }

    private func perform(_ action: LiveMonitorModel.NoticeAction) {
        switch action {
        case .quickSetup: actions.quickSetup()
        case .retry: actions.retry()
        case .resume: actions.toggleMonitoring()
        }
    }

    // MARK: - 声暴露

    private var doseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("过去 7 天")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(Formatters.percent(model.doseFraction * 100))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: model.doseFraction))
                    .animation(.snappy, value: Int(model.doseFraction * 1_000))
            }
            ProgressTrack(fraction: model.doseFraction, color: doseColor)
            if !model.days.isEmpty {
                DailyBars(days: model.days, mode: model.mode)
                    .padding(.top, 2)
            }
            Text("\(model.mode.displayName)：\(Int(model.mode.baselineDBA)) dBA × 40 小时 = 100% · \(model.doseStatus)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }

    private var doseColor: Color {
        model.doseFraction >= 1 ? Theme.loud : model.doseFraction >= 0.8 ? Theme.caution : Theme.accent
    }

    // MARK: - 底部工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            IconButton(
                systemName: model.monitoringEnabled ? "pause.fill" : "play.fill",
                label: model.monitoringEnabled ? "暂停监测" : "继续监测",
                action: actions.toggleMonitoring
            )
            IconButton(systemName: "chart.bar.fill", label: "每周小结", action: actions.showWeekly)
            IconButton(systemName: "waveform.path.ecg", label: "校准", action: actions.showCalibration)
            IconButton(systemName: "gearshape", label: "设置", action: actions.showSettings)
            Spacer()
            Menu {
                Button("打开主窗口", action: actions.showOverview)
                Button("设备与校准", action: actions.showDevices)
                Divider()
                Button("退出音量监测", action: actions.quit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 44, height: 32)
                    .background(Theme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多")
            .accessibilityLabel("更多")
        }
    }
}

/// 带悬停高亮的图标按钮。
struct IconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @StateObject private var hovering = ViewState(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 32)
                .background(
                    Theme.track.opacity(hovering.value ? 1 : 0.7),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .scaleEffect(hovering.value ? 1.04 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering.value)
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
