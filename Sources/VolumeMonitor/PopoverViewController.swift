import AppKit
import Foundation
import CoreAudio

// MARK: - Headphone Model
struct HeadphoneModel {
    let name: String
    let outputDeviceNames: [String]
    let sensitivityDBV: Float
    let impedance: Float
    let maxOutputVRMS: Float
    let isEstimatedProfile: Bool
}

private let playbackProfiles: [HeadphoneModel] = [
    HeadphoneModel(
        name: "AirPods Pro 3",
        outputDeviceNames: ["airpods pro", "airpods", "airpods pro 3"],
        sensitivityDBV: 105,
        impedance: 32,
        maxOutputVRMS: 1.0,
        isEstimatedProfile: true
    ),
    HeadphoneModel(
        name: "Mac 普通扬声器",
        outputDeviceNames: ["macbook", "mac", "built-in", "internal speakers", "内建", "内置", "扬声器", "speakers"],
        sensitivityDBV: 84,
        impedance: 8,
        maxOutputVRMS: 1.0,
        isEstimatedProfile: true
    ),
    HeadphoneModel(
        name: "水月雨 竹 2",
        outputDeviceNames: ["chu", "chu ii", "chu 2", "水月雨", "竹", "moondrop", "headphones", "external headphones", "外置耳机", "耳机"],
        sensitivityDBV: 119,
        impedance: 18,
        maxOutputVRMS: 1.0,
        isEstimatedProfile: false
    )
]

private let fallbackProfile = playbackProfiles[1]

// MARK: - Volume Estimation
let macMaxOutputVRMS: Float = 1.0
let maxAttenuation: Float = 65
let curveExponent: Float = 1.6

func volumeToVoltage(_ volume: Float, maxOutputVRMS: Float = macMaxOutputVRMS) -> Float {
    guard volume > 0 else { return 0 }
    return maxOutputVRMS * pow(10, -maxAttenuation * pow(1 - volume/100, curveExponent) / 20.0)
}

func estimateDBSPL(volume: Float, model: HeadphoneModel) -> (dbSPL: Float, attenuationDB: Float) {
    let v = volumeToVoltage(volume, maxOutputVRMS: model.maxOutputVRMS)
    let attenDB: Float = volume > 0 ? 20 * log10(v / model.maxOutputVRMS) : -.infinity
    return (model.sensitivityDBV + attenDB, attenDB)
}

