import AppKit
import Foundation
import SwiftUI

/// 菜单栏宿主状态（macOS 26 Tahoe 起由系统按 bundle id 管理；宿主拒绝时按钮窗口会保持
/// 22pt/零尺寸、且不产生任何带内容的图标）。App 侧只做探测与提示，无法直接修复。
@MainActor
enum MenuBarHostStatus {
    static var unhosted = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: MonitorController!
    private var mainWindowController: MainWindowController?
    private var calibrationWindowController: CalibrationWizardWindowController?
    private var archiveTimer: Timer?
    private var timer: Timer?
    private var lastStatusBarText = ""
    private var lastStatusBarColorKey = ""

    private let audioMonitor = SystemAudioLevelMonitor()
    private let appAttribution = AppAudioAttributionMonitor()
    private let outputMonitor = OutputDeviceMonitor()
    private let preferences = AppPreferences.shared
    private lazy var profileRepository = ProfileRepository()
    private lazy var exposureService = ExposureService()
    private lazy var calibrationStore = CalibrationStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 任何窗口（含 SwiftUI 的 sheet）成为 key window 时都统一滚动条样式。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        installStatusItem()
        outputMonitor.start()

        monitor = MonitorController(
            audioMonitor: audioMonitor,
            appAttribution: appAttribution,
            outputMonitor: outputMonitor,
            profiles: profileRepository,
            exposure: exposureService,
            preferences: preferences,
            calibrationStore: calibrationStore
        )
        let actions = PopoverActions(
            toggleMonitoring: { [weak self] in
                guard let self else { return }
                setMonitoringEnabled(!preferences.monitoringEnabled, forceRestart: !preferences.monitoringEnabled)
            },
            retry: { [weak self] in self?.setMonitoringEnabled(true, forceRestart: true) },
            quickSetup: { [weak self] in self?.showQuickSetup() },
            showWeekly: { [weak self] in self?.showMainWindow(.weekly) },
            showCalibration: { [weak self] in self?.showCalibration() },
            showSettings: { [weak self] in self?.showMainWindow(.general) },
            showOverview: { [weak self] in self?.showMainWindow(.overview) },
            showDevices: { [weak self] in self?.showMainWindow(.devices) },
            quit: { NSApplication.shared.terminate(nil) }
        )
        let popoverContent = NSHostingController(rootView: PopoverView(model: monitor.model, actions: actions))
        popoverContent.sizingOptions = [.preferredContentSize]

        popover = NSPopover()
        popover.contentViewController = popoverContent
        // VM_OPEN_POPOVER=1 时保持弹出，便于截图验证；正常使用仍是 transient。
        popover.behavior = ProcessInfo.processInfo.environment["VM_OPEN_POPOVER"] == "1"
            ? .applicationDefined
            : .transient
        popover.animates = true
        popover.delegate = self

        if preferences.monitoringEnabled {
            audioMonitor.start()
            appAttribution.start()
        }
        refreshData()
        setRefreshInterval(Self.backgroundRefreshInterval)

