// TessellationLoadGovernorTests.swift
// OCCTSwiftViewport Tests
//
// The load governor that scales the uniform tessellation factor (adaptiveTessellation == false).

import Foundation
import Testing

@testable import OCCTSwiftViewport

@Suite("Tessellation load governor")
struct TessellationLoadGovernorTests {

    private static let budget = 1.0 / 60.0

    private static func sample(
        load: Double?, thermal: ProcessInfo.ThermalState = .nominal, lowPower: Bool = false,
        min: Float = 4, max: Float = 32, idle: Double? = nil
    ) -> TessellationLoadSample {
        TessellationLoadSample(
            gpuFrameTime: load.map { $0 * budget }, gpuIdleBefore: idle.map { $0 * budget },
            frameBudget: budget, thermalState: thermal,
            isLowPowerModeEnabled: lowPower, minFactor: min, maxFactor: max)
    }

    /// A sample in seconds, for replaying measured times against a budget other than 1/60.
    private static func measured(
        gpu: Double, idle: Double?, budget: Double, min: Float = 4, max: Float = 32
    ) -> TessellationLoadSample {
        TessellationLoadSample(
            gpuFrameTime: gpu, gpuIdleBefore: idle, frameBudget: budget, thermalState: .nominal,
            isLowPowerModeEnabled: false, minFactor: min, maxFactor: max)
    }

    /// Steps `frames` times with the same sample and returns every frame's factor.
    private static func run(
        _ governor: inout TessellationLoadGovernor, _ sample: TessellationLoadSample, frames: Int
    ) -> [Float] {
        var factors: [Float] = []
        for _ in 0..<frames {
            governor = governor.step(sample)
            factors.append(governor.factor ?? -1)
        }
        return factors
    }

    @Test("Starts at the ceiling with no measurement yet")
    func startsAtCeiling() {
        let governor = TessellationLoadGovernor().step(Self.sample(load: nil))
        #expect(governor.factor == 32)
    }

