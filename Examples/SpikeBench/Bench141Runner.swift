// Bench141Runner.swift
// The three measurements issue #141 asks for, as report tables, plus a control.
//
//   1. Frame cost of mutating one body's `transform` at 60 Hz with 20 static bodies, the bodies
//      array re-assigned every frame. Pass line: 1 ms of CPU.
//   2. Whether `generation` survives a transform change and no GPU buffer is re-created.
//   3. Cost of re-assigning a 100-body array every frame.
//   Control. An unrelated @Published Int changes every frame and the bodies are not touched: does
//      the SwiftUI update cost depend on the bodies at all?
//
// Each row counts the draw callbacks the viewport ran per 60 Hz tick. A SwiftUI update of the
// viewport can make the MTKView draw an extra time in the same tick, which adds one more encode
// to that tick's main-thread CPU. So a row is judged on its ticks that held exactly ONE draw (the
// cost of one update and one draw) when it has enough of them, and says so; the all-ticks median
// is shown beside it.
//
// The measurements need the viewport to be drawing, which the system only does for a window that
// is on screen and unlocked. A run therefore stops with an explicit message, not an empty table,
// when the viewport draws nothing, and each table says whether the window stayed visible.

import OCCTSwiftViewport
import SwiftUI

@_spi(Bench) import OCCTSwiftViewport

extension Bench141Model {

    /// The issue's pass line for case 1, in milliseconds of CPU per frame.
    static let passLineMilliseconds = 1.0
    /// Ticks with exactly one draw that a row needs before its figure is judged on them alone.
    static let minimumSingleDrawTicks = 30

