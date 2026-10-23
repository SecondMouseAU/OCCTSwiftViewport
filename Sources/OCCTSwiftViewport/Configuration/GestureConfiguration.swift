// GestureConfiguration.swift
// ViewportKit
//
// Configuration for gesture handling and input mapping.

import Foundation

/// Configuration for gesture handling in the viewport.
///
/// Defines sensitivity, key modifiers, and touch gesture mappings
/// for different platforms.
public struct GestureConfiguration: Sendable {

    // MARK: - Sensitivity

    /// Orbit sensitivity (radians per point of drag).
    public var orbitSensitivity: Float

    /// Pan speed as a multiple of the pointer's: `1` (the default) is 1:1.
    ///
    /// At `1` the point under the finger or pointer stays under it while panning: the world
    /// point at the pivot's depth in perspective, any point in orthographic. `2` pans twice as
    /// far as the pointer moves, `0.5` half as far.
    ///
    /// Before issue #200 the default was `0.005` world units per point, scaled by the camera
    /// distance, which panned about five times as far as the finger in an 800 pt tall view. A
    /// value carried over from then pans 200 times slower than 1:1; use `1` instead.
    public var panSensitivity: Float

    /// Pinch and drag-zoom sensitivity: the exponent applied to the gesture's magnification
    /// (`1` = unchanged, `2` = twice as fast, `0.5` = half as fast).
    public var zoomSensitivity: Float

    /// Scroll wheel zoom sensitivity.
    public var scrollZoomSensitivity: Float

    /// Minimum pan speed, in world units per point of drag.
    ///
    /// Default `0`.
    /// The 1:1 pan already tracks the pointer however close the camera is, so the default leaves
    /// it alone. A positive value speeds pan up wherever 1:1 would move less than that per
    /// point. It was `0.001` before issue #200, which broke 1:1 inside a distance of about 1.
    public var minPanSpeed: Float

    // MARK: - Orbit direction

    /// Which way an orbiting drag turns the view.
    ///
    /// Default ``DragRotationConvention/rotateObject``.
    ///
    /// Applies to every drag that resolves to `.orbit`: the iOS / visionOS one-finger (or
    /// two-finger) drag, the macOS mouse drag, the navigation cube, and the release momentum of
    /// each. `invertOrbitHorizontal` and `invertOrbitVertical` flip single axes on top of it.
    public var dragRotation: DragRotationConvention

    /// Flips the horizontal orbit direction on top of `dragRotation` (default `false`).
    ///
    /// Kept for source compatibility. Prefer `dragRotation`, which sets both axes at once; this
    /// remains a per-axis override. Before `dragRotation` existed the horizontal axis defaulted
    /// to the camera-orbit direction, and some apps set this to `true` to get the
    /// object-follows-finger feel. That is now the default, so such apps should drop the flag.
    public var invertOrbitHorizontal: Bool

    /// Flips the vertical orbit direction on top of `dragRotation` (default `false`).
    public var invertOrbitVertical: Bool

    /// Signs applied to an orbiting drag delta (points, y down) before it reaches
    /// `CameraController.orbit(deltaX:deltaY:)`.
    ///
    /// `CameraController.orbit` itself turns the model with the drag on both axes, so
    /// `.rotateObject` is `(1, 1)` and `.orbitCamera` is `(-1, -1)`; each invert flag then
    /// negates its axis. The drag, its momentum and the navigation cube all use these signs.
    public var orbitDragSigns: SIMD2<Float> {
        let base: Float = dragRotation == .rotateObject ? 1 : -1
        return SIMD2(
            invertOrbitHorizontal ? -base : base,
            invertOrbitVertical ? -base : base)
    }

    /// Which way an arcball drag outside the sphere rolls the view: `1` with the pointer for
    /// `.rotateObject`, `-1` against it for `.orbitCamera`.
    ///
    /// The invert flags name the horizontal and vertical axes, so they leave the roll alone.
    public var orbitRollSign: Float {
        dragRotation == .rotateObject ? 1 : -1
    }

    // MARK: - Inertia

    /// Whether to enable inertia (momentum) after gestures.
    public var enableInertia: Bool

    /// Damping factor for inertia (0 = no damping, 1 = instant stop).
    public var dampingFactor: Float

    /// Fraction of the release speed that orbit and pan momentum start with (default `0.06`).
    ///
    /// `1` carries the drag on at the speed the pointer was moving when released. The default
    /// keeps the short, gentle coast the viewport has always had: the release velocity used to
    /// be multiplied by 0.001 where the conversion from points per second to the camera's points
    /// per 1/60 s needed 1/60, which is `0.06` of the release speed. With the default
    /// `dampingFactor` of 0.1 the coast covers about `0.16 s × momentumScale` times the release
    /// speed: a 1500 pt/s flick coasts about 14 pt at the default and about 240 pt at `1`.
    /// `0` turns momentum off, as `enableInertia = false` does.
    public var momentumScale: Float

    // MARK: - iOS Gesture Mapping
    //
    // These also apply on visionOS, which uses the touch-style gesture path.

