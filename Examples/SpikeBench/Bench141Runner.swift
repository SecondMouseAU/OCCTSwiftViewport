// Bench141Runner.swift
// The three measurements issue #141 asks for, as report tables.
//
//   1. Frame cost of mutating one body's `transform` at 60 Hz with 20 static bodies, the bodies
//      array re-assigned every frame. Pass line: 1 ms of CPU.
//   2. Whether `generation` survives a transform change and no GPU buffer is re-created.
//   3. Cost of re-assigning a 100-body array every frame.
//
// The measurements need the viewport to be drawing, which the system only does for a window that
// is on screen. A run therefore stops with an explicit message, not an empty table, when the
// viewport draws nothing, and each table says whether the window stayed visible.

import OCCTSwiftViewport
import SwiftUI

@_spi(Bench) import OCCTSwiftViewport

extension Bench141Model {

    /// The issue's pass line for case 1, in milliseconds of CPU per frame.
    static let passLineMilliseconds = 1.0

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
            title: "#141 frame cost, main-thread CPU ms per 60 Hz frame (\(frames) frames after \(warmup) warm-up)",
            columns: [
                "bodies", "update", "main med", "main p95", "main mean", "renderer encode",
                "SwiftUI+other", "cost over static", "gpu med", "drawn/ticks", "rebuilds",
            ])

        struct Saved {
            var window: Window
            var median: Double
        }
        var results: [String: Saved] = [:]
        var aborted: String?
        var rateNotes: [String] = []

        /// Measures one window and adds its row; on failure records why and stops the run.
        func run(
            _ id: String, _ mutation: Mutation, staticMedian: Double?, label: String
        ) async {
            guard aborted == nil else { return }
            step(label)
            do {
                let window = try await measure(mutation: mutation, warmup: warmup, frames: frames)
                let median = Stats.median(window.mainCPU)
                let encode = Stats.median(
                    window.samples.map { $0.encodeSeconds * 1e3 }.filter { $0 > 0 })
                let gpu = Stats.median(window.samples.map { $0.gpuSeconds * 1e3 }.filter { $0 > 0 })
                let over = staticMedian.map { ms(median - $0) } ?? "-"
                var drawn = "\(window.samples.count)/\(window.ticks)"
                if window.drewShort { drawn += " FEW FRAMES DRAWN" }
                if window.stalled { drawn += " STALLED" }
                report.row(
                    casesTable, id,
                    [
                        "\(window.bodyCount)", window.mutation.rawValue, ms(median),
                        ms(Stats.percentile(window.mainCPU, 0.95)), ms(Stats.mean(window.mainCPU)),
                        ms(encode), ms(max(0, median - encode)), over, ms(gpu), drawn,
                        "\(window.rebuilds)",
                    ])
                let rate = Double(window.samples.count) / Double(max(window.ticks, 1))
                if rate > 1.1 || rate < 0.9 { rateNotes.append("\(id) \(String(format: "%.2f", rate))") }
                results[id] = Saved(window: window, median: median)
            } catch let failure as Failure {
                aborted = failure.message
            } catch {
                aborted = "\(error)"
            }
        }

        // Scene of 21 bodies: case 1 and its static baseline.
        load(count: 21)
        await run("static21", .none, staticMedian: nil, label: "#141: 21 bodies, static")
        let static21 = results["static21"]?.median
        await run(
            "case1", .copyAssign, staticMedian: static21, label: "#141 case 1: copy + assign")
        await run(
            "case1.inPlace", .inPlace, staticMedian: static21, label: "#141 case 1: in place")

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
                    "\(w.rebuilds) rebuilds in \(w.ticks) frames of 21 bodies",
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

        // Scene of 100 bodies: case 3 and its static baseline.
        if aborted == nil { load(count: 100) }
        await run("static100", .none, staticMedian: nil, label: "#141: 100 bodies, static")
        let static100 = results["static100"]?.median
        await run(
            "case3", .reassign, staticMedian: static100, label: "#141 case 3: reassign only")
        await run(
            "case3.mutate", .reassignAndMutate, staticMedian: static100,
            label: "#141 case 3: reassign + mutate")

        // Verdict against the issue's pass line.
        let verdict = "141.verdict"
        report.table(
            verdict,
            title: "#141 pass line: \(ms(Self.passLineMilliseconds)) ms CPU per frame for case 1 (21 bodies, one transform changing)",
            columns: ["measure", "ms", "result"])
        if let case1 = results["case1"]?.median, let baseline = static21 {
            let over = case1 - baseline
            let line = Self.passLineMilliseconds
            report.row(
                verdict, "case1.cost",
                [
                    "cost the update adds over static (copy + assign)", ms(over),
                    over < line ? "PASS" : "FAIL",
                ])
            report.row(
                verdict, "case1.total",
                [
                    "whole main-thread frame including drawing", ms(case1),
                    case1 < line ? "PASS" : "FAIL",
                ])
        }
        if let inPlace = results["case1.inPlace"]?.median, let baseline = static21 {
            let over = inPlace - baseline
            report.row(
                verdict, "case1.inPlace.cost",
                [
                    "cost over static (in place)", ms(over),
                    over < Self.passLineMilliseconds ? "PASS" : "FAIL",
                ])
        }

        // How the run went, under every table.
        let other = RunEnvironment.otherInstances()
        for table in [casesTable, case2, verdict] {
            report.footer(table, visibility.summary)
            if !rateNotes.isEmpty {
                report.footer(
                    table,
                    "CAUTION draws per 60 Hz tick differ from 1.00 in: \(rateNotes.joined(separator: ", ")). "
                        + "Each tick's main-thread CPU then covers that many draw callbacks; compare only rows drawn at the same rate.")
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
