// OrthographicRendererTests.swift
// OCCTSwiftViewport Tests
//
// Issue #215: in orthographic, translucent bodies sorted by distance from the eye, depth-of-field
// autofocus measured from the eye, the eye was placed in front of the geometry-layer bodies only
// (so an overlay or the axes nearer the camera were near-clipped), the offscreen renderer drew the
// camera it was given as it was, eye inside the scene or not, and lit shading took its view
// vector from the eye, so it changed wherever the eye was placed.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Orthographic renderer follow-ups (#215)")
struct OrthographicRendererTests {

    // MARK: - Helpers

    /// A front orthographic camera on +Z, `distance` from the origin, looking down -Z.
    private func front(distance: Float, orthographic: Bool = true) -> CameraState {
        CameraState(
            distance: distance, pivot: .zero, orthographicScale: 10,
            isOrthographic: orthographic)
    }

    private let red = SIMD4<Float>(1, 0, 0, 1)
    private let blue = SIMD4<Float>(0, 0, 1, 1)
    private let green = SIMD4<Float>(0, 1, 0, 1)

    /// A red quad at z = 1.5 in front of a blue one at z = -1.5, both 2 x 2 about the axis.
    private var stackedQuads: [ViewportBody] {
        [
            ParityRender.quad(id: "front", x0: -1, y0: -1, x1: 1, y1: 1, z: 1.5, color: red),
            ParityRender.quad(id: "back", x0: -1, y0: -1, x1: 1, y1: 1, z: -1.5, color: blue),
        ]
    }

    /// A small green overlay-layer quad at z = 6, in front of `stackedQuads`.
    private var overlayInFront: ViewportBody {
        var body = ParityRender.quad(
            id: "gizmo", x0: -0.5, y0: -0.5, x1: 0.5, y1: 0.5, z: 6, color: green)
        body.renderLayer = .overlay
        return body
    }

    private func offscreen(
        _ bodies: [ViewportBody], camera: CameraState, explicitOrtho: Bool = false
    ) throws -> [UInt8] {
        var options = ParityRender.options()
        options.cameraState = camera
        if explicitOrtho {
            options.explicitOrthoBounds = OrthoBounds(left: -5, right: 5, bottom: -5, top: 5)
        }
        return try ParityRender.render(bodies, options).pixels
    }

    private func center(_ pixels: [UInt8]) -> SIMD3<Int> {
        ParityRender.rgb(pixels, width: 128, x: 64, y: 64)
    }

    private func isMostly(_ c: SIMD3<Int>, channel: Int) -> Bool {
        (0..<3).allSatisfy { $0 == channel ? c[$0] > 150 : c[$0] < 60 }
    }

    // MARK: - 1. Transparent sort

