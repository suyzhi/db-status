import AppKit
import Charts
import Combine
import SwiftUI

@MainActor
final class WeeklySummaryViewModel: ObservableObject {
    @Published private(set) var current: WeeklySummary
    @Published private(set) var archived: [WeeklySummary] = []
    @Published private(set) var mode: ExposureMode
    @Published private(set) var annotations: [ExposureAnnotation] = []

    private let store: WeeklySummaryStore
    private let preferences: AppPreferences
    private let profiles: ProfileRepository

    init(
        store: WeeklySummaryStore = .shared,
        preferences: AppPreferences = .shared,
        profiles: ProfileRepository
    ) {
        self.store = store
        self.preferences = preferences
        self.profiles = profiles
        current = store.currentWeek()
        mode = preferences.exposureMode
        reload()
    }

    func reload() {
        store.archiveCompletedWeeks()
        current = store.currentWeek()
        archived = store.archivedWeeks.reversed()
        mode = preferences.exposureMode
        annotations = LocalDataStore.shared.annotations
    }

    var chartWeeks: [WeeklySummary] {
        Array((archived.reversed() + [current]).suffix(26))
    }

    func annotations(in week: WeeklySummary) -> [ExposureAnnotation] {
        let end = week.weekStart.addingTimeInterval(7 * 24 * 60 * 60)
        return annotations.filter { $0.date >= week.weekStart && $0.date < end }
    }

    func deviceName(_ uid: String) -> String {
        profiles.profile(for: uid)?.name ?? uid
    }
}

@MainActor
final class WeeklySummaryWindowController: NSWindowController {
    private let viewModel: WeeklySummaryViewModel

    init(profiles: ProfileRepository) {
        viewModel = WeeklySummaryViewModel(profiles: profiles)
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: WeeklySummaryView(viewModel: viewModel)
        ))
        window.title = "每周小结"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 580, height: 680))
        window.contentMinSize = NSSize(width: 520, height: 480)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        viewModel.reload()
        super.showWindow(sender)
        OverlayScrollers.apply(to: window)
    }
}

struct WeeklySummaryView: View {
    @ObservedObject var viewModel: WeeklySummaryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每周小结").font(.title2.bold())
                    Text("\(viewModel.mode.displayName)：\(Int(viewModel.mode.baselineDBA)) dBA × 40 小时 = 100%。每周汇总永久保留，分钟明细保留 8 周。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                trendChart
                WeekCard(week: viewModel.current, inProgress: true, viewModel: viewModel)
                ForEach(viewModel.archived) { week in
                    WeekCard(week: week, inProgress: false, viewModel: viewModel)
                }
                if viewModel.archived.isEmpty {
                    Text("第一周结束后，这里会出现历史小结。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trendChart: some View {
        let weeks = viewModel.chartWeeks
        let peak = weeks.map { $0.dosePercent(mode: viewModel.mode) }.max() ?? 0
        return Chart {
            ForEach(weeks) { week in
                BarMark(
                    x: .value("周", week.weekStart, unit: .weekOfYear),
                    y: .value("暴露 %", week.dosePercent(mode: viewModel.mode))
                )
                .foregroundStyle(week.id == viewModel.current.id ? Color.accentColor.opacity(0.5) : Color.accentColor)
            }
            if peak >= 50 {
                RuleMark(y: .value("上限", 100))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYAxisLabel("每周暴露 %")
        // Charts 按环境日历分周；不指定会按周日开始，与汇总的周一起始错开。
        .environment(\.calendar, WeeklySummaryBuilder.calendar)
        .frame(height: 150)
    }
}

private struct WeekCard: View {
    let week: WeeklySummary
    let inProgress: Bool
    @ObservedObject var viewModel: WeeklySummaryViewModel

    private static let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(dateRange).font(.headline)
                    if inProgress {
                        Text("进行中").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", week.dosePercent(mode: viewModel.mode)))
                        .font(.title3.bold())
                        .monospacedDigit()
                        .foregroundStyle(doseColor)
                }
                if week.listeningSeconds <= 0 {
                    Text("这一周没有可信的声暴露记录").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(overview).font(.callout).monospacedDigit()
                    if let loudest = week.loudestDay {
                        Text(String(
                            format: "最响的一天：%@（平均 %.1f dBA，%@）",
                            Self.weekdays[loudest.index],
                            loudest.levelDBA ?? 0,
                            Self.hoursText(loudest.seconds)
                        ))
                        .font(.callout)
                        .monospacedDigit()
                    }
                    if !appLine.isEmpty {
                        Text("来源：\(appLine)").font(.callout)
                    }
                    if significantDevices.count > 1 {
                        Text("设备：\(deviceLine)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(viewModel.annotations(in: week)) { annotation in
                    Text("◆ \(annotation.date.formatted(.dateTime.month().day())) \(annotation.title)：\(annotation.detail)")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let end = week.weekStart.addingTimeInterval(6 * 24 * 60 * 60)
        return "\(formatter.string(from: week.weekStart)) – \(formatter.string(from: end))"
    }

    private var overview: String {
        var parts = ["收听 \(Self.hoursText(week.listeningSeconds))"]
        if let level = week.equivalentLevelDBA {
            parts.append(String(format: "平均 %.1f dBA", level))
        }
        if let maxLAF = week.maxLAF {
            parts.append(String(format: "最响一刻 %.0f dBA", maxLAF))
        }
        return parts.joined(separator: " · ")
    }

    private var appLine: String {
        guard week.energy > 0 else { return "" }
        var items = week.appEnergy
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\(AppNames.displayName(for: $0.key)) \(Self.percent($0.value / week.energy))" }
        let unknown = week.unattributedEnergy / week.energy
        if unknown >= 0.01 {
            items.append("未识别 \(Self.percent(unknown))")
        }
        return items.joined(separator: " · ")
    }

    /// 占比不足 1% 的设备不列出。
    private var significantDevices: [(key: String, value: Double)] {
        guard week.energy > 0 else { return [] }
        return week.deviceEnergy
            .filter { $0.value / week.energy >= 0.01 }
            .sorted { $0.value > $1.value }
    }

    private var deviceLine: String {
        significantDevices
            .map { "\(viewModel.deviceName($0.key)) \(Self.percent($0.value / week.energy))" }
            .joined(separator: " · ")
    }

    private var doseColor: Color {
        let dose = week.dosePercent(mode: viewModel.mode)
        return dose >= 100 ? .red : dose >= 80 ? .orange : .primary
    }

    private static func hoursText(_ seconds: Double) -> String {
        seconds >= 3_600
            ? String(format: "%.1f 小时", seconds / 3_600)
            : String(format: "%.0f 分钟", seconds / 60)
    }

    private static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}
