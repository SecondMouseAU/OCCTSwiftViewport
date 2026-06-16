// Headless renderer for OCCTSwift cookbook figures (OCCTSwift #210).
// Usage: swift run CookbookRender [outputDir]
// Renders each scene from the same OCCTSwift API the cookbook page shows, so
// the figure and the code never drift.
import Foundation
import OCCTSwift
import OCCTSwiftTools
import OCCTSwiftViewport

let outDir: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

@MainActor
func render(_ bodies: [ViewportBody], to name: String, width: Int = 1280, height: Int = 720) {
    guard let renderer = OffscreenRenderer() else { fail("No Metal device — headless render unavailable") }
    let visible = bodies.filter { $0.isVisible }
    guard !visible.isEmpty else { fail("\(name): no renderable bodies") }
    var opts = OffscreenRenderOptions()
    opts.width = width
    opts.height = height
    opts.showGrid = false
    opts.showAxes = false
    if let cam = opts.cameraState.fit(to: visible, aspectRatio: Float(width) / Float(height), padding: 1.25) {
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

func body(_ shape: Shape?, _ id: String, _ rgba: SIMD4<Float>) -> ViewportBody? {
    guard let shape else { return nil }
    return CADFileLoader.shapeToBodyAndMetadata(shape, id: id, color: rgba).0
}

// Palette
let steel = SIMD4<Float>(0.62, 0.66, 0.72, 1)
let blue  = SIMD4<Float>(0.30, 0.52, 0.90, 1)
let amber = SIMD4<Float>(0.95, 0.62, 0.22, 1)

// ── Booleans: box ∪ / − / ∩ a through-cylinder ───────────────────────────
// A cylinder passing through the box makes the three results textbook-clear:
// union = box + protruding rod, cut = box with a through-hole, common = the rod stub.
// Rendered as three separate, individually-fit figures (the page lays them in a row).
@MainActor
func booleansThreeOps() {
    guard let box = Shape.box(width: 10, height: 10, depth: 10),
          let cyl = Shape.cylinder(at: SIMD3(0, 0, -8), direction: SIMD3(0, 0, 1),
                                   radius: 3, height: 16) else { fail("booleans: primitives") }
    let w = 560, h = 480
    if let b = body(box.union(cyl), "union", steel)         { render([b], to: "booleans-union.png", width: w, height: h) }
    if let b = body(box.subtracting(cyl), "cut", blue)      { render([b], to: "booleans-cut.png", width: w, height: h) }
    if let b = body(box.intersection(cyl), "common", amber) { render([b], to: "booleans-common.png", width: w, height: h) }
}

MainActor.assumeIsolated {
    booleansThreeOps()
}
