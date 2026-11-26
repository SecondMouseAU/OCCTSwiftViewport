// HeightfieldLatticeShadedWithEdgesTests.swift
// OCCTSwiftViewport Tests
//
// In `.shadedWithEdges` a heightfield draws its lattice over the shaded surface (#263), as a mesh
// draws its edges over its faces. These render it through the offscreen and the live renderer
// and pin what the PR decided: the lines are drawn only where the `.wireframe` lattice has them,
// at the same spacing; they are hidden behind a ridge and behind a nearer body; they do not
// z-fight with the surface they lie on; they are styled by `edgeLineConfiguration` and coloured as
// a mesh's edges are; the pick is the surface pick, on a line and between lines alike; and no other
// display mode changed.
//
// A "line pixel" below is a pixel that differs from the same scene in `.shaded`, which draws the
// identical surface without the lines.
//
// An opt-in suite at the end writes the before/after pictures of the PR:
//
//     VIEWPORT_LATTICE_RENDERS=/some/dir swift test --filter HeightfieldLatticeRenders

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Rig

/// A per-pixel yes / no, which prints as its size rather than every pixel when an expectation on it
/// fails.
struct LineMask: CustomTestStringConvertible {
    var bits: [Bool]
    var count: Int { bits.count }
    subscript(i: Int) -> Bool { bits[i] }
    var testDescription: String { "LineMask(\(bits.count) px, \(bits.filter { $0 }.count) set)" }
}

@MainActor
enum ShadedEdgesScene {

    /// A pale body, so the lattice's contrast colour is dark and clearly apart from the surface.
    static let pale = SIMD4<Float>(0.85, 0.85, 0.85, 1)
    /// A dark body, whose contrast colour is light.
    static let dark = SIMD4<Float>(0.08, 0.08, 0.12, 1)

    /// The pixels where `a` differs from `b` by more than `threshold` summed over the channels.
    static func differing(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24) -> LineMask {
        precondition(a.count == b.count)
        var mask = LineMask(bits: [Bool](repeating: false, count: a.count / 4))
        for i in 0..<mask.count {
            var sum = 0
            for c in 0..<3 { sum += abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c])) }
            mask.bits[i] = sum > threshold
        }
        return mask
    }

    static func count(
        _ mask: LineMask, in region: (x: ClosedRange<Int>, y: ClosedRange<Int>)? = nil
    )
        -> Int
    {
        let size = LatticeScene.size
        var n = 0
        for y in 0..<size {
            for x in 0..<size where mask[y * size + x] {
                if let region, !(region.x.contains(x) && region.y.contains(y)) { continue }
                n += 1
            }
        }
        return n
    }

    /// Whether `mask` is set within one pixel of the (fractional) pixel position `p`.
    static func hasInk(_ mask: LineMask, near p: SIMD2<Float>) -> Bool {
        let size = LatticeScene.size
        let cx = Int(p.x.rounded(.down))
        let cy = Int(p.y.rounded(.down))
        for dy in -1...1 {
            for dx in -1...1 {
                let x = cx + dx
                let y = cy + dy
                if x >= 0, y >= 0, x < size, y < size, mask[y * size + x] { return true }
            }
        }
        return false
    }

    /// The line pixels of `bodies` under `setup`: `.shadedWithEdges` against `.shaded`.
    static func lineMask(
        _ bodies: [ViewportBody], _ setup: LatticeSetup, _ render: LatticeScene.Render,
        threshold: Int = 24
    ) throws -> LineMask {
        var edges = setup
        edges.mode = .shadedWithEdges
        var shaded = setup
        shaded.mode = .shaded
        return differing(
            try render(bodies, edges), try render(bodies, shaded), threshold: threshold)
    }

    /// The world position of cell column / row `g` (a vertex stands at the cell's centre).
    static func centre(_ g: Int) -> Float { Float(g) + 0.5 }

    /// A 100 x 100 field rising 0.4 a cell along y.
    static func ramp() throws -> Heightfield { try LatticeScene.field { _, j in 0.4 * Float(j) } }

    /// Rolling ridges, for the pictures: smooth, so lines read, with sharp crests that hide others.
    static func ridges(size n: Int) throws -> Heightfield {
        var heights = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let t =
                    40 * sin(Float(x) * 0.004) * cos(Float(y) * 0.005)
                    + 15 * sin(Float(x) * 0.02 + Float(y) * 0.015)
                let r =
                    90 * pow(max(0, sin(Float(y) * 0.012)), 3) * (0.6 + 0.4 * sin(Float(x) * 0.008))
                heights[y * n + x] = t + r
            }
        }
        return try Heightfield(width: n, height: n, heights: heights)
    }
}

// MARK: - Drawing

@MainActor
@Suite("Heightfield lattice in .shadedWithEdges (#263)")
struct HeightfieldLatticeShadedWithEdgesTests {

    typealias Scene = ShadedEdgesScene

    // MARK: Which modes

