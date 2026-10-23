// CameraProjectionFollowupTests.swift
// OCCTSwiftViewport Tests
//
// Issue #208: orthographic behind-camera culling in worldToScreen, fit(to: bodies) ignoring
// transforms and layers, the orthographic dynamic-pivot zoom decision, and the pivot update
// raycasting a stale snapshot of the bodies. Also the projection switch keeping the view's size.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Camera and projection follow-ups (#208)")
struct CameraProjectionFollowupTests {

    // MARK: - Helpers

    /// A camera at (0, 0, distance) looking down -Z at the origin.
    private func camera(
        orthographic: Bool, distance: Float = 10, scale: Float = 10
    ) -> CameraState {
        CameraState(
            distance: distance, pivot: .zero, orthographicScale: scale,
            isOrthographic: orthographic)
    }

    private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1)
            ))
    }

    private func box(_ id: String, at t: SIMD3<Float>, size: Float = 4) -> ViewportBody {
        var body = ViewportBody.box(id: id, width: size, height: size, depth: size)
        body.transform = translation(t)
        return body
    }

    /// The height the camera shows at the pivot.
    private func visibleHeight(_ state: CameraState) -> Float {
        state.isOrthographic
            ? state.orthographicScale : 2 * state.distance * tan(state.fieldOfView * .pi / 360)
    }

    /// Ticks the camera at 60 Hz until nothing moves, or one simulated second has passed.
    private func settle(_ vc: ViewportController) {
        for _ in 0..<60 where vc.cameraController.advance(by: 1.0 / 60) {}
    }

    // MARK: - 1. worldToScreen behind an orthographic camera

    @Test("A point behind an orthographic camera does not project", arguments: [false, true])
    func orthographicBehindCameraIsCulled(orthographic: Bool) {
        let state = camera(orthographic: orthographic)
        let vp = state.projectionMatrix(aspectRatio: 1, near: 0.01, far: 1000) * state.viewMatrix
        let size = CGSize(width: 400, height: 400)

        // In front: the origin projects to the centre of the view.
        let front = ProjectionUtility.worldToScreen(
            point: .zero, vpMatrix: vp, viewportSize: size)
        #expect(front.map { abs($0.x - 200) < 0.01 && abs($0.y - 200) < 0.01 } == true)

        // Behind the eye at z = 10, slightly off axis so a mirrored projection would land
        // inside the view.
        let behind = SIMD3<Float>(1, 1, 15)
        #expect(
            ProjectionUtility.worldToScreen(point: behind, vpMatrix: vp, viewportSize: size) == nil)
        #expect(ProjectionUtility.worldToNDC(point: behind, vpMatrix: vp) == nil)
    }

    @Test("Orthographic culling follows the near plane, as the renderer clips")
    func orthographicCullUsesNearPlane() {
        let state = camera(orthographic: true)
        let vp = state.projectionMatrix(aspectRatio: 1, near: 2, far: 100) * state.viewMatrix
        // Depth 1 from the eye at z = 10 is nearer than the near plane (2): culled.
        #expect(ProjectionUtility.worldToNDC(point: SIMD3(0, 0, 9), vpMatrix: vp) == nil)
        // Depth 3: drawn, with NDC z between 0 and 1.
        let ndc = ProjectionUtility.worldToNDC(point: SIMD3(0, 0, 7), vpMatrix: vp)
        #expect(ndc.map { $0.z > 0 && $0.z < 1 } == true)
    }

    // MARK: - 2. fit(to: bodies)

    @Test("fit(to: bodies) frames a moved body where it is drawn")
    func fitUsesWorldBounds() throws {
        let fitted = try #require(
            camera(orthographic: false).fit(
                to: [box("moved", at: SIMD3(100, 0, 0))], aspectRatio: 1))
        #expect(simd_distance(fitted.pivot, SIMD3(100, 0, 0)) < 1e-3)
    }

    @Test("fit(to: bodies) leaves out overlay widgets, unless nothing else is visible")
    func fitSkipsOverlays() throws {
        var gizmo = box("gizmo", at: SIMD3(50, 0, 0), size: 40)
        gizmo.renderLayer = .overlay
        var hidden = box("hidden", at: SIMD3(-80, 0, 0))
        hidden.isVisible = false
        let model = box("model", at: .zero)

        let fitted = try #require(
            camera(orthographic: false).fit(to: [model, gizmo, hidden], aspectRatio: 1))
        #expect(simd_length(fitted.pivot) < 1e-3, "pivot \(fitted.pivot)")
        // Fitted to the 4-unit box alone, not to the 40-unit gizmo too.
        let alone = try #require(camera(orthographic: false).fit(to: [model], aspectRatio: 1))
        #expect(abs(fitted.distance - alone.distance) < 1e-3)

        let gizmoOnly = try #require(
            camera(orthographic: false).fit(to: [gizmo, hidden], aspectRatio: 1))
        #expect(simd_distance(gizmoOnly.pivot, SIMD3(50, 0, 0)) < 1e-3)
    }

    // MARK: - 3. Orthographic pivot zoom decision

    @Test("An orthographic zoom in reaches the raycast pivot, whatever the distance")
    func orthographicZoomUsesScale() throws {
        // Zoomed in by scale (1 unit of a 4-unit box shown), but at a distance that alone
        // reads as zoomed far out.
        let state = camera(orthographic: true, distance: 100, scale: 1)
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: state, bodies: [box("b", at: .zero)], aspectRatio: 1,
                config: .default))
        // The raycast hit on the front face (z = 2), not the scene centre's depth (z = 0).
        #expect(abs(pivot.z - 2) < 1e-3, "pivot \(pivot)")
    }

    @Test("An orthographic zoom out orbits the scene centre, whatever the distance")
    func orthographicZoomOutUsesScale() throws {
        // Zoomed out by scale (100 units shown), at a distance that alone reads as zoomed in.
        let state = camera(orthographic: true, distance: 3, scale: 100)
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: state, bodies: [box("b", at: .zero)], aspectRatio: 1,
                config: .default))
        #expect(abs(pivot.z) < 1e-3, "pivot \(pivot)")
    }

    @Test("The orthographic zoom distance shows the same height as perspective")
    func zoomDistanceMatchesPerspective() {
        let ortho = camera(orthographic: true, distance: 1, scale: 8)
        let d = PivotStrategy.zoomDistance(of: ortho)
        #expect(abs(2 * d * tan(ortho.fieldOfView * .pi / 360) - 8) < 1e-4)
        #expect(PivotStrategy.zoomDistance(of: camera(orthographic: false, distance: 7)) == 7)
    }

    // MARK: - 4. The scheduled pivot update reads the bodies when it runs

    /// Holds the scene the scheduled update reads, so the test can change it after scheduling.
    @MainActor
    final class SceneBox {
        var bodies: [ViewportBody] = []
    }

    @Test("A pivot update scheduled before an edit raycasts the edited bodies")
    func scheduledPivotReadsCurrentBodies() async throws {
        var config = ViewportConfiguration()
        config.rotationStyle = .turntable
        config.initialCameraState = camera(orthographic: false, distance: 12)
        // Always the raycast branch.
        config.dynamicPivotConfiguration = DynamicPivotConfiguration(zoomThreshold: 100)
        let vc = ViewportController(configuration: config)
        vc.updateViewportSize(CGSize(width: 400, height: 400))

        let scene = SceneBox()
        scene.bodies = [box("b", at: .zero)]
        vc.scheduleDynamicPivotUpdate(delay: 0.02) { scene.bodies }
        // Edited within the delay: the box moves back 3 units, so its front face is at z = -1.
        scene.bodies = [box("b", at: SIMD3(0, 0, -3))]

        let eye = vc.cameraState.position
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            settle(vc)
            if abs(vc.cameraState.distance - 12) > 0.01 { break }
        }
        // Eye at z = 12; the moved box's front face is at depth 13, the stale one's at 10.
        #expect(abs(vc.cameraState.distance - 13) < 1e-2, "distance \(vc.cameraState.distance)")
        #expect(simd_distance(vc.cameraState.position, eye) < 1e-3)
    }

    // MARK: - Projection switch keeps the view's size

    @Test("Toggling the projection keeps the height shown at the pivot")
    func toggleProjectionKeepsFraming() {
        var config = ViewportConfiguration()
        config.initialCameraState = camera(orthographic: false, distance: 20, scale: 10)
        let vc = ViewportController(configuration: config)
        let before = visibleHeight(vc.cameraState)

        vc.toggleProjection()
        settle(vc)
        #expect(vc.cameraState.isOrthographic)
        #expect(abs(visibleHeight(vc.cameraState) - before) < 1e-3)

        // Zoom in orthographic, then back to perspective: the zoom carries over.
        vc.cameraController.zoom(factor: 2)
        let zoomed = visibleHeight(vc.cameraState)
        vc.toggleProjection()
        settle(vc)
        #expect(!vc.cameraState.isOrthographic)
        #expect(abs(visibleHeight(vc.cameraState) - zoomed) < 1e-3)
        #expect(simd_length(vc.cameraState.pivot) < 1e-4)
    }

    @Test("A standard view in the other projection keeps the height shown at the pivot")
    func standardViewKeepsFraming() {
        var config = ViewportConfiguration()
        config.initialCameraState = StandardView.isometricFrontRight.cameraState(distance: 30)
        let vc = ViewportController(configuration: config)
        let before = visibleHeight(vc.cameraState)
        vc.goToStandardView(.front)
        settle(vc)
        #expect(vc.cameraState.isOrthographic)
        #expect(abs(visibleHeight(vc.cameraState) - before) < 1e-3)
    }

    @Test("The projection switch mid-animation does not jump the view in size")
    func interpolationIsContinuousAcrossSwitch() {
        let persp = camera(orthographic: false, distance: 20, scale: 3)
        let ortho = persp.matchingFraming(orthographic: true)
        let justBefore = persp.interpolated(to: ortho, t: 0.499)
        let justAfter = persp.interpolated(to: ortho, t: 0.501)
        #expect(!justBefore.isOrthographic && justAfter.isOrthographic)
        #expect(abs(visibleHeight(justBefore) - visibleHeight(justAfter)) < 1e-2)
        // The start is unchanged.
        #expect(
            abs(visibleHeight(persp.interpolated(to: ortho, t: 0)) - visibleHeight(persp)) < 1e-4)
    }
}
