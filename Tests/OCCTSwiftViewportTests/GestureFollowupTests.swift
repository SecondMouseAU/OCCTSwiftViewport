// GestureFollowupTests.swift
// OCCTSwiftViewport Tests
//
// Issue #204: interrupted drags never snap to an axis view, a pinch zooms toward where the
// fingers are now, and the measurement overlay projects with the renderer's fitted planes.
// The pinch tests project a world point to screen points before and after each step and check
// that it stayed under the fingers.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Gesture follow-ups (#204)")
struct GestureFollowupTests {

    private static let viewSize = CGSize(width: 800, height: 600)

    private func controller(
        state: CameraState = StandardView.isometricFrontRight.cameraState(distance: 12),
        gestures: GestureConfiguration = .default
    ) -> ViewportController {
        var config = ViewportConfiguration()
        config.rotationStyle = .turntable
        config.initialCameraState = state
        config.gestureConfiguration = gestures
        let vc = ViewportController(configuration: config)
        vc.updateViewportSize(Self.viewSize)
        return vc
    }

    /// The front view turned 1° off its axis, inside the 3° slow-release snap.
    private var nearFront: CameraState {
        var state = StandardView.front.cameraState(distance: 12)
        state.rotation = simd_normalize(
            simd_quatf(angle: 1 * .pi / 180, axis: SIMD3(0, 0, 1)) * state.rotation)
        return state
    }