    @Test(
        "The lattice is drawn over the surface in .shadedWithEdges only; every other mode is as before"
    )
    func modeRules() {
        for mode in DisplayMode.allCases {
            #expect(
                HeightfieldDrawSet.drawsLatticeOverSurface(in: mode) == (mode == .shadedWithEdges),
                "\(mode)")
            // In place of the surface: still `.wireframe` alone.
            #expect(HeightfieldDrawSet.drawsLattice(in: mode) == (mode == .wireframe), "\(mode)")
            // The plan carries a pitch for either.
            #expect(
                HeightfieldDrawSet.plansLattice(in: mode)
                    == (mode == .wireframe || mode == .shadedWithEdges), "\(mode)")
        }
    }

    // MARK: Lines

    @Test("Lines are drawn where the lattice is, in the body's surface and nowhere else")
    func linesOnlyWhereTheLatticeIs() throws {
        let body = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        let camera = LatticeScene.topDown
        // 16 px at 0.533 px a cell is 30 cells, a pitch of 32: lines at 0, 32, 64 and 96.
        let lineCells = [0, 32, 64, 96]
        for (name, render) in LatticeScene.renderers {
            var setup = LatticeSetup()
            setup.mode = .shadedWithEdges
            let edges = try render([body], setup)
            setup.mode = .shaded
            let shaded = try render([body], setup)
            let mask = Scene.differing(edges, shaded)

            for g in lineCells {
                let column = LatticeScene.project(SIMD3(Scene.centre(g), 50, 0), camera: camera)
                #expect(Scene.hasInk(mask, near: column), "\(name): no vertical line at \(g)")
                let row = LatticeScene.project(SIMD3(50, Scene.centre(g), 0), camera: camera)
                #expect(Scene.hasInk(mask, near: row), "\(name): no horizontal line at \(g)")
            }
            // Between the lines the surface is untouched, pixel for pixel.
            for (x, y) in [(62, 80), (78, 80), (95, 95), (78, 62), (100, 62), (78, 95)] {
                #expect(!mask[y * LatticeScene.size + x], "\(name): a line at (\(x), \(y))")
                let i = (y * LatticeScene.size + x) * 4
                #expect(Array(edges[i..<(i + 4)]) == Array(shaded[i..<(i + 4)]), "\(name)")
            }
            // A sparse lattice over a drawn surface: a small share of the footprint changed.
            let footprint = 54 * 54
            let region = (x: 53...106, y: 53...106)
            let changed = Scene.count(mask, in: region)
            #expect(changed > footprint / 20, "\(name): only \(changed) line pixels")
            #expect(changed < footprint * 3 / 10, "\(name): \(changed) pixels changed")
            // Outside the field nothing changed: the background and the rest of the frame.
            var outside = 0
            for y in 0..<LatticeScene.size {
                for x in 0..<LatticeScene.size
                where mask[y * LatticeScene.size + x] && !(53...106).contains(x)
                    && !(53...106).contains(y)
                {
                    outside += 1
                }
            }
            #expect(outside == 0, "\(name): \(outside) pixels changed outside the field")
            // And the surface is still drawn: it is not replaced by the lattice.
            #expect(LatticeScene.isDrawn(edges, 78, 80), "\(name): no surface")
        }
    }

    @Test("The lines are the .wireframe lattice's: the same lines at the same places")
    func sameLinesAsWireframe() throws {
        let field = try LatticeScene.field { i, j in 6 * sin(Float(i) * 0.15) * cos(Float(j) * 0.12)
        }
        let body = LatticeScene.body(field, color: Scene.pale)
        var setup = LatticeSetup()
        setup.camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 0), distance: 400, tilt: 0.5, orthographicScale: 200)
        setup.forcedLevel = 0
        for (name, render) in LatticeScene.renderers {
            let mask = try Scene.lineMask([body], setup, render)
            var wire = setup
            wire.mode = .wireframe
            let wireframe = try render([body], wire)
            let size = LatticeScene.size
            var wireInk = 0
            var covered = 0
            var maskInk = 0
            var near = 0
            for y in 0..<size {
                for x in 0..<size {
                    let inWire = LatticeScene.isDrawn(wireframe, x, y)
                    let inMask = mask[y * size + x]
                    if inWire {
                        wireInk += 1
                        // A wireframe line pixel has the edge colour over it, within a pixel.
                        if Scene.hasInk(mask, near: SIMD2(Float(x) + 0.5, Float(y) + 0.5)) {
                            covered += 1
                        }
                    }
                    if inMask {
                        maskInk += 1
                        if LatticeScene.hasInk(
                            wireframe, near: SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                        {
                            near += 1
                        }
                    }
                }
            }
            #expect(wireInk > 300, "\(name): the wireframe lattice has \(wireInk) px")
            // Lines hidden behind a crest are in the wireframe only, so not every wireframe pixel
            // is covered; but those drawn over the surface are the wireframe's.
            #expect(
                Double(near) > 0.97 * Double(maskInk),
                "\(name): \(near) of \(maskInk) line pixels are on a wireframe line")
            #expect(
                Double(covered) > 0.6 * Double(wireInk),
                "\(name): \(covered) of \(wireInk) wireframe pixels have a line")
        }
    }

    @Test("Lines behind a ridge are hidden: the surface is opaque to them")
    func linesBehindARidgeAreHidden() throws {
        // A wall across the front half, the camera tilted so the wall's top hides a strip of the
        // floor behind it. In `.wireframe` the floor lines in that strip show (a lattice is
        // see-through); here they must not, while the lines on the wall and on the floor beyond do.
        let wall: Float = 40
        let field = try LatticeScene.field { _, j in j < 50 ? wall : 0 }
        let body = LatticeScene.body(field, color: Scene.pale)
        let camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 20), distance: 400, tilt: 0.8, orthographicScale: 260)
        let back = camera.rotation.act(SIMD3<Float>(0, 0, 1))
        let perUnit = LatticeScene.pixelsPerUnit(camera)
        let pitch =
            1
            << HeightfieldLayout.latticeLevel(cellPixels: perUnit, latticePixels: 16, meshLevel: 0)
        var setup = LatticeSetup()
        setup.camera = camera
        setup.forcedLevel = 0

        var hidden: [SIMD3<Float>] = []
        var visible: [SIMD3<Float>] = []
        for gy in stride(from: 0, to: 100, by: pitch) where gy >= 50 {
            for i in stride(from: 10, to: 90, by: 9) {
                let floorPoint = SIMD3<Float>(Scene.centre(i), Scene.centre(gy), 0)
                guard back.z > 0.1 else { continue }
                // March toward the camera to the wall's top plane.
                let top = floorPoint + back * (wall / back.z)
                if top.y > 1, top.y < 49 {
                    hidden.append(floorPoint)
                } else if top.y > 51 {
                    visible.append(floorPoint)
                }
            }
        }
        try #require(hidden.count >= 3, "the camera does not look over the wall (back = \(back))")
        try #require(visible.count >= 3, "no floor line is in view beyond the wall")
        // The wall's own lines, which a hit near a hidden point could be mistaken for.
        var wallLines: [SIMD2<Float>] = []
        for gy in stride(from: 0, to: 50, by: pitch) {
            for i in 0..<100 {
                wallLines.append(
                    LatticeScene.project(
                        SIMD3(Scene.centre(i), Scene.centre(gy), wall), camera: camera))
            }
        }
        for gx in stride(from: 0, to: 100, by: pitch) {
            for j in 0..<50 {
                wallLines.append(
                    LatticeScene.project(
                        SIMD3(Scene.centre(gx), Scene.centre(j), wall), camera: camera))
            }
        }
        func isolated(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
            points.filter { point in
                let p = LatticeScene.project(point, camera: camera)
                return wallLines.allSatisfy { simd_distance($0, p) > 3 }
            }
        }
        let hiddenPoints = isolated(hidden)
        try #require(hiddenPoints.count >= 2, "every hidden floor point is beside a wall line")

        for (name, render) in LatticeScene.renderers {
            let mask = try Scene.lineMask([body], setup, render)
            for point in hiddenPoints {
                let p = LatticeScene.project(point, camera: camera)
                #expect(
                    !Scene.hasInk(mask, near: p),
                    "\(name): the floor line behind the wall at \(point) is drawn through it")
            }
            // The floor lines beyond the hidden strip are in view, and so are the wall's top.
            let seen = visible.filter {
                Scene.hasInk(mask, near: LatticeScene.project($0, camera: camera))
            }
            #expect(!seen.isEmpty, "\(name): no floor line in view is drawn")
            var wallTop = 0
            for gx in stride(from: 0, to: 100, by: pitch) {
                for j in stride(from: 5, to: 45, by: 7) {
                    let p = LatticeScene.project(
                        SIMD3(Scene.centre(gx), Scene.centre(j), wall), camera: camera)
                    if Scene.hasInk(mask, near: p) { wallTop += 1 }
                }
            }
            #expect(wallTop >= 8, "\(name): \(wallTop) line points on the wall's top")

            // In `.wireframe` the same points do show: the hiding is the surface's doing.
            var wire = setup
            wire.mode = .wireframe
            let wireframe = try render([body], wire)
            for point in hiddenPoints {
                #expect(
                    LatticeScene.hasInk(
                        wireframe, near: LatticeScene.project(point, camera: camera)),
                    "\(name): control: wireframe does not draw the line at \(point)")
            }
        }
    }

    @Test("A nearer body hides the lines, and the lines do not disturb it")
    func nearerBodyHidesTheLines() throws {
        let body = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        // A box above the middle of the field: 50 wide, 10 deep, top at 20, so the lines at cells
        // 32 and 64 run under it, clear of its own edges.
        var box = ViewportBody.box(
            id: "box", width: 50, height: 50, depth: 10, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(50, 50, 15, 1)
        let camera = LatticeScene.topDown
        // The line at cell 64 runs under the box (x = 50 +- 25 covers cells 25 to 75) and on past it.
        let hiddenUnderBox = LatticeScene.project(SIMD3(Scene.centre(64), 50, 0), camera: camera)
        let beyondBox = LatticeScene.project(SIMD3(Scene.centre(64), 90, 0), camera: camera)
        for (name, render) in LatticeScene.renderers {
            let mask = try Scene.lineMask([body, box], LatticeSetup(), render)
            #expect(!Scene.hasInk(mask, near: hiddenUnderBox), "\(name): a line through the box")
            #expect(Scene.hasInk(mask, near: beyondBox), "\(name): no line beside the box")
            // The box is as `.shaded` draws it, apart from its own edges: its centre is the same.
            var setup = LatticeSetup()
            setup.mode = .shadedWithEdges
            let edges = try render([body, box], setup)
            setup.mode = .shaded
            let shaded = try render([body, box], setup)
            let c = Int(LatticeScene.project(SIMD3(50, 50, 20), camera: camera).x)
            for dy in [-3, 0, 3] {
                let i = ((c + dy) * LatticeScene.size + c) * 4
                #expect(Array(edges[i..<(i + 4)]) == Array(shaded[i..<(i + 4)]), "\(name)")
            }
        }
    }

    @Test(
        "The lines do not z-fight with the surface: they are unbroken, in perspective and orthographic"
    )
    func noZFighting() throws {
        // Perspective, straight down on rolling ridges, where no line is hidden: every pixel of
        // the `.wireframe` lattice is a pixel of a line over the surface. The lattice and the
        // surface are two draws of the same triangles through two vertex functions, and their
        // depth agrees only to rounding in a perspective projection (an orthographic one agrees
        // exactly), so with no pull toward the viewer about a quarter of the line pixels are lost
        // to the depth test (measured: 78 percent kept at 1x, 92 at 4x MSAA).
        let ridges = LatticeScene.body(try Scene.ridges(size: 256), color: Scene.pale)
        for (name, render) in LatticeScene.renderers {
            for msaa in [1, 4] {
                var setup = LatticeSetup()
                setup.camera = HeightfieldScene.camera(
                    pivot: SIMD3(128, 128, 0), distance: 500, tilt: 0)
                setup.msaa = msaa
                setup.latticePixels = 8
                var wire = setup
                wire.mode = .wireframe
                let wireframe = LatticeScene.drawnCount(try render([ridges], wire))
                let lines = Scene.count(try Scene.lineMask([ridges], setup, render))
                #expect(wireframe > 1000, "\(name) msaa\(msaa): \(wireframe) wireframe px")
                #expect(
                    Double(lines) >= 0.97 * Double(wireframe),
                    "\(name) msaa\(msaa): \(lines) line pixels over the surface, \(wireframe) in the wireframe"
                )
            }
        }

        // A ramp seen from a tilted orthographic camera: the surface's depth varies across every
        // line pixel, and no line has a gap.
        let ramp = LatticeScene.body(try Scene.ramp(), color: Scene.pale)
        var rampSetup = LatticeSetup()
        rampSetup.camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 20), distance: 400, tilt: 0.8, orthographicScale: 220)
        rampSetup.forcedLevel = 0
        // The lines of constant x run up the picture at a fixed screen column.
        let perUnit = LatticeScene.pixelsPerUnit(rampSetup.camera)
        let pitch =
            1
            << HeightfieldLayout.latticeLevel(cellPixels: perUnit, latticePixels: 16, meshLevel: 0)
        for (name, render) in LatticeScene.renderers {
            for msaa in [1, 4] {
                var setup = rampSetup
                setup.msaa = msaa
                let mask = try Scene.lineMask([ramp], setup, render)
                var rows = 0
                var broken = 0
                for gx in stride(from: pitch, to: 100, by: pitch) {
                    // From the near edge to the far edge of the field, a few pixels in from each.
                    let a = LatticeScene.project(
                        SIMD3(Scene.centre(gx), 6, 0.4 * 6), camera: setup.camera)
                    let b = LatticeScene.project(
                        SIMD3(Scene.centre(gx), 93, 0.4 * 93), camera: setup.camera)
                    for y in Int(min(a.y, b.y))...Int(max(a.y, b.y)) {
                        // A horizontal lattice line crossing here is no gap in this one, but a gap
                        // in this one is a gap: look for any ink within a pixel of the column.
                        let x = a.x
                        rows += 1
                        if !Scene.hasInk(mask, near: SIMD2(x, Float(y) + 0.5)) { broken += 1 }
                    }
                }
                #expect(rows > 100, "\(name) msaa\(msaa): \(rows) rows")
                #expect(
                    broken == 0, "\(name) msaa\(msaa): \(broken) of \(rows) rows of a line missing")
            }
        }
    }

    @Test("MSAA draws the same lines")
    func withMSAA() throws {
        let body = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        let camera = LatticeScene.topDown
        for (name, render) in LatticeScene.renderers {
            var setup = LatticeSetup()
            setup.msaa = 4
            let mask = try Scene.lineMask([body], setup, render)
            let column = LatticeScene.project(SIMD3(Scene.centre(64), 50, 0), camera: camera)
            #expect(Scene.hasInk(mask, near: column), "\(name)")
            #expect(!mask[80 * LatticeScene.size + 78], "\(name)")
        }
    }

    // MARK: Style

    @Test(
        "Spacing follows heightfieldLatticePixels, as in .wireframe, and the plan carries the pitch"
    )
    func spacingIsTheWireframesSetting() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let body = LatticeScene.body(try LatticeScene.flatField())
        func pitches(_ setup: LatticeSetup) throws -> Set<UInt32> {
            _ = try #require(renderer.render(bodies: [body], options: LatticeScene.options(setup)))
            let plan = try #require(renderer.heightfieldState(forBodyID: "field")?.lastPlan)
            let buffer = try #require(plan.instanceBuffer)
            var found = Set<UInt32>()
            for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
                let instances = buffer.contents().advanced(
                    by: plan.ranges[level].first * MemoryLayout<HeightfieldTileInstance>.stride
                ).bindMemory(to: HeightfieldTileInstance.self, capacity: plan.ranges[level].count)
                for i in 0..<plan.ranges[level].count { found.insert(instances[i].lattice) }
            }
            return found
        }
        // 0.533 px a cell, 16 px wanted: 2^5; 256 px: 2^9 (the `.wireframe` test's numbers).
        var edges = LatticeSetup()
        edges.mode = .shadedWithEdges
        #expect(try pitches(edges) == [5])
        edges.latticePixels = 256
        #expect(try pitches(edges) == [9])
        // The default is the same 16 px.
        var wire = LatticeSetup()
        wire.mode = .wireframe
        #expect(try pitches(wire) == [5])

        // Coarser lines, fewer of them.
        let pale = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        var fine = LatticeSetup()
        fine.latticePixels = 8
        var coarse = LatticeSetup()
        coarse.latticePixels = 64
        for (name, render) in LatticeScene.renderers {
            let f = Scene.count(try Scene.lineMask([pale], fine, render))
            let c = Scene.count(try Scene.lineMask([pale], coarse, render))
            #expect(f > c, "\(name): 8 px \(f), 64 px \(c)")
        }
    }

    @Test(
        "Width and dash follow the edge configuration, and edge intensity applies, as for a mesh's edges"
    )
    func edgeConfigurationStylesTheLines() throws {
        let body = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        for (name, render) in LatticeScene.renderers {
            let thin = Scene.count(try Scene.lineMask([body], LatticeSetup(), render))
            var wide = LatticeSetup()
            wide.edge = EdgeLineConfiguration(width: 4)
            let wideCount = Scene.count(try Scene.lineMask([body], wide, render))
            #expect(
                Double(wideCount) > Double(thin) * 1.8, "\(name): 4 px \(wideCount), 1 px \(thin)")

            var dashed = LatticeSetup()
            dashed.edge = EdgeLineConfiguration(
                width: 1, dashPattern: EdgeLineDashPattern(dashLength: 6, gapLength: 6))
            let dashedCount = Scene.count(try Scene.lineMask([body], dashed, render))
            #expect(dashedCount < thin * 7 / 10, "\(name): dashed \(dashedCount), solid \(thin)")
            #expect(dashedCount > thin / 4, "\(name): dashed \(dashedCount), solid \(thin)")

            // Native Metal lines: one pixel and solid whatever the width and dash say.
            var native = LatticeSetup()
            native.edge = EdgeLineConfiguration(
                width: 4, dashPattern: EdgeLineDashPattern(dashLength: 6, gapLength: 6),
                useQuadExpansion: false)
            let nativeCount = Scene.count(try Scene.lineMask([body], native, render))
            #expect(
                abs(nativeCount - thin) < thin / 10 + 5, "\(name): native \(nativeCount), \(thin)")

            // `edgeIntensity` 0 hides a meshed body's edges, and so these (in `.wireframe` the
            // lattice ignores it, as an edge-only body's edges do).
            var off = LatticeSetup()
            off.edgeIntensity = 0
            #expect(Scene.count(try Scene.lineMask([body], off, render)) == 0, "\(name)")
        }
    }

    @Test("The lines are the contrast colour a mesh's edges get, not the body's colour")
    func contrastColour() throws {
        let camera = LatticeScene.topDown
        let p = LatticeScene.project(SIMD3(Scene.centre(64), 50, 0), camera: camera)
        let beside = SIMD2(Int(p.x.rounded(.down)) + 6, Int(p.y.rounded(.down)))
        func luminance(_ c: SIMD3<Int>) -> Double {
            0.299 * Double(c.x) + 0.587 * Double(c.y) + 0.114 * Double(c.z)
        }
        for (name, render) in LatticeScene.renderers {
            for (label, colour, darker) in [
                ("pale", Scene.pale, true), ("dark", Scene.dark, false),
            ] {
                let body = LatticeScene.body(try LatticeScene.flatField(), color: colour)
                var setup = LatticeSetup()
                setup.mode = .shadedWithEdges
                let pixels = try render([body], setup)
                // The centre of the line: the darkest (or lightest) pixel within a pixel of it.
                var line = SIMD3<Int>(repeating: darker ? 255 : 0)
                for dx in -1...1 {
                    let c = HeightfieldIntegrationTests.rgb(
                        pixels, Int(p.x.rounded(.down)) + dx, Int(p.y.rounded(.down)))
                    if darker ? luminance(c) < luminance(line) : luminance(c) > luminance(line) {
                        line = c
                    }
                }
                let surface = HeightfieldIntegrationTests.rgb(pixels, beside.x, beside.y)
                if darker {
                    #expect(
                        luminance(line) + 40 < luminance(surface),
                        "\(name) \(label): \(line) on \(surface)")
                } else {
                    #expect(
                        luminance(line) > luminance(surface) + 40,
                        "\(name) \(label): \(line) on \(surface)")
                }
            }
        }
    }

    @Test("Section planes clip the lines with the surface")
    func clipPlanes() throws {
        let body = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        let plane = ClipPlane(normal: SIMD3(1, 0, 0), distance: -50)
        for (name, render) in LatticeScene.renderers {
            var setup = LatticeSetup()
            let full = try Scene.lineMask([body], setup, render)
            setup.clipPlanes = [plane]
            let clipped = try Scene.lineMask([body], setup, render)
            // The plane hides one half of the field, surface and lines alike: what lines are left
            // are the unclipped lattice's on that half.
            func columns(_ mask: LineMask, _ range: Range<Int>) -> Int {
                var n = 0
                for y in 0..<LatticeScene.size {
                    for x in range where mask[y * LatticeScene.size + x] { n += 1 }
                }
                return n
            }
            let fullLeft = columns(full, 0..<78)
            let fullRight = columns(full, 84..<160)
            #expect(fullLeft > 100 && fullRight > 100, "\(name)")
            let clippedLeft = columns(clipped, 0..<78)
            let clippedRight = columns(clipped, 84..<160)
            let keptLeft = clippedLeft == fullLeft && clippedRight == 0
            let keptRight = clippedRight == fullRight && clippedLeft == 0
            #expect(
                keptLeft || keptRight,
                "\(name): left \(clippedLeft)/\(fullLeft), right \(clippedRight)/\(fullRight)")
        }
    }

    @Test("A translucent field draws its lattice too, as a translucent mesh draws its edges")
    func translucentField() throws {
        var colour = Scene.pale
        colour.w = 0.5
        let body = LatticeScene.body(try LatticeScene.flatField(), color: colour)
        let camera = LatticeScene.topDown
        let column = LatticeScene.project(SIMD3(Scene.centre(64), 50, 0), camera: camera)
        for (name, render) in LatticeScene.renderers {
            let mask = try Scene.lineMask([body], LatticeSetup(), render, threshold: 12)
            #expect(
                Scene.hasInk(mask, near: column), "\(name): no line under a translucent surface")
            #expect(!mask[80 * LatticeScene.size + 78], "\(name)")
        }
    }

    @Test("An overlay field and a field out of view get no lines")
    func overlayAndInvisible() throws {
        var overlay = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        overlay.renderLayer = .overlay
        var hiddenField = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        hiddenField.isVisible = false
        for (name, render) in LatticeScene.renderers {
            // An overlay surface draws in every mode, with no edges, as a widget does.
            #expect(
                Scene.count(try Scene.lineMask([overlay], LatticeSetup(), render)) == 0,
                "\(name): overlay lines")
            var setup = LatticeSetup()
            setup.mode = .shadedWithEdges
            let image = try render([hiddenField], setup)
            #expect(LatticeScene.drawnCount(image) == 0, "\(name): an invisible field drew")
        }
    }

    // MARK: Other modes

    @Test(
        "Every other display mode is unchanged: the lattice setting does nothing and no pitch is planned"
    )
    func otherModesAreUnchanged() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.field { i, j in 5 * sin(Float(i) * 0.2) * cos(Float(j) * 0.2) }
        let body = LatticeScene.body(field)
        for mode in DisplayMode.allCases where mode != .wireframe && mode != .shadedWithEdges {
            var a = LatticeSetup()
            a.mode = mode
            a.latticePixels = 1
            var b = a
            b.latticePixels = 256
            // Not even an edge style reaches them.
            var c = a
            c.edge = EdgeLineConfiguration(width: 6)
            for (name, render) in LatticeScene.renderers {
                let one = try render([body], a)
                #expect(
                    one == (try render([body], b)),
                    "\(name): \(mode) changed with the lattice setting")
                #expect(
                    one == (try render([body], c)), "\(name): \(mode) changed with the edge style")
                #expect(LatticeScene.isDrawn(one, 78, 80), "\(name): \(mode) draws no surface")
            }
            // The tile plan carries no pitch.
            _ = try #require(renderer.render(bodies: [body], options: LatticeScene.options(a)))
            let plan = try #require(renderer.heightfieldState(forBodyID: "field")?.lastPlan)
            let buffer = try #require(plan.instanceBuffer)
            for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
                let instances = buffer.contents().advanced(
                    by: plan.ranges[level].first * MemoryLayout<HeightfieldTileInstance>.stride
                ).bindMemory(to: HeightfieldTileInstance.self, capacity: plan.ranges[level].count)
                for i in 0..<plan.ranges[level].count {
                    #expect(instances[i].lattice == 0, "\(mode)")
                }
            }
        }
        // `.shadedWithEdges` does depend on it, and the lines are the only difference from `.shaded`.
        var coarse = LatticeSetup()
        coarse.mode = .shadedWithEdges
        coarse.latticePixels = 64
        var fine = coarse
        fine.latticePixels = 8
        #expect(try LatticeScene.offscreen([body], coarse) != LatticeScene.offscreen([body], fine))
    }

    @Test(
        "A mesh body beside a heightfield is drawn as it is without the field: the lattice pass leaves the state as it found it"
    )
    func meshBodyUnchanged() throws {
        // A box over the middle of the field. Its top face is the same pixels whether or not the
        // field (and so its lattice pass, which sets the depth state and cull mode) is in the scene.
        var box = ViewportBody.box(
            id: "box", width: 20, height: 20, depth: 20, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(50, 50, 10, 1)
        let field = LatticeScene.body(try LatticeScene.flatField(), color: Scene.pale)
        var setup = LatticeSetup()
        setup.mode = .shadedWithEdges
        let camera = LatticeScene.topDown
        let c = LatticeScene.project(SIMD3(50, 50, 20), camera: camera)
        let half = Int(10 * LatticeScene.pixelsPerUnit(camera)) - 2
        for (name, render) in LatticeScene.renderers {
            let with = try render([box, field], setup)
            let without = try render([box], setup)
            var differing = 0
            for y in (Int(c.y) - half)...(Int(c.y) + half) {
                for x in (Int(c.x) - half)...(Int(c.x) + half) {
                    let i = (y * LatticeScene.size + x) * 4
                    if Array(with[i..<(i + 4)]) != Array(without[i..<(i + 4)]) { differing += 1 }
                }
            }
            #expect(differing == 0, "\(name): \(differing) pixels of the box's top face changed")
        }
    }

    @Test("Offscreen and live draw the same lines")
    func liveMatchesOffscreen() throws {
        let field = try LatticeScene.field { i, j in 6 * sin(Float(i) * 0.15) * cos(Float(j) * 0.12)
        }
        let body = LatticeScene.body(field, color: Scene.pale)
        var setup = LatticeSetup()
        setup.camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 0), distance: 400, tilt: 0.7, orthographicScale: 200)
        let offscreen = try Scene.lineMask([body], setup, LatticeScene.offscreen)
        let live = try Scene.lineMask([body], setup, LatticeScene.live)
        var differing = 0
        for i in 0..<offscreen.count where offscreen[i] != live[i] { differing += 1 }
        #expect(Scene.count(offscreen) > 300)
        #expect(differing == 0, "\(differing) line pixels differ between offscreen and live")
    }
}

