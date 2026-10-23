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

    /// Pan sensitivity multiplier.
    public var panSensitivity: Float

    /// Pinch and drag-zoom sensitivity: the exponent applied to the gesture's magnification
    /// (`1` = unchanged, `2` = twice as fast, `0.5` = half as fast).
    public var zoomSensitivity: Float

    /// Scroll wheel zoom sensitivity.
    public var scrollZoomSensitivity: Float

    /// Minimum pan speed floor (prevents pan stalling when zoomed in very close).
    public var minPanSpeed: Float

    // MARK: - Orbit direction

    /// Inverts horizontal orbit, so a left or right drag turns the model the opposite way.
    ///
    /// Which direction feels correct is a user expectation, not a correctness question: some
    /// people read the gesture as "grab the model and drag it", with the object following the
    /// finger, rather than as the camera orbiting around a stationary model.
    public var invertOrbitHorizontal: Bool

    /// Invert vertical orbit (up/down drag).
    public var invertOrbitVertical: Bool

    // MARK: - Inertia

    /// Whether to enable inertia (momentum) after gestures.
    public var enableInertia: Bool

    /// Damping factor for inertia (0 = no damping, 1 = instant stop).
    public var dampingFactor: Float

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
        panSensitivity: Float = 0.005,
        zoomSensitivity: Float = 1.0,
        scrollZoomSensitivity: Float = 0.25,
        minPanSpeed: Float = 0.001,
        invertOrbitHorizontal: Bool = false,
        invertOrbitVertical: Bool = false,
        enableInertia: Bool = true,
        dampingFactor: Float = 0.1,
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
        self.invertOrbitHorizontal = invertOrbitHorizontal
        self.invertOrbitVertical = invertOrbitVertical
        self.enableInertia = enableInertia
        self.dampingFactor = dampingFactor
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
