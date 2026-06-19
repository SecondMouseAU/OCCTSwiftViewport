// UnlitColorTests.swift
// OCCTSwiftViewport Tests
//
// Unlit / flat-colour display mode (issue #77). Headless render: a vivid magenta
// panel rendered with `.unlit` must reproduce its base colour faithfully (no
// lighting / ambient / fresnel / tone-map desaturation), where `.shaded` washes
// it out toward grey/green.

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("Unlit display mode")
struct UnlitColorTests {

    // Camera at +Z (identity rotation) looking down -Z at the origin.
    private let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero
    )

    // A vivid magenta — the diagnostic colour from the issue that `.shaded` desaturates.
    private let magenta = SIMD4<Float>(1.0, 0.15, 0.85, 1.0)

    /// A flat quad at depth `z` facing +Z (toward the camera), covering the centre.
    /// Positions are baked in because `OffscreenRenderer` doesn't apply `body.transform`.
    private func panel(color: SIMD4<Float>) -> ViewportBody {
        let z: Float = 3, half: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        return ViewportBody(id: "panel", vertexData: verts, indices: idx, edges: [], color: color)
    }

    @Test("Unlit mode reproduces the body's base colour faithfully (#77)")
    func unlitIsFaithful() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let base = OffscreenRenderOptions(width: 64, height: 64, cameraState: camera,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        var unlitOpts = base; unlitOpts.displayMode = .unlit
        var shadedOpts = base; shadedOpts.displayMode = .shaded

        guard let unlitImg = renderer.render(bodies: [panel(color: magenta)], options: unlitOpts),
              let shadedImg = renderer.render(bodies: [panel(color: magenta)], options: shadedOpts) else {
            Issue.record("renderer returned nil image")
            return
        }

        let (ur, ug, ub) = centerPixel(unlitImg)
        let (sr, sg, sb) = centerPixel(shadedImg)

        // Unlit centre is the source magenta (≈ 255, 38, 217), within tolerance:
        // red & blue dominant, green clearly the smallest channel.
        #expect(ur > 200, "unlit red should be high, got \(ur)")
        #expect(ub > 170, "unlit blue should be high, got \(ub)")
        #expect(ug < 90, "unlit green should be low, got \(ug)")
        #expect(ur - ug > 110 && ub - ug > 70,
                "unlit pixel should read as magenta, got (\(ur),\(ug),\(ub))")

        // Unlit preserves far more saturation than shaded (the whole point of #77).
        let satUnlit = max(ur, ug, ub) - min(ur, ug, ub)
        let satShaded = max(sr, sg, sb) - min(sr, sg, sb)
        #expect(satUnlit > satShaded,
                "unlit should be more saturated than shaded; unlit=\(satUnlit) shaded=\(satShaded) (unlit rgb \(ur),\(ug),\(ub) / shaded rgb \(sr),\(sg),\(sb))")
    }

    // MARK: - Helpers

    /// (r, g, b) of the centre pixel, 0–255.
    private func centerPixel(_ image: CGImage) -> (Int, Int, Int) {
        let (buffer, width, height) = readBGRA(image)
        let bytesPerRow = width * 4
        let x = width / 2, y = height / 2
        let i = y * bytesPerRow + x * 4
        return (Int(buffer[i + 2]), Int(buffer[i + 1]), Int(buffer[i]))
    }

    private func readBGRA(_ image: CGImage) -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (buffer, width, height)
    }
}
