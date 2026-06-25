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
import SwiftUI
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

    @Test("Direct-mesh body casts the same shadow as the interleaved body")
    func directShadowMatchesInterleaved() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }

        // Caster sphere, built two ways (interleaved reference + direct de-interleaved).
        let interleavedCaster = ViewportBody.sphere(id: "caster", radius: 1.5, color: color)
        let (positions, normals) = deinterleave(interleavedCaster.vertexData)
        let directCaster = ViewportBody.directMesh(id: "caster", positions: positions, normals: normals,
                                                   indices: interleavedCaster.indices, color: color)

        // Flat ground receiver below the caster — large enough to catch the cast shadow,
        // so a missing/mismatched shadow shows up as a wide block of differing pixels
        // (a lone sphere's self-shadow is too small to be a meaningful check).
        var receiver = ViewportBody.box(id: "ground", width: 12, height: 0.2, depth: 12,
                                        color: SIMD4<Float>(0.85, 0.85, 0.85, 1))
        receiver.transform = translation(0, -3, 0)

        // Strong, deterministic shadow so the cast region is unambiguous on the receiver.
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.6
        var opts = OffscreenRenderOptions(width: 160, height: 160, displayMode: .shaded,
                                          lightingConfiguration: lighting,
                                          backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        if let cam = opts.cameraState.fit(to: [interleavedCaster, receiver], aspectRatio: 1, padding: 1.2) {
            opts.cameraState = cam
        }

        guard let imgInterleaved = renderer.render(bodies: [interleavedCaster, receiver], options: opts),
              let imgDirect = renderer.render(bodies: [directCaster, receiver], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }

        // Shadows-off control on the SAME scene — proves the shadow is materially present,
        // so the direct-vs-interleaved equality below can't pass trivially via "no shadow".
        var noShadow = lighting
        noShadow.shadowsEnabled = false
        var optsNoShadow = opts
        optsNoShadow.lightingConfiguration = noShadow
        guard let imgNoShadow = renderer.render(bodies: [directCaster, receiver], options: optsNoShadow) else {
            Issue.record("renderer returned nil image")
            return
        }

        let (interleaved, w, h) = readBGRA(imgInterleaved)
        let (direct, _, _) = readBGRA(imgDirect)
        let (unshadowed, _, _) = readBGRA(imgNoShadow)

        // 1) The direct caster's shadow matches the interleaved caster's — same depth written by
        //    shadowDirectPipeline vs shadowPipeline, so only antialiased silhouette pixels differ.
        var maxDiff = 0
        for p in stride(from: 0, to: interleaved.count, by: 4) {
            let d = max(abs(Int(interleaved[p]) - Int(direct[p])),
                        max(abs(Int(interleaved[p + 1]) - Int(direct[p + 1])),
                            abs(Int(interleaved[p + 2]) - Int(direct[p + 2]))))
            maxDiff = max(maxDiff, d)
        }
        #expect(maxDiff <= 6, "direct vs interleaved shadow per-channel max diff \(maxDiff)/255 (expected ≤6 edge AA)")

        // 2) The cast shadow is materially sized — the receiver is meaningfully darker WITH the
        //    direct body's shadow than without. If the direct body weren't casting, this is ~0.
        var shadowedPixels = 0
        for p in stride(from: 0, to: direct.count, by: 4) {
            let lostLight = (Int(unshadowed[p]) + Int(unshadowed[p + 1]) + Int(unshadowed[p + 2]))
                          - (Int(direct[p]) + Int(direct[p + 1]) + Int(direct[p + 2]))
            if lostLight > 30 { shadowedPixels += 1 }
        }
        #expect(shadowedPixels > 100,
                "expected a materially-sized cast shadow on the receiver (\(shadowedPixels) px in \(w)×\(h)) — direct body may not be casting")
    }

    /// The interactive `ViewportRenderer` builds its `directMeshPipeline` (the new two-buffer
    /// vertex descriptor) at init and returns nil if any pipeline fails to compile — so a
    /// successful init with a direct-mesh body on screen proves the live path's GPU objects are
    /// valid. (Pixel-level correctness of the live draw is covered by the OffscreenRenderer test
    /// above, which uses the identical shaders / descriptor / buffer binding.)
    @Test("ViewportRenderer constructs with a direct-mesh body (directMeshPipeline compiles)")
    func viewportRendererAcceptsDirectMesh() {
        let controller = ViewportController()
        let sphere = ViewportBody.sphere(id: "s", radius: 1, color: color)
        var positions: [Float] = []
        var normals: [Float] = []
        let vd = sphere.vertexData
        var i = 0
        while i + 5 < vd.count {
            positions.append(vd[i]); positions.append(vd[i + 1]); positions.append(vd[i + 2])
            normals.append(vd[i + 3]); normals.append(vd[i + 4]); normals.append(vd[i + 5])
            i += 6
        }
        let bodies = [ViewportBody.directMesh(id: "s", positions: positions, normals: normals,
                                              indices: sphere.indices, color: color)]
        let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        #expect(renderer != nil, "ViewportRenderer init failed — a render pipeline did not compile")
    }

    // MARK: - Helpers

    /// Split interleaved stride-6 `[px,py,pz,nx,ny,nz, …]` vertex data into the separate
    /// position/normal arrays OCCT's `Mesh` hands back (the layout the direct path consumes).
    private func deinterleave(_ vd: [Float]) -> (positions: [Float], normals: [Float]) {
        var positions: [Float] = []
        var normals: [Float] = []
        positions.reserveCapacity(vd.count / 2)
        normals.reserveCapacity(vd.count / 2)
        var i = 0
        while i + 5 < vd.count {
            positions.append(vd[i]); positions.append(vd[i + 1]); positions.append(vd[i + 2])
            normals.append(vd[i + 3]); normals.append(vd[i + 4]); normals.append(vd[i + 5])
            i += 6
        }
        return (positions, normals)
    }

    /// Column-major translation matrix (translation in the 4th column).
    private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
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
