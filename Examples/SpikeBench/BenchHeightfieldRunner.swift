// BenchHeightfieldRunner.swift
// The spike notes' "on-device session" checklist, items 1 to 4, run without interaction:
//
//   1. GPU frame time for an orbiting camera at mesh-cell targets 2, 3, 4, 6 and 8 px, MSAA 4 and 1.
//   2. The same with shadows + SSAO + silhouettes on.
//   3. 200 replace() calls of 130 x 120 cells per frame, sliding and disjoint: replace CPU time,
//      uploaded bytes, frame GPU time (and 1 and 50 edits for the curve).
//   4. float16 against float32 heights.
//
// Frames are rendered off-screen through the live renderer's own draw path
// (`ViewportRenderer.benchRenderFrames`), queued back to back with at most three in flight, so the
// GPU never sits idle between frames and its clock stays up (issue #238). Each figure is the median
// of `frames` frames after `warmup` frames that are thrown away. Build in Release for any number
// you intend to quote.

import OCCTSwiftViewport
import SwiftUI

@_spi(Bench) import OCCTSwiftViewport

@MainActor
final class BenchHeightfieldRunner {

    struct Options {
        var width = 1668
        var height = 1194
        var warmup = 30
        var frames = 150
        /// Runs the cases in reverse order, to tell an ordering effect from a configuration one.
        var reverse = false
    }

    /// Everything that needs a new renderer (and a new field) when it changes. The mesh-cell
    /// target is `ViewportConfiguration.heightfieldMeshCellPixels`, a `let` on the controller, so
    /// it is part of the key: each target gets its own controller and renderer.
    struct SessionKey: Equatable {
        var cellPixels: Float = 4
        var msaa = 4
        var allPasses = false
        var float16 = false
        var picking = false
    }

    struct Case {
        var table: String
        var id: String
        var key = SessionKey()
        var edits = 0
        var pattern = BenchHeightfieldScene.EditPattern.sliding
        /// Keep the previous case's renderer and field (with whatever edits it holds) instead of
        /// building new ones. Every case starts from the pristine terrain unless it asks for this.
        var reuse = false
    }

    /// Medians and means over the measured frames.
    struct Measure {
        /// Time between consecutive frames finishing, with frames queued back to back: what one
        /// frame costs in steady state, whichever of the GPU and the CPU is slower. Median, the
        /// fast end (10th percentile) and the slow end (95th).
        var frame: Double
        var frame10: Double
        var frame95: Double
        /// `gpuEndTime - gpuStartTime` of each frame's command buffer, median. With frames
        /// overlapping in the queue this runs above the frame time.
        var gpu: Double
        var encode: Double
        var update: Double
        var plan: Double
        var replace: Double
        var uploadMB: Double
        var tiles: Double
        var draws: Double
        var frames: Int
        var gpuFrames: Int
        /// The frame time over the first and the last third of the measured frames: a drift
        /// within one window (the GPU slowing down) shows as the two differing.
        var firstThird: Double
        var lastThird: Double
    }

    private final class BodyBox: @unchecked Sendable {
        var bodies: [ViewportBody] = []
    }

    private struct Session {
        var key: SessionKey
        var controller: ViewportController
        var renderer: ViewportRenderer
        var field: Heightfield
        var box: BodyBox
    }

    private let options: Options
    private let heights: [Float]
    private var session: Session?

    init(options: Options) {
        self.options = options
        heights = BenchHeightfieldScene.terrainHeights()
    }

    // MARK: Sessions

    /// Why the last session could not be made, for the report.
    private var failure: String?

    private func makeSession(_ key: SessionKey) -> Session? {
        var config = ViewportConfiguration()
        config.msaaSampleCount = key.msaa
        config.heightfieldMeshCellPixels = key.cellPixels
        config.enableSilhouettes = key.allPasses
        config.backgroundColor = SIMD4(0.12, 0.12, 0.14, 1)
        config.pickingConfiguration = PickingConfiguration(isEnabled: key.picking)
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = key.allPasses
        lighting.enableSSAO = key.allPasses
        config.lightingConfiguration = lighting
        let controller = ViewportController(configuration: config)
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        let field: Heightfield
        do {
            field = try BenchHeightfieldScene.makeField(
                heights: heights, float16: key.float16, rampPainted: false, tracksIDs: false)
        } catch {
            // HeightfieldError: nothing to draw, so no session.
            failure = "Heightfield init threw: \(error)"
            return nil
        }
        let box = BodyBox()
        box.bodies = [BenchHeightfieldScene.body(field)]
        guard
            let renderer = ViewportRenderer(
                controller: controller,
                bodies: Binding(get: { box.bodies }, set: { box.bodies = $0 }))
        else { return nil }
        return Session(
            key: key, controller: controller, renderer: renderer, field: field, box: box)
    }

