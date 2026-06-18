// Headless renderer for OCCTSwift cookbook figures (OCCTSwift #210).
// Usage: swift run CookbookRender [outputDir]
// Renders each scene from the same OCCTSwift API the cookbook page shows, so
// the figure and the code never drift.
import Foundation
import simd
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
func render(_ bodies: [ViewportBody], to name: String, width: Int = 1280, height: Int = 720,
            view: CameraState? = nil) {
    guard let renderer = OffscreenRenderer() else { fail("No Metal device — headless render unavailable") }
    let visible = bodies.filter { $0.isVisible }
    guard !visible.isEmpty else { fail("\(name): no renderable bodies") }
    var opts = OffscreenRenderOptions()
    opts.width = width
    opts.height = height
    opts.showGrid = false
    opts.showAxes = false
    if let view { opts.cameraState = view }   // pick a viewpoint (default looks down +Z)
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

// GLB models go next to the images dir (…/cookbook/models) for the interactive <model-viewer>.
let modelsDir = outDir.deletingLastPathComponent().appendingPathComponent("models", isDirectory: true)
try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

// Export a GLB with a baked-in material colour. Exporter.writeGLTF(shape:) emits no
// material (renders white in model-viewer), so go through an XDE Document: set the colour
// on the shape's label, then writeGLTF preserves it as a glTF baseColorFactor.
func exportGLB(_ shape: Shape?, _ name: String, _ rgba: SIMD4<Float>) {
    guard let shape, let doc = Document.create() else { return }
    let labelId = doc.addShape(shape, makeAssembly: false)
    doc.node(at: labelId)?.setColor(Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z)))
    let url = modelsDir.appendingPathComponent(name)
    if doc.writeGLTF(to: url, binary: true) {
        print("exported \(name)")
    } else {
        fail("\(name): GLB export failed")
    }
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
    let ops: [(name: String, shape: Shape?, color: SIMD4<Float>)] = [
        ("union",  box.union(cyl),        steel),
        ("cut",    box.subtracting(cyl),  blue),
        ("common", box.intersection(cyl), amber),
    ]
    for op in ops {
        if let b = body(op.shape, op.name, op.color) {
            render([b], to: "booleans-\(op.name).png", width: w, height: h)   // static figure / poster
        }
        exportGLB(op.shape, "booleans-\(op.name).glb", op.color)              // interactive model-viewer (coloured)
    }
}

// ── Threads: a smooth ISO-68 V-thread built without booleans (#213) ───────
// threadedShaft on a plain cylinder builds the rod DIRECTLY (cam-loft + sew, no BOP):
// a smooth, BRepCheck-valid 60° V-thread. One portrait figure + interactive GLB.
@MainActor
func threadsScene() {
    guard let shank = Shape.cylinder(radius: 6, height: 24) else { fail("threads: shank") }
    let spec = ThreadSpec(form: .iso68, nominalDiameter: 12, pitch: 1.75)
    guard let threaded = shank.threadedShaft(axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                             spec: spec, length: 18) else { fail("threads: build") }
    if let b = body(threaded, "thread", steel) {
        // Isometric view — a Z-axis shaft seen down +Z is just a circle; show the flanks.
        render([b], to: "threads-shaft.png", width: 520, height: 640, view: .isometric)
    }
    exportGLB(threaded, "threads-shaft.glb", steel)                     // interactive model-viewer
}

// ── Helices: a coiled spring = a circle swept along a helix ───────────────
// Stock pipe-sweep along a Wire.helix. The circular section is rotationally symmetric,
// so the sweep's Frenet re-framing is harmless (correctedFrenet keeps the section true) —
// the very thing that distorts an asymmetric thread profile and forced #213's custom build.
@MainActor
func helicesScene() {
    let r = 10.0, pitch = 4.0, turns = 5.0, wire = 1.5
    guard let spine = Wire.helix(radius: r, pitch: pitch, turns: turns) else { fail("helices: spine") }
    let tangent = simd_normalize(SIMD3<Double>(0, r, pitch / (2 * .pi)))   // helix tangent at the start
    guard let profile = Wire.circle(origin: SIMD3(r, 0, 0), normal: tangent, radius: wire) else { fail("helices: profile") }
    guard let spring = Shape.pipeShell(spine: spine, profile: profile, mode: .correctedFrenet, solid: true) else { fail("helices: spring") }
    if let b = body(spring, "spring", steel) {
        render([b], to: "helices-spring.png", width: 560, height: 560, view: .isometric)
    }
    exportGLB(spring, "helices-spring.glb", steel)
}

// ── Thread forms gallery: a few visually-distinct forms (#thread-forms) ────
@MainActor
func threadFormsScene() {
    let forms: [(name: String, form: ThreadForm, color: SIMD4<Float>)] = [
        ("acme", .acme, amber), ("square", .square, blue), ("buttress", .buttress, steel),
    ]
    for f in forms {
        guard let shank = Shape.cylinder(radius: 7, height: 24) else { continue }
        let spec = ThreadSpec(form: f.form, nominalDiameter: 14, pitch: 3.0)
        guard let t = shank.threadedShaft(axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                          spec: spec, length: 18) else { fail("forms: \(f.name)") }
        if let b = body(t, f.name, f.color) {
            render([b], to: "threads-\(f.name).png", width: 360, height: 460, view: .isometric)
        }
        exportGLB(t, "threads-\(f.name).glb", f.color)
    }
}

// Render only the scenes named on the command line after the output dir (default: all).
let sceneArgs = Set(CommandLine.arguments.dropFirst(2).map { $0.lowercased() })
func wants(_ name: String) -> Bool { sceneArgs.isEmpty || sceneArgs.contains(name) }

MainActor.assumeIsolated {
    if wants("booleans")    { booleansThreeOps() }
    if wants("threads")     { threadsScene() }
    if wants("threadforms") { threadFormsScene() }
    if wants("helices")     { helicesScene() }
}
