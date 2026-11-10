// Bench141Model.swift
// Issue #141: drives a real MetalViewportView with a body that moves every frame, and measures
// what that costs the main thread.
//
// What "frame cost" means here. Each display-link tick (60 Hz) the model changes the bodies the
// view is given. SwiftUI then re-evaluates the view and the MTKView's draw callback encodes the
// frame, all on the main thread. `MainThreadMeter` totals the main thread's CPU time across those
// run-loop turns, so the figure per tick is everything the app's main thread did for one frame:
// the mutation, the SwiftUI update, the renderer's encode and Core Animation's commit. The
// renderer's own encode time comes from the library's Bench hook, so the two can be compared.
// The "static" rows are the same scene with the bodies left alone, so a row's cost over the static
// row is what the update path adds.

import OCCTSwiftViewport
import SwiftUI
import simd

@_spi(Bench) import OCCTSwiftViewport

/// What the control panel shows. Kept apart from the model so that the bodies changing every
/// frame invalidates only the viewport's host view, as it would in an app, not the panel.
@MainActor
final class Bench141PanelState: ObservableObject {
    @Published var mutation: Bench141Model.Mutation = .none
    @Published var isTicking = false
    @Published var readout = "stopped"
    @Published var status = ""
    /// While a table is measured the panel shrinks to a plain status line.
    @Published var measuring = false
}

/// Owns the bodies the viewport draws. Only `bodies` is published, so the only view that
/// observes this object is the one hosting `MetalViewportView`.
@MainActor
final class Bench141Model: ObservableObject {

