// MetalViewportView.swift
// ViewportKit
//
// SwiftUI view wrapping MTKView with gesture support for Metal rendering.

import SwiftUI
import simd

/// A 3D viewport view using Metal.
///
/// MetalViewportView provides a complete Metal-based 3D viewing experience with:
/// - Orbit, pan, and zoom gestures
/// - ViewCube for orientation and quick navigation
/// - Shaded and wireframe display modes
///
/// ## Example
///
/// ```swift
/// struct ContentView: View {
///     @StateObject private var controller = ViewportController(configuration: .cad)
///     @State private var bodies: [ViewportBody] = [
///         .box(id: "box", color: SIMD4<Float>(0.5, 0.7, 1.0, 1.0))
///     ]
///
///     var body: some View {
///         MetalViewportView(controller: controller, bodies: $bodies)
///     }
/// }
/// ```
public struct MetalViewportView: View {

    // MARK: - Properties

    @ObservedObject private var controller: ViewportController
    @Binding private var bodies: [ViewportBody]
    @Environment(\.colorScheme) private var colorScheme

    @State private var renderer: ViewportRenderer?

    // MARK: - Gesture State

    @State private var lastDragValue: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0
    @State private var isPanning: Bool = false
    @State private var lastRotation: Angle = .zero

    #if os(macOS)
    /// Tracks which modifier-based gesture the current drag is performing.
    @State private var activeDragMode: MacDragMode = .orbit

    private enum MacDragMode { case orbit, pan, zoom }
    #endif

    // MARK: - Initialization

    public init(
        controller: ViewportController,
        bodies: Binding<[ViewportBody]>
    ) {
        self.controller = controller
        self._bodies = bodies
    }

