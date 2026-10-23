// DragRotationTests.swift
// OCCTSwiftViewport Tests
//
// Which way an orbiting drag turns the model on screen. Each test drags, then projects a world
// point on the model's near side through the new camera and checks which way it moved. Before
// `GestureConfiguration.dragRotation`, a horizontal drag moved the camera (the model turned against
// the finger) while a vertical drag turned the model with it; and arcball composed its screen-space
// axis in world space, so a horizontal drag from the front view rolled the picture.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Drag rotation convention")
struct DragRotationTests {

    // MARK: - Helpers

    /// Screen position (x right, y up, in units of the focal length) of `point` seen by `state`.
    private func screen(_ point: SIMD3<Float>, _ state: CameraState) -> SIMD2<Float> {
        let c = state.viewMatrix * SIMD4<Float>(point, 1)
        return SIMD2(c.x / -c.z, c.y / -c.z)
    }

    private func controller(
        style: RotationStyle, view: StandardView,
        gestures: GestureConfiguration = .default
    ) -> ViewportController {
        var config = ViewportConfiguration()
        config.rotationStyle = style
        config.initialCameraState = view.cameraState()
        config.gestureConfiguration = gestures
        return ViewportController(configuration: config)
    }

    /// A model point that a drag along `axis` (0 = x, 1 = y) visibly moves.
    ///
    /// The point on the model's near side, straight toward the camera, except for a horizontal
    /// drag from the top view in the Z-up styles. That spins the view about the line of sight, so
    /// a point off the centre is the one that shows it: below the centre (the near edge of the
    /// turntable) for turntable, which spins about the pivot. First-person turns in place, so it
    /// spins about the point straight below the camera; from a view tilted a little short of
    /// straight down, that point sits below the screen centre and everything above it, the
    /// centre included, follows the drag. The point above the centre is the one that does.
    private func probePoint(
        _ state: CameraState, style: RotationStyle, view: StandardView, axis: Int
    )
        -> SIMD3<Float>
    {
        if axis == 0, view == .top, style != .arcball {
            let side: Float = style == .firstPerson ? 1 : -1
            return state.pivot + state.upVector * (side * state.distance * 0.3)
        }
        return state.pivot + (state.position - state.pivot) * 0.3
    }

    /// On-screen motion of the probe point for one drag of `delta` (points, y down).
    private func motion(
        style: RotationStyle, view: StandardView, delta: SIMD2<Float>,
        gestures: GestureConfiguration = .default
    ) -> SIMD2<Float> {
        let vc = controller(style: style, view: view, gestures: gestures)
        let start = vc.cameraState
        let axis = delta.x != 0 ? 0 : 1
        let point = probePoint(start, style: style, view: view, axis: axis)
        let before = screen(point, start)
        vc.dispatch(.dragChanged(delta: delta, modifiers: []))
        return screen(point, vc.cameraState) - before
    }

    nonisolated static let cases: [(RotationStyle, StandardView)] =
        RotationStyle.allCases.flatMap { style in
            [StandardView.front, .isometricFrontRight, .top, .right].map { (style, $0) }
        }

    // MARK: - Default: rotate the object

    @Test("Default: a drag right carries the model's near side right", arguments: cases)
    func dragRightMovesModelRight(style: RotationStyle, view: StandardView) {
        let m = motion(style: style, view: view, delta: SIMD2(10, 0))
        #expect(m.x > 1e-3)
        // Turns it sideways, not up or down (turntable from iso tilts it a hair).
        #expect(abs(m.y) < abs(m.x) * 0.05)
    }

    @Test("Default: a drag up carries the model's near side up", arguments: cases)
    func dragUpMovesModelUp(style: RotationStyle, view: StandardView) {
        let m = motion(style: style, view: view, delta: SIMD2(0, -10))
        #expect(m.y > 1e-3)
        #expect(abs(m.x) < abs(m.y) * 0.05)
    }

    // MARK: - Orbit camera

