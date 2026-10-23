// ViewportInputRouter.swift
// ViewportKit
//
// Central interpretation of ViewportInputEvent into camera actions. This is the
// single entry point platform layers (and synthetic / XR / test input) feed; it
// owns gesture-action resolution, sign conventions, and the zoom curve so the
// translation layer stays a thin native->event adapter.

import Foundation
import simd

extension ViewportController {

    /// Interprets a portable input event and applies it to the camera.
    ///
    /// The platform layer is responsible only for translating native input into
    /// `ViewportInputEvent` (delta math, gesture arbitration) and for any lifecycle
    /// glue it already owns (e.g. dynamic-pivot scheduling). All *interpretation*
    /// (which `GestureAction` a drag, pinch, scroll or double-tap maps to, the orbit
    /// direction from `GestureConfiguration.dragRotation`, the drag-to-zoom curve) lives here, so the meaning is
    /// identical regardless of the input source.
    public func dispatch(_ event: ViewportInputEvent) {
        dispatch(event, tapModifiers: [])
    }

    /// Resets the camera if `key` with exactly `modifiers` held matches a `.keyCombination` in
    /// `GestureConfiguration.resetViewTriggers`.
    ///
    /// `MetalViewportView` calls this on macOS for keys typed into the viewport. Call it yourself
    /// to forward keys from elsewhere (for example a SwiftUI `onKeyPress` on iOS).
    ///
    /// - Returns: `true` if the key was handled, so the caller can stop passing it on.
    @discardableResult
    public func handleKeyCombination(_ key: Character, modifiers: ViewportModifierKeys) -> Bool {
        guard configuration.gestureConfiguration.resetsView(onKey: key, modifiers: modifiers)
        else { return false }
        reset(animated: true)
        return true
    }

    /// Whether any `.keyCombination` reset trigger is configured, so the platform view only takes
    /// keyboard focus when something will use it.
    var wantsViewportKeyEvents: Bool {
        configuration.gestureConfiguration.resetViewTriggers.contains {
            if case .keyCombination = $0 { return true }
            return false
        }
    }

    /// Whether a key trigger without ⌘ is configured.
    ///
    /// Plain keys reach only the first responder, so the macOS view then takes focus when
    /// clicked; ⌘ combinations arrive as key equivalents whatever has focus.
    var wantsViewportKeyFocus: Bool {
        configuration.gestureConfiguration.resetViewTriggers.contains {
            if case .keyCombination(_, let modifiers) = $0 { return !modifiers.contains(.command) }
            return false
        }
    }

    /// Whether anything uses a double-tap.
    ///
    /// That is a `.doubleTap` reset trigger, or a `doubleTap` action the router acts on. When
    /// nothing does, the touch view leaves the double-tap recognizer off,
    /// so single-tap picks are not held back waiting for a possible second tap.
    var usesDoubleTap: Bool {
        let gestures = configuration.gestureConfiguration
        return gestures.resetsViewOnDoubleTap
            || gestures.doubleTap == .focusOnPoint || gestures.doubleTap == .resetView
    }

