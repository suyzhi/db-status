import Foundation

enum CalibrationMeasurementMath {
    static func normalizedAcousticLevel(
        microphoneLevelDBFS: Double,
        signalRMSDBFS: Double
    ) -> Double {
        microphoneLevelDBFS - signalRMSDBFS
    }

    static func relativeDB(
        microphoneLevelDBFS: Double,
        signalRMSDBFS: Double,
        referenceMicrophoneLevelDBFS: Double,
        referenceSignalRMSDBFS: Double
    ) -> Double {
        normalizedAcousticLevel(
            microphoneLevelDBFS: microphoneLevelDBFS,
            signalRMSDBFS: signalRMSDBFS
        ) - normalizedAcousticLevel(
            microphoneLevelDBFS: referenceMicrophoneLevelDBFS,
            signalRMSDBFS: referenceSignalRMSDBFS
        )
    }
}

struct CalibrationProgress: Sendable, Equatable {
    let message: String
    let fraction: Double
    let retry: Int
}

struct FrequencySweepResult: Sendable, Equatable {
    let points: [FrequencyCalibrationPoint]
    let minimumSNRDB: Double
    let testSignalRMSDBFS: Double
    let skippedFrequencies: [Double]

    init(
        points: [FrequencyCalibrationPoint],
        minimumSNRDB: Double,
        testSignalRMSDBFS: Double,
        skippedFrequencies: [Double] = []
    ) {
        self.points = points
        self.minimumSNRDB = minimumSNRDB
        self.testSignalRMSDBFS = testSignalRMSDBFS
        self.skippedFrequencies = skippedFrequencies
    }
}

struct VolumeSweepResult: Sendable, Equatable {
    let points: [VolumeCalibrationPoint]
    let minimumSNRDB: Double
    let referenceNormalizedLevelDBFS: Double
    let testSignalRMSDBFS: Double
}

struct RelativeValidationResult: Sendable, Equatable {
    let systemVolume: Float
    let predictedRelativeDB: Double
    let measuredRelativeDB: Double
    let absoluteErrorDB: Double
}

enum CalibrationMeasurementError: LocalizedError {
    case outputDeviceChanged
    case inputDeviceChanged
    case inputChainChanged
    case volumeUnavailable(Float)
    case noMeasurement(Double)
    case clipping(Double)
    case insufficientSNR(frequency: Double, snr: Double)
    case unstable(frequency: Double, stability: Double)
    case volumeCurveInconsistent(volume: Float, dropDB: Double)

    var errorDescription: String? {
        switch self {
        case .outputDeviceChanged: "输出设备在校准过程中发生变化，测试已停止"
        case .inputDeviceChanged: "校准麦克风已断开或发生变化，测试已停止"
        case .inputChainChanged: "麦克风输入链在校准过程中发生变化，本次校准已停止，请重新开始。"
        case .volumeUnavailable(let volume): "请把系统音量调到 \(Int(volume * 100))% 后重试"
        case .noMeasurement(let frequency): "\(Int(frequency)) Hz 没有获得足够的麦克风数据"
        case .clipping(let frequency): "\(Int(frequency)) Hz 测量时麦克风输入接近削波"
        case .insufficientSNR(let frequency, let snr):
            "\(Int(frequency)) Hz 信噪比不足（\(String(format: "%.1f", snr)) dB）。已自动提高到封顶电平重试；仍不足时请重点检查：① 环境噪声——关闭风扇/空调/其它播放（开放式耳罩双向透声，噪声最容易混入低频测量）；② 探头位置——EM258 尽量贴近耳机单元中心并保持稳定（开放式大耳低频对探头位置敏感）；③ 保持耳机和探头不动后点击「仅重测当前阶段」"
        case .unstable(let frequency, let stability):
            "\(Int(frequency)) Hz 测量不稳定（\(String(format: "%.2f", stability)) dB）"
        case .volumeCurveInconsistent(let volume, let dropDB):
            "\(Int(volume * 100))% 音量点的麦克风读数比上一档低了约 \(String(format: "%.1f", dropDB)) dB，物理上不可能（该点可能没有真正以目标音量播放）。请确认：① 被测设备上的系统音量确实依次为 30% → 50% → 70%（不要用遥控器/其它软件误调）；② 耳机与 EM258 位置没有移动；③ 然后重测当前阶段。"
        }
    }
}

