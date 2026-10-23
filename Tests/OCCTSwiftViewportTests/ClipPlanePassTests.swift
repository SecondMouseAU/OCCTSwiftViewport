// ClipPlanePassTests.swift
// OCCTSwiftViewport Tests
//
// Section clip planes must hide geometry in every pass, not just the shaded and wireframe ones
// (issue #136, H3). Before the fix the pick, depth-prepass (SSAO/silhouette), selection-outline
// and point-cloud fragments ignored `Uniforms.clipPlanes`, so a click on a sectioned model picked
// the invisible clipped-away body, silhouettes outlined it, the selection outline painted it, and
// point clouds ignored the section entirely.
//
// Every test drives `ViewportRenderer`'s real frame encoder through its headless entry point.

import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

/// Scene builders shared by the clip-plane pass tests.
@MainActor
private enum ClipScene {

    static let width = 160
    static let height = 120

    /// Removes everything with z > 0.2: the whole front body, none of the back one.
    static let section = ClipPlane(normal: SIMD3<Float>(0, 0, -1), distance: 0.2)

    static func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    /// A wide slab behind the section plane that fills the middle of the frame.
    static func backBody() -> ViewportBody {
        var back = ViewportBody.box(
            id: "back", width: 4, height: 3, depth: 0.4,
            color: SIMD4<Float>(0.85, 0.25, 0.2, 1))
        back.transform = translation(0, 0, -1)
        return back
    }

    /// A smaller box entirely in front of the section plane, pickable as a face, edge, arc and
    /// vertex, so a single region pick exercises every pick fragment.
    static func frontBody() -> ViewportBody {
        let size: Float = 1.6
        let depth: Float = 0.4
        var front = ViewportBody.box(
            id: "front", width: size, height: size, depth: depth,
            color: SIMD4<Float>(0.2, 0.5, 0.9, 1))
        front.edgeIndices = (0..<Int32(front.edges.count)).map { $0 }
        let h = size / 2
        let d = depth / 2
        front.vertices = [
            SIMD3(-h, -h, -d), SIMD3(h, -h, -d), SIMD3(h, h, -d), SIMD3(-h, h, -d),
            SIMD3(-h, -h, d), SIMD3(h, -h, d), SIMD3(h, h, d), SIMD3(-h, h, d),
        ]
        front.arcs = [
            ViewportArc(
                center: SIMD3(0, 0, d), radius: 0.5,
                xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        ]
        front.transform = translation(0, 0, 1)
        return front
    }

    /// A yellow point cloud entirely in front of the section plane.
    static func frontCloud() -> ViewportBody {
        var points: [SIMD3<Float>] = []
        for i in 0..<9 {
            for j in 0..<9 {
                points.append(
                    SIMD3<Float>(Float(i) * 0.25 - 1, Float(j) * 0.25 - 1, 1))
            }
        }
        return ViewportBody(
            id: "cloud", vertexData: [], indices: [], edges: [],
            vertices: points, color: SIMD4<Float>(1, 1, 0.1, 1),
            pointRadius: 0.08, primitiveKind: .point)
    }

    /// Builds a controller/renderer pair.
    ///
    /// The controller is returned because the renderer only holds it weakly.
    static func makeRenderer(
        bodies: [ViewportBody],
        clipped: Bool,
        quality: RenderingQuality = .standard,
        silhouettes: Bool = false,
        ssao: Bool = false,
        picking: Bool = false,
        selected: Set<String> = []
    ) -> (controller: ViewportController, renderer: ViewportRenderer)? {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = ssao
        let configuration = ViewportConfiguration(
            initialCameraState: CameraState(),
            displayMode: .shaded,
            lightingConfiguration: lighting,
            showAxes: false,
            showGrid: false,
            enableSilhouettes: silhouettes,
            pickingConfiguration: PickingConfiguration(isEnabled: picking),
            renderingQuality: quality
        )
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = .shaded
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.selectedBodyIDs = selected
        controller.clipPlanes = clipped ? [section] : []
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else { return nil }
        return (controller, renderer)
    }

    static func render(
        bodies: [ViewportBody], clipped: Bool = true, silhouettes: Bool = false,
        ssao: Bool = false, selected: Set<String> = []
    ) -> [UInt8]? {
        guard
            let pair = makeRenderer(
                bodies: bodies, clipped: clipped, silhouettes: silhouettes, ssao: ssao,
                selected: selected)
        else { return nil }
        return pair.renderer.renderHeadlessBGRA(
            width: width, height: height,
            backgroundColor: pair.controller.configuration.backgroundColor)
    }

    /// Number of pixels whose largest channel difference exceeds `tolerance`.
    static func differingPixels(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 1) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) / 4 }
        var count = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            var maxDelta = 0
            for c in 0..<3 { maxDelta = max(maxDelta, abs(Int(a[p + c]) - Int(b[p + c]))) }
            if maxDelta > tolerance { count += 1 }
        }
        return count
    }
}