    func runCases(
        report: BenchReport, warmup: Int, frames: Int, status: @escaping (String) -> Void
    ) async {
        panel.measuring = true
        defer { panel.measuring = false }
        visibility.reset()
        func step(_ text: String) {
            setStatus(text)
            status(text)
        }

        let casesTable = "141.cases"
        report.table(
            casesTable,
            title: "#141 frame cost, main-thread CPU ms per 60 Hz tick (\(frames) ticks after \(warmup) warm-up)",
            columns: [
                "bodies", "update", "draws/tick", "ticks by draws 0/1/2/3+", "main med (1 draw)",
                "main med (all)", "main p95 (all)", "renderer encode", "SwiftUI+other",
                "cost over static", "basis", "gpu med", "rebuilds",
            ])

        struct Saved {
            var window: Window
            var all: Double
            var single: Double?
            var encode: Double
        }
        var results: [String: Saved] = [:]
        var aborted: String?
        var rateNotes: [String] = []

        /// The figure a row is judged on against `reference`: the median over ticks with one
        /// draw when both rows have enough of them, else the all-ticks median.
        func compare(_ row: Saved, to reference: Saved?) -> (cost: Double, basis: String)? {
            guard let reference else { return nil }
            if let a = row.single, let b = reference.single { return (a - b, "1-draw ticks") }
            return (row.all - reference.all, "all ticks (*)")
        }

        /// Measures one window and adds its row; on failure records why and stops the run.
        func run(
            _ id: String, _ mutation: Mutation, reference: String?, label: String
        ) async {
            guard aborted == nil else { return }
            step(label)
            do {
                let window = try await measure(mutation: mutation, warmup: warmup, frames: frames)
                let pairs = Array(zip(window.mainCPU, window.drawsPerTick))
                let singles = pairs.filter { $0.1 == 1 }.map(\.0)
                let all = Stats.median(window.mainCPU)
                let single: Double? =
                    singles.count >= Self.minimumSingleDrawTicks ? Stats.median(singles) : nil
                let encode = Stats.median(
                    window.samples.map { $0.encodeSeconds * 1e3 }.filter { $0 > 0 })
                let gpu = Stats.median(window.samples.map { $0.gpuSeconds * 1e3 }.filter { $0 > 0 })
                let saved = Saved(window: window, all: all, single: single, encode: encode)
                let drawsPerTick =
                    Double(window.drawsPerTick.reduce(0, +)) / Double(max(window.ticks, 1))
                if drawsPerTick > 1.1 || drawsPerTick < 0.9 {
                    rateNotes.append("\(id) \(String(format: "%.2f", drawsPerTick))")
                }
                var bins = [0, 0, 0, 0]
                for draws in window.drawsPerTick { bins[min(max(draws, 0), 3)] += 1 }
                let histogram = bins.map(String.init).joined(separator: "/")
                let comparison = compare(saved, to: reference.flatMap { results[$0] })
                var basis = comparison?.basis ?? "-"
                if window.drewShort { basis += " FEW FRAMES DRAWN" }
                if window.stalled { basis += " STALLED" }
                report.row(
                    casesTable, id,
                    [
                        "\(window.bodyCount)", window.mutation.rawValue,
                        String(format: "%.2f", drawsPerTick),
                        histogram, single.map(ms) ?? "-", ms(all),
                        ms(Stats.percentile(window.mainCPU, 0.95)), ms(encode),
                        ms(max(0, (single ?? all) - encode)),
                        comparison.map { ms($0.cost) } ?? "-", basis, ms(gpu),
                        "\(window.rebuilds)",
                    ])
                results[id] = saved
            } catch let failure as Failure {
                aborted = failure.message
            } catch {
                aborted = "\(error)"
            }
        }

        // Scene of 21 bodies: case 1, its static baseline and the control.
        load(count: 21)
        await run("static21", .none, reference: nil, label: "#141: 21 bodies, static")
        let drawable = controller.drawablePixelSize
        report.note(
            "#141 viewport drawable \(Int(drawable.width))x\(Int(drawable.height)) px, MSAA \(controller.configuration.msaaSampleCount), preferredFramesPerSecond \(controller.configuration.preferredFramesPerSecond)"
        )
        await run(
            "control21", .stateOnly, reference: "static21",
            label: "#141 control: unrelated state, 21 bodies")
        await run(
            "case1", .copyAssign, reference: "static21", label: "#141 case 1: copy + assign")
        await run(
            "case1.inPlace", .inPlace, reference: "static21", label: "#141 case 1: in place")

        // Case 2: what the case 1 windows did to generation and buffers.
        let case2 = "141.case2"
        report.table(
            case2, title: "#141 case 2: generation and GPU buffers across a transform change",
            columns: ["observed", "result"])
        for id in ["case1", "case1.inPlace"] {
            guard let w = results[id]?.window else { continue }
            report.row(
                case2, "\(id).generation",
                [
                    w.generationBefore == w.generationAfter
                        ? "generation preserved" : "generation CHANGED",
                    "mover generation \(w.generationBefore) -> \(w.generationAfter)",
                ])
            report.row(
                case2, "\(id).rebuilds",
                [
                    w.rebuilds == 0 ? "no body buffer rebuilt" : "BUFFERS REBUILT",
                    "\(w.rebuilds) rebuilds in \(w.ticks) ticks of 21 bodies",
                ])
        }
        if aborted == nil {
            step("#141 case 2: control")
            if let control = await geometryChangeControl() {
                report.row(
                    case2, "control.geometry",
                    [
                        "a geometry change does rebuild (the counter can move)",
                        "\(control.rebuilds) rebuild, generation changed: \(control.generationChanged)",
                    ])
            }
            report.row(
                case2, "identity",
                [
                    "buffer object identity is internal state",
                    "asserted in the package test BodyTransformUpdateTests (swift test)",
                ])
        }

        // Scene of 100 bodies: case 3, its static baseline and the control.
        if aborted == nil { load(count: 100) }
        await run("static100", .none, reference: nil, label: "#141: 100 bodies, static")
        await run(
            "control100", .stateOnly, reference: "static100",
            label: "#141 control: unrelated state, 100 bodies")
        await run(
            "case3", .reassign, reference: "static100", label: "#141 case 3: reassign only")
        await run(
            "case3.mutate", .reassignAndMutate, reference: "static100",
            label: "#141 case 3: reassign + mutate")

        // Verdict against the issue's pass line.
        let verdict = "141.verdict"
        report.table(
            verdict,
            title: "#141 pass line: \(ms(Self.passLineMilliseconds)) ms CPU per frame for case 1 (21 bodies, one transform changing)",
            columns: ["measure", "ms", "basis", "result"])
        let line = Self.passLineMilliseconds
        func verdictRow(_ id: String, _ text: String, row: String) {
            guard let saved = results[row], let c = compare(saved, to: results["static21"]) else {
                return
            }
            report.row(
                verdict, id, [text, ms(c.cost), c.basis, c.cost < line ? "PASS" : "FAIL"])
        }
        verdictRow("case1.cost", "cost the update adds over static (copy + assign)", row: "case1")
        verdictRow("case1.inPlace.cost", "cost over static (in place)", row: "case1.inPlace")
        verdictRow(
            "control.cost", "cost of an unrelated state change over static (control)",
            row: "control21")
        if let case1 = results["case1"] {
            let whole = case1.single ?? case1.all
            report.row(
                verdict, "case1.total",
                [
                    "whole main-thread tick including drawing", ms(whole),
                    case1.single == nil ? "all ticks (*)" : "1-draw ticks",
                    whole < line ? "PASS" : "FAIL",
                ])
        }

        // How the run went, under every table.
        let other = RunEnvironment.otherInstances()
        for table in [casesTable, case2, verdict] {
            report.footer(table, visibility.summary)
            report.footer(
                table,
                "* a basis marked (*) means a row had fewer than \(Self.minimumSingleDrawTicks) ticks with exactly one draw, so all ticks are compared and any extra draws are included")
            if !rateNotes.isEmpty {
                report.footer(
                    table,
                    "CAUTION draws per 60 Hz tick differ from 1.00 in: \(rateNotes.joined(separator: ", ")). "
                        + "A tick with two draws costs one more encode; the 1-draw columns leave those ticks out.")
            }
            report.footer(
                table,
                other.isEmpty
                    ? "other SpikeBench instances running: none"
                    : "other SpikeBench instances running: \(other.count) (pids \(other.map(String.init).joined(separator: ", "))): CONTAMINATED, quit them and rerun"
            )
            if let aborted { report.footer(table, "RUN STOPPED: \(aborted)") }
        }
        if let aborted { report.note("#141 stopped: \(aborted)") }
        step(aborted == nil ? "#141 done" : "#141 stopped")
    }
}
