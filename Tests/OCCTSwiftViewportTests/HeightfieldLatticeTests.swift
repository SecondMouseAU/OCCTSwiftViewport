// HeightfieldLatticeTests.swift
// OCCTSwiftViewport Tests
//
// A heightfield in `.wireframe` draws a lattice on its displaced surface (#254). These render it,
// through the offscreen and the live renderer, and pin what the PR decided: the lines, their
// spacing in screen pixels, that they sit on the same surface the shaded passes draw, that lines
// behind a ridge show (see-through, as a mesh's edges do), the edge configuration's style, clip
// planes and transforms, what is picked, and that no other display mode changed.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Rig

/// What one lattice render varies.
@MainActor
struct LatticeSetup {
    var camera = LatticeScene.topDown
    var mode: DisplayMode = .wireframe
    var edge = EdgeLineConfiguration.default
    var clipPlanes: [ClipPlane] = []
    var latticePixels: Float?
    var meshCellPixels: Float?
    var forcedLevel: Int?
    var msaa = 1
    var edgeIntensity: Float?
}

@MainActor
enum LatticeScene {
    static let size = 160

    /// Top-down orthographic camera over a 100 x 100 field: 300 world units across the view, so
    /// 160 / 300 pixels per world unit.
    static let topDown = HeightfieldIntegrationTests.topDown

    static let green = SIMD4<Float>(0.1, 0.7, 0.1, 1)

    /// A drawable pixel is one that is not the (magenta) background.
    static func isDrawn(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return !HeightfieldIntegrationTests.isBackground(pixels, x, y)
    }

    static func drawnCount(_ pixels: [UInt8], in rect: ClosedRange<Int>? = nil) -> Int {
        var count = 0
        for y in 0..<size {
            for x in 0..<size where isDrawn(pixels, x, y) {
                if let rect, !(rect.contains(x) && rect.contains(y)) { continue }
                count += 1
            }
        }
        return count
    }

    /// Whether a drawn pixel lies within one pixel of the (fractional) pixel position `p`.
    static func hasInk(_ pixels: [UInt8], near p: SIMD2<Float>) -> Bool {
        let cx = Int(p.x.rounded(.down))
        let cy = Int(p.y.rounded(.down))
        for dy in -1...1 {
            for dx in -1...1 where isDrawn(pixels, cx + dx, cy + dy) { return true }
        }
        return false
    }

    /// The pixel position of a world point under an orthographic `camera`.
    static func project(_ p: SIMD3<Float>, camera: CameraState) -> SIMD2<Float> {
        let v = camera.viewMatrix * SIMD4(p, 1)
        let perPixel = camera.orthographicScale / Float(size)
        return SIMD2(Float(size) / 2 + v.x / perPixel, Float(size) / 2 - v.y / perPixel)
    }

    /// Pixels per world unit under an orthographic camera.
    static func pixelsPerUnit(_ camera: CameraState) -> Float {
        Float(size) / camera.orthographicScale
    }

    /// A flat 100 x 100 field.
    static func flatField(height: Float = 0) throws -> Heightfield {
        try Heightfield(width: 100, height: 100, initialHeight: height)
    }

    /// A field of `size` cells whose height is `f(i, j)`.
    static func field(_ n: Int = 100, _ f: (Int, Int) -> Float) throws -> Heightfield {
        var heights = [Float](repeating: 0, count: n * n)
        for j in 0..<n { for i in 0..<n { heights[j * n + i] = f(i, j) } }
        return try Heightfield(width: n, height: n, heights: heights)
    }

    static func body(
        _ field: Heightfield, id: String = "field", color: SIMD4<Float> = green
    ) -> ViewportBody {
        HeightfieldScene.body(field, id: id, color: color)
    }

    // MARK: Renderers

    typealias Render = ([ViewportBody], LatticeSetup) throws -> [UInt8]

    @MainActor
    static func offscreen(_ bodies: [ViewportBody], _ setup: LatticeSetup) throws -> [UInt8] {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            throw HeightfieldPickRig.Unavailable()
        }
        renderer.heightfieldForcedLevel = setup.forcedLevel
        return HeightfieldScene.pixels(
            try #require(
                renderer.render(bodies: bodies, options: options(setup)))
        ).pixels
    }

    @MainActor
    static func options(_ setup: LatticeSetup) -> OffscreenRenderOptions {
        var options = HeightfieldScene.options(
            width: size, height: size, camera: setup.camera, displayMode: setup.mode)
        options.edgeLineConfiguration = setup.edge
        options.clipPlanes = setup.clipPlanes
        options.msaaSampleCount = setup.msaa
        if let intensity = setup.edgeIntensity { options.edgeIntensity = intensity }
        if let pixels = setup.latticePixels { options.heightfieldLatticePixels = pixels }
        if let pixels = setup.meshCellPixels { options.heightfieldMeshCellPixels = pixels }
        return options
    }

    @MainActor
    static func liveRig(
        _ bodies: [ViewportBody], _ setup: LatticeSetup
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var config = ViewportConfiguration()
        config.initialCameraState = setup.camera
        config.backgroundColor = HeightfieldScene.background
        config.showViewCube = false
        config.msaaSampleCount = setup.msaa
        config.enableSilhouettes = false
        config.edgeLineConfiguration = setup.edge
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: 0)
        if let pixels = setup.latticePixels { config.heightfieldLatticePixels = pixels }
        if let pixels = setup.meshCellPixels { config.heightfieldMeshCellPixels = pixels }
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        config.lightingConfiguration = lighting
        let controller = ViewportController(configuration: config)
        controller.displayMode = setup.mode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        controller.clipPlanes = setup.clipPlanes
        if let intensity = setup.edgeIntensity { controller.edgeIntensity = intensity }
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping")
            throw HeightfieldPickRig.Unavailable()
        }
        renderer.heightfieldCache.forcedLevel = setup.forcedLevel
        return (controller, renderer)
    }

    @MainActor
    static func live(_ bodies: [ViewportBody], _ setup: LatticeSetup) throws -> [UInt8] {
        let rig = try liveRig(bodies, setup)
        return try #require(
            rig.renderer.renderHeadlessBGRA(
                width: size, height: size, backgroundColor: HeightfieldScene.background))
    }

    @MainActor
    static var renderers: [(name: String, render: Render)] {
        [
            ("offscreen", { try LatticeScene.offscreen($0, $1) }),
            ("live", { try LatticeScene.live($0, $1) }),
        ]
    }
}

