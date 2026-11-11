// ViewportRenderer+Bench.swift
// OCCTSwiftViewport
//
// The benchmark hooks (Examples/SpikeBench) on the live renderer, behind
// `@_spi(Bench) import OCCTSwiftViewport`. Not public API.

import Foundation

extension ViewportController {
    /// The renderer currently drawing this controller's viewport, or `nil` before the view has
    /// appeared.
    @_spi(Bench) public var benchRenderer: ViewportRenderer? { attachedRenderer }
}

extension ViewportRenderer {

    /// Frames the renderer has started encoding since it was created, whether or not recording.
    /// Differences between two reads count the draw callbacks in between.
    @_spi(Bench) public var benchEncodedFrames: Int { benchMetrics.framesEncoded }

    /// Times any body's vertex, normal or index buffers were built or rebuilt since the renderer
    /// was created. A body whose `transform` alone changes must not raise it.
    @_spi(Bench) public var benchBodyBufferBuilds: Int { benchMetrics.bodyBufferBuilds }

    /// Recorded frames whose command buffer has not completed yet (0 while not recording). A
    /// back-to-back loop waits on this to keep a few frames queued rather than all of them.
    @_spi(Bench) public var benchFramesInFlight: Int { benchMetrics.framesInFlight }

    /// Starts recording one `ViewportFrameSample` per frame, discarding earlier ones.
    @_spi(Bench) public func benchStartRecording() { benchMetrics.start() }

    /// Returns the samples recorded so far and carries on recording into a fresh list. The GPU
    /// time of a frame still in flight reads 0.
    @_spi(Bench) public func benchRestartRecording() -> [ViewportFrameSample] {
        benchMetrics.restart()
    }

    /// Stops recording and returns the samples. Waits a moment for the GPU times of frames still
    /// in flight, then returns what it has.
    @_spi(Bench) public func benchStopRecording() async -> [ViewportFrameSample] {
        benchMetrics.stop()
        var result = benchMetrics.snapshot()
        var waited = 0
        while !result.complete, waited < 2000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
            result = benchMetrics.snapshot()
        }
        return result.samples
    }

    /// Renders `count` frames off-screen back to back and returns once the GPU has drained them.
    ///
    /// The frames go through the same `encodeFrame` as the on-screen path, queued without waiting
    /// for each other, so the GPU stays busy the whole time. `beforeFrame` runs ahead of each
    /// (move the camera, edit a heightfield). `shouldStop` is asked before each frame; `true` ends
    /// the run early.
    @_spi(Bench) @discardableResult
    public func benchRenderFrames(
        count: Int, width: Int, height: Int, backgroundColor: SIMD4<Float>,
        shouldStop: () -> Bool = { false }, beforeFrame: (Int) -> Void
    ) -> Bool {
        withoutActuallyEscaping(beforeFrame) { before in
            withoutActuallyEscaping(shouldStop) { stop in
                renderHeadlessBGRA(
                    width: width, height: height, backgroundColor: backgroundColor,
                    frameCount: count, beforeFrame: before, shouldStop: stop) != nil
            }
        }
    }
}
