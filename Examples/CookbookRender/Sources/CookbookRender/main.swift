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

// ── Threaded holes: a hex nut, a wing nut, and a lead-screw + anti-backlash nut+spring ──
// A hex prism with a central bore, threaded internally (threadedHole works on any block).
@MainActor
func hexNut(acrossFlats: Double, thickness: Double, spec: ThreadSpec, z: Double = 0) -> Shape? {
    let r = acrossFlats / sqrt(3.0)                       // circumradius from across-flats
    let pts = (0..<6).map { i -> SIMD2<Double> in
        let a = Double(i) * .pi / 3 + .pi / 6
        return SIMD2(r * cos(a), r * sin(a))
    }
    guard let hex = Wire.polygon(pts),
          let prism = Shape.extrude(profile: hex, direction: SIMD3(0, 0, 1), length: thickness),
          let bore = Shape.cylinder(at: SIMD3(0, 0, -1), direction: SIMD3(0, 0, 1),
                                    radius: spec.nominalDiameter / 2, height: thickness + 2),
          let block = prism.subtracting(bore),
          let tapped = block.threadedHole(axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                          spec: spec, depth: thickness) else { return nil }
    return z == 0 ? tapped : tapped.translated(by: SIMD3(0, 0, z))
}

@MainActor
func nutScene() {
    let spec = ThreadSpec(form: .iso68, nominalDiameter: 12, pitch: 1.75)   // M12 ISO hex nut
    guard let nut = hexNut(acrossFlats: 19, thickness: 10, spec: spec) else { fail("nut") }
    if let b = body(nut, "nut", steel) {
        render([b], to: "threadedhole-nut.png", width: 480, height: 420, view: .isometric)
    }
    exportGLB(nut, "threadedhole-nut.glb", steel)
}

@MainActor
func wingNutScene() {
    let spec = ThreadSpec(form: .unified, nominalDiameter: 9.525, pitch: 25.4 / 16)   // 3/8-16 UNC
    // Thread the simple cylindrical body FIRST — the smooth internal cut runs on a clean cylinder
    // (where it's robust) — then union the wings on afterward. Result: a smooth bore thread even
    // though the finished body is complex. (Threading the unioned body directly falls back to faceted.)
    guard let cyl = Shape.cylinder(radius: 8, height: 9),
          let bore = Shape.cylinder(at: SIMD3(0, 0, -1), direction: SIMD3(0, 0, 1),
                                    radius: spec.nominalDiameter / 2, height: 11),
          let body0 = cyl.subtracting(bore),
          var wingnut = body0.threadedHole(axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                           spec: spec, depth: 9) else { fail("wingnut tap") }
    // Two wings: a tab built with its inner-bottom edge at the origin, tilted up ~22°, then placed
    // at the body and mirrored to the far side. The tilt swings the tab's upper-inner corner in to
    // ~r4.1 — inside the r4.76 bore — so each wing is trimmed against the bore column (`bore`) before
    // the union, clipping it at the nut's inner edge so it can't intrude into the threaded bore (#219).
    func wing(mirror: Bool) -> Shape? {
        guard let tab = Shape.box(origin: SIMD3(0, -1.4, 0), width: 13, height: 2.8, depth: 7),
              let tilted = tab.rotated(axis: SIMD3(0, 1, 0), angle: -0.38) else { return nil }
        let placed = tilted.translated(by: SIMD3(6.5, 0, 1.5))
        let oriented = mirror ? placed?.rotated(axis: SIMD3(0, 0, 1), angle: .pi) : placed
        return oriented?.subtracting(bore)
    }
    if let w1 = wing(mirror: false), let u = wingnut.union(w1) { wingnut = u }
    if let w2 = wing(mirror: true),  let u = wingnut.union(w2) { wingnut = u }
    if let b = body(wingnut, "wingnut", blue) {
        render([b], to: "threadedhole-wingnut.png", width: 520, height: 420, view: .isometric)
    }
    exportGLB(wingnut, "threadedhole-wingnut.glb", blue)
}

