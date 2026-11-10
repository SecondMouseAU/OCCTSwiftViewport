// BenchReport.swift
// The results table shared by both benchmarks.
//
// Every row is printed to stdout the moment it is produced, as one line:
//
//     BENCH <table> <row> | <column>=<value> | <column>=<value> ...
//
// so `grep '^BENCH 139.gpu '` pulls one table out of a log. `printTables()` then prints every table
// again, column-aligned, between `=== SPIKE BENCH TABLE ===` and `=== END ===`. The same text is
// shown in the app (`BenchReportView`) with a Copy button.

import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
final class BenchReport: ObservableObject {

    struct Row: Identifiable {
        var id: String
        var cells: [String]
    }

    struct Table: Identifiable {
        var id: String
        var title: String
        var columns: [String]
        var rows: [Row] = []
        var footers: [String] = []
    }

    @Published private(set) var tables: [Table] = []
    @Published private(set) var lines: [String] = []

    // MARK: Building

    /// Adds `line` to the free text above the tables and prints it as `BENCH-NOTE`.
    func note(_ line: String) {
        lines.append(line)
        emit("BENCH-NOTE \(line)")
    }

    /// Prints `key=value` pairs describing the device and build as `BENCH-ENV`.
    func environment(_ pairs: [(String, String)]) {
        let text = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        lines.append(text)
        emit("BENCH-ENV \(text)")
    }

    /// Starts (or restarts) a table. Rows added to an unknown table id are dropped.
    func table(_ id: String, title: String, columns: [String]) {
        tables.removeAll { $0.id == id }
        tables.append(Table(id: id, title: title, columns: columns))
        emit("BENCH-TABLE \(id) \(title)")
    }

    func row(_ table: String, _ id: String, _ cells: [String]) {
        guard let t = tables.firstIndex(where: { $0.id == table }) else { return }
        tables[t].rows.append(Row(id: id, cells: cells))
        let pairs = zip(tables[t].columns, cells).map { "\($0)=\($1)" }.joined(separator: " | ")
        emit("BENCH \(table) \(id) | \(pairs)")
    }

    /// A line under a table: how the run went (window visibility, other instances, aborts).
    func footer(_ table: String, _ text: String) {
        guard let t = tables.firstIndex(where: { $0.id == table }) else { return }
        tables[t].footers.append(text)
        emit("BENCH-FOOTER \(table) \(text)")
    }

    /// Whether any table has a row.
    var hasRows: Bool { tables.contains { !$0.rows.isEmpty } }

    func reset() {
        tables = []
        lines = []
    }

    // MARK: Output

    /// The whole report as aligned plain text.
    var text: String {
        var out: [String] = lines
        for table in tables {
            out.append("")
            out.append("[\(table.id)] \(table.title)")
            let header = ["row"] + table.columns
            let body = table.rows.map { [$0.id] + $0.cells }
            let widths = header.indices.map { column in
                ([header] + body).map { $0.indices.contains(column) ? $0[column].count : 0 }.max()
                    ?? 0
            }
            func format(_ cells: [String]) -> String {
                cells.indices.map { cells[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                    .joined(separator: "  ")
            }
            out.append(format(header))
            out.append(String(repeating: "-", count: format(header).count))
            out.append(contentsOf: body.map(format))
            if body.isEmpty { out.append("(no rows collected)") }
            out.append(contentsOf: table.footers.map { "* \($0)" })
        }
        return out.joined(separator: "\n")
    }

    func printTables() {
        emit("=== SPIKE BENCH TABLE ===")
        emit(text)
        emit("=== END ===")
    }

    func copyToPasteboard() {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #else
            UIPasteboard.general.string = text
        #endif
    }

    private func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}

// MARK: - View

struct BenchReportView: View {
    @ObservedObject var report: BenchReport
    var busy = false
    var status = ""
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Results").font(.headline)
                if busy {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if busy {
                    Button("Cancel run", role: .destructive, action: onCancel)
                }
                Button("Copy") { report.copyToPasteboard() }
                    .disabled(report.tables.isEmpty && report.lines.isEmpty)
                // Escape closes it; the run, if any, carries on behind it.
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if !report.hasRows {
                Text(
                    busy
                        ? "No rows yet: the first rows arrive when the first measured window ends."
                        : "No results were collected. The notes below say why."
                )
                .font(.callout).foregroundStyle(.orange)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(report.tables.isEmpty && report.lines.isEmpty ? "No results yet." : report.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}