// MARK: - Tile borders

/// A lattice line on a tile border over the surface is as wide as any other (#262), from either side.
///
/// The rig is `HeightfieldLatticeBorderTests`': a long strip seen along its length, whose tiles
/// differ in pitch, so some borders are reached by one tile's pitch only.
@MainActor
@Suite("Heightfield lattice in .shadedWithEdges: tile borders (#262, #263)")
struct HeightfieldLatticeShadedWithEdgesBorderTests {

    typealias Rig = HeightfieldLatticeBorderTests
    typealias Side = HeightfieldLatticeBorderTests.Side

    static func body(_ side: Side) throws -> ViewportBody {
        LatticeScene.body(try side.field(), id: "strip-\(side)", color: ShadedEdgesScene.pale)
    }

    /// The line's width in pixels at `p`: the colour the lattice adds over the surface, summed
    /// across the line and divided by its value at the line's core, where the coverage is 1.
    static func width(edges: [UInt8], shaded: [UInt8], at p: SIMD2<Float>, side: Side) -> Float {
        var sum = 0
        var peak = 0
        for offset in -6...6 {
            let x = Int(p.x) + (side.longIsY ? 0 : offset)
            let y = Int(p.y) + (side.longIsY ? offset : 0)
            let i = (y * Rig.size + x) * 4
            var d = 0
            for c in 0..<3 { d += abs(Int(edges[i + c]) - Int(shaded[i + c])) }
            sum += d
            peak = max(peak, d)
        }
        return peak > 0 ? Float(sum) / Float(peak) : 0
    }