@MainActor
final class CalibrationMeasurementEngine {
    typealias ProgressHandler = @MainActor (CalibrationProgress) -> Void

    private let microphone: CalibrationMicrophoneMonitor
    private let toneGenerator: CalibrationToneGenerator
    private let outputMonitor: OutputDeviceMonitor
    private(set) var isRunning = false

    init(
        microphone: CalibrationMicrophoneMonitor,
        toneGenerator: CalibrationToneGenerator,
        outputMonitor: OutputDeviceMonitor
    ) {
        self.microphone = microphone
        self.toneGenerator = toneGenerator
        self.outputMonitor = outputMonitor
    }

    func cancel() {
        toneGenerator.stop()
    }

    func measureFrequencyResponse(
        outputDeviceUID: String,
        testSignalRMSDBFS: Double,
        maxSignalRMSDBFS: Double? = nil,
        allowSkipTopFrequencies: Bool = false,
        progress: @escaping ProgressHandler
    ) async throws -> FrequencySweepResult {
        let originalVolume = outputMonitor.snapshot().volumeScalar
        isRunning = true
        defer {
            toneGenerator.stop()
            if let originalVolume { _ = outputMonitor.setVolumeScalar(originalVolume) }
            isRunning = false
        }
        try await setOrAwaitVolume(0.5, outputDeviceUID: outputDeviceUID, progress: progress)

        var measurements: [(measurement: CalibrationFrequencyMeasurement, signalRMSDBFS: Double)] = []
        var skipped: [Double] = []
        var currentLevel = testSignalRMSDBFS
        for (index, frequency) in CalibrationProfile.requiredFrequenciesHz.enumerated() {
            try Task.checkCancellation()
            try verifyDevices(outputDeviceUID: outputDeviceUID)
            let fraction = Double(index) / Double(CalibrationProfile.requiredFrequenciesHz.count)
            do {
                let result = try await measureWithRetries(
                    frequencyHz: frequency,
                    initialRMSDBFS: currentLevel,
                    maxSignalRMSDBFS: maxSignalRMSDBFS,
                    outputDeviceUID: outputDeviceUID,
                    baseFraction: fraction,
                    progress: progress
                )
                currentLevel = min(currentLevel, result.usedSignalRMSDBFS)
                measurements.append((result.measurement, result.usedSignalRMSDBFS))
            } catch CalibrationMeasurementError.insufficientSNR
                where allowSkipTopFrequencies && frequency >= 8_000 {
                // 8/12 kHz 是开放式大耳最常出现的低频响点；A 加权暴露中该频段贡献很小，
                // 跳过并以最后一个有效点（≤8 kHz）截止是合理兜底。
                skipped.append(frequency)
                progress(CalibrationProgress(
                    message: "\(Int(frequency)) Hz 信噪比不足，已跳过（曲线将在该点上方截止）",
                    fraction: min(0.99, fraction + 0.04),
                    retry: 0
                ))
            }
        }
        if measurements.count < 7 {
            throw CalibrationMeasurementError.noMeasurement(1_000)
        }
        guard let reference = measurements.first(where: {
            abs($0.measurement.frequencyHz - 1_000) < 0.5
        }) else {
            throw CalibrationMeasurementError.noMeasurement(1_000)
        }
        let referenceNormalized = CalibrationMeasurementMath.normalizedAcousticLevel(
            microphoneLevelDBFS: reference.measurement.levelDBFS,
            signalRMSDBFS: reference.signalRMSDBFS
        )
        let points = measurements.map { item in
            FrequencyCalibrationPoint(
                frequencyHz: item.measurement.frequencyHz,
                relativeDB: CalibrationMeasurementMath.normalizedAcousticLevel(
                    microphoneLevelDBFS: item.measurement.levelDBFS,
                    signalRMSDBFS: item.signalRMSDBFS
                ) - referenceNormalized,
                stabilityDB: item.measurement.stabilityDB,
                measuredLevelDBFS: item.measurement.levelDBFS,
                signalRMSDBFS: item.signalRMSDBFS
            )
        }
        let summary = skipped.isEmpty
            ? "9 个频率点测量完成"
            : "\(points.count) 个频率点测量完成（已跳过：\(skipped.map { "\(Int($0)) Hz" }.joined(separator: "、"))；\(Int(points.map(\.frequencyHz).max() ?? 0)) Hz 以上按该点值延伸）"
        progress(CalibrationProgress(message: summary, fraction: 1, retry: 0))
        return FrequencySweepResult(
            points: points,
            minimumSNRDB: measurements.map(\.measurement.snrDB).min() ?? 0,
            testSignalRMSDBFS: currentLevel,
            skippedFrequencies: skipped
        )
    }

