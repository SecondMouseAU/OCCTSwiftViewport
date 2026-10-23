// MetalViewportView.swift
// ViewportKit
//
// SwiftUI view wrapping MTKView with gesture support for Metal rendering.

import SwiftUI
import simd

extension ViewCubePosition {
    /// SwiftUI alignment for placing the view-cube overlay in its corner (issue #62).
    var overlayAlignment: Alignment {
        switch self {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

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
    @Environment(\.displayScale) private var displayScale

    @State private var renderer: ViewportRenderer?

    // MARK: - Gesture State

    // These hold per-frame deltas for translating native gestures into
    // `ViewportInputEvent`s; interpretation (which action a drag performs) lives
    // in `ViewportController.dispatch(_:)`.
    #if os(iOS) || os(visionOS)
        @State private var touchDrags = TouchDragArbiter()
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
                // On macOS, drag / magnify / rotate are handled natively by `ScrollCaptureMTKView`
                // (SwiftUI gestures never fire over it on macOS 27, issue #127).
                metalView
                    #if os(iOS) || os(visionOS)
                        // Two-finger pan, pinch and rotate are UIKit recognizers on this overlay,
                        // all simultaneous: they report a cancel and the fingers' current
                        // centroid, which SwiftUI's MagnifyGesture/RotateGesture do not (#204).
                        .overlay { twoFingerGestureOverlay }
                        .gesture(orbitGesture(viewSize: geometry.size))
                        .gesture(
                            SpatialTapGesture()
                                .onEnded { value in
                                    handlePickAt(value.location, viewSize: geometry.size)
                                }
                        )
                        // Only when something uses it: an attached double-tap holds back every
                        // single-tap pick until the second-tap window has passed.
                        .gesture(
                            doubleTapGesture(viewSize: geometry.size),
                            including: controller.usesDoubleTap ? .all : .subviews)
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

    /// Passes the view's size to the controller, for picking and for a 1:1 pan.
    private func updateAspectRatio(_ size: CGSize) {
        controller.updateViewportSize(size)
    }

    // MARK: - Measurement Overlay

    private func measurementOverlay(viewportSize: CGSize) -> some View {
        let aspect =
            viewportSize.width > 0 && viewportSize.height > 0
            ? Float(viewportSize.width / viewportSize.height)
            : Float(1.0)
        // The near/far planes the renderer fitted to the scene for its last frame (#204), so
        // the overlay hides what the renderer clips rather than using a fixed 0.01/10000.
        return MeasurementOverlay(
            measurements: controller.measurements,
            vpMatrix: MeasurementOverlay.viewProjection(
                cameraState: controller.cameraState, aspectRatio: aspect,
                clipPlanes: renderer?.lastFrameClipPlanes),
            viewportSize: viewportSize
        )
    }

    // MARK: - Metal View

    /// `backgroundColor`, or `darkModeBackgroundColor` while the environment is dark (unless `nil`).
    private var canvasBackgroundColor: SIMD4<Float> {
        controller.configuration.resolvedBackgroundColor(isDark: colorScheme == .dark)
    }

    // MARK: - Picking Helpers

    /// Gesture centre → NDC (top-left UIKit/SwiftUI coords → −1…+1, y up).
    private func pinchCenterNDC(_ location: CGPoint, _ size: CGSize) -> SIMD2<Float> {
        TouchPinchRotate.ndc(location, viewSize: size)
    }

    /// Converts a view-space point to drawable pixel coordinates.
    private func viewToPixel(_ point: CGPoint, viewSize: CGSize) -> SIMD2<Int>? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale = nativeScaleFactor(viewSize: viewSize)
        let px = Int(point.x * scale)
        #if os(macOS)
            // macOS: AppKit origin is bottom-left, flip Y
            let py = Int((viewSize.height - point.y) * scale)
        #else
            // UIKit (iOS / visionOS): origin is top-left, no flip needed
            let py = Int(point.y * scale)
        #endif
        return SIMD2<Int>(px, py)
    }

    /// Points-to-pixels scale, taken from the renderer's own drawable size.
    ///
    /// Deriving it from the drawable rather than the screen gives the exact ratio the GPU is
    /// using, and avoids `UIScreen`/`NSScreen` entirely, which matters because the former does
    /// not exist on visionOS. Until the first frame has established a drawable size it falls
    /// back to the environment's `displayScale`, the scale of the screen this view is on.
    private func nativeScaleFactor(viewSize: CGSize) -> CGFloat {
        if let drawable = renderer?.lastDrawableSize,
            drawable.width > 0, viewSize.width > 0
        {
            return drawable.width / viewSize.width
        }
        return displayScale > 0 ? displayScale : 1
    }

    /// Dispatches a tap or click to the input router, then picks at it.
    ///
    /// `count` is the tap count: 1 for a single tap, 2 for the second click of a macOS
    /// double-click. `modifiers` are the keys held (macOS). The router interprets doubles via
    /// `GestureConfiguration.resetViewTriggers` and `doubleClick`.
    private func handlePickAt(
        _ location: CGPoint, viewSize: CGSize, count: Int = 1,
        modifiers: ViewportModifierKeys = []
    ) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }

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