    static func render(
        _ renderer: OffscreenRenderer, side: Side, pivot: Float, mode: DisplayMode
    ) throws -> [UInt8] {
        let options = Rig.options(camera: side.camera(pivot: pivot), width: 4, mode: mode)
        return HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [try body(side)], options: options))
        ).pixels
    }

    @Test(
        "A border line is full width, whichever tile's pitch reaches it, and the plan carries the bits"
    )
    func borderLineIsFullWidth() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            var oneSided = 0
            for pivot in side.pivots {
                let camera = side.camera(pivot: pivot)
                // The `.shadedWithEdges` frame last, so the plan read back is its own.
                let shaded = try Self.render(renderer, side: side, pivot: pivot, mode: .shaded)
                let edges = try Self.render(
                    renderer, side: side, pivot: pivot, mode: .shadedWithEdges)
                let tiles = try Rig.tiles(renderer, bodyID: "strip-\(side)")
                // The plan has the borders `.wireframe` has: bits 24 to 27 of `levels`.
                _ = try Self.render(renderer, side: side, pivot: pivot, mode: .wireframe)
                let wireTiles = try Rig.tiles(renderer, bodyID: "strip-\(side)")
                #expect(tiles.count == wireTiles.count, "\(side)")
                for (key, tile) in tiles {
                    #expect(tile.levels == wireTiles[key]?.levels, "\(side) tile \(key)")
                    #expect(tile.lattice == wireTiles[key]?.lattice, "\(side) tile \(key)")
                }
                for border in Rig.borders(tiles, side: side) {
                    guard border.oneSided || border.bothSides,
                        let p = Rig.measurable(border, side: side, camera: camera)
                    else { continue }
                    let width = Self.width(edges: edges, shaded: shaded, at: p, side: side)
                    #expect(
                        abs(width - 4) < 0.4,
                        "\(side) pivot \(pivot): border \(border.position) pitches \(border.before)|\(border.after) is \(width) px"
                    )
                    if border.oneSided { oneSided += 1 }
                }
            }
            #expect(oneSided >= 1, "\(side): no border drawn by one tile's pitch alone")
        }
    }

    @Test("The live renderer draws the border line over the surface as wide too")
    func liveBorderLineIsFullWidth() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            let pivot = side.pivots[0]
            let camera = side.camera(pivot: pivot)
            _ = try Self.render(renderer, side: side, pivot: pivot, mode: .shadedWithEdges)
            let tiles = try Rig.tiles(renderer, bodyID: "strip-\(side)")
            func live(_ mode: DisplayMode) throws -> [UInt8] {
                var setup = LatticeSetup()
                setup.camera = camera
                setup.mode = mode
                setup.edge = EdgeLineConfiguration(width: 4)
                setup.latticePixels = Rig.latticePixels
                let rig = try LatticeScene.liveRig([try Self.body(side)], setup)
                return try #require(
                    rig.renderer.renderHeadlessBGRA(
                        width: Rig.size, height: Rig.size,
                        backgroundColor: HeightfieldScene.background))
            }
            let edges = try live(.shadedWithEdges)
            let shaded = try live(.shaded)
            var measured = 0
            for border in Rig.borders(tiles, side: side) where border.oneSided {
                guard let p = Rig.measurable(border, side: side, camera: camera) else { continue }
                let width = Self.width(edges: edges, shaded: shaded, at: p, side: side)
                #expect(abs(width - 4) < 0.4, "\(side): border \(border.position) is \(width) px")
                measured += 1
            }
            #expect(measured >= 1, "\(side): no border measured")
        }
    }
}

