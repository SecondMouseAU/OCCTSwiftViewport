// PivotLineOfSightTests.swift
// OCCTSwiftViewport Tests
//
// Issue #204 item 5: the dynamic pivot runs after every gesture, and moving it to the off-axis
// scene centre carried the camera across with it, so a released two-finger pan slid back to the
// model. The pivot now only slides along the line of sight. These tests pan, release, run the
// pivot update and tick its animation to completion, then check that the eye and the forward
// vector did not move.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Dynamic pivot stays on the line of sight (#204)")
struct PivotLineOfSightTests {

    private static let viewSize = CGSize(width: 800, height: 600)

    /// Which branch of `PivotStrategy` the update takes.
    enum Branch: CaseIterable {
        /// The camera is far out, so the pivot goes to the scene centre's depth.
        case sceneCentre
        /// The camera is close in, so the pivot goes to the view-centre raycast hit.
        case raycast

        var zoomThreshold: Float {
            switch self {
            // distance 12 / diagonal 6.9 = 1.7, well past 0.5 (zoomed out).
            case .sceneCentre: return 0.5
            // 1.7 is well under 3 (zoomed in), with the camera still outside the box.
            case .raycast: return 3
            }
        }
    }

    private func controller(orthographic: Bool, branch: Branch) -> ViewportController {
        var config = ViewportConfiguration()
        config.rotationStyle = .turntable
        var state = StandardView.isometricFrontRight.cameraState(distance: 12)
        state.isOrthographic = orthographic
        state.orthographicScale = 7
        config.initialCameraState = state
        config.dynamicPivotConfiguration = DynamicPivotConfiguration(
            zoomThreshold: branch.zoomThreshold)
        let vc = ViewportController(configuration: config)
        vc.updateViewportSize(Self.viewSize)
        return vc
    }

