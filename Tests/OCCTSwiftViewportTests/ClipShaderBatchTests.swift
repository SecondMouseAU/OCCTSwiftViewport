// ClipShaderBatchTests.swift
// OCCTSwiftViewport Tests
//
// Headless pixel tests for three shader fixes:
// - #162: the shadow-map pass ignored section clip planes, so geometry a clip plane removed still
//   cast its shadow into what was left.
// - #164: with MSAA, `worldPosition` was interpolated at the pixel centre, i.e. extrapolated past
//   the triangle edge for partially covered pixels, so the clip test kept samples of a clipped-away
//   wall seen nearly edge-on and left a ghost line along its silhouette.
// - #181: the edge depth fade mapped hyperbolic NDC depth straight to 0-1, so edges faded far
//   more than their distance warranted.
//
// Every test drives `ViewportRenderer`'s real frame encoder through its headless entry point:
// `OffscreenRenderer` has no clip-plane option yet (it arrives with #154), though its shadow pass
// now binds the clip uniforms too.

import Foundation
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
private enum BatchScene {

    struct Unavailable: Error {}

    static let background = SIMD4<Float>(0, 0, 0, 1)

    /// Builds a controller/renderer pair; the controller is returned because the renderer only
    /// holds it weakly.
    static func makeRenderer(
        bodies: [ViewportBody],
        camera: CameraState,
        clipPlanes: [ClipPlane],
        displayMode: DisplayMode,
        shadows: Bool = false,
        msaa: Int = 4,
        quality: RenderingQuality = .standard,
        edges: EdgeLineConfiguration = EdgeLineConfiguration(),
        edgeIntensity: Float? = nil
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = shadows
        lighting.shadowIntensity = 0.7
        lighting.enableSSAO = false
        let configuration = ViewportConfiguration(
            initialCameraState: camera,
            displayMode: displayMode,
            lightingConfiguration: lighting,
            showAxes: false,
            showGrid: false,
            backgroundColor: background,
            msaaSampleCount: msaa,
            enableSilhouettes: false,
            edgeLineConfiguration: edges,
            renderingQuality: quality
        )
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = displayMode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.clipPlanes = clipPlanes
        if let edgeIntensity { controller.edgeIntensity = edgeIntensity }
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw Unavailable()
        }
        return (controller, renderer)
    }

    static func render(
        _ pair: (controller: ViewportController, renderer: ViewportRenderer),
        width: Int, height: Int
    ) throws -> [UInt8] {
        guard
            let pixels = pair.renderer.renderHeadlessBGRA(
                width: width, height: height, backgroundColor: background)
        else {
            Issue.record("headless render returned nil")
            throw Unavailable()
        }
        return pixels
    }

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    /// Number of pixels whose largest RGB channel difference exceeds `threshold`.
    static func differingPixels(_ a: [UInt8], _ b: [UInt8], threshold: Int) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) / 4 }
        var n = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(a[p + c]) - Int(b[p + c]))) }
            if d > threshold { n += 1 }
        }
        return n
    }
}

// MARK: - #162: clipped geometry casts no shadow

@MainActor
@Suite("Section clip planes apply to the shadow map")
struct ShadowClipPlaneTests {

    /// A ground slab whose top is at y = -0.9, and a box caster above it from y = -0.3 to 0.7.
    ///
    /// Without the caster, an edge-only stand-in with the same bounds takes its place: edge-only
    /// bodies cast no shadow, and keeping the scene bounds identical keeps the light frustum and
    /// the camera's near/far identical, so the two frames differ only by the caster's shadow.
    private static func scene(withCaster: Bool) -> [ViewportBody] {
        var ground = ViewportBody.box(
            id: "ground", width: 6, height: 0.2, depth: 6, color: SIMD4<Float>(0.8, 0.8, 0.8, 1))
        ground.transform = BatchScene.translation(0.6, -1.0, 0.4)
        var caster = ViewportBody.box(
            id: "caster", width: 1, height: 1, depth: 1, color: SIMD4<Float>(0.8, 0.4, 0.2, 1))
        caster.transform = BatchScene.translation(-0.5, 0.2, 0.3)
        if !withCaster {
            var standIn = ViewportBody(
                id: "caster-bounds", vertexData: [], indices: [], edges: caster.edges,
                color: SIMD4<Float>(0.8, 0.4, 0.2, 1))
            standIn.transform = caster.transform
            caster = standIn
        }
        return [ground, caster]
    }

