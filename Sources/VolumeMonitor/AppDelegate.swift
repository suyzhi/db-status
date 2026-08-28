import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!
    private var settingsWindowController: SettingsWindowController?
    private var calibrationWindowController: CalibrationWizardWindowController?
    private var timer: Timer?
    private var lastStatusBarText = ""
    private var lastStatusBarColorKey = ""

    private let audioMonitor = SystemAudioLevelMonitor()
    private let outputMonitor = OutputDeviceMonitor()
    private let preferences = AppPreferences.shared
    private lazy var profileRepository = ProfileRepository()
    private lazy var exposureService = ExposureService()
    private lazy var calibrationStore = CalibrationStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        outputMonitor.start()

        popoverVC = PopoverViewController(
            audioMonitor: audioMonitor,
            outputMonitor: outputMonitor,
            profiles: profileRepository,
            exposure: exposureService,
            preferences: preferences,
            calibrationStore: calibrationStore
        )
        popoverVC.onShowSettings = { [weak self] in self?.showSettings() }
        popoverVC.onShowCalibration = { [weak self] in self?.showCalibration() }
        popoverVC.onQuit = { NSApplication.shared.terminate(nil) }
        popoverVC.onMonitoringChanged = { [weak self] enabled in
            self?.setMonitoringEnabled(enabled, forceRestart: enabled)
        }

        popover = NSPopover()
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true

        if preferences.monitoringEnabled { audioMonitor.start() }
        refreshData()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshData() }
        }
        timer?.tolerance = 0.025

        // A menu-bar-only app otherwise looks as if nothing happened when opened
        // from Finder. Present the popover once the status item has joined the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showPopover()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        exposureService.flush()
        outputMonitor.stop()
        audioMonitor.stop()
        calibrationWindowController?.stopCalibration()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPopover()
        return true
    }

    private func showPopover() {
        refreshData()
        guard let button = statusItem.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func setMonitoringEnabled(_ enabled: Bool, forceRestart: Bool = false) {
        preferences.monitoringEnabled = enabled
        if enabled {
            exposureService.requestNotificationAuthorization()
            if forceRestart { audioMonitor.stop() }
            audioMonitor.start()
        } else {
            audioMonitor.stop()
        }
        refreshData()
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                outputMonitor: outputMonitor,
                profiles: profileRepository,
                preferences: preferences,
                calibrationStore: calibrationStore,
                onMonitoringChanged: { [weak self] enabled in
                    self?.setMonitoringEnabled(enabled)
                }
            )
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showCalibration() {
        if calibrationWindowController == nil {
            calibrationWindowController = CalibrationWizardWindowController(
                outputMonitor: outputMonitor,
                profiles: profileRepository,
                calibrationStore: calibrationStore,
                onSaved: { [weak self] in self?.refreshData() }
            )
        }
        calibrationWindowController?.showWindow(nil)
        calibrationWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func refreshData() {
        popoverVC.refresh()
        updateStatusBarIcon()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 48)
        guard let button = statusItem.button else { return }
        button.image = createStatusBarIcon(text: "--", color: .systemGray)
        button.action = #selector(togglePopover)
        button.target = self
        button.toolTip = "听力暴露监测"
    }

    private func updateStatusBarIcon() {
        let text = popoverVC.statusBarLevelText
        let color = popoverVC.statusBarLevelColor
        let colorKey = statusBarColorKey(color)
        guard text != lastStatusBarText || colorKey != lastStatusBarColorKey else { return }
        lastStatusBarText = text
        lastStatusBarColorKey = colorKey
        statusItem.button?.image = createStatusBarIcon(text: text, color: color)
        switch preferences.statusBarDisplayMode {
        case .estimatedDBA:
            statusItem.button?.toolTip = text == "--" ? "当前无可信 dBA 估算" : "实时估算 ≈\(text) dBA"
        case .sevenDayDose:
            statusItem.button?.toolTip = "过去 7 天估算声暴露 \(text)"
        case .rmsDBFS:
            statusItem.button?.toolTip = text == "--" ? "当前无音频" : "RMS(A) \(text) dBFS"
        }
    }

    private func createStatusBarIcon(text: String, color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 44, height: 18))
        image.lockFocus()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: max(1, 35 - textSize.width), y: 0), withAttributes: attributes)
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 38, y: 6, width: 5, height: 5)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func statusBarColorKey(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return String(
            format: "%.2f-%.2f-%.2f-%.2f",
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        )
    }
}