// A square-thread lead screw with a split anti-backlash nut: two half-nuts pushed apart by a
// compression spring so opposite flanks bear, taking up backlash. (Fun: it's a thread + a spring.)
@MainActor
func leadScrewScene() {
    let scr = ThreadSpec(form: .square, nominalDiameter: 12, pitch: 3)
    guard let stock = Shape.cylinder(radius: 6, height: 56),
          let screw = stock.threadedShaft(axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                          spec: scr, length: 52) else { fail("lead screw") }
    guard let nutA = hexNut(acrossFlats: 18, thickness: 8, spec: scr, z: 14),
          let nutB = hexNut(acrossFlats: 18, thickness: 8, spec: scr, z: 34) else { fail("nuts") }
    // anti-backlash spring around the screw, between the two half-nuts (z 22…32); sized a touch
    // wider than the nut flats so the coil is clearly visible.
    guard let spine = Wire.helix(origin: SIMD3(0, 0, 22), radius: 11, pitch: 2.5, turns: 4),
          let prof = Wire.circle(origin: SIMD3(11, 0, 22),
                                 normal: simd_normalize(SIMD3(0, 11, 2.5 / (2 * .pi))), radius: 1.3),
          let spring = Shape.pipeShell(spine: spine, profile: prof, mode: .correctedFrenet, solid: true)
    else { fail("spring") }

    var bodies: [ViewportBody] = []
    if let b = body(screw, "screw", steel) { bodies.append(b) }
    if let b = body(nutA, "nutA", blue)   { bodies.append(b) }
    if let b = body(nutB, "nutB", blue)   { bodies.append(b) }
    if let b = body(spring, "spring", amber) { bodies.append(b) }
    render(bodies, to: "threadedhole-leadscrew.png", width: 460, height: 680, view: .isometric)
    // GLB: one combined model isn't trivial to colour per-part here; export the screw alone as the poster's 3D.
    exportGLB(screw, "threadedhole-leadscrew.glb", steel)
}

// ── Lofting & sweeps: the four hero solids from the lofting-and-sweeps page ──
// Each built from the same OCCTSwift API the page shows: a swept elbow, a square→round
// loft, a circle lofted to a vertex (cone), and a multi-section pipe shell (vase).
@MainActor
func loftsScene() {
    // sweep — circular section along a quarter-arc path → pipe elbow.
    // The section sits at the path start (16,0,0) with its plane square to the path
    // tangent there (+Y), so the tube isn't edge-on to the sweep.
    if let section = Wire.circle(origin: SIMD3(16, 0, 0), normal: SIMD3(0, 1, 0), radius: 5),
       let path = Wire.arc(center: .zero, radius: 16, startAngle: 0, endAngle: .pi / 2),
       let elbow = Shape.sweep(profile: section, along: path) {
        if let b = body(elbow, "elbow", blue) {
            render([b], to: "sweep-pipe.png", width: 520, height: 460, view: .isometric)
        }
        exportGLB(elbow, "sweep-pipe.glb", blue)
    }
    // loft — square base (z=0) → round top (z=12): a transition duct
    if let base = Wire.polygon3D([SIMD3(-5, -5, 0), SIMD3(5, -5, 0), SIMD3(5, 5, 0), SIMD3(-5, 5, 0)], closed: true),
       let top = Wire.circle(origin: SIMD3(0, 0, 12), radius: 4),
       let frustum = Shape.loft(profiles: [base, top], solid: true) {
        if let b = body(frustum, "frustum", steel) {
            render([b], to: "loft-frustum.png", width: 480, height: 520, view: .isometric)
        }
        exportGLB(frustum, "loft-frustum.glb", steel)
    }
    // loft — single circle lofted to a vertex tip → cone
    if let circle = Wire.circle(radius: 5),
       let cone = Shape.loft(profiles: [circle], solid: true, ruled: true, lastVertex: SIMD3(0, 0, 10)) {
        if let b = body(cone, "cone", amber) {
            render([b], to: "loft-cone.png", width: 440, height: 520, view: .isometric)
        }
        exportGLB(cone, "loft-cone.glb", amber)
    }
    // multi-section sweep — three coaxial circles of varying radius along a straight spine → vase
    if let spine = Wire.line(from: .zero, to: SIMD3(0, 0, 12)) {
        let stations = zip([0.0, 6.0, 12.0], [4.0, 2.0, 5.0]).compactMap {
            Wire.circle(origin: SIMD3(0, 0, $0.0), radius: $0.1)
        }
        if stations.count == 3,
           let vase = Shape.pipeShellMultiSection(spine: spine, profiles: stations, mode: .frenet, solid: true) {
            if let b = body(vase, "vase", blue) {
                render([b], to: "sweep-vase.png", width: 440, height: 560, view: .isometric)
            }
            exportGLB(vase, "sweep-vase.glb", blue)
        }
    }
}

