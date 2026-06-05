import Testing
import simd
@testable import OCCTSwiftViewport

@MainActor
@Suite("Viewport input router")
struct ViewportInputRouterTests {

    // MARK: - Observation

    @Test("onInputEvent fires with the exact event for every dispatch")
    func observerReceivesEvents() {
        let controller = ViewportController()
        var seen: [ViewportInputEvent] = []
        controller.onInputEvent = { seen.append($0) }

        let events: [ViewportInputEvent] = [
            .dragChanged(delta: SIMD2<Float>(5, 0), modifiers: []),
            .dragEnded(velocity: .zero, modifiers: []),
            .pinchChanged(scale: 1.1),
            .pinchEnded,
            .rotateChanged(radians: 0.2),
            .rotateEnded,
            .twoFingerPanChanged(translation: SIMD2<Float>(3, 4)),
            .twoFingerPanEnded(velocity: .zero),
            .scroll(delta: 1, cursorNDC: .zero, aspectRatio: 1),
            .tap(ndc: .zero, count: 1)
        ]
        for e in events { controller.dispatch(e) }
        #expect(seen == events)
    }

    // MARK: - Interpretation

    @Test("Primary drag with default config orbits (rotation changes)")
    func dragOrbits() {
        let controller = ViewportController()
        let before = controller.cameraState.rotation.vector
        controller.dispatch(.dragChanged(delta: SIMD2<Float>(60, 0), modifiers: []))
        #expect(controller.cameraState.rotation.vector != before)
        #expect(controller.activeInputDragMode == .orbit)
    }

    @Test("Pinch zooms (distance changes)")
    func pinchZooms() {
        let controller = ViewportController()
        let before = controller.cameraState.distance
        controller.dispatch(.pinchChanged(scale: 1.5))
        #expect(controller.cameraState.distance != before)
    }

    @Test("Two-finger pan moves the pivot")
    func twoFingerPans() {
        let controller = ViewportController()
        let before = controller.cameraState.pivot
        controller.dispatch(.twoFingerPanChanged(translation: SIMD2<Float>(40, 20)))
        #expect(controller.cameraState.pivot != before)
    }

    @Test("Scroll zooms (distance changes)")
    func scrollZooms() {
        let controller = ViewportController()
        let before = controller.cameraState.distance
        controller.dispatch(.scroll(delta: 3, cursorNDC: .zero, aspectRatio: 1.0))
        #expect(controller.cameraState.distance != before)
    }

    @Test("dragEnded resets the active drag mode to orbit")
    func dragEndedResetsMode() {
        let controller = ViewportController()
        // Force a non-orbit mode first via a pan-resolving drag where possible.
        controller.dispatch(.dragChanged(delta: SIMD2<Float>(10, 0), modifiers: []))
        controller.dispatch(.dragEnded(velocity: .zero, modifiers: []))
        #expect(controller.activeInputDragMode == .orbit)
    }

    @Test("Single tap routes no camera change; double tap is handled")
    func tapRouting() {
        let controller = ViewportController()
        let before = controller.cameraState.rotation.vector
        controller.dispatch(.tap(ndc: .zero, count: 1))
        // Single tap performs no camera action (picking is a separate path).
        #expect(controller.cameraState.rotation.vector == before)
        // Double tap triggers reset (animated) — just exercise the path safely.
        controller.dispatch(.tap(ndc: .zero, count: 2))
    }

    #if os(macOS)
    @Test("macOS: modifier resolves drag action via GestureConfiguration")
    func macModifierResolution() {
        let controller = ViewportController()  // default: shift = pan
        let pivotBefore = controller.cameraState.pivot
        controller.dispatch(.dragChanged(delta: SIMD2<Float>(30, 10), modifiers: .shift))
        #expect(controller.activeInputDragMode == .pan)
        #expect(controller.cameraState.pivot != pivotBefore)
    }
    #endif
}
