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
    /// X-axis inversion, the drag-to-zoom curve) lives here, so the meaning is
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
            applyDrag(configuration.gestureConfiguration.twoFingerDrag, delta: translation)

        case .twoFingerPanEnded(let velocity):
            endDrag(configuration.gestureConfiguration.twoFingerDrag, velocity: velocity)

        case .pinchChanged(let scale):
            guard resolvedPinchAction == .zoom else { break }
            handleZoom(magnification: CGFloat(scale))

        case .pinchAtChanged(let scale, let centerNDC, let aspectRatio):
            guard resolvedPinchAction == .zoom else { break }
            handleZoom(
                magnification: CGFloat(scale), centerNormalized: centerNDC, aspectRatio: aspectRatio
            )

        case .pinchEnded:
            break

        case .rotateChanged(let radians):
            handleRoll(angle: CGFloat(radians))

        case .rotateEnded:
            break

        case .scroll(let delta, let cursorNDC, let aspectRatio):
            guard configuration.gestureConfiguration.scrollWheel == .zoom else { break }
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
    /// (issue #163).
    private func focus(atNDC ndc: SIMD2<Float>) {
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: lastAspectRatio)
        guard
            let hit = SceneRaycast.cast(
                ray: ray, bodies: inputSceneBodies, clipPlanes: clipPlanes)
        else { return }
        focusOn(point: hit.point, animated: true)
    }

    // MARK: - Drag interpretation

    /// Drag-zoom rate: log zoom per point of vertical drag, before `zoomSensitivity` applies.
    static let dragZoomRate: Float = 0.02

    private func apply(dragDelta delta: SIMD2<Float>, modifiers: ViewportModifierKeys) {
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
        applyDrag(action, delta: delta)
    }

    /// Applies one drag increment as `action`, for both the primary and the two-finger drag.
    private func applyDrag(_ action: GestureAction, delta: SIMD2<Float>) {
        switch action {
        case .orbit:
            // Negate X so left/right drag rotates the model under the pointer; the invert flags let a
            // consumer flip either axis to taste (object-follows-finger vs camera-orbits).
            let cfg = configuration.gestureConfiguration
            let sx: CGFloat = cfg.invertOrbitHorizontal ? 1 : -1
            let sy: CGFloat = cfg.invertOrbitVertical ? -1 : 1
            handleOrbit(
                translation: CGSize(
                    width: sx * CGFloat(delta.x),
                    height: sy * CGFloat(delta.y)))
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

    private func endDrag(velocity: SIMD2<Float>) {
        endDrag(mode: activeInputDragMode, velocity: velocity)
        activeInputDragMode = .orbit
    }

    /// Applies release inertia for a two-finger drag interpreted as `action`.
    private func endDrag(_ action: GestureAction, velocity: SIMD2<Float>) {
        switch action {
        case .orbit: endDrag(mode: .orbit, velocity: velocity)
        case .pan: endDrag(mode: .pan, velocity: velocity)
        default: break
        }
    }

    private func endDrag(mode: InputDragMode, velocity: SIMD2<Float>) {
        switch mode {
        case .orbit:
            let cfg = configuration.gestureConfiguration
            let sx: CGFloat = cfg.invertOrbitHorizontal ? 1 : -1
            let sy: CGFloat = cfg.invertOrbitVertical ? -1 : 1
            endOrbit(
                velocity: CGSize(
                    width: sx * CGFloat(velocity.x),
                    height: sy * CGFloat(velocity.y)))
        case .pan:
            endPan(
                velocity: CGSize(
                    width: CGFloat(velocity.x),
                    height: CGFloat(velocity.y)))
        case .zoom:
            break
        }
    }
}
