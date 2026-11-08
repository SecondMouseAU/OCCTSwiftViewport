// TranslucentShadingTests.swift
// OCCTSwiftViewport Tests
//
// Shading of translucent surfaces (issue #136 H6 follow-up, flagged in #207):
// - a translucent body's far wall is seen through its near wall with vertex normals pointing
//   away from the camera; it used to be lit with those normals, so the Fresnel rim and the
//   environment reflection (which peak as N·V → 0) lit up the whole far wall;
// - "over" blending scales the whole colour by alpha, so glass at 10 % opacity lost its specular
//   highlight entirely.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Translucent surface shading")
struct TranslucentShadingTests {

    private static let size = 64
    private static let black = SIMD4<Float>(0, 0, 0, 1)

    // Camera at +Z (identity rotation) looking down -Z at the origin.
    private static let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

    /// A camera-facing quad at z = 3 whose vertex normals point along `normalZ` (+1 toward the
    /// camera, -1 away from it, as on the far wall of a closed body).
    private static func panel(normalZ: Float, alpha: Float) -> ViewportBody {
        let z: Float = 3
        let half: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, normalZ] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        return ViewportBody(
            id: "panel", vertexData: verts, indices: [0, 1, 2, 0, 2, 3], edges: [],
            color: SIMD4<Float>(0.3, 0.5, 0.8, alpha))
    }

    private static func options() -> OffscreenRenderOptions {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        var options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera, displayMode: .shaded,
            lightingConfiguration: lighting, backgroundColor: black)
        options.appearance = .light
        options.showGrid = false
        options.showAxes = false
        options.enableSilhouettes = false
        return options
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width
        let h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    private static func centre(_ bgra: [UInt8]) -> SIMD3<Int> {
        let i = (size / 2) * size * 4 + (size / 2) * 4
        return SIMD3<Int>(Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
    }

    @Test("A translucent far wall is shaded like the near wall, not as a rim")
    func backFacingTranslucentMatchesFrontFacing() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let front = try #require(
            renderer.render(bodies: [Self.panel(normalZ: 1, alpha: 0.5)], options: Self.options()))
        let back = try #require(
            renderer.render(bodies: [Self.panel(normalZ: -1, alpha: 0.5)], options: Self.options()))
        let f = Self.centre(Self.pixels(front))
        let b = Self.centre(Self.pixels(back))
        let d = f &- b
        #expect(
            max(abs(d.x), abs(d.y), abs(d.z)) <= 2, "front-facing \(f) vs back-facing \(b)")
    }

    @Test("Glass keeps its specular highlight over its low opacity")
    func glassKeepsSpecularHighlight() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var glass = ViewportBody.sphere(id: "glass", radius: 2.5)
        glass.material = PBRMaterial(
            baseColor: SIMD3<Float>(0.9, 0.9, 0.9), roughness: 0.1, opacity: 0.1)
        let image = try #require(renderer.render(bodies: [glass], options: Self.options()))
        let bgra = Self.pixels(image)
        var brightest = 0
        for p in stride(from: 0, to: bgra.count, by: 4) {
            brightest = max(brightest, Int(bgra[p + 1]))
        }
        // Over black, "over" blending at alpha 0.1 caps a non-boosted surface near 0.1 × 255.
        #expect(brightest > 120, "brightest highlight only \(brightest)/255")
    }
}
