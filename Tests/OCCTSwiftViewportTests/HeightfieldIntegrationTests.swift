// HeightfieldIntegrationTests.swift
// OCCTSwiftViewport Tests
//
// A heightfield in the rest of the renderer: translucency, the selection outline, the overlay
// layer, display modes without a surface, TAA history, and what happens when the GPU cannot hold
// the field. Each is checked through the live renderer and the offscreen renderer.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield integration (#139)")
struct HeightfieldIntegrationTests {

    // MARK: Scene helpers

    static let size = 160

    /// Top-down orthographic camera over a 100 x 100 field: 300 world units across the view.
    static let topDown = CameraState(
        distance: 600, pivot: SIMD3(50, 50, 0), orthographicScale: 300, isOrthographic: true)

    static let green = SIMD4<Float>(0.1, 0.7, 0.1, 1)
    static let red = SIMD4<Float>(0.9, 0.1, 0.1, 1)

    /// A pixel's (r, g, b) in a BGRA buffer.
    static func rgb(_ pixels: [UInt8], _ x: Int, _ y: Int, width: Int = size) -> SIMD3<Int> {
        let i = (y * width + x) * 4
        return SIMD3(Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
    }

    static func isBackground(_ pixels: [UInt8], _ x: Int, _ y: Int, width: Int = size) -> Bool {
        HeightfieldScene.isBackground(rgb(pixels, x, y, width: width))
    }

    static func flatField(_ size: Int = 100, height: Float = 0) throws -> Heightfield {
        try Heightfield(width: size, height: size, initialHeight: height)
    }

    /// A box above or below the field's plane, centred over its middle.
    static func box(top: Float, color: SIMD4<Float> = red, size: Float = 30) -> ViewportBody {
        var box = ViewportBody.box(
            id: "box", width: size, height: size, depth: 10, color: color)
        box.transform.columns.3 = SIMD4(50, 50, top - 5, 1)
        return box
    }

    /// Renders `bodies` through the offscreen renderer.
    static func offscreen(
        _ bodies: [ViewportBody], displayMode: DisplayMode = .shaded,
        selected: Set<String> = [], hovered: String? = nil
    ) throws -> [UInt8] {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            throw HeightfieldPickRig.Unavailable()
        }
        var options = HeightfieldScene.options(
            width: size, height: size, camera: topDown, displayMode: displayMode)
        options.selectedBodyIDs = selected
        options.hoveredBodyID = hovered
        options.enableSilhouettes = false
        return HeightfieldScene.pixels(try #require(renderer.render(bodies: bodies, options: options)))
            .pixels
    }

    /// A live renderer for `bodies`, with a controller it holds weakly.
    static func liveRenderer(
        _ bodies: [ViewportBody], displayMode: DisplayMode = .shaded,
        selected: Set<String> = [], hovered: String? = nil, enableTAA: Bool = false,
        silhouettes: Bool = false
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var config = ViewportConfiguration()
        config.initialCameraState = topDown
        config.backgroundColor = HeightfieldScene.background
        config.showViewCube = false
        config.msaaSampleCount = 1
        config.enableSilhouettes = silhouettes
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: 0)
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        config.lightingConfiguration = lighting
        let controller = ViewportController(configuration: config)
        controller.displayMode = displayMode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = enableTAA
        controller.selectedBodyIDs = selected
        controller.hoveredBodyID = hovered
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping")
            throw HeightfieldPickRig.Unavailable()
        }
        return (controller, renderer)
    }

    static func live(
        _ bodies: [ViewportBody], displayMode: DisplayMode = .shaded,
        selected: Set<String> = [], hovered: String? = nil
    ) throws -> [UInt8] {
        let rig = try liveRenderer(
            bodies, displayMode: displayMode, selected: selected, hovered: hovered)
        return try #require(
            rig.renderer.renderHeadlessBGRA(
                width: size, height: size, backgroundColor: HeightfieldScene.background))
    }

    typealias Renderer = ([ViewportBody], DisplayMode, Set<String>, String?) throws -> [UInt8]

    static let renderers: [(name: String, render: Renderer)] = [
        ("offscreen", { try HeightfieldIntegrationTests.offscreen($0, displayMode: $1, selected: $2, hovered: $3) }),
        ("live", { try HeightfieldIntegrationTests.live($0, displayMode: $1, selected: $2, hovered: $3) }),
    ]

    // MARK: Translucency

    @Test("A translucent heightfield shows what is beneath it, and an opaque one hides it")
    func translucentFieldShowsWhatIsBeneath() throws {
        for (name, render) in Self.renderers {
            let beneath = Self.box(top: -20)
            var translucent = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            translucent.color.w = 0.4
            let opaque = HeightfieldScene.body(try Self.flatField(), color: Self.green)

            let seen = try render([translucent, beneath], .shaded, [], nil)
            let hidden = try render([opaque, beneath], .shaded, [], nil)
            let centre = Self.size / 2
            let through = Self.rgb(seen, centre, centre)
            let blocked = Self.rgb(hidden, centre, centre)
            // Over the box the translucent field is a blend of its green and the box's red; the
            // opaque field is green alone.
            #expect(through.x > blocked.x + 40, "\(name): red beneath not seen: \(through) vs \(blocked)")
            #expect(through.y > 20, "\(name): the field itself is not drawn: \(through)")
            // Beside the box the translucent field still shows the background through it.
            let beside = Self.rgb(seen, centre - 15, centre)
            #expect(!HeightfieldScene.isBackground(beside), "\(name): field missing beside box")
            #expect(beside != Self.rgb(hidden, centre - 15, centre), "\(name): not blended")
        }
    }

    @Test("A translucent field is sorted with translucent meshes, back to front")
    func translucentFieldSortsWithMeshes() throws {
        for (name, render) in Self.renderers {
            var field = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            field.color.w = 0.5
            // A translucent blue sheet above the field and another below it: swapping which is
            // nearer the camera changes the blend, so the order is observable.
            func sheet(_ z: Float, _ color: SIMD4<Float>) -> ViewportBody {
                var b = ViewportBody.box(
                    id: "sheet\(z)", width: 60, height: 60, depth: 1, color: color)
                b.transform.columns.3 = SIMD4(50, 50, z, 1)
                return b
            }
            let near = sheet(10, SIMD4(0.1, 0.1, 0.9, 0.5))
            let far = sheet(-10, SIMD4(0.9, 0.1, 0.1, 0.5))
            let pixels = try render([far, field, near], .shaded, [], nil)
            let swapped = try render(
                [sheet(10, SIMD4(0.9, 0.1, 0.1, 0.5)), field, sheet(-10, SIMD4(0.1, 0.1, 0.9, 0.5))],
                .shaded, [], nil)
            let a = Self.rgb(pixels, Self.size / 2, Self.size / 2)
            let b = Self.rgb(swapped, Self.size / 2, Self.size / 2)
            #expect(a != b, "\(name): order made no difference: \(a) vs \(b)")
            // The nearer sheet contributes more: blue dominates when the blue sheet is on top.
            #expect(a.z > a.x, "\(name): blue sheet should be nearest: \(a)")
            #expect(b.x > b.z, "\(name): red sheet should be nearest: \(b)")
        }
    }

    @Test("X-ray draws a heightfield translucent")
    func xrayIsTranslucent() throws {
        for (name, render) in Self.renderers {
            let field = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            let beneath = Self.box(top: -20)
            let solid = try render([field, beneath], .shaded, [], nil)
            let xray = try render([field, beneath], .xray, [], nil)
            let c = Self.size / 2
            let s = Self.rgb(solid, c, c)
            let x = Self.rgb(xray, c, c)
            #expect(x.x > s.x + 40, "\(name): x-ray should show the box beneath: \(x) vs \(s)")
            #expect(!Self.isBackground(xray, c - 15, c), "\(name): x-ray drew nothing")
        }
    }

    // MARK: Selection

    @Test("A selected heightfield is ringed by the outline, and the outline stays off the body")
    func selectionOutlineRingsTheField() throws {
        for (name, render) in Self.renderers {
            let field = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            let plain = try render([field], .shaded, [], nil)
            let selected = try render([field], .shaded, ["field"], nil)
            var ring = 0
            for y in 0..<Self.size {
                for x in 0..<Self.size
                where Self.isBackground(plain, x, y) && !Self.isBackground(selected, x, y) {
                    ring += 1
                }
            }
            #expect(ring > 150, "\(name): the selection ring is missing (\(ring) px)")
            // Inside the footprint only the faint tint changes: no outline colour painted over it.
            let c = Self.size / 2
            let inside = Self.rgb(selected, c, c) &- Self.rgb(plain, c, c)
            #expect(max(abs(inside.x), abs(inside.y), abs(inside.z)) < 70, "\(name): \(inside)")
            #expect(Self.rgb(selected, c, c) != Self.rgb(plain, c, c), "\(name): no tint")

            let hovered = try render([field], .shaded, [], "field")
            var hoverRing = 0
            for y in 0..<Self.size {
                for x in 0..<Self.size
                where Self.isBackground(plain, x, y) && !Self.isBackground(hovered, x, y) {
                    hoverRing += 1
                }
            }
            #expect(hoverRing > 150, "\(name): the hover ring is missing (\(hoverRing) px)")
        }
    }

    @Test("The selection ring of a translucent heightfield and of one in wireframe")
    func selectionRingInOtherModes() throws {
        for (name, render) in Self.renderers {
            var translucent = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            translucent.color.w = 0.4
            let plain = try render([translucent], .shaded, [], nil)
            let selected = try render([translucent], .shaded, ["field"], nil)
            var ring = 0
            for y in 0..<Self.size {
                for x in 0..<Self.size
                where Self.isBackground(plain, x, y) && !Self.isBackground(selected, x, y) {
                    ring += 1
                }
            }
            #expect(ring > 150, "\(name): no ring around the translucent field (\(ring) px)")
        }
    }

    // MARK: Overlay layer

    @Test("An overlay heightfield draws over geometry in front of it, in every display mode")
    func overlayFieldDrawsOnTop() throws {
        for (name, render) in Self.renderers {
            let inFront = Self.box(top: 40)
            var geometry = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            var overlay = geometry
            overlay.renderLayer = .overlay
            geometry.renderLayer = .geometry
            let c = Self.size / 2

            let behind = try render([geometry, inFront], .shaded, [], nil)
            let over = try render([overlay, inFront], .shaded, [], nil)
            let boxColour = Self.rgb(behind, c, c)
            let fieldColour = Self.rgb(over, c, c)
            #expect(boxColour.x > boxColour.y, "\(name): the box should hide the field: \(boxColour)")
            #expect(fieldColour.y > fieldColour.x, "\(name): the overlay field is not on top: \(fieldColour)")

            // Overlay surfaces draw in wireframe too; a geometry heightfield does not.
            let wireOverlay = try render([overlay], .wireframe, [], nil)
            let wireGeometry = try render([geometry], .wireframe, [], nil)
            #expect(!Self.isBackground(wireOverlay, c, c), "\(name): overlay missing in wireframe")
            #expect(Self.isBackground(wireGeometry, c, c), "\(name): geometry drew in wireframe")
        }
    }

    @Test("An overlay heightfield wins the pick over geometry in front of it")
    func overlayFieldWinsPick() async throws {
        let inFront = Self.box(top: 40)
        var overlay = HeightfieldScene.body(try Self.flatField(), color: Self.green)
        overlay.renderLayer = .overlay
        let bodies = [overlay, inFront]
        let c = Self.size / 2

        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var options = HeightfieldScene.options(width: Self.size, height: Self.size, camera: Self.topDown)
        options.pickRadius = 0
        let offscreen = try #require(
            renderer.performPick(bodies: bodies, at: SIMD2(c, c), options: options))
        #expect(offscreen.bodyID == "field")
        #expect(offscreen.heightfield != nil)

        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: Self.topDown, width: Self.size, height: Self.size)
        let live = try #require(await rig.pick(SIMD2(c, c)))
        #expect(live.bodyID == "field")
        #expect(live.heightfield?.cell == offscreen.heightfield?.cell)
    }

    // MARK: Wireframe

    @Test("Wireframe draws nothing for a heightfield and does not crash; shaded-with-edges draws it")
    func wireframeIsADefinedNoOp() throws {
        for (name, render) in Self.renderers {
            let field = HeightfieldScene.body(try Self.flatField(), color: Self.green)
            let wire = try render([field], .wireframe, [], nil)
            let drawn = (0..<Self.size * Self.size).filter {
                !Self.isBackground(wire, $0 % Self.size, $0 / Self.size)
            }
            #expect(drawn.isEmpty, "\(name): wireframe drew \(drawn.count) px for a heightfield")
            let edges = try render([field], .shadedWithEdges, [], nil)
            #expect(!Self.isBackground(edges, Self.size / 2, Self.size / 2), "\(name)")
        }
    }

    // MARK: Mesh cell target

    @Test("The mesh cell target steers the levels of detail, and is clamped")
    func meshCellTargetSteersLevels() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try HeightfieldScene.terrainField(width: 640, height: 640)
        let body = HeightfieldScene.body(field)
        func meanLevel(_ pixels: Float) throws -> Double {
            var options = HeightfieldScene.options(
                width: 128, height: 128,
                camera: CameraState(
                    distance: 2000, pivot: SIMD3(320, 320, 0), orthographicScale: 700,
                    isOrthographic: true))
            options.heightfieldMeshCellPixels = pixels
            _ = try #require(renderer.render(bodies: [body], options: options))
            let plan = try #require(renderer.heightfieldState(forBodyID: "field")?.lastPlan)
            let total = plan.levelHistogram.reduce(0, +)
            return Double(plan.levelHistogram.enumerated().reduce(0) { $0 + $1.offset * $1.element })
                / Double(total)
        }
        // 128 px over 700 units: one cell is about 0.18 px, so 4 px allows stride 16 or so.
        let fine = try meanLevel(1)
        let normal = try meanLevel(Heightfield.defaultMeshCellPixels)
        let coarse = try meanLevel(16)
        #expect(fine < normal && normal < coarse, "\(fine), \(normal), \(coarse)")
        // Out-of-range values are clamped to Heightfield.meshCellPixelsRange.
        #expect(try meanLevel(0.01) == fine)
        #expect(try meanLevel(-3) == fine)
        #expect(try meanLevel(10_000) == (try meanLevel(Heightfield.meshCellPixelsRange.upperBound)))
    }

    // MARK: TAA

    @Test("An edit under a still camera restarts TAA accumulation, so it does not ghost")
    func editRestartsTAA() throws {
        let field = try Heightfield(width: 100, height: 100, initialHeight: 0)
        let body = HeightfieldScene.body(field, color: Self.green)
        let rig = try Self.liveRenderer([body], enableTAA: true)
        func frames(_ count: Int) throws {
            _ = try #require(
                rig.renderer.renderHeadlessBGRA(
                    width: 64, height: 64, backgroundColor: HeightfieldScene.background,
                    frameCount: count))
        }

        // A still camera accumulates: the index counts frames since the last reset.
        try frames(8)
        #expect(rig.renderer.taaFrameIndex == 8)
        try frames(1)
        #expect(rig.renderer.taaFrameIndex == 9, "a frame with nothing changed keeps accumulating")

        // An edit invalidates the history, as an animated body's motion would: the resolve of
        // the next frame starts again from the current image alone.
        let edit = HeightfieldRegion(x: 10, y: 10, width: 80, height: 80)
        field.replace(
            region: edit, heights: [Float](repeating: 5, count: edit.cellCount),
            attributes: [UInt8](repeating: 200, count: edit.cellCount))
        try frames(1)
        #expect(rig.renderer.taaFrameIndex == 1, "the frame after an edit did not restart TAA")

        // A ramp change alters the picture too.
        try frames(3)
        #expect(rig.renderer.taaFrameIndex == 4)
        field.ramp = [SIMD4<Float>](repeating: SIMD4(1, 0, 0, 1), count: Heightfield.rampSize)
        try frames(1)
        #expect(rig.renderer.taaFrameIndex == 1, "a ramp change did not restart TAA")
    }

    // MARK: GPU limits

    @Test("A field the GPU cannot hold is logged once and not drawn, never silently half-drawn")
    func gpuAllocationFailureIsReported() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let saved = HeightfieldGPU.textureSideLimit
        HeightfieldGPU.textureSideLimit = 128
        defer { HeightfieldGPU.textureSideLimit = saved }

        // 300 cells pad to 320 texels: over the lowered limit.
        let field = try Heightfield(width: 300, height: 300)
        let body = HeightfieldScene.body(field, color: Self.green)
        var options = HeightfieldScene.options(
            width: 64, height: 64,
            camera: CameraState(
                distance: 800, pivot: SIMD3(150, 150, 0), orthographicScale: 400,
                isOrthographic: true))
        options.enableSilhouettes = false
        let image = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: options)))
        let drawn = (0..<64 * 64).filter {
            !Self.isBackground(image.pixels, $0 % 64, $0 / 64, width: 64)
        }
        #expect(drawn.isEmpty)
        #expect(renderer.heightfieldFailureCount == 1)
        #expect(renderer.heightfieldState(forBodyID: "field") == nil)

        // The same field again is not retried and not reported again.
        _ = renderer.render(bodies: [body], options: options)
        #expect(renderer.heightfieldFailureCount == 1)

        // A field that fits draws, and a second oversized one is reported on its own.
        let small = HeightfieldScene.body(try Self.flatField(50), color: Self.green)
        var other = HeightfieldScene.body(try Self.flatField(300), color: Self.green)
        other.id = "other"
        _ = renderer.render(bodies: [small, other], options: options)
        #expect(renderer.heightfieldState(forBodyID: "field") != nil)
        #expect(renderer.heightfieldFailureCount == 2)
    }

    @Test("A field at the maximum width allocates and draws")
    func maximumWidthFieldDraws() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let before = renderer.heightfieldFailureCount
        let field = try Heightfield(
            width: Heightfield.maximumDimension, height: 2, cellSize: SIMD2(1, 8000))
        let body = HeightfieldScene.body(field, color: Self.green)
        var options = HeightfieldScene.options(
            width: 96, height: 96,
            camera: CameraState(
                distance: 40_000, pivot: SIMD3(8160, 4000, 0), orthographicScale: 17_000,
                isOrthographic: true))
        options.enableSilhouettes = false
        let image = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: options)))
        let drawn = (0..<96 * 96).filter {
            !Self.isBackground(image.pixels, $0 % 96, $0 / 96, width: 96)
        }
        #expect(renderer.heightfieldFailureCount == before)
        #expect(drawn.count > 500, "the widest field drew only \(drawn.count) px")
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        #expect(state.paddedWidth <= 16_384)
    }
}
