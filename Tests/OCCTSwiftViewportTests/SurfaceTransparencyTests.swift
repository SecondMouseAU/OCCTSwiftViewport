// SurfaceTransparencyTests.swift
// OCCTSwiftViewport Tests
//
// Per-body surface transparency (issue #53). Differential headless render:
// the same scene with the front box opaque vs translucent — the translucent
// render must reveal more of the opaque red box behind it.

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("Surface transparency")
struct SurfaceTransparencyTests {

    // Camera at +Z (identity rotation) looking down -Z at the origin, so a larger
    // +Z offset is nearer the camera.
    private let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero
    )

    /// A flat quad at depth `z` facing +Z (toward the camera). Positions are baked
    /// into the geometry because `OffscreenRenderer` doesn't apply `body.transform`.
    private func panel(id: String, z: Float, half: Float, color: SIMD4<Float>) -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        return ViewportBody(id: id, vertexData: verts, indices: idx, edges: [], color: color)
    }

    /// Red opaque box at the origin, with a large blue panel baked in front of it
    /// (toward the camera at +Z) that fully covers it in screen space.
    private func scene(blueAlpha: Float) -> [ViewportBody] {
        let red = ViewportBody.box(id: "red", width: 2, height: 2, depth: 2,
                                   color: SIMD4<Float>(1, 0, 0, 1))
        let blue = panel(id: "blue", z: 3, half: 3, color: SIMD4<Float>(0, 0, 1, blueAlpha))
        return [red, blue]
    }

    @Test("Translucent front body reveals the opaque body behind it (#53)")
    func translucentRevealsBehind() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let opts = OffscreenRenderOptions(width: 200, height: 200, cameraState: camera,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))

        guard let opaqueImg = renderer.render(bodies: scene(blueAlpha: 1.0), options: opts),
              let transImg = renderer.render(bodies: scene(blueAlpha: 0.3), options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        // With an OPAQUE blue panel in front, the red box is hidden → almost no red.
        // With a TRANSLUCENT panel, the red shows through → many red-bearing pixels.
        let redOpaque = countRedBearingPixels(opaqueImg)
        let redTrans = countRedBearingPixels(transImg)

        #expect(redOpaque < 400,
                "opaque front panel should hide the red box, got \(redOpaque) red pixels")
        #expect(redTrans > redOpaque + 1000,
                "translucent panel should reveal the red box behind; opaque=\(redOpaque) translucent=\(redTrans)")
    }

    // MARK: - Helpers

    /// Pixels where the red channel is clearly present and not a white specular
    /// highlight (red noticeably exceeds green).
    private func countRedBearingPixels(_ image: CGImage) -> Int {
        let (buffer, width, height) = readBGRA(image)
        let bytesPerRow = width * 4
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let b = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let r = Int(buffer[i + 2])
                _ = b
                if r > 60 && r > g + 30 { count += 1 }
            }
        }
        return count
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
