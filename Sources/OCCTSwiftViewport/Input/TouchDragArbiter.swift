// TouchDragArbiter.swift
// ViewportKit
//
// Arbitration between the touch view's one-finger drag and its two-finger pan (issue #200).
// Kept free of SwiftUI and UIKit so the rules can be unit-tested on any platform.

import CoreGraphics
import simd

/// Decides which one-finger drag changes reach the input router while two-finger pans come and
/// go, and makes sure every drag that began is ended.
///
/// On iOS and visionOS a two-finger pan also drives SwiftUI's one-finger `DragGesture`, so the
/// one-finger drag must stand aside while the pan runs. This used to be an `isPanning` flag that
/// only the one-finger drag's end cleared. A two-finger pan that never started the one-finger
/// drag left the flag set, and the next one-finger drag was swallowed whole. A one-finger orbit
/// interrupted by a second finger was never ended, so the router kept its stale pointer and the
/// next drag continued it. And `DragGesture` does not call `onEnded` when it is cancelled, which
/// left a stale translation that made the next drag jump.
///
/// The rules now:
/// - The pan's own end clears the pan, whether or not the one-finger drag ever fired.
/// - A pan that begins during a one-finger drag ends that drag at once, with no momentum, and
///   the rest of that drag is ignored, even after the second finger lifts.
/// - A drag whose start differs from the last one is a new drag, even if the last one's end
///   never arrived; that one is ended first.
/// - A drag ended for either reason is *interrupted*, not released: it ends with no momentum and
///   never snaps to a nearby axis view (issue #204). Its end used to go out as a `.dragEnded`
///   with zero velocity, which looks like a slow release and snapped within 3° of an axis.
struct TouchDragArbiter {

    /// What the view should do for one gesture callback, in order: interrupt the last drag, set
    /// the drag origin, then dispatch the events.
    struct Step: Equatable {
        /// Whether to end the drag in progress as interrupted, with
        /// `ViewportController.interruptDrag()`, before anything else.
        var interruptsDrag = false
        /// Where the drag starts, in points from the view centre (y down), for
        /// `ViewportController.setDragOrigin(offsetFromCenter:)`.
        var dragOrigin: SIMD2<Float>?
        /// Events to dispatch, in order.
        var events: [ViewportInputEvent] = []
    }

    /// Whether a two-finger pan is in progress.
    private(set) var isTwoFingerPanActive = false

    /// The start location of the one-finger drag the callbacks belong to.
    private var dragStart: CGPoint?

    /// The drag's translation at the last change, to turn the next one into a delta.
    private var lastTranslation: CGSize = .zero

    /// Whether a `.dragChanged` went out for this drag and its `.dragEnded` has not.
    private var dragDispatched = false

    /// Whether this drag met a two-finger pan, so the rest of it is ignored.
    private var dragSuppressed = false

    /// A one-finger drag changed.
    ///
    /// - Parameters:
    ///   - start: The drag's start location, in view points (top-left origin).
    ///   - translation: The drag's translation from `start`.
    ///   - viewSize: The view's size in points.
    /// - Returns: The origin to set, if the drag begins here, and the events to dispatch.
    mutating func dragChanged(start: CGPoint, translation: CGSize, viewSize: CGSize) -> Step {
        var step = Step()
        if dragStart != start {
            // A new drag. If the last one never got its end (a cancelled gesture), end it now.
            if dragDispatched { step.interruptsDrag = true }
            dragStart = start
            lastTranslation = .zero
            dragDispatched = false
            dragSuppressed = false
        }
        if isTwoFingerPanActive || dragSuppressed {
            dragSuppressed = true
            if dragDispatched {
                step.interruptsDrag = true
                dragDispatched = false
            }
            lastTranslation = translation
            return step
        }
        if !dragDispatched {
            step.dragOrigin = SIMD2(
                Float(start.x - viewSize.width / 2), Float(start.y - viewSize.height / 2))
            dragDispatched = true
        }
        let delta = SIMD2(
            Float(translation.width - lastTranslation.width),
            Float(translation.height - lastTranslation.height))
        lastTranslation = translation
        step.events.append(.dragChanged(delta: delta, modifiers: []))
        return step
    }

    /// The one-finger drag ended with `velocity` (points per second).
    ///
    /// - Returns: The drag's end, if a `.dragChanged` went out for it.
    mutating func dragEnded(velocity: CGSize) -> Step {
        var step = Step()
        if dragDispatched {
            step.events.append(
                .dragEnded(
                    velocity: SIMD2(Float(velocity.width), Float(velocity.height)), modifiers: []))
        }
        dragStart = nil
        lastTranslation = .zero
        dragDispatched = false
        dragSuppressed = false
        return step
    }

    /// A two-finger pan began.
    ///
    /// A one-finger drag in progress ends here, interrupted: no momentum, no snap.
    ///
    /// - Returns: A step that interrupts that drag, if one went out.
    mutating func twoFingerPanBegan() -> Step {
        isTwoFingerPanActive = true
        var step = Step()
        if dragStart != nil { dragSuppressed = true }
        if dragDispatched {
            step.interruptsDrag = true
            dragDispatched = false
        }
        return step
    }

    /// The two-finger pan ended or was cancelled.
    mutating func twoFingerPanEnded() {
        isTwoFingerPanActive = false
    }
}
