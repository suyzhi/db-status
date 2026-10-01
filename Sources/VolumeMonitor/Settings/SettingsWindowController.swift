import AppKit
import SwiftUI

struct ExposureHistoryPoint: Identifiable {
    var id: Date { minute }
    let minute: Date
    let equivalentLevelDBA: Double
    let peakDBA: Double
    let deviceUID: String
}

struct DeviceExposureSummary: Identifiable {
    var id: String { deviceUID }
    let deviceUID: String
    let dosePercent: Double
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let viewModel: SettingsViewModel

    init(
        outputMonitor: OutputDeviceMonitor,
        profiles: ProfileRepository,
        preferences: AppPreferences,
        calibrationStore: CalibrationStore,
        onMonitoringChanged: @escaping (Bool) -> Void,
        onShowWeeklySummary: @escaping () -> Void
    ) {
        viewModel = SettingsViewModel(
            outputMonitor: outputMonitor,
            profiles: profiles,
            preferences: preferences,
            calibrationStore: calibrationStore,
            onMonitoringChanged: onMonitoringChanged,
            onShowWeeklySummary: onShowWeeklySummary
        )
        // VM_OPEN_ADVANCED / VM_OPEN_WIZARD 仅供调试/验证：直接定位到对应页面。
        // 必须在创建 NSHostingController 之前设置，否则首帧已经按旧值渲染。
        if ProcessInfo.processInfo.environment["VM_OPEN_ADVANCED"] == "1" {
            viewModel.showAdvanced = true
        }
        if ProcessInfo.processInfo.environment["VM_OPEN_WIZARD"] == "1" {
            viewModel.showQuickSetup = true
        }
        let hostingController = NSHostingController(rootView: SettingsView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "音量监测设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 600, height: 760))
        window.contentMinSize = NSSize(width: 560, height: 620)
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        viewModel.reloadCurrentDevice()
        super.showWindow(sender)
        applyOverlayScrollers()
        // SwiftUI 的 Form 在首次布局后才挂上内部 NSScrollView，稍后再配置一次。
        DispatchQueue.main.async { [weak self] in self?.applyOverlayScrollers() }
    }

    private func applyOverlayScrollers() {
        OverlayScrollers.apply(to: window)
    }
}
