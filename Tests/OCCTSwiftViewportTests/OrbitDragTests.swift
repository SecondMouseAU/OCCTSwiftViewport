// OrbitDragTests.swift
// OCCTSwiftViewport Tests
//
// What an orbit drag fixes at its start, and the momentum after it: the turntable turn direction
// over the pole (#195), the Shoemake arcball and its roll (#196), the momentum units (#197) and
// first-person look-around (#198). Like DragRotationTests, most tests project a world point
// through the camera before and after and check which way it moved on screen.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Orbit drags and momentum")
struct OrbitDragTests {

    // MARK: - Helpers

    /// Screen position (x right, y up, in units of the focal length) of `point` seen by `state`.
    private func screen(_ point: SIMD3<Float>, _ state: CameraState) -> SIMD2<Float> {
        let c = state.viewMatrix * SIMD4<Float>(point, 1)
        return SIMD2(c.x / -c.z, c.y / -c.z)
    }

    private func controller(
        style: RotationStyle, view: StandardView = .isometricFrontRight,
        gestures: GestureConfiguration = .default
    ) -> ViewportController {
        var config = ViewportConfiguration()
        config.rotationStyle = style
        config.initialCameraState = view.cameraState()
        config.gestureConfiguration = gestures
        return ViewportController(configuration: config)
    }

    /// One complete drag: its moves, then a release with no velocity.
    private func drag(_ vc: ViewportController, _ deltas: [SIMD2<Float>]) {
        for delta in deltas { vc.dispatch(.dragChanged(delta: delta, modifiers: [])) }
        vc.dispatch(.dragEnded(velocity: .zero, modifiers: []))
    }

    /// The model's near side: the point a third of the way from the pivot to the camera.
    private func nearPoint(_ state: CameraState) -> SIMD3<Float> {
        state.pivot + (state.position - state.pivot) * 0.3
    }