    @Test("Sustained overload lowers the factor to the floor, never below")
    func overloadLowersToFloor() {
        var governor = TessellationLoadGovernor()
        let factors = Self.run(&governor, Self.sample(load: 2.0), frames: 600)
        #expect(factors.first == 32 * TessellationLoadGovernor.decreaseFactor)
        #expect(factors.last == 4)
        #expect(factors.allSatisfy { $0 >= 4 && $0 <= 32 })
        // Monotonic: no frame raises the factor while overloaded.
        #expect(zip(factors, factors.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test("Headroom raises the factor back to the max")
    func headroomRaisesToMax() {
        var governor = TessellationLoadGovernor()
        _ = Self.run(&governor, Self.sample(load: 2.0), frames: 600)
        #expect(governor.factor == 4)
        let factors = Self.run(&governor, Self.sample(load: 0.2), frames: 1200)
        #expect(factors.last == 32)
        #expect(zip(factors, factors.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Load inside the hysteresis band holds the factor")
    func bandHolds() {
        var governor = TessellationLoadGovernor()
        _ = Self.run(&governor, Self.sample(load: 2.0), frames: 40)
        let held = governor.factor
        let factors = Self.run(&governor, Self.sample(load: 0.7), frames: 600)
        // The EMA needs time to settle into the band; after that, no further change.
        #expect(Set(factors.suffix(300)).count == 1)
        #expect(held != nil)
    }

    @Test("Changes are rate-limited by the cooldown (no frame-to-frame oscillation)")
    func cooldownLimitsChanges() {
        var governor = TessellationLoadGovernor()
        // Alternate wildly between overload and idle every frame.
        var factors: [Float] = []
        for i in 0..<600 {
            governor = governor.step(Self.sample(load: i.isMultiple(of: 2) ? 3.0 : 0.0))
            factors.append(governor.factor ?? -1)
        }
        let changes = zip(factors, factors.dropFirst()).filter { $0 != $1 }.count
        #expect(changes <= 600 / TessellationLoadGovernor.cooldownFrames + 1)
    }

    @Test("Thermal pressure and Low Power Mode lower the ceiling at once")
    func systemStateCapsCeiling() {
        var governor = TessellationLoadGovernor()
        _ = Self.run(&governor, Self.sample(load: 0.1), frames: 10)
        #expect(governor.factor == 32)
        governor = governor.step(Self.sample(load: 0.1, thermal: .serious))
        #expect(governor.factor == 16)
        governor = governor.step(Self.sample(load: 0.1, thermal: .serious, lowPower: true))
        #expect(governor.factor == 8)
        governor = governor.step(Self.sample(load: 0.1, thermal: .critical))
        #expect(governor.factor == 4)
        #expect(
            TessellationLoadGovernor.ceiling(
                maxFactor: 32, minFactor: 4, thermalState: .fair, isLowPowerModeEnabled: false)
                == 24)
    }

    @Test("A minimum above the max is capped to the max")
    func minimumAboveMax() {
        var governor = TessellationLoadGovernor()
        let factors = Self.run(&governor, Self.sample(load: 3.0, min: 50, max: 16), frames: 100)
        #expect(factors.allSatisfy { $0 == 16 })
    }

    @Test("Invalid frame times are ignored")
    func invalidFrameTimesIgnored() {
        var governor = TessellationLoadGovernor()
        var bad = Self.sample(load: nil)
        bad.gpuFrameTime = .nan
        governor = governor.step(bad)
        bad.gpuFrameTime = -1
        governor = governor.step(bad)
        #expect(governor.smoothedFrameTime == nil)
        #expect(governor.factor == 32)
    }

    // MARK: - Idle-clocked GPU time (#241)

    /// The M4 measurements from #238.
    ///
    /// 645k triangles, 1080p, 4x MSAA. The first frame after a 130 ms pause took 10.0 ms and the
    /// next took 5.0 ms (scene A, 120 fps budget); 15.2 and 9.0 ms with shadows, SSAO and
    /// silhouettes (scene D, 60 fps budget).
    private static let scenes: [(name: String, cold: Double, warm: Double, budget: Double)] = [
        ("scene A, 120 fps", 0.0100, 0.0050, 1.0 / 120),
        ("scene D, 60 fps", 0.0152, 0.0090, 1.0 / 60),
    ]

    @Test("Without the idle signal the cold-clock times still lower the factor (old behaviour)")
    func coldClockWithoutSignalDrops() {
        for scene in Self.scenes {
            var warm = TessellationLoadGovernor()
            var cold = TessellationLoadGovernor()
            for _ in 0..<1200 {
                warm = warm.step(Self.measured(gpu: scene.warm, idle: nil, budget: scene.budget))
                cold = cold.step(Self.measured(gpu: scene.cold, idle: nil, budget: scene.budget))
            }
            #expect(warm.factor == 32, "\(scene.name) warm")
            #expect(cold.factor == 4, "\(scene.name) cold")
        }
    }

    @Test("Cold-clock frames after a pause do not lower the factor; warm frames behave as before")
    func coldClockHoldsFactor() {
        for scene in Self.scenes {
            // Every frame follows a 130 ms pause, as in a debug build or on-demand drawing.
            var cold = TessellationLoadGovernor()
            // Frames submitted back to back with no idle gap.
            var warm = TessellationLoadGovernor()
            // On demand: a cold frame, then the frame submitted straight behind it.
            var mixed = TessellationLoadGovernor()
            for _ in 0..<1200 {
                cold = cold.step(Self.measured(gpu: scene.cold, idle: 0.130, budget: scene.budget))
                warm = warm.step(Self.measured(gpu: scene.warm, idle: 0, budget: scene.budget))
                mixed = mixed.step(
                    Self.measured(gpu: scene.cold, idle: 0.130, budget: scene.budget))
                mixed = mixed.step(Self.measured(gpu: scene.warm, idle: 0, budget: scene.budget))
                #expect(cold.factor == 32, "\(scene.name) cold")
                #expect(warm.factor == 32, "\(scene.name) warm")
                #expect(mixed.factor == 32, "\(scene.name) mixed")
            }
            #expect(cold.cooldown == 0, "a frame that is ignored must not start the cooldown")
        }
    }

    @Test("Frames stretched to fill their interval by an unsaturated GPU do not lower the factor")
    func stretchedFramesHoldFactor() {
        // Paced at 120 fps, an M4 ran a 2 ms workload in 7.2 ms (0.87 of the budget, #241): above
        // the 0.85 threshold, with 13% of the interval idle.
        let budget = 1.0 / 120
        var stretched = TessellationLoadGovernor()
        var unaware = TessellationLoadGovernor()
        for _ in 0..<1200 {
            stretched = stretched.step(
                Self.measured(gpu: 0.87 * budget, idle: 0.13 * budget, budget: budget))
            unaware = unaware.step(Self.measured(gpu: 0.87 * budget, idle: nil, budget: budget))
        }
        #expect(stretched.factor == 32)
        #expect(unaware.factor == 4)
    }

    @Test("A saturated GPU (frames back to back) still lowers the factor, as without the signal")
    func saturatedOverloadStillDrops() {
        var withSignal = TessellationLoadGovernor()
        var withoutSignal = TessellationLoadGovernor()
        var factors: [Float] = []
        for _ in 0..<600 {
            withSignal = withSignal.step(Self.sample(load: 2.0, idle: 0))
            withoutSignal = withoutSignal.step(Self.sample(load: 2.0))
            factors.append(withSignal.factor ?? -1)
        }
        #expect(withSignal == withoutSignal)
        #expect(factors.first == 32 * TessellationLoadGovernor.decreaseFactor)
        #expect(factors.last == 4)
        #expect(zip(factors, factors.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test("A GPU that only just keeps up (up to 4% idle) is still saturated")
    func nearlySaturatedStillDrops() {
        for idle in [0.0, 0.01, 0.04] {
            var governor = TessellationLoadGovernor()
            let factors = Self.run(&governor, Self.sample(load: 1.0, idle: idle), frames: 600)
            #expect(factors.last == 4, "idle \(idle)")
        }
        // 7% idle is more than the 5% the threshold allows: not evidence of overload.
        var governor = TessellationLoadGovernor()
        let factors = Self.run(&governor, Self.sample(load: 1.0, idle: 0.07), frames: 600)
        #expect(factors.last == 32)
    }

    @Test("Frames over budget only because the display is slow do not lower the factor")
    func displayLimitedFramesHoldFactor() {
        // 1.2x the budget of GPU time, but half of each interval idle: the display, not the GPU,
        // sets the pace.
        var governor = TessellationLoadGovernor()
        let factors = Self.run(&governor, Self.sample(load: 1.2, idle: 1.2), frames: 600)
        #expect(factors.allSatisfy { $0 == 32 })
    }

    @Test("A light load measured on an idle-clocked GPU still raises the factor")
    func lightColdLoadRaisesFactor() {
        var governor = TessellationLoadGovernor()
        _ = Self.run(&governor, Self.sample(load: 2.0, idle: 0), frames: 600)
        #expect(governor.factor == 4)
        // The scene got light: even stretched or cold, its frames are far under the budget.
        let factors = Self.run(&governor, Self.sample(load: 0.2, idle: 5), frames: 1200)
        #expect(factors.last == 32)
        #expect(zip(factors, factors.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A cold, heavy frame leaves the average where it was")
    func coldHeavyFrameLeavesAverage() {
        var governor = TessellationLoadGovernor()
        _ = Self.run(&governor, Self.sample(load: 2.0, idle: 0), frames: 600)
        let smoothed = governor.smoothedFrameTime
        governor = governor.step(Self.sample(load: 4.0, idle: 8))
        #expect((governor.smoothedFrameTime ?? .infinity) <= (smoothed ?? 0))
        #expect(governor.factor == 4)
    }

    @Test("With no average yet, an ignored frame seeds the middle of the hold band")
    func firstColdFrameSeedsNeutralLoad() {
        // First frame of the session: the recorder reports infinite idle.
        let heavy = TessellationLoadGovernor().step(Self.sample(load: 3.0, idle: .infinity))
        #expect(heavy.factor == 32)
        let neutral = TessellationLoadGovernor.neutralLoad * Self.budget
        #expect(abs((heavy.smoothedFrameTime ?? 0) - neutral) < 1e-12)
        // A light first frame is used as it is: it can only confirm headroom.
        let light = TessellationLoadGovernor().step(Self.sample(load: 0.2, idle: .infinity))
        #expect(abs((light.smoothedFrameTime ?? 0) - 0.2 * Self.budget) < 1e-12)
    }

    @Test("An ignored frame with a zero budget still seeds a valid average")
    func ignoredFrameWithoutBudget() {
        var sample = Self.sample(load: 3.0, idle: 10)
        sample.frameBudget = 0
        let governor = TessellationLoadGovernor().step(sample)
        #expect(governor.smoothedFrameTime == sample.gpuFrameTime)
        #expect(governor.factor == 32)
    }

    @Test("Changes stay rate-limited by the cooldown when the idle signal is present")
    func cooldownLimitsChangesWithSignal() {
        var governor = TessellationLoadGovernor()
        var factors: [Float] = []
        // Alternate wildly between saturated overload and idle every frame.
        for i in 0..<600 {
            let overloaded = i.isMultiple(of: 2)
            governor = governor.step(
                Self.sample(load: overloaded ? 3.0 : 0.0, idle: overloaded ? 0 : 5))
            factors.append(governor.factor ?? -1)
        }
        let changes = zip(factors, factors.dropFirst()).filter { $0 != $1 }.count
        #expect(changes <= 600 / TessellationLoadGovernor.cooldownFrames + 1)
    }

    @Test("Busy fraction is the share of the span the GPU ran, and nil when unknown")
    func busyFraction() {
        func fraction(_ time: Double?, _ idle: Double?) -> Double? {
            TessellationLoadSample(
                gpuFrameTime: time, gpuIdleBefore: idle, frameBudget: 1.0 / 60,
                thermalState: .nominal, isLowPowerModeEnabled: false, minFactor: 4, maxFactor: 32
            ).gpuBusyFraction
        }
        #expect(fraction(0.010, 0.010) == 0.5)
        #expect(fraction(0.010, 0) == 1)
        #expect(fraction(0.010, -0.002) == 1, "overlapping work has no gap")
        #expect(fraction(0.010, .infinity) == 0)
        #expect(fraction(0.010, nil) == nil)
        #expect(fraction(nil, 0.010) == nil)
        #expect(fraction(0.010, .nan) == nil)
        #expect(fraction(.nan, 0.010) == nil)
        #expect(fraction(0, 0) == nil)
    }

    @Test("The idle signal defaults to absent, which keeps the old behaviour")
    func absentSignalDefault() {
        let sample = TessellationLoadSample(
            gpuFrameTime: 0.02, frameBudget: 1.0 / 60, thermalState: .nominal,
            isLowPowerModeEnabled: false, minFactor: 4, maxFactor: 32)
        #expect(sample.gpuIdleBefore == nil)
        #expect(sample.gpuBusyFraction == nil)
        // The time is taken at face value: 1.2x the budget lowers the factor at once.
        let governor = TessellationLoadGovernor().step(sample)
        #expect(governor.smoothedFrameTime == 0.02)
        #expect(governor.factor == 32 * TessellationLoadGovernor.decreaseFactor)
    }

    @Test("Thermal and Low Power ceilings still apply to ignored frames")
    func ceilingAppliesToIgnoredFrames() {
        var governor = TessellationLoadGovernor()
        governor = governor.step(Self.sample(load: 0.1, idle: 5))
        #expect(governor.factor == 32)
        governor = governor.step(Self.sample(load: 3.0, thermal: .serious, idle: 5))
        #expect(governor.factor == 16)
    }

    @Test("uniformFactor resolves fixed and load-adaptive policies")
    func uniformFactorPolicy() {
        typealias G = TessellationLoadGovernor
        #expect(G.uniformFactor(policy: .fixed(8), maxFactor: 32, governed: 4) == 8)
        #expect(G.uniformFactor(policy: .fixed(100), maxFactor: 32, governed: nil) == 32)
        #expect(G.uniformFactor(policy: .fixed(0), maxFactor: 32, governed: nil) == 1)
        #expect(G.uniformFactor(policy: .loadAdaptive(), maxFactor: 32, governed: nil) == 32)
        #expect(G.uniformFactor(policy: .loadAdaptive(), maxFactor: 32, governed: 12) == 12)
    }

    @Test("GPU frame time recorder ignores missing timestamps")
    func recorder() {
        let recorder = GPUFrameTimeRecorder()
        recorder.record(gpuStartTime: 0, gpuEndTime: 0)
        #expect(recorder.latestFrameTime == nil)
        #expect(recorder.latestTiming == nil)
        recorder.record(gpuStartTime: 10, gpuEndTime: 10.004)
        #expect(abs((recorder.latestFrameTime ?? 0) - 0.004) < 1e-9)
        recorder.record(gpuStartTime: 10, gpuEndTime: 9)
        #expect(abs((recorder.latestFrameTime ?? 0) - 0.004) < 1e-9)
    }

    @Test("GPU frame time recorder measures the idle gap from the previous frame's end")
    func recorderIdleGap() throws {
        let recorder = GPUFrameTimeRecorder()
        // Nothing ran before the first frame.
        recorder.record(gpuStartTime: 10, gpuEndTime: 10.004)
        #expect(recorder.latestTiming?.idleBefore == .infinity)
        // Back to back: no gap.
        recorder.record(gpuStartTime: 10.004, gpuEndTime: 10.009)
        var timing = try #require(recorder.latestTiming)
        #expect(timing.idleBefore == 0)
        #expect(abs(timing.duration - 0.005) < 1e-9)
        // After a 130 ms pause.
        recorder.record(gpuStartTime: 10.139, gpuEndTime: 10.149)
        timing = try #require(recorder.latestTiming)
        #expect(abs(timing.idleBefore - 0.130) < 1e-9)
        // Overlapping work has no gap, rather than a negative one.
        recorder.record(gpuStartTime: 10.145, gpuEndTime: 10.155)
        #expect(recorder.latestTiming?.idleBefore == 0)
        // A rejected record neither replaces the timing nor moves the reference end.
        recorder.record(gpuStartTime: 11, gpuEndTime: 10)
        recorder.record(gpuStartTime: 0, gpuEndTime: 20)
        #expect(recorder.latestTiming?.idleBefore == 0)
        recorder.record(gpuStartTime: 10.165, gpuEndTime: 10.170)
        #expect(abs((recorder.latestTiming?.idleBefore ?? 0) - 0.010) < 1e-9)
    }
}
