// Live verification for the Option A direct-mesh path through the INTERACTIVE
// ViewportRenderer (MTKView draw loop). Shows the same sphere two ways side by
// side — left: interleaved vertexData; right: ViewportBody.directMesh(...) from
// de-interleaved position/normal arrays. They must look identical.
import SwiftUI
import simd
import OCCTSwiftViewport

private let bodyColor = SIMD4<Float>(0.45, 0.70, 0.95, 1)

private func makeBodies() -> (interleaved: [ViewportBody], direct: [ViewportBody]) {
    var interleaved = ViewportBody.sphere(id: "s", radius: 1.4, color: bodyColor)
    interleaved.material = .chromedSteel    // glossy metal makes any normal error obvious

    var pos: [Float] = []
    var nrm: [Float] = []
    let vd = interleaved.vertexData
    var i = 0
    while i + 5 < vd.count {
        pos.append(vd[i]); pos.append(vd[i + 1]); pos.append(vd[i + 2])
        nrm.append(vd[i + 3]); nrm.append(vd[i + 4]); nrm.append(vd[i + 5])
        i += 6
    }
    let direct = ViewportBody.directMesh(id: "s", positions: pos, normals: nrm,
                                         indices: interleaved.indices, color: bodyColor,
                                         material: .chromedSteel)
    return ([interleaved], [direct])
}

struct PaneView: View {
    let title: String
    @StateObject private var controller = ViewportController()
    @State private var bodies: [ViewportBody]

    init(title: String, bodies: [ViewportBody]) {
        self.title = title
        _bodies = State(initialValue: bodies)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).padding(.top, 6)
            MetalViewportView(controller: controller, bodies: $bodies)
        }
        .onAppear {
            if let cam = CameraState.isometric.fit(to: bodies, aspectRatio: 1, padding: 1.4) {
                controller.animateTo(cam, duration: 0)
            }
        }
    }
}

struct ContentView: View {
    private let made = makeBodies()
    var body: some View {
        HStack(spacing: 1) {
            PaneView(title: "Interleaved (vertexData)", bodies: made.interleaved)
            Divider()
            PaneView(title: "Direct mesh (Option A)", bodies: made.direct)
        }
        .frame(minWidth: 900, minHeight: 480)
    }
}

@main
struct DirectMeshLiveDemoApp: App {
    var body: some Scene {
        WindowGroup("Direct-Mesh Live Verification") {
            ContentView()
        }
    }
}