    /// Keeps y <= -0.5: all of the ground, none of the caster.
    private static let section = ClipPlane(normal: SIMD3<Float>(0, -1, 0), distance: -0.5)

    /// Near top-down, so the key light's shadow is not hidden behind the caster.
    private static var camera: CameraState {
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: -1.45, axis: SIMD3<Float>(1, 0, 0))
        camera.distance = 9
        camera.pivot = SIMD3<Float>(0, -0.9, 0)
        return camera
    }

    private func render(withCaster: Bool, clipped: Bool, quality: RenderingQuality) throws
        -> [UInt8]
    {
        let pair = try BatchScene.makeRenderer(
            bodies: Self.scene(withCaster: withCaster), camera: Self.camera,
            clipPlanes: clipped ? [Self.section] : [], displayMode: .shaded, shadows: true,
            quality: quality)
        return try BatchScene.render(pair, width: 160, height: 160)
    }

    @Test(
        "A caster removed by a section plane leaves no shadow on the geometry that remains",
        arguments: [RenderingQuality.standard, .enhanced, .maximum])
    func clippedCasterCastsNoShadow(quality: RenderingQuality) throws {
        // Control: unclipped, the caster's shadow is plainly visible on the ground, so the
        // comparison below would catch it.
        let unclippedWith = try render(withCaster: true, clipped: false, quality: quality)
        let unclippedWithout = try render(withCaster: false, clipped: false, quality: quality)
        let shadowAndCaster = BatchScene.differingPixels(
            unclippedWith, unclippedWithout, threshold: 20)
        #expect(shadowAndCaster > 400, "control: caster + shadow covered \(shadowAndCaster) px")

        // Clipped, the caster is gone, and so must its shadow be: the frame matches a scene that
        // never had the caster.
        let clippedWith = try render(withCaster: true, clipped: true, quality: quality)
        let clippedWithout = try render(withCaster: false, clipped: true, quality: quality)
        let ghostShadow = BatchScene.differingPixels(clippedWith, clippedWithout, threshold: 20)
        #expect(
            ghostShadow < 10,
            "a clipped-away caster still shadows \(ghostShadow) px (\(quality))")
    }
}

// MARK: - #164: no MSAA ghost line at a section cut

@MainActor
@Suite("MSAA section cut leaves no ghost of the clipped-away part")
struct MSAASectionGhostTests {

    struct View: CustomTestStringConvertible, Sendable {
        let eye: SIMD3<Float>
        let quality: RenderingQuality
        var testDescription: String { "eye \(eye), \(quality)" }
    }

    /// Eyes from which the box's top wall is seen nearly edge-on, so a sample just past its
    /// silhouette extrapolates a long way along the wall, across the cut.
    nonisolated static let views: [View] = [
        SIMD3<Float>(-4, 0.51, 1.5), SIMD3<Float>(-1.5, 0.52, 5),
    ].flatMap { eye in
        [RenderingQuality.standard, .enhanced, .maximum].map { View(eye: eye, quality: $0) }
    }

    @Test(
        "A clipped box at MSAA 4 covers no pixel the physically cut box leaves empty",
        arguments: views)
    func noGhostOutsideCutFootprint(view: View) throws {
        let camera = CameraState.lookAt(target: SIMD3<Float>(0.3, 0, 0), from: view.eye)
        let white = SIMD4<Float>(1, 1, 1, 1)

        // A 2-wide box with ClipPlane.xPlane removing x < 0 ...
        let full = ViewportBody.box(id: "full", width: 2, height: 1, depth: 1, color: white)
        let clipped = try BatchScene.render(
            BatchScene.makeRenderer(
                bodies: [full], camera: camera, clipPlanes: [.xPlane], displayMode: .unlit,
                quality: view.quality),
            width: 200, height: 160)

        // ... has the same screen footprint as the 1-wide box that really is cut there (convex,
        // and its cap lies in the clip plane), so any pixel lit by the first and empty in the
        // second is a sample of the removed half that escaped the clip test.
        var half = ViewportBody.box(id: "half", width: 1, height: 1, depth: 1, color: white)
        half.transform = BatchScene.translation(0.5, 0, 0)
        let reference = try BatchScene.render(
            BatchScene.makeRenderer(
                bodies: [half], camera: camera, clipPlanes: [], displayMode: .unlit,
                quality: view.quality),
            width: 200, height: 160)

        var ghost = 0
        for p in stride(from: 0, to: clipped.count, by: 4) {
            let lit = max(clipped[p], clipped[p + 1], clipped[p + 2])
            let refLit = max(reference[p], reference[p + 1], reference[p + 2])
            if refLit == 0 && lit > 8 { ghost += 1 }
        }
        #expect(ghost < 3, "\(ghost) ghost pixels of the clipped-away half at MSAA 4")
    }
}

