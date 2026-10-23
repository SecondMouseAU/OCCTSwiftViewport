// SSAOOcclusionTests.swift
// OCCTSwiftViewport Tests
//
// SSAO occludes only from the surface's normal-facing hemisphere (issue #136, H6 follow-up).
// The composite used to compare each tap's depth against the centre pixel's depth, so on any
// sloped or curved surface half the taps were "in front" and the surface darkened itself. Its
// sample radius was also `radius / depth` texels × 4, a fraction of a pixel at ordinary viewing
// distances, so real creases got no occlusion. A V-groove covers both: its flat sloped faces must
// not darken, and the concave valley must.

import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("SSAO hemisphere occlusion")
struct SSAOOcclusionTests {

    private static let size = 128
    private static let grey = SIMD4<Float>(0.6, 0.6, 0.6, 1)

    /// Two 45° panels meeting in a valley along the Y axis at z = 0, open toward +Z.
    private static func vGroove() -> ViewportBody {
        let h: Float = 4
        let n = 1 / Float(2).squareRoot()
        // Left panel: z = -x for x in [-4, 0]; outward normal (n, 0, n).
        // Right panel: z = x for x in [0, 4]; outward normal (-n, 0, n).
        let verts: [Float] = [
            -h, -h, h, n, 0, n,
            0, -h, 0, n, 0, n,
            0, h, 0, n, 0, n,
            -h, h, h, n, 0, n,
            0, -h, 0, -n, 0, n,
            h, -h, h, -n, 0, n,
            h, h, h, -n, 0, n,
            0, h, 0, -n, 0, n,
        ]
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7]
        return ViewportBody(id: "groove", vertexData: verts, indices: idx, edges: [], color: grey)
    }

    /// Renders the groove from +Z, returning BGRA8 pixels, or `nil` without Metal.
    private func render(ssao: Bool, orthographic: Bool = false) -> [UInt8]? {
        var camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 9,
            pivot: SIMD3<Float>(0, 0, 1))
        if orthographic {
            camera.isOrthographic = true
            camera.orthographicScale = 6
        }
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = ssao
        lighting.ssaoIntensity = 1.0
        let background = SIMD4<Float>(0, 0, 0, 1)
        let configuration = ViewportConfiguration(
            initialCameraState: camera, displayMode: .shaded, lightingConfiguration: lighting,
            showAxes: false, showGrid: false, backgroundColor: background,
            enableSilhouettes: false)
        let controller = ViewportController(configuration: configuration)
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        guard
            let renderer = ViewportRenderer(
                controller: controller, bodies: .constant([Self.vGroove()]))
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: Self.size, height: Self.size, backgroundColor: background)
    }

    /// Green channel at column `x` of the middle row.
    private static func value(_ bgra: [UInt8], x: Int) -> Int {
        Int(bgra[(size / 2) * size * 4 + x * 4 + 1])
    }

    private func check(orthographic: Bool) {
        guard let on = render(ssao: true, orthographic: orthographic),
            let off = render(ssao: false, orthographic: orthographic)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let mid = Self.size / 2
        // Open faces, well away from the valley: flat sloped surfaces must not self-occlude.
        for x in [mid - 40, mid - 30, mid + 30, mid + 40] {
            let a = Self.value(on, x: x)
            let b = Self.value(off, x: x)
            #expect(abs(a - b) <= 3, "face at x=\(x) darkened by SSAO: on \(a) off \(b)")
        }
        // Next to the valley: the opposite panel is in front of this one's tangent plane.
        let nearOn = Self.value(on, x: mid - 3) + Self.value(on, x: mid + 3)
        let nearOff = Self.value(off, x: mid - 3) + Self.value(off, x: mid + 3)
        #expect(nearOff - nearOn > 10, "valley not occluded: on \(nearOn) off \(nearOff)")
    }

    @Test("Perspective: sloped faces don't self-occlude; the concave valley does")
    func perspectiveGroove() {
        check(orthographic: false)
    }

    @Test("Orthographic: sloped faces don't self-occlude; the concave valley does")
    func orthographicGroove() {
        check(orthographic: true)
    }
}
