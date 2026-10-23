// CameraFeelTests.swift
// OCCTSwiftViewport Tests
//
// Issue #200: a 1:1 pan, a dynamic-pivot shift that leaves the view still, a bounded
// orthographic zoom, two-finger arcball roll from the touches' centroid, the touch view's
// drag/pan arbitration, and focusOn stopping momentum. The pan tests project a world point to
// screen points before and after and check that it stayed under the pointer.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Camera feel (#200)")
struct CameraFeelTests {

    // MARK: - Helpers

    private static let viewSize = CGSize(width: 800, height: 600)

    private func controller(
        style: RotationStyle = .turntable, orthographic: Bool = false,
        gestures: GestureConfiguration = .default
    ) -> ViewportController {
        var config = ViewportConfiguration()
        config.rotationStyle = style
        var state = StandardView.isometricFrontRight.cameraState(distance: 12)
        state.isOrthographic = orthographic
        state.orthographicScale = 7
        config.initialCameraState = state
        config.gestureConfiguration = gestures
        let vc = ViewportController(configuration: config)
        vc.updateViewportSize(Self.viewSize)
        return vc
    }

    /// Where `point` appears, in view points from the top-left (y down).
    private func screenPoint(
        _ point: SIMD3<Float>, _ state: CameraState, size: CGSize = viewSize
    ) -> SIMD2<Float> {
        let aspect = Float(size.width / size.height)
        let clip =
            state.projectionMatrix(aspectRatio: aspect) * state.viewMatrix * SIMD4(point, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2(
            (ndc.x + 1) / 2 * Float(size.width), (1 - ndc.y) / 2 * Float(size.height))
    }

    /// A world point at the pivot's depth, off the centre of the view.
    private func pivotDepthPoint(_ state: CameraState) -> SIMD3<Float> {
        state.pivot + state.rightVector * 1.3 - state.upVector * 0.8
    }

    /// Pans by `total` points, in `steps` equal two-finger increments.
    private func pan(_ vc: ViewportController, by total: SIMD2<Float>, steps: Int = 8) {
        for _ in 0..<steps {
            vc.dispatch(.twoFingerPanChanged(translation: total / Float(steps)))
        }
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
    }

    // MARK: - 1:1 pan

    @Test("Perspective pan is 1:1: the pivot-depth point under the finger stays under it")
    func perspectivePanIsOneToOne() {
        let vc = controller()
        let start = vc.cameraState
        let point = pivotDepthPoint(start)
        let delta = SIMD2<Float>(137, -64)
        pan(vc, by: delta)
        let moved = screenPoint(point, vc.cameraState) - screenPoint(point, start)
        #expect(simd_length(moved - delta) < 1, "moved \(moved), expected \(delta)")
    }

    @Test("Orthographic pan is 1:1, following the orthographic scale rather than the distance")
    func orthographicPanIsOneToOne() {
        let vc = controller(orthographic: true)
        let start = vc.cameraState
        // Any point, not only the pivot's depth: depth does not change size in orthographic.
        let point = pivotDepthPoint(start) + start.viewDirection * 3
        let delta = SIMD2<Float>(-90, 45)
        pan(vc, by: delta)
        let moved = screenPoint(point, vc.cameraState) - screenPoint(point, start)
        #expect(simd_length(moved - delta) < 1, "moved \(moved), expected \(delta)")
    }

    @Test("Pan stays 1:1 at any zoom and after a resize")
    func panTracksZoomAndViewSize() {
        let vc = controller()
        vc.cameraController.zoom(factor: 40)
        vc.updateViewportSize(CGSize(width: 1000, height: 400))
        #expect(vc.cameraController.viewportHeight == 400)
        let start = vc.cameraState
        let point = pivotDepthPoint(start) * 0.02 + start.pivot * 0.98
        pan(vc, by: SIMD2(50, 0))
        let resized = CGSize(width: 1000, height: 400)
        let moved =
            screenPoint(point, vc.cameraState, size: resized)
            - screenPoint(point, start, size: resized)
        #expect(simd_length(moved - SIMD2(50, 0)) < 1, "moved \(moved)")
    }

    @Test("panSensitivity multiplies the 1:1 speed")
    func panSensitivityMultiplies() {
        let vc = controller(gestures: GestureConfiguration(panSensitivity: 2))
        let start = vc.cameraState
        let point = pivotDepthPoint(start)
        pan(vc, by: SIMD2(40, 0))
        let moved = screenPoint(point, vc.cameraState) - screenPoint(point, start)
        #expect(simd_length(moved - SIMD2(80, 0)) < 1, "moved \(moved)")
    }

    @Test("Pan momentum keeps the 1:1 scale")
    func panMomentumIsOneToOne() {
        let vc = controller(gestures: GestureConfiguration(momentumScale: 1))
        let start = vc.cameraState
        let point = pivotDepthPoint(start)
        vc.endPan(velocity: CGSize(width: 600, height: 0))
        _ = vc.cameraController.advance(by: 1.0 / 60)
        vc.cameraController.stopInertia()
        // 600 pt/s for 1/60 s is 10 pt.
        let moved = screenPoint(point, vc.cameraState) - screenPoint(point, start)
        #expect(simd_length(moved - SIMD2(10, 0)) < 0.1, "moved \(moved)")
    }

    @Test("The gesture defaults are 1:1 pan with no speed floor")
    func panDefaults() {
        #expect(GestureConfiguration.default.panSensitivity == 1)
        #expect(GestureConfiguration.default.minPanSpeed == 0)
        let camera = CameraController()
        #expect(camera.panSensitivity == 1)
        #expect(camera.minPanSpeed == 0)
    }

    @Test("minPanSpeed is a floor in world units per point")
    func minPanSpeedFloor() {
        let camera = CameraController(
            initialState: CameraState(distance: 0.1, pivot: .zero))
        camera.minPanSpeed = 0.01
        camera.pan(deltaX: 10, deltaY: 0)
        #expect(abs(simd_length(camera.cameraState.pivot) - 0.1) < 1e-5)
    }

    // MARK: - Orthographic zoom

    @Test("Orthographic zoom stops at the scale range, in and out")
    func orthographicZoomIsClamped() {
        let vc = controller(orthographic: true)
        let camera = vc.cameraController
        let range = camera.orthographicScaleRange
        camera.zoom(factor: 1e9)
        #expect(abs(vc.cameraState.orthographicScale - range.lowerBound) < 1e-6)
        camera.zoom(factor: 1e-12)
        #expect(abs(vc.cameraState.orthographicScale - range.upperBound) < 1e-2)
    }

    @Test("Orthographic zoom-at-cursor stops sliding the view at the scale limit")
    func orthographicZoomTowardAtLimit() {
        let vc = controller(orthographic: true)
        let camera = vc.cameraController
        camera.zoom(factor: 1e9)
        let pivot = vc.cameraState.pivot
        camera.zoomToward(factor: 2, cursorNormalized: SIMD2(0.8, 0.5), aspectRatio: 4 / 3)
        #expect(simd_distance(vc.cameraState.pivot, pivot) < 1e-6)
    }

    @Test("The orthographic scale range spans the field of view at minDistance and maxDistance")
    func orthographicRangeFollowsDistanceLimits() {
        let camera = CameraController(initialState: CameraState(fieldOfView: 90))
        camera.minDistance = 0.5
        camera.maxDistance = 200
        // tan(45°) = 1, so the height spanned is twice the distance.
        #expect(abs(camera.orthographicScaleRange.lowerBound - 1) < 1e-5)
        #expect(abs(camera.orthographicScaleRange.upperBound - 400) < 1e-3)
    }

    // MARK: - Dynamic pivot

    @Test("A pivot shift along the line of sight leaves the camera where it is")
    func pivotShiftKeepsCameraPosition() {
        for duration: Float in [0, 0.15] {
            let vc = controller()
            let start = vc.cameraState
            let hit = start.pivot + start.viewDirection * 2.5
            vc.cameraController.adjustPivot(to: hit, duration: duration)
            for _ in 0..<20 {
                _ = vc.cameraController.advance(by: 1.0 / 60)
                #expect(simd_distance(vc.cameraState.position, start.position) < 1e-4)
            }
            #expect(simd_distance(vc.cameraState.pivot, hit) < 1e-4)
            #expect(abs(vc.cameraState.distance - (start.distance + 2.5)) < 1e-4)
        }
    }

    @Test("A pivot shift across the view moves the camera only across, not in depth")
    func pivotShiftAcrossKeepsDepth() {
        let vc = controller()
        let start = vc.cameraState
        let target = start.pivot + start.rightVector * 1.5 - start.viewDirection * 3
        vc.cameraController.adjustPivot(to: target, duration: 0)
        let depth = { (s: CameraState) in simd_dot(s.position, start.viewDirection) }
        #expect(abs(depth(vc.cameraState) - depth(start)) < 1e-4)
        #expect(simd_distance(vc.cameraState.pivot, target) < 1e-5)
    }

    @Test("A pivot shift keeps the distance within its limits")
    func pivotShiftClampsDistance() {
        let vc = controller()
        let start = vc.cameraState
        // A pivot beyond the camera would need a negative distance.
        vc.cameraController.adjustPivot(
            to: start.pivot - start.viewDirection * (start.distance * 2), duration: 0)
        #expect(vc.cameraState.distance == vc.cameraController.minDistance)
    }

    @Test("The dynamic pivot moves the pivot onto the model without moving the view")
    func dynamicPivotDoesNotZoom() {
        let vc = controller()
        let box = ViewportBody.box(id: "b", width: 4, height: 4, depth: 4)
        // Zoomed in, so the pivot goes to the view-centre raycast hit on the box.
        vc.cameraController.zoom(factor: 4)
        let start = vc.cameraState
        vc.updateDynamicPivot(bodies: [box])
        for _ in 0..<30 { _ = vc.cameraController.advance(by: 1.0 / 60) }
        #expect(simd_distance(vc.cameraState.pivot, start.pivot) > 0.1)
        #expect(simd_distance(vc.cameraState.position, start.position) < 1e-3)
    }

    // MARK: - Two-finger arcball roll

    @Test("A two-finger arcball drag from its centroid outside the sphere rolls the view")
    func twoFingerArcballRolls() {
        let vc = controller(style: .arcball, gestures: GestureConfiguration(twoFingerDrag: .orbit))
        let start = vc.cameraState
        let radius = vc.cameraController.arcballRadius
        vc.setTwoFingerDragOrigin(offsetFromCenter: SIMD2(radius * 1.5, 0))
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(0, -40)))
        #expect(simd_dot(vc.cameraState.viewDirection, start.viewDirection) > 0.99999)
        #expect(simd_dot(vc.cameraState.upVector, start.upVector) < 0.999)
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
    }

    @Test("A two-finger drag matches a one-finger drag from the same place")
    func twoFingerMatchesPrimaryFromSameOrigin() {
        let gestures = GestureConfiguration(twoFingerDrag: .orbit)
        let a = controller(style: .arcball, gestures: gestures)
        let b = controller(style: .arcball, gestures: gestures)
        a.setDragOrigin(offsetFromCenter: SIMD2(120, -200))
        b.setTwoFingerDragOrigin(offsetFromCenter: SIMD2(120, -200))
        for _ in 0..<5 {
            a.dispatch(.dragChanged(delta: SIMD2(9, 14), modifiers: []))
            b.dispatch(.twoFingerPanChanged(translation: SIMD2(9, 14)))
        }
        let dot = abs(simd_dot(a.cameraState.rotation.vector, b.cameraState.rotation.vector))
        #expect(dot > 0.999999)
    }

    @Test("The two-finger origin is used once; the next two-finger drag starts at the centre")
    func twoFingerOriginIsConsumed() {
        let vc = controller(style: .arcball, gestures: GestureConfiguration(twoFingerDrag: .orbit))
        vc.setTwoFingerDragOrigin(offsetFromCenter: SIMD2(30, 40))
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(1, 1)))
        #expect(vc.twoFingerDragPointer == SIMD2(31, 41))
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
        #expect(vc.twoFingerDragPointer == nil)
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(1, 1)))
        #expect(vc.twoFingerDragPointer == SIMD2(1, 1))
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
    }

    // MARK: - Gestures take the camera from animations and momentum

    @Test("focusOn(animated: false) stops momentum")
    func focusOnStopsMomentum() {
        let vc = controller()
        vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
        vc.endPan(velocity: CGSize(width: 900, height: 0))
        vc.focusOn(point: SIMD3(1, 2, 3), animated: false)
        #expect(vc.cameraController.angularVelocity == .zero)
        #expect(vc.cameraController.panVelocity == .zero)
        let focused = vc.cameraState
        _ = vc.cameraController.advance(by: 1.0 / 60)
        #expect(vc.cameraState == focused)
        #expect(simd_distance(focused.pivot, SIMD3(1, 2, 3)) < 1e-6)
    }

    @Test("A pan during a view animation is not overwritten by it")
    func panCancelsViewAnimation() {
        let vc = controller()
        vc.goToStandardView(.top)
        #expect(vc.cameraController.isAnimating)
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(40, 0)))
        #expect(!vc.cameraController.isAnimating)
        let panned = vc.cameraState
        _ = vc.cameraController.advance(by: 1.0 / 60)
        #expect(vc.cameraState == panned)
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
    }

    @Test("A pinch, scroll or roll during a view animation is kept; momentum keeps coasting")
    func zoomAndRollCancelViewAnimation() {
        let events: [ViewportInputEvent] = [
            .pinchChanged(scale: 1.3),
            .pinchAtChanged(scale: 1.3, centerNDC: SIMD2(0.2, 0.1), aspectRatio: 4 / 3),
            .scroll(delta: 1, cursorNDC: .zero, aspectRatio: 4 / 3),
            .rotateChanged(radians: 0.2),
        ]
        for event in events {
            let vc = controller()
            vc.goToStandardView(.top)
            vc.endPan(velocity: CGSize(width: 900, height: 0))
            vc.dispatch(event)
            #expect(!vc.cameraController.isAnimating, "\(event)")
            #expect(vc.cameraController.panVelocity != .zero, "\(event)")
            let after = vc.cameraState
            _ = vc.cameraController.advance(by: 1.0 / 60)
            #expect(vc.cameraState.distance == after.distance, "\(event)")
            #expect(vc.cameraState.rotation == after.rotation, "\(event)")
        }
    }

    @Test("A drag keeps the dynamic pivot's animation running")
    func dragKeepsPivotAnimation() {
        let vc = controller()
        let target = vc.cameraState.pivot + SIMD3(0.5, 0, 0)
        vc.cameraController.adjustPivot(to: target, duration: 0.15)
        vc.dispatch(.dragChanged(delta: SIMD2(5, 0), modifiers: []))
        #expect(vc.cameraController.isAnimating)
        for _ in 0..<20 { _ = vc.cameraController.advance(by: 1.0 / 60) }
        #expect(simd_distance(vc.cameraState.pivot, target) < 1e-4)
        vc.dispatch(.dragEnded(velocity: .zero, modifiers: []))
    }
}

