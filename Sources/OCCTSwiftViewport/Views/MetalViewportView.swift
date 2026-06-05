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

    // These hold per-frame deltas for translating native gestures into
    // `ViewportInputEvent`s; interpretation (which action a drag performs) lives
    // in `ViewportController.dispatch(_:)`.
    @State private var lastDragValue: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1.0
    @State private var isPanning: Bool = false
    @State private var lastRotation: Angle = .zero

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

        // Observational only — routes nothing for a single tap, but surfaces taps
        // on the input-event stream (e.g. for a HUD input inspector).
        controller.dispatch(.tap(ndc: ndc, count: 1))

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
                        controller.dispatch(.scroll(
                            delta: Float(delta),
                            cursorNDC: SIMD2<Float>(nx, ny),
                            aspectRatio: aspect
                        ))
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
                controller.dispatch(.twoFingerPanChanged(
                    translation: SIMD2<Float>(Float(translation.width), Float(translation.height))
                ))
            },
            onEnded: { velocity in
                controller.dispatch(.twoFingerPanEnded(
                    velocity: SIMD2<Float>(Float(velocity.width), Float(velocity.height))
                ))
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

                controller.dispatch(.dragChanged(
                    delta: SIMD2<Float>(Float(delta.width), Float(delta.height)),
                    modifiers: []
                ))
            }
            .onEnded { value in
                lastDragValue = .zero
                if !isPanning {
                    controller.dispatch(.dragEnded(
                        velocity: SIMD2<Float>(Float(value.velocity.width), Float(value.velocity.height)),
                        modifiers: []
                    ))
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
                controller.dispatch(.pinchChanged(scale: Float(delta)))
            }
            .onEnded { _ in
                lastMagnification = 1.0
                controller.dispatch(.pinchEnded)
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var rollGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let delta = Float((value.rotation - lastRotation).radians)
                lastRotation = value.rotation
                controller.dispatch(.rotateChanged(radians: delta))
            }
            .onEnded { _ in
                lastRotation = .zero
                controller.dispatch(.rotateEnded)
            }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                controller.dispatch(.tap(ndc: .zero, count: 2))
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

                let modifiers = ViewportModifierKeys(NSApp.currentEvent?.modifierFlags ?? [])
                controller.dispatch(.dragChanged(
                    delta: SIMD2<Float>(Float(delta.width), Float(delta.height)),
                    modifiers: modifiers
                ))
            }
            .onEnded { value in
                lastDragValue = .zero
                let modifiers = ViewportModifierKeys(NSApp.currentEvent?.modifierFlags ?? [])
                controller.dispatch(.dragEnded(
                    velocity: SIMD2<Float>(Float(value.velocity.width), Float(value.velocity.height)),
                    modifiers: modifiers
                ))
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var macMagnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let delta = value.magnification / lastMagnification
                lastMagnification = value.magnification
                controller.dispatch(.pinchChanged(scale: Float(delta)))
            }
            .onEnded { _ in
                lastMagnification = 1.0
                controller.dispatch(.pinchEnded)
                controller.scheduleDynamicPivotUpdate(bodies: bodies)
            }
    }

    private var macRotateGesture: some Gesture {
        RotateGesture()
            .onChanged { value in
                let delta = Float((value.rotation - lastRotation).radians)
                lastRotation = value.rotation
                controller.dispatch(.rotateChanged(radians: delta))
            }
            .onEnded { _ in
                lastRotation = .zero
                controller.dispatch(.rotateEnded)
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
