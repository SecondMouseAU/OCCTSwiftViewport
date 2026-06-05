// MetalViewRepresentable.swift
// ViewportKit
//
// Platform-specific MTKView wrapper for SwiftUI.

import SwiftUI
import MetalKit

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

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        let locationInView = convert(event.locationInWindow, from: nil)
        let viewSize = bounds.size
        onScrollWheel?(CGFloat(delta), locationInView, viewSize)
    }

    override func mouseDown(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let viewSize = bounds.size
        onMouseDown?(locationInView, viewSize)
        // Do NOT call super — it starts an NSView mouse-tracking loop
        // that prevents SwiftUI DragGesture from receiving the drag.
    }
}

/// macOS wrapper for MTKView.
struct MetalViewRepresentable: NSViewRepresentable {
    let renderer: ViewportRenderer
    let backgroundColor: SIMD4<Float>
    var sampleCount: Int = 4
    var onScrollWheel: ((CGFloat, CGPoint, CGSize) -> Void)?
    var onMouseDown: ((CGPoint, CGSize) -> Void)?

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
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.clearColor = mtlClearColor(from: backgroundColor)
        if let scView = nsView as? ScrollCaptureMTKView {
            scView.onScrollWheel = onScrollWheel
            scView.onMouseDown = onMouseDown
        }
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
