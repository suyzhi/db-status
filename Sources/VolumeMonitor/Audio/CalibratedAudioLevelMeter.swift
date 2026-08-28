import Accelerate
import CoreAudio
import Foundation

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
    private var pendingSamples: [[Float]]
    private var latestChannelRMS: [Float]
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
        latestChannelRMS = Array(repeating: 0, count: channelCount)

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
    }

    func reset() {
        pendingSamples = Array(repeating: [], count: channelCount)
        latestChannelRMS = Array(repeating: 0, count: channelCount)
        processedWindowCount = 0
    }

    func measure(_ audioBufferList: UnsafePointer<AudioBufferList>) -> (rms: Float, peak: Float)? {
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
            for frame in 0..<frameCount {
                for channel in 0..<channelsInBuffer {
                    let value = samples[frame * channelsInBuffer + channel]
                    peak = max(peak, abs(value))
                    pendingSamples[channelOffset + channel].append(value)
                }
            }
            channelOffset += channelsInBuffer
        }
        guard channelOffset == channelCount else { return nil }

        while pendingSamples.allSatisfy({ $0.count >= fftSize }) {
            for channel in 0..<channelCount {
                latestChannelRMS[channel] = analyzeWindow(
                    Array(pendingSamples[channel].prefix(fftSize))
                )
                pendingSamples[channel].removeFirst(hopSize)
            }
            processedWindowCount += 1
        }

        guard processedWindowCount > 0, let loudest = latestChannelRMS.max(), loudest.isFinite else {
            return nil
        }
        return (rms: min(max(loudest, 0), 1), peak: min(max(peak, 0), 1))
    }

    private func analyzeWindow(_ samples: [Float]) -> Float {
        var real = [Float](repeating: 0, count: fftSize)
        var imaginary = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &real, 1, vDSP_Length(fftSize))

        var windowedSumSquares: Float = 0
        vDSP_svesq(real, 1, &windowedSumSquares, vDSP_Length(fftSize))
        guard windowedSumSquares > 0, windowEnergy > 0 else { return 0 }

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                vDSP_fft_zip(fftSetup, &split, 1, log2FFTSize, FFTDirection(FFT_FORWARD))
            }
        }

        var rawTotal = 0.0
        var rawWeighted = 0.0
        for bin in 0...fftSize / 2 {
            let factor = (bin == 0 || bin == fftSize / 2) ? 1.0 : 2.0
            let power = (Double(real[bin]) * Double(real[bin])
                + Double(imaginary[bin]) * Double(imaginary[bin])) * factor
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
