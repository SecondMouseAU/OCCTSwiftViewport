// MetalViewRepresentable.swift
// ViewportKit
//
// Platform-specific MTKView wrapper for SwiftUI.

import MetalKit
import SwiftUI

#if os(iOS) || os(visionOS)

    /// UIKit (iOS / visionOS) wrapper for MTKView. visionOS runs this in a window /
    /// volume (shared space); the same `MTKView` + SwiftUI gesture path applies.
    struct MetalViewRepresentable: UIViewRepresentable {
        let renderer: ViewportRenderer
        let backgroundColor: SIMD4<Float>
        var sampleCount: Int = 4

        func makeUIView(context: Context) -> MTKView {
            let view = MTKView()
            view.device = renderer.metalDevice
            view.delegate = renderer
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .depth32Float_stencil8
            view.sampleCount = sampleCount
            view.clearColor = mtlClearColor(from: backgroundColor)
            view.preferredFramesPerSecond = 60
            view.isMultipleTouchEnabled = true
            return view
        }

        func updateUIView(_ uiView: MTKView, context: Context) {
            uiView.clearColor = mtlClearColor(from: backgroundColor)
        }
    }

#elseif os(macOS)

    /// MTKView subclass that captures scroll wheel and mouse-down events on macOS.
    class ScrollCaptureMTKView: MTKView {
        var onScrollWheel: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onMouseDown: ((CGPoint, CGSize) -> Void)?
        /// Incremental drag delta in points (y down) since the previous event.
        var onDrag: ((SIMD2<Float>, ViewportModifierKeys) -> Void)?
        /// Drag finished; velocity in points/second (y down).
        var onDragEnd: ((SIMD2<Float>, ViewportModifierKeys) -> Void)?
        /// Incremental magnification factor (1 = unchanged), cursor in view coords, view size.
        var onMagnify: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onMagnifyEnd: (() -> Void)?
        /// Incremental rotation in radians, positive clockwise on screen.
        var onRotate: ((Float) -> Void)?
        var onRotateEnd: (() -> Void)?

        /// Matches SwiftUI `DragGesture(minimumDistance: 1)`: a click is not a drag.
        private static let dragThreshold: CGFloat = 1
        private var dragOrigin: CGPoint?
        private var dragLast: CGPoint = .zero
        private var dragActive = false
        private var dragSamples: [(time: TimeInterval, location: CGPoint)] = []

        override var acceptsFirstResponder: Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // Precise devices (trackpads, Magic Mouse) report PIXEL deltas: ±60/event during a flick,
            // ~10× a wheel line tick. Normalize so one "unit" means the same zoom on every device;
            // without this, trackpad zoom is violent and steppy.
            let raw = event.scrollingDeltaY
            let delta = event.hasPreciseScrollingDeltas ? raw / 10.0 : raw
            let locationInView = convert(event.locationInWindow, from: nil)
            let viewSize = bounds.size
            onScrollWheel?(CGFloat(delta), locationInView, viewSize)
        }

        override func mouseDown(with event: NSEvent) {
            let locationInView = convert(event.locationInWindow, from: nil)
            let viewSize = bounds.size
            onMouseDown?(locationInView, viewSize)
            // Do NOT call super: it starts an NSView mouse-tracking loop.
            // Drags are handled natively below (SwiftUI gestures stopped firing over
            // this view on macOS 27, issue #127).
            dragOrigin = event.locationInWindow
            dragLast = event.locationInWindow
            dragActive = false
            dragSamples = [(event.timestamp, event.locationInWindow)]
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            let location = event.locationInWindow
            if !dragActive {
                guard hypot(location.x - origin.x, location.y - origin.y) >= Self.dragThreshold
                else { return }
                dragActive = true
            }
            // Window coords are y-up; viewport input is y-down like SwiftUI's DragGesture.
            let delta = SIMD2<Float>(
                Float(location.x - dragLast.x), Float(dragLast.y - location.y))
            dragLast = location
            dragSamples.append((event.timestamp, location))
            if dragSamples.count > 8 { dragSamples.removeFirst() }
            onDrag?(delta, ViewportModifierKeys(event.modifierFlags))
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                dragOrigin = nil
                dragActive = false
                dragSamples = []
            }
            guard dragActive else { return }
            // Velocity over the last ~100 ms of movement.
            var velocity = SIMD2<Float>.zero
            if let last = dragSamples.last,
                let first = dragSamples.first(where: { last.time - $0.time <= 0.1 }),
                last.time > first.time
            {
                let dt = Float(last.time - first.time)
                velocity = SIMD2<Float>(
                    Float(last.location.x - first.location.x) / dt,
                    Float(first.location.y - last.location.y) / dt)
            }
            onDragEnd?(velocity, ViewportModifierKeys(event.modifierFlags))
        }

        override func magnify(with event: NSEvent) {
            switch event.phase {
            case .ended, .cancelled:
                onMagnifyEnd?()
            default:
                let locationInView = convert(event.locationInWindow, from: nil)
                onMagnify?(1 + event.magnification, locationInView, bounds.size)
            }
        }

        override func rotate(with event: NSEvent) {
            switch event.phase {
            case .ended, .cancelled:
                onRotateEnd?()
            default:
                // NSEvent.rotation is degrees, counterclockwise positive.
                onRotate?(-event.rotation * .pi / 180)
            }
        }
    }

    /// macOS wrapper for MTKView.
    struct MetalViewRepresentable: NSViewRepresentable {
        let renderer: ViewportRenderer
        let backgroundColor: SIMD4<Float>
        var sampleCount: Int = 4
        var onScrollWheel: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onMouseDown: ((CGPoint, CGSize) -> Void)?
        var onDrag: ((SIMD2<Float>, ViewportModifierKeys) -> Void)?
        var onDragEnd: ((SIMD2<Float>, ViewportModifierKeys) -> Void)?
        var onMagnify: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onMagnifyEnd: (() -> Void)?
        var onRotate: ((Float) -> Void)?
        var onRotateEnd: (() -> Void)?

        func makeNSView(context: Context) -> MTKView {
            let view = ScrollCaptureMTKView()
            view.device = renderer.metalDevice
            view.delegate = renderer
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .depth32Float_stencil8
            view.sampleCount = sampleCount
            view.clearColor = mtlClearColor(from: backgroundColor)
            view.preferredFramesPerSecond = 60
            view.onScrollWheel = onScrollWheel
            view.onMouseDown = onMouseDown
            install(on: view)
            return view
        }

        func updateNSView(_ nsView: MTKView, context: Context) {
            nsView.clearColor = mtlClearColor(from: backgroundColor)
            if let scView = nsView as? ScrollCaptureMTKView {
                scView.onScrollWheel = onScrollWheel
                scView.onMouseDown = onMouseDown
                install(on: scView)
            }
        }

        private func install(on view: ScrollCaptureMTKView) {
            view.onDrag = onDrag
            view.onDragEnd = onDragEnd
            view.onMagnify = onMagnify
            view.onMagnifyEnd = onMagnifyEnd
            view.onRotate = onRotate
            view.onRotateEnd = onRotateEnd
        }
    }

#endif

// MARK: - Helpers

private func mtlClearColor(from color: SIMD4<Float>) -> MTLClearColor {
    MTLClearColor(
        red: Double(color.x),
        green: Double(color.y),
        blue: Double(color.z),
        alpha: Double(color.w)
    )
}
