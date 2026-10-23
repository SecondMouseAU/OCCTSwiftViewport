// TouchPinchRotate.swift
// ViewportKit
//
// The touch view's pinch and rotation, as input events (issue #204). Kept free of SwiftUI and
// UIKit so the conversion can be unit-tested on any platform.

import CoreGraphics
import simd

/// Turns the touch view's pinch and rotation recognizer steps into `ViewportInputEvent`s.
///
/// The touch view used SwiftUI's `MagnifyGesture` and `RotateGesture`. Neither calls `onEnded`
/// when it is cancelled, so the last cumulative value it kept to turn the next one into a step
/// went stale, and the first step of the next pinch or twist was skewed by it. And
/// `MagnifyGesture` reports only where the pinch started, so the zoom stayed anchored there
/// while the fingers moved. The view now uses UIKit's pinch and rotation recognizers, which
/// report a cancel and the touches' current centroid. Each recognizer's value is reset after
/// every step, so there is no cumulative value to go stale.
enum TouchPinchRotate {

    /// A point in the view (top-left origin, y down) in normalized device coordinates
    /// (−1…+1, y up). `.zero`, the view centre, when the view has no size.
    static func ndc(_ location: CGPoint, viewSize: CGSize) -> SIMD2<Float> {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        return SIMD2(
            Float(location.x / viewSize.width) * 2 - 1,
            Float(1 - location.y / viewSize.height) * 2 - 1)
    }

    /// The event for one pinch step: zoom by `scale` toward `centroid`, where the fingers are
    /// now.
    ///
    /// - Parameters:
    ///   - scale: The scale since the last step (1 = no change).
    ///   - centroid: The touches' centroid now, in view points (top-left origin).
    ///   - viewSize: The view's size in points.
    /// - Returns: `nil` for a non-positive scale or an empty view.
    static func pinchStep(scale: CGFloat, centroid: CGPoint, viewSize: CGSize)
        -> ViewportInputEvent?
    {
        guard scale > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        return .pinchAtChanged(
            scale: Float(scale), centerNDC: ndc(centroid, viewSize: viewSize),
            aspectRatio: Float(viewSize.width / viewSize.height))
    }
}
