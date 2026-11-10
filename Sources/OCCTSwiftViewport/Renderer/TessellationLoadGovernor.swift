// TessellationLoadGovernor.swift
// OCCTSwiftViewport
//
// Scales the uniform tessellation factor (adaptiveTessellation == false) to system load:
// measured GPU frame time against the frame budget, thermal state and Low Power Mode. A frame
// time only counts as overload when the GPU was saturated (#241).

import Foundation

/// One frame's load signals, fed to `TessellationLoadGovernor.step(_:)`.
struct TessellationLoadSample: Sendable, Equatable {
    /// GPU time of the most recently completed frame, in seconds; `nil` when none was measured.
    ///
    /// This is not a property of the scene alone. A frame that follows an idle GPU takes longer
    /// than the same frame behind a busy one (10.0 against 5.0 ms for one scene on an M4), and a
    /// debug build's slow CPU-side encoding makes every frame such a frame (#238). The governor
    /// therefore reads it together with `gpuIdleBefore`, and only lets a frame the GPU was
    /// saturated for lower the factor (#241).
    var gpuFrameTime: Double?
    /// Seconds the GPU sat idle between the previous frame finishing and this frame starting;
    /// `nil` when unknown, and `.infinity` for the first frame measured.
    ///
    /// With `gpuFrameTime` it gives how much of the span the GPU was busy (`gpuBusyFraction`).
    /// When `nil` the frame time is taken at face value, as before this field existed.
    var gpuIdleBefore: Double?
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

    /// The fraction of the span from the previous frame's end to this frame's end that the GPU
    /// spent running this frame (0...1); `nil` when `gpuIdleBefore` or `gpuFrameTime` is unknown.
    ///
    /// Near 1 means frames run back to back, so the GPU is the bottleneck. Well below 1 means the
    /// GPU waited on the CPU, the display or an idle app, and its clock may have dropped.
    var gpuBusyFraction: Double? {
        guard let time = gpuFrameTime, let idle = gpuIdleBefore, time.isFinite, time >= 0,
            !idle.isNaN
        else { return nil }
        let span = time + max(0, idle)
        return span > 0 ? time / span : nil
    }
}

/// Load-driven controller for the uniform tessellation factor.
///
/// A value type with pure `step`, so the maths is unit-testable without a GPU. The renderer
/// keeps one instance per live view and steps it once per frame; off-screen renders do not use
/// it and tessellate at the configured factor, so their output stays deterministic.
///
/// Behaviour:
/// - The GPU frame time is smoothed with an exponential moving average.
/// - A frame the GPU was not saturated for (it sat idle for more than 5% of the span before the
///   frame, see `saturatedBusyFraction`) is only an upper bound on what the frame costs, because
///   an idle GPU clocks down and runs the same work slower. Such a frame can pull the average
///   down, so a light scene still earns a higher factor, but it never pushes the average up, so it
///   cannot lower the factor.
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
    /// A frame counts as overload evidence only when the GPU was busy for at least this fraction
    /// of the span since the previous frame ended (`TessellationLoadSample.gpuBusyFraction`).
    ///
    /// Measured on an M4 (#241): frames that fit their budget are stretched by the GPU's clock
    /// governor to fill 0.75 to 0.91 of the interval whatever the work, so a busy fraction there
    /// says nothing about load. Frames that really overrun the budget queue behind each other and
    /// measure 1.00 at every percentile.
    static let saturatedBusyFraction = 0.95
    /// The load, as a fraction of the budget, assumed for a frame that is not overload evidence
    /// when there is no average yet: the middle of the hold band, so it moves the factor neither
    /// way.
    static let neutralLoad = (highLoad + lowLoad) / 2

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
            var evidence = time
            if let busy = sample.gpuBusyFraction, busy < Self.saturatedBusyFraction {
                // The GPU was not the bottleneck for this frame, so `time` may be inflated by an
                // idle clock. Use it only to confirm headroom, never to show overload.
                let bound =
                    smoothedFrameTime
                    ?? (sample.frameBudget > 0 ? Self.neutralLoad * sample.frameBudget : time)
                evidence = min(time, bound)
            }
            next.smoothedFrameTime =
                smoothedFrameTime.map { $0 + Self.smoothing * (evidence - $0) } ?? evidence
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

/// One completed frame's GPU timing, as recorded by `GPUFrameTimeRecorder`.
struct GPUFrameTiming: Sendable, Equatable {
    /// GPU time of the frame (`gpuEndTime - gpuStartTime`), in seconds.
    var duration: Double
    /// Seconds the GPU sat idle between the previous recorded frame's end and this frame's start;
    /// `.infinity` for the first frame recorded, since nothing ran before it.
    var idleBefore: Double
}

/// Thread-safe holder for the latest GPU frame timing, written from a command buffer's
/// completion handler (any thread) and read on the main actor when the next frame is encoded.
final class GPUFrameTimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: GPUFrameTiming?
    private var previousEnd: Double?

    /// Records one completed frame's GPU timing; ignores missing (zero) or invalid timestamps.
    ///
    /// Both timestamps come from the GPU's own clock, so the idle gap needs no host clock. A
    /// frame that starts before the previous one ended (overlapping work) has no gap.
    func record(gpuStartTime: Double, gpuEndTime: Double) {
        let duration = gpuEndTime - gpuStartTime
        guard gpuStartTime > 0, duration.isFinite, duration >= 0 else { return }
        lock.lock()
        let idle = previousEnd.map { max(0, gpuStartTime - $0) } ?? .infinity
        latest = GPUFrameTiming(duration: duration, idleBefore: idle)
        previousEnd = gpuEndTime
        lock.unlock()
    }

    /// The most recently recorded GPU frame timing.
    var latestTiming: GPUFrameTiming? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// The most recently recorded GPU frame time, in seconds.
    var latestFrameTime: Double? { latestTiming?.duration }
}
