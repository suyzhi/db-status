import Accelerate
import CoreAudio
import Foundation

/// 基于 FFT 的校准后电平表。
///
/// 该对象只在 CoreAudio 采集回调所属的串行队列上使用，因此内部 scratch buffer
/// 可以安全复用：每个分析窗口都不再分配新数组，也不再把样本数组整体前移。
final class CalibratedAudioLevelMeter {
    let sampleRate: Double
    let channelCount: Int
    let fftSize: Int
    let hopSize: Int

    private let log2FFTSize: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let windowEnergy: Double
    private let binPowerCorrections: [Double]

    /// 每个声道的待处理样本。用 pendingStart 记录读取位置而不是 removeFirst，
    /// 每轮回调结束后才压缩一次，避免每个窗口都做一次 O(n) 搬移。
    private var pendingSamples: [[Float]]
    private var pendingStart: [Int]

    private let realScratch: UnsafeMutablePointer<Float>
    private let imaginaryScratch: UnsafeMutablePointer<Float>

    /// 最近一个分析窗口的均方（各声道按能量平均）。
    private var latestMeanSquare = 0.0
    private(set) var processedWindowCount = 0

    init?(
        sampleRate: Double,
        channelCount: Int,
        frequencyPoints: [FrequencyCalibrationPoint],
        fftSize: Int = 4_096
    ) {
        guard sampleRate > 0,
              channelCount > 0,
              fftSize >= 1_024,
              fftSize.nonzeroBitCount == 1,
              let response = FrequencyResponseInterpolator(points: frequencyPoints) else {
            return nil
        }
        let log2Size = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return nil }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.fftSize = fftSize
        hopSize = fftSize / 2
        log2FFTSize = log2Size
        fftSetup = setup
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = hann
        windowEnergy = hann.reduce(0) { $0 + Double($1 * $1) }
        pendingSamples = Array(repeating: [], count: channelCount)
        pendingStart = Array(repeating: 0, count: channelCount)
        realScratch = .allocate(capacity: fftSize)
        imaginaryScratch = .allocate(capacity: fftSize)
        realScratch.initialize(repeating: 0, count: fftSize)
        imaginaryScratch.initialize(repeating: 0, count: fftSize)

        let aWeighting = AWeightingMeter(sampleRate: sampleRate, channelCount: 1)
        binPowerCorrections = (0...fftSize / 2).map { bin in
            let frequency = Double(bin) * sampleRate / Double(fftSize)
            guard frequency > 0 else { return 0 }
            let totalDB = aWeighting.frequencyResponseDB(at: frequency)
                + response.responseDB(at: frequency)
            return totalDB.isFinite ? pow(10, totalDB / 10) : 0
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realScratch.deallocate()
        imaginaryScratch.deallocate()
    }

    func reset() {
        for channel in 0..<channelCount {
            pendingSamples[channel].removeAll(keepingCapacity: true)
            pendingStart[channel] = 0
        }
        latestMeanSquare = 0
        processedWindowCount = 0
    }

    func measure(_ audioBufferList: UnsafePointer<AudioBufferList>) -> (rms: Float, peak: Float)? {
        measure(audioBufferList) { _, _ in }
    }

    /// 每完成一个分析窗口回调一次 `onWindow(均方, 该窗口代表的帧数)`，供能量积分；
    /// 返回最近窗口的 RMS 与本块峰值。尚未攒够第一个窗口时返回 nil。
    func measure(
        _ audioBufferList: UnsafePointer<AudioBufferList>,
        onWindow: (Double, Int) -> Void
    ) -> (rms: Float, peak: Float)? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        var channelOffset = 0
        var peak: Float = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let valueCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let channelsInBuffer = max(1, Int(buffer.mNumberChannels))
            let frameCount = valueCount / channelsInBuffer
            guard frameCount > 0, channelOffset + channelsInBuffer <= channelCount else { return nil }
            let samples = data.bindMemory(to: Float.self, capacity: valueCount)

            if channelsInBuffer == 1 {
                // 非交错（CoreAudio tap 的常见布局）可以整段追加，省掉逐样本下标。
                let source = UnsafeBufferPointer(start: samples, count: frameCount)
                for value in source { peak = max(peak, abs(value)) }
                pendingSamples[channelOffset].append(contentsOf: source)
            } else {
                for frame in 0..<frameCount {
                    let base = frame * channelsInBuffer
                    for channel in 0..<channelsInBuffer {
                        let value = samples[base + channel]
                        peak = max(peak, abs(value))
                        pendingSamples[channelOffset + channel].append(value)
                    }
                }
            }
            channelOffset += channelsInBuffer
        }
        guard channelOffset == channelCount else { return nil }

        var processedAnyWindow = false
        while pendingSamples.indices.allSatisfy({
            pendingSamples[$0].count - pendingStart[$0] >= fftSize
        }) {
            // 左右声道按能量平均：普通音乐左右基本一致，取最大值会让偏声道内容虚高。
            var powerSum = 0.0
            for channel in 0..<channelCount {
                let rms = Double(analyzeWindow(
                    pendingSamples[channel],
                    start: pendingStart[channel]
                ))
                powerSum += rms * rms
                pendingStart[channel] += hopSize
            }
            latestMeanSquare = powerSum / Double(channelCount)
            onWindow(latestMeanSquare, hopSize)
            processedWindowCount += 1
            processedAnyWindow = true
        }
        if processedAnyWindow { compactPendingSamples() }

        guard processedWindowCount > 0, latestMeanSquare.isFinite else { return nil }
        let rms = Float(sqrt(max(0, latestMeanSquare)))
        return (rms: min(max(rms, 0), 1), peak: min(max(peak, 0), 1))
    }

    private func compactPendingSamples() {
        for channel in 0..<channelCount {
            let start = pendingStart[channel]
            guard start > 0 else { continue }
            pendingSamples[channel].removeFirst(start)
            pendingStart[channel] = 0
        }
    }

    private func analyzeWindow(_ buffer: [Float], start: Int) -> Float {
        buffer.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            vDSP_vmul(base + start, 1, window, 1, realScratch, 1, vDSP_Length(fftSize))
        }
        vDSP_vclr(imaginaryScratch, 1, vDSP_Length(fftSize))

        var windowedSumSquares: Float = 0
        vDSP_svesq(realScratch, 1, &windowedSumSquares, vDSP_Length(fftSize))
        guard windowedSumSquares > 0, windowEnergy > 0 else { return 0 }

        var split = DSPSplitComplex(realp: realScratch, imagp: imaginaryScratch)
        vDSP_fft_zip(fftSetup, &split, 1, log2FFTSize, FFTDirection(FFT_FORWARD))

        var rawTotal = 0.0
        var rawWeighted = 0.0
        for bin in 0...fftSize / 2 {
            let factor = (bin == 0 || bin == fftSize / 2) ? 1.0 : 2.0
            let real = Double(realScratch[bin])
            let imaginary = Double(imaginaryScratch[bin])
            let power = (real * real + imaginary * imaginary) * factor
            rawTotal += power
            rawWeighted += power * binPowerCorrections[bin]
        }
        guard rawTotal > 0, rawWeighted.isFinite else { return 0 }

        // Normalize through Parseval using the actual windowed time-domain
        // energy, avoiding dependence on an FFT implementation scale factor.
        let unweightedPower = Double(windowedSumSquares) / windowEnergy
        let correctedPower = unweightedPower * rawWeighted / rawTotal
        return Float(sqrt(max(0, correctedPower)))
    }
}
