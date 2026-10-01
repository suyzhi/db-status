import Combine
import SwiftUI

@MainActor
final class OverviewModel: ObservableObject {
    @Published private(set) var week: WeeklySummary
    @Published private(set) var annotations: [ExposureAnnotation] = []

    init() {
        week = WeeklySummaryStore.shared.currentWeek()
    }

    func reload() {
        let newWeek = WeeklySummaryStore.shared.currentWeek()
        if newWeek != week { week = newWeek }
        let newAnnotations = Array(LocalDataStore.shared.annotations.suffix(3).reversed())
        if newAnnotations != annotations { annotations = newAnnotations }
    }

    /// 本周各 App 占比（从大到小，最多 4 个），以及未识别部分。
    var appShares: [(name: String, fraction: Double, unknown: Bool)] {
        guard week.energy > 0 else { return [] }
        var items = week.appEnergy
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { (name: AppNames.displayName(for: $0.key), fraction: $0.value / week.energy, unknown: false) }
        let unknown = week.unattributedEnergy / week.energy
        if unknown >= 0.01 { items.append((name: "未识别", fraction: unknown, unknown: true)) }
        return items
    }
}

struct OverviewPage: View {
    @ObservedObject var live: LiveMonitorModel
    @ObservedObject var overview: OverviewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "概览", subtitle: "\(live.mode.displayName) · \(Int(live.mode.baselineDBA)) dBA × 40 小时 = 100%")
                    .appearAnimation()
                HStack(alignment: .top, spacing: 14) {
                    nowCard.appearAnimation(delay: 0.03)
                    doseCard.appearAnimation(delay: 0.06)
                    todayCard.appearAnimation(delay: 0.09)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    petalCard.appearAnimation(delay: 0.12)
                    VStack(spacing: 14) {
                        sourcesCard
                        markersCard
                    }
                    .frame(width: 250)
                    .appearAnimation(delay: 0.15)
                }
            }
            .padding(24)
        }
    }

    private var nowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("现在").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(live.displayLevel.map { "\(Int($0.rounded()))" } ?? "--")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: live.displayLevel ?? 0))
                    .animation(.easeOut(duration: 0.15), value: live.displayLevel.map { Int($0.rounded()) })
                Text("dBA").foregroundStyle(.secondary)
                Spacer()
                if let zone = live.zone {
                    Text(zone.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(zone.chipColor, in: Capsule())
                        .animation(.easeInOut(duration: 0.3), value: zone)
                }
            }
            Text("\(live.deviceName) · \(live.stateText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .card()
    }

    private var doseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("过去 7 天暴露").font(.caption).foregroundStyle(.secondary)
            Text(Formatters.percent(live.doseFraction * 100))
                .font(.system(size: 34, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: live.doseFraction))
            ProgressTrack(fraction: live.doseFraction)
            Text(live.doseStatus).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今天").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", live.todaySeconds / 3_600))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: live.todaySeconds))
                Text("小时").foregroundStyle(.secondary)
            }
            Text(live.todayLevel.map { String(format: "平均 %.1f dBA", $0) } ?? "今天还没有收听记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var petalCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近 7 天").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let first = live.days.first, let last = live.days.last {
                    Text("\(Formatters.monthDay(first.day)) – \(Formatters.monthDay(last.day))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if live.days.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                PetalChart(days: live.days, mode: live.mode)
                    .frame(height: 320)
                Text("花瓣长度 = 当天收听时长，数字为当天暴露 %")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .card()
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本周来源").font(.system(size: 13, weight: .semibold))
            if overview.appShares.isEmpty {
                Text("本周还没有记录").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(overview.appShares.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).foregroundStyle(item.unknown ? .secondary : .primary)
                        Spacer()
                        Text(Formatters.percent(item.fraction * 100, digits: 0)).monospacedDigit()
                            .foregroundStyle(item.unknown ? .secondary : .primary)
                    }
                    .font(.caption)
                    ProgressTrack(
                        fraction: item.fraction,
                        height: 5,
                        color: item.unknown ? Color.secondary.opacity(0.5) : Theme.accent
                    )
                }
            }
        }
        .card()
    }

    private var markersCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据标记").font(.system(size: 13, weight: .semibold))
            if overview.annotations.isEmpty {
                Text("测量口径变化（校准、偏移）会记在这里").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(overview.annotations) { annotation in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Formatters.monthDay(annotation.date)) · \(annotation.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.marker)
                    Text(annotation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }
        }
        .card()
    }
}