func safetyInfo(_ db: Float) -> (label: String, emoji: String, color: NSColor) {
    switch db {
    case ..<70:  return ("安全", "🟢", NSColor(red: 0.3, green: 0.85, blue: 0.5, alpha: 1))
    case ..<80:  return ("较安全", "🟡", NSColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
    case ..<85:  return ("注意", "🟠", NSColor.orange)
    case ..<90:  return ("偏高", "🔶", NSColor(red: 1, green: 0.6, blue: 0.1, alpha: 1))
    case ..<100: return ("危险", "🔴", NSColor.red)
    default:     return ("极度危险", "⛔", NSColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
    }
}

// MARK: - Popover View Controller
@MainActor
class PopoverViewController: NSViewController {
    private let audioMonitor: SystemAudioLevelMonitor

    private var titleLabel: NSTextField!
    private var statusDot: NSView!
    private var statusLabel: NSTextField!
    private var volTitleLabel: NSTextField!
    private var volumeNumberLabel: NSTextField!
    private var volumeUnitLabel: NSTextField!
    private var volumeBarContainer: NSView!
    private var volumeBar: NSView!
    private var maxSPLLabel: NSTextField!
    private var dbTitleLabel: NSTextField!
    private var dbSPLLabel: NSTextField!
    private var dbUnitLabel: NSTextField!
    private var audioBarContainer: NSView!
    private var audioBar: NSView!
    private var rmsLabel: NSTextField!
    private var peakLabel: NSTextField!
    private var safetyEmojiLabel: NSTextField!
    private var safetyLabel: NSTextField!
    private var safetyDetailLabel: NSTextField!
    private var hpInfoLabel: NSTextField!
    private var separatorLine: NSView!
    private var scaleContainer: NSView!
    private var scaleTitleField: NSTextField!
    private var scaleTrack: NSView!
    private var scaleFill: NSView!
    private var thresholdMarker: NSView!
    private var currentMarker: NSView!
    private var scaleLabels: [NSTextField] = []

    private var currentVolume: Float = 0
    private var displayedVolume: Float = 0
    private var displayedRMSDBFS: Float = -96
    private var displayedPeakDBFS: Float = -96
    private var displayedAudioFraction: Float = 0
    private var displayedDBSPL: Float?
    private var currentDBSPL: Float?
    private var lastVolumePoll = Date.distantPast
    private var lastDisplayRefresh = Date()
    private var lastTextRefresh = Date.distantPast
    private var activeProfile = fallbackProfile

    private(set) var statusBarLevelText = "--"
    private(set) var statusBarLevelColor = NSColor.systemGray

    init(audioMonitor: SystemAudioLevelMonitor) {
        self.audioMonitor = audioMonitor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 390))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        relayout()
    }

    // MARK: - UI Build
    private func buildUI() {
        let root = view
        root.wantsLayer = true
        root.layer?.cornerRadius = 16
        root.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)

        let overlay = NSView(frame: root.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: blur)

        titleLabel = makeLabel("🎧 音量监测", size: 15, weight: .semibold, color: .white)
        root.addSubview(titleLabel)

        statusDot = NSView(frame: .zero)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = NSColor.systemGray.cgColor
        root.addSubview(statusDot)

        statusLabel = makeLabel("启动中", size: 10, weight: .medium, color: NSColor(white: 0.68, alpha: 1))
        statusLabel.alignment = .right
        root.addSubview(statusLabel)

        volTitleLabel = makeLabel("系统音量", size: 11, weight: .medium, color: NSColor(white: 0.72, alpha: 1))
        root.addSubview(volTitleLabel)

        volumeNumberLabel = makeLabel("0", size: 31, weight: .bold, color: NSColor(red: 0.56, green: 0.84, blue: 1.0, alpha: 1))
        volumeNumberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 31, weight: .bold)
        root.addSubview(volumeNumberLabel)

        volumeUnitLabel = makeLabel("%", size: 12, weight: .medium, color: NSColor(white: 0.58, alpha: 1))
        root.addSubview(volumeUnitLabel)

        volumeBarContainer = makeBarContainer(heightRadius: 5)
        root.addSubview(volumeBarContainer)

        volumeBar = makeBar(color: NSColor(red: 0.38, green: 0.72, blue: 1.0, alpha: 0.8), radius: 4)
        volumeBarContainer.addSubview(volumeBar)

        maxSPLLabel = makeLabel("满刻度估算 -- dBA", size: 10, weight: .regular, color: NSColor(white: 0.52, alpha: 1))
        root.addSubview(maxSPLLabel)

        dbTitleLabel = makeLabel("实时估算声压(A)", size: 11, weight: .medium, color: NSColor(white: 0.72, alpha: 1))
        root.addSubview(dbTitleLabel)

        dbSPLLabel = makeLabel("—", size: 39, weight: .bold, color: .white)
        dbSPLLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 39, weight: .bold)
        root.addSubview(dbSPLLabel)

        dbUnitLabel = makeLabel("dBA", size: 12, weight: .medium, color: NSColor(white: 0.55, alpha: 1))
        root.addSubview(dbUnitLabel)

        audioBarContainer = makeBarContainer(heightRadius: 6)
        root.addSubview(audioBarContainer)

        audioBar = makeBar(color: NSColor.systemGreen.withAlphaComponent(0.78), radius: 5)
        audioBarContainer.addSubview(audioBar)

        rmsLabel = makeLabel("RMS(A) -- dBFS", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        root.addSubview(rmsLabel)

        peakLabel = makeLabel("Peak -- dBFS", size: 10, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        peakLabel.alignment = .right
        root.addSubview(peakLabel)

        safetyEmojiLabel = makeLabel("◌", size: 17, weight: .regular, color: .white)
        root.addSubview(safetyEmojiLabel)

        safetyLabel = makeLabel("等待音频", size: 14, weight: .semibold, color: .white)
        root.addSubview(safetyLabel)

        safetyDetailLabel = makeLabel("播放声音后开始估算", size: 11, weight: .regular, color: NSColor(white: 0.58, alpha: 1))
        root.addSubview(safetyDetailLabel)

        separatorLine = NSView(frame: .zero)
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor(white: 0.32, alpha: 0.25).cgColor
        root.addSubview(separatorLine)

        hpInfoLabel = makeLabel("🎯 \(profileDescription(activeProfile))", size: 10, weight: .regular, color: NSColor(white: 0.48, alpha: 1))
        root.addSubview(hpInfoLabel)

        buildScale()
    }

    private func buildScale() {
        scaleContainer = NSView(frame: .zero)
        scaleContainer.wantsLayer = true
        scaleContainer.layer?.cornerRadius = 8
        scaleContainer.layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.48).cgColor
        scaleContainer.layer?.borderColor = NSColor(white: 0.22, alpha: 0.32).cgColor
        scaleContainer.layer?.borderWidth = 0.5
        view.addSubview(scaleContainer)

        scaleTitleField = makeLabel("声压参考", size: 9, weight: .medium, color: NSColor(white: 0.56, alpha: 1))
        scaleContainer.addSubview(scaleTitleField)

        scaleTrack = makeBarContainer(heightRadius: 4)
        scaleContainer.addSubview(scaleTrack)

        scaleFill = makeBar(color: NSColor(red: 0.4, green: 0.78, blue: 1.0, alpha: 0.65), radius: 3)
        scaleTrack.addSubview(scaleFill)

        thresholdMarker = makeMarker(color: NSColor.orange)
        scaleContainer.addSubview(thresholdMarker)

        currentMarker = makeMarker(color: .white)
        scaleContainer.addSubview(currentMarker)

        for text in ["50", "70", "85", "100", "117 dBA"] {
            let label = makeLabel(text, size: 8, weight: .regular, color: NSColor(white: 0.52, alpha: 1))
            label.alignment = .center
            scaleContainer.addSubview(label)
            scaleLabels.append(label)
        }
    }

    // MARK: - Layout
    private func relayout() {
        let w = view.bounds.width
        let margin: CGFloat = 18
        let contentW = w - margin * 2

        titleLabel.frame = NSRect(x: margin, y: 354, width: 170, height: 22)
        statusDot.frame = NSRect(x: w - margin - 8, y: 361, width: 8, height: 8)
        statusLabel.frame = NSRect(x: w - 148, y: 339, width: 130, height: 16)

        volTitleLabel.frame = NSRect(x: margin, y: 314, width: 140, height: 16)
        volumeNumberLabel.frame = NSRect(x: margin, y: 276, width: 66, height: 38)
        volumeUnitLabel.frame = NSRect(x: 78, y: 289, width: 20, height: 16)
        volumeBarContainer.frame = NSRect(x: 116, y: 294, width: w - 134, height: 10)
        maxSPLLabel.frame = NSRect(x: 116, y: 274, width: w - 134, height: 14)

        dbTitleLabel.frame = NSRect(x: margin, y: 241, width: 160, height: 16)
        dbSPLLabel.frame = NSRect(x: margin, y: 197, width: 128, height: 44)
        dbUnitLabel.frame = NSRect(x: 151, y: 212, width: 62, height: 18)
        audioBarContainer.frame = NSRect(x: margin, y: 181, width: contentW, height: 12)
        rmsLabel.frame = NSRect(x: margin, y: 160, width: 128, height: 14)
        peakLabel.frame = NSRect(x: w - margin - 128, y: 160, width: 128, height: 14)

        safetyEmojiLabel.frame = NSRect(x: margin, y: 132, width: 24, height: 22)
        safetyLabel.frame = NSRect(x: 46, y: 134, width: 104, height: 19)
        safetyDetailLabel.frame = NSRect(x: 150, y: 135, width: w - 168, height: 16)

        separatorLine.frame = NSRect(x: margin, y: 119, width: contentW, height: 1)
        hpInfoLabel.frame = NSRect(x: margin, y: 97, width: contentW, height: 16)

        scaleContainer.frame = NSRect(x: margin, y: 18, width: contentW, height: 70)
        layoutScale()
        updateBars(animated: false)
    }

    private func layoutScale() {
        let c = scaleContainer.bounds
        guard c.width > 0 else { return }

        scaleTitleField.frame = NSRect(x: 10, y: c.height - 20, width: c.width - 20, height: 14)
        scaleTrack.frame = NSRect(x: 10, y: 31, width: c.width - 20, height: 8)

        let values: [Float] = [50, 70, 85, 100, 117]
        for (index, label) in scaleLabels.enumerated() {
            let x = scaleX(for: values[index], in: c) - 18
            label.frame = NSRect(x: x, y: 10, width: 36, height: 12)
        }

        let thresholdX = scaleX(for: 85, in: c)
        thresholdMarker.frame = NSRect(x: thresholdX - 1, y: 27, width: 2, height: 16)
    }

    // MARK: - Data Refresh
    func refreshVolume() {
        loadViewIfNeeded()

        refreshSystemVolume()
        let maxSPL = estimateDBSPL(volume: currentVolume, model: activeProfile).dbSPL
        let snapshot = audioMonitor.snapshot()
        updateSmoothedDisplay(snapshot: snapshot, maxSPL: maxSPL)

        volumeNumberLabel.stringValue = "\(Int(displayedVolume.rounded()))"
        hpInfoLabel.stringValue = "🎯 \(profileDescription(activeProfile))"
        if maxSPL.isFinite {
            maxSPLLabel.stringValue = String(format: "满刻度估算 %.1f dBA", maxSPL)
        } else {
            maxSPLLabel.stringValue = "系统静音"
        }

        updateAudioState(snapshot: snapshot, maxSPL: maxSPL)
        updateBars(animated: true)
    }

    private func refreshSystemVolume() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var sz = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return }

        if let deviceName = readOutputDeviceName(deviceID: deviceID) {
            activeProfile = profile(for: deviceName)
        }

        if let volume = readOutputVolume(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            currentVolume = volume * 100
            return
        }

        let channels = [
            readOutputVolume(deviceID: deviceID, element: 1),
            readOutputVolume(deviceID: deviceID, element: 2)
        ].compactMap { $0 }

        if !channels.isEmpty {
            currentVolume = (channels.reduce(0, +) / Float(channels.count)) * 100
        }
    }

    private func readOutputVolume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &volAddr) else { return nil }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &volAddr, 0, nil, &size, &volume) == noErr else {
            return nil
        }

        return max(0, min(1, volume))
    }

    private func readOutputDeviceName(deviceID: AudioObjectID) -> String? {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &nameAddr) else { return nil }

        var deviceName: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &deviceName) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &size, pointer)
        }

        guard result == noErr else { return nil }
        return deviceName as String
    }

    private func profile(for deviceName: String) -> HeadphoneModel {
        let normalizedName = deviceName.lowercased()
        if let profile = playbackProfiles.first(where: { model in
            model.outputDeviceNames.contains(where: { normalizedName.contains($0.lowercased()) })
        }) {
            return profile
        }

        return fallbackProfile
    }

    private func updateAudioState(snapshot: AudioLevelSnapshot, maxSPL: Float) {
        rmsLabel.stringValue = formatDBFS("RMS(A)", displayedRMSDBFS)
        peakLabel.stringValue = formatDBFS("Peak", displayedPeakDBFS)

        guard currentVolume > 0 else {
            currentDBSPL = nil
            setInactiveState(title: "系统静音", detail: "提高系统音量后开始估算", color: NSColor.systemGray)
            return
        }

        switch snapshot.status {
        case .capturing where snapshot.hasUsableAudio && maxSPL.isFinite:
            let spl = displayedDBSPL ?? max(0, maxSPL + snapshot.rmsDBFS)
            currentDBSPL = spl
            if shouldRefreshText() {
                dbSPLLabel.stringValue = String(format: "%.1f", spl)
            }

            let safety = safetyInfo(spl)
            statusBarLevelText = "\(Int(spl.rounded()))"
            statusBarLevelColor = safety.color
            safetyEmojiLabel.stringValue = safety.emoji
            safetyLabel.stringValue = safety.label
            safetyLabel.textColor = safety.color
            safetyDetailLabel.stringValue = detailText(for: spl)
            statusLabel.stringValue = "实时采集中"
            statusDot.layer?.backgroundColor = safety.color.cgColor
            audioBar.layer?.backgroundColor = softenedColor(safety.color).cgColor
            scaleFill.layer?.backgroundColor = softenedColor(safety.color).cgColor

        case .noPermission:
            currentDBSPL = nil
            setInactiveState(title: "需要系统音频权限", detail: "授权一次后即可持续读取系统音频", color: NSColor.systemOrange)

        case .failed(let message):
            currentDBSPL = nil
            setInactiveState(title: "采集异常", detail: message.isEmpty ? "无法读取系统音频" : message, color: NSColor.systemRed)

        case .starting:
            currentDBSPL = nil
            setInactiveState(title: "启动采集中", detail: "正在连接系统音频 tap", color: NSColor.systemBlue)

        default:
            currentDBSPL = nil
            setInactiveState(title: "无音频", detail: "播放声音后开始估算", color: NSColor.systemBlue)
        }
    }

    private func setInactiveState(title: String, detail: String, color: NSColor) {
        statusBarLevelText = "--"
        statusBarLevelColor = color
        dbSPLLabel.stringValue = "—"
        safetyEmojiLabel.stringValue = "◌"
        safetyLabel.stringValue = title
        safetyLabel.textColor = color
        safetyDetailLabel.stringValue = detail
        statusLabel.stringValue = title
        statusDot.layer?.backgroundColor = color.cgColor
        audioBar.layer?.backgroundColor = color.withAlphaComponent(0.65).cgColor
        scaleFill.layer?.backgroundColor = color.withAlphaComponent(0.55).cgColor
    }

    private func updateSmoothedDisplay(snapshot: AudioLevelSnapshot, maxSPL: Float) {
        let now = Date()
        let dt = min(max(Float(now.timeIntervalSince(lastDisplayRefresh)), 1.0 / 120.0), 0.25)
        lastDisplayRefresh = now

        displayedVolume = smooth(
            current: displayedVolume,
            target: currentVolume,
            dt: dt,
            attackTime: 0.12,
            releaseTime: 0.18
        )

        guard snapshot.hasUsableAudio, currentVolume > 0, maxSPL.isFinite else {
            displayedRMSDBFS = smooth(
                current: displayedRMSDBFS,
                target: -96,
                dt: dt,
                attackTime: 0.45,
                releaseTime: 0.45
            )
            displayedPeakDBFS = smooth(
                current: displayedPeakDBFS,
                target: -96,
                dt: dt,
                attackTime: 0.7,
                releaseTime: 0.7
            )
            displayedAudioFraction = smooth(
                current: displayedAudioFraction,
                target: 0,
                dt: dt,
                attackTime: 0.45,
                releaseTime: 0.45
            )
            displayedDBSPL = nil
            return
        }

        displayedRMSDBFS = smooth(
            current: displayedRMSDBFS,
            target: snapshot.rmsDBFS,
            dt: dt,
            attackTime: 0.16,
            releaseTime: 0.85
        )
        displayedPeakDBFS = smooth(
            current: displayedPeakDBFS,
            target: snapshot.peakDBFS,
            dt: dt,
            attackTime: 0.08,
            releaseTime: 1.1
        )

        let targetSPL = max(0, maxSPL + snapshot.rmsDBFS)
        displayedDBSPL = smooth(
            current: displayedDBSPL ?? targetSPL,
            target: targetSPL,
            dt: dt,
            attackTime: 0.2,
            releaseTime: 1.0
        )

        let targetAudioFraction = max(0.04, min(1, (displayedRMSDBFS + 60) / 60))
        displayedAudioFraction = smooth(
            current: displayedAudioFraction,
            target: targetAudioFraction,
            dt: dt,
            attackTime: 0.18,
            releaseTime: 0.9
        )
    }

    private func smooth(current: Float, target: Float, dt: Float, attackTime: Float, releaseTime: Float) -> Float {
        let time = target > current ? attackTime : releaseTime
        let alpha = 1 - exp(-dt / max(time, 0.001))
        return current + (target - current) * alpha
    }

    private func shouldRefreshText() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastTextRefresh) >= 0.12 else { return false }
        lastTextRefresh = now
        return true
    }

    private func updateBars(animated: Bool) {
        guard volumeBarContainer.bounds.width > 0, audioBarContainer.bounds.width > 0 else { return }

        let volumeFraction = CGFloat(max(0, min(100, displayedVolume)) / 100)
        let audioFraction = CGFloat(displayedAudioFraction)

        let volumeWidth = max(4, (volumeBarContainer.bounds.width - 2) * volumeFraction)
        let audioWidth = max(4, (audioBarContainer.bounds.width - 2) * audioFraction)
        let scaleWidth = max(0, scaleFillWidth())

        let volumeFrame = NSRect(x: 1, y: 1, width: volumeWidth, height: volumeBarContainer.bounds.height - 2)
        let audioFrame = NSRect(x: 1, y: 1, width: audioWidth, height: audioBarContainer.bounds.height - 2)
        let scaleFrame = NSRect(x: 1, y: 1, width: scaleWidth, height: scaleTrack.bounds.height - 2)
        let markerFrame = currentMarkerFrame()

        let updates = {
            self.volumeBar.frame = volumeFrame
            self.audioBar.frame = audioFrame
            self.scaleFill.frame = scaleFrame
            self.currentMarker.frame = markerFrame
            self.currentMarker.isHidden = self.currentDBSPL == nil
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                updates()
            }
        } else {
            updates()
        }
    }

    private func scaleFillWidth() -> CGFloat {
        guard let db = currentDBSPL else { return 0 }
        let clamped = max(50, min(117, db))
        return (scaleTrack.bounds.width - 2) * CGFloat((clamped - 50) / 67)
    }

    private func currentMarkerFrame() -> NSRect {
        guard let db = currentDBSPL else { return .zero }
        let x = scaleX(for: db, in: scaleContainer.bounds)
        return NSRect(x: x - 1, y: 26, width: 2, height: 18)
    }

    private func scaleX(for db: Float, in bounds: NSRect) -> CGFloat {
        let clamped = max(50, min(117, db))
        let fraction = CGFloat((clamped - 50) / 67)
        return 10 + (bounds.width - 20) * fraction
    }

    private func detailText(for spl: Float) -> String {
        switch spl {
        case ..<70:  return "可持续聆听"
        case ..<80:  return "每天不超过 8 小时"
        case ..<85:  return "每天不超过 2 小时"
        case ..<90:  return "每天不超过 45 分钟"
        case ..<100: return "每天不超过 10 分钟"
        default:     return "立即降低音量"
        }
    }

    private func formatDBFS(_ prefix: String, _ value: Float) -> String {
        guard value > -95 else { return "\(prefix) -- dBFS" }
        return String(format: "\(prefix) %.0f dBFS", value)
    }

    private func softenedColor(_ color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        return NSColor(
            red: min(1, rgb.redComponent * 0.7 + 0.22),
            green: min(1, rgb.greenComponent * 0.7 + 0.22),
            blue: min(1, rgb.blueComponent * 0.7 + 0.22),
            alpha: 0.78
        )
    }

    private func profileDescription(_ profile: HeadphoneModel) -> String {
        let marker = profile.isEstimatedProfile ? "估算" : "标称"
        return String(
            format: "%@ · %.0f dB/V · %.0f Ω · %@",
            profile.name,
            profile.sensitivityDBV,
            profile.impedance,
            marker
        )
    }

    private func makeBarContainer(heightRadius: CGFloat) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.cornerRadius = heightRadius
        container.layer?.backgroundColor = NSColor(white: 0.28, alpha: 0.32).cgColor
        return container
    }

    private func makeBar(color: NSColor, radius: CGFloat) -> NSView {
        let bar = NSView(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.cornerRadius = radius
        bar.layer?.backgroundColor = color.cgColor
        return bar
    }

    private func makeMarker(color: NSColor) -> NSView {
        let marker = NSView(frame: .zero)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1
        marker.layer?.backgroundColor = color.cgColor
        return marker
    }
}

// MARK: - Helper
@MainActor
func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = NSFont.systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.backgroundColor = .clear
    label.isBezeled = false
    label.isEditable = false
    label.isSelectable = false
    label.lineBreakMode = .byTruncatingTail
    return label
}
