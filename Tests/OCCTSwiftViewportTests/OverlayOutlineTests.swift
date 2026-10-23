// OverlayOutlineTests.swift
// OCCTSwiftViewport Tests
//
// The selection / hover outline is drawn for `.geometry` bodies only (issue #136, L4). An
// `.overlay` body is drawn after the outline with always-pass depth and never writes the
// stencil mask, so an outline for it was the whole expanded silhouette, depth-tested against
// geometry the overlay itself ignores.

import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Overlay selection outline")
struct OverlayOutlineTests {

    @MainActor
    private static func render(
        _ body: ViewportBody, selected: Set<String> = [], hovered: String? = nil
    ) -> [UInt8]? {
        var camera = CameraState()
        camera.pivot = .zero
        camera.distance = 5
        var config = ViewportConfiguration()
        config.initialCameraState = camera
        let controller = ViewportController(configuration: config)
        controller.showGrid = false
        controller.showAxes = false
        controller.selectedBodyIDs = selected
        controller.hoveredBodyID = hovered
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
    }

    private static func box(layer: RenderLayer) -> ViewportBody {
        var body = ViewportBody.box(
            id: "b", width: 1, height: 1, depth: 1, color: SIMD4<Float>(0.8, 0.8, 0.8, 1))
        body.renderLayer = layer
        return body
    }

    @Test("A selected geometry body gets an outline (the probe can see outlines)")
    @MainActor
    func geometryBodyIsOutlined() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let body = Self.box(layer: .geometry)
        guard let plain = Self.render(body), let selected = Self.render(body, selected: ["b"])
        else {
            Issue.record("headless render failed")
            return
        }
        #expect(plain != selected)
    }

    @Test("A selected or hovered overlay body draws no outline")
    @MainActor
    func overlayBodyIsNotOutlined() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let body = Self.box(layer: .overlay)
        guard let plain = Self.render(body),
            let selected = Self.render(body, selected: ["b"]),
            let hovered = Self.render(body, hovered: "b")
        else {
            Issue.record("headless render failed")
            return
        }
        #expect(plain == selected)
        #expect(plain == hovered)
    }
}
