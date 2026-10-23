// OrthographicFollowup217Tests.swift
// OCCTSwiftViewport Tests
//
// Issue #217: the grid near-clipped in a low-elevation orthographic view, manual depth-of-field
// focus measured from the placed eye, eye placement with the base axis radius, and the live
// translucent sort recomputing its keys inside the comparator.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Orthographic follow-ups (#217)")
struct OrthographicFollowup217Tests {

    // MARK: - Helpers

    /// An orthographic camera looking along +Y, `elevation` degrees down onto the XY grid.
    private func lowCamera(elevation: Float = 10, distance: Float = 10) -> CameraState {
        CameraState(
            rotation: simd_quatf(angle: (90 - elevation) * .pi / 180, axis: SIMD3(1, 0, 0)),
            distance: distance, pivot: .zero, orthographicScale: 10, isOrthographic: true)
    }

    /// A small red box at the origin, so the eye sits close and the grid runs past it.
    private var smallBox: ViewportBody {
        .box(id: "b", width: 1, height: 1, depth: 1, color: SIMD4(1, 0, 0, 1))
    }

    /// Lit pixels (any channel above `threshold`) in rows `rows` of a 128-wide BGRA image.
    private func litCount(_ pixels: [UInt8], rows: Range<Int>, threshold: Int = 30) -> Int {
        var n = 0
        for y in rows {
            for x in 0..<128 {
                let c = ParityRender.rgb(pixels, width: 128, x: x, y: y)
                if c.x > threshold || c.y > threshold || c.z > threshold { n += 1 }
            }
        }
        return n
    }

    /// Rows below the box where the grid lies in front of the eye: past ~10 units toward the
    /// camera, row ~87 on. The dot window ends 15 units out, at row ~97.
    private func nearRows(_ style: GridStyle) -> Range<Int> {
        style == .plane ? 100..<128 : 90..<97
    }

    /// Lit pixels the grid leaves in `nearRows`: the lines are about 2 px apart, the dots fewer.
    private func minimumLit(_ style: GridStyle) -> Int { style == .plane ? 500 : 20 }

    private func isRed(_ c: SIMD3<Int>) -> Bool { c.x > 150 && c.y < 60 && c.z < 60 }

    // MARK: - 1. The grid in front of the eye is drawn, not near-clipped

    @Test(
        "A low-elevation orthographic grid reaches the bottom of the view, offscreen",
        arguments: [GridStyle.plane, .dots])
    func lowElevationGridOffscreen(style: GridStyle) throws {
        var options = ParityRender.options()
        options.cameraState = lowCamera()
        options.showGrid = true
        options.gridStyle = style
        let pixels = try ParityRender.render([smallBox], options).pixels
        // The grid toward the camera, below the box: past ~10 units it is in front of the eye,
        // which the near plane cut away at row ~87.
        #expect(litCount(pixels, rows: nearRows(style)) > minimumLit(style), "near grid clipped")
        // The box still covers the grid behind it.
        #expect(isRed(ParityRender.rgb(pixels, width: 128, x: 64, y: 64)))
    }