    /// Action for single-finger drag on iOS: `.orbit`, `.pan` or `.zoom`; anything else ignores it.
    public var singleFingerDrag: GestureAction

    /// Action for two-finger drag on iOS: `.orbit`, `.pan` or `.zoom`; anything else ignores it.
    public var twoFingerDrag: GestureAction

    /// Action for pinch gesture on iOS: `.zoom`; anything else ignores the pinch.
    public var pinchGesture: GestureAction

    /// Action for double-tap on iOS (default `.none`).
    ///
    /// Supports `.focusOnPoint` and `.resetView`; anything else ignores the double-tap. To bind
    /// view reset, prefer `resetViewTriggers`.
    public var doubleTap: GestureAction

    // MARK: - macOS Gesture Mapping

    /// Action for mouse drag (no modifier).
    public var mouseDrag: GestureAction

    /// Action for shift+drag.
    public var shiftDrag: GestureAction

    /// Action for option/alt+drag.
    public var optionDrag: GestureAction

    /// Action for command+drag.
    public var commandDrag: GestureAction

    /// Action for scroll wheel: `.zoom`; anything else ignores scrolling.
    public var scrollWheel: GestureAction

    /// Action for trackpad pinch: `.zoom`; anything else ignores the pinch.
    public var trackpadPinch: GestureAction

    /// Action for an unmodified double-click (default `.none`).
    ///
    /// Supports `.focusOnPoint` and `.resetView`; anything else ignores the double-click. To bind
    /// view reset, prefer `resetViewTriggers`.
    public var doubleClick: GestureAction

    // MARK: - View Reset

    /// Inputs that reset the camera to `ViewportConfiguration.initialCameraState`.
    ///
    /// Empty by default: nothing resets the view unless the app opts in. Each trigger is a key
    /// combination, a double-click with optional modifiers (macOS), or a double-tap (iOS /
    /// visionOS); list several to cover more than one platform or input style. The reset itself is
    /// `ViewportController.reset(animated:)`, which an app can also call from its own menu item or
    /// shortcut.
    ///
    /// ```swift
    /// var gestures = GestureConfiguration.default
    /// gestures.resetViewTriggers = [
    ///     .keyCombination(key: "h", modifiers: [.command, .shift]),
    ///     .doubleTap,
    /// ]
    /// ```
    public var resetViewTriggers: [ViewResetTrigger]

    /// Whether `key` with exactly `modifiers` held matches a `.keyCombination` reset trigger.
    ///
    /// Keys compare case-insensitively.
    public func resetsView(onKey key: Character, modifiers: ViewportModifierKeys) -> Bool {
        resetViewTriggers.contains { trigger in
            guard case .keyCombination(let bound, let boundModifiers) = trigger else {
                return false
            }
            return bound.lowercased() == key.lowercased() && boundModifiers == modifiers
        }
    }

    /// Whether a double-click with exactly `modifiers` held matches a `.doubleClick` reset trigger.
    public func resetsView(onDoubleClickWith modifiers: ViewportModifierKeys) -> Bool {
        resetViewTriggers.contains(.doubleClick(modifiers: modifiers))
    }

    /// Whether a `.doubleTap` reset trigger is configured.
    public var resetsViewOnDoubleTap: Bool {
        resetViewTriggers.contains(.doubleTap)
    }

    // MARK: - Initialization

    /// Creates a gesture configuration with the specified settings.
    public init(
        orbitSensitivity: Float = 0.005,
        panSensitivity: Float = 1,
        zoomSensitivity: Float = 1.0,
        scrollZoomSensitivity: Float = 0.25,
        minPanSpeed: Float = 0,
        dragRotation: DragRotationConvention = .rotateObject,
        invertOrbitHorizontal: Bool = false,
        invertOrbitVertical: Bool = false,
        enableInertia: Bool = true,
        dampingFactor: Float = 0.1,
        momentumScale: Float = 0.06,
        singleFingerDrag: GestureAction = .orbit,
        twoFingerDrag: GestureAction = .pan,
        pinchGesture: GestureAction = .zoom,
        doubleTap: GestureAction = .none,
        mouseDrag: GestureAction = .orbit,
        shiftDrag: GestureAction = .pan,
        optionDrag: GestureAction = .zoom,
        commandDrag: GestureAction = .select,
        scrollWheel: GestureAction = .zoom,
        trackpadPinch: GestureAction = .zoom,
        doubleClick: GestureAction = .none,
        resetViewTriggers: [ViewResetTrigger] = []
    ) {
        self.orbitSensitivity = orbitSensitivity
        self.panSensitivity = panSensitivity
        self.zoomSensitivity = zoomSensitivity
        self.scrollZoomSensitivity = scrollZoomSensitivity
        self.minPanSpeed = minPanSpeed
        self.dragRotation = dragRotation
        self.invertOrbitHorizontal = invertOrbitHorizontal
        self.invertOrbitVertical = invertOrbitVertical
        self.enableInertia = enableInertia
        self.dampingFactor = dampingFactor
        self.momentumScale = momentumScale
        self.singleFingerDrag = singleFingerDrag
        self.twoFingerDrag = twoFingerDrag
        self.pinchGesture = pinchGesture
        self.doubleTap = doubleTap
        self.mouseDrag = mouseDrag
        self.shiftDrag = shiftDrag
        self.optionDrag = optionDrag
        self.commandDrag = commandDrag
        self.scrollWheel = scrollWheel
        self.trackpadPinch = trackpadPinch
        self.doubleClick = doubleClick
        self.resetViewTriggers = resetViewTriggers
    }

