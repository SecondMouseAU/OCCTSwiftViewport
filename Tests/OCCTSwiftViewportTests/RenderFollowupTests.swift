// RenderFollowupTests.swift
// OCCTSwiftViewport Tests
//
// Regression tests for #209 items 1, 2 and 4: shadow-pass culling and mirrored transforms, the
// selection outline around face-on flat-normal meshes, and the offscreen overlay in-view test
// under `pixelPan` / `explicitOrthoBounds`. Pixel scenes render
// through both the live renderer (headless) and `OffscreenRenderer`, light appearance, grid and
// axes off.

import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Shadow pass culling (#209 item 1)

@Suite("Shadow pass casts from either side and under mirroring (#209)")
@MainActor
struct ShadowCullTests {

    /// Shadows on at full strength, SSAO off, the key light shining down and towards +X at 45°.
    private var shadowLighting: LightingConfiguration {
        var lighting = ParityRender.plainLighting
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 1
        lighting.keyLight.direction = simd_normalize(SIMD3<Float>(1, 0, -1))
        return lighting
    }

    private let ground = ParityRender.quad(
        id: "ground", x0: -5, y0: -5, x1: 5, y1: 5, z: 0, color: SIMD4(0.8, 0.8, 0.8, 1))

    /// A 2 x 2 sheet at z = 2 over the origin, one-sided: its triangles wind counter-clockwise
    /// seen from +Z (`facingLight`) or from -Z.
    private func sheet(facingLight: Bool, mirrored: Bool) -> ViewportBody {
        let normalZ: Float = facingLight ? 1 : -1
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 2, 0, 0, normalZ] }
        var body = ViewportBody(
            id: "sheet", vertexData: v(-1, -1) + v(1, -1) + v(1, 1) + v(-1, 1),
            indices: facingLight ? [0, 1, 2, 0, 2, 3] : [0, 2, 1, 0, 3, 2], edges: [],
            color: SIMD4(0.2, 0.2, 0.9, 1))
        // Mirroring in X maps the symmetric sheet onto itself but reverses its winding on screen.
        if mirrored { body.transform = simd_float4x4(diagonal: SIMD4(-1, 1, 1, 1)) }
        return body
    }

    /// Brightness of the ground where the sheet's shadow falls (x ≈ 2) against open ground on
    /// the far side (x ≈ -3); rows are the middle of the 128 px image.
    private func shadowContrast(_ pixels: [UInt8]) -> (shadowed: Int, open: Int) {
        func luma(_ x: Int) -> Int {
            let c = PassScene.rgb(pixels, x: x, y: 64)
            return c.x + c.y + c.z
        }
        return (luma(90), luma(26))
    }

    @Test("Control: with no sheet the two sample points are lit alike")
    func groundAloneIsUniform() throws {
        guard let pixels = PassScene.offscreen([ground], lighting: shadowLighting)?.pixels else {
            Issue.record("Metal device unavailable")
            return
        }
        let (shadowed, open) = shadowContrast(pixels)
        #expect(abs(shadowed - open) < 20, "\(shadowed) vs \(open)")
    }

    @Test(
        "A one-sided sheet casts its shadow facing the light, facing away, and mirrored",
        arguments: [(true, false), (false, false), (true, true), (false, true)])
    func sheetCastsShadow(facingLight: Bool, mirrored: Bool) throws {
        let bodies = [ground, sheet(facingLight: facingLight, mirrored: mirrored)]
        guard
            let live = PassScene.live(bodies, lighting: shadowLighting),
            let offscreen = PassScene.offscreen(bodies, lighting: shadowLighting)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        for (name, pixels) in [("live", live.pixels), ("offscreen", offscreen.pixels)] {
            let (shadowed, open) = shadowContrast(pixels)
            #expect(
                shadowed + 60 < open,
                """
                \(name), facingLight \(facingLight), mirrored \(mirrored): no shadow under the \
                sheet (\(shadowed) vs open ground \(open))
                """)
        }
    }
}

// MARK: - Face-on outline (#209 item 2)

@Suite("Selection outline rings face-on flat-normal meshes (#209)")
@MainActor
struct FaceOnOutlineTests {

    private let outline = SelectionOutlineStyle(color: SIMD3(1, 1, 0), width: 3)
    private let yellow: (SIMD3<Int>) -> Bool = { $0.x > 150 && $0.y > 150 && $0.z < 100 }