    /// A 4-unit box whose centre is off the initial pivot, in depth as well as across the view.
    private var scene: [ViewportBody] {
        var box = ViewportBody.box(id: "b", width: 4, height: 4, depth: 4)
        box.transform = simd_float4x4(
            columns: (
                SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0.4, -0.3, -1.5, 1)
            ))
        return [box]
    }

    /// Pans by `total` points in two-finger increments, then releases with `velocity`.
    private func panAndRelease(
        _ vc: ViewportController, by total: SIMD2<Float>, velocity: SIMD2<Float> = .zero
    ) {
        for _ in 0..<8 {
            vc.dispatch(.twoFingerPanChanged(translation: total / 8))
        }
        vc.dispatch(.twoFingerPanEnded(velocity: velocity))
    }

    /// Ticks the camera at 60 Hz until nothing moves, or one simulated second has passed.
    private func settle(_ vc: ViewportController) {
        for _ in 0..<60 where vc.cameraController.advance(by: 1.0 / 60) {}
    }

    private func expectViewUnchanged(
        _ before: CameraState, _ after: CameraState, _ label: String
    ) {
        #expect(
            simd_distance(after.position, before.position) < 1e-3,
            "\(label): eye moved from \(before.position) to \(after.position)")
        #expect(
            simd_dot(after.viewDirection, before.viewDirection) > 0.999999,
            "\(label): forward turned")
        #expect(simd_dot(after.upVector, before.upVector) > 0.999999, "\(label): up turned")
    }

    @Test(
        "Releasing a pan and running the dynamic pivot leaves the eye and forward vector alone",
        arguments: [false, true], Branch.allCases)
    func panReleaseKeepsView(orthographic: Bool, branch: Branch) {
        let vc = controller(orthographic: orthographic, branch: branch)
        panAndRelease(vc, by: SIMD2(40, -25))
        settle(vc)
        let released = vc.cameraState
        vc.updateDynamicPivot(bodies: scene)
        settle(vc)
        let label = "\(orthographic ? "ortho" : "persp") \(branch)"
        expectViewUnchanged(released, vc.cameraState, label)
        // The pivot moved, and only along the line of sight.
        #expect(
            abs(vc.cameraState.distance - released.distance) > 0.01, "\(label): pivot never moved")
        let offAxis = simd_cross(
            vc.cameraState.pivot - released.position, released.viewDirection)
        #expect(simd_length(offAxis) < 1e-3, "\(label): pivot left the line of sight")
    }

    @Test("Zoomed out, the pivot goes to the scene centre's depth, not to the centre itself")
    func sceneCentreBranchUsesDepthOnly() {
        let vc = controller(orthographic: false, branch: .sceneCentre)
        panAndRelease(vc, by: SIMD2(150, 90))
        let released = vc.cameraState
        vc.updateDynamicPivot(bodies: scene)
        settle(vc)
        let centre = SIMD3<Float>(0.4, -0.3, -1.5)
        let forward = released.viewDirection
        #expect(
            abs(
                simd_dot(vc.cameraState.pivot - released.position, forward)
                    - simd_dot(centre - released.position, forward)) < 1e-3)
        // The pan put the pivot off the centre, and it stays off it.
        #expect(simd_distance(vc.cameraState.pivot, centre) > 1)
    }

    @Test("Zoomed in, the pivot goes to the view-centre raycast hit on the model")
    func raycastBranchUsesHit() {
        let vc = controller(orthographic: false, branch: .raycast)
        vc.updateDynamicPivot(bodies: scene)
        settle(vc)
        // The hit is on the box's surface: one coordinate at a face, relative to its centre.
        let local = vc.cameraState.pivot - SIMD3<Float>(0.4, -0.3, -1.5)
        #expect(abs(simd_reduce_max(simd_abs(local)) - 2) < 1e-3, "pivot \(local) not on a face")
    }

    @Test(
        "A pivot update during pan momentum moves the camera only as the momentum does",
        arguments: Branch.allCases)
    func pivotDuringPanMomentum(branch: Branch) {
        // Orthographic, so a pan's world speed does not depend on the distance the pivot
        // update changes: the camera must end exactly where the momentum alone takes it.
        let withPivot = controller(orthographic: true, branch: branch)
        let alone = controller(orthographic: true, branch: branch)
        for vc in [withPivot, alone] {
            panAndRelease(vc, by: SIMD2(30, 10), velocity: SIMD2(400, -150))
        }
        withPivot.updateDynamicPivot(bodies: scene)
        settle(withPivot)
        settle(alone)
        expectViewUnchanged(alone.cameraState, withPivot.cameraState, "\(branch)")
        #expect(abs(withPivot.cameraState.distance - alone.cameraState.distance) > 0.01)
    }

    @Test("A pivot update during orbit momentum leaves the momentum's rotation alone")
    func pivotDuringOrbitMomentum() {
        let withPivot = controller(orthographic: false, branch: .sceneCentre)
        let alone = controller(orthographic: false, branch: .sceneCentre)
        for vc in [withPivot, alone] {
            vc.dispatch(.dragChanged(delta: SIMD2(20, 0), modifiers: []))
            vc.dispatch(.dragEnded(velocity: SIMD2(1200, 0), modifiers: []))
        }
        withPivot.updateDynamicPivot(bodies: scene)
        for _ in 0..<60 {
            _ = withPivot.cameraController.advance(by: 1.0 / 60)
            _ = alone.cameraController.advance(by: 1.0 / 60)
            #expect(
                simd_dot(withPivot.cameraState.viewDirection, alone.cameraState.viewDirection)
                    > 0.999999)
        }
        // Every tick's pivot is on the line of sight from wherever the eye then is: the pivot
        // depth ends at the scene centre's depth measured when the update ran.
        #expect(abs(withPivot.cameraState.distance - alone.cameraState.distance) > 0.01)
    }

    @Test("A pivot behind the camera is ignored")
    func behindCameraIgnored() {
        let camera = CameraController(initialState: CameraState(distance: 5))
        let start = camera.cameraState
        camera.slidePivotAlongLineOfSight(
            toDepthOf: start.position - start.viewDirection * 3, duration: 0)
        #expect(camera.cameraState == start)
    }

    @Test("The slide keeps the distance within its limits without moving the eye")
    func slideClampsDistance() {
        let camera = CameraController(initialState: CameraState(distance: 5))
        camera.minDistance = 2
        let start = camera.cameraState
        camera.slidePivotAlongLineOfSight(
            toDepthOf: start.position + start.viewDirection * 0.5, duration: 0)
        #expect(camera.cameraState.distance == 2)
        #expect(simd_distance(camera.cameraState.position, start.position) < 1e-5)
    }

    @Test("A slide that starts while another animation runs is skipped")
    func slideSkippedWhileAnimating() {
        let camera = CameraController(initialState: CameraState(distance: 5))
        camera.animateTo(StandardView.top, duration: 0.3)
        let target = camera.cameraState.position + camera.cameraState.viewDirection * 9
        camera.slidePivotAlongLineOfSight(toDepthOf: target, duration: 0.15)
        for _ in 0..<60 { _ = camera.advance(by: 1.0 / 60) }
        #expect(abs(camera.cameraState.distance - 5) < 1e-4)
    }
}
