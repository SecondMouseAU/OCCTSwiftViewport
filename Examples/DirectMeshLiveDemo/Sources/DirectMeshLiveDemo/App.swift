// Live verification for the Option A direct-mesh path through the INTERACTIVE
// ViewportRenderer (MTKView draw loop) — the passes the headless OffscreenRenderer
// twin CANNOT drive: the SSAO/silhouette depth prepass, the always-on-top overlay
// layer, and the GPU pick-ID texture (draw + readback).
//
// Left pane:  interleaved vertexData sphere (the reference).
// Right pane: the SAME sphere as ViewportBody.directMesh(...) — de-interleaved
//             position@buffer0 / normal@buffer2 — plus a small overlay-layer
//             direct body. Both panes run under a config with SSAO + silhouettes
//             + shadows + picking ENABLED, so every Phase-4 pass encodes each
//             frame. Click a body to fire a GPU pick; the picked id is shown so
//             readback correctness on a direct body is visible, not just inferred.
//
// Run under Metal API + GPU validation to prove the direct pipelines bind their
// stride-12 buffers against the direct vertex descriptor (a stride mismatch would
// be a validation error or visibly wrong shading):
//
//   cd Examples/DirectMeshLiveDemo
//   METAL_DEVICE_WRAPPER_TYPE=1 METAL_ERROR_MODE=5 METAL_DEBUG_ERROR_MODE=5 \
//     swift run DirectMeshLiveDemo
import SwiftUI
import simd
import OCCTSwiftViewport

private let bodyColor = SIMD4<Float>(0.45, 0.70, 0.95, 1)
private let overlayColor = SIMD4<Float>(1.0, 0.55, 0.15, 1)

/// A config that turns on every per-frame pass Phase 4 needs to validate on a
/// direct-mesh body: SSAO + shadows (lighting), screen-space silhouettes, and the
/// R32Uint pick texture. Silhouettes + SSAO exercise the depth-only direct prepass;
/// picking exercises the pick-shaded direct pipeline (draw every frame + readback).
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

/// De-interleave a primitive's [px,py,pz,nx,ny,nz,...] into separate position /
/// normal arrays so we can build the direct-mesh twin from identical data.
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

private func interleavedBodies() -> [ViewportBody] {
    var s = ViewportBody.sphere(id: "sphere", radius: 1.4, color: bodyColor)
    s.material = .chromedSteel   // glossy metal makes any normal error obvious
    return [s]
}

/// The direct-mesh pane: a main pickable direct sphere + a small direct box in the
/// `.overlay` render layer (always-on-top). Both are `usesDirectMesh` bodies so the
/// overlay draw + pick draw both run the direct pipelines.
private func directBodies() -> [ViewportBody] {
    let refSphere = interleavedBodies()[0]
    let s = deinterleave(refSphere.vertexData)
    var sphere = ViewportBody.directMesh(id: "sphere", positions: s.pos, normals: s.nrm,
                                         indices: refSphere.indices, color: bodyColor,
                                         material: .chromedSteel)
    sphere.isPickable = true

    // Small overlay-layer direct body, offset up-right, drawn always-on-top.
    let refBox = ViewportBody.box(id: "overlay", width: 0.7, height: 0.7, depth: 0.7, color: overlayColor)
    let b = deinterleave(refBox.vertexData)
    var overlay = ViewportBody.directMesh(id: "overlay", positions: b.pos, normals: b.nrm,
                                          indices: refBox.indices, color: overlayColor)
    overlay.renderLayer = .overlay
    overlay.isPickable = true
    overlay.transform = simd_float4x4(translation: SIMD3<Float>(1.6, 1.6, 0))

    return [sphere, overlay]
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self.init(SIMD4<Float>(1, 0, 0, 0),
                  SIMD4<Float>(0, 1, 0, 0),
                  SIMD4<Float>(0, 0, 1, 0),
                  SIMD4<Float>(t.x, t.y, t.z, 1))
    }
}

struct PaneView: View {
    let title: String
    let isDirect: Bool
    @StateObject private var controller = ViewportController(configuration: phase4Config())
    @State private var bodies: [ViewportBody]

    init(title: String, isDirect: Bool, bodies: [ViewportBody]) {
        self.title = title
        self.isDirect = isDirect
        _bodies = State(initialValue: bodies)
    }

    private var pickReadout: String {
        guard let r = controller.pickResult else { return "— tap a body to pick —" }
        let direct = bodies.indices.contains(r.bodyIndex) && bodies[r.bodyIndex].usesDirectMesh
        return "picked: \(r.bodyID)  [idx \(r.bodyIndex), \(r.kind), direct=\(direct)]"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).padding(.top, 6)
            MetalViewportView(controller: controller, bodies: $bodies)
            Text(pickReadout)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(controller.pickResult == nil ? .secondary : .green)
                .padding(.bottom, 4)
        }
        .onAppear {
            if let cam = CameraState.isometric.fit(to: bodies, aspectRatio: 1, padding: 1.6) {
                controller.animateTo(cam, duration: 0)
            }
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("Phase 4 — direct-mesh live: SSAO + silhouettes + overlay + GPU pick")
                .font(.subheadline).bold().padding(.top, 6)
            HStack(spacing: 1) {
                PaneView(title: "Interleaved (reference)", isDirect: false, bodies: interleavedBodies())
                Divider()
                PaneView(title: "Direct mesh (Option A) + overlay", isDirect: true, bodies: directBodies())
            }
        }
        .frame(minWidth: 960, minHeight: 560)
    }
}

@main
struct DirectMeshLiveDemoApp: App {
    var body: some Scene {
        WindowGroup("Direct-Mesh Live Verification (Phase 4)") {
            ContentView()
        }
    }
}