        // 已结束的周写入永久存档；分钟明细 8 周后裁剪，存档在此之前早已完成。
        WeeklySummaryStore.shared.archiveCompletedWeeks()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in WeeklySummaryStore.shared.archiveCompletedWeeks() }
        }

        // 默认只在用户点击菜单栏图标时弹出，避免启动/自启时打扰。
        // （从 Finder 打开时也保持安静：状态栏图标本身即是反馈。）
        // VM_OPEN_POPOVER=1 供调试/验证用：启动即弹出。
        if ProcessInfo.processInfo.environment["VM_OPEN_POPOVER"] == "1" {
            presentPopoverWhenReady()
        }
        if ProcessInfo.processInfo.environment["VM_OPEN_MAIN"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.prewarmMainWindow()
            }
        }
        // VM_OPEN_CALIBRATION=1 供调试/验证用：启动即打开校准向导。
        if ProcessInfo.processInfo.environment["VM_OPEN_CALIBRATION"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showCalibration()
            }
        }
        // VM_OPEN_MAIN=overview|weekly|devices|general 供调试/验证用：启动即打开主窗口对应页。
        if let raw = ProcessInfo.processInfo.environment["VM_OPEN_MAIN"], let tab = MainTab(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showMainWindow(tab)
            }
        }
        // macOS 26+ 的宿主异常时，按钮窗口始终是 22pt 高（正常为 30/33pt）且无内容，
        // 说明系统侧没有把该 bundle id 的菜单栏项目放上栏。启动后探测一次，之后定时复检。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            Task { @MainActor in self?.checkMenuBarHost() }
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMenuBarHost() }
        }
    }

    /// 弹窗打开时 10 Hz 刷新数字；平时只需更新菜单栏，1 Hz 足够。
    /// 声暴露由音频线程累计能量，刷新频率不影响积分精度。
    private static let popoverRefreshInterval: TimeInterval = 0.1
    private static let backgroundRefreshInterval: TimeInterval = 1.0

    private func setRefreshInterval(_ interval: TimeInterval) {
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshData() }
        }
        timer?.tolerance = interval * 0.25
    }

    func popoverWillShow(_ notification: Notification) {
        monitor.reloadDailyStats()
        setRefreshInterval(Self.popoverRefreshInterval)
    }

    func popoverDidClose(_ notification: Notification) {
        setRefreshInterval(Self.backgroundRefreshInterval)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        OverlayScrollers.apply(to: notification.object as? NSWindow)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        exposureService.flush()
        outputMonitor.stop()
        audioMonitor.stop()
        appAttribution.stop()
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
            appAttribution.start()
        } else {
            audioMonitor.stop()
            appAttribution.stop()
        }
        refreshData()
    }

    private func showMainWindow(_ tab: MainTab) {
        popover.performClose(nil)
        makeMainWindowControllerIfNeeded()
        mainWindowController?.show(tab: tab)
    }

    private func makeMainWindowControllerIfNeeded() {
        if mainWindowController == nil {
            let settings = SettingsViewModel(
                outputMonitor: outputMonitor,
                profiles: profileRepository,
                preferences: preferences,
                calibrationStore: calibrationStore,
                onMonitoringChanged: { [weak self] enabled in
                    self?.setMonitoringEnabled(enabled)
                }
            )
            mainWindowController = MainWindowController(
                live: monitor.model,
                settings: settings,
                profiles: profileRepository,
                calibrationStore: calibrationStore,
                outputMonitor: outputMonitor,
                onShowCalibration: { [weak self] in self?.showCalibration() },
                onWillShow: { [weak self] in self?.monitor.reloadDailyStats() }
            )
        }
    }

    /// 主窗口第一次创建要加载 SwiftUI 分栏、Charts 等框架并汇总数据，现做会卡近一秒半。
    /// 启动几秒后趁空闲提前建好（不显示），之后打开只剩几十毫秒。
    private func prewarmMainWindow() {
        guard mainWindowController == nil else { return }
        let start = CFAbsoluteTimeGetCurrent()
        makeMainWindowControllerIfNeeded()
        mainWindowController?.prewarm {
            AppDiagnostics.log(String(format: "main window prewarmed in %.0f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000))
        }
    }

    private func showQuickSetup() {
        showMainWindow(.devices)
        mainWindowController?.settings.showQuickSetup = true
    }

    private func showCalibration() {
        if calibrationWindowController == nil {
            calibrationWindowController = CalibrationWizardWindowController(
                outputMonitor: outputMonitor,
                profiles: profileRepository,
                calibrationStore: calibrationStore,
                onSaved: { [weak self] in
                    self?.refreshData()
                    self?.mainWindowController?.settings.revision += 1
                }
            )
        }
        calibrationWindowController?.showWindow(nil)
        calibrationWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func refreshData() {
        monitor.refresh()
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
        button.attributedTitle = statusBarAttributedTitle("🎧 --")
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.toolTip = "听力暴露监测"
        button.needsDisplay = true
        diag("install done: frame=\(String(describing: button.window?.frame)) mainScreen=\(String(describing: NSScreen.main?.frame))")
    }

    private func diag(_ message: String) {
        AppDiagnostics.log(message)
    }

    /// 菜单栏状态项统一使用白色文字；深色菜单栏/壁纸下更清晰。
    private func statusBarAttributedTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: statusItem.button?.font
                    ?? NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }

    private func updateStatusBarIcon() {
        let text = monitor.statusBarLevelText
        let color = monitor.statusBarLevelColor
        let colorKey = statusBarColorKey(color)
        guard text != lastStatusBarText || colorKey != lastStatusBarColorKey else { return }
        lastStatusBarText = text
        lastStatusBarColorKey = colorKey
        statusItem.button?.attributedTitle = statusBarAttributedTitle(text)
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