// MARK: - #181: linear edge depth fade

@MainActor
@Suite("Edge depth fade is linear in view distance")
struct EdgeDepthFadeTests {

    private static let width = 200
    private static let height = 240
    private static let rungDepths: [Float] = [0, -3, -6, -9, -12]
    private static let camera = CameraState.lookAt(
        target: SIMD3<Float>(0, 0, -5), from: SIMD3<Float>(0, 9, 5))
    /// Dimmed so the fade shows: minAlpha = 0.6, alpha = 0.5 * mix(1, 0.6, fade).
    private static let edgeIntensity: Float = 0.5

    /// Horizontal edge "rungs" receding from the camera, on a body with a mesh.
    ///
    /// The tiny triangle is there because edge-only bodies skip the fade. The body is blue, so
    /// its contrast-adaptive edge colour is (0.6, 0.6, 1).
    private static func ladder() -> ViewportBody {
        let edges = rungDepths.map { z in [SIMD3<Float>(-2, 0, z), SIMD3<Float>(2, 0, z)] }
        let tri: [Float] = [
            0, 0, -6, 0, 1, 0,
            0.01, 0, -6, 0, 1, 0,
            0, 0, -6.01, 0, 1, 0,
        ]
        return ViewportBody(
            id: "ladder", vertexData: tri, indices: [0, 1, 2], edges: edges,
            color: SIMD4<Float>(0, 0, 1, 1))
    }

    @Test("Edge brightness falls off linearly with depth", arguments: [true, false])
    func linearFade(quadExpansion: Bool) throws {
        let body = Self.ladder()
        let edges = EdgeLineConfiguration(width: 3, useQuadExpansion: quadExpansion)
        let pixels = try BatchScene.render(
            BatchScene.makeRenderer(
                bodies: [body], camera: Self.camera, clipPlanes: [], displayMode: .wireframe,
                edges: edges, edgeIntensity: Self.edgeIntensity),
            width: Self.width, height: Self.height)

        // The renderer's own near/far for this scene, and each rung's screen row and view depth.
        let bounds = try #require(body.boundingBox)
        let clip = Self.camera.clipPlanes(sceneBounds: bounds)
        let viewProjection =
            Self.camera.projectionMatrix(
                aspectRatio: Float(Self.width) / Float(Self.height), near: clip.near, far: clip.far)
            * Self.camera.viewMatrix
        let minAlpha = 0.2 + 0.8 * Self.edgeIntensity

        var measured: [Double] = []
        var predicted: [Double] = []
        for z in Self.rungDepths {
            let centre = SIMD4<Float>(0, 0, z, 1)
            let clipPos = viewProjection * centre
            let row = Int(((1 - clipPos.y / clipPos.w) * 0.5 * Float(Self.height)).rounded())
            try #require(row >= 5 && row < Self.height - 5, "rung at z = \(z) is off screen")
            // Summed blue over a band of rows and a few central columns: independent of how the
            // line's coverage splits between adjacent pixel rows.
            var sum = 0
            for y in max(row - 5, 0)...min(row + 5, Self.height - 1) {
                for x in (Self.width / 2 - 8)...(Self.width / 2 + 8) {
                    sum += Int(pixels[(y * Self.width + x) * 4])  // BGRA: blue
                }
            }
            measured.append(Double(sum))
            let viewDepth = -(Self.camera.viewMatrix * centre).z
            let fade = min(max((viewDepth - clip.near) / (clip.far - clip.near), 0), 1)
            predicted.append(Double(1 - (1 - minAlpha) * fade))
        }

        #expect(measured[0] > 0, "nearest rung not drawn")
        // Brightness relative to the nearest rung tracks the linear fade. The old hyperbolic
        // mapping faded the far rungs much harder than their distance warrants.
        for i in 1..<measured.count {
            let ratio = measured[i] / measured[0]
            let expected = predicted[i] / predicted[0]
            #expect(
                abs(ratio - expected) < 0.03,
                "rung \(i): brightness ratio \(ratio), linear fade predicts \(expected)")
        }
    }
}