    /// Where `point` appears, in view points from the top-left (y down).
    private func screenPoint(_ point: SIMD3<Float>, _ state: CameraState) -> SIMD2<Float> {
        let size = Self.viewSize
        let clip =
            state.projectionMatrix(aspectRatio: Float(size.width / size.height))
            * state.viewMatrix * SIMD4(point, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        return SIMD2(
            (ndc.x + 1) / 2 * Float(size.width), (1 - ndc.y) / 2 * Float(size.height))
    }

    /// The world point at the pivot's depth under `screen` (view points, top-left origin).
    private func pivotDepthPoint(under screen: CGPoint, _ state: CameraState) -> SIMD3<Float> {
        let ndc = TouchPinchRotate.ndc(screen, viewSize: Self.viewSize)
        let ray = Ray.fromCamera(
            ndc: ndc, cameraState: state,
            aspectRatio: Float(Self.viewSize.width / Self.viewSize.height))
        let t =
            simd_dot(state.pivot - ray.origin, state.viewDirection)
            / simd_dot(ray.direction, state.viewDirection)
        return ray.origin + ray.direction * t
    }

    // MARK: - Interrupted drags do not snap (item 6)

    @Test("A slow release near an axis view still snaps (control)")
    func slowReleaseSnaps() {
        let vc = controller(state: nearFront)
        vc.dispatch(.dragChanged(delta: SIMD2(0.5, 0), modifiers: []))
        vc.dispatch(.dragEnded(velocity: .zero, modifiers: []))
        #expect(vc.cameraController.isAnimating)
    }

    @Test("An interrupted one-finger drag near an axis view does not snap")
    func interruptedDragDoesNotSnap() {
        let vc = controller(state: nearFront)
        var seen: [ViewportInputEvent] = []
        vc.onInputEvent = { seen.append($0) }
        vc.dispatch(.dragChanged(delta: SIMD2(0.5, 0), modifiers: []))
        let dragged = vc.cameraState
        vc.interruptDrag()
        #expect(!vc.cameraController.isAnimating)
        #expect(!vc.cameraController.isOrbitDragActive)
        #expect(vc.cameraController.angularVelocity == .zero)
        _ = vc.cameraController.advance(by: 0.5)
        #expect(vc.cameraState == dragged)
        #expect(vc.inputDragPointer == nil)
        // An input inspector still sees the drag end.
        #expect(seen.last == .dragEnded(velocity: .zero, modifiers: []))
    }

    @Test("A cancelled two-finger orbit near an axis view does not snap")
    func interruptedTwoFingerDragDoesNotSnap() {
        let vc = controller(state: nearFront, gestures: GestureConfiguration(twoFingerDrag: .orbit))
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(0.5, 0)))
        let dragged = vc.cameraState
        vc.interruptTwoFingerDrag()
        #expect(!vc.cameraController.isAnimating)
        #expect(!vc.twoFingerDragActive)
        #expect(vc.twoFingerDragPointer == nil)
        _ = vc.cameraController.advance(by: 0.5)
        #expect(vc.cameraState == dragged)
        // The next two-finger drag starts fresh.
        vc.setTwoFingerDragOrigin(offsetFromCenter: SIMD2(5, 6))
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(1, 1)))
        #expect(vc.twoFingerDragPointer == SIMD2(6, 7))
        vc.dispatch(.twoFingerPanEnded(velocity: .zero))
    }

    @Test("A drag whose end never came is interrupted, and the next drag keeps its own origin")
    func arbiterStepKeepsNewOrigin() {
        let vc = controller(state: nearFront)
        var arbiter = TouchDragArbiter()
        let size = Self.viewSize
        // Mirrors MetalViewportView.apply(_:): interrupt, then the origin, then the events.
        func apply(_ step: TouchDragArbiter.Step) {
            if step.interruptsDrag { vc.interruptDrag() }
            if let origin = step.dragOrigin { vc.setDragOrigin(offsetFromCenter: origin) }
            for event in step.events { vc.dispatch(event) }
        }
        apply(
            arbiter.dragChanged(
                start: CGPoint(x: 400, y: 300), translation: CGSize(width: 1, height: 0),
                viewSize: size))
        // No end: the gesture was cancelled. A new drag starts near the top-left corner.
        apply(
            arbiter.dragChanged(
                start: CGPoint(x: 100, y: 50), translation: CGSize(width: 2, height: 0),
                viewSize: size))
        #expect(!vc.cameraController.isAnimating)
        #expect(vc.inputDragPointer == SIMD2(-298, -250))
        apply(arbiter.dragEnded(velocity: CGSize(width: 900, height: 0)))
    }

    // MARK: - Pinch follows the fingers (item 2)

    @Test("Each pinch step zooms toward the fingers' current centroid", arguments: [false, true])
    func pinchFollowsMovingCentroid(orthographic: Bool) throws {
        var state = StandardView.isometricFrontRight.cameraState(distance: 12)
        state.isOrthographic = orthographic
        state.orthographicScale = 7
        let vc = controller(state: state)
        // The fingers spread while drifting right and down.
        let centroids = [
            CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 230), CGPoint(x: 390, y: 270),
            CGPoint(x: 450, y: 320),
        ]
        for centroid in centroids {
            let before = vc.cameraState
            let point = pivotDepthPoint(under: centroid, before)
            let event = try #require(
                TouchPinchRotate.pinchStep(scale: 1.15, centroid: centroid, viewSize: Self.viewSize)
            )
            vc.dispatch(event)
            let moved = screenPoint(point, vc.cameraState)
            let expected = SIMD2(Float(centroid.x), Float(centroid.y))
            #expect(simd_distance(moved, expected) < 0.5, "\(centroid): \(moved)")
        }
    }

    @Test("A pinch step converts the centroid to NDC with the view's aspect")
    func pinchStepEvent() throws {
        let event = try #require(
            TouchPinchRotate.pinchStep(
                scale: 1.25, centroid: CGPoint(x: 600, y: 150), viewSize: Self.viewSize))
        #expect(
            event == .pinchAtChanged(scale: 1.25, centerNDC: SIMD2(0.5, 0.5), aspectRatio: 4 / 3))
        #expect(
            TouchPinchRotate.pinchStep(scale: 0, centroid: .zero, viewSize: Self.viewSize) == nil)
        #expect(TouchPinchRotate.pinchStep(scale: 1.1, centroid: .zero, viewSize: .zero) == nil)
        #expect(TouchPinchRotate.ndc(CGPoint(x: 400, y: 300), viewSize: Self.viewSize) == .zero)
        #expect(TouchPinchRotate.ndc(.zero, viewSize: Self.viewSize) == SIMD2(-1, 1))
    }

    // MARK: - Measurement overlay planes (item 3)

    @Test("The overlay projects with the renderer's fitted planes, else the wide default")
    func overlayUsesFittedPlanes() {
        let state = StandardView.isometricFrontRight.cameraState(distance: 12)
        let fitted = MeasurementOverlay.viewProjection(
            cameraState: state, aspectRatio: 4 / 3, clipPlanes: (near: 5, far: 40))
        #expect(
            fitted == state.projectionMatrix(aspectRatio: 4 / 3, near: 5, far: 40)
                * state.viewMatrix)
        let fallback = MeasurementOverlay.viewProjection(
            cameraState: state, aspectRatio: 4 / 3, clipPlanes: nil)
        let wide = state.clipPlanes(sceneBounds: nil)
        #expect(
            fallback == state.projectionMatrix(aspectRatio: 4 / 3, near: wide.near, far: wide.far)
                * state.viewMatrix)
        // The planes set depth only: a point lands at the same screen position either way, and
        // inside the fitted depth range.
        let point = SIMD3<Float>(0.7, -0.4, 1.1)
        let a = ProjectionUtility.worldToScreen(
            point: point, vpMatrix: fitted, viewportSize: Self.viewSize)
        let b = ProjectionUtility.worldToScreen(
            point: point, vpMatrix: fallback, viewportSize: Self.viewSize)
        #expect(a != nil && b != nil)
        if let a, let b { #expect(hypot(a.x - b.x, a.y - b.y) < 1e-3) }
        let depth = ProjectionUtility.worldToNDC(point: point, vpMatrix: fitted)?.z ?? -1
        #expect(depth > 0 && depth < 1)
    }
}
