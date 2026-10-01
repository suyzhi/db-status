import SwiftUI

struct GeneralPage: View {
    @ObservedObject var settings: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "通用")
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .appearAnimation()
            Form {
                Section("监测") {
                    Toggle("启用系统音频监测", isOn: Binding(
                        get: { settings.monitoringEnabled },
                        set: { settings.setMonitoringEnabled($0) }
                    ))
                    Toggle("登录时启动", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.setLaunchAtLogin($0) }
                    ))
                }
                Section {
                    Picker("声暴露标准", selection: Binding(
                        get: { settings.exposureMode },
                        set: { settings.setExposureMode($0) }
                    )) {
                        Text("WHO 成人（80 dBA）").tag(ExposureMode.adult)
                        Text("保守（75 dBA）").tag(ExposureMode.conservative)
                    }
                    .pickerStyle(.segmented)
                    Picker("菜单栏显示", selection: Binding(
                        get: { settings.statusBarDisplayMode },
                        set: { settings.setStatusBarDisplayMode($0) }
                    )) {
                        Text("实时 dBA").tag(StatusBarDisplayMode.estimatedDBA)
                        Text("7 天暴露 %").tag(StatusBarDisplayMode.sevenDayDose)
                        Text("RMS dBFS").tag(StatusBarDisplayMode.rmsDBFS)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("显示与标准")
                } footer: {
                    Text("过去 7 天滚动累计，按所选标准 40 小时为 100%。保守模式适合想留出更多余量的情况。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    LabeledContent("系统音频录制权限") {
                        Button("打开系统设置…") { settings.openAudioPermissionSettings() }
                    }
                    LabeledContent("本地数据") {
                        Button("导出 CSV…") { settings.exportCSV() }
                    }
                } header: {
                    Text("权限与数据")
                } footer: {
                    Text("所有记录只存在本机：分钟明细保留 8 周，每周汇总永久保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Text("音量监测根据系统音频与耳机参数估算耳边声压，用于了解自己的聆听习惯。估算结果不代替专业测量或医疗建议；如有听力方面的担心，请做一次纯音测听。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .appearAnimation(delay: 0.05)
        }
    }
}
