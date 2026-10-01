import AppKit
import Combine
import SwiftUI

/// 视图内部的动画状态。本机只有 Command Line Tools，没有 SwiftUI 宏插件，
/// `@State` 无法编译，用 `@StateObject` + 这个容器代替。
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// 全应用统一的颜色与声级分区。浅色/深色各一套，跟随系统外观。
enum Theme {
    static let safe = dynamic(light: 0x237055, dark: 0x4CC491)
    static let caution = dynamic(light: 0x8F5500, dark: 0xF2A33A)
    static let loud = dynamic(light: 0xB8322A, dark: 0xFF6A5C)
    static let accent = dynamic(light: 0x0062C4, dark: 0x4DA3FF)
    static let petal = dynamic(light: 0xE3A086, dark: 0x9C5A43)
    static let petalToday = dynamic(light: 0xC15F3C, dark: 0xE08A66)
    static let marker = dynamic(light: 0x6A3FB5, dark: 0xB79BFF)
    static let track = dynamic(light: 0xE9E9EE, dark: 0x3A3A40)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardStroke = dynamic(light: 0xE3E3E8, dark: 0x3A3A3F)

    /// 声级色块上的白字需要更深的底色（对比度 ≥ 4.5:1），深色模式也用同一组。
    static let safeChip = Color(hex: 0x237055)
    static let cautionChip = Color(hex: 0x8F5500)
    static let loudChip = Color(hex: 0xB8322A)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

/// 声级分区：≤80 安全、80~85 注意、>85 偏响（WHO 成人周参考 80 dBA；85 dBA 为职业噪声常用警戒线）。
enum LevelZone: Equatable {
    case safe, caution, loud

    static let meterRange: ClosedRange<Double> = 40...100
    static let cautionThreshold = 80.0
    static let loudThreshold = 85.0

    init(dBA: Double) {
        if dBA > Self.loudThreshold {
            self = .loud
        } else if dBA > Self.cautionThreshold {
            self = .caution
        } else {
            self = .safe
        }
    }

    var label: String {
        switch self {
        case .safe: "安全"
        case .caution: "注意"
        case .loud: "偏响"
        }
    }

    var color: Color {
        switch self {
        case .safe: Theme.safe
        case .caution: Theme.caution
        case .loud: Theme.loud
        }
    }

    var chipColor: Color {
        switch self {
        case .safe: Theme.safeChip
        case .caution: Theme.cautionChip
        case .loud: Theme.loudChip
        }
    }

    var nsColor: NSColor {
        switch self {
        case .safe: .systemGreen
        case .caution: .systemOrange
        case .loud: .systemRed
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 统一的卡片外观。
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// 出现时淡入上移；主窗口每次打开、每次切到本页都会重播。开启“减弱动态效果”时直接显示。
    func appearAnimation(delay: Double = 0) -> some View {
        modifier(AppearAnimation(delay: delay))
    }

    /// 入场动画的触发点：首次出现时，以及 revealToken 变化时（打开主窗口、切到本页）。
    /// token 为 −1 表示“即将展示”：先瞬间复位到动画起点，等窗口出现后再播放，避免和窗口弹出抢帧。
    func onReveal(reset: @escaping () -> Void, reveal: @escaping () -> Void) -> some View {
        modifier(RevealTrigger(reset: reset, reveal: reveal))
    }
}

private struct RevealTokenKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// 0：页面未显示；−1：即将显示，先复位；正数：播放入场动画。
    var revealToken: Int {
        get { self[RevealTokenKey.self] }
        set { self[RevealTokenKey.self] = newValue }
    }
}

/// 不带动画地改状态（用于把动画复位到起点）。
@MainActor
func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

private struct RevealTrigger: ViewModifier {
    let reset: () -> Void
    let reveal: () -> Void
    @Environment(\.revealToken) private var token

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard token != -1 else { return reset() }
                reveal()
            }
            .onChange(of: token) {
                if token == -1 {
                    reset()
                } else if token > 0 {
                    reset()
                    DispatchQueue.main.async { reveal() }
                }
            }
    }
}

private struct AppearAnimation: ViewModifier {
    let delay: Double
    @StateObject private var visible = ViewState(false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible.value || reduceMotion ? 1 : 0)
            .offset(y: visible.value || reduceMotion ? 0 : 8)
            .onReveal(
                reset: { withoutAnimation { visible.value = false } },
                reveal: {
                    guard !reduceMotion else { return }
                    withAnimation(.easeOut(duration: 0.3).delay(delay)) {
                        visible.value = true
                    }
                }
            )
    }
}

enum Formatters {
    static func hours(_ seconds: Double) -> String {
        seconds >= 3_600
            ? String(format: "%.1f 小时", seconds / 3_600)
            : String(format: "%.0f 分钟", seconds / 60)
    }

    static func shortHours(_ seconds: Double) -> String {
        String(format: "%.1f h", seconds / 3_600)
    }

    static func percent(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f%%", value)
    }

    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    static func weekday(_ date: Date) -> String {
        weekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
    }

    /// DateFormatter 只做格式化时线程安全；复用一个，避免每次渲染新建（新建很慢）。
    nonisolated(unsafe) private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func monthDay(_ date: Date) -> String {
        monthDayFormatter.string(from: date)
    }
}