    // MARK: - Presets

    // Every preset turns the model with the drag (`dragRotation = .rotateObject`). That is how
    // Blender's middle-mouse orbit and Fusion 360's orbit behave (the near side of the model
    // follows the pointer on both axes), as do Shapr3D, Onshape and SolidWorks; none of them
    // defaults to the camera-orbit direction.

    /// Default gesture configuration (Shapr3D-style).
    public static let `default` = GestureConfiguration()

    /// Blender-style gesture configuration.
    public static let blender = GestureConfiguration(
        mouseDrag: .select,
        shiftDrag: .pan,
        optionDrag: .orbit,
        commandDrag: .zoom
    )

    /// Fusion 360-style gesture configuration.
    public static let fusion360 = GestureConfiguration(
        mouseDrag: .select,
        shiftDrag: .orbit,
        optionDrag: .pan,
        commandDrag: .zoom
    )

    /// Gesture configuration tuned for visionOS spatial (indirect pinch + look)
    /// input in a window / volume (issue #36, Phase 2).
    ///
    /// Keeps the touch-style mapping (single pinch-drag orbits; two-handed
    /// pinch/twist zoom/roll via the magnify/rotate gestures), and raises inertia
    /// damping a little so momentum settles more predictably with indirect input.
    ///
    /// - Note: These are a sensible **starting point**. Indirect spatial input
    ///   ultimately feels different from a touchscreen, so the sensitivities are
    ///   best fine-tuned on Vision Pro hardware.
    public static let visionOS = GestureConfiguration(
        dampingFactor: 0.15
    )

    // MARK: - Input Interpretation

    /// Resolves the action for a pointer drag given the active modifier keys.
    ///
    /// Priority, matching the historical macOS handler, is
    /// command → shift → option → unmodified. This is the portable interpretation
    /// seam: platform code bridges its native modifier flags into
    /// `ViewportModifierKeys` (see its `init(_:)` overloads) and calls this, so the
    /// mapping stays free of `NSEvent` / `UIEvent`.
    public func dragAction(for modifiers: ViewportModifierKeys) -> GestureAction {
        if modifiers.contains(.command) { return commandDrag }
        if modifiers.contains(.shift) { return shiftDrag }
        if modifiers.contains(.option) { return optionDrag }
        return mouseDrag
    }
}

// MARK: - Drag Rotation Convention

/// How an orbiting drag maps onto the view: turn the model under the finger, or move the camera.
///
/// The two differ only in sign. With `.rotateObject` a drag to the right carries the near side of
/// the model to the right and a drag up carries it up, as if the finger were turning the object.
/// With `.orbitCamera` the drag moves the camera around the pivot instead, so the model appears
/// to turn the opposite way on both axes.
///
/// The convention holds for every `RotationStyle`. `.firstPerson` turns the camera in place
/// rather than about the pivot, so there `.rotateObject` drags the scene with the finger (drag
/// right and the view turns left, as in a touch panorama viewer) and `.orbitCamera` gives the
/// desktop mouse-look feel (drag right, look right). For `.arcball` the convention also sets
/// which way a drag outside the sphere rolls the view (`orbitRollSign`).
public enum DragRotationConvention: String, CaseIterable, Sendable {
    /// Grab and turn the model: its near side follows the drag on both axes (default).
    case rotateObject

    /// Move the camera around the pivot: the model appears to turn against the drag.
    case orbitCamera
}

// MARK: - View Reset Trigger

/// An input that resets the viewport camera.
///
/// See `GestureConfiguration.resetViewTriggers`.
public enum ViewResetTrigger: Sendable, Hashable {
    /// A key pressed with exactly `modifiers` held (macOS `MetalViewportView`, or any app that
    /// forwards keys to `ViewportController.handleKeyCombination(_:modifiers:)`).
    ///
    /// `key` is the unshifted character, compared case-insensitively: Shift+H is
    /// `.keyCombination(key: "h", modifiers: [.shift])`.
    case keyCombination(key: Character, modifiers: ViewportModifierKeys)

    /// A double-click with exactly `modifiers` held (macOS). Pass `[]` for a plain double-click.
    case doubleClick(modifiers: ViewportModifierKeys)

    /// A double-tap (iOS / visionOS).
    case doubleTap
}

// MARK: - Gesture Action

/// Actions that can be triggered by gestures.
public enum GestureAction: String, CaseIterable, Sendable {
    /// Orbit (rotate) the camera around the pivot.
    case orbit

    /// Pan the camera parallel to the view plane.
    case pan

    /// Zoom in/out.
    case zoom

    /// Select objects.
    case select

    /// Focus on a point under the cursor.
    case focusOnPoint

    /// Reset the view to default.
    case resetView

    /// No action.
    case none
}
