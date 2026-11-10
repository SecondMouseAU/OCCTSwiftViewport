// Bench141View.swift
// The #141 tab: a viewport whose bodies change every frame, with a live readout.
//
// Two views on purpose. `Bench141Viewport` is all an app would have around `MetalViewportView`,
// and the only view that observes the bodies, so what the benchmark measures is the cost of that
// update and nothing from the controls. The panel observes its own state and is not re-evaluated
// when the bodies change.

import OCCTSwiftViewport
import SwiftUI

struct Bench141View: View {
    let model: Bench141Model

    var body: some View {
        ZStack(alignment: .bottom) {
            Bench141Viewport(model: model)
            Bench141Panel(model: model, state: model.panel)
        }
    }
}

struct Bench141Viewport: View {
    @ObservedObject var model: Bench141Model

    var body: some View {
        MetalViewportView(controller: model.controller, bodies: $model.bodies)
    }
}

struct Bench141Panel: View {
    let model: Bench141Model
    @ObservedObject var state: Bench141PanelState
    @State private var bodyCount = 21

    var body: some View {
        if state.measuring {
            Text(state.status)
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color.black.opacity(0.6))
                .foregroundStyle(.white)
                .padding(8)
        } else {
            controls
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Bodies", selection: $bodyCount) {
                    Text("21 bodies").tag(21)
                    Text("100 bodies").tag(100)
                }
                .pickerStyle(.segmented)
                .onChange(of: bodyCount) { _, count in model.load(count: count) }
                Button(state.isTicking ? "Stop" : "Start 60 Hz") {
                    state.isTicking ? model.stopTicking() : model.startTicking()
                }
            }
            Picker("Update", selection: $state.mutation) {
                ForEach(Bench141Model.Mutation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            Text(state.mutation.explanation)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(state.readout)
                .font(.system(.caption, design: .monospaced))
            if !state.status.isEmpty {
                Text(state.status).font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
                Text("DEBUG build: numbers are not representative. Build Release.")
                    .font(.caption).bold().foregroundStyle(.red)
            #endif
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(8)
    }
}
