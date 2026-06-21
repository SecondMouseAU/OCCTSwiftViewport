// Headless renderer for OCCTSwiftViewport cookbook figures.
// Usage: swift run DocFigures [outputDir]
//
// Each figure is produced by the viewport's own OffscreenRenderer from the
// built-in ViewportBody primitives, so the picture matches the documented API.
import Foundation
import simd
import OCCTSwiftViewport

let outDir: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

@MainActor
func render(_ bodies: [ViewportBody], to name: String,
            width: Int = 640, height: Int = 480,
            configure: (inout OffscreenRenderOptions) -> Void = { _ in }) {
    guard let renderer = OffscreenRenderer() else { fail("No Metal device — headless render unavailable") }
    let visible = bodies.filter { $0.isVisible }
    guard !visible.isEmpty else { fail("\(name): no renderable bodies") }

    var opts = OffscreenRenderOptions()
    opts.width = width
    opts.height = height
    opts.backgroundColor = SIMD4<Float>(0.93, 0.94, 0.96, 1)
    opts.cameraState = .isometric
    configure(&opts)
    if let cam = opts.cameraState.fit(to: visible,
                                      aspectRatio: Float(width) / Float(height),
                                      padding: 1.3) {
        opts.cameraState = cam
    }
    let url = outDir.appendingPathComponent(name)
    do {
        let bytes = try renderer.renderToPNG(bodies: visible, url: url, options: opts)
        print("rendered \(name) (\(bytes) bytes)")
    } catch {
        fail("\(name): render failed — \(error)")
    }
}

// A body with a per-body PBR material applied.
func withMaterial(_ body: ViewportBody, _ material: PBRMaterial) -> ViewportBody {
    var b = body
    b.material = material
    return b
}

// ── Scene for display-mode figures: a sphere resting beside a box ──────────
func sceneShapes() -> [ViewportBody] {
    var box = ViewportBody.box(id: "box", width: 1.6, height: 1.6, depth: 1.6,
                               color: SIMD4(0.40, 0.62, 0.90, 1))
    box.transform = simd_float4x4(translation: SIMD3(-1.1, 0, 0))
    var sphere = ViewportBody.sphere(id: "sphere", radius: 1.0,
                                     color: SIMD4(0.92, 0.58, 0.26, 1))
    sphere.transform = simd_float4x4(translation: SIMD3(1.1, 0, 0))
    return [box, sphere]
}

extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4(t, 1)
    }
}

// ── Display modes ──────────────────────────────────────────────────────────
for (mode, name) in [(DisplayMode.wireframe, "display-wireframe.png"),
                     (.shaded, "display-shaded.png"),
                     (.shadedWithEdges, "display-shaded-edges.png"),
                     (.unlit, "display-unlit.png")] {
    render(sceneShapes(), to: name) { $0.displayMode = mode }
}

// ── Lighting presets (a single sphere) ─────────────────────────────────────
func litSphere() -> [ViewportBody] {
    [ViewportBody.sphere(id: "s", radius: 1.0, color: SIMD4(0.78, 0.30, 0.34, 1))]
}
for (cfg, name) in [(LightingConfiguration.threePoint, "lighting-threepoint.png"),
                    (.studio, "lighting-studio.png"),
                    (.architectural, "lighting-architectural.png"),
                    (.flat, "lighting-flat.png")] {
    render(litSphere(), to: name) {
        $0.displayMode = .shaded
        $0.lightingConfiguration = cfg
    }
}

// ── PBR materials (a single sphere) ────────────────────────────────────────
for (mat, name) in [(PBRMaterial.steel, "material-steel.png"),
                    (.brass, "material-brass.png"),
                    (.gold, "material-gold.png"),
                    (.plasticGlossy, "material-plastic.png")] {
    let s = withMaterial(ViewportBody.sphere(id: "s", radius: 1.0,
                                             color: SIMD4(0.8, 0.8, 0.8, 1)), mat)
    render([s], to: name) {
        $0.displayMode = .shaded
        $0.lightingConfiguration = .studio
    }
}

print("done.")
