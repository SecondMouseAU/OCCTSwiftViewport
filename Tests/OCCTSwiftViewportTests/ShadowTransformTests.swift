// ShadowTransformTests.swift
// OCCTSwiftViewport Tests
//
// The shaded fragment's shadow lookup must project the fragment's world position through the
// light's view-projection exactly once. `ShadedVertexOut.worldPosition` is already
// `modelMatrix * position`, so multiplying by `modelMatrix` again (issue #136, H2) sampled the
// shadow map at `transform * transform * p` for any body with a non-identity `transform`.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Shadow lookup honours body transforms once")
struct ShadowTransformTests {

    private static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    /// Returns `body` with its pure-translation `transform` baked into the vertex positions and
    /// edges, and an identity transform — the same world-space geometry, placed the other way.
    ///
    /// The caller passes a freshly built body with its own id, so no renderer buffer cache keyed
    /// on the transformed body's id/generation can serve it stale vertices.
    private static func baked(_ body: ViewportBody, offset: SIMD3<Float>) -> ViewportBody {
        var out = body
        var vd = body.vertexData
        var i = 0
        while i + 5 < vd.count {
            vd[i] += offset.x
            vd[i + 1] += offset.y
            vd[i + 2] += offset.z
            i += 6
        }
        out.vertexData = vd
        out.edges = body.edges.map { polyline in polyline.map { $0 + offset } }
        out.transform = matrix_identity_float4x4
        return out
    }

    private static let groundOffset = SIMD3<Float>(0.6, -1.0, 0.4)
    private static let casterOffset = SIMD3<Float>(-0.5, 0.2, 0.3)

    /// A ground slab and a box caster, placed by `transform` or baked into their vertices.
    private static func scene(baked bake: Bool) -> [ViewportBody] {
        let suffix = bake ? "-baked" : ""
        var ground = ViewportBody.box(
            id: "ground" + suffix, width: 6, height: 0.2, depth: 6,
            color: SIMD4<Float>(0.8, 0.8, 0.8, 1))
        var caster = ViewportBody.box(
            id: "caster" + suffix, width: 1, height: 1, depth: 1,
            color: SIMD4<Float>(0.8, 0.4, 0.2, 1))
        if bake {
            ground = baked(ground, offset: groundOffset)
            caster = baked(caster, offset: casterOffset)
        } else {
            ground.transform = translation(groundOffset.x, groundOffset.y, groundOffset.z)
            caster.transform = translation(casterOffset.x, casterOffset.y, casterOffset.z)
        }
        return [ground, caster]
    }

    private static func options() -> OffscreenRenderOptions {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.7
        // Keep the SSAO / silhouette composite (and its tone mapping) out of the shadow check.
        lighting.enableSSAO = false
        // Near top-down, so the key light's shadow (cast toward -X/-Z) is not hidden behind the
        // caster as it would be from a camera on the light's side.
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: -1.45, axis: SIMD3<Float>(1, 0, 0))
        camera.distance = 9
        camera.pivot = SIMD3<Float>(0, -0.9, 0)
        return OffscreenRenderOptions(
            width: 160, height: 160, cameraState: camera, displayMode: .shaded,
            lightingConfiguration: lighting, backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            appearance: .light, enableSilhouettes: false)
    }

    @Test("A transformed scene shadows exactly like the same scene baked into its vertices")
    func transformedMatchesBaked() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let transformed = Self.scene(baked: false)
        let bakedScene = Self.scene(baked: true)
        let opts = Self.options()

        var unshadowedOpts = opts
        unshadowedOpts.lightingConfiguration.shadowsEnabled = false

        guard let imgTransformed = renderer.render(bodies: transformed, options: opts),
            let imgBaked = renderer.render(bodies: bakedScene, options: opts),
            let imgNoShadow = renderer.render(bodies: bakedScene, options: unshadowedOpts)
        else {
            Issue.record("renderer returned nil image")
            return
        }
        let a = readBGRA(imgTransformed)
        let b = readBGRA(imgBaked)
        let none = readBGRA(imgNoShadow)

        // Sanity: the shadow is actually visible, so the comparison below is not vacuous.
        let shadowPixels = differingPixels(b, none, threshold: 20)
        #expect(shadowPixels > 200, "expected a visible cast shadow, got \(shadowPixels) pixels")

        // Same world geometry, so the shadow must land in the same place. GPU vs CPU translation
        // rounding can flip a handful of shadow-edge texels, nothing more.
        let mismatched = differingPixels(a, b, threshold: 20)
        #expect(
            mismatched < 40,
            "transformed bodies shadow differently from baked ones: \(mismatched) pixels differ")
    }

    // MARK: - Helpers

    private func differingPixels(_ x: [UInt8], _ y: [UInt8], threshold: Int) -> Int {
        guard x.count == y.count else { return max(x.count, y.count) / 4 }
        var n = 0
        for p in stride(from: 0, to: x.count, by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(x[p + c]) - Int(y[p + c]))) }
            if d > threshold { n += 1 }
        }
        return n
    }

    private func readBGRA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let bpr = width * 4
        var buffer = [UInt8](repeating: 0, count: bpr * height)
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue)
            {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }
}