    func measureVolumeCurve(
        outputDeviceUID: String,
        testSignalRMSDBFS: Double,
        maxSignalAtVolume: ((Float) -> Double?)? = nil,
        progress: @escaping ProgressHandler
    ) async throws -> VolumeSweepResult {
        let originalVolume = outputMonitor.snapshot().volumeScalar
        isRunning = true
        defer {
            toneGenerator.stop()
            if let originalVolume { _ = outputMonitor.setVolumeScalar(originalVolume) }
            isRunning = false
        }

        var measurements: [(
            volume: Float,
            measurement: CalibrationFrequencyMeasurement,
            signalRMSDBFS: Double
        )] = []
        var currentLevel = testSignalRMSDBFS
        for (index, volume) in CalibrationProfile.requiredVolumes.enumerated() {
            try Task.checkCancellation()
            try verifyDevices(outputDeviceUID: outputDeviceUID)
            progress(CalibrationProgress(
                message: "正在设置系统音量到 \(Int(volume * 100))%",
                fraction: Double(index) / 3,
                retry: 0
            ))
            try await setOrAwaitVolume(volume, outputDeviceUID: outputDeviceUID, progress: progress)
            let result = try await measureWithRetries(
                frequencyHz: 1_000,
                initialRMSDBFS: currentLevel,
                maxSignalRMSDBFS: maxSignalAtVolume?(volume),
                outputDeviceUID: outputDeviceUID,
                baseFraction: Double(index) / 3,
                progress: progress
            )
            currentLevel = min(currentLevel, result.usedSignalRMSDBFS)
            measurements.append((volume, result.measurement, result.usedSignalRMSDBFS))
        }

        // 原始读数一致性校验：系统音量升高，麦克风收到的电平（无论测试音是否
        // 被削波回退）不应出现大幅下降。若后一档比前一档低 12 dB 以上，说明
        // 该点很可能没有真正以目标音量播放（音量被外部改动、输出路由切换等），
        // 拒绝保存，避免生成"数学上自洽但物理上不可能"的音量曲线。
        let sortedMeasurements = measurements.sorted { $0.volume < $1.volume }
        var previousMic: Double?
        for item in sortedMeasurements {
            let mic = item.measurement.levelDBFS
            if let previousMic, mic < previousMic - 12 {
                throw CalibrationMeasurementError.volumeCurveInconsistent(
                    volume: item.volume,
                    dropDB: previousMic - mic
                )
            }
            previousMic = mic
        }

        guard let reference = measurements.first(where: { abs($0.volume - 0.5) < 0.002 }) else {
            throw CalibrationMeasurementError.noMeasurement(1_000)
        }
        let referenceNormalized = CalibrationMeasurementMath.normalizedAcousticLevel(
            microphoneLevelDBFS: reference.measurement.levelDBFS,
            signalRMSDBFS: reference.signalRMSDBFS
        )
        let points = measurements.map { item in
            VolumeCalibrationPoint(
                systemVolume: item.volume,
                relativeDB: CalibrationMeasurementMath.normalizedAcousticLevel(
                    microphoneLevelDBFS: item.measurement.levelDBFS,
                    signalRMSDBFS: item.signalRMSDBFS
                ) - referenceNormalized,
                stabilityDB: item.measurement.stabilityDB,
                measuredLevelDBFS: item.measurement.levelDBFS,
                signalRMSDBFS: item.signalRMSDBFS
            )
        }
        progress(CalibrationProgress(message: "3 个系统音量点测量完成", fraction: 1, retry: 0))
        return VolumeSweepResult(
            points: points,
            minimumSNRDB: measurements.map(\.measurement.snrDB).min() ?? 0,
            referenceNormalizedLevelDBFS: referenceNormalized,
            testSignalRMSDBFS: currentLevel
        )
    }