    /// How the bodies change each frame.
    enum Mutation: String, CaseIterable, Identifiable {
        case none = "static"
        case inPlace = "in place"
        case copyAssign = "copy + assign"
        case reassign = "reassign only"
        case reassignAndMutate = "reassign + mutate"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .none: "bodies untouched: the cost of drawing"
            case .inPlace: "bodies[0].transform = m"
            case .copyAssign: "var next = bodies; next[0].transform = m; bodies = next"
            case .reassign: "bodies = bodies.map { $0 }  (no change at all)"
            case .reassignAndMutate: "bodies = bodies.map { $0 } with next[0].transform = m"
            }
        }
    }

    /// One measured window.
    struct Window {
        var bodyCount: Int
        var mutation: Mutation
        /// Main-thread CPU milliseconds per tick.
        var mainCPU: [Double]
        var samples: [ViewportFrameSample]
        var ticks: Int
        var rebuilds: Int
        var generationBefore: UInt64
        var generationAfter: UInt64
        var stalled: Bool
        /// The viewport drew fewer than half the frames the window lasted.
        var drewShort: Bool
    }

    /// Why a window could not be measured.
    enum Failure: Error {
        case noRenderer
        case notDrawing(drawn: Int, expected: Int)
        case cancelled

        var message: String {
            switch self {
            case .noRenderer:
                "the viewport never appeared (no renderer after 10 s). Is the SpikeBench window on screen?"
            case .notDrawing(let drawn, let expected):
                "the viewport drew \(drawn) of \(expected) warm-up frames, so nothing can be measured. "
                    + "A window that is hidden, minimised, on another Space or completely covered is not drawn by the system. "
                    + "Keep SpikeBench frontmost and uncovered while a #141 run is in progress."
            case .cancelled:
                "cancelled"
            }
        }
    }

    @Published var bodies: [ViewportBody] = []
    let panel = Bench141PanelState()

    var mutation: Mutation {
        get { panel.mutation }
        set { panel.mutation = newValue }
    }
    private var isTicking: Bool {
        get { panel.isTicking }
        set { panel.isTicking = newValue }
    }
    private var readout: String {
        get { panel.readout }
        set { panel.readout = newValue }
    }
    private var lastMutation = Mutation.none

    let controller: ViewportController
    private let ticker = FrameTicker()
    private let meter = MainThreadMeter()
    private var phase = 0.0
    private var lastCPU: UInt64?
    private var ticks = 0
    private var collecting = false
    private var windowCPU: [Double] = []
    private var liveCPU: [Double] = []
    private var measuring = false
    /// Whether the window was visible and key on every tick of the measured windows.
    let visibility = VisibilityLog()
    private var onTick: (@MainActor (Int) -> Void)?

    init() {
        var config = ViewportConfiguration()
        config.preferredFramesPerSecond = 60
        controller = ViewportController(configuration: config)
        load(count: 21)
    }

    var renderer: ViewportRenderer? { controller.benchRenderer }

    func setStatus(_ text: String) { panel.status = text }

    // MARK: Scene

    func load(count: Int) {
        stopTicking()
        bodies = Bench141Scene.bodies(count: count)
        if let camera = CameraState.isometric.fit(to: bodies, aspectRatio: 1.6, padding: 1.4) {
            controller.animateTo(camera, duration: 0)
        }
    }

    // MARK: Ticking

    func startTicking() {
        guard !ticker.isRunning else { return }
        lastCPU = nil
        ticks = 0
        liveCPU = []
        isTicking = true
        ticker.start(framesPerSecond: 60) { [weak self] in self?.tick() }
    }

    func stopTicking() {
        ticker.stop()
        isTicking = false
        if !measuring { readout = "stopped" }
    }

    private func resetLiveWindow() {
        liveCPU = []
        lastCPU = nil
    }

    private func tick() {
        // The CPU spent since the previous tick: the previous tick's mutation, the SwiftUI update
        // and draw callbacks that followed it, and Core Animation's commit.
        let cpu = meter.totalNanos()
        if lastMutation != panel.mutation {
            lastMutation = panel.mutation
            resetLiveWindow()
        }
        if let lastCPU {
            let delta = Double(cpu &- lastCPU) / 1e6
            if collecting {
                windowCPU.append(delta)
                visibility.sample()
            }
            liveCPU.append(delta)
            if liveCPU.count > 120 { liveCPU.removeFirst(liveCPU.count - 120) }
        }
        lastCPU = cpu
        ticks += 1
        applyMutation()
        onTick?(ticks)
        if !measuring, ticks % 30 == 0 { publishLiveReadout() }
    }

    private func applyMutation() {
        phase += 0.05
        let transform = Bench141Scene.moverTransform(phase: phase)
        switch mutation {
        case .none:
            break
        case .inPlace:
            bodies[0].transform = transform
        case .copyAssign:
            var next = bodies
            next[0].transform = transform
            bodies = next
        case .reassign:
            bodies = bodies.map { $0 }
        case .reassignAndMutate:
            var next = bodies.map { $0 }
            next[0].transform = transform
            bodies = next
        }
    }

    private func publishLiveReadout() {
        guard let renderer else {
            readout = "waiting for the viewport"
            return
        }
        let samples = renderer.benchRestartRecording()
        let encode = Stats.median(samples.map { $0.encodeSeconds * 1e3 }.filter { $0 > 0 })
        let gpu = Stats.median(samples.map { $0.gpuSeconds * 1e3 }.filter { $0 > 0 })
        readout = String(
            format:
                "main thread %@ ms/frame (median of %d)  encode %@  gpu %@ (paced, idle-clocked)  buffer builds %d  generation %llu",
            ms(Stats.median(liveCPU)), liveCPU.count, ms(encode), ms(gpu),
            renderer.benchBodyBufferBuilds, bodies.first?.generation ?? 0)
        if LaunchOptions.current.logLive {
            print("BENCH-LIVE 141 | \(readout)")
            fflush(stdout)
        }
    }

    // MARK: Measuring

    private func waitForRenderer() async -> ViewportRenderer? {
        for _ in 0..<200 {
            if let renderer { return renderer }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    /// Waits for `count` more ticks, or gives up after a generous multiple of the time they
    /// should take (the display link may not be running).
    private func waitTicks(_ count: Int) async -> Bool {
        let target = ticks + count
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            onTick = { [weak self] current in
                if current >= target || RunControl.shared.cancelled, !flag.done {
                    flag.done = true
                    self?.onTick = nil
                    continuation.resume(returning: !RunControl.shared.cancelled)
                }
            }
            let patience = UInt64(max(5.0, Double(count) / 60.0 * 4.0) * 1e9)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: patience)
                if !flag.done {
                    flag.done = true
                    self?.onTick = nil
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func checkCancelled() throws {
        if RunControl.shared.cancelled {
            stopTicking()
            throw Failure.cancelled
        }
    }

    /// Runs `mutation` for `warmup` ticks, then measures `frames` ticks.
    ///
    /// Throws when the viewport is not drawing (the warm-up records far fewer frames than ticks),
    /// rather than returning an empty window.
    func measure(mutation: Mutation, warmup: Int, frames: Int) async throws -> Window {
        guard let renderer = await waitForRenderer() else { throw Failure.noRenderer }
        try checkCancelled()
        measuring = true
        defer { measuring = false }
        stopTicking()
        self.mutation = mutation
        renderer.benchStartRecording()
        startTicking()
        let warmed = await waitTicks(warmup)
        try checkCancelled()
        // The frames the viewport drew while warming up: none means the window is not being drawn.
        let warmFrames = renderer.benchRestartRecording().count
        if warmFrames < max(1, warmup / 4) {
            stopTicking()
            throw Failure.notDrawing(drawn: warmFrames, expected: warmup)
        }

        windowCPU = []
        let rebuildsBefore = renderer.benchBodyBufferBuilds
        let generationBefore = bodies[0].generation
        collecting = true
        let finished = await waitTicks(frames)
        collecting = false
        let samples = await renderer.benchStopRecording()
        let generationAfter = bodies[0].generation
        let rebuilds = renderer.benchBodyBufferBuilds - rebuildsBefore
        stopTicking()
        try checkCancelled()
        return Window(
            bodyCount: bodies.count, mutation: mutation, mainCPU: windowCPU, samples: samples,
            ticks: frames, rebuilds: rebuilds, generationBefore: generationBefore,
            generationAfter: generationAfter, stalled: !(warmed && finished),
            drewShort: samples.count < frames / 2)
    }

    /// Replaces body 1's geometry once, which must take a new generation and rebuild exactly one
    /// body: proof that the rebuild counter can move.
    func geometryChangeControl() async -> (rebuilds: Int, generationChanged: Bool)? {
        guard let renderer = await waitForRenderer(), bodies.count > 1 else { return nil }
        measuring = true
        defer { measuring = false }
        stopTicking()
        mutation = .none
        let before = renderer.benchBodyBufferBuilds
        let generation = bodies[1].generation
        var vertices = bodies[1].vertexData
        vertices[0] += 0.001
        bodies[1].vertexData = vertices
        startTicking()
        _ = await waitTicks(10)
        stopTicking()
        return (renderer.benchBodyBufferBuilds - before, bodies[1].generation != generation)
    }
}
