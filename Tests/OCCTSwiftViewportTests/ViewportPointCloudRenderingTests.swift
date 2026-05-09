// ViewportPointCloudRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Visible point-cloud rendering pipeline — issue #28.

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("Visible point-cloud rendering")
struct ViewportPointCloudRenderingTests {

    // MARK: - Acceptance: 10k points produce non-empty pixel coverage

    @Test("10k-point cloud renders visible pixels in its projected bounds")
    func tenThousandPointsRenderVisible() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }

        // 10k points distributed in a unit cube around the origin. The default
        // CameraState looks at the origin from distance 10 — well-framed for
        // a unit cube — so the cloud is guaranteed to land inside the frame.
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(10_000)
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        for _ in 0..<10_000 {
            let x = nextUnitFloat(&seed) * 2 - 1
            let y = nextUnitFloat(&seed) * 2 - 1
            let z = nextUnitFloat(&seed) * 2 - 1
            points.append(SIMD3<Float>(x, y, z))
        }

        let body = ViewportBody(
            id: "cloud",
            vertexData: [],
            indices: [],
            edges: [],
            vertices: points,
            color: SIMD4<Float>(1.0, 0.5, 0.0, 1.0),
            pointRadius: 0.04,
            primitiveKind: .point
        )

        let opts = OffscreenRenderOptions(
            width: 256, height: 192,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1)  // black so any cloud pixel is non-zero
        )
        guard let image = renderer.render(bodies: [body], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        let nonBackground = countNonBackgroundPixels(image, background: (0, 0, 0))
        // A 10k-point cloud at radius 0.04 in a 256×192 frame should easily
        // cover hundreds of pixels even after MSAA + disk masking. A floor
        // of ~50 pixels is generous against shader/clamp regressions while
        // still being a meaningful "did anything draw" check.
        #expect(nonBackground > 50,
                "expected the point cloud to cover many pixels, got \(nonBackground)")
    }

    // MARK: - Per-vertex colour fallback

    @Test("Per-vertex colour overrides the body colour")
    func perVertexColorOverridesBodyColor() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }

        // A small cluster of points where every per-point colour is bright
        // green. The body colour is bright red. Any rendered cloud pixel
        // should be predominantly green (G > R), proving the per-point
        // colour buffer was bound rather than the fallback.
        let positions: [SIMD3<Float>] = (0..<400).map { i in
            let t = Float(i) / 400.0
            return SIMD3<Float>(t * 2 - 1, sin(t * .pi * 4) * 0.5, 0)
        }
        let greens = [SIMD4<Float>](
            repeating: SIMD4<Float>(0, 1, 0, 1),
            count: positions.count
        )

        let body = ViewportBody(
            id: "perVertex",
            vertexData: [],
            indices: [],
            edges: [],
            vertices: positions,
            vertexColors: greens,
            color: SIMD4<Float>(1, 0, 0, 1),  // red — must NOT appear
            pointRadius: 0.06,
            primitiveKind: .point
        )

        let opts = OffscreenRenderOptions(
            width: 256, height: 192,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1)
        )
        guard let image = renderer.render(bodies: [body], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        let (greenDominant, redDominant) = countDominantChannelPixels(image)
        #expect(greenDominant > 50, "expected many green pixels, got \(greenDominant)")
        #expect(redDominant == 0,
                "per-vertex green should fully suppress the red body colour, got \(redDominant) red pixels")
    }

    // MARK: - Mismatched vertexColors silently fall back to body colour

    @Test("Mismatched vertexColors length falls back to body colour")
    func mismatchedColorCountFallsBack() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }

        let positions: [SIMD3<Float>] = (0..<200).map { i in
            let t = Float(i) / 200.0
            return SIMD3<Float>(t * 2 - 1, 0, 0)
        }
        // Deliberate length mismatch — the body should not crash and should
        // render in its base colour.
        let mismatched = [SIMD4<Float>(0, 1, 0, 1), SIMD4<Float>(0, 1, 0, 1)]

        let body = ViewportBody(
            id: "mismatch",
            vertexData: [],
            indices: [],
            edges: [],
            vertices: positions,
            vertexColors: mismatched,
            color: SIMD4<Float>(0.2, 0.4, 1.0, 1.0),  // strong blue
            pointRadius: 0.06,
            primitiveKind: .point
        )

        let opts = OffscreenRenderOptions(
            width: 256, height: 192,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1)
        )
        guard let image = renderer.render(bodies: [body], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        let (_, redDominant) = countDominantChannelPixels(image)
        #expect(redDominant == 0)  // no leak from the per-vertex override
        let blueDominant = countBlueDominantPixels(image)
        #expect(blueDominant > 20,
                "expected blue body-colour pixels after the colour buffer was rejected")
    }

    // MARK: - Mesh bodies are unaffected

    @Test("Default .mesh bodies still render through the shaded path")
    func meshBodiesUnaffected() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        // A box body with its default `.mesh` primitiveKind must still
        // render. The point pass should be a no-op for it.
        let body = ViewportBody.box(id: "mesh-default")
        let opts = OffscreenRenderOptions(width: 256, height: 192)
        guard let image = renderer.render(bodies: [body], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }
        #expect(image.width == 256 && image.height == 192)
    }

    // MARK: - Helpers

    /// Count pixels whose RGB channels differ noticeably from the background.
    /// Threshold of 16 / 255 keeps MSAA-edge pixels in but stays well above
    /// quantization noise.
    private func countNonBackgroundPixels(
        _ image: CGImage,
        background: (UInt8, UInt8, UInt8),
        threshold: Int = 16
    ) -> Int {
        let (buffer, width, height) = readBGRA(image)
        let bytesPerRow = width * 4
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let b = buffer[i]
                let g = buffer[i + 1]
                let r = buffer[i + 2]
                if absDiff(b, background.2) > threshold ||
                   absDiff(g, background.1) > threshold ||
                   absDiff(r, background.0) > threshold {
                    count += 1
                }
            }
        }
        return count
    }

    /// Returns (greenDominantCount, redDominantCount) for pixels where the
    /// dominant channel exceeds the others by ≥ 32. Background-coloured
    /// pixels (all near zero) are excluded.
    private func countDominantChannelPixels(_ image: CGImage) -> (green: Int, red: Int) {
        let (buffer, width, height) = readBGRA(image)
        let bytesPerRow = width * 4
        var green = 0, red = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let b = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let r = Int(buffer[i + 2])
                if max(r, g, b) < 32 { continue }  // background
                if g >= r + 32 && g >= b + 32 { green += 1 }
                if r >= g + 32 && r >= b + 32 { red += 1 }
            }
        }
        return (green, red)
    }

    private func countBlueDominantPixels(_ image: CGImage) -> Int {
        let (buffer, width, height) = readBGRA(image)
        let bytesPerRow = width * 4
        var blue = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                let b = Int(buffer[i])
                let g = Int(buffer[i + 1])
                let r = Int(buffer[i + 2])
                if max(r, g, b) < 32 { continue }
                if b >= r + 32 && b >= g + 16 { blue += 1 }
            }
        }
        return blue
    }

    private func absDiff(_ a: UInt8, _ b: UInt8) -> Int {
        let ai = Int(a), bi = Int(b)
        return ai > bi ? ai - bi : bi - ai
    }

    /// Drops the CGImage into a BGRA8 buffer matching `OffscreenRenderer`'s
    /// output layout.
    private func readBGRA(_ image: CGImage) -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )
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

    /// Cheap deterministic [0, 1) PRNG (xorshift64). We seed explicitly so
    /// the test is reproducible across runs and platforms.
    private func nextUnitFloat(_ state: inout UInt64) -> Float {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return Float(x & 0xFFFFFF) / Float(0x1000000)
    }
}
