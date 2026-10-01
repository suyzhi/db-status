import SwiftUI

/// 40~100 dBA 的分区电平条，标记随声级平滑移动。
struct LevelMeter: View {
    let level: Double?

    private static let range = LevelZone.meterRange

    private static func fraction(_ value: Double) -> Double {
        (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
            / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let caution = Self.fraction(LevelZone.cautionThreshold)
                let loud = Self.fraction(LevelZone.loudThreshold)
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                            .fill(Theme.safe.opacity(0.35))
                            .frame(width: width * caution - 2)
                        Rectangle()
                            .fill(Theme.caution.opacity(0.45))
                            .frame(width: width * (loud - caution) - 2)
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(Theme.loud.opacity(0.45))
                    }
                    .frame(height: 8)
                    if let level {
                        Capsule()
                            .fill(Color.primary)
                            .frame(width: 4, height: 16)
                            .offset(x: width * Self.fraction(level) - 2)
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: level)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Text("40")
                    Text("80").offset(x: width * Self.fraction(80) - 6)
                    Text("85").offset(x: width * Self.fraction(85) - 2)
                    Text("100").frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: 12)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.map { "当前 \(Int($0.rounded())) dBA，\(LevelZone(dBA: $0).label)" } ?? "当前无声级")
    }
}

/// 最近 30 秒的声级走势。按时间而不是样本数绘制，刷新频率变化不影响形状。
struct Sparkline: View {
    let samples: [LevelSample]
    var window: TimeInterval = 30
    var range: ClosedRange<Double> = 40...100

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: samples.isEmpty)) { context in
            Canvas { graphics, size in
                let now = context.date
                var path = Path()
                var started = false
                for sample in samples {
                    let age = now.timeIntervalSince(sample.date)
                    guard age <= window else { continue }
                    let x = size.width * (1 - age / window)
                    guard let level = sample.level else {
                        started = false
                        continue
                    }
                    let clamped = min(max(level, range.lowerBound), range.upperBound)
                    let y = size.height * (1 - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound))
                    if started {
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        path.move(to: CGPoint(x: x, y: y))
                        started = true
                    }
                }
                graphics.stroke(
                    path,
                    with: .color(Theme.accent),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

struct LevelSample: Equatable {
    let date: Date
    let level: Double?
}

/// 细进度条；出现时从 0 长到目标值。
struct ProgressTrack: View {
    let fraction: Double
    var height: CGFloat = 6
    var color: Color = Theme.accent
    @StateObject private var shown = ViewState(0.0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(height, proxy.size.width * min(max(shown.value, 0), 1)))
            }
        }
        .frame(height: height)
        .onReveal(
            reset: { withoutAnimation { shown.value = 0 } },
            reveal: { update(animated: !reduceMotion) }
        )
        .onChange(of: fraction) { update(animated: !reduceMotion) }
    }

    private func update(animated: Bool) {
        if animated {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown.value = fraction }
        } else {
            shown.value = fraction
        }
    }
}

/// 七天小柱图；出现时依次长高。
struct DailyBars: View {
    let days: [DailyExposureStat]
    var mode: ExposureMode
    var height: CGFloat = 34
    @StateObject private var grown = ViewState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let maxValue = max(days.map(\.energy).max() ?? 0, .leastNonzeroMagnitude)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                let isToday = index == days.count - 1
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isToday ? Theme.accent : Theme.accent.opacity(0.3))
                        .frame(height: max(3, (grown.value ? day.energy / maxValue : 0) * (height - 14)))
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.8).delay(Double(index) * 0.04),
                            value: grown.value
                        )
                    Text(Formatters.weekday(day.day))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Formatters.monthDay(day.day))：\(Formatters.hours(day.seconds))，暴露 \(Formatters.percent(day.dosePercent(mode: mode), digits: 2))")
            }
        }
        .frame(height: height, alignment: .bottom)
        .onReveal(
            reset: { withoutAnimation { grown.value = false } },
            reveal: {
                if reduceMotion {
                    withoutAnimation { grown.value = true }
                } else {
                    DispatchQueue.main.async { grown.value = true }
                }
            }
        )
    }
}

/// 最近 7 天的花瓣图：七片花瓣对应七天，长度为收听时长，今天颜色加深。
/// 出现时花瓣从中心依次绽开。
struct PetalChart: View {
    let days: [DailyExposureStat]
    var mode: ExposureMode
    @StateObject private var bloomed = ViewState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let labelRadius = min(size.width * 0.42, size.height / 2 - 18)
            let maxPetal = max(labelRadius - 44, 30)
            let innerRadius = 14.0
            let longest = max(days.map(\.seconds).max() ?? 0, 1)
            ZStack {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let isToday = index == days.count - 1
                    let angle = Angle.degrees(-90 + Double(index) * 360 / Double(max(days.count, 1)))
                    let length = max(10, day.seconds / longest * maxPetal)
                    let width = bloomed.value ? innerRadius + length : innerRadius
                    let stagger = Animation.spring(response: 0.6, dampingFraction: 0.72)
                        .delay(Double(index) * 0.07)
                    Capsule()
                        .fill(isToday ? Theme.petalToday : Theme.petal)
                        .frame(width: width, height: 20)
                        .offset(x: width / 2)
                        .rotationEffect(angle)
                        .position(center)
                        .animation(stagger, value: bloomed.value)
                    VStack(spacing: 1) {
                        Text("\(isToday ? "今天" : "周" + Formatters.weekday(day.day)) · \(Formatters.shortHours(day.seconds))")
                            .font(.system(size: 12, weight: isToday ? .bold : .semibold))
                        Text(Formatters.percent(day.dosePercent(mode: mode), digits: 2))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .position(
                        x: center.x + labelRadius * cos(angle.radians),
                        y: center.y + labelRadius * sin(angle.radians)
                    )
                    .opacity(bloomed.value ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.25 + Double(index) * 0.07), value: bloomed.value)
                }
                Circle()
                    .fill(Theme.petalToday)
                    .frame(width: 24, height: 24)
                    .scaleEffect(bloomed.value ? 1 : 0.4)
                    .position(center)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: bloomed.value)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(days.map {
            "\(Formatters.monthDay($0.day)) \(Formatters.hours($0.seconds))"
        }.joined(separator: "，"))
        .onReveal(
            reset: { withoutAnimation { bloomed.value = false } },
            reveal: {
                if reduceMotion {
                    withoutAnimation { bloomed.value = true }
                } else {
                    DispatchQueue.main.async { bloomed.value = true }
                }
            }
        )
    }
}