@MainActor
@Suite("Section clip planes apply to every pass")
struct ClipPlanePassTests {

    /// Region-picks the whole headless frame and returns the body IDs hit.
    private func pickedBodies(clipped: Bool, quality: RenderingQuality) async -> Set<String>? {
        guard
            let pair = ClipScene.makeRenderer(
                bodies: [ClipScene.backBody(), ClipScene.frontBody()],
                clipped: clipped, quality: quality, picking: true)
        else { return nil }
        guard
            pair.renderer.renderHeadlessBGRA(
                width: ClipScene.width, height: ClipScene.height,
                backgroundColor: pair.controller.configuration.backgroundColor) != nil
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: ClipScene.width, height: ClipScene.height)
        let results: [PickResult] = await withCheckedContinuation { continuation in
            pair.renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
        return Set(results.map(\.bodyID))
    }

    @Test(
        "A sectioned model never picks the clipped-away body",
        arguments: [RenderingQuality.standard, .enhanced, .maximum])
    func pickSkipsClippedBody(quality: RenderingQuality) async throws {
        // Control: without the section the front body (faces, edges, arc, vertices) is pickable,
        // so its absence below is the clip test, not a scene that never drew it.
        guard let unclipped = await pickedBodies(clipped: false, quality: quality) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(unclipped.contains("front"), "control: front body should be pickable unclipped")

        let clipped = try #require(await pickedBodies(clipped: true, quality: quality))
        #expect(!clipped.contains("front"), "clipped-away body was picked (\(quality))")
        #expect(clipped.contains("back"), "the visible body behind the section must be pickable")
    }

    @Test("A fully clipped point cloud draws nothing")
    func clippedPointCloudDrawsNothing() throws {
        guard let baseline = ClipScene.render(bodies: [ClipScene.backBody()]) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let withCloud = try #require(
            ClipScene.render(bodies: [ClipScene.backBody(), ClipScene.frontCloud()]))
        let unclipped = try #require(
            ClipScene.render(
                bodies: [ClipScene.backBody(), ClipScene.frontCloud()], clipped: false))

        #expect(
            ClipScene.differingPixels(baseline, unclipped) > 50,
            "control: the unclipped cloud should be visible")
        #expect(
            ClipScene.differingPixels(baseline, withCloud) == 0,
            "a point cloud on the clipped side of a section still rendered")
    }

    @Test("The selection outline is not drawn for a clipped-away body")
    func selectionOutlineRespectsSection() throws {
        let bodies = [ClipScene.backBody(), ClipScene.frontBody()]
        guard let unselected = ClipScene.render(bodies: bodies) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let selected = try #require(ClipScene.render(bodies: bodies, selected: ["front"]))
        #expect(
            ClipScene.differingPixels(unselected, selected) == 0,
            "selecting a fully clipped body still painted its outline")

        // Control: selecting the visible body does draw an outline.
        let backSelected = try #require(ClipScene.render(bodies: bodies, selected: ["back"]))
        #expect(ClipScene.differingPixels(unselected, backSelected) > 0)
    }

    @Test(
        "The SSAO/silhouette depth prepass ignores clipped-away geometry",
        arguments: [(silhouettes: true, ssao: false), (silhouettes: false, ssao: true)])
    func depthPrepassRespectsSection(silhouettes: Bool, ssao: Bool) throws {
        // A prepass that still drew the clipped front body would outline it (silhouettes) or
        // shade around it (SSAO + depth unsharp-mask). Both effects are subtle, so compare at a
        // 1-level tolerance: measured before the fix, SSAO alone moved ~460 pixels by 2-4 levels
        // and silhouettes ~580 pixels; after it, both frames match the back-body-only baseline.
        guard
            let baseline = ClipScene.render(
                bodies: [ClipScene.backBody()], silhouettes: silhouettes, ssao: ssao)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let withFront = try #require(
            ClipScene.render(
                bodies: [ClipScene.backBody(), ClipScene.frontBody()],
                silhouettes: silhouettes, ssao: ssao))
        #expect(
            ClipScene.differingPixels(baseline, withFront) == 0,
            "the prepass outlined/occluded geometry the section removed")
    }
}
