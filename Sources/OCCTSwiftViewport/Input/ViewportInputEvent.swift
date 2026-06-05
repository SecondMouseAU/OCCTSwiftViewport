// ViewportInputEvent.swift
// ViewportKit
//
// Portable, source-neutral input event model — an Aspect_Touch / Aspect_VKey
// analogue. Platform layers translate native input into these; the viewport
// interprets them via ViewportController.dispatch(_:). Synthetic / XR / test
// input can produce the same events without any AppKit / UIKit type.

import simd

/// A platform-neutral viewport input event.
///
/// Deltas and velocities are raw (in points / points-per-second); the *meaning*
/// (which gesture action, sign conventions, zoom curve) is applied centrally by
/// `ViewportController.dispatch(_:)`, never by the platform translation layer.
///
/// This is the seam that lets non-AppKit/UIKit input sources — visionOS / XR,
/// Catalyst, scripting, tests — drive the camera through one entry point.
public enum ViewportInputEvent: Sendable, Equatable {

    /// Primary pointer drag changed (mouse on macOS, single finger on iOS).
    /// `modifiers` is empty on iOS.
    case dragChanged(delta: SIMD2<Float>, modifiers: ViewportModifierKeys)

    /// Primary pointer drag ended, carrying release velocity for inertia.
    case dragEnded(velocity: SIMD2<Float>, modifiers: ViewportModifierKeys)

    /// Secondary translation changed (two-finger pan on iOS).
    case twoFingerPanChanged(translation: SIMD2<Float>)

    /// Secondary translation ended, carrying release velocity.
    case twoFingerPanEnded(velocity: SIMD2<Float>)

    /// Pinch changed, as an incremental scale ratio (1.0 = no change).
    case pinchChanged(scale: Float)

    /// Pinch ended.
    case pinchEnded

    /// Rotate changed, as an incremental angle in radians.
    case rotateChanged(radians: Float)

    /// Rotate ended.
    case rotateEnded

    /// Scroll-wheel input toward a cursor position (macOS).
    case scroll(delta: Float, cursorNDC: SIMD2<Float>, aspectRatio: Float)

    /// A tap / click at normalized-device coordinates. `count >= 2` resets the view;
    /// single taps are observational here (picking runs on its own renderer-bound path).
    case tap(ndc: SIMD2<Float>, count: Int)
}
