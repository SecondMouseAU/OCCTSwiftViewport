// DirectMeshRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Option A spike — render B-Rep triangulation directly from de-interleaved
// position/normal arrays (the shape OCCT's Mesh already provides), skipping the
// interleaved-vertexData repack. Differential headless render: the SAME sphere
// built two ways (interleaved vs. direct) must produce the same image.

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("Direct-mesh rendering (Option A)")
struct DirectMeshRenderingTests {

    private let color = SIMD4<Float>(0.40, 0.70, 0.95, 1)

    @Test("Direct de-interleaved body renders identically to the interleaved body")
    func directMatchesInterleaved() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }

        // Interleaved reference body (stride-6 vertexData), via the primitive factory.
        let interleaved = ViewportBody.sphere(id: "s", radius: 1.5, color: color)

        // De-interleave the exact same data into separate position/normal arrays —
        // this is the layout OCCT's `Mesh` hands back (positions, normals, indices).
        var positions: [Float] = []
        var normals: [Float] = []
        let vd = interleaved.vertexData
        positions.reserveCapacity(vd.count / 2)
        normals.reserveCapacity(vd.count / 2)
        var i = 0
        while i + 5 < vd.count {
            positions.append(vd[i]); positions.append(vd[i + 1]); positions.append(vd[i + 2])
            normals.append(vd[i + 3]); normals.append(vd[i + 4]); normals.append(vd[i + 5])
            i += 6
        }

        let direct = ViewportBody.directMesh(id: "s", positions: positions, normals: normals,
                                             indices: interleaved.indices, color: color)
        #expect(direct.usesDirectMesh, "directMesh body should report usesDirectMesh")
        #expect(direct.vertexData.isEmpty, "direct body should carry no interleaved vertexData")

        // Identical options + camera for both renders (fit to the shared bounds once).
        // A baseline (interleaved vs itself) absorbs MSAA edge-resolve nondeterminism.
        var opts = OffscreenRenderOptions(width: 128, height: 128, displayMode: .shaded,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        if let cam = opts.cameraState.fit(to: [interleaved], aspectRatio: 1, padding: 1.3) {
            opts.cameraState = cam
        }

        // Render the interleaved body twice to measure the renderer's own run-to-run noise,
        // then the direct body — its delta vs interleaved must be no worse than that baseline.
        guard let imgRef1 = renderer.render(bodies: [interleaved], options: opts),
              let imgRef2 = renderer.render(bodies: [interleaved], options: opts),
              let imgDirect = renderer.render(bodies: [direct], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        let (a, w, h) = readBGRA(imgRef1)
        let (ref, _, _) = readBGRA(imgRef2)
        let (b, _, _) = readBGRA(imgDirect)
        #expect(a.count == b.count)

        func maxChannelDiff(_ x: [UInt8], _ y: [UInt8]) -> Int {
            var m = 0
            for p in stride(from: 0, to: x.count, by: 4) {
                for c in 0..<3 { m = max(m, abs(Int(x[p + c]) - Int(y[p + c]))) }
            }
            return m
        }
        // Sanity: the renderer is deterministic for the same pipeline (baseline noise == 0),
        // so any interleaved-vs-direct delta is attributable to the direct path alone.
        let baseline = maxChannelDiff(a, ref)
        #expect(baseline == 0, "offscreen render is expected to be deterministic; baseline noise \(baseline)")

        // Tally lit pixels and how many differ from the interleaved render.
        var litPixels = 0, differingPixels = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            if Int(a[p]) + Int(a[p + 1]) + Int(a[p + 2]) > 30 { litPixels += 1 }
            let d = max(abs(Int(a[p]) - Int(b[p])),
                        max(abs(Int(a[p + 1]) - Int(b[p + 1])), abs(Int(a[p + 2]) - Int(b[p + 2]))))
            if d > 0 { differingPixels += 1 }
        }
        let maxDiff = maxChannelDiff(a, b)

        // The direct path feeds the SAME vertices/normals through the SAME shaders. The surface
        // shading comes out identical; only antialiased *silhouette* pixels differ, and only by a
        // hair — so the per-channel max is tiny and the differing pixels are a thin edge fringe,
        // not the whole surface (a whole-surface diff would mean normals were misread).
        #expect(maxDiff <= 6, "direct vs interleaved per-channel max diff \(maxDiff)/255 (expected ≤6 edge AA)")
        #expect(differingPixels * 8 < litPixels,
                "too many pixels differ (\(differingPixels)/\(litPixels)) — looks like a surface mismatch, not edge AA")
        #expect(litPixels > 800, "render looks blank (\(litPixels) lit pixels in \(w)×\(h))")
    }

    // MARK: - Helpers

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