    /// `dispatch(_:)` with the modifier keys held during a tap.
    ///
    /// `ViewportInputEvent.tap` does not carry modifiers. The macOS view passes them so `.doubleClick(modifiers:)` triggers match.
    func dispatch(_ event: ViewportInputEvent, tapModifiers: ViewportModifierKeys) {
        onInputEvent?(event)

        switch event {
        case .dragChanged(let delta, let modifiers):
            apply(dragDelta: delta, modifiers: modifiers)

        case .dragEnded(let velocity, _):
            endDrag(velocity: velocity)

        case .twoFingerPanChanged(let translation):
            if !twoFingerDragActive {
                twoFingerDragActive = true
                cameraController.yieldToGesture()
                twoFingerDragPointer = pendingTwoFingerDragOrigin ?? .zero
                pendingTwoFingerDragOrigin = nil
            }
            let pointer = twoFingerDragPointer ?? .zero
            applyDrag(
                configuration.gestureConfiguration.twoFingerDrag, delta: translation,
                pointer: pointer)
            twoFingerDragPointer = pointer + translation

        case .twoFingerPanEnded(let velocity):
            twoFingerDragActive = false
            twoFingerDragPointer = nil
            pendingTwoFingerDragOrigin = nil
            endDrag(configuration.gestureConfiguration.twoFingerDrag, velocity: velocity)

        // Pinch, roll and scroll take the camera from a view animation, which would overwrite
        // them on its next tick, but leave momentum coasting.
        case .pinchChanged(let scale):
            guard resolvedPinchAction == .zoom else { break }
            cameraController.cancelViewAnimation()
            handleZoom(magnification: CGFloat(scale))

        case .pinchAtChanged(let scale, let centerNDC, let aspectRatio):
            guard resolvedPinchAction == .zoom else { break }
            cameraController.cancelViewAnimation()
            handleZoom(
                magnification: CGFloat(scale), centerNormalized: centerNDC, aspectRatio: aspectRatio
            )

        case .pinchEnded:
            break

        case .rotateChanged(let radians):
            cameraController.cancelViewAnimation()
            handleRoll(angle: CGFloat(radians))

        case .rotateEnded:
            break

        case .scroll(let delta, let cursorNDC, let aspectRatio):
            guard configuration.gestureConfiguration.scrollWheel == .zoom else { break }
            cameraController.cancelViewAnimation()
            handleScrollZoom(
                delta: CGFloat(delta),
                cursorNormalized: cursorNDC,
                aspectRatio: aspectRatio)

        case .tap(let ndc, let count):
            guard count >= 2 else { break }
            if resetTriggerMatchesDoubleTap(modifiers: tapModifiers) {
                reset(animated: true)
                break
            }
            // The per-gesture action applies to an unmodified double-tap / double-click only.
            guard tapModifiers.isEmpty else { break }
            switch resolvedDoubleTapAction {
            case .resetView:
                reset(animated: true)
            case .focusOnPoint:
                focus(atNDC: ndc)
            default:
                break
            }
        }
    }

    // MARK: - Platform action resolution

    /// Resolves the action for a primary drag. macOS uses modifier-aware
    /// `dragAction(for:)`; iOS (no modifiers) uses `singleFingerDrag`.
    private func resolvedDragAction(_ modifiers: ViewportModifierKeys) -> GestureAction {
        #if os(macOS)
            return configuration.gestureConfiguration.dragAction(for: modifiers)
        #else
            return configuration.gestureConfiguration.singleFingerDrag
        #endif
    }

    /// Pinch action: `trackpadPinch` on macOS, `pinchGesture` elsewhere.
    private var resolvedPinchAction: GestureAction {
        #if os(macOS)
            return configuration.gestureConfiguration.trackpadPinch
        #else
            return configuration.gestureConfiguration.pinchGesture
        #endif
    }

    /// Double-tap action: `doubleClick` on macOS, `doubleTap` elsewhere.
    private var resolvedDoubleTapAction: GestureAction {
        #if os(macOS)
            return configuration.gestureConfiguration.doubleClick
        #else
            return configuration.gestureConfiguration.doubleTap
        #endif
    }

    /// Whether a double-tap (double-click on macOS) with `modifiers` matches a reset trigger.
    private func resetTriggerMatchesDoubleTap(modifiers: ViewportModifierKeys) -> Bool {
        #if os(macOS)
            return configuration.gestureConfiguration.resetsView(onDoubleClickWith: modifiers)
        #else
            return configuration.gestureConfiguration.resetsViewOnDoubleTap
        #endif
    }

    // MARK: - Focus