    @Test(
        "A low-elevation orthographic grid reaches the bottom of the view, live",
        arguments: [GridStyle.plane, .dots])
    func lowElevationGridLive(style: GridStyle) throws {
        let config = ViewportConfiguration(
            initialCameraState: lowCamera(), displayMode: .unlit,
            lightingConfiguration: ParityRender.plainLighting, showGrid: true, gridStyle: style,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        let controller = ViewportController(configuration: config)
        controller.showAxes = false
        let bodies = [smallBox]
        controller.attachSceneBodies { bodies }
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let pixels = renderer.renderHeadlessBGRA(
                width: 128, height: 128, backgroundColor: SIMD4(0, 0, 0, 1))
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(litCount(pixels, rows: nearRows(style)) > minimumLit(style), "near grid clipped")
        #expect(isRed(ParityRender.rgb(pixels, width: 128, x: 64, y: 64)))
    }

    @Test("The grid is depth-clamped in orthographic only")
    func gridClipMode() {
        #expect(RendererSharedSetup.gridDepthClipMode(orthographic: true) == .clamp)
        #expect(RendererSharedSetup.gridDepthClipMode(orthographic: false) == .clip)
    }

    @Test("A pivot slide in a low-elevation orthographic view with the grid never moves the eye")
    func lowElevationPivotSlideKeepsEye() {
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: lowCamera(distance: 2), showGrid: true))
        let bodies = [smallBox]
        controller.attachSceneBodies { bodies }
        let before = controller.cameraState
        controller.cameraController.slidePivotAlongLineOfSight(
            toDepthOf: SIMD3(0, 30, 0), duration: 0)
        let after = controller.cameraState
        #expect(after.pivot != before.pivot, "the pivot should have slid")
        #expect(simd_distance(after.position, before.position) < 1e-3)
        #expect(after.rotation == before.rotation)
    }

    // MARK: - 3. Manual depth-of-field focus in orthographic

    @Test("A manual orthographic focal distance keeps its plane wherever the eye is placed")
    func manualFocusIgnoresEyePlacement() {
        var near = lowCamera(distance: 10)
        near.orthographicScale = 8
        var far = near
        far.distance = 250
        let dNear = ViewportRenderer.manualFocusDistance(12, cameraState: near)
        let dFar = ViewportRenderer.manualFocusDistance(12, cameraState: far)
        // Depths from each eye: the same plane is 240 further from the further eye.
        #expect(abs((dFar - dNear) - 240) < 1e-3, "near \(dNear), far \(dFar)")
        // Measured from the eye a perspective camera showing the same height sits at.
        let reference = PivotStrategy.zoomDistance(of: near)
        #expect(abs(dNear - (near.distance + 12 - reference)) < 1e-4)
        // The matching perspective framing focuses on the same plane.
        let persp = near.matchingFraming(orthographic: false)
        let forward = simd_normalize(near.viewDirection)
        let perspPlane = persp.position + simd_normalize(persp.viewDirection) * 12
        let orthoPlane = near.position + forward * dNear
        #expect(abs(simd_dot(perspPlane - orthoPlane, forward)) < 1e-3)
        // A plane behind the eye focuses just in front of it, never at 0 (autofocus).
        var close = near
        close.distance = 1
        let behind = ViewportRenderer.manualFocusDistance(0.01, cameraState: close)
        #expect(behind > 0 && behind < 0.01 + 1e-6)
    }

    @Test("A manual perspective focal distance is still measured from the eye")
    func manualFocusPerspectiveUnchanged() {
        var persp = lowCamera(distance: 10)
        persp.isOrthographic = false
        #expect(ViewportRenderer.manualFocusDistance(7, cameraState: persp) == 7)
        persp.distance = 300
        #expect(ViewportRenderer.manualFocusDistance(7, cameraState: persp) == 7)
    }

    // MARK: - 4. Eye placement with the axes as thick as they are drawn

    /// `.constantScreenWidth` axes 1 unit long, zoomed out so they are drawn 20 units thick.
    private func zoomedOutAxesConfig() -> ViewportConfiguration {
        var camera = CameraState(
            distance: 2, pivot: .zero,
            orthographicScale: GridAxisGeometry.referenceVisibleHeight * 1000,
            isOrthographic: true)
        camera.rotation = simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3(1, 1, 0)))
        var config = ViewportConfiguration(
            initialCameraState: camera, displayMode: .unlit, showGrid: false)
        config.axisStyle = .constantScreenWidth
        config.axisLength = 1
        config.axisRadius = 0.02
        return config
    }

    /// The box the axes are drawn in for `state`.
    private func drawnAxes(_ state: CameraState, _ config: ViewportConfiguration) -> BoundingBox {
        let r = GridAxisGeometry.axisWorldRadius(
            style: config.axisStyle, baseRadius: config.axisRadius ?? 0, cameraState: state)
        return BoundingBox(min: SIMD3(repeating: -r), max: SIMD3(repeating: 1 + r))
    }

    @Test("The orthographic eye is placed in front of zoomed-out constant-width axes")
    func eyeInFrontOfThickAxes() {
        let config = zoomedOutAxesConfig()
        let controller = ViewportController(configuration: config)
        controller.showAxes = true
        let bodies = [smallBox]
        controller.attachSceneBodies { bodies }
        let state = controller.cameraState
        let axes = drawnAxes(state, config)
        #expect(axes.max.x > 15, "axes drawn \(axes.max.x - 1) thick")
        let nearest = CameraState.nearestDepth(
            of: axes, from: state.position, along: state.viewDirection)
        #expect(nearest > 0, "the axis cylinders reach \(-nearest) past the eye")

        // A zoom out thickens them further; the eye moves back with them.
        controller.cameraController.zoom(factor: 0.25)
        let zoomed = controller.cameraState
        #expect(
            CameraState.nearestDepth(
                of: drawnAxes(zoomed, config), from: zoomed.position, along: zoomed.viewDirection)
                > 0)
    }

    @Test("The orthographic eye bounds take the axes at the radius drawn for the camera")
    func eyeBoundsTakeDrawnRadius() {
        let config = zoomedOutAxesConfig()
        let state = config.initialCameraState
        let settings = GridAxisSettings(configuration: config)
        let bounds = RendererSharedSetup.orthographicEyeBounds(
            modelBounds: nil, bodies: [], settings: settings, showAxes: true, cameraState: state)
        #expect(bounds == drawnAxes(state, config))
        // The radius follows the scale only: the eye's distance and the pivot leave it alone,
        // so a pivot update still never moves the eye.
        var moved = state
        moved.distance = 500
        moved.pivot = SIMD3(3, -2, 7)
        #expect(
            RendererSharedSetup.orthographicEyeBounds(
                modelBounds: nil, bodies: [], settings: settings, showAxes: true,
                cameraState: moved) == bounds)
    }

    @Test("A pivot slide with zoomed-out constant-width axes never moves the eye")
    func thickAxesPivotSlideKeepsEye() {
        let controller = ViewportController(configuration: zoomedOutAxesConfig())
        controller.showAxes = true
        let bodies = [smallBox]
        controller.attachSceneBodies { bodies }
        let before = controller.cameraState
        controller.cameraController.slidePivotAlongLineOfSight(
            toDepthOf: SIMD3(0.2, 0.1, 0.4), duration: 0)
        let after = controller.cameraState
        #expect(after.pivot != before.pivot, "the pivot should have slid")
        #expect(simd_distance(after.position, before.position) < 1e-2)
        #expect(after.rotation == before.rotation)
    }

    @Test("The live frame's near plane is in front of zoomed-out constant-width axes")
    func liveNearPlaneInFrontOfThickAxes() {
        let config = zoomedOutAxesConfig()
        let controller = ViewportController(configuration: config)
        controller.showAxes = true
        let bodies = [smallBox]
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            renderer.renderHeadlessBGRA(
                width: 64, height: 64, backgroundColor: SIMD4(0, 0, 0, 1)) != nil,
            let clip = renderer.lastFrameClipPlanes
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // No scene provider: the frame places the eye itself. The planes are depths from the
        // controller's eye, as the axes' nearest corner is here.
        let state = controller.cameraState
        let nearest = CameraState.nearestDepth(
            of: drawnAxes(state, config), from: state.position, along: state.viewDirection)
        #expect(clip.near <= nearest, "near \(clip.near), axes from \(nearest)")
        // And the frame's eye was in front of them: the near plane is not at its floor.
        #expect(clip.far - clip.near < (clip.far - nearest) * 1.5)
    }

    // MARK: - 5. Translucent sort keys

    @Test("The translucent sort computes each key once and orders back to front")
    func sortComputesKeysOnce() {
        let camera = CameraState(distance: 10, pivot: .zero, isOrthographic: true)
        let centers: [SIMD3<Float>] = (0..<40).map {
            SIMD3(Float($0 % 7), 0, Float($0 % 11) - 5)
        }
        var calls = 0
        let sorted = RendererSharedSetup.sortedBackToFront(
            Array(centers.indices), cameraState: camera
        ) { i -> SIMD3<Float> in
            calls += 1
            return centers[i]
        }
        #expect(calls == centers.count)
        let depths = sorted.map {
            RendererSharedSetup.transparentSortDepth(center: centers[$0], cameraState: camera)
        }
        #expect(zip(depths, depths.dropFirst()).allSatisfy { $0 >= $1 })
    }
}
