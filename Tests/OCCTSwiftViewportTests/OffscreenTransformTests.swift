// OffscreenTransformTests.swift
// OCCTSwiftViewport Tests
//
// OffscreenRenderer now honours per-body `transform` (issue #55).

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("OffscreenRenderer per-body transform")
struct OffscreenTransformTests {

    @Test("A body's transform offsets it in headless renders (#55)")
    func transformOffsetsGeometry() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let opts = OffscreenRenderOptions(width: 200, height: 200,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))

        // Box at the origin (identity transform) — fills the centre of the frame.
        let centered = ViewportBody.box(id: "b", width: 1.5, height: 1.5, depth: 1.5,
                                        color: SIMD4<Float>(0.9, 0.9, 0.9, 1))
        guard let imgCentered = renderer.render(bodies: [centered], options: opts) else {
            Issue.record("nil image"); return
        }

        // Same box translated far out of the view frustum. If `transform` is
        // applied it disappears; if ignored (the old behaviour) it would render
        // identically to the centered case.
        var moved = ViewportBody.box(id: "b2", width: 1.5, height: 1.5, depth: 1.5,
                                     color: SIMD4<Float>(0.9, 0.9, 0.9, 1))
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(1000, 0, 0, 1)
        moved.transform = t
        guard let imgMoved = renderer.render(bodies: [moved], options: opts) else {
            Issue.record("nil image"); return
        }

        let nCentered = countNonBackground(imgCentered)
        let nMoved = countNonBackground(imgMoved)
        #expect(nCentered > 1000, "centered box should cover the frame, got \(nCentered)")
        #expect(nMoved < nCentered / 10,
                "translated-out-of-frame box should mostly disappear; centered=\(nCentered) moved=\(nMoved)")
    }

    @Test("A modest transform shifts the body toward the offset direction")
    func transformShiftsCentroid() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        // Camera at +Z looking down -Z, so +X world maps to +X (right) on screen.
        let camera = CameraState(rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
                                 distance: 10, pivot: .zero)
        let opts = OffscreenRenderOptions(width: 200, height: 200, cameraState: camera,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))

        var right = ViewportBody.box(id: "r", width: 1, height: 1, depth: 1,
                                     color: SIMD4<Float>(0.9, 0.9, 0.9, 1))
        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(2.5, 0, 0, 1)   // shift right
        right.transform = t

        guard let img = renderer.render(bodies: [right], options: opts) else {
            Issue.record("nil image"); return
        }
        let cx = centroidX(img)
        // The box was shifted +X, so its rendered centroid should sit right of centre.
        #expect(cx > Float(img.width) * 0.5, "expected centroid right of centre, got \(cx)")
    }

    // MARK: - Helpers

    private func countNonBackground(_ image: CGImage, threshold: Int = 24) -> Int {
        let (buffer, width, height) = readBGRA(image)
        let bpr = width * 4
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                if Int(buffer[i]) > threshold || Int(buffer[i + 1]) > threshold || Int(buffer[i + 2]) > threshold {
                    count += 1
                }
            }
        }
        return count
    }

    /// Mean x of non-background pixels (0 if none).
    private func centroidX(_ image: CGImage, threshold: Int = 24) -> Float {
        let (buffer, width, height) = readBGRA(image)
        let bpr = width * 4
        var sum = 0, n = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bpr + x * 4
                if Int(buffer[i]) > threshold || Int(buffer[i + 1]) > threshold || Int(buffer[i + 2]) > threshold {
                    sum += x; n += 1
                }
            }
        }
        return n > 0 ? Float(sum) / Float(n) : 0
    }

    private func readBGRA(_ image: CGImage) -> ([UInt8], Int, Int) {
        let width = image.width, height = image.height
        let bpr = width * 4
        var buffer = [UInt8](repeating: 0, count: bpr * height)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: bpr, space: cs, bitmapInfo: info.rawValue) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (buffer, width, height)
    }
}
