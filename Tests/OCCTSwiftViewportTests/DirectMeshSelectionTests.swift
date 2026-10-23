// DirectMeshSelectionTests.swift
// OCCTSwiftViewport Tests
//
// The selection outline and per-triangle highlight passes must read direct-mesh bodies through
// the two-buffer descriptor (position@0 / normal@2), like every other per-body pass (issue #136,
// H5). Before the fix they bound the stride-12 position buffer to the interleaved stride-24
// pipelines, so selecting, hovering or styling a `ViewportBody.directMesh(...)` body drew garbage.
//
// Differential check through `ViewportRenderer.renderHeadlessBGRA`: the same sphere built
// interleaved and direct-mesh, rendered unselected and then selected / styled. The pixels the
// selection (or style) changes must match between the two builds.

import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Direct-mesh selection outline and triangle highlight")
struct DirectMeshSelectionTests {

    private static let color = SIMD4<Float>(0.4, 0.7, 0.95, 1)

    private static func interleavedSphere() -> ViewportBody {
        ViewportBody.sphere(id: "sphere", radius: 0.8, color: color)
    }

    /// The interleaved sphere's exact data, de-interleaved into a direct-mesh body.
    private static func directSphere() -> ViewportBody {
        let interleaved = interleavedSphere()
        var positions: [Float] = []
        var normals: [Float] = []
        let vd = interleaved.vertexData
        var i = 0
        while i + 5 < vd.count {
            positions.append(contentsOf: [vd[i], vd[i + 1], vd[i + 2]])
            normals.append(contentsOf: [vd[i + 3], vd[i + 4], vd[i + 5]])
            i += 6
        }
        return ViewportBody.directMesh(
            id: "sphere", positions: positions, normals: normals,
            indices: interleaved.indices, color: color)
    }

    /// Styles every other triangle opaque red.
    private static func styled(_ body: ViewportBody) -> ViewportBody {
        var out = body
        let triangleCount = body.indices.count / 3
        out.triangleStyles = (0..<triangleCount).map { t in
            t % 2 == 0 ? TriangleStyle(color: SIMD4<Float>(1, 0, 0, 1)) : TriangleStyle()
        }
        return out
    }

    private static func render(
        _ body: ViewportBody, selected: Bool, hovered: Bool = false
    ) -> [UInt8]? {
        let camera = ViewportRenderBattery.fittedCamera(for: [interleavedSphere()])
        let configuration = ViewportConfiguration(
            initialCameraState: camera,
            displayMode: .shaded,
            lightingConfiguration: ViewportRenderBattery.lighting(ssao: false),
            showAxes: false,
            showGrid: false,
            enableSilhouettes: false,
            pickingConfiguration: PickingConfiguration(isEnabled: false),
            enableTAA: false
        )
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = .shaded
        controller.lightingConfiguration = ViewportRenderBattery.lighting(ssao: false)
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        controller.selectedBodyIDs = selected ? [body.id] : []
        if hovered { controller.hoveredBodyID = body.id }
        guard
            let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: ViewportRenderBattery.width,
            height: ViewportRenderBattery.height,
            backgroundColor: configuration.backgroundColor,
            frameCount: 1)
    }

    /// Indices of pixels whose largest channel delta exceeds `threshold`.
    private static func changedPixels(_ a: [UInt8], _ b: [UInt8], threshold: Int = 24) -> Set<Int> {
        var out = Set<Int>()
        for p in stride(from: 0, to: min(a.count, b.count), by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(a[p + c]) - Int(b[p + c]))) }
            if d > threshold { out.insert(p / 4) }
        }
        return out
    }

    /// Asserts the direct build's changed-pixel mask matches the interleaved build's.
    private static func expectMasksMatch(
        interleaved: Set<Int>, direct: Set<Int>, what: String
    ) {
        #expect(interleaved.count > 50, "\(what): interleaved reference changed too few pixels")
        let symmetricDifference = interleaved.symmetricDifference(direct).count
        // Allow a sliver of disagreement for MSAA edge coverage; garbage vertex reads disagree on
        // hundreds to thousands of pixels.
        let tolerance = max(4, interleaved.count / 50)
        #expect(
            symmetricDifference <= tolerance,
            """
            \(what): direct-mesh mask differs from interleaved by \(symmetricDifference) pixels \
            (interleaved \(interleaved.count), direct \(direct.count), tolerance \(tolerance))
            """)
    }

    @Test("Selecting a direct-mesh body draws the same outline as the interleaved body")
    func selectionOutlineMatches() throws {
        guard let iBase = Self.render(Self.interleavedSphere(), selected: false),
            let iSel = Self.render(Self.interleavedSphere(), selected: true),
            let dBase = Self.render(Self.directSphere(), selected: false),
            let dSel = Self.render(Self.directSphere(), selected: true)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        Self.expectMasksMatch(
            interleaved: Self.changedPixels(iBase, iSel),
            direct: Self.changedPixels(dBase, dSel),
            what: "selection outline")
    }

    @Test("Hovering a direct-mesh body draws the same outline as the interleaved body")
    func hoverOutlineMatches() throws {
        guard let iBase = Self.render(Self.interleavedSphere(), selected: false),
            let iHover = Self.render(Self.interleavedSphere(), selected: false, hovered: true),
            let dBase = Self.render(Self.directSphere(), selected: false),
            let dHover = Self.render(Self.directSphere(), selected: false, hovered: true)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        Self.expectMasksMatch(
            interleaved: Self.changedPixels(iBase, iHover),
            direct: Self.changedPixels(dBase, dHover),
            what: "hover outline")
    }

    @Test("Per-triangle styles on a direct-mesh body match the interleaved body")
    func triangleHighlightMatches() throws {
        guard let iBase = Self.render(Self.interleavedSphere(), selected: false),
            let iStyled = Self.render(Self.styled(Self.interleavedSphere()), selected: false),
            let dBase = Self.render(Self.directSphere(), selected: false),
            let dStyled = Self.render(Self.styled(Self.directSphere()), selected: false)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        Self.expectMasksMatch(
            interleaved: Self.changedPixels(iBase, iStyled),
            direct: Self.changedPixels(dBase, dStyled),
            what: "triangle highlight")
    }
}