    /// Angle between two rotations, in radians.
    private func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector))))
    }

    /// Tilts a turntable camera from the front view over the top, until it is upside down.
    private func tiltOverThePole(_ vc: ViewportController) {
        // Front to top is 90°, 314 pt at 0.005 rad/pt; 400 pt goes about 25° past it.
        drag(vc, Array(repeating: SIMD2(0, -20), count: 20))
    }

    // MARK: - #195 Turntable over the pole

    @Test("Turntable: past the pole, a new horizontal drag still carries the model with it")
    func turntableOverThePole() {
        for convention in DragRotationConvention.allCases {
            let vc = controller(
                style: .turntable, view: .front,
                gestures: GestureConfiguration(dragRotation: convention))
            tiltOverThePole(vc)
            #expect(vc.cameraState.upVector.z < -0.1)

            let start = vc.cameraState
            let point = nearPoint(start)
            vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
            let moved = screen(point, vc.cameraState).x - screen(point, start).x
            #expect(convention == .rotateObject ? moved > 1e-3 : moved < -1e-3)
        }
    }

    @Test("Turntable: the turn direction is fixed when the drag begins, not flipped mid-drag")
    func turntableDirectionFixedPerDrag() {
        let vc = controller(style: .turntable, view: .front)
        // One drag: over the pole, then sideways. The drag began upright, so it keeps the upright
        // direction and the model now turns against the pointer, without a jump at the top view.
        for _ in 0..<20 { vc.dispatch(.dragChanged(delta: SIMD2(0, -20), modifiers: [])) }
        #expect(vc.cameraState.upVector.z < -0.1)
        let start = vc.cameraState
        let point = nearPoint(start)
        vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        #expect(screen(point, vc.cameraState).x - screen(point, start).x < -1e-3)
    }

    @Test("Turntable: past the pole, momentum keeps turning the way the drag did")
    func turntableMomentumOverThePole() {
        let vc = controller(style: .turntable, view: .front)
        tiltOverThePole(vc)
        let start = vc.cameraState
        let point = nearPoint(start)
        vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        let afterDrag = vc.cameraState
        vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
        _ = vc.cameraController.advance(by: 1.0 / 60)
        let dragMove = screen(point, afterDrag).x - screen(point, start).x
        let coastMove = screen(point, vc.cameraState).x - screen(point, afterDrag).x
        vc.cameraController.stopInertia()
        #expect(dragMove > 1e-3)
        #expect(coastMove > 0)
    }

    @Test("Turntable: an upside-down view re-read after an animation still tilts with the drag")
    func turntableResyncKeepsTiltDirection() {
        let vc = controller(style: .turntable, view: .front)
        tiltOverThePole(vc)
        // A zero-length animation re-reads the turntable angles from the rotation.
        vc.cameraController.animateTo(vc.cameraState, duration: 0)
        let start = vc.cameraState
        let point = nearPoint(start)
        vc.dispatch(.dragChanged(delta: SIMD2(0, -10), modifiers: []))
        #expect(angle(start.rotation, vc.cameraState.rotation) > 1e-3)
        #expect(screen(point, vc.cameraState).y - screen(point, start).y > 1e-3)
    }

    @Test("Turntable: switching from arcball does not snap back to the last turntable view")
    func styleSwitchDoesNotSnap() {
        let vc = controller(style: .arcball)
        drag(vc, [SIMD2(40, 25), SIMD2(30, -10)])
        let tumbled = vc.cameraState.rotation
        vc.cameraController.rotationStyle = .turntable
        vc.dispatch(.dragChanged(delta: SIMD2(0.5, 0), modifiers: []))
        #expect(angle(tumbled, vc.cameraState.rotation) < 0.01)
    }

    // MARK: - #196 Arcball

    @Test("Arcball: a drag around the centre outside the sphere rolls the view")
    func arcballRollsOutsideTheSphere() {
        for convention in DragRotationConvention.allCases {
            let vc = controller(
                style: .arcball, gestures: GestureConfiguration(dragRotation: convention))
            let start = vc.cameraState
            let radius = vc.cameraController.arcballRadius
            let point = start.pivot + start.rightVector * (start.distance * 0.2)
            // Start right of the sphere and move up: anticlockwise about the centre.
            vc.setDragOrigin(offsetFromCenter: SIMD2(radius * 1.5, 0))
            vc.dispatch(.dragChanged(delta: SIMD2(0, -40), modifiers: []))

            // A pure roll: the line of sight stays put while the picture turns about it.
            #expect(simd_dot(vc.cameraState.viewDirection, start.viewDirection) > 0.99999)
            #expect(simd_dot(vc.cameraState.upVector, start.upVector) < 0.999)
            // With .rotateObject the model rolls with the pointer, so the point right of the
            // centre moves up; .orbitCamera rolls it the other way.
            let moved = screen(point, vc.cameraState).y - screen(point, start).y
            #expect(convention == .rotateObject ? moved > 1e-3 : moved < -1e-3)
        }
    }

    @Test("Arcball: inside the sphere, a drag tumbles the model without rolling it")
    func arcballTumblesInside() {
        let vc = controller(style: .arcball)
        let start = vc.cameraState
        vc.dispatch(.dragChanged(delta: SIMD2(0, -30), modifiers: []))
        // A vertical drag through the centre turns about the screen's x axis only.
        #expect(simd_dot(vc.cameraState.rightVector, start.rightVector) > 0.99999)
        #expect(simd_dot(vc.cameraState.viewDirection, start.viewDirection) < 0.999)
    }

    @Test("Arcball: the rotation depends only on where the pointer is, not the path it took")
    func arcballIsPathIndependent() {
        let a = controller(style: .arcball)
        let b = controller(style: .arcball)
        a.setDragOrigin(offsetFromCenter: SIMD2(50, 80))
        b.setDragOrigin(offsetFromCenter: SIMD2(50, 80))
        a.dispatch(.dragChanged(delta: SIMD2(120, -60), modifiers: []))
        for _ in 0..<12 { b.dispatch(.dragChanged(delta: SIMD2(10, -5), modifiers: [])) }
        #expect(angle(a.cameraState.rotation, b.cameraState.rotation) < 1e-4)

        // Back to where it started: the model is as it was.
        let start = controller(style: .arcball).cameraState
        b.dispatch(.dragChanged(delta: SIMD2(-300, 0), modifiers: []))
        b.dispatch(.dragChanged(delta: SIMD2(180, 60), modifiers: []))
        #expect(angle(start.rotation, b.cameraState.rotation) < 1e-4)
    }

    @Test("Arcball: near the centre it turns orbitSensitivity radians per point, like turntable")
    func arcballCentreRate() {
        let vc = controller(style: .arcball)
        let start = vc.cameraState
        vc.dispatch(.dragChanged(delta: SIMD2(4, 0), modifiers: []))
        let turned = angle(start.rotation, vc.cameraState.rotation)
        #expect(abs(turned - 4 * GestureConfiguration.default.orbitSensitivity) < 1e-4)
    }

    @Test("Arcball: release momentum keeps turning the way the drag did")
    func arcballMomentum() {
        for convention in DragRotationConvention.allCases {
            let vc = controller(
                style: .arcball, gestures: GestureConfiguration(dragRotation: convention))
            let start = vc.cameraState
            let point = nearPoint(start)
            vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
            let afterDrag = vc.cameraState
            vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
            _ = vc.cameraController.advance(by: 1.0 / 60)
            let dragMove = screen(point, afterDrag).x - screen(point, start).x
            let coastMove = screen(point, vc.cameraState).x - screen(point, afterDrag).x
            vc.cameraController.stopInertia()
            #expect(abs(dragMove) > 1e-3)
            #expect(coastMove * dragMove > 0)
        }
    }

    // MARK: - #197 Momentum units

    @Test("Momentum at momentumScale 1 continues at the release speed")
    func momentumMatchesReleaseSpeed() {
        let gestures = GestureConfiguration(momentumScale: 1)
        let coasting = controller(style: .turntable, gestures: gestures)
        let dragging = controller(style: .turntable, gestures: gestures)
        coasting.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        dragging.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))

        // 600 pt/s for 1/60 s is 10 pt, so one tick of momentum matches 10 pt more drag.
        coasting.dispatch(.dragEnded(velocity: SIMD2(600, 0), modifiers: []))
        _ = coasting.cameraController.advance(by: 1.0 / 60)
        coasting.cameraController.stopInertia()
        dragging.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        #expect(angle(coasting.cameraState.rotation, dragging.cameraState.rotation) < 1e-4)
    }

    @Test("Momentum scales with momentumScale; the default keeps the historical 0.001 per pt/s")
    func momentumScale() {
        #expect(GestureConfiguration.default.momentumScale == 0.06)
        let vc = controller(style: .turntable)
        let momentum = vc.momentum(fromReleaseVelocity: CGSize(width: 1000, height: -500))
        #expect(simd_length(momentum - SIMD2(1, -0.5)) < 1e-5)

        let half = controller(style: .turntable, gestures: GestureConfiguration(momentumScale: 0.5))
        let scaled = half.momentum(fromReleaseVelocity: CGSize(width: 600, height: 0))
        #expect(abs(scaled.x - 5) < 1e-5)
    }

    @Test("Pan momentum at momentumScale 1 continues at the release speed")
    func panMomentumMatchesReleaseSpeed() {
        let gestures = GestureConfiguration(momentumScale: 1)
        let coasting = controller(style: .turntable, gestures: gestures)
        let dragging = controller(style: .turntable, gestures: gestures)
        coasting.endPan(velocity: CGSize(width: 600, height: 0))
        _ = coasting.cameraController.advance(by: 1.0 / 60)
        coasting.cameraController.stopInertia()
        dragging.handlePan(translation: CGSize(width: 10, height: 0))
        #expect(simd_distance(coasting.cameraState.pivot, dragging.cameraState.pivot) < 1e-5)
    }

    @Test("A new drag stops the momentum of the last one")
    func newDragStopsMomentum() {
        let vc = controller(style: .turntable)
        vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
        #expect(simd_length(vc.cameraController.angularVelocity) > 0)
        vc.dispatch(.dragChanged(delta: SIMD2(0, 1), modifiers: []))
        #expect(vc.cameraController.angularVelocity == .zero)
        vc.dispatch(.dragEnded(velocity: .zero, modifiers: []))
    }

    @Test("A dynamic-pivot shift during momentum keeps the turn the momentum made")
    func pivotShiftKeepsMomentum() {
        let plain = controller(style: .turntable)
        let shifted = controller(style: .turntable)
        for vc in [plain, shifted] {
            vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
            vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
        }
        shifted.cameraController.adjustPivot(to: SIMD3(1, 2, 3), duration: 0.1)
        for _ in 0..<30 {
            _ = plain.cameraController.advance(by: 1.0 / 60)
            _ = shifted.cameraController.advance(by: 1.0 / 60)
        }
        #expect(angle(plain.cameraState.rotation, shifted.cameraState.rotation) < 1e-4)
        #expect(simd_distance(shifted.cameraState.pivot, SIMD3(1, 2, 3)) < 1e-4)
    }

    // MARK: - #198 First-person look-around

    @Test("First-person: a drag turns the view in place and the pivot moves with it")
    func firstPersonLooksAroundInPlace() {
        let vc = controller(style: .firstPerson)
        let start = vc.cameraState
        vc.dispatch(.dragChanged(delta: SIMD2(30, -20), modifiers: []))
        #expect(simd_distance(vc.cameraState.position, start.position) < 1e-4 * start.distance)
        #expect(simd_distance(vc.cameraState.pivot, start.pivot) > 0.01)
        #expect(abs(vc.cameraState.distance - start.distance) < 1e-6)
    }

    @Test("First-person: orbitCamera is mouse-look, drag right turns the view right")
    func firstPersonMouseLook() {
        let vc = controller(
            style: .firstPerson, view: .front,
            gestures: GestureConfiguration(dragRotation: .orbitCamera))
        let start = vc.cameraState
        vc.dispatch(.dragChanged(delta: SIMD2(20, 0), modifiers: []))
        #expect(simd_dot(vc.cameraState.viewDirection - start.viewDirection, start.rightVector) > 0)

        // And the default drags the scene: the view turns left.
        let touch = controller(style: .firstPerson, view: .front)
        touch.dispatch(.dragChanged(delta: SIMD2(20, 0), modifiers: []))
        #expect(
            simd_dot(touch.cameraState.viewDirection - start.viewDirection, start.rightVector) < 0)
    }

    // MARK: - Snap on release

    @Test("A slow release near an axis view snaps the orientation but keeps the projection")
    func snapKeepsProjection() {
        var config = ViewportConfiguration()
        var start = StandardView.front.cameraState()
        start.isOrthographic = false
        config.initialCameraState = start
        let vc = ViewportController(configuration: config)
        vc.dispatch(.dragChanged(delta: SIMD2(2, 0), modifiers: []))
        #expect(angle(vc.cameraState.rotation, start.rotation) > 1e-3)
        vc.dispatch(.dragEnded(velocity: SIMD2(50, 0), modifiers: []))
        _ = vc.cameraController.advance(by: 1)
        #expect(angle(vc.cameraState.rotation, start.rotation) < 1e-4)
        #expect(!vc.cameraState.isOrthographic)
    }

    // MARK: - Roll and zoom

    @Test("A positive roll turns the picture clockwise in every rotation style")
    func rollDirectionMatchesAcrossStyles() {
        for style in RotationStyle.allCases {
            let vc = controller(style: style, view: .front)
            let start = vc.cameraState
            let point = start.pivot + start.rightVector * (start.distance * 0.2)
            vc.dispatch(.rotateChanged(radians: 0.2))
            // Clockwise: the point right of the centre moves down.
            #expect(screen(point, vc.cameraState).y - screen(point, start).y < -1e-3)
            #expect(simd_dot(vc.cameraState.viewDirection, start.viewDirection) > 0.99999)
        }
    }

    @Test("Zoom toward the cursor stops sliding the view once the distance is at its limit")
    func zoomTowardStopsAtTheLimit() {
        let vc = controller(style: .turntable)
        let cam = vc.cameraController
        cam.zoomToward(factor: 1e6, cursorNormalized: SIMD2(0.5, 0.5), aspectRatio: 1)
        #expect(abs(vc.cameraState.distance - cam.minDistance) < 1e-6)
        let pivot = vc.cameraState.pivot
        cam.zoomToward(factor: 2, cursorNormalized: SIMD2(0.5, 0.5), aspectRatio: 1)
        #expect(simd_distance(vc.cameraState.pivot, pivot) < 1e-6)
    }

    @Test("First-person: the dynamic pivot leaves the camera where it is")
    func firstPersonSkipsDynamicPivot() {
        let vc = controller(style: .firstPerson)
        let start = vc.cameraState
        vc.updateDynamicPivot(bodies: [ViewportBody.box(id: "b", width: 4, height: 4, depth: 4)])
        #expect(!vc.cameraController.isAnimating)
        #expect(vc.cameraState.pivot == start.pivot)
    }
}
