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
    /// glue it already owns (e.g. dynamic-pivot scheduling). All *interpretation* —
    /// which `GestureAction` a drag maps to, the orbit X-axis inversion, the
    /// drag-to-zoom curve — lives here, so the meaning is identical regardless of
    /// the input source.
    public func dispatch(_ event: ViewportInputEvent) {
        onInputEvent?(event)

        switch event {
        case let .dragChanged(delta, modifiers):
            apply(dragDelta: delta, modifiers: modifiers)

        case let .dragEnded(velocity, _):
            endDrag(velocity: velocity)

        case let .twoFingerPanChanged(translation):
            handlePan(translation: CGSize(width: CGFloat(translation.x),
                                          height: CGFloat(translation.y)))

        case let .twoFingerPanEnded(velocity):
            endPan(velocity: CGSize(width: CGFloat(velocity.x),
                                    height: CGFloat(velocity.y)))

        case let .pinchChanged(scale):
            handleZoom(magnification: CGFloat(scale))

        case .pinchEnded:
            break

        case let .rotateChanged(radians):
            handleRoll(angle: CGFloat(radians))

        case .rotateEnded:
            break

        case let .scroll(delta, cursorNDC, aspectRatio):
            handleScrollZoom(delta: CGFloat(delta),
                             cursorNormalized: cursorNDC,
                             aspectRatio: aspectRatio)

        case let .tap(_, count):
            if count >= 2 { reset(animated: true) }
        }
    }

    // MARK: - Drag interpretation

    /// Resolves the action for a primary drag. macOS uses modifier-aware
    /// `dragAction(for:)`; iOS (no modifiers) uses `singleFingerDrag`.
    private func resolvedDragAction(_ modifiers: ViewportModifierKeys) -> GestureAction {
        #if os(macOS)
        return configuration.gestureConfiguration.dragAction(for: modifiers)
        #else
        return configuration.gestureConfiguration.singleFingerDrag
        #endif
    }

    private func apply(dragDelta delta: SIMD2<Float>, modifiers: ViewportModifierKeys) {
        switch resolvedDragAction(modifiers) {
        case .orbit:
            activeInputDragMode = .orbit
            // Negate X so left/right drag rotates the model under the pointer.
            handleOrbit(translation: CGSize(width: CGFloat(-delta.x),
                                            height: CGFloat(delta.y)))
        case .pan:
            activeInputDragMode = .pan
            handlePan(translation: CGSize(width: CGFloat(delta.x),
                                          height: CGFloat(delta.y)))
        case .zoom:
            activeInputDragMode = .zoom
            handleZoom(magnification: CGFloat(1.0 + delta.y * 0.02))
        default:
            // .select / .focusOnPoint / .resetView / .none don't drive a drag;
            // leave activeInputDragMode unchanged (matches the historical handler).
            break
        }
    }

    private func endDrag(velocity: SIMD2<Float>) {
        switch activeInputDragMode {
        case .orbit:
            endOrbit(velocity: CGSize(width: CGFloat(-velocity.x),
                                      height: CGFloat(velocity.y)))
        case .pan:
            endPan(velocity: CGSize(width: CGFloat(velocity.x),
                                    height: CGFloat(velocity.y)))
        case .zoom:
            break
        }
        activeInputDragMode = .orbit
    }
}