    /// Yellow pixels in the strips just outside each side of a box spanning `-half...half` in
    /// x and y, seen face-on by the front camera (12.8 px per unit, centred at 64).
    private func ringSides(_ pixels: [UInt8], half: Float) -> [Int] {
        let edge = Int((half * 12.8).rounded())
        let lo = 64 - edge
        let hi = 64 + edge
        func count(xs: Range<Int>, ys: Range<Int>) -> Int {
            var n = 0
            for y in ys {
                for x in xs where yellow(PassScene.rgb(pixels, x: x, y: y)) { n += 1 }
            }
            return n
        }
        let mid = (lo + 4)..<(hi - 4)
        return [
            count(xs: (lo - 4)..<lo, ys: mid),  // left
            count(xs: hi..<(hi + 4), ys: mid),  // right
            count(xs: mid, ys: (lo - 4)..<lo),  // top
            count(xs: mid, ys: hi..<(hi + 4)),  // bottom
        ]
    }

    @Test("A box seen face-on gets a ring on all four sides, in both renderers")
    func faceOnBoxIsRinged() throws {
        let box = ViewportBody.box(
            id: "box", width: 4, height: 4, depth: 4, color: SIMD4(0.6, 0.6, 0.6, 1))
        guard
            let live = PassScene.live([box], selected: ["box"], outline: outline),
            let offscreen = PassScene.offscreen([box], selected: ["box"], outline: outline)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        for (name, pixels) in [("live", live.pixels), ("offscreen", offscreen.pixels)] {
            let sides = ringSides(pixels, half: 2)
            // Each strip is 4 px deep along a ~43 px side: a 3 px ring fills about 3/4 of it.
            #expect(sides.allSatisfy { $0 > 80 }, "\(name): ring per side \(sides)")
            // The ring stays off the box itself.
            let centre = PassScene.rgb(pixels, x: 64, y: 64)
            #expect(!yellow(centre), "\(name): outline over the box face \(centre)")
        }
    }

    @Test("A direct-mesh box seen face-on is ringed too")
    func faceOnDirectMeshBoxIsRinged() throws {
        let source = ViewportBody.box(
            id: "box", width: 4, height: 4, depth: 4, color: SIMD4(0.6, 0.6, 0.6, 1))
        var positions: [Float] = []
        var normals: [Float] = []
        for v in stride(from: 0, to: source.vertexData.count, by: 6) {
            positions += source.vertexData[v..<(v + 3)]
            normals += source.vertexData[(v + 3)..<(v + 6)]
        }
        let box = ViewportBody.directMesh(
            id: "box", positions: positions, normals: normals, indices: source.indices,
            color: SIMD4(0.6, 0.6, 0.6, 1))
        guard
            let live = PassScene.live([box], selected: ["box"], outline: outline),
            let offscreen = PassScene.offscreen([box], selected: ["box"], outline: outline)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        for (name, pixels) in [("live", live.pixels), ("offscreen", offscreen.pixels)] {
            let sides = ringSides(pixels, half: 2)
            #expect(sides.allSatisfy { $0 > 80 }, "\(name): ring per side \(sides)")
        }
    }

    @Test("The ring is about the configured width")
    func ringWidthFollowsStyle() throws {
        let box = ViewportBody.box(
            id: "box", width: 4, height: 4, depth: 4, color: SIMD4(0.6, 0.6, 0.6, 1))
        for width: Float in [1, 6] {
            let style = SelectionOutlineStyle(color: SIMD3(1, 1, 0), width: width)
            guard let pixels = PassScene.offscreen([box], selected: ["box"], outline: style)?.pixels
            else {
                Issue.record("Metal device unavailable")
                return
            }
            // Yellow run along the middle row, right of the box.
            var run = 0
            for x in 90..<PassScene.size where yellow(PassScene.rgb(pixels, x: x, y: 64)) {
                run += 1
            }
            #expect(abs(Float(run) - width) <= 1.5, "width \(width): \(run) px ring")
        }
    }