    /// Moves the orbit pivot to the nearest surface under `ndc`, raycasting `inputSceneBodies`.
    ///
    /// Does nothing when the ray misses, since there is then no point to focus on. Geometry
    /// removed by `clipPlanes` is skipped, so a sectioned model focuses on the visible cut
    /// (issue #163). Widgets and non-pickable bodies are skipped, and the bounding boxes come
    /// from the dynamic pivot's per-generation cache rather than a rescan per tap (issue #180).
    private func focus(atNDC ndc: SIMD2<Float>) {
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: lastAspectRatio)
        guard
            let hit = pivotStrategy.raycast(
                ray: ray, bodies: inputSceneBodies, clipPlanes: clipPlanes)
        else { return }
        focusOn(point: hit.point, animated: true)
    }

    // MARK: - Drag interpretation

    /// Drag-zoom rate: log zoom per point of vertical drag, before `zoomSensitivity` applies.
    static let dragZoomRate: Float = 0.02

    /// Where the next primary drag starts, in points from the centre of the view (y down).
    ///
    /// Optional. The arcball rotation style uses it to place the pointer on its virtual sphere,
    /// so that a drag that starts near the edge of the view and moves around the centre rolls
    /// the view. `MetalViewportView` calls it on mouse-down (macOS) and at the start of a
    /// one-finger drag (iOS); call it yourself before dispatching the first `.dragChanged` of
    /// a drag from another input source. Without it the drag is taken to start at the centre.
    public func setDragOrigin(offsetFromCenter: SIMD2<Float>) {
        pendingDragOrigin = offsetFromCenter
    }

    /// Where the next two-finger drag starts: the centroid of the two touches, in points from the
    /// centre of the view (y down).
    ///
    /// Optional, like `setDragOrigin(offsetFromCenter:)`, and used the same way when
    /// `GestureConfiguration.twoFingerDrag` is `.orbit` with the arcball rotation style: a
    /// two-finger drag that starts near the edge of the view and moves around the centre rolls
    /// it. `MetalViewportView` calls it when a two-finger pan begins (iOS / visionOS); call it
    /// before the first `.twoFingerPanChanged` of a drag from another input source. Without it
    /// the drag is taken to start at the centre, where it can only tumble.
    public func setTwoFingerDragOrigin(offsetFromCenter: SIMD2<Float>) {
        pendingTwoFingerDragOrigin = offsetFromCenter
    }

    private func apply(dragDelta delta: SIMD2<Float>, modifiers: ViewportModifierKeys) {
        if inputDragPointer == nil {
            // A new drag: stop any momentum still coasting rather than adding to it, and any
            // animation that would overwrite the drag.
            cameraController.yieldToGesture()
            inputDragPointer = pendingDragOrigin ?? .zero
            pendingDragOrigin = nil
        }
        let action = resolvedDragAction(modifiers)
        switch action {
        case .orbit: activeInputDragMode = .orbit
        case .pan: activeInputDragMode = .pan
        case .zoom: activeInputDragMode = .zoom
        default:
            // .select / .focusOnPoint / .resetView / .none don't drive a drag;
            // leave activeInputDragMode unchanged (matches the historical handler).
            break
        }
        let pointer = inputDragPointer ?? .zero
        if action != .orbit, cameraController.isOrbitDragActive {
            // A modifier changed mid-drag; the orbit part of the drag is over.
            cameraController.endOrbitDrag()
        }
        applyDrag(action, delta: delta, pointer: pointer)
        inputDragPointer = pointer + delta
    }

    /// Applies one drag increment as `action`, for both the primary and the two-finger drag.
    ///
    /// `pointer` is where the pointer was before this increment, in points from the view
    /// centre; an orbit that begins here begins there.
    private func applyDrag(_ action: GestureAction, delta: SIMD2<Float>, pointer: SIMD2<Float>) {
        switch action {
        case .orbit:
            if !cameraController.isOrbitDragActive {
                beginOrbitDrag(at: pointer)
            }
            orbitDrag(delta: delta)
        case .pan:
            handlePan(
                translation: CGSize(
                    width: CGFloat(delta.x),
                    height: CGFloat(delta.y)))
        case .zoom:
            // exp() matches the historical 1 + 0.02·dy for small steps but never goes
            // non-positive on a fast drag. handleZoom then applies zoomSensitivity.
            handleZoom(magnification: CGFloat(exp(delta.y * Self.dragZoomRate)))
        default:
            break
        }
    }

    /// Begins an orbit drag at `pointer` (points from the view centre, y down) with the
    /// configured `dragRotation` direction, stopping any orbit momentum.
    ///
    /// `orbitDrag(delta:)` calls it when no drag is in progress, at the centre.
    func beginOrbitDrag(at pointer: SIMD2<Float>) {
        let gestures = configuration.gestureConfiguration
        let signs = gestures.orbitDragSigns
        cameraController.beginOrbitDrag(
            at: pointer, signs: SIMD3(signs.x, signs.y, gestures.orbitRollSign))
    }

    /// Orbits by a screen drag (points, y down) in the configured `dragRotation` direction.
    ///
    /// The one place a drag's orbit signs are applied: the viewport drag and the navigation cube
    /// both come through here, so they always turn the same way.
    func orbitDrag(delta: SIMD2<Float>) {
        if !cameraController.isOrbitDragActive { beginOrbitDrag(at: .zero) }
        let signed = delta * configuration.gestureConfiguration.orbitDragSigns
        handleOrbit(translation: CGSize(width: CGFloat(signed.x), height: CGFloat(signed.y)))
    }

    /// Releases an orbit drag with `velocity` (points per second, y down), signed like
    /// `orbitDrag(delta:)` so the momentum keeps turning the way the drag did.
    func endOrbitDrag(velocity: SIMD2<Float>) {
        let signed = velocity * configuration.gestureConfiguration.orbitDragSigns
        endOrbit(velocity: CGSize(width: CGFloat(signed.x), height: CGFloat(signed.y)))
    }

    private func endDrag(velocity: SIMD2<Float>) {
        endDrag(mode: activeInputDragMode, velocity: velocity)
        activeInputDragMode = .orbit
        inputDragPointer = nil
        pendingDragOrigin = nil
    }

    /// Ends the primary drag in progress as interrupted rather than released: no momentum, and
    /// never the slow-release snap to a nearby axis view.
    ///
    /// The touch view calls it when a second finger takes over a one-finger drag, or when a drag
    /// whose end never arrived (a cancelled gesture) is followed by a new one. Its end used to
    /// go out as a zero-velocity `.dragEnded`, which reads as a gentle release and snapped the
    /// view within 3° of an axis (issue #204). `onInputEvent` still sees a zero-velocity
    /// `.dragEnded`, so an input inspector shows the drag ending.
    func interruptDrag() {
        onInputEvent?(.dragEnded(velocity: .zero, modifiers: []))
        cameraController.endOrbitDrag()
        activeInputDragMode = .orbit
        inputDragPointer = nil
        pendingDragOrigin = nil
    }

    /// Ends the two-finger drag in progress as interrupted (its recognizer was cancelled): no
    /// momentum and no snap, as `interruptDrag()` does for the primary drag. `onInputEvent` sees
    /// a zero-velocity `.twoFingerPanEnded`.
    func interruptTwoFingerDrag() {
        onInputEvent?(.twoFingerPanEnded(velocity: .zero))
        twoFingerDragActive = false
        twoFingerDragPointer = nil
        pendingTwoFingerDragOrigin = nil
        cameraController.endOrbitDrag()
    }

    /// Applies release inertia for a two-finger drag interpreted as `action`.
    private func endDrag(_ action: GestureAction, velocity: SIMD2<Float>) {
        switch action {
        case .orbit: endDrag(mode: .orbit, velocity: velocity)
        case .pan: endDrag(mode: .pan, velocity: velocity)
        default: cameraController.endOrbitDrag()
        }
    }

    private func endDrag(mode: InputDragMode, velocity: SIMD2<Float>) {
        switch mode {
        case .orbit:
            endOrbitDrag(velocity: velocity)
        case .pan:
            cameraController.endOrbitDrag()
            endPan(
                velocity: CGSize(
                    width: CGFloat(velocity.x),
                    height: CGFloat(velocity.y)))
        case .zoom:
            cameraController.endOrbitDrag()
        }
    }
}