    /// A new renderer and field for `c`, so every case starts from the same terrain, unless it
    /// asks (`reuse`) to carry on with the previous one.
    private func session(for c: Case) -> Session? {
        if c.reuse, let session, session.key == c.key { return session }
        session = nil  // release the old renderer and its textures first
        session = makeSession(c.key)
        return session
    }

    // MARK: One case

    private func measure(_ c: Case, in s: Session) async -> Measure {
        let renderer = s.renderer
        let load = c.edits > 0
            ? BenchHeightfieldScene.EditLoad(count: c.edits, pattern: c.pattern, field: s.field)
            : nil
        let warmup = options.warmup
        var replaceMs: [Double] = []
        renderer.benchStartRecording()
        renderer.benchRenderFrames(
            count: warmup + options.frames, width: options.width, height: options.height,
            backgroundColor: SIMD4(0.12, 0.12, 0.14, 1),
            shouldStop: { RunControl.shared.cancelled }
        ) { frame in
            // Keep two frames queued, not all of them: the GPU always has the next one to start.
            while renderer.benchFramesInFlight >= 2 { usleep(50) }
            s.controller.animateTo(BenchHeightfieldScene.orbitCamera(frame: frame), duration: 0)
            if let load {
                let start = DispatchTime.now().uptimeNanoseconds
                load.apply(to: s.field, frame: frame)
                if frame >= warmup {
                    replaceMs.append(Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-6)
                }
            }
        }
        let samples = Array(await renderer.benchStopRecording().dropFirst(warmup))
        func values(_ f: (ViewportFrameSample) -> Double) -> [Double] { samples.map(f) }
        let gpu = values { $0.gpuSeconds * 1e3 }.filter { $0 > 0 }
        let ends = values { $0.gpuEndTime }
        var intervals: [Double] = []
        for i in ends.indices.dropFirst() where ends[i] > 0 && ends[i - 1] > 0 {
            intervals.append((ends[i] - ends[i - 1]) * 1e3)
        }
        let third = max(intervals.count / 3, 1)
        return Measure(
            frame: Stats.median(intervals), frame10: Stats.percentile(intervals, 0.10),
            frame95: Stats.percentile(intervals, 0.95), gpu: Stats.median(gpu),
            encode: Stats.median(values { $0.encodeSeconds * 1e3 }),
            update: Stats.median(values { $0.heightfieldUpdateSeconds * 1e3 }),
            plan: Stats.median(values { $0.heightfieldPlanSeconds * 1e3 }),
            replace: Stats.mean(replaceMs),
            uploadMB: Stats.mean(values { Double($0.heightfieldUploadedBytes) }) / 1_048_576,
            tiles: Stats.median(values { Double($0.heightfieldTilesDrawn) }),
            draws: Stats.median(values { Double($0.heightfieldDrawCalls) }),
            frames: samples.count, gpuFrames: gpu.count,
            firstThird: Stats.median(Array(intervals.prefix(third))),
            lastThird: Stats.median(Array(intervals.suffix(third))))
    }

    // MARK: Everything

