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

    /// Pinch zoom sensitivity.
    public var zoomSensitivity: Float

    /// Scroll wheel zoom sensitivity.
    public var scrollZoomSensitivity: Float

    /// Minimum pan speed floor (prevents pan stalling when zoomed in very close).
    public var minPanSpeed: Float

    // MARK: - Inertia

    /// Whether to enable inertia (momentum) after gestures.
    public var enableInertia: Bool

    /// Damping factor for inertia (0 = no damping, 1 = instant stop).
    public var dampingFactor: Float

    // MARK: - iOS Gesture Mapping

    /// Action for single-finger drag on iOS.
    public var singleFingerDrag: GestureAction

    /// Action for two-finger drag on iOS.
    public var twoFingerDrag: GestureAction

    /// Action for pinch gesture on iOS.
    public var pinchGesture: GestureAction

    /// Action for double-tap on iOS.
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

    /// Action for scroll wheel.
    public var scrollWheel: GestureAction

    /// Action for trackpad pinch.
    public var trackpadPinch: GestureAction

    /// Action for double-click.
    public var doubleClick: GestureAction

    // MARK: - Initialization

    /// Creates a gesture configuration with the specified settings.
    public init(
        orbitSensitivity: Float = 0.005,
        panSensitivity: Float = 0.005,
        zoomSensitivity: Float = 1.0,
        scrollZoomSensitivity: Float = 0.25,
        minPanSpeed: Float = 0.001,
        enableInertia: Bool = true,
        dampingFactor: Float = 0.1,
        singleFingerDrag: GestureAction = .orbit,
        twoFingerDrag: GestureAction = .pan,
        pinchGesture: GestureAction = .zoom,
        doubleTap: GestureAction = .focusOnPoint,
        mouseDrag: GestureAction = .orbit,
        shiftDrag: GestureAction = .pan,
        optionDrag: GestureAction = .zoom,
        commandDrag: GestureAction = .select,
        scrollWheel: GestureAction = .zoom,
        trackpadPinch: GestureAction = .zoom,
        doubleClick: GestureAction = .focusOnPoint
    ) {
        self.orbitSensitivity = orbitSensitivity
        self.panSensitivity = panSensitivity
        self.zoomSensitivity = zoomSensitivity
        self.scrollZoomSensitivity = scrollZoomSensitivity
        self.minPanSpeed = minPanSpeed
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
    /// Priority — matching the historical macOS handler — is
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
