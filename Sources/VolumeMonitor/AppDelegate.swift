import AppKit
import Foundation

// MARK: - App Delegate
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private var timer: Timer?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        
        popoverVC = PopoverViewController()
        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
        
        // Refresh on a timer
        refreshData()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshData()
            }
        }
    }
    
    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshData()
            guard let button = statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    @objc func refreshData() {
        popoverVC.refreshVolume()
    }
    
    private func installStatusItem() {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = createStatusBarIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func createStatusBarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        
        // Draw dB text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let text = "dB"
        text.draw(at: NSPoint(x: 2, y: 1), withAttributes: attributes)
        
        // Small green dot
        let dotRect = NSRect(x: 17, y: 4, width: 4, height: 4)
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
