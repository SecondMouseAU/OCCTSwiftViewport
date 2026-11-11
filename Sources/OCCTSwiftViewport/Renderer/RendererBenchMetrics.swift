// RendererBenchMetrics.swift
// OCCTSwiftViewport
//
// Read-only per-frame timings and counters for benchmark apps (Examples/SpikeBench). Nothing is
// recorded unless a benchmark asks, and the only always-on cost is one integer increment when a
// body's GPU buffers are rebuilt. Reached through `@_spi(Bench) import OCCTSwiftViewport`; it is
// not public API.

import Foundation
@preconcurrency import Metal

/// What one frame cost, as the live renderer measured it.
@_spi(Bench)
public struct ViewportFrameSample: Sendable {
    /// Wall-clock seconds the main thread spent encoding the frame (the draw callback's work,
    /// including the commit).
    public var encodeSeconds: Double = 0
    /// `gpuEndTime - gpuStartTime` of the frame's command buffer; 0 until it has completed.
    public var gpuSeconds: Double = 0
    /// `gpuEndTime` of the frame's command buffer (seconds on the GPU's clock); 0 until it has
    /// completed. Differences between consecutive frames give the frame interval when frames
    /// are queued back to back and their `gpuSeconds` spans overlap.
    public var gpuEndTime: Double = 0
    /// Bytes copied into heightfield staging buffers for this frame.
    public var heightfieldUploadedBytes: Int = 0
    /// Tiles planned for the heightfields' shaded pass (one pass's worth).
    public var heightfieldTilesDrawn: Int = 0
    /// Instanced draw calls issued for heightfields, summed over every pass.
    public var heightfieldDrawCalls: Int = 0
    /// CPU seconds spent encoding the heightfield uploads and pyramid rebuild.
    public var heightfieldUpdateSeconds: Double = 0
    /// CPU seconds spent planning the heightfield tiles.
    public var heightfieldPlanSeconds: Double = 0

    public init() {}
}

/// Counts a heightfield's instanced draws. The encoders that draw it are not main-actor
/// isolated, so the count sits behind a lock.
final class HeightfieldDrawCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Running totals over every heightfield a renderer holds.
struct HeightfieldBenchTotals {
    var uploadedBytes = 0
    var drawCalls = 0
    var updateSeconds = 0.0
    var planSeconds = 0.0
    var plannedTiles = 0
}

extension HeightfieldRenderCache {
    /// Counters summed over all bodies' GPU state.
    var benchTotals: HeightfieldBenchTotals {
        var totals = HeightfieldBenchTotals()
        for state in states.values {
            totals.uploadedBytes += state.uploadedBytes
            totals.drawCalls += state.drawCounter.count
            totals.updateSeconds += state.lastUpdateSeconds
            totals.planSeconds += state.lastPlanSeconds
            totals.plannedTiles += state.lastPlan?.tileCount ?? 0
        }
        return totals
    }
}

/// One frame being recorded: where it started and which sample it fills.
final class BenchFrame {
    let started = DispatchTime.now().uptimeNanoseconds
    let before: HeightfieldBenchTotals
    var index = -1
    var epoch = 0

    init(before: HeightfieldBenchTotals) { self.before = before }
}

/// Collects `ViewportFrameSample`s while recording; the GPU time arrives from the command
/// buffer's completion handler on another thread, hence the lock. Each `start()` opens a new
/// epoch, so a frame still in flight from an earlier one cannot write into the new samples.
final class RendererBenchMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var epoch = 0
    private var samples: [ViewportFrameSample] = []
    private var pendingGPU = 0
    private var buildCount = 0
    private var encodedCount = 0

    /// Times a body's vertex/index buffers were built or rebuilt since the renderer was created.
    var bodyBufferBuilds: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCount
    }

    /// Recorded frames whose command buffer has not completed yet.
    var framesInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingGPU
    }

    /// Frames `encodeFrame` has started since the renderer was created (recording or not).
    var framesEncoded: Int {
        lock.lock()
        defer { lock.unlock() }
        return encodedCount
    }

    func countBodyBufferBuild() {
        lock.lock()
        buildCount += 1
        lock.unlock()
    }

    /// Starts recording into an empty sample list.
    func start() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        pendingGPU = 0
        epoch += 1
        recording = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        recording = false
        lock.unlock()
    }

    /// The samples so far, and whether every recorded frame's GPU time has arrived.
    func snapshot() -> (samples: [ViewportFrameSample], complete: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, pendingGPU == 0)
    }

    /// Returns the samples so far and keeps recording into a fresh list. GPU times of frames
    /// still in flight are lost (they read 0).
    func restart() -> [ViewportFrameSample] {
        lock.lock()
        let taken = samples
        samples.removeAll(keepingCapacity: true)
        pendingGPU = 0
        epoch += 1
        recording = true
        lock.unlock()
        return taken
    }

    /// Called first in `encodeFrame`; `nil` when nothing is recording.
    @MainActor
    func begin(heightfields: HeightfieldRenderCache) -> BenchFrame? {
        lock.lock()
        encodedCount += 1
        let on = recording
        lock.unlock()
        return on ? BenchFrame(before: heightfields.benchTotals) : nil
    }

    /// Reserves the frame's sample and has `commandBuffer` fill in its GPU time. Call before
    /// `commit()`.
    func attach(_ frame: BenchFrame?, to commandBuffer: MTLCommandBuffer) {
        guard let frame else { return }
        lock.lock()
        frame.epoch = epoch
        frame.index = samples.count
        samples.append(ViewportFrameSample())
        pendingGPU += 1
        lock.unlock()
        let index = frame.index
        let frameEpoch = frame.epoch
        commandBuffer.addCompletedHandler { [self] buffer in
            lock.lock()
            if frameEpoch == epoch, index < samples.count {
                samples[index].gpuSeconds = buffer.gpuEndTime - buffer.gpuStartTime
                samples[index].gpuEndTime = buffer.gpuEndTime
                pendingGPU -= 1
            }
            lock.unlock()
        }
    }

    /// Called after `commit()`: fills in the CPU side of the frame's sample.
    @MainActor
    func finish(_ frame: BenchFrame?, heightfields: HeightfieldRenderCache) {
        guard let frame, frame.index >= 0 else { return }
        let encode = Double(DispatchTime.now().uptimeNanoseconds - frame.started) * 1e-9
        let after = heightfields.benchTotals
        lock.lock()
        if frame.epoch == epoch, frame.index < samples.count {
            samples[frame.index].encodeSeconds = encode
            samples[frame.index].heightfieldUploadedBytes =
                after.uploadedBytes - frame.before.uploadedBytes
            samples[frame.index].heightfieldTilesDrawn = after.plannedTiles
            samples[frame.index].heightfieldDrawCalls = after.drawCalls - frame.before.drawCalls
            samples[frame.index].heightfieldUpdateSeconds = after.updateSeconds
            samples[frame.index].heightfieldPlanSeconds = after.planSeconds
        }
        lock.unlock()
    }
}