        // A single tap routes nothing but surfaces on the input-event stream (e.g. for a HUD
        // input inspector); a double runs a matching resetViewTriggers entry or doubleClick.
        // The modifiers ride along for `.doubleClick(modifiers:)` triggers. Dispatched before
        // the picking guard so it still works with picking disabled.
        if count >= 2 { controller.inputSceneBodies = bodies }
        controller.dispatch(.tap(ndc: ndc, count: count), tapModifiers: modifiers)

        guard controller.configuration.pickingConfiguration.isEnabled else { return }
        guard let pixel = viewToPixel(location, viewSize: viewSize) else { return }

        let ctrl = controller
        let snapshot = bodies
        let aspect = controller.lastAspectRatio
        renderer?.performPick(at: pixel) { result in
            Task { @MainActor in
                // While a measurement tool is active, taps feed the measurement
                // accumulator instead of the selection stream.
                if ctrl.measurementMode != .none {
                    ctrl.handleMeasurementPick(
                        result: result, ndc: ndc, bodies: snapshot, aspectRatio: aspect)
                } else {
                    let resolved = ctrl.resolveAmbiguousFacePick(
                        result, ndc: ndc, bodies: snapshot, aspectRatio: aspect)
                    ctrl.handlePick(result: resolved, ndc: ndc)
                }
            }
        }
    }

    private var metalView: some View {
        Group {
            if let renderer = renderer {
                #if os(macOS)
                    macOSMetalView(renderer: renderer)
                #else
                    otherPlatformMetalView(renderer: renderer)
                #endif
            } else {
                metalViewFallback
            }
        }
    }

    private var metalViewFallback: some View {
        Color(
            red: Double(canvasBackgroundColor.x),
            green: Double(canvasBackgroundColor.y),
            blue: Double(canvasBackgroundColor.z)
        )
    }

    #if os(macOS)
        @ViewBuilder
        private func macOSMetalView(renderer: ViewportRenderer) -> some View {
            let onScrollWheel: (CGFloat, CGPoint, CGSize) -> Void = {
                delta, cursorInView, viewSize in
                guard viewSize.width > 0, viewSize.height > 0 else { return }
                let nx = Float((cursorInView.x / viewSize.width) * 2 - 1)
                let ny = Float((1 - cursorInView.y / viewSize.height) * 2 - 1)
                let aspect = Float(viewSize.width / viewSize.height)
                controller.dispatch(
                    .scroll(
                        delta: Float(delta),
                        cursorNDC: SIMD2<Float>(nx, ny),
                        aspectRatio: aspect
                    ))
                controller.scheduleDynamicPivotUpdate { bodies }
            }
            let onMouseDown: (CGPoint, CGSize, Int, ViewportModifierKeys) -> Void = {
                location, viewSize, clickCount, modifiers in
                // AppKit view coordinates are y-up; the drag origin is y-down from the centre.
                controller.setDragOrigin(
                    offsetFromCenter: SIMD2(
                        Float(location.x - viewSize.width / 2),
                        Float(viewSize.height / 2 - location.y)))
                handlePickAt(location, viewSize: viewSize, count: clickCount, modifiers: modifiers)
            }
            // Only claim keys when a key-combination trigger is configured, so by default every
            // key still goes to the responder chain untouched.
            let onKeyCombination: ((Character, ViewportModifierKeys) -> Bool)? =
                controller.wantsViewportKeyEvents
                ? { key, modifiers in controller.handleKeyCombination(key, modifiers: modifiers) }
                : nil
            let onDrag: (SIMD2<Float>, ViewportModifierKeys) -> Void = { delta, modifiers in
                controller.dispatch(.dragChanged(delta: delta, modifiers: modifiers))
            }
            let onDragEnd: (SIMD2<Float>, ViewportModifierKeys) -> Void = { velocity, modifiers in
                controller.dispatch(.dragEnded(velocity: velocity, modifiers: modifiers))
                controller.scheduleDynamicPivotUpdate { bodies }
            }
            let onMagnify: (CGFloat, CGPoint, CGSize) -> Void = { scale, cursor, viewSize in
                guard viewSize.width > 0, viewSize.height > 0 else { return }
                // AppKit view coords are y-up; pinchCenterNDC expects top-left origin.
                let topLeft = CGPoint(x: cursor.x, y: viewSize.height - cursor.y)
                controller.dispatch(
                    .pinchAtChanged(
                        scale: Float(scale),
                        centerNDC: pinchCenterNDC(topLeft, viewSize),
                        aspectRatio: Float(viewSize.width / viewSize.height)))
            }
            let onMagnifyEnd: () -> Void = {
                controller.dispatch(.pinchEnded)
                controller.scheduleDynamicPivotUpdate { bodies }
            }
            let onRotate: (Float) -> Void = { radians in
                controller.dispatch(.rotateChanged(radians: radians))
            }
            let onRotateEnd: () -> Void = {
                controller.dispatch(.rotateEnded)
            }
            MetalViewRepresentable(
                renderer: renderer,
                backgroundColor: canvasBackgroundColor,
                sampleCount: renderer.pipelineSampleCount,
                preferredFramesPerSecond: controller.configuration.preferredFramesPerSecond,
                onScrollWheel: onScrollWheel,
                onMouseDown: onMouseDown,
                onKeyCombination: onKeyCombination,
                takesKeyFocusOnClick: controller.wantsViewportKeyFocus,
                onDrag: onDrag,
                onDragEnd: onDragEnd,
                onMagnify: onMagnify,
                onMagnifyEnd: onMagnifyEnd,
                onRotate: onRotate,
                onRotateEnd: onRotateEnd
            )
        }
    #else
        @ViewBuilder
        private func otherPlatformMetalView(renderer: ViewportRenderer) -> some View {
            MetalViewRepresentable(
                renderer: renderer,
                backgroundColor: canvasBackgroundColor,
                sampleCount: renderer.pipelineSampleCount,
                preferredFramesPerSecond: controller.configuration.preferredFramesPerSecond
            )
        }
    #endif

    // MARK: - iOS / visionOS Gestures

    #if os(iOS) || os(visionOS)
        private var twoFingerGestureOverlay: some View {
            TwoFingerGestureView(
                onPanBegan: { centroid, viewSize in
                    apply(touchDrags.twoFingerPanBegan())
                    controller.setTwoFingerDragOrigin(
                        offsetFromCenter: SIMD2(
                            Float(centroid.x - viewSize.width / 2),
                            Float(centroid.y - viewSize.height / 2)))
                },
                onPanChanged: { translation in
                    controller.dispatch(
                        .twoFingerPanChanged(
                            translation: SIMD2<Float>(
                                Float(translation.width), Float(translation.height))
                        ))
                },
                onPanEnded: { velocity, cancelled in
                    touchDrags.twoFingerPanEnded()
                    if cancelled {
                        // No momentum and no slow-release snap for a cancelled pan (#204).
                        controller.interruptTwoFingerDrag()
                    } else {
                        controller.dispatch(
                            .twoFingerPanEnded(
                                velocity: SIMD2<Float>(
                                    Float(velocity.width), Float(velocity.height))
                            ))
                    }
                    controller.scheduleDynamicPivotUpdate { bodies }
                },
                onPinch: { scale, centroid, viewSize in
                    // Toward where the fingers are now, not where the pinch began (#204).
                    if let event = TouchPinchRotate.pinchStep(
                        scale: scale, centroid: centroid, viewSize: viewSize)
                    {
                        controller.dispatch(event)
                    }
                },
                onPinchEnded: {
                    controller.dispatch(.pinchEnded)
                    controller.scheduleDynamicPivotUpdate { bodies }
                },
                onRotate: { radians in
                    controller.dispatch(.rotateChanged(radians: Float(radians)))
                },
                onRotateEnded: {
                    controller.dispatch(.rotateEnded)
                }
            )
        }

        /// Interrupts the last drag, sets the drag origin and dispatches the events of one
        /// `TouchDragArbiter` step, in that order.
        ///
        /// The interruption comes first: ending a drag clears the pending origin, so a new
        /// drag's origin set before it was lost and the drag began at the centre.
        private func apply(_ step: TouchDragArbiter.Step) {
            if step.interruptsDrag {
                controller.interruptDrag()
            }
            if let origin = step.dragOrigin {
                controller.setDragOrigin(offsetFromCenter: origin)
            }
            for event in step.events {
                controller.dispatch(event)
            }
        }

        private func orbitGesture(viewSize: CGSize) -> some Gesture {
            // minimumDistance 8 (was 1): a 1pt threshold caught the sub-pixel jitter of a *tap* as a
            // micro-orbit, so SpatialTapGesture rarely fired and tap-to-select felt broken. 8pt cleanly
            // separates a tap (select) from a drag (orbit).
            // `TouchDragArbiter` keeps this drag out of the way of a two-finger pan, and ends a
            // drag whose end never arrived (issue #200).
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    apply(
                        touchDrags.dragChanged(
                            start: value.startLocation, translation: value.translation,
                            viewSize: viewSize))
                }
                .onEnded { value in
                    apply(touchDrags.dragEnded(velocity: value.velocity))
                    controller.scheduleDynamicPivotUpdate { bodies }
                }
        }

        private func doubleTapGesture(viewSize: CGSize) -> some Gesture {
            // Spatial, so a `.focusOnPoint` double-tap knows where the user tapped.
            SpatialTapGesture(count: 2)
                .onEnded { value in
                    controller.inputSceneBodies = bodies
                    controller.dispatch(
                        .tap(ndc: pinchCenterNDC(value.location, viewSize), count: 2))
                }
        }
    #endif

    // MARK: - ViewCube Overlay

    private var viewCubeOverlay: some View {
        // Honour configuration.viewCubePosition (issue #62) and keep clear of the
        // safe area (e.g. an iPhone bottom sheet covering bottom-trailing).
        NavigationCubeView(controller: controller)
            .frame(width: 96, height: 96)
            .padding(12)
            .frame(
                maxWidth: .infinity, maxHeight: .infinity,
                alignment: controller.configuration.viewCubePosition.overlayAlignment)
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

// MARK: - iOS / visionOS Two-Finger Gestures (Metal version)

#if os(iOS) || os(visionOS)
    import UIKit

    /// A transparent UIView overlay that recognizes the two-finger pan, pinch and rotation via
    /// UIKit, all simultaneously.
    ///
    /// UIKit rather than SwiftUI's `MagnifyGesture` / `RotateGesture`, because a recognizer
    /// reports `.cancelled` (SwiftUI skips `onEnded`) and its touches' current centroid
    /// (`MagnifyGesture` only gives where the pinch started) (issue #204).
    private struct TwoFingerGestureView: UIViewRepresentable {
        /// The pan began: the touches' centroid where they went down, and the view's size.
        var onPanBegan: (CGPoint, CGSize) -> Void
        /// The pan moved by this translation since the last change.
        var onPanChanged: (CGSize) -> Void
        /// The pan ended with this velocity, or was cancelled (`true`).
        var onPanEnded: (CGSize, Bool) -> Void
        /// The pinch scaled by this much since the last step, centred on the touches' centroid
        /// now; the view's size.
        var onPinch: (CGFloat, CGPoint, CGSize) -> Void
        /// The pinch ended or was cancelled.
        var onPinchEnded: () -> Void
        /// The twist turned by this many radians since the last step, clockwise positive.
        var onRotate: (CGFloat) -> Void
        /// The twist ended or was cancelled.
        var onRotateEnded: () -> Void

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear

            let pan = UIPanGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePan(_:))
            )
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            let pinch = UIPinchGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            let rotation = UIRotationGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleRotation(_:)))
            for recognizer in [pan, pinch, rotation] as [UIGestureRecognizer] {
                recognizer.delegate = context.coordinator
                view.addGestureRecognizer(recognizer)
            }

            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.view = self
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(view: self)
        }

        @MainActor
        class Coordinator: NSObject, UIGestureRecognizerDelegate {
            /// The latest representable, for its callbacks.
            var view: TwoFingerGestureView

            init(view: TwoFingerGestureView) {
                self.view = view
            }

            @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
                switch recognizer.state {
                case .began:
                    // The translation is not reset here, so the first change carries the
                    // movement since touch-down; the centroid there is where the drag began.
                    let location = recognizer.location(in: recognizer.view)
                    let translation = recognizer.translation(in: recognizer.view)
                    view.onPanBegan(
                        CGPoint(x: location.x - translation.x, y: location.y - translation.y),
                        recognizer.view?.bounds.size ?? .zero)
                case .changed:
                    let translation = recognizer.translation(in: recognizer.view)
                    view.onPanChanged(CGSize(width: translation.x, height: translation.y))
                    recognizer.setTranslation(.zero, in: recognizer.view)
                case .ended:
                    let velocity = recognizer.velocity(in: recognizer.view)
                    view.onPanEnded(CGSize(width: velocity.x, height: velocity.y), false)
                case .cancelled:
                    view.onPanEnded(.zero, true)
                default:
                    break
                }
            }

            @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
                switch recognizer.state {
                case .began, .changed:
                    // With one finger lifted the centroid is that one finger; wait for both.
                    guard recognizer.numberOfTouches >= 2 else { return }
                    view.onPinch(
                        recognizer.scale, recognizer.location(in: recognizer.view),
                        recognizer.view?.bounds.size ?? .zero)
                    // Reset, so each step is relative to the last and nothing carries over.
                    recognizer.scale = 1
                case .ended, .cancelled:
                    view.onPinchEnded()
                default:
                    break
                }
            }

            @objc func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
                switch recognizer.state {
                case .began, .changed:
                    view.onRotate(recognizer.rotation)
                    recognizer.rotation = 0
                case .ended, .cancelled:
                    view.onRotateEnded()
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