    func runAll(report: BenchReport, status: (String) -> Void) async {
        let o = options
        func cell(_ value: Double) -> String { ms(value) }

        // Table 1 and 2: GPU time by mesh-cell target, without and with the extra passes.
        let gpuTable = "139.gpu"
        report.table(
            gpuTable,
            title: "#139 frame time by mesh-cell target (frames back to back; frame = interval between frames finishing), \(o.width)x\(o.height), orbiting camera, no edits",
            columns: [
                "passes", "msaa", "cell px", "frame med", "frame p10", "frame p95", "gpu span", "cpu encode", "plan", "tiles",
                "draws/frame", "frames",
            ])
        let repeatTable = "139.repeat"
        report.table(
            repeatTable,
            title: "#139 the same 4 px, MSAA 4, shaded-only scene measured again: at the start, fresh at the end, in one session, and after edits",
            columns: [
                "what", "frame med", "first third", "last third", "frame p10", "gpu span", "seconds into run",
            ])
        var cases: [Case] = []
        cases.append(Case(table: repeatTable, id: "anchor.start"))
        cases.append(
            Case(table: repeatTable, id: "anchor.all.start", key: SessionKey(allPasses: true)))
        let targets: [Float] = [2, 3, 4, 6, 8]
        for allPasses in [false, true] {
            for msaa in [4, 1] {
                for px in targets {
                    cases.append(
                        Case(
                            table: gpuTable,
                            id: "\(allPasses ? "all" : "plain").msaa\(msaa).px\(Int(px))",
                            key: SessionKey(cellPixels: px, msaa: msaa, allPasses: allPasses)))
                }
            }
        }
        // Edits.
        let editTable = "139.edits"
        report.table(
            editTable,
            title: "#139 replace() load, regions of 130x120 cells per frame, 4 px cells, MSAA 4",
            columns: [
                "edits/frame", "pattern", "replace CPU", "cpu encode", "update CPU",
                "upload MB/frame", "frame med", "frame p10", "frame over none", "gpu span", "holds 16.6 ms",
            ])
        cases.append(Case(table: editTable, id: "e0"))
        for pattern in BenchHeightfieldScene.EditPattern.allCases {
            for edits in [1, 50, 200] {
                cases.append(
                    Case(table: editTable, id: "e\(edits).\(pattern.rawValue)", edits: edits, pattern: pattern))
            }
        }
        // Precision.
        let precisionTable = "139.precision"
        report.table(
            precisionTable, title: "#139 float16 against float32 heights, 4 px cells, MSAA 4",
            columns: [
                "precision", "edits/frame", "frame med", "frame p10", "gpu span", "upload MB/frame",
                "replace CPU", "cpu encode",
            ])
        for float16 in [false, true] {
            for edits in [0, 200] {
                cases.append(
                    Case(
                        table: precisionTable,
                        id: "\(float16 ? "f16" : "f32").e\(edits)",
                        key: SessionKey(float16: float16), edits: edits, pattern: .disjoint))
            }
        }
        // Pick pass.
        let pickTable = "139.pick"
        report.table(
            pickTable, title: "#139 cost of the pick pass (picking enabled), 4 px cells, MSAA 4",
            columns: ["pick pass", "frame med", "frame p10", "gpu span", "cpu encode", "draws/frame"])
        for picking in [false, true] {
            cases.append(
                Case(table: pickTable, id: picking ? "on" : "off", key: SessionKey(picking: picking)))
        }

        // The same scene again, to separate position in the run from configuration.
        for n in 1...3 { cases.append(Case(table: repeatTable, id: "fresh\(n).end")) }
        cases.append(Case(table: repeatTable, id: "oneSession.1"))
        for n in 2...3 {
            cases.append(Case(table: repeatTable, id: "oneSession.\(n)", reuse: true))
        }
        cases.append(
            Case(
                table: repeatTable, id: "edited.200disjoint", edits: 200, pattern: .disjoint))
        cases.append(Case(table: repeatTable, id: "edited.then0edits", reuse: true))
        cases.append(
            Case(table: repeatTable, id: "anchor.all.end", key: SessionKey(allPasses: true)))
        if o.reverse { cases.reverse() }

        var noEditGPU: Double?
        var stopped: String?
        let runStart = DispatchTime.now().uptimeNanoseconds
        for (index, c) in cases.enumerated() {
            if RunControl.shared.cancelled {
                stopped = "cancelled before case \(index + 1) of \(cases.count) (\(c.table) \(c.id))"
                break
            }
            status("#139 \(index + 1)/\(cases.count): \(c.table) \(c.id)")
            await Task.yield()
            guard let s = session(for: c) else {
                report.note("no renderer for \(c.id): \(failure ?? "ViewportRenderer.init returned nil")")
                continue
            }
            let m = await measure(c, in: s)
            switch c.table {
            case gpuTable:
                report.row(
                    gpuTable, c.id,
                    [
                        c.key.allPasses ? "shadows+SSAO+silhouettes" : "shaded only",
                        "\(c.key.msaa)", "\(Int(c.key.cellPixels))", cell(m.frame), cell(m.frame10),
                        cell(m.frame95), cell(m.gpu),
                        cell(m.encode), cell(m.plan), "\(Int(m.tiles))", "\(Int(m.draws))",
                        "\(m.gpuFrames)",
                    ])
            case editTable:
                if c.edits == 0 { noEditGPU = m.frame }
                report.row(
                    editTable, c.id,
                    [
                        "\(c.edits)", c.edits == 0 ? "-" : c.pattern.rawValue, cell(m.replace),
                        cell(m.encode), cell(m.update), String(format: "%.2f", m.uploadMB),
                        cell(m.frame), cell(m.frame10), noEditGPU.map { cell(m.frame - $0) } ?? "-",
                        cell(m.gpu), m.frame < 16.6 ? "yes" : "NO",
                    ])
            case precisionTable:
                report.row(
                    precisionTable, c.id,
                    [
                        c.key.float16 ? "float16" : "float32", "\(c.edits)", cell(m.frame),
                        cell(m.frame10), cell(m.gpu), String(format: "%.2f", m.uploadMB),
                        cell(m.replace), cell(m.encode),
                    ])
            case repeatTable:
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - runStart) * 1e-9
                report.row(
                    repeatTable, c.id,
                    [
                        c.id, cell(m.frame), cell(m.firstThird), cell(m.lastThird),
                        cell(m.frame10), cell(m.gpu), String(format: "%.0f", elapsed),
                    ])
            default:
                report.row(
                    pickTable, c.id,
                    [c.id, cell(m.frame), cell(m.frame10), cell(m.gpu), cell(m.encode), "\(Int(m.draws))"])
            }
        }
        session = nil