// ── Helical sweeps: a standalone helicoid ridge vs. a proper threaded worm (#225) ──
// helicalSweep produces a standalone helical ridge (an auger flight); to get a real thread,
// threadedRod composes a custom profile with the core directly (NO boolean) — the boolean
// compose route is invalid/collapses (#225, #213, #181).
@MainActor
func helicalSweepsScene() {
    let R = 3.0, crest = 6.0, pitch = 4.0
    // 1) A standalone helical ridge — what helicalSweep makes on its own.
    if let rib = Wire.polygon3D([SIMD3(R, 0, 0), SIMD3(crest, 0, pitch * 0.4), SIMD3(R, 0, pitch * 0.8)], closed: true),
       let ridge = Shape.helicalSweep(profile: rib, axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1),
                                      radius: R, pitch: pitch, turns: 3, clockwise: false, solid: true) {
        if let b = body(ridge, "ridge", amber) {
            render([b], to: "helical-ridge.png", width: 460, height: 600, view: .isometric)
        }
        exportGLB(ridge, "helical-ridge.glb", amber)
    }
    // 2) A smooth worm built the right way — threadedRod from a custom trapezoidal profile.
    //    Worm-like proportions: shallow tooth (cutDepth 1.8 on r6), pitch 5, several turns.
    let worm = ThreadProfile(vertices: [
        .init(axial: 0.000, depth: 1), .init(axial: 0.125, depth: 1),
        .init(axial: 0.375, depth: 0), .init(axial: 0.625, depth: 0),
        .init(axial: 0.875, depth: 1), .init(axial: 1.000, depth: 1),
    ]).flatMap {
        Shape.threadedRod(customProfile: $0, nominalDiameter: 12, pitch: 5,
                          cutDepth: 1.8, length: 22)
    }
    if let worm, let b = body(worm, "worm", steel) {
        render([b], to: "helical-worm.png", width: 460, height: 640, view: .isometric)
        exportGLB(worm, "helical-worm.glb", steel)
    }
}

// ── XCAF: a two-part assembly, each part its own colour (#210) ──
// Built as a real XCAF Document so the GLB carries per-part colours (box blue, sphere amber).
@MainActor
func xcafScene() {
    guard let box = Shape.box(width: 10, height: 20, depth: 30),
          let sphere0 = Shape.sphere(radius: 5) else { fail("xcaf: prims") }
    let sphere = sphere0.translated(by: SIMD3(50, 0, 0)) ?? sphere0
    var bodies: [ViewportBody] = []
    if let b = body(box, "box", blue) { bodies.append(b) }
    if let b = body(sphere, "sphere", amber) { bodies.append(b) }
    render(bodies, to: "xcaf-assembly.png", width: 680, height: 600, view: .isometric)
    if let doc = Document.create() {
        let bid = doc.addShape(box, makeAssembly: false)
        doc.node(at: bid)?.setColor(Color(red: 0.30, green: 0.52, blue: 0.90))
        let sid = doc.addShape(sphere, makeAssembly: false)
        doc.node(at: sid)?.setColor(Color(red: 0.95, green: 0.62, blue: 0.22))
        if doc.writeGLTF(to: modelsDir.appendingPathComponent("xcaf-assembly.glb"), binary: true) {
            print("exported xcaf-assembly.glb")
        }
    }
}

// Render only the scenes named on the command line after the output dir (default: all).
let sceneArgs = Set(CommandLine.arguments.dropFirst(2).map { $0.lowercased() })
func wants(_ name: String) -> Bool { sceneArgs.isEmpty || sceneArgs.contains(name) }

MainActor.assumeIsolated {
    if wants("booleans")    { booleansThreeOps() }
    if wants("threads")     { threadsScene() }
    if wants("threadforms") { threadFormsScene() }
    if wants("nut")         { nutScene() }
    if wants("wingnut")     { wingNutScene() }
    if wants("leadscrew")   { leadScrewScene() }
    if wants("helices")     { helicesScene() }
    if wants("lofts")       { loftsScene() }
    if wants("helical")     { helicalSweepsScene() }
    if wants("xcaf")        { xcafScene() }
}
