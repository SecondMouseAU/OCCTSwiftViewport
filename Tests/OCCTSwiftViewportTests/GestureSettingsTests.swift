import Testing
import simd

@testable import OCCTSwiftViewport

#if os(macOS)
    import AppKit
#endif

/// Gesture and camera settings that used to be ignored (issue #136, M4 / L1).
@Suite("Gesture and camera settings")
@MainActor
struct GestureSettingsTests {

    private func controller(_ gestures: GestureConfiguration = .default) -> ViewportController {
        var config = ViewportConfiguration()
        config.gestureConfiguration = gestures
        return ViewportController(configuration: config)
    }

    /// A drag that every platform resolves to `action`: bare mouse on macOS, one finger elsewhere.
    private func dragAll(_ action: GestureAction, zoomSensitivity: Float = 1)
        -> GestureConfiguration
    {
        GestureConfiguration(
            zoomSensitivity: zoomSensitivity, singleFingerDrag: action, mouseDrag: action)
    }

    private func isClose(_ a: Float, _ b: Float, _ tolerance: Float = 1e-4) -> Bool {
        abs(a - b) <= tolerance * max(1, abs(b))
    }

    private func sameRotation(_ a: simd_quatf, _ b: simd_quatf) -> Bool {
        abs(simd_dot(simd_normalize(a), simd_normalize(b))) > 0.9999
    }

    // MARK: - Zoom sensitivity

    @Test("Pinch magnification is raised to zoomSensitivity")
    func pinchUsesZoomSensitivity() {
        let vc = controller(GestureConfiguration(zoomSensitivity: 2))
        let before = vc.cameraState.distance
        vc.dispatch(.pinchChanged(scale: 1.5))
        #expect(isClose(vc.cameraState.distance, before / 2.25))
    }

    @Test("Pinch-at-centre also applies zoomSensitivity")
    func pinchAtUsesZoomSensitivity() {
        let vc = controller(GestureConfiguration(zoomSensitivity: 0.5))
        let before = vc.cameraState.distance
        vc.dispatch(.pinchAtChanged(scale: 4, centerNDC: .zero, aspectRatio: 1))
        #expect(isClose(vc.cameraState.distance, before / 2))
    }

    @Test("Default sensitivity applies the pinch unchanged")
    func defaultPinchUnchanged() {
        let vc = controller()
        let before = vc.cameraState.distance
        vc.dispatch(.pinchChanged(scale: 1.5))
        #expect(isClose(vc.cameraState.distance, before / 1.5))
    }

    @Test("Drag-zoom follows zoomSensitivity")
    func dragZoomUsesZoomSensitivity() {
        let vc = controller(dragAll(.zoom, zoomSensitivity: 2))
        let before = vc.cameraState.distance
        vc.dispatch(.dragChanged(delta: SIMD2(0, 10), modifiers: []))
        let expected = before / exp(10 * ViewportController.dragZoomRate * 2)
        #expect(isClose(vc.cameraState.distance, expected))
    }

    @Test("A fast drag-zoom out zooms out instead of collapsing to minDistance")
    func fastDragZoomOutStaysPositive() {
        let vc = controller(dragAll(.zoom))
        let before = vc.cameraState.distance
        // The old 1 + 0.02·dy factor went negative here, and the clamp then snapped to minDistance.
        vc.dispatch(.dragChanged(delta: SIMD2(0, -100), modifiers: []))
        #expect(vc.cameraState.distance > before)
    }

    // MARK: - Gesture mapping

