import AppKit
import Combine
import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case overview, weekly, devices, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .weekly: "每周小结"
        case .devices: "设备与校准"
        case .general: "通用"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .weekly: "chart.bar.xaxis"
        case .devices: "headphones"
        case .general: "slider.horizontal.3"
        }
    }
}

@MainActor
final class MainWindowState: ObservableObject {
    @Published var tab: MainTab = .overview
    /// 每次打开窗口加一，让当前页重播入场动画。
    @Published var revealToken = 1
    /// 窗口正在弹出：当前页先停在动画起点，等窗口出现后再播放。
    @Published var revealPending = false

    func token(for tab: MainTab) -> Int {
        guard tab == self.tab else { return 0 }
        return revealPending ? -1 : revealToken
    }
}

/// 主窗口：合并了原来的设置窗口、详情弹层和每周小结窗口。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let state = MainWindowState()
    let settings: SettingsViewModel
    let weekly: WeeklySummaryViewModel
    let devices: DevicesModel
    let overview: OverviewModel
    private let live: LiveMonitorModel
    private let onWillShow: () -> Void

    init(
        live: LiveMonitorModel,
        settings: SettingsViewModel,
        profiles: ProfileRepository,
        calibrationStore: CalibrationStore,
        outputMonitor: OutputDeviceMonitor,
        onShowCalibration: @escaping () -> Void,
        onWillShow: @escaping () -> Void
    ) {
        self.live = live
        self.settings = settings
        self.onWillShow = onWillShow
        weekly = WeeklySummaryViewModel(profiles: profiles)
        devices = DevicesModel(profiles: profiles, calibrationStore: calibrationStore, outputMonitor: outputMonitor)
        overview = OverviewModel()

        let root = MainWindowView(
            state: state,
            settings: settings,
            live: live,
            weekly: weekly,
            devices: devices,
            overview: overview,
            onShowCalibration: onShowCalibration
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "音量监测"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 940, height: 660))
        window.contentMinSize = NSSize(width: 820, height: 580)
        window.setFrameAutosaveName("VolumeMonitorMainWindow")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    /// 关窗时（窗口已不可见）就把当前页复位到动画起点，下次打开不用在弹出的那一帧里重排。
    func windowWillClose(_ notification: Notification) {
        state.revealPending = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 启动后空闲时调用：提前加载数据、建立各页面并排版一次（含首次加载 Charts 等框架），
    /// 用户第一次打开时就不用现做。窗口不显示。
    /// 依次把四页各建一次（含首次加载 Charts），并让窗口“真正上屏”一次（全透明、在最后面），
    /// 系统第一次显示窗口时的初始化（约 70 ms）也提前做掉。
    func prewarm(completion: @escaping () -> Void = {}) {
        reloadData()
        guard let window else { return completion() }
        window.alphaValue = 0
        window.orderBack(nil)
        let tabs: [MainTab] = [.weekly, .devices, .general, .overview]
        func step(_ index: Int) {
            guard index < tabs.count else {
                window.orderOut(nil)
                window.alphaValue = 1
                state.revealPending = true
                return completion()
            }
            state.tab = tabs[index]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                step(index + 1)
            }
        }
        step(0)
    }

    func show(tab: MainTab) {
        // 先让窗口弹出（当前页停在动画起点），数据刷新和入场动画放到窗口出现之后。
        // 不用 showWindow：它会为“无缝打开文档”动画临时加载 QuickLook 框架，本应用用不到。
        if window?.isVisible != true { state.revealPending = true }
        if state.tab != tab { state.tab = tab }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            reloadData()
            state.revealToken += 1
            state.revealPending = false
        }
    }

    private func reloadData() {
        onWillShow()
        settings.reloadCurrentDevice()
        weekly.reload()
        devices.reload()
        overview.reload()
    }
}

struct MainWindowView: View {
    @ObservedObject var state: MainWindowState
    @ObservedObject var settings: SettingsViewModel
    // 下面几个只传给各页面，根视图不订阅：实时声级每秒都在变，订阅会让整个窗口跟着重算。
    let live: LiveMonitorModel
    let weekly: WeeklySummaryViewModel
    let devices: DevicesModel
    let overview: OverviewModel
    let onShowCalibration: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { state.tab },
                set: { if let tab = $0 { state.tab = tab } }
            )) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                Text("估算结果不代替专业测量或医疗建议。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(12)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                // 只保留当前页：隐藏页即使透明也会每帧参与绘制，常驻四页反而更卡（实测）。
                // 各页在启动后的预加载里都建过一次，切换时重建很快。
                page(for: state.tab)
                    .id(state.tab)
                    .environment(\.revealToken, state.token(for: state.tab))
                    .transition(.opacity)
                if !settings.message.isEmpty {
                    MessageBanner(text: settings.message) { settings.message = "" }
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: state.tab)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: settings.message)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $settings.showQuickSetup) {
            QuickSetupWizardView(
                viewModel: QuickSetupWizardViewModel(
                    outputMonitor: settings.outputMonitor,
                    profiles: settings.profiles
                ),
                onSaved: {
                    settings.showQuickSetup = false
                    settings.revision += 1
                    settings.reloadCurrentDevice()
                },
                onCancel: { settings.showQuickSetup = false }
            )
        }
        .sheet(isPresented: $settings.showEditor) {
            ProfileEditorSheet(settings: settings)
        }
        .onChange(of: settings.revision) {
            devices.reload()
            overview.reload()
        }
    }

    @ViewBuilder private func page(for tab: MainTab) -> some View {
        switch tab {
        case .overview:
            OverviewPage(live: live, overview: overview)
        case .weekly:
            WeeklySummaryView(viewModel: weekly)
        case .devices:
            DevicesPage(settings: settings, devices: devices, onShowCalibration: onShowCalibration)
        case .general:
            GeneralPage(settings: settings)
        }
    }
}

/// 页面底部的操作结果提示，几秒后自动消失。
private struct MessageBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isProblem ? Theme.loud : Theme.safe)
            Text(text)
                .font(.callout)
                .lineLimit(3)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .frame(maxWidth: 560)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(isProblem ? 8 : 4))
            onDismiss()
        }
    }

    private var isProblem: Bool {
        ["失败", "无效", "错误", "请输入", "请记录", "不能", "无法"].contains { text.contains($0) }
    }
}

/// 页面标题 + 可选副标题。
struct PageHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Spacer()
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
