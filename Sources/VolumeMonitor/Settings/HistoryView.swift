import Charts
import SwiftUI

struct HistoryView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("过去 7 天趋势").font(.headline)
                Spacer()
                Button("关闭") { viewModel.showHistory = false }
                    .buttonStyle(.link)
            }
            if viewModel.historyPoints.isEmpty {
                Text("暂无可信的声暴露记录")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
                Spacer()
            } else {
                Chart {
                    ForEach(viewModel.historyPoints) { point in
                        LineMark(
                            x: .value("时间", point.minute),
                            y: .value("LAeq", point.equivalentLevelDBA)
                        )
                        .foregroundStyle(.blue)
                        PointMark(
                            x: .value("时间", point.minute),
                            y: .value("峰值", point.peakDBA)
                        )
                        .foregroundStyle(.orange.opacity(0.45))
                    }
                    ForEach(visibleAnnotations) { annotation in
                        RuleMark(x: .value("标记", annotation.date))
                            .foregroundStyle(.purple.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .frame(height: 200)

                ForEach(viewModel.annotations.suffix(3).reversed()) { annotation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("◆ \(annotation.date.formatted(date: .abbreviated, time: .shortened)) · \(annotation.title)")
                            .foregroundStyle(.purple)
                        Text(annotation.detail).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }

                ForEach(viewModel.deviceExposure.prefix(6)) { device in
                    HStack {
                        Text(device.deviceUID).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", device.dosePercent))
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
                HStack {
                    Spacer()
                    Button("导出 CSV…") { viewModel.exportCSV() }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 540, height: 520)
    }

    private var visibleAnnotations: [ExposureAnnotation] {
        guard let first = viewModel.historyPoints.first?.minute else { return [] }
        return viewModel.annotations.filter { $0.date >= first }
    }
}