    @Test("twoFingerDrag = .orbit orbits instead of panning")
    func twoFingerOrbit() {
        let vc = controller(GestureConfiguration(twoFingerDrag: .orbit))
        let rotation = vc.cameraState.rotation
        let pivot = vc.cameraState.pivot
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(40, 20)))
        #expect(!sameRotation(vc.cameraState.rotation, rotation))
        #expect(vc.cameraState.pivot == pivot)
    }

    @Test("twoFingerDrag = .none ignores the gesture")
    func twoFingerNone() {
        let vc = controller(GestureConfiguration(twoFingerDrag: .none))
        let before = vc.cameraState
        vc.dispatch(.twoFingerPanChanged(translation: SIMD2(40, 20)))
        vc.dispatch(.twoFingerPanEnded(velocity: SIMD2(500, 0)))
        #expect(vc.cameraState == before)
        #expect(vc.cameraController.panVelocity == .zero)
    }

    @Test("A pinch mapped to .none is ignored")
    func pinchNone() {
        let vc = controller(GestureConfiguration(pinchGesture: .none, trackpadPinch: .none))
        let before = vc.cameraState.distance
        vc.dispatch(.pinchChanged(scale: 1.5))
        vc.dispatch(.pinchAtChanged(scale: 1.5, centerNDC: .zero, aspectRatio: 1))
        #expect(vc.cameraState.distance == before)
    }

    @Test("scrollWheel = .none ignores scrolling")
    func scrollNone() {
        let vc = controller(GestureConfiguration(scrollWheel: .none))
        let before = vc.cameraState.distance
        vc.dispatch(.scroll(delta: 3, cursorNDC: .zero, aspectRatio: 1))
        #expect(vc.cameraState.distance == before)
    }

    @Test("Double-tap and double-click default to .resetView")
    func doubleTapDefaults() {
        #expect(GestureConfiguration.default.doubleTap == .resetView)
        #expect(GestureConfiguration.default.doubleClick == .resetView)
    }

    @Test("A double-tap mapped to .none leaves the camera alone")
    func doubleTapNone() {
        let vc = controller(GestureConfiguration(doubleTap: .none, doubleClick: .none))
        vc.dispatch(.dragChanged(delta: SIMD2(60, 0), modifiers: []))
        let before = vc.cameraState
        vc.dispatch(.tap(ndc: .zero, count: 2))
        #expect(!vc.cameraController.isAnimating)
        #expect(vc.cameraState == before)
    }

    @Test("A .focusOnPoint double-tap moves the pivot onto the surface under the tap")
    func doubleTapFocusOnPoint() {
        let vc = controller(
            GestureConfiguration(doubleTap: .focusOnPoint, doubleClick: .focusOnPoint))
        vc.cameraController.animateTo(
            CameraState(rotation: StandardView.front.rotation, distance: 10, pivot: .zero),
            duration: 0)
        vc.inputSceneBodies = [.box(id: "box", width: 2, height: 2, depth: 2)]
        vc.dispatch(.tap(ndc: .zero, count: 2))
        _ = vc.cameraController.advance(by: 1)
        // Looking at the box centre, the nearest surface is a face 1 unit from the centre.
        #expect(isClose(simd_length(vc.cameraState.pivot), 1, 1e-3))
    }

    @Test("A .focusOnPoint double-tap on empty space does nothing")
    func doubleTapFocusMiss() {
        let vc = controller(
            GestureConfiguration(doubleTap: .focusOnPoint, doubleClick: .focusOnPoint))
        let before = vc.cameraState
        vc.dispatch(.tap(ndc: .zero, count: 2))
        #expect(!vc.cameraController.isAnimating)
        #expect(vc.cameraState == before)
    }

    // MARK: - Reset

    @Test("Double-tap reset returns to configuration.initialCameraState")
    func doubleTapResetsToInitialState() {
        var config = ViewportConfiguration()
        config.initialCameraState = .top
        let vc = ViewportController(configuration: config)
        vc.dispatch(.dragChanged(delta: SIMD2(60, 30), modifiers: []))
        vc.dispatch(.tap(ndc: .zero, count: 2))
        _ = vc.cameraController.advance(by: 1)
        #expect(sameRotation(vc.cameraState.rotation, CameraState.top.rotation))
        #expect(isClose(vc.cameraState.distance, CameraState.top.distance))
    }

    @Test("CameraController.reset returns to its initial state, not CameraState()")
    func controllerResetsToHomeState() {
        let camera = CameraController(initialState: .isometric)
        camera.orbit(deltaX: 80, deltaY: 40)
        camera.reset(animated: false)
        #expect(sameRotation(camera.cameraState.rotation, CameraState.isometric.rotation))
    }

    // MARK: - Turntable

    @Test(
        "The first turntable orbit from any preset view is continuous",
        arguments: StandardView.allCases.map { $0.cameraState() } + [CameraState()])
    func firstOrbitIsContinuous(state: CameraState) {
        let camera = CameraController(initialState: state)
        camera.orbit(deltaX: 1, deltaY: 1)
        // One point of drag turns the camera by about orbitSensitivity, not a snap to another view.
        #expect(sameRotation(camera.cameraState.rotation, state.rotation))
        #expect(camera.cameraState.rotation != state.rotation)
    }

    @Test("A turntable orbit right after reset or an animation is continuous")
    func orbitAfterResetIsContinuous() {
        let camera = CameraController(initialState: .isometric)
        camera.orbit(deltaX: 120, deltaY: -80)
        camera.reset(animated: false)
        camera.orbit(deltaX: 1, deltaY: 1)
        #expect(sameRotation(camera.cameraState.rotation, CameraState.isometric.rotation))

        camera.animateTo(StandardView.front, duration: 0)
        let front = camera.cameraState.rotation
        camera.orbit(deltaX: 1, deltaY: 1)
        #expect(sameRotation(camera.cameraState.rotation, front))
    }

    @Test("Turntable tilt is unclamped: it carries on over the pole")
    func turntableTiltIsUnclamped() {
        let camera = CameraController(initialState: .isometric)
        let back = { camera.cameraState.rotation.act(SIMD3<Float>(0, 0, 1)) }
        #expect(back().z > 0)  // camera above the model
        for _ in 0..<4 { camera.orbit(deltaX: 0, deltaY: (.pi / 4) / camera.orbitSensitivity) }
        // A π tilt from above ends below the model; a clamped turntable would stop at the top.
        #expect(back().z < 0)
    }

    // MARK: - Defaults

    @Test("CameraController defaults match GestureConfiguration.default")
    func controllerDefaultsMatchGestureDefaults() {
        let camera = CameraController()
        let gestures = GestureConfiguration.default
        #expect(camera.orbitSensitivity == gestures.orbitSensitivity)
        #expect(camera.panSensitivity == gestures.panSensitivity)
        #expect(camera.zoomSensitivity == gestures.zoomSensitivity)
        #expect(camera.scrollZoomSensitivity == gestures.scrollZoomSensitivity)
        #expect(camera.minPanSpeed == gestures.minPanSpeed)
        #expect(camera.dampingFactor == gestures.dampingFactor)
        #expect(camera.enableInertia == gestures.enableInertia)
    }

    // MARK: - Frame rate

    @Test("The camera timer rate follows ViewportConfiguration.preferredFramesPerSecond")
    func frameRateFlowsToCamera() {
        #expect(ViewportConfiguration().preferredFramesPerSecond == 120)
        var config = ViewportConfiguration()
        config.preferredFramesPerSecond = 60
        #expect(
            ViewportController(configuration: config).cameraController.preferredFramesPerSecond
                == 60)
    }

    @Test("At 60 Hz one tick keeps the historical per-frame damping")
    func inertiaAt60HzUnchanged() {
        let camera = CameraController()
        camera.setPanVelocity(SIMD2(10, 0))
        _ = camera.advance(by: 1.0 / 60.0)
        #expect(isClose(camera.panVelocity.x, 10 * (1 - camera.dampingFactor)))
    }

    @Test("Inertia decays at the same rate whatever the tick rate")
    func inertiaIsFrameRateIndependent() {
        let at60 = CameraController()
        let at120 = CameraController()
        for camera in [at60, at120] {
            camera.setPanVelocity(SIMD2(10, 0))
            camera.setAngularVelocity(SIMD2(0, 5))
        }
        for _ in 0..<6 { _ = at60.advance(by: 1.0 / 60.0) }
        for _ in 0..<12 { _ = at120.advance(by: 1.0 / 120.0) }
        #expect(isClose(at60.panVelocity.x, at120.panVelocity.x))
        #expect(isClose(at60.angularVelocity.y, at120.angularVelocity.y))

        // A coalesced tick (one 1/20 s step) decays as much as three 1/60 s ticks.
        let coalesced = CameraController()
        coalesced.setPanVelocity(SIMD2(10, 0))
        _ = coalesced.advance(by: 3.0 / 60.0)
        let stepped = CameraController()
        stepped.setPanVelocity(SIMD2(10, 0))
        for _ in 0..<3 { _ = stepped.advance(by: 1.0 / 60.0) }
        #expect(isClose(coalesced.panVelocity.x, stepped.panVelocity.x))
    }

    // MARK: - macOS double-click

    #if os(macOS)
        @Test("macOS: mouse down forwards the click count, so double-clicks reach the router")
        func macClickCountForwarded() throws {
            let view = ScrollCaptureMTKView()
            var counts: [Int] = []
            view.onMouseDown = { _, _, count in counts.append(count) }
            for clickCount in [1, 2] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [],
                        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                        clickCount: clickCount, pressure: 1))
                view.mouseDown(with: event)
                view.mouseUp(with: event)
            }
            #expect(counts == [1, 2])
        }
    #endif
}