    @Test("orbitCamera reverses both axes", arguments: cases)
    func orbitCameraReversesBothAxes(style: RotationStyle, view: StandardView) {
        let gestures = GestureConfiguration(dragRotation: .orbitCamera)
        #expect(motion(style: style, view: view, delta: SIMD2(10, 0), gestures: gestures).x < -1e-3)
        #expect(
            motion(style: style, view: view, delta: SIMD2(0, -10), gestures: gestures).y < -1e-3)
    }

    // MARK: - Invert flags

    @Test("orbitDragSigns: the convention, then each invert flag flips its own axis")
    func orbitDragSigns() {
        typealias G = GestureConfiguration
        #expect(G().orbitDragSigns == SIMD2(1, 1))
        #expect(G(dragRotation: .orbitCamera).orbitDragSigns == SIMD2(-1, -1))
        #expect(G(invertOrbitHorizontal: true).orbitDragSigns == SIMD2(-1, 1))
        #expect(G(invertOrbitVertical: true).orbitDragSigns == SIMD2(1, -1))
        #expect(
            G(dragRotation: .orbitCamera, invertOrbitHorizontal: true).orbitDragSigns
                == SIMD2(1, -1))
    }

    @Test("invertOrbitHorizontal still flips only the horizontal axis")
    func invertHorizontalStillWorks() {
        let gestures = GestureConfiguration(invertOrbitHorizontal: true)
        let view = StandardView.isometricFrontRight
        #expect(
            motion(style: .turntable, view: view, delta: SIMD2(10, 0), gestures: gestures).x < 0)
        #expect(
            motion(style: .turntable, view: view, delta: SIMD2(0, -10), gestures: gestures).y > 0)
    }

    // MARK: - Defaults and presets

    @Test("Every preset rotates the object")
    func presetsRotateObject() {
        for preset in [GestureConfiguration.default, .blender, .fusion360, .visionOS] {
            #expect(preset.dragRotation == .rotateObject)
            #expect(!preset.invertOrbitHorizontal && !preset.invertOrbitVertical)
        }
    }

    // MARK: - Every orbit input agrees

    @Test("A two-finger drag bound to orbit turns the same way as the primary drag")
    func twoFingerOrbitMatches() {
        let gestures = GestureConfiguration(twoFingerDrag: .orbit)
        let a = controller(style: .turntable, view: .isometricFrontRight, gestures: gestures)
        let b = controller(style: .turntable, view: .isometricFrontRight, gestures: gestures)
        a.dispatch(.dragChanged(delta: SIMD2(12, -7), modifiers: []))
        b.dispatch(.twoFingerPanChanged(translation: SIMD2(12, -7)))
        #expect(simd_length(a.cameraState.rotation.vector - b.cameraState.rotation.vector) < 1e-6)
    }

    @Test("The navigation cube's orbit drag turns the same way as the viewport drag")
    func navigationCubeMatches() {
        let a = controller(style: .turntable, view: .isometricFrontRight)
        let b = controller(style: .turntable, view: .isometricFrontRight)
        a.dispatch(.dragChanged(delta: SIMD2(12, -7), modifiers: []))
        b.orbitDrag(delta: SIMD2(12, -7))
        #expect(simd_length(a.cameraState.rotation.vector - b.cameraState.rotation.vector) < 1e-6)
    }

    // MARK: - Momentum

    @Test(
        "Release momentum keeps turning the way the drag did",
        arguments: DragRotationConvention.allCases)
    func momentumFollowsDrag(convention: DragRotationConvention) {
        let gestures = GestureConfiguration(dragRotation: convention)
        let vc = controller(style: .turntable, view: .isometricFrontRight, gestures: gestures)
        let start = vc.cameraState
        let point = start.pivot + (start.position - start.pivot) * 0.3

        vc.dispatch(.dragChanged(delta: SIMD2(10, 0), modifiers: []))
        let afterDrag = vc.cameraState
        let dragMove = screen(point, afterDrag).x - screen(point, start).x

        vc.dispatch(.dragEnded(velocity: SIMD2(1500, 0), modifiers: []))
        _ = vc.cameraController.advance(by: 1.0 / 60)
        let coastMove = screen(point, vc.cameraState).x - screen(point, afterDrag).x
        vc.cameraController.setAngularVelocity(.zero)

        #expect(abs(dragMove) > 1e-3)
        #expect(coastMove * dragMove > 0)
    }

    // MARK: - Arcball frame

    @Test("Arcball: a horizontal drag from the front view turns the model, it does not roll it")
    func arcballDoesNotRollFromFront() {
        let vc = controller(style: .arcball, view: .front)
        let up = vc.cameraState.upVector
        vc.dispatch(.dragChanged(delta: SIMD2(30, 0), modifiers: []))
        // Turning about the screen's vertical axis leaves the camera's up vector where it was.
        #expect(simd_dot(vc.cameraState.upVector, up) > 0.9999)
        #expect(
            simd_dot(vc.cameraState.viewDirection, StandardView.front.cameraState().viewDirection)
                < 0.999)
    }
}
