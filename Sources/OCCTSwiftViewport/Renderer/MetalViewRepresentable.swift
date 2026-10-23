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
        var preferredFramesPerSecond: Int = 120

        func makeUIView(context: Context) -> MTKView {
            let view = MTKView()
            view.device = renderer.metalDevice
            view.delegate = renderer
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .depth32Float_stencil8
            view.sampleCount = sampleCount
            view.clearColor = mtlClearColor(from: backgroundColor)
            view.preferredFramesPerSecond = preferredFramesPerSecond
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
        /// Mouse down: location in view coords, view size, `NSEvent.clickCount` (2 for the second
        /// click of a double-click) and the modifier keys held.
        var onMouseDown: ((CGPoint, CGSize, Int, ViewportModifierKeys) -> Void)?
        /// A key typed with the view focused, or a key equivalent sent through the window.
        ///
        /// Returns `true` if handled. `nil` (the default) leaves every key to the responder chain.
        var onKeyCombination: ((Character, ViewportModifierKeys) -> Bool)?
        /// Whether a click makes this view first responder (off by default).
        ///
        /// Plain (non-⌘) key triggers then reach `keyDown` without relying on implicit focus.
        var takesKeyFocusOnClick = false
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

        override func keyDown(with event: NSEvent) {
            if handleKeyCombination(event) { return }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handleKeyCombination(event) || super.performKeyEquivalent(with: event)
        }

        /// Offers a key-down event to `onKeyCombination`, keyed by its unshifted character.
        func handleKeyCombination(_ event: NSEvent) -> Bool {
            guard let onKeyCombination, event.type == .keyDown, !event.isARepeat,
                let key = event.characters(byApplyingModifiers: [])?.first
            else { return false }
            return onKeyCombination(key, ViewportModifierKeys(event.modifierFlags))
        }

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
            if takesKeyFocusOnClick, window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            onMouseDown?(
                locationInView, viewSize, event.clickCount,
                ViewportModifierKeys(event.modifierFlags))
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
            // Fall back to the previous sample when a quick flick leaves only one in the window.
            if let last = dragSamples.last,
                let first = dragSamples.first(where: {
                    $0.time < last.time && last.time - $0.time <= 0.1
                }) ?? (dragSamples.count >= 2 ? dragSamples[dragSamples.count - 2] : nil),
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
            handleMagnify(
                magnificationDelta: event.magnification, phase: event.phase,
                locationInWindow: event.locationInWindow)
        }

        override func rotate(with event: NSEvent) {
            handleRotate(degrees: event.rotation, phase: event.phase)
        }

        func handleMagnify(
            magnificationDelta: CGFloat, phase: NSEvent.Phase, locationInWindow: CGPoint
        ) {
            switch phase {
            case .ended, .cancelled:
                onMagnifyEnd?()
            default:
                // Apple: `NSEvent.magnification` is "the change in magnification" for this event
                // (0 = no change; a cumulative scale is the SwiftUI `MagnifyGesture` model, not this).
                // `.pinchAtChanged` wants an incremental scale factor (1 = no change), hence 1 + delta.
                let locationInView = convert(locationInWindow, from: nil)
                onMagnify?(1 + magnificationDelta, locationInView, bounds.size)
            }
        }

        func handleRotate(degrees: Float, phase: NSEvent.Phase) {
            switch phase {
            case .ended, .cancelled:
                onRotateEnd?()
            default:
                // `NSEvent.rotation` is degrees, counterclockwise positive.
                onRotate?(-degrees * .pi / 180)
            }
        }
    }

    /// macOS wrapper for MTKView.
    struct MetalViewRepresentable: NSViewRepresentable {
        let renderer: ViewportRenderer
        let backgroundColor: SIMD4<Float>
        var sampleCount: Int = 4
        var preferredFramesPerSecond: Int = 120
        var onScrollWheel: ((CGFloat, CGPoint, CGSize) -> Void)?
        var onMouseDown: ((CGPoint, CGSize, Int, ViewportModifierKeys) -> Void)?
        var onKeyCombination: ((Character, ViewportModifierKeys) -> Bool)?
        var takesKeyFocusOnClick = false
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
            view.preferredFramesPerSecond = preferredFramesPerSecond
            view.onScrollWheel = onScrollWheel
            view.onMouseDown = onMouseDown
            view.onKeyCombination = onKeyCombination
            view.takesKeyFocusOnClick = takesKeyFocusOnClick
            install(on: view)
            return view
        }

        func updateNSView(_ nsView: MTKView, context: Context) {
            nsView.clearColor = mtlClearColor(from: backgroundColor)
            if let scView = nsView as? ScrollCaptureMTKView {
                scView.onScrollWheel = onScrollWheel
                scView.onMouseDown = onMouseDown
                scView.onKeyCombination = onKeyCombination
                scView.takesKeyFocusOnClick = takesKeyFocusOnClick
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