    // MARK: - Body

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                metalView
                    #if os(iOS)
                    .overlay { panGestureOverlay }
                    .gesture(orbitGesture)
                    .gesture(zoomGesture)
                    .gesture(rollGesture)
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                handlePickAt(value.location, viewSize: geometry.size)
                            }
                    )
                    .gesture(doubleTapGesture)
                    #else
                    .gesture(macGestures)
                    .gesture(macMagnifyGesture)
                    .gesture(macRotateGesture)
                    #endif

                if controller.showViewCube {
                    viewCubeOverlay
                }

                if controller.showOrientationGnomon {
                    orientationGnomonOverlay
                }

                if controller.showScaleBar {
                    scaleBarOverlay(viewportSize: geometry.size)
                }

                if !controller.measurements.isEmpty {
                    measurementOverlay(viewportSize: geometry.size)
                }
            }
            .onChange(of: geometry.size) {
                updateAspectRatio(geometry.size)
            }
            .onAppear {
                updateAspectRatio(geometry.size)
            }
        }
        .onAppear {
            if renderer == nil {
                renderer = ViewportRenderer(controller: controller, bodies: $bodies)
            }
        }
    }

    private func updateAspectRatio(_ size: CGSize) {
        if size.width > 0, size.height > 0 {
            controller.lastAspectRatio = Float(size.width / size.height)
        }
    }

    // MARK: - Measurement Overlay

    private func measurementOverlay(viewportSize: CGSize) -> some View {
        let aspect = viewportSize.width > 0 && viewportSize.height > 0
            ? Float(viewportSize.width / viewportSize.height)
            : Float(1.0)
        let cs = controller.cameraState
        let vpMatrix = cs.projectionMatrix(aspectRatio: aspect, near: 0.01, far: 10000.0) * cs.viewMatrix
        return MeasurementOverlay(
            measurements: controller.measurements,
            vpMatrix: vpMatrix,
            viewportSize: viewportSize
        )
    }

    // MARK: - Metal View

    private var canvasBackgroundColor: SIMD4<Float> {
        colorScheme == .dark
            ? SIMD4<Float>(0.12, 0.12, 0.12, 1.0)
            : controller.configuration.backgroundColor
    }

    // MARK: - Picking Helpers

    /// Converts a view-space point to drawable pixel coordinates.
    private func viewToPixel(_ point: CGPoint, viewSize: CGSize) -> SIMD2<Int>? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale = nativeScaleFactor
        let px = Int(point.x * scale)
        #if os(macOS)
        // macOS: AppKit origin is bottom-left, flip Y
        let py = Int((viewSize.height - point.y) * scale)
        #else
        // iOS: UIKit origin is top-left, no flip needed
        let py = Int(point.y * scale)
        #endif
        return SIMD2<Int>(px, py)
    }

    private var nativeScaleFactor: CGFloat {
        #if os(macOS)
        NSScreen.main?.backingScaleFactor ?? 2.0
        #else
        UIScreen.main.scale
        #endif
    }

    private func handlePickAt(_ location: CGPoint, viewSize: CGSize) {
        guard controller.configuration.pickingConfiguration.isEnabled else { return }
        guard let pixel = viewToPixel(location, viewSize: viewSize) else { return }

        // Compute NDC from tap location for sub-body selection
        let ndcX = Float(location.x / viewSize.width) * 2.0 - 1.0
        #if os(macOS)
        // macOS: AppKit origin is bottom-left; NDC y already matches
        let ndcY = Float(location.y / viewSize.height) * 2.0 - 1.0
        #else
        // iOS: UIKit origin is top-left; flip y for NDC
        let ndcY = Float(1.0 - location.y / viewSize.height) * 2.0 - 1.0
        #endif
        let ndc = SIMD2<Float>(ndcX, ndcY)

        let ctrl = controller
        renderer?.performPick(at: pixel) { result in
            Task { @MainActor in
                ctrl.handlePick(result: result, ndc: ndc)
            }
        }
    }

    private var metalView: some View {
        Group {
            if let renderer = renderer {
                #if os(macOS)
                MetalViewRepresentable(
                    renderer: renderer,
                    backgroundColor: canvasBackgroundColor,
                    sampleCount: controller.configuration.msaaSampleCount,
                    onScrollWheel: { delta, cursorInView, viewSize in
                        guard viewSize.width > 0, viewSize.height > 0 else { return }
                        let nx = Float((cursorInView.x / viewSize.width) * 2 - 1)
                        let ny = Float((1 - cursorInView.y / viewSize.height) * 2 - 1)
                        let aspect = Float(viewSize.width / viewSize.height)
                        controller.handleScrollZoom(
                            delta: delta,
                            cursorNormalized: SIMD2<Float>(nx, ny),
                            aspectRatio: aspect
                        )
                        controller.scheduleDynamicPivotUpdate(bodies: bodies)
                    },
                    onMouseDown: { location, viewSize in
                        handlePickAt(location, viewSize: viewSize)
                    }
                )
                #else
                MetalViewRepresentable(
                    renderer: renderer,
                    backgroundColor: canvasBackgroundColor,
                    sampleCount: controller.configuration.msaaSampleCount
                )
                #endif
            } else {
                Color(
                    red: Double(canvasBackgroundColor.x),
                    green: Double(canvasBackgroundColor.y),
                    blue: Double(canvasBackgroundColor.z)
                )
            }
        }
    }

    // MARK: - iOS Gestures

    #if os(iOS)
    private var panGestureOverlay: some View {
        TwoFingerPanGestureView(
            onChanged: { translation in
                isPanning = true
                controller.handlePan(translation: translation)
            },
            onEnded: { velocity in
                controller.endPan(velocity: velocity)
            }
        )
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !isPanning else { return }

                let delta = CGSize(
                    width: value.translation.width - lastDragValue.width,
                    height: value.translation.height - lastDragValue.height
                )
                lastDragValue = value.translation

                // Negate horizontal so left/right swipe rotates the object
                // under the finger (direct manipulation) rather than orbiting
                // the camera around the object.
                controller.handleOrbit(translation: CGSize(width: -delta.width, height: delta.height))
            }
            .onEnded { value in
                lastDragValue = .zero
                if !isPanning {
                    controller.endOrbit(velocity: CGSize(width: -value.velocity.width, height: value.velocity.height))
                }
                isPanning = false
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                controller.handleZoom(magnification: delta)
            }
            .onEnded { _ in
                lastMagnification = 1.0
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var rollGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let delta = Float((value.rotation - lastRotation).radians)
                lastRotation = value.rotation
                controller.handleRoll(angle: CGFloat(delta))
            }
            .onEnded { _ in
                lastRotation = .zero
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                controller.reset(animated: true)
            }
    }
    #endif

    // MARK: - macOS Gestures

    #if os(macOS)
    private var macGestures: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let delta = CGSize(
                    width: value.translation.width - lastDragValue.width,
                    height: value.translation.height - lastDragValue.height
                )
                lastDragValue = value.translation

                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                let gc = controller.configuration.gestureConfiguration
                print("[GESTURE] mouseDrag=\(gc.mouseDrag) shift=\(modifiers.contains(.shift))")

                let action: GestureAction
                if modifiers.contains(.command) {
                    action = gc.commandDrag
                } else if modifiers.contains(.shift) {
                    action = gc.shiftDrag
                } else if modifiers.contains(.option) {
                    action = gc.optionDrag
                } else {
                    action = gc.mouseDrag
                }

                switch action {
                case .pan:
                    activeDragMode = .pan
                    controller.handlePan(translation: delta)
                case .zoom:
                    activeDragMode = .zoom
                    let zoomDelta = 1.0 + delta.height * 0.02
                    controller.handleZoom(magnification: zoomDelta)
                case .orbit:
                    activeDragMode = .orbit
                    controller.handleOrbit(translation: CGSize(width: -delta.width, height: delta.height))
                case .none:
                    break
                default:
                    break
                }
            }
            .onEnded { value in
                lastDragValue = .zero

                switch activeDragMode {
                case .orbit:
                    controller.endOrbit(velocity: CGSize(width: -value.velocity.width, height: value.velocity.height))
                case .pan:
                    controller.endPan(velocity: value.velocity)
                case .zoom:
                    break
                }
                activeDragMode = .orbit

                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var macMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                controller.handleZoom(magnification: delta)
            }
            .onEnded { _ in
                lastMagnification = 1.0
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var macRotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let delta = Float((value.rotation - lastRotation).radians)
                lastRotation = value.rotation
                controller.handleRoll(angle: CGFloat(delta))
            }
            .onEnded { _ in
                lastRotation = .zero
            }
    }
    #endif

    // MARK: - ViewCube Overlay

    private var viewCubeOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                ViewCubeView(controller: controller)
                    .frame(width: 80, height: 80)
                    .padding(12)
            }
        }
    }

    // MARK: - HUD Overlays

    /// Orientation gnomon pinned to the top-leading corner.
    private var orientationGnomonOverlay: some View {
        VStack {
            HStack {
                OrientationGnomon(controller: controller)
                    .frame(width: 64, height: 64)
                    .padding(12)
                Spacer()
            }
            Spacer()
        }
    }

    /// Scale bar pinned to the bottom-leading corner.
    private func scaleBarOverlay(viewportSize: CGSize) -> some View {
        VStack {
            Spacer()
            HStack {
                ScaleBarView(
                    controller: controller,
                    viewportHeightPoints: viewportSize.height,
                    unitLabel: controller.configuration.scaleBarUnitLabel
                )
                .padding(12)
                Spacer()
            }
        }
    }
}

// MARK: - iOS Two-Finger Pan Gesture (Metal version)

#if os(iOS)
import UIKit

/// A transparent UIView overlay that recognizes two-finger pan gestures via UIKit.
private struct TwoFingerPanGestureView: UIViewRepresentable {
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    @MainActor
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .changed:
                let translation = recognizer.translation(in: recognizer.view)
                onChanged(CGSize(width: translation.x, height: translation.y))
                recognizer.setTranslation(.zero, in: recognizer.view)
            case .ended, .cancelled:
                let velocity = recognizer.velocity(in: recognizer.view)
                onEnded(CGSize(width: velocity.x, height: velocity.y))
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