// MARK: - Picking

@MainActor
@Suite("Heightfield lattice in .shadedWithEdges: picking (#263)")
struct HeightfieldLatticeShadedWithEdgesPickTests {

    typealias Scene = ShadedEdgesScene

    private static func options(
        mode: DisplayMode, followsDisplayMode: Bool = true
    ) -> OffscreenRenderOptions {
        var setup = LatticeSetup()
        setup.mode = mode
        var options = LatticeScene.options(setup)
        options.pickRadius = 0
        options.pickFollowsDisplayMode = followsDisplayMode
        return options
    }

    @Test("The pick rules: the lattice is stamped in .wireframe only, never in .shadedWithEdges")
    func stampRules() {
        for mode in DisplayMode.allCases {
            let follows = PickStampRules(displayMode: mode, followsDisplayMode: true)
            #expect(follows.stampsHeightfieldLattice == (mode == .wireframe), "\(mode)")
            // The surface is stamped wherever the lattice is drawn over it.
            if HeightfieldDrawSet.drawsLatticeOverSurface(in: mode) {
                #expect(follows.stampsSurfaces, "\(mode)")
            }
            // With the setting off the whole surface is stamped, and the lattice never.
            let all = PickStampRules(displayMode: mode, followsDisplayMode: false)
            #expect(all.stampsSurfaces, "\(mode)")
            #expect(!all.stampsHeightfieldLattice, "\(mode)")
        }
    }