    func validateVolumeCurve(
        outputDeviceUID: String,
        volumeResult: VolumeSweepResult,
        progress: @escaping ProgressHandler
    ) async throws -> RelativeValidationResult {
        let validationVolume: Float = 0.6
        let originalVolume = outputMonitor.snapshot().volumeScalar
        isRunning = true
        defer {
            toneGenerator.stop()
            if let originalVolume { _ = outputMonitor.setVolumeScalar(originalVolume) }
            isRunning = false
        }
        try verifyDevices(outputDeviceUID: outputDeviceUID)
        try await setOrAwaitVolume(
            validationVolume,
            outputDeviceUID: outputDeviceUID,
            progress: progress
        )
        progress(CalibrationProgress(message: "正在 60% 音量进行独立验证", fraction: 0.2, retry: 0))
        let result = try await measureWithRetries(
            frequencyHz: 1_000,
            initialRMSDBFS: volumeResult.testSignalRMSDBFS,
            outputDeviceUID: outputDeviceUID,
            baseFraction: 0.3,
            progress: progress
        )
        guard let curve = VolumeCalibrationCurve(points: volumeResult.points) else {
            throw CalibrationStoreError.invalidProfile("音量曲线无法插值")
        }
        let predicted = curve.relativeDB(at: validationVolume) - curve.relativeDB(at: 0.5)
        let measured = CalibrationMeasurementMath.normalizedAcousticLevel(
            microphoneLevelDBFS: result.measurement.levelDBFS,
            signalRMSDBFS: result.usedSignalRMSDBFS
        )
            - volumeResult.referenceNormalizedLevelDBFS
        let error = abs(predicted - measured)
        progress(CalibrationProgress(
            message: Self.validationMessage(errorDB: error),
            fraction: 1,
            retry: 0
        ))
        return RelativeValidationResult(
            systemVolume: validationVolume,
            predictedRelativeDB: predicted,
            measuredRelativeDB: measured,
            absoluteErrorDB: error
        )
    }

