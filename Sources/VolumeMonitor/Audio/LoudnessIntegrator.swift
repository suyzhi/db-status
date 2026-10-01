import Darwin
import Foundation

/// 音频线程 → 主线程的 A 加权能量通道。
///
/// 声暴露必须对每个样本的能量积分，而不是对 10 Hz 采样的显示值积分：
/// 显示值经过平滑，且主线程定时器会被 App Nap、合并或卡顿打断。
/// 这里由音频线程累加"有声时段"的能量与时长，主线程每次刷新取走并清零。
///
/// 实时线程从不阻塞：只做 try-lock，拿不到锁（主线程正在取数）就先记在
/// 本地，下一个回调再合并。
final class LoudnessIntegrator: @unchecked Sendable {
    struct Drained: Sendable, Equatable {
        /// 有声时段的 A 加权均方（线性，满幅 = 1）。
        let meanSquare: Double
        /// 有声时长（秒）。
        let activeSeconds: Double
        /// 这段时间内 Fast（125 ms）计权的最大均方，用于 LAFmax。
        let maxFastMeanSquare: Double

        static let empty = Drained(meanSquare: 0, activeSeconds: 0, maxFastMeanSquare: 0)
    }

    /// IEC 61672 Fast 时间计权常数。
    static let fastTimeConstant = 0.125
    /// 低于 −80 dBFS 视为无声，不计入时长（与 AudioLevelSnapshot.hasUsableAudio 一致）。
    static let activityThresholdMeanSquare = 1e-8

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    // 受锁保护，主线程读取。
    private var sharedEnergy = 0.0
    private var sharedSeconds = 0.0
    private var sharedMaxFast = 0.0

    // 仅音频线程访问。
    private var pendingEnergy = 0.0
    private var pendingSeconds = 0.0
    private var pendingMaxFast = 0.0
    private(set) var fastMeanSquare = 0.0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// 音频线程：加入一段信号块，返回更新后的 Fast 计权均方。
    @discardableResult
    func add(meanSquare: Double, frames: Int, sampleRate: Double) -> Double {
        guard frames > 0, sampleRate > 0, meanSquare.isFinite, meanSquare >= 0 else {
            return fastMeanSquare
        }
        let seconds = Double(frames) / sampleRate
        let alpha = 1 - exp(-seconds / Self.fastTimeConstant)
        fastMeanSquare += (meanSquare - fastMeanSquare) * alpha
        if meanSquare > Self.activityThresholdMeanSquare {
            pendingEnergy += meanSquare * seconds
            pendingSeconds += seconds
            pendingMaxFast = max(pendingMaxFast, fastMeanSquare)
        }
        guard pendingSeconds > 0, os_unfair_lock_trylock(lock) else { return fastMeanSquare }
        sharedEnergy += pendingEnergy
        sharedSeconds += pendingSeconds
        sharedMaxFast = max(sharedMaxFast, pendingMaxFast)
        os_unfair_lock_unlock(lock)
        pendingEnergy = 0
        pendingSeconds = 0
        pendingMaxFast = 0
        return fastMeanSquare
    }

    /// 音频线程（或采集停止后）：让 Fast 计权按静音衰减，不累计时长。
    @discardableResult
    func addSilence(frames: Int, sampleRate: Double) -> Double {
        add(meanSquare: 0, frames: frames, sampleRate: sampleRate)
    }

    /// 只能在音频回调停止后调用（采集队列上 stop 时）。
    func resetAudioThreadState() {
        pendingEnergy = 0
        pendingSeconds = 0
        pendingMaxFast = 0
        fastMeanSquare = 0
    }

    /// 主线程：取走自上次以来的累计值并清零。
    func drain() -> Drained {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard sharedSeconds > 0 else { return .empty }
        let result = Drained(
            meanSquare: sharedEnergy / sharedSeconds,
            activeSeconds: sharedSeconds,
            maxFastMeanSquare: sharedMaxFast
        )
        sharedEnergy = 0
        sharedSeconds = 0
        sharedMaxFast = 0
        return result
    }
}
