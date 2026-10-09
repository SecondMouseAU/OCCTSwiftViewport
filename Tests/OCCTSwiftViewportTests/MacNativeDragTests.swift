#if os(macOS)
    import AppKit
    import Testing

    @testable import OCCTSwiftViewport

    @Suite("macOS native drag handling (#127)")
    @MainActor
    struct MacNativeDragTests {

        private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, t: TimeInterval)
            -> NSEvent
        {
            NSEvent.mouseEvent(
                with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: t,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        @Test("mouse down, drag, up dispatches incremental y-down deltas and an end velocity")
        func dragSequence() {
            let view = ScrollCaptureMTKView()
            var deltas: [SIMD2<Float>] = []
            var ended: SIMD2<Float>?
            view.onDrag = { delta, _ in deltas.append(delta) }
            view.onDragEnd = { velocity, _ in ended = velocity }

            view.mouseDown(with: mouse(.leftMouseDown, 100, 100, t: 0))
            view.mouseDragged(with: mouse(.leftMouseDragged, 110, 100, t: 0.02))
            view.mouseDragged(with: mouse(.leftMouseDragged, 110, 90, t: 0.04))
            view.mouseUp(with: mouse(.leftMouseUp, 110, 90, t: 0.05))

            #expect(deltas == [SIMD2(10, 0), SIMD2(0, 10)])  // window y-up -> y-down
            #expect(ended != nil)
            #expect((ended?.x ?? 0) > 0)
        }

        @Test("a click without movement is not a drag")
        func clickIsNotDrag() {
            let view = ScrollCaptureMTKView()
            var dragged = false
            var ended = false
            view.onDrag = { _, _ in dragged = true }
            view.onDragEnd = { _, _ in ended = true }

            view.mouseDown(with: mouse(.leftMouseDown, 5, 5, t: 0))
            view.mouseUp(with: mouse(.leftMouseUp, 5, 5, t: 0.1))

            #expect(!dragged)
            #expect(!ended)
        }
    }
#endif
