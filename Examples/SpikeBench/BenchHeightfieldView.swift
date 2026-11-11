// BenchHeightfieldView.swift
// The #139 tab: orbit the field with the viewport's own gestures, change how it is drawn and
// edited, and read what the frames cost.

import OCCTSwiftViewport
import SwiftUI

struct BenchHeightfieldView: View {
    @ObservedObject var model: BenchHeightfieldModel
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .bottom) {
            MetalViewportView(controller: model.controller, bodies: $model.bodies)
                .id(model.viewID)

            VStack(alignment: .leading, spacing: 6) {
                readouts
                Button(showControls ? "Hide controls" : "Show controls") {
                    showControls.toggle()
                }
                .font(.caption)
                if showControls {
                    ScrollView { controls }.frame(maxHeight: 250)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
        }
    }

    private var readouts: some View {
        let r = model.readout
        return VStack(alignment: .leading, spacing: 2) {
            Text(
                String(
                    format: "frame CPU %.2f ms   GPU %.2f ms (display-paced)   %.0f fps", r.encodeMs,
                    r.gpuMs, r.framesPerSecond)
            )
            Text(
                String(
                    format: "uploaded %.0f KB/frame   tiles %d   draw calls %d   replace() %.2f ms",
                    r.uploadKB, r.tiles, r.drawCalls, r.replaceMs))
            Text(model.pickText).foregroundStyle(.green)
            #if DEBUG
                Text("DEBUG build: numbers are not representative. Build Release.")
                    .bold().foregroundStyle(.red)
            #endif
        }
        .font(.system(.caption, design: .monospaced))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Mesh cell target (px)") {
                Picker("", selection: $model.settings.targetPixels) {
                    ForEach([2, 3, 4, 6, 8] as [Float], id: \.self) { Text("\(Int($0))").tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 220)
            }
            LabeledContent("MSAA") {
                Picker("", selection: $model.settings.msaa) {
                    Text("1").tag(1)
                    Text("4").tag(4)
                }
                .pickerStyle(.segmented).frame(maxWidth: 100)
            }
            LabeledContent("Edits per frame (130x120)") {
                Picker("", selection: $model.settings.editsPerFrame) {
                    ForEach([0, 1, 50, 200], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
            }
            LabeledContent("Edit pattern") {
                Picker("", selection: $model.settings.pattern) {
                    ForEach(BenchHeightfieldScene.EditPattern.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented).frame(maxWidth: 180)
            }
            HStack {
                Toggle("Shadows", isOn: $model.settings.shadows)
                Toggle("SSAO", isOn: $model.settings.ssao)
                Toggle("Silhouettes", isOn: $model.settings.silhouettes)
            }
            HStack {
                Toggle("float16", isOn: $model.settings.float16)
                Toggle("Ramp painted", isOn: $model.settings.rampPainted)
                Toggle("Pick pass", isOn: $model.settings.picking)
                Toggle("Auto-orbit", isOn: $model.settings.autoOrbit)
            }
        }
        .font(.caption)
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
