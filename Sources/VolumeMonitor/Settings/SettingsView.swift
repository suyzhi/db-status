import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.showAdvanced {
                    advancedForm
                } else {
                    simpleForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .frame(minWidth: 560, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $viewModel.showHistory) {
            HistoryView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showQuickSetup) {
            QuickSetupWizardView(
                viewModel: QuickSetupWizardViewModel(
                    outputMonitor: viewModel.outputMonitor,
                    profiles: viewModel.profiles
                ),
                onSaved: {
                    viewModel.reloadCurrentDevice()
                    viewModel.showQuickSetup = false
                },
                onCancel: {
                    viewModel.showQuickSetup = false
                }
            )
        }
    }

    // MARK: - 简单页（默认）

    private var simpleForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("监测") {
                    Toggle("启用系统音频监测", isOn: Binding(
                        get: { viewModel.monitoringEnabled },
                        set: { viewModel.setMonitoringEnabled($0) }
                    ))
                    HStack {
                        Text("菜单栏显示")
                        Spacer()
                        Picker("", selection: Binding(
                            get: {
                                viewModel.statusBarDisplayMode == .estimatedDBA
                                    ? StatusBarDisplayMode.estimatedDBA
                                    : StatusBarDisplayMode.sevenDayDose
                            },
                            set: { viewModel.setStatusBarDisplayMode($0) }
                        )) {
                            Text("实时 dBA").tag(StatusBarDisplayMode.estimatedDBA)
                            Text("过去 7 天剂量 %").tag(StatusBarDisplayMode.sevenDayDose)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    if viewModel.statusBarDisplayMode == .rmsDBFS {
                        Text("当前显示为 RMS(A) dBFS（高级选项）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("当前设备") {
                    LabeledContent("名称", value: viewModel.deviceName)
                    LabeledContent("档案", value: viewModel.hasBoundProfile ? "✓ 已绑定可信估算" : "未绑定（先做快速设置）")
                    Button {
                        viewModel.showQuickSetup = true
                    } label: {
                        Label(viewModel.hasBoundProfile ? "重新快速设置…" : "快速设置…", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    HStack {
                        Button("导出档案…") { viewModel.exportProfiles() }
                        Button("导入档案…") { viewModel.importProfiles() }
                    }
                }

                Section("过去 7 天声暴露") {
                    HStack {
                        Text(String(format: "%.1f%%", viewModel.currentDosePercent))
                            .font(.system(size: 34, weight: .bold))
                            .monospacedDigit()
                        Spacer()
                        Button("每周小结…") { viewModel.onShowWeeklySummary() }
                        Button("查看详情…") { viewModel.showHistory = true }
                    }
                    if viewModel.historyPoints.isEmpty {
                        Text("暂无可信的声暴露记录")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    } else {
                        Text("按 WHO 成人参考：80 dBA × 40 小时 = 100%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 高级页（展开全部现有功能）

    private var advancedForm: some View {
        Form {
            Section("监测") {
                Toggle("启用系统音频监测", isOn: Binding(
                    get: { viewModel.monitoringEnabled },
                    set: { viewModel.setMonitoringEnabled($0) }
                ))
                Toggle("登录时启动", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                Button("打开系统音频权限设置…") {
                    viewModel.openAudioPermissionSettings()
                }
                Picker("声暴露基准", selection: Binding(
                    get: { viewModel.exposureMode },
                    set: { viewModel.setExposureMode($0) }
                )) {
                    ForEach(ExposureMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("菜单栏显示", selection: Binding(
                    get: { viewModel.statusBarDisplayMode },
                    set: { viewModel.setStatusBarDisplayMode($0) }
                )) {
                    ForEach(StatusBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("当前输出设备") {
                LabeledContent("名称", value: viewModel.deviceName)
                LabeledContent("CoreAudio UID", value: viewModel.deviceUID.isEmpty ? "不可用" : viewModel.deviceUID)
                Button { viewModel.showQuickSetup = true } label: {
                    Label("快速设置当前设备…", systemImage: "sparkles")
                }
            }

            Section("可信估算档案") {
                TextField("档案名称", text: $viewModel.profileName)
                Picker("档案类型", selection: $viewModel.kind) {
                    ForEach(TransducerKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                if viewModel.kind == .wiredHeadphones {
                    Picker("灵敏度单位", selection: $viewModel.sensitivityUnit) {
                        Text("dB/V").tag("dbPerVolt")
                        Text("dB/mW").tag("dbPerMilliwatt")
                    }
                    TextField("灵敏度数值", text: $viewModel.sensitivityValue)
                    if viewModel.sensitivityUnit == "dbPerMilliwatt" {
                        TextField("阻抗 (Ω)", text: $viewModel.impedanceOhms)
                    }
                    TextField("灵敏度测量频率 (Hz)", text: $viewModel.sensitivityReferenceHz)
                    Text("规格里写的频率，例如“110 dB @ 1 V / 500 Hz”填 500；没写就填 1000。有 EM258 频响校准时会据此换算。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("输出源最大 Vrms", text: $viewModel.maxOutputVRMS)
                    TextField("音量曲线（可选）", text: $viewModel.volumeCurveText)
                    Text("例如 25=-40, 50=-18, 100=0；少于两个曲线点时结果标记为“估算曲线”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("校准点（音量%=dBA）", text: $viewModel.acousticPointsText)
                    Text("例如 25=70, 50=82, 100=96；请使用声学耦合器或可追溯的参考测量，扬声器需在固定聆听位置校准。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("可选校准偏移 (dB)", text: $viewModel.calibrationOffsetDB)
                TextField("规格/校准来源（必填）", text: $viewModel.reference)
                HStack {
                    Button("保存并绑定当前 UID") { viewModel.saveProfile() }
                        .buttonStyle(.borderedProminent)
                    Button("删除档案", role: .destructive) { viewModel.removeProfile() }
                    Spacer()
                    Button("重新读取设备") { viewModel.reloadCurrentDevice() }
                }
                HStack {
                    Button("导出全部档案…") { viewModel.exportProfiles() }
                    Button("导入档案…") { viewModel.importProfiles() }
                    Spacer()
                }
                Text("导出包含所有设备档案和 EM258 校准，换电脑时导入即可，不用重新校准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("EM258 校准") {
                Text(viewModel.calibrationStatus)
                    .font(.caption)
                    .foregroundStyle(viewModel.hasCurrentCalibration ? .blue : .secondary)
                Text("删除校准不会删除耳机参数档案或声暴露记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("删除当前校准并恢复标准估算", role: .destructive) {
                    viewModel.removeCalibration()
                }
                .disabled(!viewModel.hasCurrentCalibration)
            }

            Section("过去 7 天声暴露") {
                HStack {
                    Text(String(format: "%.1f%%", viewModel.currentDosePercent))
                        .font(.system(size: 28, weight: .bold))
                        .monospacedDigit()
                    Spacer()
                    Button("查看详情…") { viewModel.showHistory = true }
                }
                Text("按 WHO 成人参考：80 dBA × 40 小时 = 100%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 底部状态栏（固定，不随内容滚走）

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: footerIsProblem ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(footerIsProblem ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.message.isEmpty ? "所有档案和暴露记录仅保存在本机。" : viewModel.message)
                    .font(.caption)
                    .foregroundStyle(footerIsProblem ? Color.red : Color.secondary)
                    .lineLimit(2)
                Text("估算结果不代替专业测量或医疗建议。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 16)
            Button(viewModel.showAdvanced ? "返回简版" : "显示高级选项…") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    viewModel.showAdvanced.toggle()
                }
            }
            .buttonStyle(.link)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var footerIsProblem: Bool {
        viewModel.message.contains("失败")
            || viewModel.message.contains("请")
            || viewModel.message.contains("无法")
    }
}

/// 趋势/历史详情（弹层）。