    @Test("Orthographic translucent bodies sort by depth along the line of sight")
    func transparentSortUsesViewDepth() {
        let camera = front(distance: 10)
        // Shallow but far off-axis, against deeper on the axis: from the eye at z = 10 the first
        // is further away (11.4 against 11), yet it is in front.
        let offAxisFront = SIMD3<Float>(7, 0, 1)
        let onAxisBack = SIMD3<Float>(0, 0, -1)
        #expect(
            RendererSharedSetup.transparentSortDepth(center: onAxisBack, cameraState: camera)
                > RendererSharedSetup.transparentSortDepth(
                    center: offAxisFront, cameraState: camera))
        // Perspective keeps the distance from the eye.
        let persp = front(distance: 10, orthographic: false)
        #expect(
            abs(
                RendererSharedSetup.transparentSortDepth(center: offAxisFront, cameraState: persp)
                    - simd_distance(offAxisFront, persp.position)) < 1e-4)
    }

    /// Red over blue, both half transparent, the red one nearer but its centre far off-axis.
    private var translucentPair: [ViewportBody] {
        [
            ParityRender.quad(
                id: "near", x0: -1, y0: -1, x1: 15, y1: 1, z: 1, color: SIMD4(1, 0, 0, 0.5)),
            ParityRender.quad(
                id: "far", x0: -1, y0: -1, x1: 1, y1: 1, z: -1, color: SIMD4(0, 0, 1, 0.5)),
        ]
    }

    @Test("An off-axis translucent body in front composites over a deeper one, offscreen")
    func transparentOrderOffscreen() throws {
        let pixel = center(try offscreen(translucentPair, camera: front(distance: 10)))
        // Back to front: blue first, then red over it, so red dominates.
        #expect(pixel.x > pixel.z, "red must be composited last: \(pixel)")
    }

    @Test("An off-axis translucent body in front composites over a deeper one, live")
    func transparentOrderLive() throws {
        guard let live = liveRender(translucentPair, camera: front(distance: 10)) else {
            Issue.record("Metal device unavailable")
            return
        }
        let pixel = center(live)
        #expect(pixel.x > pixel.z, "red must be composited last: \(pixel)")
    }

    // MARK: - 2. Depth-of-field autofocus

    @Test("Autofocus is the view depth of the scene centre, not its distance from the eye")
    func autofocusUsesViewDepth() {
        var body = ViewportBody.box(id: "b", width: 1, height: 1, depth: 1)
        body.transform.columns.3 = SIMD4(5, 0, -2, 1)
        // Pivot plane at depth 10, the centre 2 past it and 5 off-axis.
        for orthographic in [true, false] {
            let camera = front(distance: 10, orthographic: orthographic)
            let d = ViewportRenderer.autoFocusDistance(bodies: [body], cameraState: camera)
            #expect(abs(d - 12) < 1e-4, "orthographic \(orthographic): focused at \(d)")
        }
        // An orthographic eye placed further back keeps the focus on the same plane of the
        // scene: the depth buffer is measured from that eye too.
        let near = front(distance: 10)
        var far = near
        far.distance = 40
        let dNear = ViewportRenderer.autoFocusDistance(bodies: [body], cameraState: near)
        let dFar = ViewportRenderer.autoFocusDistance(bodies: [body], cameraState: far)
        #expect(abs((dFar - dNear) - 30) < 1e-4)
        // A centre behind the eye's plane focuses just in front of the eye, never at 0 (which
        // would mean "autofocus") or a negative depth.
        var behind = body
        behind.transform.columns.3 = SIMD4(0, 0, 50, 1)
        let dBehind = ViewportRenderer.autoFocusDistance(
            bodies: [behind], cameraState: front(distance: 10, orthographic: false))
        #expect(dBehind > 0 && dBehind < 0.01, "focused at \(dBehind)")
    }

    // MARK: - 3. Overlays and axes in the eye placement

    @Test("The live orthographic eye is placed in front of overlay bodies too")
    func controllerPlacesEyeInFrontOfOverlays() {
        let bodies = stackedQuads + [overlayInFront]
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: front(distance: 3), showGrid: false))
        controller.showAxes = false
        controller.attachSceneBodies { bodies }
        let state = controller.cameraState
        #expect(state.position.z > 6, "eye at z = \(state.position.z), behind the overlay")
        // The picture is unchanged: only the eye moved, along the line of sight.
        #expect(state.pivot == .zero && state.orthographicScale == 10)
    }

    @Test("The orthographic eye bounds hold the axes and overlays, capped near the model")
    func eyeBoundsHoldAxesAndOverlays() {
        let model = BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))
        var config = ViewportConfiguration()
        config.axisLength = 8
        let settings = GridAxisSettings(configuration: config, sceneBounds: model)
        let bounds = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: model, bodies: [overlayInFront], settings: settings, showAxes: true)
        #expect((bounds?.max.z ?? 0) >= 8, "axes: \(String(describing: bounds))")
        #expect(bounds?.min == model.min, "only the axes and the overlay widen the model")
        // The overlay alone, axes hidden: it reaches z = 6, past the model.
        let overlayOnly = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: model, bodies: [overlayInFront], settings: settings, showAxes: false)
        #expect(overlayOnly?.max.z == 6, "overlay: \(String(describing: overlayOnly))")
        let none = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: model, bodies: [], settings: settings, showAxes: false)
        #expect(none == model)
        // A huge widget counts only four model diagonals past the model, so it can't push the
        // eye, and with it the far plane and the edge depth fade, far back.
        let axis = ViewportBody(
            id: "axis", vertexData: [], indices: [],
            edges: [[SIMD3(0, 0, -1e5), SIMD3(0, 0, 1e5)]], color: SIMD4(1, 0, 0, 1),
            renderLayer: .overlay)
        let huge = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: model, bodies: [axis], settings: settings, showAxes: false)
        #expect((huge?.max.z ?? .infinity) <= 1 + model.diagonalLength * 4 + 1e-3)
    }

    @Test("The clip fit and the eye placement cap an overlay alike, whatever the grid window")
    func overlayCapMatchesClipFit() {
        let model = BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))
        let settings = GridAxisSettings(configuration: ViewportConfiguration(), sceneBounds: model)
        // A long widget toward the camera, past four model diagonals; a zoomed-out grid window.
        var widget = overlayInFront
        widget.transform.columns.3 = SIMD4(0, 0, 40, 1)
        let withGrid = model.union(BoundingBox(min: SIMD3(-60, -60, 0), max: SIMD3(60, 60, 0)))
        let basis = RendererSharedSetup.overlayCapBasis(
            modelBounds: model, settings: settings, showAxes: false)
        let fit = RendererSharedSetup.clipFitBounds(
            withGrid, includingOverlaysOf: [widget], in: nil, capBasis: basis)
        let eye = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: model, bodies: [widget], settings: settings, showAxes: false)
        // The eye is placed in front of everything the clip fit takes in.
        #expect((eye?.max.z ?? 0) >= (fit?.max.z ?? .infinity))
    }

    @Test("The live clip fit caps overlays as the eye placement does, with a zoomed-out grid")
    func liveRendererPassesOverlayCap() {
        // A unit box, a zoomed-out view whose grid window is hundreds of units wide, and a long
        // widget reaching toward the camera far past the model. Capped around the grid window
        // (as the clip fit did), the widget's whole length was fitted though the eye sits in
        // front of only the capped part, so the near plane collapsed to its floor.
        let model = ViewportBody.box(id: "b", width: 1, height: 1, depth: 1)
        let widget = ViewportBody(
            id: "w", vertexData: [], indices: [],
            edges: [[SIMD3(0, 0, 0), SIMD3(0, 0, 100)]], color: SIMD4(0, 1, 0, 1),
            renderLayer: .overlay)
        let bodies = [model, widget]
        var camera = front(distance: 10)
        // Straight down onto the grid, so no part of the grid itself reaches past the eye.
        camera.orthographicScale = 400
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: camera, displayMode: .unlit, showGrid: true))
        controller.showAxes = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            renderer.renderHeadlessBGRA(
                width: 64, height: 64, backgroundColor: SIMD4(0, 0, 0, 1)) != nil,
            let clip = renderer.lastFrameClipPlanes
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // The planes as depths from the frame's own (placed) eye.
        let placed = controller.cameraState.placingOrthographicEye(
            inFrontOf: controller.orthographicEyeBounds(of: bodies))
        let shift = placed.distance - controller.cameraState.distance
        let near = clip.near + shift
        let far = clip.far + shift
        #expect(near > far * 1e-3, "near \(near) collapsed against far \(far)")
    }

    @Test("The bounds MetalViewportView watches follow overlays and the axes")
    func watchedBoundsFollowOverlaysAndAxes() {
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: front(distance: 10), showGrid: false))
        controller.showAxes = false
        let base = controller.orthographicSceneBounds(of: stackedQuads)
        #expect(controller.orthographicSceneBounds(of: stackedQuads + [overlayInFront]) != base)
        var moved = overlayInFront
        moved.transform.columns.3 = SIMD4(0, 0, 2, 1)
        #expect(
            controller.orthographicSceneBounds(of: stackedQuads + [moved])
                != controller.orthographicSceneBounds(of: stackedQuads + [overlayInFront]))
        controller.showAxes = true
        #expect(controller.orthographicSceneBounds(of: stackedQuads) != base)
    }

    @Test("A pivot slide still never moves the eye with overlays and axes in the placement")
    func pivotSlideKeepsEye() {
        let bodies = stackedQuads + [overlayInFront]
        var tilted = front(distance: 3)
        tilted.rotation = simd_quatf(angle: 1.2, axis: SIMD3(1, 0, 0))
        let controller = ViewportController(
            configuration: ViewportConfiguration(initialCameraState: tilted, showGrid: true))
        controller.attachSceneBodies { bodies }
        let before = controller.cameraState
        controller.cameraController.slidePivotAlongLineOfSight(
            toDepthOf: SIMD3(0, 0, 1.5), duration: 0)
        let after = controller.cameraState
        #expect(after.pivot != before.pivot, "the pivot should have slid")
        #expect(simd_distance(after.position, before.position) < 1e-3)
        #expect(after.rotation == before.rotation)
    }

    @Test("Live and offscreen both draw an overlay in front of the model in orthographic")
    func overlayInFrontDrawnLiveAndOffscreen() throws {
        let bodies = stackedQuads + [overlayInFront]
        let camera = front(distance: 3)
        let off = center(try offscreen(bodies, camera: camera))
        #expect(isMostly(off, channel: 1), "offscreen centre \(off): overlay clipped")
        guard let live = liveRender(bodies, camera: camera, attachScene: true) else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(isMostly(center(live), channel: 1), "live centre \(center(live)): overlay clipped")
        // A controller without a scene provider: the live frame places the eye itself.
        guard let unattached = liveRender(bodies, camera: camera) else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(isMostly(center(unattached), channel: 1), "unattached centre \(center(unattached))")
    }

    @Test("The live clip planes the measurement overlay reads are relative to the controller's eye")
    func liveClipPlanesFollowControllerEye() throws {
        let bodies = stackedQuads + [overlayInFront]
        let config = ViewportConfiguration(
            initialCameraState: front(distance: 0.5), displayMode: .unlit, showGrid: false)
        let controller = ViewportController(configuration: config)
        controller.showAxes = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            renderer.renderHeadlessBGRA(
                width: 64, height: 64, backgroundColor: SIMD4(0, 0, 0, 1)) != nil
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // The controller's eye is still at z = 0.5; the frame drew from further back.
        #expect(controller.cameraState.distance == 0.5)
        let vp = MeasurementOverlay.viewProjection(
            cameraState: controller.cameraState, aspectRatio: 1,
            clipPlanes: renderer.lastFrameClipPlanes)
        for z: Float in [6, 1.5, -1.5] {
            let ndc = ProjectionUtility.worldToNDC(point: SIMD3(0, 0, z), vpMatrix: vp)
            #expect(
                ndc.map { $0.z >= 0 && $0.z <= 1 } == true, "z = \(z): \(String(describing: ndc))")
        }
    }

    // MARK: - 4. Offscreen eye placement

    @Test("An offscreen orthographic camera with its eye inside the scene draws all of it")
    func offscreenPlacesEye() throws {
        // The eye at z = 0.5 is between the quads: the red one in front was cut away.
        let inside = center(try offscreen(stackedQuads, camera: front(distance: 0.5)))
        #expect(isMostly(inside, channel: 0), "centre \(inside): the front quad was clipped")
        let outside = center(try offscreen(stackedQuads, camera: front(distance: 50)))
        #expect(inside == outside)
    }

    @Test("Orthographic lit shading does not depend on where the eye is placed")
    func orthographicShadingIgnoresEye() throws {
        // A shaded sphere, near and far eyes: the specular and rim lighting used to bend toward
        // the eye like a perspective view's, so the two differed.
        let sphere = ViewportBody.sphere(id: "s", radius: 2, color: SIMD4(0.7, 0.7, 0.7, 1))
        func shaded(_ distance: Float) throws -> [UInt8] {
            var options = ParityRender.options(displayMode: .shaded)
            options.cameraState = front(distance: distance)
            options.cameraState.rotation = simd_quatf(
                angle: 0.6, axis: simd_normalize(SIMD3(1, 1, 0)))
            return try ParityRender.render([sphere], options).pixels
        }
        func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).filter { p in
                ((0..<3).map { abs(Int(a[p + $0]) - Int(b[p + $0])) }.max() ?? 0) > 3
            }.count
        }
        let near = try shaded(4)
        let far = try shaded(400)
        #expect(differing(near, far) == 0, "offscreen: the near and far eye differ")
        // Live, through the same uniform.
        func live(_ distance: Float) -> [UInt8]? {
            var camera = front(distance: distance)
            camera.rotation = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3(1, 1, 0)))
            return liveRender([sphere], camera: camera, displayMode: .shaded)
        }
        guard let liveNear = live(4), let liveFar = live(400) else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(differing(liveNear, liveFar) == 0, "live: the near and far eye differ")
    }

    @Test("explicitOrthoBounds places the eye of a perspective camera too")
    func offscreenExplicitOrthoPlacesEye() throws {
        let pixel = center(
            try offscreen(
                stackedQuads, camera: front(distance: 0.5, orthographic: false),
                explicitOrtho: true))
        #expect(isMostly(pixel, channel: 0), "centre \(pixel): the front quad was clipped")
    }

    // MARK: - Live rig

    /// Renders `bodies` through the live renderer, headless, as `MetalViewportView` sets it up.
    private func liveRender(
        _ bodies: [ViewportBody], camera: CameraState, attachScene: Bool = false,
        displayMode: DisplayMode = .unlit
    ) -> [UInt8]? {
        let config = ViewportConfiguration(
            initialCameraState: camera, displayMode: displayMode,
            lightingConfiguration: ParityRender.plainLighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        let controller = ViewportController(configuration: config)
        controller.showAxes = false
        if attachScene { controller.attachSceneBodies { bodies } }
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: 128, height: 128, backgroundColor: SIMD4(0, 0, 0, 1))
    }
}