        // Heightfield.raycast: the exact re-cast that ViewportController.refinePick does for each
        // tap (MetalViewportView applies it to every tap). Timed on the CPU, 200 casts per ray.
        let rayTable = "139.refine"
        report.table(
            rayTable,
            title: "#139 Heightfield.raycast, the re-cast behind refinePick, 2000 x 2000 field, 200 casts per ray",
            columns: ["ray", "result", "median us", "max us"])
        if stopped == nil {
            do {
                let field = try BenchHeightfieldScene.makeField(
                    heights: heights, float16: false, rampPainted: false, tracksIDs: false)
                let rays: [(String, SIMD3<Float>, SIMD3<Float>)] = [
                    ("top-down", SIMD3(1000.3, 1000.7, 500), SIMD3(0, 0, -1)),
                    ("grazing, along the field", SIMD3(-5, 1000.3, 70), SIMD3(1, 0.0004, -0.02)),
                    ("oblique, from a corner", SIMD3(-300, -300, 700), SIMD3(1, 1, -0.45)),
                ]
                for (name, origin, direction) in rays {
                    var micros: [Double] = []
                    var result = "miss"
                    for i in 0..<200 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let hit = field.raycast(origin: origin, direction: direction)
                        micros.append(Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-3)
                        if i == 0, let hit { result = "cell (\(hit.cell.x), \(hit.cell.y))" }
                    }
                    report.row(
                        rayTable, name,
                        [
                            name, result, String(format: "%.1f", Stats.median(micros)),
                            String(format: "%.1f", micros.max() ?? 0),
                        ])
                }
            } catch {
                report.note("raycast rows skipped: \(error)")
            }
        }
        // Under every table: how the run went. These are off-screen frames, so the window being
        // hidden does not matter here, but a second copy of the app on the GPU does.
        let other = RunEnvironment.otherInstances()
        for table in [gpuTable, editTable, precisionTable, pickTable, repeatTable, rayTable] {
            report.footer(
                table,
                "off-screen frames, back to back (window state does not matter); other SpikeBench instances running: "
                    + (other.isEmpty ? "none" : "\(other.count) CONTAMINATED, quit them and rerun"))
            if let stopped { report.footer(table, "RUN STOPPED: \(stopped)") }
        }
        if let stopped { report.note("#139 stopped: \(stopped)") }
        status(stopped == nil ? "#139 done" : "#139 stopped")
    }
}
