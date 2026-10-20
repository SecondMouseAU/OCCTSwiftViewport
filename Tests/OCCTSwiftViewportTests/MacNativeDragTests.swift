#if os(macOS)
    import AppKit
    import Testing

    @testable import OCCTSwiftViewport

    @Suite("macOS native drag handling (#127)")
    @MainActor
    struct MacNativeDragTests {

        private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat, t: TimeInterval)
            throws -> NSEvent
        {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: t,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        @Test("mouse down, drag, up dispatches incremental y-down deltas and an end velocity")
        func dragSequence() throws {
            let view = ScrollCaptureMTKView()
            var deltas: [SIMD2<Float>] = []
            var ended: SIMD2<Float>?
            view.onDrag = { delta, _ in deltas.append(delta) }
            view.onDragEnd = { velocity, _ in ended = velocity }

            view.mouseDown(with: try mouse(.leftMouseDown, 100, 100, t: 0))
            view.mouseDragged(with: try mouse(.leftMouseDragged, 110, 100, t: 0.02))
            view.mouseDragged(with: try mouse(.leftMouseDragged, 110, 90, t: 0.04))
            view.mouseUp(with: try mouse(.leftMouseUp, 110, 90, t: 0.05))

            #expect(deltas == [SIMD2(10, 0), SIMD2(0, 10)])  // window y-up -> y-down
            #expect(ended != nil)
            #expect((ended?.x ?? 0) > 0)
        }

        @Test("a click without movement is not a drag")
        func clickIsNotDrag() throws {
            let view = ScrollCaptureMTKView()
            var dragged = false
            var ended = false
            view.onDrag = { _, _ in dragged = true }
            view.onDragEnd = { _, _ in ended = true }

            view.mouseDown(with: try mouse(.leftMouseDown, 5, 5, t: 0))
            view.mouseUp(with: try mouse(.leftMouseUp, 5, 5, t: 0.1))

            #expect(!dragged)
            #expect(!ended)
        }

        @Test("magnify forwards 1 + delta and ends on the ended/cancelled phases")
        func magnifySequence() {
            let view = ScrollCaptureMTKView()
            view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
            var scales: [CGFloat] = []
            var ends = 0
            view.onMagnify = { scale, _, size in
                scales.append(scale)
                #expect(size == CGSize(width: 200, height: 100))
            }
            view.onMagnifyEnd = { ends += 1 }

            view.handleMagnify(magnificationDelta: 0.25, phase: .changed, locationInWindow: .zero)
            view.handleMagnify(magnificationDelta: -0.1, phase: .changed, locationInWindow: .zero)
            view.handleMagnify(magnificationDelta: 0, phase: .ended, locationInWindow: .zero)
            view.handleMagnify(magnificationDelta: 0, phase: .cancelled, locationInWindow: .zero)

            #expect(scales == [1.25, 0.9])
            #expect(ends == 2)
        }

        @Test("rotate flips AppKit's counterclockwise degrees to clockwise radians")
        func rotateSequence() {
            let view = ScrollCaptureMTKView()
            var radians: [Float] = []
            var ends = 0
            view.onRotate = { radians.append($0) }
            view.onRotateEnd = { ends += 1 }

            view.handleRotate(degrees: 90, phase: .changed)
            view.handleRotate(degrees: 0, phase: .ended)

            #expect(radians.count == 1)
            #expect(abs((radians.first ?? 0) + .pi / 2) < 1e-5)
            #expect(ends == 1)
        }
    }
#endif