    @Test("The outline scissor covers the projected bounds plus the width")
    func outlineScissor() {
        let viewProjection =
            ParityRender.frontCamera.projectionMatrix(aspectRatio: 1, near: 1, far: 100)
            * ParityRender.frontCamera.viewMatrix
        let box = BoundingBox(min: SIMD3(-2, -2, -2), max: SIMD3(2, 2, 2))
        let size = SIMD2(128, 128)
        guard
            let rect = RendererSharedSetup.selectionOutlineScissor(
                bounds: [box], viewProjection: viewProjection, size: size, margin: 3)
        else {
            Issue.record("no scissor for an on-screen box")
            return
        }
        // ±2 units at 12.8 px per unit around 64, grown by 3 px + 2 px slack.
        #expect(rect.x <= 64 - 26 - 3 && rect.x >= 64 - 26 - 6)
        #expect(rect.x + rect.width >= 64 + 26 + 3 && rect.x + rect.width <= 64 + 26 + 6)
        // Unknown bounds: the whole target.
        let full = RendererSharedSetup.selectionOutlineScissor(
            bounds: [nil], viewProjection: viewProjection, size: size, margin: 3)
        #expect(full?.width == 128 && full?.height == 128)
        // Far off to the side: nothing to draw.
        let away = BoundingBox(min: SIMD3(100, 0, 0), max: SIMD3(101, 1, 1))
        #expect(
            RendererSharedSetup.selectionOutlineScissor(
                bounds: [away], viewProjection: viewProjection, size: size, margin: 3) == nil)
    }
}

// MARK: - Offscreen overlay frustum (#209 item 4)

@Suite("Offscreen overlay in-view test follows pixelPan and explicitOrthoBounds (#209)")
@MainActor
struct OffscreenOverlayFrustumTests {

    private let model = ParityRender.quad(
        id: "model", x0: -1, y0: -1, x1: 1, y1: 1, z: 0, color: SIMD4(0.5, 0.5, 0.5, 1))

    /// A red overlay quad in front of the model (z = 6, the camera is at z = 10), centred at
    /// `x`: nearer the camera than the near plane fitted to the model alone.
    private func overlay(atX x: Float) -> ViewportBody {
        var body = ParityRender.quad(
            id: "overlay", x0: x - 0.5, y0: -0.5, x1: x + 0.5, y1: 0.5, z: 6,
            color: SIMD4(1, 0, 0, 1))
        body.renderLayer = .overlay
        return body
    }

    private func redCount(_ options: OffscreenRenderOptions, overlayX: Float) -> Int? {
        guard let renderer = OffscreenRenderer(),
            let image = renderer.render(bodies: [model, overlay(atX: overlayX)], options: options)
        else { return nil }
        return PassScene.count(ParityRender.bgra(image).0, where: PassScene.isRed)
    }

    @Test("An overlay that pixelPan brings into view is drawn")
    func pixelPanOverlay() throws {
        // x = 6 is off the right edge (±5 visible); a 40 px pan left brings it to x ≈ 101 px.
        var options = ParityRender.options(displayMode: .shaded)
        options.pixelPan = SIMD2(-40, 0)
        let red = try #require(redCount(options, overlayX: 6), "Metal device unavailable")
        #expect(red > 50, "overlay brought into view by pixelPan was clipped (\(red) px)")
    }

    @Test("An overlay inside explicitOrthoBounds but outside the camera's view is drawn")
    func explicitOrthoBoundsOverlay() throws {
        var options = ParityRender.options(displayMode: .shaded)
        options.explicitOrthoBounds = OrthoBounds(left: 3, right: 13, bottom: -5, top: 5)
        let red = try #require(redCount(options, overlayX: 8), "Metal device unavailable")
        #expect(red > 50, "overlay inside explicitOrthoBounds was clipped (\(red) px)")
    }

    @Test("The offscreen projection applies explicitOrthoBounds, then pixelPan")
    func projectionMatchesRender() {
        var options = ParityRender.options(displayMode: .shaded)
        options.explicitOrthoBounds = OrthoBounds(left: 3, right: 13, bottom: -5, top: 5)
        options.pixelPan = SIMD2(32, 0)
        let projection = OffscreenRenderer.projectionMatrix(options: options, near: 1, far: 20)
        // World x = 8 (the bounds' centre) maps to NDC 0, then the 32 px pan of 128 px adds 0.5.
        let clip = projection * options.cameraState.viewMatrix * SIMD4<Float>(8, 0, 0, 1)
        #expect(abs(clip.x / clip.w - 0.5) < 1e-4)
        // The view spans world x 3...13 shifted by a quarter width: x ≈ 0.5...10.5.
        func point(_ x: Float) -> BoundingBox {
            BoundingBox(min: SIMD3(x - 0.01, -0.01, -0.01), max: SIMD3(x + 0.01, 0.01, 0.01))
        }
        let frustum = OffscreenRenderer.wideViewFrustum(options: options)
        #expect(frustum.intersects(point(1)))
        #expect(!frustum.intersects(point(-1)))
        #expect(!frustum.intersects(point(12)))
    }
}