// MARK: - Touch drag arbitration

@Suite("Touch drag arbitration (#200)")
struct TouchDragArbiterTests {

    private let size = CGSize(width: 400, height: 300)

    private func changed(_ delta: SIMD2<Float>) -> ViewportInputEvent {
        .dragChanged(delta: delta, modifiers: [])
    }

    @Test("A one-finger drag sets its origin once and dispatches deltas, then its end")
    func plainDrag() {
        var arbiter = TouchDragArbiter()
        let start = CGPoint(x: 300, y: 50)
        let first = arbiter.dragChanged(
            start: start, translation: CGSize(width: 10, height: 0), viewSize: size)
        #expect(first.dragOrigin == SIMD2(100, -100))
        #expect(!first.interruptsDrag)
        #expect(first.events == [changed(SIMD2(10, 0))])
        let second = arbiter.dragChanged(
            start: start, translation: CGSize(width: 14, height: 3), viewSize: size)
        #expect(second.dragOrigin == nil)
        #expect(second.events == [changed(SIMD2(4, 3))])
        let end = arbiter.dragEnded(velocity: CGSize(width: 50, height: 0))
        #expect(end.events == [.dragEnded(velocity: SIMD2(50, 0), modifiers: [])])
    }

    @Test("A two-finger pan the one-finger drag never saw does not swallow the next drag")
    func panAloneDoesNotSwallowNextDrag() {
        var arbiter = TouchDragArbiter()
        let began = arbiter.twoFingerPanBegan()
        #expect(began.events.isEmpty)
        #expect(!began.interruptsDrag)
        arbiter.twoFingerPanEnded()
        #expect(!arbiter.isTwoFingerPanActive)
        let step = arbiter.dragChanged(
            start: CGPoint(x: 10, y: 10), translation: CGSize(width: 9, height: 0),
            viewSize: size)
        #expect(step.events == [changed(SIMD2(9, 0))])
    }

