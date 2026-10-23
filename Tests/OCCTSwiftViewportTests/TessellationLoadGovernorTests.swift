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
        min: Float = 4, max: Float = 32
    ) -> TessellationLoadSample {
        TessellationLoadSample(
            gpuFrameTime: load.map { $0 * budget }, frameBudget: budget, thermalState: thermal,
            isLowPowerModeEnabled: lowPower, minFactor: min, maxFactor: max)
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
        recorder.record(gpuStartTime: 10, gpuEndTime: 10.004)
        #expect(abs((recorder.latestFrameTime ?? 0) - 0.004) < 1e-9)
        recorder.record(gpuStartTime: 10, gpuEndTime: 9)
        #expect(abs((recorder.latestFrameTime ?? 0) - 0.004) < 1e-9)
    }
}