    private func measureWithRetries(
        frequencyHz: Double,
        initialRMSDBFS: Double,
        maxSignalRMSDBFS: Double? = nil,
        outputDeviceUID: String,
        baseFraction: Double,
        progress: @escaping ProgressHandler
    ) async throws -> (measurement: CalibrationFrequencyMeasurement, usedSignalRMSDBFS: Double) {
        var signalLevel = initialRMSDBFS
        var lastError: Error = CalibrationMeasurementError.noMeasurement(frequencyHz)
        // SNR 不足时直接一步提到封顶电平重测（最多重测 2 次）。
        // 封顶 = 调用方提供的模型上限（按当前音量换算的 90 dBA，权威值）；
        // 未提供时退化为 初始+12 dB。数字电平再钳制在 -6 dBFS 以下
        // （保留正弦峰值余量），且不低于初始电平。削波保护仍会回退。
        let relativeCapDB = 12.0
        let requestedCap = maxSignalRMSDBFS ?? (initialRMSDBFS + relativeCapDB)
        let ceiling = max(initialRMSDBFS, min(requestedCap, -6.0))
        var jumpedToMax = false
        for attempt in 0...2 {
            try Task.checkCancellation()
            let label = attempt == 0 ? "" : "（自动提高到封顶电平重测 \(attempt)/2）"
            progress(CalibrationProgress(
                message: "测量 \(Int(frequencyHz)) Hz\(label)",
                fraction: min(0.99, baseFraction),
                retry: attempt
            ))

            microphone.beginFrequencyMeasurement(frequencyHz)
            try await waitWhileVerifyingDevices(
                milliseconds: 450,
                outputDeviceUID: outputDeviceUID
            )
            let noise = microphone.snapshot.noiseFloorDBFS
            _ = microphone.finishFrequencyMeasurement()

            let attemptSignalLevel = signalLevel
            let toneTask = Task { @MainActor in
                try await toneGenerator.playTone(
                    frequencyHz: frequencyHz,
                    duration: 4.6,
                    rmsDBFS: attemptSignalLevel
                )
            }
            defer { toneTask.cancel() }
            try await waitWhileVerifyingDevices(
                milliseconds: 800,
                outputDeviceUID: outputDeviceUID
            )
            microphone.beginFrequencyMeasurement(frequencyHz)
            try await waitWhileVerifyingDevices(
                milliseconds: 3_100,
                outputDeviceUID: outputDeviceUID
            )
            guard let measurement = microphone.finishFrequencyMeasurement(noiseFloorDBFS: noise) else {
                lastError = CalibrationMeasurementError.noMeasurement(frequencyHz)
                continue
            }
            _ = try? await toneTask.value

            if measurement.isClipping {
                lastError = CalibrationMeasurementError.clipping(frequencyHz)
                signalLevel -= 4
                continue
            }
            if measurement.snrDB < 12 {
                lastError = CalibrationMeasurementError.insufficientSNR(
                    frequency: frequencyHz,
                    snr: measurement.snrDB
                )
                if !jumpedToMax && ceiling > signalLevel {
                    signalLevel = ceiling
                    jumpedToMax = true
                    continue
                }
                continue
            }
            if measurement.stabilityDB > 0.5 {
                lastError = CalibrationMeasurementError.unstable(
                    frequency: frequencyHz,
                    stability: measurement.stabilityDB
                )
                continue
            }
            return (measurement, signalLevel)
        }
        throw lastError
    }

    private func verifyDevices(outputDeviceUID: String) throws {
        guard outputMonitor.snapshot().uid == outputDeviceUID else {
            throw CalibrationMeasurementError.outputDeviceChanged
        }
        guard microphone.verifySelectedDeviceIsPresent() else {
            throw CalibrationMeasurementError.inputDeviceChanged
        }
        guard microphone.matchesCurrentInputChain() else {
            throw CalibrationMeasurementError.inputChainChanged
        }
    }

    private func setOrAwaitVolume(
        _ target: Float,
        outputDeviceUID: String,
        progress: @escaping ProgressHandler
    ) async throws {
        if outputMonitor.setVolumeScalar(target) {
            for _ in 0..<15 {
                try verifyDevices(outputDeviceUID: outputDeviceUID)
                outputMonitor.refresh()
                try await Task.sleep(for: .milliseconds(100))
                if let volume = outputMonitor.snapshot().volumeScalar, abs(volume - target) < 0.015 {
                    return
                }
            }
        }

        progress(CalibrationProgress(
            message: "请把系统音量调到 \(Int(target * 100))%，检测到后会自动继续",
            fraction: 0,
            retry: 0
        ))
        for _ in 0..<600 {
            try Task.checkCancellation()
            try verifyDevices(outputDeviceUID: outputDeviceUID)
            outputMonitor.refresh()
            try await Task.sleep(for: .milliseconds(100))
            if let volume = outputMonitor.snapshot().volumeScalar, abs(volume - target) < 0.015 {
                return
            }
        }
        throw CalibrationMeasurementError.volumeUnavailable(target)
    }

    private func waitWhileVerifyingDevices(
        milliseconds: Int,
        outputDeviceUID: String
    ) async throws {
        var remaining = milliseconds
        while remaining > 0 {
            try Task.checkCancellation()
            try verifyDevices(outputDeviceUID: outputDeviceUID)
            let interval = min(100, remaining)
            try await Task.sleep(for: .milliseconds(interval))
            remaining -= interval
        }
    }

    static func validationMessage(errorDB: Double) -> String {
        if errorDB <= 1.0 { return "音量曲线验证通过" }
        if errorDB <= 2.0 { return "校准可用，但验证误差偏大" }
        return "校准验证失败，建议重新测试音量曲线"
    }
}
