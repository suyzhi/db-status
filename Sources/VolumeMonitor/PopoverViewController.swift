import AppKit
import Foundation

// MARK: - Headphone Model
struct HeadphoneModel {
    let name: String
    let sensitivityDBV: Float
    let impedance: Float
}

let chu2 = HeadphoneModel(name: "水月雨 竹 2", sensitivityDBV: 117, impedance: 28)

// MARK: - Volume Estimation
let macMaxOutputVRMS: Float = 1.0
let maxAttenuation: Float = 65
let curveExponent: Float = 1.6

func volumeToVoltage(_ volume: Float) -> Float {
    guard volume > 0 else { return 0 }
    return macMaxOutputVRMS * pow(10, -maxAttenuation * pow(1 - volume/100, curveExponent) / 20.0)
}

func estimateDBSPL(volume: Float) -> (dbSPL: Float, attenuationDB: Float) {
    let v = volumeToVoltage(volume)
    let attenDB: Float = volume > 0 ? 20 * log10(v / macMaxOutputVRMS) : -.infinity
    return (chu2.sensitivityDBV + attenDB, attenDB)
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
    // UI
    private var titleLabel: NSTextField!
    private var statusDot: NSView!
    private var volumeNumberLabel: NSTextField!
    private var volumeBar: NSView!
    private var barContainer: NSView!
    private var dbSPLLabel: NSTextField!
    private var dbUnitLabel: NSTextField!
    private var safetyLabel: NSTextField!
    private var safetyEmojiLabel: NSTextField!
    private var safetyDetailLabel: NSTextField!
    private var hpInfoLabel: NSTextField!
    private var separatorLine: NSView!
    private var scaleContainer: NSView!
    
    // Stored scale subviews
    private var scaleBars: [NSView] = []
    private var scalePctLabels: [NSTextField] = []
    private var scaleDBLabels: [NSTextField] = []
    private var scaleTitle: NSTextField!
    private var threshLabel: NSTextField!
    
    // Weak references to section title labels
    private var volTitleLabel: NSTextField!
    private var dbTitleLabel: NSTextField!
    
    // Data
    private var currentVolume: Float = 0
    private var currentDBSPL: Float = 0
    
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 290))
        self.view = v
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
        
        // Frosted glass
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        
        // Dark overlay
        let overlay = NSView(frame: root.bounds)
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.35).cgColor
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay, positioned: .above, relativeTo: blur)
        
        // ── Title ──
        titleLabel = makeLabel("🎧 音量监测", size: 14, weight: .semibold, color: .white)
        root.addSubview(titleLabel)
        
        statusDot = NSView(frame: .zero)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        root.addSubview(statusDot)
        
        // ── Volume Section ──
        volTitleLabel = makeLabel("🔊 系统音量", size: 11, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        root.addSubview(volTitleLabel)
        
        volumeNumberLabel = makeLabel("0", size: 30, weight: .bold, color: NSColor(red: 0.6, green: 0.85, blue: 1.0, alpha: 1))
        volumeNumberLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        root.addSubview(volumeNumberLabel)
        
        // Volume bar
        barContainer = NSView(frame: .zero)
        barContainer.wantsLayer = true
        barContainer.layer?.cornerRadius = 4
        barContainer.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.3).cgColor
        root.addSubview(barContainer)
        
        volumeBar = NSView(frame: .zero)
        volumeBar.wantsLayer = true
        volumeBar.layer?.cornerRadius = 3
        volumeBar.layer?.backgroundColor = NSColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 0.7).cgColor
        barContainer.addSubview(volumeBar)
        
        // ── dB SPL Section ──
        dbTitleLabel = makeLabel("🎚 估算声压", size: 11, weight: .medium, color: NSColor(white: 0.75, alpha: 1))
        root.addSubview(dbTitleLabel)
        
        dbSPLLabel = makeLabel("0.0", size: 28, weight: .bold, color: .white)
        dbSPLLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        root.addSubview(dbSPLLabel)
        
        dbUnitLabel = makeLabel("dB SPL", size: 11, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
        root.addSubview(dbUnitLabel)
        
        safetyEmojiLabel = makeLabel("🟢", size: 16, weight: .regular, color: .white)
        root.addSubview(safetyEmojiLabel)
        
        safetyLabel = makeLabel("安全", size: 13, weight: .semibold, color: .white)
        root.addSubview(safetyLabel)
        
        safetyDetailLabel = makeLabel("可持续聆听", size: 10, weight: .regular, color: NSColor(white: 0.55, alpha: 1))
        root.addSubview(safetyDetailLabel)
        
        // ── Separator ──
        separatorLine = NSView(frame: .zero)
        separatorLine.wantsLayer = true
        separatorLine.layer?.backgroundColor = NSColor(white: 0.3, alpha: 0.25).cgColor
        root.addSubview(separatorLine)
        
        // ── Headphone Info ──
        hpInfoLabel = makeLabel("🎯 \(chu2.name) · 117 dB/V · 28 Ω", size: 10, weight: .regular, color: NSColor(white: 0.45, alpha: 1))
        root.addSubview(hpInfoLabel)
        
        // ── Reference Scale ──
        scaleContainer = NSView(frame: .zero)
        scaleContainer.wantsLayer = true
        scaleContainer.layer?.cornerRadius = 8
        scaleContainer.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.5).cgColor
        scaleContainer.layer?.borderColor = NSColor(white: 0.2, alpha: 0.3).cgColor
        scaleContainer.layer?.borderWidth = 0.5
        root.addSubview(scaleContainer)
        
        buildScale()
    }
    
    // MARK: - Layout
    private func relayout() {
        let w = view.bounds.width
        
        titleLabel.frame = NSRect(x: 16, y: 256, width: 180, height: 22)
        statusDot.frame = NSRect(x: w - 22, y: 261, width: 6, height: 6)
        
        // Volume section
        let volSectionTop: CGFloat = 232
        volTitleLabel.frame = NSRect(x: 16, y: volSectionTop, width: 120, height: 18)
        volumeNumberLabel.frame = NSRect(x: 16, y: volSectionTop - 28, width: 80, height: 36)
        
        // Volume bar
        barContainer.frame = NSRect(x: 16, y: volSectionTop - 44, width: w - 32, height: 10)
        updateVolumeBar()
        
        // dB SPL section
        let dbSectionTop: CGFloat = volSectionTop - 64
        dbTitleLabel.frame = NSRect(x: 16, y: dbSectionTop, width: 120, height: 18)
        dbSPLLabel.frame = NSRect(x: 16, y: dbSectionTop - 30, width: 120, height: 34)
        dbUnitLabel.frame = NSRect(x: dbSPLLabel.frame.maxX - 4, y: dbSectionTop - 22, width: 60, height: 16)
        
        safetyEmojiLabel.frame = NSRect(x: 16, y: dbSectionTop - 56, width: 24, height: 20)
        safetyLabel.frame = NSRect(x: 40, y: dbSectionTop - 56, width: 100, height: 20)
        safetyDetailLabel.frame = NSRect(x: 40, y: dbSectionTop - 72, width: 180, height: 14)
        
        // Separator
        let sepY: CGFloat = dbSectionTop - 84
        separatorLine.frame = NSRect(x: 16, y: sepY, width: w - 32, height: 1)
        
        // Headphone info
        hpInfoLabel.frame = NSRect(x: 16, y: sepY - 18, width: w - 32, height: 14)
        
        // Reference scale
        let scaleTop = sepY - 30
        scaleContainer.frame = NSRect(x: 16, y: 12, width: w - 32, height: scaleTop - 16)
        layoutScale()
    }
    
    private func updateVolumeBar() {
        let w = barContainer.bounds.width
        guard w > 0 else { return }
        let fw = max(4, w * CGFloat(currentVolume / 100.0))
        volumeBar.frame = NSRect(x: 1, y: 1, width: fw - 2, height: barContainer.bounds.height - 2)
    }
    
    // MARK: - Scale
    private func buildScale() {
        scaleTitle = makeLabel("音量参考 (dB SPL)", size: 9, weight: .medium, color: NSColor(white: 0.5, alpha: 1))
        scaleContainer.addSubview(scaleTitle)
        
        let refPoints: [(vol: Int, db: Float)] = [
            (10, 62.1), (30, 80.3), (50, 95.6), (70, 107.5), (100, 117.0)
        ]
        
        for (i, rp) in refPoints.enumerated() {
            let bar = NSView(frame: .zero)
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 2
            let frac = CGFloat(rp.vol) / 100.0
            bar.layer?.backgroundColor = NSColor(
                red: 0.35 + frac * 0.5,
                green: 0.7 - frac * 0.4,
                blue: 0.9 - frac * 0.5,
                alpha: 0.6
            ).cgColor
            scaleContainer.addSubview(bar)
            scaleBars.append(bar)
            
            let lbl = makeLabel("\(rp.vol)%", size: 8, weight: .regular, color: NSColor(white: 0.5, alpha: 1))
            scaleContainer.addSubview(lbl)
            scalePctLabels.append(lbl)
            
            let dblbl = makeLabel(String(format: "%.0f", rp.db), size: 8, weight: .bold, color: NSColor(white: 0.65, alpha: 1))
            scaleContainer.addSubview(dblbl)
            scaleDBLabels.append(dblbl)
        }
        
        threshLabel = makeLabel("⚠ 85 dB", size: 7, weight: .medium, color: NSColor.orange)
        scaleContainer.addSubview(threshLabel)
    }
    
    private func layoutScale() {
        let c = scaleContainer.bounds
        guard c.width > 0, c.height > 0 else { return }
        
        scaleTitle.frame = NSRect(x: 8, y: c.height - 16, width: c.width - 16, height: 12)
        
        let listY: CGFloat = 8
        let listH: CGFloat = c.height - 26
        let itemH: CGFloat = 14
        let gap: CGFloat = 4
        
        let itemW = c.width - 16
        let refPoints: [(vol: Int, db: Float)] = [
            (10, 62.1), (30, 80.3), (50, 95.6), (70, 107.5), (100, 117.0)
        ]
        
        for (i, rp) in refPoints.enumerated() {
            let y = listY + CGFloat(i) * (itemH + gap)
            let frac = CGFloat(rp.vol) / 100.0
            let barW = max(8, frac * itemW * 0.5)
            
            guard i < scaleBars.count, i < scalePctLabels.count, i < scaleDBLabels.count else { break }
            
            scaleBars[i].frame = NSRect(x: 8, y: y + 2, width: barW, height: 10)
            scalePctLabels[i].frame = NSRect(x: 8 + barW + 4, y: y + 1, width: 30, height: 12)
            scaleDBLabels[i].frame = NSRect(x: 8 + barW + 34, y: y + 1, width: 40, height: 12)
        }
        
        threshLabel.frame = NSRect(x: 8, y: 0, width: c.width - 16, height: 10)
        threshLabel.isHidden = listH < 50
    }
    
    // MARK: - Data Refresh
    func refreshVolume() {
        loadViewIfNeeded()
        
        guard let vol = getSystemVolume() else { return }
        currentVolume = vol
        let (spl, _) = estimateDBSPL(volume: vol)
        currentDBSPL = spl
        let safety = safetyInfo(spl)
        
        volumeNumberLabel.stringValue = "\(Int(vol))"
        dbSPLLabel.stringValue = String(format: "%.1f", spl)
        
        // Update bar
        if barContainer.bounds.width > 0 {
            updateVolumeBar()
        }
        
        // Safety
        safetyEmojiLabel.stringValue = safety.emoji
        safetyLabel.stringValue = safety.label
        safetyLabel.textColor = safety.color
        
        // Detail text
        switch spl {
        case ..<70:  safetyDetailLabel.stringValue = "可持续聆听"
        case ..<80:  safetyDetailLabel.stringValue = "每天不超过 8 小时"
        case ..<85:  safetyDetailLabel.stringValue = "每天不超过 2 小时"
        case ..<90:  safetyDetailLabel.stringValue = "每天不超过 45 分钟"
        case ..<100: safetyDetailLabel.stringValue = "每天不超过 10 分钟"
        default:     safetyDetailLabel.stringValue = "立即降低音量！"
        }
        
        // Status dot color
        statusDot.layer?.backgroundColor = safety.color.cgColor
        
        // Bar color follows safety
        volumeBar.layer?.backgroundColor = NSColor(
            red: safety.color.redComponent * 0.7 + 0.2,
            green: safety.color.greenComponent * 0.7 + 0.2,
            blue: safety.color.blueComponent * 0.7 + 0.2,
            alpha: 0.7
        ).cgColor
    }
    
    private func getSystemVolume() -> Float? {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", "output volume of (get volume settings)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let vol = Float(str) else { return nil }
        return vol
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
    return label
}
