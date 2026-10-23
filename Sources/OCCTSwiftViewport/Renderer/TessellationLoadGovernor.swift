// TessellationLoadGovernor.swift
// OCCTSwiftViewport
//
// Scales the uniform tessellation factor (adaptiveTessellation == false) to system load:
// measured GPU frame time against the frame budget, thermal state and Low Power Mode.

import Foundation

/// One frame's load signals, fed to `TessellationLoadGovernor.step(_:)`.
struct TessellationLoadSample: Sendable, Equatable {
    /// GPU time of the most recently completed frame, in seconds; `nil` when none was measured.
    var gpuFrameTime: Double?
    /// Time available per frame, in seconds (`1 / preferredFramesPerSecond`).
    var frameBudget: Double
    /// `ProcessInfo.thermalState` at the time of the sample.
    var thermalState: ProcessInfo.ThermalState
    /// `ProcessInfo.isLowPowerModeEnabled` at the time of the sample.
    var isLowPowerModeEnabled: Bool
    /// The lowest factor the governor may choose.
    var minFactor: Float
    /// The configured (and pipeline-capped) maximum factor.
    var maxFactor: Float
}

/// Load-driven controller for the uniform tessellation factor.
///
/// A value type with pure `step`, so the maths is unit-testable without a GPU. The renderer
/// keeps one instance per live view and steps it once per frame; off-screen renders do not use
/// it and tessellate at the configured factor, so their output stays deterministic.
///
/// Behaviour:
/// - The GPU frame time is smoothed with an exponential moving average.
/// - Above `highLoad` × budget the factor drops multiplicatively; below `lowLoad` × budget it
///   rises slowly. In between it holds, which is the hysteresis band.
/// - After any change the factor is held for `cooldownFrames` frames, so it cannot oscillate
///   frame to frame.
/// - Thermal pressure and Low Power Mode lower the ceiling, and the factor snaps under a lowered
///   ceiling at once.
struct TessellationLoadGovernor: Sendable, Equatable {

    /// Smoothed load is above this fraction of the budget: reduce the factor.
    static let highLoad = 0.85
    /// Smoothed load is below this fraction of the budget: raise the factor.
    static let lowLoad = 0.55
    /// Exponential moving average weight of the newest frame time.
    static let smoothing = 0.1
    /// Multiplier applied when overloaded.
    static let decreaseFactor: Float = 0.8
    /// Additive step applied when there is headroom.
    static let increaseStep: Float = 2
    /// Frames to hold after a change before another change is allowed.
    static let cooldownFrames = 30

    /// The factor to tessellate with this frame; `nil` until the first step.
    private(set) var factor: Float?
    /// Smoothed GPU frame time, in seconds; `nil` until the first measured frame.
    private(set) var smoothedFrameTime: Double?
    /// Frames left before the factor may change again.
    private(set) var cooldown = 0

    /// The uniform factor to tessellate with for `policy`.
    ///
    /// - Parameters:
    ///   - policy: The configured `UniformTessellationFactor`.
    ///   - maxFactor: The clamped, pipeline-capped `tessellationMaxFactor`.
    ///   - governed: The governor's current factor, or `nil` when no governor runs (off-screen,
    ///     or before the first live frame).
    /// - Returns: `.fixed` clamped to `1...maxFactor`; for `.loadAdaptive`, `governed` clamped
    ///   to that range, or `maxFactor` when there is none.
    nonisolated static func uniformFactor(
        policy: UniformTessellationFactor, maxFactor: Float, governed: Float?
    ) -> Float {
        let upper = max(1, maxFactor)
        switch policy {
        case .fixed(let value):
            return min(max(Float(value), 1), upper)
        case .loadAdaptive:
            return min(max(governed ?? upper, 1), upper)
        }
    }

    /// The ceiling the system state allows, between `minFactor` and `maxFactor`.
    nonisolated static func ceiling(
        maxFactor: Float, minFactor: Float, thermalState: ProcessInfo.ThermalState,
        isLowPowerModeEnabled: Bool
    ) -> Float {
        let thermalScale: Float
        switch thermalState {
        case .nominal: thermalScale = 1
        case .fair: thermalScale = 0.75
        case .serious: thermalScale = 0.5
        case .critical: thermalScale = 0
        @unknown default: thermalScale = 1
        }
        let powerScale: Float = isLowPowerModeEnabled ? 0.5 : 1
        return max(minFactor, maxFactor * thermalScale * powerScale)
    }

    /// Advances the governor by one frame and returns its new state.
    nonisolated func step(_ sample: TessellationLoadSample) -> TessellationLoadGovernor {
        var next = self
        let floor = max(1, min(sample.minFactor, sample.maxFactor))
        let ceiling = Self.ceiling(
            maxFactor: max(floor, sample.maxFactor), minFactor: floor,
            thermalState: sample.thermalState,
            isLowPowerModeEnabled: sample.isLowPowerModeEnabled)

        if let time = sample.gpuFrameTime, time.isFinite, time >= 0 {
            next.smoothedFrameTime =
                smoothedFrameTime.map { $0 + Self.smoothing * (time - $0) } ?? time
        }

        // Start at the ceiling: full quality until load says otherwise.
        var factor = factor ?? ceiling
        if next.cooldown > 0 { next.cooldown -= 1 }

        if next.cooldown == 0, let load = next.smoothedFrameTime, sample.frameBudget > 0 {
            let ratio = load / sample.frameBudget
            var changed = factor
            if ratio > Self.highLoad {
                changed = factor * Self.decreaseFactor
            } else if ratio < Self.lowLoad {
                changed = factor + Self.increaseStep
            }
            changed = min(max(changed, floor), ceiling)
            if changed != factor {
                factor = changed
                next.cooldown = Self.cooldownFrames
            }
        }

        // A lowered ceiling (thermal, Low Power Mode, smaller max) applies at once.
        next.factor = min(max(factor, floor), ceiling)
        return next
    }
}

/// Thread-safe holder for the latest GPU frame time, written from a command buffer's
/// completion handler (any thread) and read on the main actor when the next frame is encoded.
final class GPUFrameTimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double?

    /// Records one completed frame's GPU time; ignores missing (zero) or invalid timestamps.
    func record(gpuStartTime: Double, gpuEndTime: Double) {
        let duration = gpuEndTime - gpuStartTime
        guard gpuStartTime > 0, duration.isFinite, duration >= 0 else { return }
        lock.lock()
        latest = duration
        lock.unlock()
    }

    /// The most recently recorded GPU frame time, in seconds.
    var latestFrameTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}