    @Test(
        "The pick over a lattice is the surface pick: the same texels as .shaded, on a line and off it"
    )
    func pickIsTheSurfacePick() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let body = LatticeScene.body(field)
        for follows in [true, false] {
            let edges = try #require(
                renderer.renderPickMap(
                    bodies: [body],
                    options: Self.options(mode: .shadedWithEdges, followsDisplayMode: follows)))
            let shaded = try #require(
                renderer.renderPickMap(
                    bodies: [body],
                    options: Self.options(mode: .shaded, followsDisplayMode: follows)))
            #expect(edges.texels == shaded.texels, "followsDisplayMode \(follows)")

            // A pixel on the line at cell 64 (px 87) gives the cell, as a face, with the payload.
            let onLine = SIMD2(87, 80)
            let hit = try #require(edges.pick(at: onLine), "no hit on a line")
            #expect(hit.bodyID == "field")
            #expect(hit.kind == .face)
            let cell = try #require(hit.heightfield)
            let expected = HeightfieldLatticeTests.cell(atPixel: onLine)
            #expect(
                abs(cell.cell.x - expected.x) <= 1 && cell.cell.y == expected.y,
                "\(cell.cell) vs \(expected)")
            #expect(hit.triangleIndex == cell.cellIndex)
            let truth = try #require(field.sample(x: cell.cell.x, y: cell.cell.y))
            #expect(cell.height == truth.height)

            // Between the lines the surface pick, with its payload: unlike `.wireframe`, not nil.
            for pixel in [SIMD2(78, 80), SIMD2(62, 62), SIMD2(95, 95)] {
                let between = try #require(edges.pick(at: pixel), "\(pixel) missed the surface")
                #expect(between.kind == .face)
                let payload = try #require(between.heightfield)
                let want = HeightfieldLatticeTests.cell(atPixel: pixel)
                #expect(abs(payload.cell.x - want.x) <= 1 && abs(payload.cell.y - want.y) <= 1)
            }
        }
    }

    @Test("A headless pick over the lattice equals the live pick")
    func headlessPickEqualsLivePick() async throws {
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: LatticeScene.topDown, width: LatticeScene.size,
            height: LatticeScene.size, sampleCount: 1)
        rig.controller.displayMode = .shadedWithEdges
        _ = try #require(
            rig.renderer.renderHeadlessBGRA(
                width: LatticeScene.size, height: LatticeScene.size,
                backgroundColor: HeightfieldScene.background))
        guard let renderer = OffscreenRenderer() else { return }
        let options = Self.options(mode: .shadedWithEdges)
        let map = try #require(renderer.renderPickMap(bodies: bodies, options: options))
        for pixel in [SIMD2(87, 80), SIMD2(78, 80), SIMD2(62, 62), SIMD2(95, 95), SIMD2(80, 87)] {
            let live = try #require(await rig.pick(pixel), "no live hit at \(pixel)")
            let offscreen = try #require(map.pick(at: pixel), "no headless hit at \(pixel)")
            #expect(live.heightfield == offscreen.heightfield, "\(pixel)")
            #expect(live.triangleIndex == offscreen.triangleIndex, "\(pixel)")
            #expect(live.kind == offscreen.kind, "\(pixel)")
        }
        // And refinePick makes the cell exact, on a line as on the surface.
        let onLine = SIMD2(87, 80)
        let live = try #require(await rig.pick(onLine))
        let ndc = SIMD2(
            (Float(onLine.x) + 0.5) / 160 * 2 - 1, 1 - (Float(onLine.y) + 0.5) / 160 * 2)
        let ray = Ray.fromCamera(ndc: ndc, cameraState: LatticeScene.topDown, aspectRatio: 1)
        let truth = try #require(field.raycast(origin: ray.origin, direction: ray.direction)).cell
        let refined = try #require(rig.controller.refinePick(live, ndc: ndc, bodies: bodies))
        #expect(refined.heightfield?.cell == truth)
    }
}

