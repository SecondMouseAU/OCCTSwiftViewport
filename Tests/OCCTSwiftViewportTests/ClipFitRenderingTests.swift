// ClipFitRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Headless pixel tests for the scene-fitted clip planes and the native-edge depth bias.
// - #156: the near plane sat exactly on the scene AABB, so a flat panel facing the camera at the
//   AABB's front face landed at NDC z = 0 and was clipped.
// - #157: the live renderer fitted near/far from the previous frame's buffer cache, so the first
//   frame used the wide 0.01/10000 fallback, and the native wireframe pass's constant NDC depth
//   bias then spanned whole world units and drew hidden edges through faces.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Clip-plane fit and edge depth bias rendering")
struct ClipFitRenderingTests {

    private static let size = 128

    /// Perspective camera at +Z, 10 units from the origin, looking down -Z.
    private static let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

    private struct RenderUnavailable: Error {}

    // MARK: - #156: face-on geometry at the front of the scene bounds

    /// A white panel at z = 0 facing the camera; with no other geometry it IS the AABB's front face.
    private static func panel() -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        return ViewportBody(
            id: "panel", vertexData: v(-2, -2) + v(2, -2) + v(2, 2) + v(-2, 2),
            indices: [0, 1, 2, 0, 2, 3], edges: [], color: SIMD4<Float>(1, 1, 1, 1))
    }

    @Test(
        "A camera-facing panel at the AABB's near face renders in the live renderer",
        arguments: [false, true])
    func panelAtAABBFrontRendersLive(orthographic: Bool) throws {
        var camera = Self.camera
        camera.isOrthographic = orthographic
        let pair = try makeLive(
            bodies: [Self.panel()], edge: EdgeLineConfiguration(), camera: camera)
        // Several frames: the first (#157) and the steady state (#156) must both draw it.
        for frames in [1, 3] {
            let pixels = try render(pair.renderer, background: SIMD4(0, 0, 0, 1), frames: frames)
            let lit = Self.litFraction(pixels, inside: 40)
            #expect(lit > 0.95, "panel only \(lit) lit after \(frames) frame(s)")
        }
    }

    @Test("A camera-facing panel at the AABB's near face renders in OffscreenRenderer")
    func panelAtAABBFrontRendersOffscreen() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        let options = OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: Self.camera,
            displayMode: .shaded, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        guard let image = renderer.render(bodies: [Self.panel()], options: options) else {
            Issue.record("renderer returned nil image")
            throw RenderUnavailable()
        }
        let lit = Self.litFraction(Self.readBGRA(image), inside: 40)
        #expect(lit > 0.95, "panel only \(lit) lit")
    }

    @Test("A camera-facing edge-only square at the AABB's near face renders with native lines")
    func nativeEdgeOnlySquareRenders() throws {
        let square: [SIMD3<Float>] = [
            SIMD3(-2, -2, 0), SIMD3(2, -2, 0), SIMD3(2, 2, 0), SIMD3(-2, 2, 0), SIMD3(-2, -2, 0),
        ]
        let wire = ViewportBody(
            id: "wire", vertexData: [], indices: [], edges: [square],
            color: SIMD4<Float>(1, 1, 1, 1))
        let pair = try makeLive(
            bodies: [wire], edge: EdgeLineConfiguration(useQuadExpansion: false))
        let pixels = try render(pair.renderer, background: SIMD4(0, 0, 0, 1), frames: 2)
        // The middle column crosses the top and bottom sides of the square.
        let x = Self.size / 2
        let lit = (0..<Self.size).filter { y in Self.brightness(pixels, x: x, y: y) > 100 }
        #expect(lit.count >= 2, "native edge-only square drew \(lit.count) pixel(s) in the column")
    }

    // MARK: - #157: hidden native edges

    /// A white plate at z = 0.5 hiding a square of edges at z = 0 behind it.
    private static func plateHidingEdges() -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0.5, 0, 0, 1] }
        let square: [SIMD3<Float>] = [
            SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0), SIMD3(-1, 1, 0), SIMD3(-1, -1, 0),
        ]
        return ViewportBody(
            id: "plate", vertexData: v(-2, -2) + v(2, -2) + v(2, 2) + v(-2, 2),
            indices: [0, 1, 2, 0, 2, 3], edges: [square], color: SIMD4<Float>(1, 1, 1, 1))
    }

    @Test("The first frame's clip planes are fitted to the scene, not the wide fallback")
    func firstFrameIsFitted() throws {
        let body = Self.plateHidingEdges()
        let pair = try makeLive(bodies: [body], edge: EdgeLineConfiguration())
        _ = try render(pair.renderer, background: SIMD4(0, 0, 0, 1), frames: 1)
        let used = try #require(pair.renderer.lastFrameClipPlanes)
        let fitted = Self.camera.clipPlanes(sceneBounds: body.boundingBox)
        #expect(used.near == fitted.near && used.far == fitted.far, "frame 1 used \(used)")
        #expect(used.near > 1, "frame 1 used the 0.01 fallback near")
    }

    @Test("The first headless frame shows no hidden native edges through a face")
    func firstFrameHidesNativeEdges() throws {
        let pair = try makeLive(
            bodies: [Self.plateHidingEdges()], edge: EdgeLineConfiguration(useQuadExpansion: false))
        let pixels = try render(pair.renderer, background: SIMD4(1, 1, 1, 1), frames: 1)
        let dark = Self.darkCount(pixels, inside: 36)
        #expect(dark == 0, "hidden edges drew \(dark) pixels through the plate on frame 1")
    }

    @Test("Native edges stay hidden when near falls to its floor (camera inside the scene AABB)")
    func nativeEdgeBiasIsRangeIndependent() throws {
        // A small triangle behind the camera stretches the scene AABB around it, so near drops to
        // the far * 1e-4 floor and a constant NDC bias spans world units of depth.
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 30, 0, 0, 1] }
        let behind = ViewportBody(
            id: "behind", vertexData: v(0, 0) + v(0.1, 0) + v(0, 0.1), indices: [0, 1, 2],
            edges: [], color: SIMD4<Float>(1, 1, 1, 1))
        let bounds = Self.plateHidingEdges().boundingBox!.union(behind.boundingBox!)
        let clip = Self.camera.clipPlanes(sceneBounds: bounds)
        #expect(clip.far / clip.near > 9_000, "test premise: near should be at its floor")

        let pair = try makeLive(
            bodies: [Self.plateHidingEdges(), behind],
            edge: EdgeLineConfiguration(useQuadExpansion: false))
        let pixels = try render(pair.renderer, background: SIMD4(1, 1, 1, 1), frames: 2)
        let dark = Self.darkCount(pixels, inside: 36)
        #expect(dark == 0, "hidden edges drew \(dark) pixels through the plate")
    }

    @Test("Native edges on the visible face still draw")
    func visibleNativeEdgesDraw() throws {
        // Same plate, but the edges lie on its front face: the bias must still let them win.
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0.5, 0, 0, 1] }
        let square: [SIMD3<Float>] = [
            SIMD3(-1, -1, 0.5), SIMD3(1, -1, 0.5), SIMD3(1, 1, 0.5), SIMD3(-1, 1, 0.5),
            SIMD3(-1, -1, 0.5),
        ]
        let plate = ViewportBody(
            id: "plate", vertexData: v(-2, -2) + v(2, -2) + v(2, 2) + v(-2, 2),
            indices: [0, 1, 2, 0, 2, 3], edges: [square], color: SIMD4<Float>(1, 1, 1, 1))
        let pair = try makeLive(
            bodies: [plate], edge: EdgeLineConfiguration(useQuadExpansion: false))
        let pixels = try render(pair.renderer, background: SIMD4(1, 1, 1, 1), frames: 1)
        #expect(Self.darkCount(pixels, inside: 36) > 20, "edges on the face were not drawn")
    }

    // MARK: - Helpers

    private func makeLive(
        bodies: [ViewportBody], edge: EdgeLineConfiguration,
        camera: CameraState = ClipFitRenderingTests.camera
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.edgeLineConfiguration = edge
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shadedWithEdges
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        return (controller, renderer)
    }

    private func render(_ renderer: ViewportRenderer, background: SIMD4<Float>, frames: Int) throws
        -> [UInt8]
    {
        guard
            let pixels = renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: background,
                frameCount: frames)
        else {
            Issue.record("headless render returned nil")
            throw RenderUnavailable()
        }
        return pixels
    }

    private static func brightness(_ pixels: [UInt8], x: Int, y: Int) -> UInt8 {
        let i = (y * size + x) * 4
        return max(pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// Fraction of pixels in the centred square `size - 2 * inset` wide that are lit.
    private static func litFraction(_ pixels: [UInt8], inside inset: Int) -> Float {
        let range = inset..<(size - inset)
        var lit = 0
        for y in range { for x in range where brightness(pixels, x: x, y: y) > 100 { lit += 1 } }
        return Float(lit) / Float(range.count * range.count)
    }

    /// Edge-darkened pixels in the centred square `size - 2 * inset` wide.
    ///
    /// The square lies inside the plate's projection. The lit plate reads ~208; a 1 px native
    /// edge over it resolves to ~150.
    private static func darkCount(_ pixels: [UInt8], inside inset: Int) -> Int {
        let range = inset..<(size - inset)
        var dark = 0
        for y in range { for x in range where brightness(pixels, x: x, y: y) < 180 { dark += 1 } }
        return dark
    }

    private static func readBGRA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }
}
