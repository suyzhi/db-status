import AppKit
import Foundation

/// 菜单栏宿主状态（macOS 26 Tahoe 起由系统按 bundle id 管理；宿主拒绝时按钮窗口会保持
/// 22pt/零尺寸、且不产生任何带内容的图标）。App 侧只做探测与提示，无法直接修复。
@MainActor
enum MenuBarHostStatus {
    static var unhosted = false
}

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

        // 默认只在用户点击菜单栏图标时弹出，避免启动/自启时打扰。
        // （从 Finder 打开时也保持安静：状态栏图标本身即是反馈。）
        // VM_OPEN_POPOVER=1 供调试/验证用：启动即弹出。
        if ProcessInfo.processInfo.environment["VM_OPEN_POPOVER"] == "1" {
            presentPopoverWhenReady()
        }
        // VM_OPEN_SETTINGS=1 供调试/验证用：启动即打开设置窗口。
        if ProcessInfo.processInfo.environment["VM_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showSettings()
            }
        }
        // macOS 26+ 的宿主异常时，按钮窗口始终是 22pt 高（正常为 30/33pt）且无内容，
        // 说明系统侧没有把该 bundle id 的菜单栏项目放上栏。启动后探测一次，之后定时复检。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            Task { @MainActor [weak self] in self?.checkMenuBarHost() }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMenuBarHost() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        exposureService.flush()
        outputMonitor.stop()
        audioMonitor.stop()
        calibrationWindowController?.stopCalibration()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover(relativeTo: sender as? NSView)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showPopover()
        return true
    }

    private func showPopover(relativeTo anchorView: NSView? = nil) {
        refreshData()
        guard let button = anchorView ?? statusItem.button else { return }
        // 锚点按钮尚未真正挂载到菜单栏（window 为 nil）时，
        // NSPopover 会把弹窗回退到屏幕左下角。此时改为排队等待。
        guard button.window != nil else {
            presentPopoverWhenReady()
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// 等 status item 真正挂载到菜单栏后再弹出，避免锚点无效时
    /// NSPopover 回退到屏幕左下角。
    private func presentPopoverWhenReady() {
        var attempts = 0
        func tryPresent() {
            attempts += 1
            guard let button = statusItem.button,
                  let window = button.window,
                  window.screen != nil,
                  window.frame.width > 0,
                  window.frame.height > 0 else {
                if attempts < 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        tryPresent()
                    }
                }
                return
            }
            showPopover(relativeTo: button)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            tryPresent()
        }
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

    private func checkMenuBarHost() {
        guard let button = statusItem.button else { return }
        let height = button.window?.frame.height ?? 0
        MenuBarHostStatus.unhosted = height < 25
        diag("menu bar host check: height=\(height) unhosted=\(MenuBarHostStatus.unhosted)")
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else {
            // button 偶尔在 app 启动早期尚未就绪，稍后重试，
            // 避免菜单栏图标静默缺失。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.statusItem?.button == nil else { return }
                self.installStatusItem()
            }
            return
        }
        // 菜单栏标记:创建时必须立刻有非空内容——macOS 26 的菜单栏宿主按
        // “创建时的内容”截图渲染;若创建时为空(先设 🎧 再清空 title 之类),
        // 上栏后是空白槽位,后续改 title 也不会更新。
        button.image = nil
        button.imagePosition = .noImage
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.attributedTitle = NSAttributedString(
            string: "🎧 --",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor
            ]
        )
        button.contentTintColor = .labelColor
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.toolTip = "听力暴露监测"
        button.needsDisplay = true
        diag("install done: frame=\(String(describing: button.window?.frame)) mainScreen=\(String(describing: NSScreen.main?.frame))")
    }

    private func diag(_ message: String) {
        let line = "\(Date()) [VolumeMonitor] \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: "/tmp/vm_diag.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/vm_diag.log"))
        }
    }

    private func updateStatusBarIcon() {
        let text = popoverVC.statusBarLevelText
        let color = popoverVC.statusBarLevelColor
        let colorKey = statusBarColorKey(color)
        guard text != lastStatusBarText || colorKey != lastStatusBarColorKey else { return }
        lastStatusBarText = text
        lastStatusBarColorKey = colorKey
        statusItem.button?.title = text
        statusItem.button?.contentTintColor = color
        switch preferences.statusBarDisplayMode {
        case .estimatedDBA:
            statusItem.button?.toolTip = text == "--" ? "当前无可信 dBA 估算" : "实时估算 ≈\(text) dBA"
        case .sevenDayDose:
            statusItem.button?.toolTip = "过去 7 天估算声暴露 \(text)"
        case .rmsDBFS:
            statusItem.button?.toolTip = text == "--" ? "当前无音频" : "RMS(A) \(text) dBFS"
        }
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
