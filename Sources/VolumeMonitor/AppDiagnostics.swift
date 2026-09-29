import Foundation

/// VM_DIAG=1 时把诊断信息追加到 /tmp/vm_diag.log；默认完全关闭，不影响正常运行。
enum AppDiagnostics {
    static let isEnabled = ProcessInfo.processInfo.environment["VM_DIAG"] == "1"

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "\(Date()) [VolumeMonitor] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: "/tmp/vm_diag.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/vm_diag.log"))
        }
    }
}
