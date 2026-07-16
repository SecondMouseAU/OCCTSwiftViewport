// DirectMeshVerifyApp — dedicated on-device (iPhone/iPad) verification for the
// Option A direct-mesh render path (spike `spike/direct-brep-rendering`, Phase 4).
//
// Deliberately tiny and dependency-light: it depends ONLY on OCCTSwiftViewport (no
// OCCTSwift / OCCT.xcframework), and has NO sidebar or settings UI — just a single
// tappable viewport of `ViewportBody.directMesh(...)` bodies with SSAO + silhouettes
// + picking enabled. A physical tap exercises the GPU pick-ID texture readback on a
// `usesDirectMesh` body; the on-screen readout shows which body was hit and whether
// it is a direct body, so pick correctness is visible, not inferred. This sidesteps
// the full MetalDemo app's sidebar (whose settings sheet crashes on this iOS build —
// a pre-existing issue unrelated to the spike).
import SwiftUI
import simd
import OCCTSwiftViewport

private func phase4Config() -> ViewportConfiguration {
    var lighting = LightingConfiguration.studio
    lighting.enableSSAO = true
    lighting.shadowsEnabled = true
    return ViewportConfiguration(
        rotationStyle: .turntable,
        lightingConfiguration: lighting,
        showViewCube: true,
        showAxes: true,
        showGrid: true,
        enableSilhouettes: true,
        silhouetteIntensity: 0.8,
        pickingConfiguration: PickingConfiguration(isEnabled: true)
    )
}

private func deinterleave(_ vd: [Float]) -> (pos: [Float], nrm: [Float]) {
    var pos: [Float] = [], nrm: [Float] = []
    var i = 0
    while i + 5 < vd.count {
        pos.append(vd[i]);     pos.append(vd[i + 1]); pos.append(vd[i + 2])
        nrm.append(vd[i + 3]); nrm.append(vd[i + 4]); nrm.append(vd[i + 5])
        i += 6
    }
    return (pos, nrm)
}

private func direct(from ref: ViewportBody, id: String,
                    color: SIMD4<Float>, material: PBRMaterial? = nil) -> ViewportBody {
    let d = deinterleave(ref.vertexData)
    return ViewportBody.directMesh(id: id, positions: d.pos, normals: d.nrm,
                                   indices: ref.indices, color: color, material: material)
}

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(SIMD4<Float>(1, 0, 0, 0),
                  SIMD4<Float>(0, 1, 0, 0),
                  SIMD4<Float>(0, 0, 1, 0),
                  SIMD4<Float>(t.x, t.y, t.z, 1))
}

private func directBodies() -> [ViewportBody] {
    let steel = SIMD4<Float>(0.55, 0.72, 0.95, 1)
    let brass = SIMD4<Float>(0.85, 0.68, 0.28, 1)
    let green = SIMD4<Float>(0.35, 0.80, 0.45, 1)
    let orange = SIMD4<Float>(1.0, 0.55, 0.15, 1)

    var sphere = direct(from: ViewportBody.sphere(id: "s", radius: 1.0, segments: 40, rings: 24, color: steel),
                        id: "direct-sphere", color: steel, material: .chromedSteel)
    sphere.transform = translation(SIMD3<Float>(-2.6, 1.0, 0))
    sphere.isPickable = true

    var cyl = direct(from: ViewportBody.cylinder(id: "c", radius: 0.7, height: 2.0, segments: 40, color: brass),
                     id: "direct-cylinder", color: brass, material: .brass)
    cyl.transform = translation(SIMD3<Float>(0, 1.0, 0))
    cyl.isPickable = true

    var box = direct(from: ViewportBody.box(id: "b", width: 1.4, height: 1.4, depth: 1.4, color: green),
                     id: "direct-box", color: green)
    box.transform = translation(SIMD3<Float>(2.6, 0.7, 0))
    box.isPickable = true

    var overlay = direct(from: ViewportBody.box(id: "o", width: 0.6, height: 0.6, depth: 0.6, color: orange),
                         id: "direct-overlay", color: orange)
    overlay.renderLayer = .overlay
    overlay.isPickable = true
    overlay.transform = translation(SIMD3<Float>(0, 2.6, 0))

    return [sphere, cyl, box, overlay]
}

struct ContentView: View {
    @StateObject private var controller = ViewportController(configuration: phase4Config())
    @State private var bodies: [ViewportBody] = directBodies()

    private var readout: String {
        guard let r = controller.pickResult else { return "Tap a body to pick" }
        let direct = bodies.indices.contains(r.bodyIndex) && bodies[r.bodyIndex].usesDirectMesh
        return "picked: \(r.bodyID)  ·  \(r.kind)  ·  direct=\(direct)"
    }

    private var picked: Bool { controller.pickResult != nil }

    var body: some View {
        ZStack {
            MetalViewportView(controller: controller, bodies: $bodies)
                .ignoresSafeArea()

            VStack {
                Text("Phase 4 — direct-mesh on device")
                    .font(.footnote).bold()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)

                Spacer()

                HStack(spacing: 12) {
                    Text(readout)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(picked ? Color.green : Color.secondary)
                    Button("Reset view") { fit() }
                        .font(.footnote)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 12)
            }
        }
        .onAppear { fit() }
    }

    private func fit() {
        if let cam = CameraState.isometric.fit(to: bodies, aspectRatio: 1, padding: 1.6) {
            controller.animateTo(cam, duration: 0)
        }
    }
}

@main
struct DirectMeshVerifyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
