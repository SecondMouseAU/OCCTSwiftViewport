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
    }

    /// Everything that needs a new renderer (and a new field) when it changes.
    struct SessionKey: Equatable {
        var msaa = 4
        var allPasses = false
        var float16 = false
        var picking = false
    }

    struct Case {
        var table: String
        var id: String
        var key = SessionKey()
        var targetPixels: Float = 4
        var edits = 0
        var pattern = BenchHeightfieldScene.EditPattern.sliding
    }

    /// Medians and means over the measured frames.
    struct Measure {
        var gpu: Double
        var gpu95: Double
        var encode: Double
        var update: Double
        var plan: Double
        var replace: Double
        var uploadMB: Double
        var tiles: Double
        var draws: Double
        var frames: Int
        var gpuFrames: Int
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

    private func makeSession(_ key: SessionKey) -> Session? {
        var config = ViewportConfiguration()
        config.msaaSampleCount = key.msaa
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
        let field = BenchHeightfieldScene.makeField(
            heights: heights, float16: key.float16, rampPainted: false, tracksIDs: false)
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

    private func session(for key: SessionKey) -> Session? {
        if let session, session.key == key { return session }
        session = nil  // release the old renderer and its textures first
        session = makeSession(key)
        return session
    }

    // MARK: One case

    private func measure(_ c: Case, in s: Session) async -> Measure {
        let renderer = s.renderer
        renderer.benchHeightfieldTargetPixels = c.targetPixels
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
            // Keep a few frames queued, not all of them; never wait while the GPU has no work.
            while renderer.benchFramesInFlight >= 3 { usleep(50) }
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
        return Measure(
            gpu: Stats.median(gpu), gpu95: Stats.percentile(gpu, 0.95),
            encode: Stats.median(values { $0.encodeSeconds * 1e3 }),
            update: Stats.median(values { $0.heightfieldUpdateSeconds * 1e3 }),
            plan: Stats.median(values { $0.heightfieldPlanSeconds * 1e3 }),
            replace: Stats.mean(replaceMs),
            uploadMB: Stats.mean(values { Double($0.heightfieldUploadedBytes) }) / 1_048_576,
            tiles: Stats.median(values { Double($0.heightfieldTilesDrawn) }),
            draws: Stats.median(values { Double($0.heightfieldDrawCalls) }),
            frames: samples.count, gpuFrames: gpu.count)
    }

    // MARK: Everything

    func runAll(report: BenchReport, status: (String) -> Void) async {
        let o = options
        func cell(_ value: Double) -> String { ms(value) }

        // Table 1 and 2: GPU time by mesh-cell target, without and with the extra passes.
        let gpuTable = "139.gpu"
        report.table(
            gpuTable,
            title: "#139 GPU frame time by mesh-cell target, \(o.width)x\(o.height), orbiting camera, no edits",
            columns: [
                "passes", "msaa", "cell px", "gpu med", "gpu p95", "cpu encode", "plan", "tiles",
                "draws/frame", "frames",
            ])
        var cases: [Case] = []
        let targets: [Float] = [2, 3, 4, 6, 8]
        for allPasses in [false, true] {
            for msaa in [4, 1] {
                for px in targets {
                    cases.append(
                        Case(
                            table: gpuTable,
                            id: "\(allPasses ? "all" : "plain").msaa\(msaa).px\(Int(px))",
                            key: SessionKey(msaa: msaa, allPasses: allPasses), targetPixels: px))
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
                "upload MB/frame", "gpu med", "gpu over none", "holds 16.6 ms",
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
            columns: ["precision", "edits/frame", "gpu med", "upload MB/frame", "replace CPU", "cpu encode"])
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
            columns: ["pick pass", "gpu med", "cpu encode", "draws/frame"])
        for picking in [false, true] {
            cases.append(
                Case(table: pickTable, id: picking ? "on" : "off", key: SessionKey(picking: picking)))
        }

        var noEditGPU: Double?
        var stopped: String?
        for (index, c) in cases.enumerated() {
            if RunControl.shared.cancelled {
                stopped = "cancelled before case \(index + 1) of \(cases.count) (\(c.table) \(c.id))"
                break
            }
            status("#139 \(index + 1)/\(cases.count): \(c.table) \(c.id)")
            await Task.yield()
            guard let s = session(for: c.key) else {
                report.note("renderer unavailable for \(c.id)")
                continue
            }
            let m = await measure(c, in: s)
            switch c.table {
            case gpuTable:
                report.row(
                    gpuTable, c.id,
                    [
                        c.key.allPasses ? "shadows+SSAO+silhouettes" : "shaded only",
                        "\(c.key.msaa)", "\(Int(c.targetPixels))", cell(m.gpu), cell(m.gpu95),
                        cell(m.encode), cell(m.plan), "\(Int(m.tiles))", "\(Int(m.draws))",
                        "\(m.gpuFrames)",
                    ])
            case editTable:
                if c.edits == 0 { noEditGPU = m.gpu }
                let cpu = m.replace + m.encode
                report.row(
                    editTable, c.id,
                    [
                        "\(c.edits)", c.edits == 0 ? "-" : c.pattern.rawValue, cell(m.replace),
                        cell(m.encode), cell(m.update), String(format: "%.2f", m.uploadMB),
                        cell(m.gpu), noEditGPU.map { cell(m.gpu - $0) } ?? "-",
                        max(cpu, m.gpu) < 16.6 ? "yes" : "NO",
                    ])
            case precisionTable:
                report.row(
                    precisionTable, c.id,
                    [
                        c.key.float16 ? "float16" : "float32", "\(c.edits)", cell(m.gpu),
                        String(format: "%.2f", m.uploadMB), cell(m.replace), cell(m.encode),
                    ])
            default:
                report.row(
                    pickTable, c.id,
                    [c.id, cell(m.gpu), cell(m.encode), "\(Int(m.draws))"])
            }
        }
        session = nil
        // Under every table: how the run went. These are off-screen frames, so the window being
        // hidden does not matter here, but a second copy of the app on the GPU does.
        let other = RunEnvironment.otherInstances()
        for table in [gpuTable, editTable, precisionTable, pickTable] {
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
