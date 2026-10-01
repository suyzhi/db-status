import CoreAudio
import Foundation

/// IEC 61672 A 计权：三节双二阶 IIR（双线性变换），在 1 kHz 归一化为 0 dB。
struct BiquadCoefficients: Sendable {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    static func bilinear(
        sampleRate: Double,
        numerator: (Double, Double, Double),
        denominator: (Double, Double, Double)
    ) -> BiquadCoefficients {
        let c = 2 * sampleRate
        let c2 = c * c
        let (b2s, b1s, b0s) = numerator
        let (a2s, a1s, a0s) = denominator
        let b0 = b2s * c2 + b1s * c + b0s
        let b1 = -2 * b2s * c2 + 2 * b0s
        let b2 = b2s * c2 - b1s * c + b0s
        let a0 = a2s * c2 + a1s * c + a0s
        let a1 = -2 * a2s * c2 + 2 * a0s
        let a2 = a2s * c2 - a1s * c + a0s
        return BiquadCoefficients(
            b0: b0 / a0,
            b1: b1 / a0,
            b2: b2 / a0,
            a1: a1 / a0,
            a2: a2 / a0
        )
    }

    func magnitude(frequency: Double, sampleRate: Double) -> Double {
        let omega = -2 * Double.pi * frequency / sampleRate
        let z1 = Complex(cos(omega), sin(omega))
        let z2 = z1 * z1
        let numerator = Complex(b0, 0) + z1 * b1 + z2 * b2
        let denominator = Complex(1, 0) + z1 * a1 + z2 * a2
        return (numerator / denominator).magnitude
    }
}

private struct BiquadState {
    let coefficients: BiquadCoefficients
    var z1 = 0.0
    var z2 = 0.0

    mutating func process(_ input: Double) -> Double {
        let output = coefficients.b0 * input + z1
        z1 = coefficients.b1 * input - coefficients.a1 * output + z2
        z2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }
}

private struct ChannelAWeightingFilter {
    var sections: [BiquadState]
    let gain: Double

    mutating func process(_ input: Double) -> Double {
        var output = input
        for index in sections.indices {
            output = sections[index].process(output)
        }
        return output * gain
    }
}

final class AWeightingMeter {
    let sampleRate: Double
    private let coefficients: [BiquadCoefficients]
    private let normalizationGain: Double
    private var filters: [ChannelAWeightingFilter]

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        let sectionCoefficients = Self.makeCoefficients(sampleRate: sampleRate)
        coefficients = sectionCoefficients
        let magnitudeAt1K = sectionCoefficients.reduce(1.0) {
            $0 * $1.magnitude(frequency: 1_000, sampleRate: sampleRate)
        }
        let gain = magnitudeAt1K > 0 ? 1 / magnitudeAt1K : 1
        normalizationGain = gain
        filters = (0..<max(1, channelCount)).map { _ in
            ChannelAWeightingFilter(
                sections: sectionCoefficients.map { BiquadState(coefficients: $0) },
                gain: gain
            )
        }
    }

    func reset() {
        filters = filters.map { _ in
            ChannelAWeightingFilter(
                sections: coefficients.map { BiquadState(coefficients: $0) },
                gain: normalizationGain
            )
        }
    }

    func frequencyResponseDB(at frequency: Double) -> Double {
        let magnitude = coefficients.reduce(normalizationGain) {
            $0 * $1.magnitude(frequency: frequency, sampleRate: sampleRate)
        }
        return 20 * log10(max(magnitude, .leastNonzeroMagnitude))
    }

    /// 单声道样本的 A 加权 RMS（线性值）。用于校准时的离线测量，会先丢弃
    /// 开头的滤波器建立段；调用后滤波器状态被重置。
    func rms<Samples: Collection>(of samples: Samples, settleSeconds: Double = 0.2) -> Double
    where Samples.Element == Float {
        reset()
        let skip = min(samples.count / 4, Int(sampleRate * settleSeconds))
        var sumSquares = 0.0
        var counted = 0
        for (index, sample) in samples.enumerated() {
            let weighted = filters[0].process(Double(sample))
            guard index >= skip else { continue }
            sumSquares += weighted * weighted
            counted += 1
        }
        reset()
        return counted > 0 ? sqrt(sumSquares / Double(counted)) : 0
    }

    /// 一个回调块的 A 加权 RMS（所有声道按能量平均）、未加权采样峰值和每声道帧数。
    func measure(
        _ audioBufferList: UnsafePointer<AudioBufferList>
    ) -> (rms: Float, peak: Float, frames: Int)? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: audioBufferList)
        )
        var sumSquares = 0.0
        var peak: Float = 0
        var sampleCount = 0
        var channelOffset = 0
        var layoutInvalid = false

        // 走 UnsafeMutableBufferPointer，避免实时线程上逐样本的数组边界检查。
        filters.withUnsafeMutableBufferPointer { filterBuffer in
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let channelCount = max(1, Int(buffer.mNumberChannels))
                let frameCount = count / channelCount
                guard frameCount > 0,
                      channelOffset + channelCount <= filterBuffer.count else {
                    layoutInvalid = true
                    return
                }
                let samples = data.bindMemory(to: Float.self, capacity: count)

                for frame in 0..<frameCount {
                    let base = frame * channelCount
                    for channel in 0..<channelCount {
                        let sample = samples[base + channel]
                        peak = max(peak, abs(sample))
                        let weighted = filterBuffer[channelOffset + channel].process(Double(sample))
                        sumSquares += weighted * weighted
                    }
                }
                sampleCount += frameCount * channelCount
                channelOffset += channelCount
            }
        }

        guard !layoutInvalid, sampleCount > 0, channelOffset > 0 else { return nil }
        return (
            rms: min(max(Float(sqrt(sumSquares / Double(sampleCount))), 0), 1),
            peak: min(max(peak, 0), 1),
            frames: sampleCount / channelOffset
        )
    }

    private static func makeCoefficients(sampleRate: Double) -> [BiquadCoefficients] {
        let w1 = 2 * Double.pi * 20.598997
        let w2 = 2 * Double.pi * 107.65265
        let w3 = 2 * Double.pi * 737.86223
        let w4 = 2 * Double.pi * 12_194.217
        return [
            .bilinear(
                sampleRate: sampleRate,
                numerator: (1, 0, 0),
                denominator: (1, 2 * w1, w1 * w1)
            ),
            .bilinear(
                sampleRate: sampleRate,
                numerator: (0, 1, 0),
                denominator: (1, w2 + w3, w2 * w3)
            ),
            .bilinear(
                sampleRate: sampleRate,
                numerator: (0, 1, 0),
                denominator: (1, 2 * w4, w4 * w4)
            )
        ]
    }
}

private struct Complex {
    let real: Double
    let imaginary: Double

    init(_ real: Double, _ imaginary: Double) {
        self.real = real
        self.imaginary = imaginary
    }

    var magnitude: Double { hypot(real, imaginary) }

    static func +(lhs: Complex, rhs: Complex) -> Complex {
        Complex(lhs.real + rhs.real, lhs.imaginary + rhs.imaginary)
    }

    static func *(lhs: Complex, rhs: Complex) -> Complex {
        Complex(
            lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func *(lhs: Complex, rhs: Double) -> Complex {
        Complex(lhs.real * rhs, lhs.imaginary * rhs)
    }

    static func /(lhs: Complex, rhs: Complex) -> Complex {
        let denominator = rhs.real * rhs.real + rhs.imaginary * rhs.imaginary
        return Complex(
            (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }
}
