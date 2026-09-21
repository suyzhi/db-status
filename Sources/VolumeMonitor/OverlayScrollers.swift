import AppKit

/// 系统「始终显示滚动条」设置下，NSScrollView 会用占宽的旧式滚动条，
/// 既不好看也会挤掉右侧内容。这里统一改成悬浮、自动隐藏、无背景的样式。
@MainActor
enum OverlayScrollers {
    static func apply(to window: NSWindow?) {
        guard let root = window?.contentView else { return }
        apply(to: root)
    }

    static func apply(to view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
        }
        for subview in view.subviews {
            apply(to: subview)
        }
    }
}