// MARK: - Pictures (opt-in)

/// Writes the pictures of the lattice over the surface for a human to look at.
///
/// Nothing here asserts a thing.
@MainActor
@Suite(
    "Heightfield lattice renders (VIEWPORT_LATTICE_RENDERS=dir)",
    .enabled(if: ProcessInfo.processInfo.environment["VIEWPORT_LATTICE_RENDERS"] != nil),
    .serialized)
struct HeightfieldLatticeRenders {

    @Test(
        "1024 x 1024 field, grazing and top-down, in every mode that shows the surface or the lattice"
    )
    func writeRenders() throws {
        let directory = try #require(
            ProcessInfo.processInfo.environment["VIEWPORT_LATTICE_RENDERS"])
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let tag = ProcessInfo.processInfo.environment["VIEWPORT_LATTICE_TAG"] ?? "render"
        guard let renderer = OffscreenRenderer() else { return }
        let body = HeightfieldScene.body(try ShadedEdgesScene.ridges(size: 1024))
        func camera(tilt: Float, distance: Float) -> CameraState {
            CameraState(
                rotation: simd_quatf(angle: 0.35, axis: SIMD3(0, 0, 1))
                    * simd_quatf(angle: tilt, axis: SIMD3(1, 0, 0)),
                distance: distance, pivot: SIMD3(512, 512, 0))
        }
        let views: [(String, CameraState)] = [
            ("grazing", camera(tilt: 1.30, distance: 1500)),
            ("grazing4deg", camera(tilt: 1.50, distance: 1400)),
            ("topdown", camera(tilt: 0, distance: 1800)),
        ]
        for (viewName, view) in views {
            for mode in DisplayMode.allCases where mode != .rendered {
                var options = HeightfieldScene.options(
                    width: 1024, height: 1024, camera: view, displayMode: mode)
                options.msaaSampleCount = 4
                options.backgroundColor = SIMD4(0.12, 0.12, 0.14, 1)
                let image = try #require(renderer.render(bodies: [body], options: options))
                let p = HeightfieldScene.pixels(image)
                HeightfieldScene.writePNG(
                    p.pixels, width: p.width, height: p.height,
                    to: "\(directory)/\(mode.rawValue)-\(viewName)-\(tag).png")
            }
        }
    }
}
