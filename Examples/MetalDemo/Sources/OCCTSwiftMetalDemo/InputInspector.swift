// InputInspector.swift
// Demo-only HUD that visualizes the viewport's portable ViewportInputEvent stream,
// so gesture interpretation can be verified live on device (issue #35).

import SwiftUI
import OCCTSwiftViewport

/// Rolling log of recent input events, fed from `ViewportController.onInputEvent`.
@MainActor
final class InputEventLog: ObservableObject {

    struct Entry: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    private var counter = 0
    private let maxEntries = 14

    func record(_ event: _ViewportInputEvent) {
        counter += 1
        entries.append(Entry(id: counter, text: Self.describe(event)))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    private static func f(_ v: Float) -> String { String(format: "%.1f", v) }

    private static func describe(_ event: _ViewportInputEvent) -> String {
        switch event {
        case let .dragChanged(delta, modifiers):
            return "drag Δ(\(f(delta.x)), \(f(delta.y)))\(mods(modifiers))"
        case let .dragEnded(velocity, modifiers):
            return "drag end v(\(f(velocity.x)), \(f(velocity.y)))\(mods(modifiers))"
        case let .twoFingerPanChanged(t):
            return "2-finger pan (\(f(t.x)), \(f(t.y)))"
        case let .twoFingerPanEnded(v):
            return "2-finger pan end v(\(f(v.x)), \(f(v.y)))"
        case let .pinchChanged(scale):
            return "pinch ×\(String(format: "%.3f", scale))"
        case .pinchEnded:
            return "pinch end"
        case let .rotateChanged(radians):
            return "rotate \(f(radians * 180 / .pi))°"
        case .rotateEnded:
            return "rotate end"
        case let .scroll(delta, cursor, _):
            return "scroll \(f(delta)) @(\(f(cursor.x)), \(f(cursor.y)))"
        case let .tap(_, count):
            return count >= 2 ? "double-tap → reset" : "tap"
        @unknown default:
            return "event"
        }
    }

    private static func mods(_ m: _ViewportModifierKeys) -> String {
        var s = ""
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.command) { s += "⌘" }
        return s.isEmpty ? "" : " [\(s)]"
    }
}

/// Translucent panel listing the most recent input events (newest at the bottom).
struct InputInspectorView: View {

    @ObservedObject var log: InputEventLog

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Input events")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .font(.caption2)
            }
            .padding(.bottom, 2)

            if log.entries.isEmpty {
                Text("Interact with the viewport…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.entries) { entry in
                    Text(entry.text)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(width: 230, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