// MARK: - Spacing and drawing

@MainActor
@Suite("Heightfield lattice (#254)")
struct HeightfieldLatticeTests {

    // MARK: Pitch choice

    @Test(
        "The lattice pitch is the smallest power of two of cells that spans the target, never finer than the mesh"
    )
    func latticeLevelChoice() {
        // 2 px a cell, 16 px wanted: 8 cells, 2^3.
        #expect(HeightfieldLayout.latticeLevel(cellPixels: 2, latticePixels: 16, meshLevel: 0) == 3)
        // 3 px a cell: 5.3 cells wanted, so 8 (24 px), not 4 (12 px, under the target).
        #expect(HeightfieldLayout.latticeLevel(cellPixels: 3, latticePixels: 16, meshLevel: 0) == 3)
        // Exactly on a power of two stays there.
        #expect(HeightfieldLayout.latticeLevel(cellPixels: 4, latticePixels: 16, meshLevel: 0) == 2)
        // A cell wider than the target: every cell.
        #expect(
            HeightfieldLayout.latticeLevel(cellPixels: 40, latticePixels: 16, meshLevel: 0) == 0)
        // Never finer than the tile's mesh cell: no mesh edge lies between.
        #expect(
            HeightfieldLayout.latticeLevel(cellPixels: 0.5, latticePixels: 1, meshLevel: 3) == 3)
        #expect(HeightfieldLayout.latticeLevel(cellPixels: 2, latticePixels: 1, meshLevel: 2) == 2)
        // Far away or degenerate: coarsest, and capped (the shader reads 4 bits).
        #expect(
            HeightfieldLayout.latticeLevel(cellPixels: 1e-9, latticePixels: 16, meshLevel: 0)
                == HeightfieldLayout.maxLatticeLevel)
        #expect(
            HeightfieldLayout.latticeLevel(cellPixels: 0, latticePixels: 16, meshLevel: 0)
                == HeightfieldLayout.maxLatticeLevel)
        #expect(HeightfieldLayout.maxLatticeLevel <= 15)
        #expect(1 << HeightfieldLayout.maxLatticeLevel >= Heightfield.maximumDimension)
        // The pitch always spans at least the target on screen (until capped), and is the
        // smallest power of two that does.
        for cellPixels: Float in [0.07, 0.3, 0.5, 1, 1.7, 2.6, 5, 11] {
            for target: Float in [1, 4, 8, 16, 32, 100] {
                let level = HeightfieldLayout.latticeLevel(
                    cellPixels: cellPixels, latticePixels: target, meshLevel: 0)
                let pitchPixels = cellPixels * Float(1 << level)
                #expect(level == 0 || pitchPixels >= target, "\(cellPixels) px, \(target)")
                if level > 0 {
                    #expect(
                        cellPixels * Float(1 << (level - 1)) < target, "\(cellPixels) px, \(target)"
                    )
                }
            }
        }
    }

    @Test("The lattice is drawn in the modes that show edges but no surface, which is .wireframe")
    func drawsLatticeModes() {
        for mode in DisplayMode.allCases {
            #expect(HeightfieldDrawSet.drawsLattice(in: mode) == (mode == .wireframe), "\(mode)")
        }
    }

    // MARK: Lines

    /// The world position of cell column / row `g` (a vertex stands at the cell's centre).
    private static func centre(_ g: Int) -> Float { Float(g) + 0.5 }

    @Test("Wireframe draws a lattice on the surface, in the body's colour, and no surface")
    func wireframeDrawsLatticeLines() throws {
        let field = try LatticeScene.flatField()
        let body = LatticeScene.body(field)
        let camera = LatticeScene.topDown
        let perUnit = LatticeScene.pixelsPerUnit(camera)
        #expect(abs(perUnit - 160.0 / 300.0) < 1e-6)
        // 16 px at 0.533 px a cell is 30 cells, so a pitch of 32: lines at 0, 32, 64 and 96.
        let lineCells = [0, 32, 64, 96]
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([body], LatticeSetup())
            // On the lines.
            for g in lineCells {
                let column = LatticeScene.project(SIMD3(Self.centre(g), 50, 0), camera: camera)
                #expect(
                    LatticeScene.hasInk(pixels, near: column), "\(name): no vertical line at \(g)")
                let row = LatticeScene.project(SIMD3(50, Self.centre(g), 0), camera: camera)
                #expect(
                    LatticeScene.hasInk(pixels, near: row), "\(name): no horizontal line at \(g)")
            }
            // Between them: the surface is not drawn.
            for (x, y) in [(62, 80), (78, 80), (95, 80), (62, 62), (78, 95), (95, 95)] {
                #expect(!LatticeScene.isDrawn(pixels, x, y), "\(name): filled at (\(x), \(y))")
            }
            // A sparse lattice, not a surface: a small share of the field's footprint.
            let footprint = 54 * 54
            let drawn = LatticeScene.drawnCount(pixels, in: 53...106)
            #expect(drawn > footprint / 20, "\(name): only \(drawn) px drawn")
            #expect(drawn < footprint * 3 / 10, "\(name): \(drawn) px drawn is a filled surface")
            // The body's colour, at the centre of a line.
            let centre = LatticeScene.project(SIMD3(Self.centre(64), 50, 0), camera: camera)
            let c = HeightfieldIntegrationTests.rgb(
                pixels, Int(centre.x.rounded(.down)), Int(centre.y.rounded(.down)))
            #expect(c.y > c.x + 40 && c.y > c.z + 40, "\(name): line colour \(c) is not green")
        }
    }

    @Test("Lattice lines are anti-aliased: MSAA on draws the same lines")
    func latticeWithMSAA() throws {
        let body = LatticeScene.body(try LatticeScene.flatField())
        let camera = LatticeScene.topDown
        for (name, render) in LatticeScene.renderers {
            var setup = LatticeSetup()
            setup.msaa = 4
            let pixels = try render([body], setup)
            let column = LatticeScene.project(SIMD3(Self.centre(64), 50, 0), camera: camera)
            #expect(LatticeScene.hasInk(pixels, near: column), "\(name)")
            #expect(!LatticeScene.isDrawn(pixels, 78, 80), "\(name)")
        }
    }

    @Test("The lattice spacing follows the zoom: about the target in pixels at any scale")
    func spacingFollowsZoom() throws {
        let body = LatticeScene.body(try LatticeScene.flatField())
        for scale: Float in [75, 150, 300, 600] {
            var camera = LatticeScene.topDown
            camera.orthographicScale = scale
            var setup = LatticeSetup()
            setup.camera = camera
            let pixels = try LatticeScene.offscreen([body], setup)
            // Line runs along the row through the middle of the view, as the pixel x of each.
            // Choose a row between two horizontal lines.
            let perUnit = LatticeScene.pixelsPerUnit(camera)
            let expectedLevel = HeightfieldLayout.latticeLevel(
                cellPixels: perUnit, latticePixels: Heightfield.defaultLatticePixels,
                meshLevel: HeightfieldLayout.level(
                    cellPixels: perUnit, targetPixels: Heightfield.defaultMeshCellPixels))
            let pitchCells = Float(1 << expectedLevel)
            let pitchPixels = pitchCells * perUnit
            #expect(
                pitchPixels >= Heightfield.defaultLatticePixels
                    && pitchPixels < 2 * Heightfield.defaultLatticePixels + 0.001,
                "scale \(scale): pitch \(pitchPixels) px")
            // Every line the pitch predicts that is inside the view is drawn.
            var checked = 0
            var g = 0
            while g < 100 {
                let column = LatticeScene.project(SIMD3(Self.centre(g), 50, 0), camera: camera)
                // A row the horizontal lines miss: halfway between two of them.
                let rowWorld = Self.centre(
                    Int(50 / pitchCells) * Int(pitchCells) + Int(pitchCells) / 2)
                var p = LatticeScene.project(SIMD3(Self.centre(g), rowWorld, 0), camera: camera)
                p.x = column.x
                if p.x > 2 && p.x < 157 && p.y > 2 && p.y < 157 {
                    #expect(
                        LatticeScene.hasInk(pixels, near: p), "scale \(scale): no line at cell \(g)"
                    )
                    checked += 1
                    // Halfway to the next line there is none.
                    var between = p
                    between.x += pitchPixels * 0.5
                    if between.x < 157 {
                        #expect(
                            !LatticeScene.hasInk(pixels, near: between),
                            "scale \(scale): a line between \(g) and the next")
                    }
                }
                g += Int(pitchCells)
            }
            #expect(checked >= 2, "scale \(scale): only \(checked) lines checked")
        }
    }

    @Test("Tiles take their pitch from the plan; a mesh cell target above the lattice target wins")
    func planCarriesThePitch() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.flatField()
        let body = LatticeScene.body(field)
        func tileLattice(_ setup: LatticeSetup) throws -> (lattice: Set<UInt32>, level: Set<Int>) {
            _ = try #require(
                renderer.render(bodies: [body], options: LatticeScene.options(setup)))
            let plan = try #require(
                renderer.heightfieldState(forBodyID: "field")?.lastPlan)
            let buffer = try #require(plan.instanceBuffer)
            var lattice = Set<UInt32>()
            var levels = Set<Int>()
            for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
                let instances = buffer.contents().advanced(
                    by: plan.ranges[level].first * MemoryLayout<HeightfieldTileInstance>.stride
                ).bindMemory(to: HeightfieldTileInstance.self, capacity: plan.ranges[level].count)
                for i in 0..<plan.ranges[level].count { lattice.insert(instances[i].lattice) }
                levels.insert(level)
            }
            return (lattice, levels)
        }
        // 0.533 px a cell: mesh level 2 (4 cells, 2.1 px). A 16 px lattice wants 30 cells: 2^5.
        let wireframe = try tileLattice(LatticeSetup())
        #expect(wireframe.level == [2])
        #expect(wireframe.lattice == [5])
        // A 1 px lattice is finer than the mesh cell, so it is the mesh cell, 2^2.
        var fine = LatticeSetup()
        fine.latticePixels = 1
        #expect(try tileLattice(fine).lattice == [2])
        // A 256 px lattice spans 480 cells: 2^9.
        var coarse = LatticeSetup()
        coarse.latticePixels = 256
        #expect(try tileLattice(coarse).lattice == [9])
        // In every other mode the plan carries no lattice.
        var shaded = LatticeSetup()
        shaded.mode = .shaded
        #expect(try tileLattice(shaded).lattice == [0])
    }

    // MARK: Depth

    /// A ramp rising 0.4 a cell along y, seen from a tilted orthographic camera: the lattice lines
    /// land where the surface is, not where a flat sheet would put them.
    @Test("The lattice sits on the displaced surface the shaded passes draw")
    func latticeSitsOnTheSurface() throws {
        let field = try LatticeScene.field { _, j in 0.4 * Float(j) }
        let body = LatticeScene.body(field)
        var camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 20), distance: 400, tilt: 0.8, orthographicScale: 300)
        camera.orthographicScale = 220
        let perUnit = LatticeScene.pixelsPerUnit(camera)
        // 16 px at perUnit px a cell.
        let pitch =
            1
            << HeightfieldLayout.latticeLevel(
                cellPixels: perUnit, latticePixels: 16, meshLevel: 0)
        var setup = LatticeSetup()
        setup.camera = camera
        setup.forcedLevel = 0  // exact heights: no min-lowering
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([body], setup)
            var checked = 0
            // Vertical lines (constant x) at the lattice columns, sampled up the slope.
            for gx in stride(from: 0, to: 100, by: pitch) {
                for j in stride(from: 8, to: 92, by: 7) {
                    let world = SIMD3<Float>(Self.centre(gx), Self.centre(j), 0.4 * Float(j))
                    let p = LatticeScene.project(world, camera: camera)
                    #expect(
                        LatticeScene.hasInk(pixels, near: p),
                        "\(name): no ink where the surface is, line x=\(gx) y=\(j) at \(p)")
                    checked += 1
                }
            }
            // Horizontal lines (constant y), sampled along them.
            for gy in stride(from: 0, to: 100, by: pitch) {
                for i in stride(from: 8, to: 92, by: 11) {
                    let world = SIMD3<Float>(Self.centre(i), Self.centre(gy), 0.4 * Float(gy))
                    let p = LatticeScene.project(world, camera: camera)
                    #expect(
                        LatticeScene.hasInk(pixels, near: p),
                        "\(name): no ink where the surface is, line y=\(gy) x=\(i) at \(p)")
                    checked += 1
                }
            }
            #expect(checked > 40, "\(name): \(checked) points")
            // The same horizontal lines on a flat sheet (a vertical line's screen column does
            // not depend on height, so only these tell) are somewhere else: most of their points
            // have no ink in this picture, so passing above is not an accident of dense lines.
            var flatHits = 0
            var flatTotal = 0
            for gy in stride(from: pitch, to: 100, by: pitch) {
                for i in [12, 20, 44, 52, 76, 84] {
                    let flat = LatticeScene.project(
                        SIMD3(Self.centre(i), Self.centre(gy), 0), camera: camera)
                    if LatticeScene.hasInk(pixels, near: flat) { flatHits += 1 }
                    flatTotal += 1
                }
            }
            #expect(
                flatHits * 2 < flatTotal,
                "\(name): \(flatHits) of \(flatTotal) flat points have ink")
        }
    }

    /// Lines behind a ridge are drawn: a lattice is see-through, as a mesh's edges are in `.wireframe`.
    ///
    /// A wall across the front half, with the camera tilted so the wall's top hides a strip of the
    /// floor behind it.
    @Test("Lines behind a ridge are drawn: the lattice is see-through")
    func linesBehindARidgeShow() throws {
        let wall: Float = 40
        let field = try LatticeScene.field { _, j in j < 50 ? wall : 0 }
        let body = LatticeScene.body(field)
        let camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 20), distance: 400, tilt: 0.8, orthographicScale: 260)
        // The camera's direction toward the viewer, in the world.
        let back = camera.rotation.act(SIMD3<Float>(0, 0, 1))
        let perUnit = LatticeScene.pixelsPerUnit(camera)
        let pitch =
            1
            << HeightfieldLayout.latticeLevel(
                cellPixels: perUnit, latticePixels: 16, meshLevel: 0)
        var setup = LatticeSetup()
        setup.camera = camera
        setup.forcedLevel = 0

        // Floor points of lines behind the wall (y >= 50) that the wall's top hides from the camera.
        var hiddenPoints: [SIMD3<Float>] = []
        for gy in stride(from: 0, to: 100, by: pitch) where gy >= 50 {
            for i in stride(from: 10, to: 90, by: 9) {
                let floorPoint = SIMD3<Float>(Self.centre(i), Self.centre(gy), 0)
                // March toward the camera to the wall's top plane.
                let t = wall / back.z
                let top = floorPoint + back * t
                if back.z > 0.1, top.y > 1, top.y < 49 { hiddenPoints.append(floorPoint) }
            }
        }
        try #require(
            hiddenPoints.count >= 3,
            "the camera does not look over the wall (back = \(back)); \(hiddenPoints.count) hidden")
        // The wall's own lines are far enough away from those floor points on screen that a hit
        // there is the floor's line.
        var wallLines: [SIMD2<Float>] = []
        for gy in stride(from: 0, to: 50, by: pitch) {
            for i in stride(from: 0, to: 100, by: 1) {
                wallLines.append(
                    LatticeScene.project(
                        SIMD3(Self.centre(i), Self.centre(gy), wall), camera: camera))
            }
        }
        for gx in stride(from: 0, to: 100, by: pitch) {
            for j in stride(from: 0, to: 50, by: 1) {
                wallLines.append(
                    LatticeScene.project(
                        SIMD3(Self.centre(gx), Self.centre(j), wall), camera: camera))
            }
        }
        let isolated = hiddenPoints.filter { point in
            let p = LatticeScene.project(point, camera: camera)
            return wallLines.allSatisfy { simd_distance($0, p) > 3 }
        }
        try #require(isolated.count >= 2, "every hidden floor point is beside a wall line")
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([body], setup)
            for point in isolated {
                let p = LatticeScene.project(point, camera: camera)
                #expect(
                    LatticeScene.hasInk(pixels, near: p),
                    "\(name): the floor line behind the wall at \(point) is hidden")
            }
        }
    }

    /// Two fields whose lines coincide on screen, the nearer drawn first: the farther field's lines
    /// still show, so the lattice writes no depth (a line of one field never knocks out another's).
    @Test("The lattice writes no depth: a farther lattice drawn after a nearer one still shows")
    func latticeWritesNoDepth() throws {
        let field = try LatticeScene.flatField()
        var near = LatticeScene.body(field, id: "near", color: SIMD4(0.1, 0.8, 0.1, 1))
        near.transform.columns.3 = SIMD4(0, 0, 30, 1)
        let far = LatticeScene.body(field, id: "far", color: SIMD4(0.9, 0.1, 0.1, 1))
        let p = LatticeScene.project(SIMD3(Self.centre(64), 50, 0), camera: LatticeScene.topDown)
        for (name, render) in LatticeScene.renderers {
            // Top-down, both fields' lines coincide: whichever is drawn last is on top where it is
            // not rejected by depth. With the nearer field drawn first and depth written, the
            // farther one would be rejected and the pixel would stay green.
            let pixels = try render([near, far], LatticeSetup())
            let c = HeightfieldIntegrationTests.rgb(
                pixels, Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
            #expect(c.x > c.y + 30, "\(name): the farther lattice is knocked out: \(c)")
        }
    }

    // MARK: Style

    @Test("Width, dash and native lines follow the edge configuration")
    func edgeConfigurationStylesTheLattice() throws {
        let body = LatticeScene.body(try LatticeScene.flatField())
        for (name, render) in LatticeScene.renderers {
            let thin = LatticeScene.drawnCount(try render([body], LatticeSetup()))
            var wide = LatticeSetup()
            wide.edge = EdgeLineConfiguration(width: 4)
            let wideCount = LatticeScene.drawnCount(try render([body], wide))
            #expect(
                Double(wideCount) > Double(thin) * 1.8, "\(name): 4 px \(wideCount) vs 1 px \(thin)"
            )

            // A dash pattern leaves gaps along the lines: fewer pixels than solid, and the same
            // lines (it is not a different lattice).
            var dashed = LatticeSetup()
            dashed.edge = EdgeLineConfiguration(
                width: 1, dashPattern: EdgeLineDashPattern(dashLength: 6, gapLength: 6))
            let dashedPixels = try render([body], dashed)
            let dashedCount = LatticeScene.drawnCount(dashedPixels)
            #expect(dashedCount < thin * 7 / 10, "\(name): dashed \(dashedCount) vs solid \(thin)")
            #expect(dashedCount > thin / 4, "\(name): dashed \(dashedCount) vs solid \(thin)")

            // Native Metal lines are one pixel wide and solid: width and dash have no effect.
            var native = LatticeSetup()
            native.edge = EdgeLineConfiguration(
                width: 4, dashPattern: EdgeLineDashPattern(dashLength: 6, gapLength: 6),
                useQuadExpansion: false)
            let nativeCount = LatticeScene.drawnCount(try render([body], native))
            #expect(
                abs(nativeCount - thin) < thin / 10 + 5,
                "\(name): native \(nativeCount) vs default \(thin)")
        }
    }

    @Test(
        "The lattice is drawn in the body's colour, undimmed by edge intensity, as an edge-only body is"
    )
    func latticeIsTheBodyColour() throws {
        // The field's own colour, red: the lattice is red, not the contrast-adaptive edge colour.
        let red = LatticeScene.body(
            try LatticeScene.flatField(), color: SIMD4(0.9, 0.1, 0.1, 1))
        let camera = LatticeScene.topDown
        let p = LatticeScene.project(SIMD3(Self.centre(64), 50, 0), camera: camera)
        // A body with a material draws in the material's base colour, as an edge-only body's
        // edges do (`effectiveMaterial`), whatever `color` says.
        var blue = red
        blue.material = PBRMaterial(
            baseColor: SIMD3(0.1, 0.3, 0.9), metallic: 0, roughness: 0.5, opacity: 1)
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([red], LatticeSetup())
            let c = HeightfieldIntegrationTests.rgb(
                pixels, Int(p.x.rounded(.down)), Int(p.y.rounded(.down)))
            #expect(c.x > c.y + 40 && c.x > c.z + 40, "\(name): \(c)")
            let m = HeightfieldIntegrationTests.rgb(
                try render([blue], LatticeSetup()), Int(p.x.rounded(.down)), Int(p.y.rounded(.down))
            )
            #expect(m.z > m.x + 40 && m.z > m.y + 40, "\(name): material colour \(m)")

            // Edge intensity dims and hides a meshed body's edges; an edge-only body's, and the
            // lattice, ignore it (no depth fade either).
            var dark = LatticeSetup()
            dark.edgeIntensity = 0
            let off = try render([red], dark)
            #expect(
                off == pixels, "\(name): edgeIntensity 0 changed the lattice")
        }
    }

    @Test("Lines are at multiples of the pitch from the first cell: the far border has none")
    func borderLineOnlyWhereThePitchLandsOnIt() throws {
        // 140 cells at a pitch of 32: lines at 0, 32, 64, 96 and 128, and the last cell, 139, is
        // not a multiple.
        let field = try LatticeScene.field(140) { _, _ in 0 }
        let body = LatticeScene.body(field)
        let camera = LatticeScene.topDown
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([body], LatticeSetup())
            let line = LatticeScene.project(SIMD3(Self.centre(128), 50, 0), camera: camera)
            let border = LatticeScene.project(SIMD3(Self.centre(139), 50, 0), camera: camera)
            #expect(simd_distance(line, border) > 4)
            #expect(LatticeScene.hasInk(pixels, near: line), "\(name): no line at 128")
            #expect(!LatticeScene.hasInk(pixels, near: border), "\(name): a line at the border")
        }
    }

    // MARK: Perspective

    /// A perspective camera, the common one: tiles near the camera have a finer pitch in cells
    /// than tiles far away, and each tile's lines are about the target apart on screen.
    @Test("A perspective camera sets each tile's pitch from its own distance")
    func perspectivePitchFollowsDistance() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let n = 1024
        let field = try LatticeScene.field(n) { _, _ in 0 }
        let body = LatticeScene.body(field)
        let camera = CameraState(
            rotation: simd_quatf(angle: 1.0, axis: SIMD3(1, 0, 0)), distance: 1100,
            pivot: SIMD3(512, 512, 0))
        let size = 256
        var options = HeightfieldScene.options(
            width: size, height: size, camera: camera, displayMode: .wireframe)
        options.msaaSampleCount = 1
        _ = try #require(renderer.render(bodies: [body], options: options))
        let plan = try #require(renderer.heightfieldState(forBodyID: "field")?.lastPlan)
        let buffer = try #require(plan.instanceBuffer)

        let viewProjection = camera.projectionMatrix(aspectRatio: 1) * camera.viewMatrix
        func pixel(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let clip = viewProjection * SIMD4(p, 1)
            guard clip.w > 1e-3 else { return nil }
            return SIMD2(
                (clip.x / clip.w * 0.5 + 0.5) * Float(size),
                (0.5 - clip.y / clip.w * 0.5) * Float(size))
        }

        var latticeLevels = Set<UInt32>()
        var checked = 0
        for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
            let instances = buffer.contents().advanced(
                by: plan.ranges[level].first * MemoryLayout<HeightfieldTileInstance>.stride
            ).bindMemory(to: HeightfieldTileInstance.self, capacity: plan.ranges[level].count)
            for i in 0..<plan.ranges[level].count {
                let tile = instances[i]
                latticeLevels.insert(tile.lattice)
                // Never finer than the tile's mesh cell.
                #expect(Int(tile.lattice) >= level)
                // On screen, a tile's lines are about the target apart: measured along x from the
                // tile's centre, within the tolerance that perspective foreshortening within a
                // tile allows. Only where the pitch was set by the target, not the mesh cell.
                guard Int(tile.lattice) > level else { continue }
                let centre = SIMD3<Float>(
                    Float(tile.origin.x) + 32.5, Float(tile.origin.y) + 32.5, 0)
                let pitch = Float(1 << tile.lattice)
                guard let a = pixel(centre), let b = pixel(centre + SIMD3(pitch, 0, 0)),
                    a.x > 0, a.x < Float(size), a.y > 0, a.y < Float(size)
                else { continue }
                let pitchPixels = simd_distance(a, b)
                #expect(
                    pitchPixels > 10 && pitchPixels < 40,
                    "tile \(tile.origin) level \(level) lattice \(tile.lattice): \(pitchPixels) px")
                checked += 1
            }
        }
        #expect(checked > 20, "only \(checked) tiles were checked")
        // Near tiles are finer than far ones: the pitch is not one value for the field.
        #expect(latticeLevels.count >= 2, "lattice levels \(latticeLevels)")
    }

    // MARK: Body properties

    @Test(
        "The body's transform moves the lattice, and its scale sets the pitch from what is on screen"
    )
    func transformApplies() throws {
        let field = try LatticeScene.flatField()
        var moved = LatticeScene.body(field)
        moved.transform.columns.3 = SIMD4(20, 0, 0, 1)
        let camera = LatticeScene.topDown
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([moved], LatticeSetup())
            // Lines at cell 32 and 64, 20 units further on.
            for g in [32, 64] {
                let p = LatticeScene.project(SIMD3(Self.centre(g) + 20, 50, 0), camera: camera)
                #expect(LatticeScene.hasInk(pixels, near: p), "\(name): not moved: \(g)")
                let old = LatticeScene.project(SIMD3(Self.centre(g), 50, 0), camera: camera)
                if abs(old.x - p.x) > 4 {
                    #expect(!LatticeScene.hasInk(pixels, near: old), "\(name): still at \(g)")
                }
            }
        }

        // Scaled by 2 across the field: a cell is twice as wide on screen, so the pitch halves.
        var scaled = LatticeScene.body(field)
        scaled.transform = simd_float4x4(
            SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-50, -50, 0, 1))
        let perUnit = LatticeScene.pixelsPerUnit(camera) * 2
        let level = HeightfieldLayout.latticeLevel(
            cellPixels: perUnit, latticePixels: 16,
            meshLevel: HeightfieldLayout.level(cellPixels: perUnit, targetPixels: 4))
        #expect(level == 4)  // 16 cells = 17 px, where the unscaled field needs 32
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([scaled], LatticeSetup())
            for g in [16, 32, 48, 64] {
                let world = SIMD3<Float>(2 * Self.centre(g) - 50, 50, 0)
                let p = LatticeScene.project(world, camera: camera)
                #expect(LatticeScene.hasInk(pixels, near: p), "\(name): scaled line \(g)")
            }
        }
    }

    @Test("Section planes clip the lattice, and a tile wholly clipped is not planned")
    func clipPlanesApply() throws {
        let body = LatticeScene.body(try LatticeScene.flatField())
        let plane = ClipPlane(normal: SIMD3(1, 0, 0), distance: -50)
        let planes = [plane]
        for (name, render) in LatticeScene.renderers {
            let full = try render([body], LatticeSetup())
            var setup = LatticeSetup()
            setup.clipPlanes = planes
            let clipped = try render([body], setup)
            // One side is gone, the other is what the unclipped lattice draws there.
            func count(_ pixels: [UInt8], columns: Range<Int>) -> Int {
                var n = 0
                for y in 0..<LatticeScene.size {
                    for x in columns where LatticeScene.isDrawn(pixels, x, y) { n += 1 }
                }
                return n
            }
            let left = (0..<78)
            let right = (84..<160)
            let fullLeft = count(full, columns: left)
            let fullRight = count(full, columns: right)
            let clippedLeft = count(clipped, columns: left)
            let clippedRight = count(clipped, columns: right)
            #expect(fullLeft > 100 && fullRight > 100, "\(name)")
            let keptLeft = clippedLeft == fullLeft && clippedRight == 0
            let keptRight = clippedRight == fullRight && clippedLeft == 0
            #expect(
                keptLeft || keptRight,
                "\(name): left \(clippedLeft)/\(fullLeft), right \(clippedRight)/\(fullRight)")
        }
    }

    @Test("An invisible field and one wholly out of view draw nothing and plan no tiles")
    func invisibleAndCulled() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.flatField()
        var hidden = LatticeScene.body(field)
        hidden.isVisible = false
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([hidden], LatticeSetup())
            #expect(LatticeScene.drawnCount(pixels) == 0, "\(name): a hidden field drew")
        }
        var far = LatticeScene.body(field)
        far.transform.columns.3 = SIMD4(5000, 0, 0, 1)
        let pixels = try LatticeScene.offscreen([far], LatticeSetup())
        #expect(LatticeScene.drawnCount(pixels) == 0)
        _ = renderer.render(bodies: [far], options: LatticeScene.options(LatticeSetup()))
        #expect(renderer.heightfieldState(forBodyID: "field")?.lastPlan?.tileCount == 0)
    }

    @Test("An overlay heightfield still draws its surface in .wireframe, not a lattice")
    func overlayKeepsItsSurface() throws {
        var overlay = LatticeScene.body(try LatticeScene.flatField())
        overlay.renderLayer = .overlay
        for (name, render) in LatticeScene.renderers {
            let pixels = try render([overlay], LatticeSetup())
            #expect(LatticeScene.isDrawn(pixels, 78, 80), "\(name): the overlay surface is missing")
            #expect(LatticeScene.isDrawn(pixels, 62, 62), "\(name)")
        }
    }

    @Test("Offscreen and live draw the same lattice")
    func liveMatchesOffscreen() throws {
        let field = try LatticeScene.field { i, j in 6 * sin(Float(i) * 0.15) * cos(Float(j) * 0.12)
        }
        let body = LatticeScene.body(field)
        var setup = LatticeSetup()
        setup.camera = HeightfieldScene.camera(
            pivot: SIMD3(50, 50, 0), distance: 400, tilt: 0.7, orthographicScale: 200)
        let a = try LatticeScene.offscreen([body], setup)
        let b = try LatticeScene.live([body], setup)
        var differing = 0
        for i in 0..<(LatticeScene.size * LatticeScene.size)
        where
            LatticeScene.isDrawn(a, i % LatticeScene.size, i / LatticeScene.size)
            != LatticeScene.isDrawn(b, i % LatticeScene.size, i / LatticeScene.size)
        { differing += 1 }
        #expect(LatticeScene.drawnCount(a) > 300)
        #expect(differing == 0, "\(differing) pixels differ between offscreen and live")
    }

    // MARK: Settings

    @Test("The lattice pitch target defaults to 16 px, is on both configurations, and is clamped")
    func latticePixelsSetting() throws {
        #expect(Heightfield.defaultLatticePixels == 16)
        #expect(ViewportConfiguration().heightfieldLatticePixels == 16)
        #expect(OffscreenRenderOptions().heightfieldLatticePixels == 16)

        var config = ViewportConfiguration()
        config.heightfieldLatticePixels = 40
        let controller = ViewportController(configuration: config)
        let options = OffscreenRenderOptions(matching: controller, width: 16, height: 16)
        #expect(options.heightfieldLatticePixels == 40)

        // Out-of-range values draw a lattice rather than nothing, or a crash.
        let body = LatticeScene.body(try LatticeScene.flatField())
        for pixels: Float in [-5, 0, 0.01, 1e6, .infinity] {
            var setup = LatticeSetup()
            setup.latticePixels = pixels
            let image = try LatticeScene.offscreen([body], setup)
            #expect(LatticeScene.drawnCount(image) > 0, "latticePixels \(pixels)")
        }
        // NaN is not a size: it draws as the default does.
        var nan = LatticeSetup()
        nan.latticePixels = .nan
        #expect(
            try LatticeScene.offscreen([body], nan)
                == LatticeScene.offscreen([body], LatticeSetup()))
    }

    @Test("Other display modes ignore the lattice setting and draw the surface as before")
    func otherModesAreUnchanged() throws {
        let field = try LatticeScene.field { i, j in 5 * sin(Float(i) * 0.2) * cos(Float(j) * 0.2) }
        let body = LatticeScene.body(field)
        for mode in DisplayMode.allCases where mode != .wireframe {
            var a = LatticeSetup()
            a.mode = mode
            a.latticePixels = 1
            var b = a
            b.latticePixels = 256
            for (name, render) in LatticeScene.renderers {
                let one = try render([body], a)
                let two = try render([body], b)
                #expect(one == two, "\(name): \(mode) changed with the lattice setting")
                // The surface is drawn: the middle of the field is not background, and so is a
                // pixel between where lattice lines would be.
                #expect(LatticeScene.isDrawn(one, 78, 80), "\(name): \(mode) draws no surface")
                #expect(LatticeScene.isDrawn(one, 62, 62), "\(name): \(mode) draws no surface")
            }
        }
        // ... and wireframe does depend on it.
        var coarse = LatticeSetup()
        coarse.latticePixels = 64
        var fine = LatticeSetup()
        fine.latticePixels = 8
        let c = try LatticeScene.offscreen([body], coarse)
        let f = try LatticeScene.offscreen([body], fine)
        #expect(LatticeScene.drawnCount(f) > LatticeScene.drawnCount(c))
    }

    // MARK: Picking

    /// The cell a `.wireframe` lattice pick reports at `pixel`.
    ///
    /// The field is 100 cells in a 160 px view, 300 units across, so pixel `(x, y)` is over the
    /// cell `(x - 80) * 1.875 + 50`, rows reversed; the lines are at cells 0, 32, 64 and 96.
    static func cell(atPixel pixel: SIMD2<Int>) -> SIMD2<Int> {
        let scale: Float = 300 / 160
        return SIMD2(
            Int((50 + (Float(pixel.x) + 0.5 - 80) * scale).rounded(.down)),
            Int((50 - (Float(pixel.y) + 0.5 - 80) * scale).rounded(.down)))
    }

    @Test("In .wireframe the lattice lines are picked, as a mesh is picked at its edges")
    func latticeLinesArePicked() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let body = LatticeScene.body(field)
        let options = LatticeScene.options(LatticeSetup())
        var picked = options
        picked.pickRadius = 0

        // A pixel on the line at cell 64 (px 87), away from the horizontal ones: the cell there.
        let onLine = SIMD2(87, 80)
        let hit = try #require(
            renderer.performPick(bodies: [body], at: onLine, options: picked), "no hit on a line")
        #expect(hit.bodyID == "field")
        #expect(hit.kind == .face)
        let cell = try #require(hit.heightfield)
        let expected = Self.cell(atPixel: onLine)
        #expect(
            abs(cell.cell.x - expected.x) <= 1 && cell.cell.y == expected.y,
            "\(cell.cell) vs \(expected)")
        #expect(hit.triangleIndex == cell.cellIndex)
        let truth = try #require(field.sample(x: cell.cell.x, y: cell.cell.y))
        #expect(cell.height == truth.height)

        // Between the lines the surface is not picked, as a mesh's faces are not in .wireframe.
        for pixel in [SIMD2(78, 80), SIMD2(62, 62), SIMD2(95, 95)] {
            #expect(
                renderer.performPick(bodies: [body], at: pixel, options: picked) == nil,
                "\(pixel) picked off the lattice")
        }

        // A pick radius reaches the line from a few pixels away, as for an edge: (82, 80) is five
        // pixels from the line at px 87.
        var near = options
        near.pickRadius = 6
        let reached = try #require(
            renderer.performPick(bodies: [body], at: SIMD2(82, 80), options: near))
        #expect(reached.heightfield != nil)

        // In .shaded the same pixels pick the surface.
        var shaded = picked
        shaded.displayMode = .shaded
        #expect(
            renderer.performPick(bodies: [body], at: SIMD2(78, 80), options: shaded)?.heightfield
                != nil)
    }

    @Test("A live pick of the lattice agrees with the offscreen one, and refinePick makes it exact")
    func livePickAndRefinement() async throws {
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: LatticeScene.topDown, width: LatticeScene.size,
            height: LatticeScene.size, sampleCount: 1)
        rig.controller.displayMode = .wireframe
        _ = try #require(
            rig.renderer.renderHeadlessBGRA(
                width: LatticeScene.size, height: LatticeScene.size,
                backgroundColor: HeightfieldScene.background))

        let onLine = SIMD2(87, 80)
        let live = try #require(await rig.pick(onLine))
        #expect(live.heightfield != nil)
        #expect(await rig.pick(SIMD2(78, 80)) == nil)

        guard let renderer = OffscreenRenderer() else { return }
        var options = LatticeScene.options(LatticeSetup())
        options.pickRadius = 0
        let offscreen = try #require(
            renderer.performPick(bodies: bodies, at: onLine, options: options))
        #expect(live.heightfield == offscreen.heightfield)
        #expect(live.triangleIndex == offscreen.triangleIndex)

        // refinePick re-casts the tap's ray over the full-resolution heights and returns the
        // cell the ray enters, whatever the display mode.
        let ndc = SIMD2(
            (Float(onLine.x) + 0.5) / 160 * 2 - 1, 1 - (Float(onLine.y) + 0.5) / 160 * 2)
        let ray = Ray.fromCamera(ndc: ndc, cameraState: LatticeScene.topDown, aspectRatio: 1)
        let truth = try #require(field.raycast(origin: ray.origin, direction: ray.direction)).cell
        let refined = try #require(rig.controller.refinePick(live, ndc: ndc, bodies: bodies))
        #expect(refined.heightfield?.cell == truth)
        #expect(refined.triangleIndex == truth.y * 100 + truth.x)
        #expect(refined.kind == .face)
    }

    @Test("A body that is not pickable, or an overlay one, behaves as in the shaded modes")
    func unpickableAndOverlay() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var options = LatticeScene.options(LatticeSetup())
        options.pickRadius = 0
        var unpickable = LatticeScene.body(try LatticeScene.flatField())
        unpickable.isPickable = false
        #expect(
            renderer.performPick(bodies: [unpickable], at: SIMD2(87, 80), options: options) == nil)
        // An overlay field stamps its surface in every mode, between the lines too.
        var overlay = LatticeScene.body(try LatticeScene.flatField())
        overlay.renderLayer = .overlay
        #expect(
            renderer.performPick(bodies: [overlay], at: SIMD2(78, 80), options: options)?
                .heightfield
                != nil)
    }
}