    @Test("A second finger ends the one-finger drag at once and the rest of it is ignored")
    func secondFingerEndsDrag() {
        var arbiter = TouchDragArbiter()
        let start = CGPoint(x: 200, y: 150)
        _ = arbiter.dragChanged(
            start: start, translation: CGSize(width: 10, height: 0), viewSize: size)
        let began = arbiter.twoFingerPanBegan()
        #expect(began.interruptsDrag)
        #expect(began.events.isEmpty)
        let during = arbiter.dragChanged(
            start: start, translation: CGSize(width: 30, height: 0), viewSize: size)
        #expect(during.events.isEmpty)
        #expect(!during.interruptsDrag)
        // The second finger lifts; the first keeps moving. Still the same drag: ignored.
        arbiter.twoFingerPanEnded()
        let after = arbiter.dragChanged(
            start: start, translation: CGSize(width: 50, height: 0), viewSize: size)
        #expect(after.events.isEmpty)
        #expect(arbiter.dragEnded(velocity: CGSize(width: 900, height: 0)).events.isEmpty)
    }

    @Test("A drag whose end never came is ended when the next drag starts, with no jump")
    func cancelledDragIsEnded() {
        var arbiter = TouchDragArbiter()
        _ = arbiter.dragChanged(
            start: CGPoint(x: 0, y: 0), translation: CGSize(width: 80, height: 0), viewSize: size)
        // No dragEnded: the gesture was cancelled. A new drag starts elsewhere.
        let next = arbiter.dragChanged(
            start: CGPoint(x: 50, y: 60), translation: CGSize(width: 9, height: 0),
            viewSize: size)
        #expect(next.interruptsDrag)
        #expect(next.events == [changed(SIMD2(9, 0))])
        #expect(next.dragOrigin == SIMD2(-150, -90))
    }

    @Test("A drag that starts during a two-finger pan is ignored until it ends")
    func dragDuringPanIsIgnored() {
        var arbiter = TouchDragArbiter()
        _ = arbiter.twoFingerPanBegan()
        let step = arbiter.dragChanged(
            start: CGPoint(x: 5, y: 5), translation: CGSize(width: 20, height: 0), viewSize: size)
        #expect(step.events.isEmpty)
        #expect(step.dragOrigin == nil)
        arbiter.twoFingerPanEnded()
        #expect(arbiter.dragEnded(velocity: .zero).events.isEmpty)
    }
}
