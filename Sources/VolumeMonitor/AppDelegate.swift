import AppKit
import Foundation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private let audioMonitor = SystemAudioLevelMonitor()
    private var timer: Timer?
    private var lastStatusBarText = ""
    private var lastStatusBarColorKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()

        popoverVC = PopoverViewController(audioMonitor: audioMonitor)
        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        refreshData()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshData()
            }
        }
        timer?.tolerance = 0.004
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        audioMonitor.stop()
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if !audioMonitor.hasStarted { audioMonitor.start() }
            refreshData()
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func refreshData() {
        popoverVC.refreshVolume()
        updateStatusBarIcon()
    }

    private func installStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = createStatusBarIcon(text: "--", color: .systemGray)
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func updateStatusBarIcon() {
        let text = popoverVC.statusBarLevelText
        let color = popoverVC.statusBarLevelColor
        let colorKey = statusBarColorKey(color)

        guard text != lastStatusBarText || colorKey != lastStatusBarColorKey else { return }
        lastStatusBarText = text
        lastStatusBarColorKey = colorKey

        statusItem.length = 44
        statusItem.button?.image = createStatusBarIcon(text: text, color: color)
        statusItem.button?.toolTip = text == "--" ? "实时估算声压：无音频" : "实时估算声压：\(text) dBA"
    }

    private func createStatusBarIcon(text: String, color: NSColor) -> NSImage {
        let size = NSSize(width: 40, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let textX = max(1, 31 - textSize.width)
        text.draw(at: NSPoint(x: textX, y: 0), withAttributes: attributes)

        let dotRect = NSRect(x: 34, y: 6, width: 5, height: 5)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusBarColorKey(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return String(format: "%.2f-%.2f-%.2f-%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
}
