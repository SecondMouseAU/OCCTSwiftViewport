// RotationStyle.swift
// ViewportKit
//
// Camera rotation behavior styles.

import Foundation

/// Defines how camera rotation behaves in response to drag gestures.
///
/// Different CAD applications use different rotation models. This enum
/// allows configuration of the rotation behavior to match user preferences.
public enum RotationStyle: String, CaseIterable, Sendable {

    /// Arcball (trackball) rotation - unrestricted 3D rotation.
    ///
    /// Uses Ken Shoemake's arcball: the pointer is placed on a virtual sphere centred on the
    /// view, and the rotation runs from where the drag began to where the pointer is now.
    /// Dragging on the sphere rotates around axes perpendicular to the drag; dragging around the
    /// centre outside the sphere rolls the view about the line of sight.
    ///
    /// Best for: Freeform 3D modeling, inspecting objects from any angle.
    case arcball

    /// Turntable rotation - Z-axis locked, like a pottery wheel.
    ///
    /// Horizontal drag rotates around the world Z (up) axis. Vertical drag tilts the camera up
    /// and down without a limit, so it can tilt over the pole; a drag that begins upside down
    /// reverses the horizontal turn so the model still follows the pointer.
    ///
    /// Best for: Architectural visualization, map-like views, CAD where
    /// "up" should always be up.
    case turntable

    /// First-person look-around: the camera turns in place.
    ///
    /// Horizontal drag yaws about world Z; vertical drag pitches about the camera's right vector.
    /// The camera stays where it is and the pivot moves with the view, `distance` in front of it.
    /// With `GestureConfiguration.dragRotation` at `.rotateObject` (the default) the scene
    /// follows the drag, as in a touch panorama viewer (drag right, the view turns left);
    /// `.orbitCamera` gives the mouse-look feel of first-person game controls (drag right, look
    /// right).
    ///
    /// Best for: Walk-through visualizations, VR-style navigation.
    case firstPerson

    // MARK: - Properties

    /// Human-readable description of this rotation style.
    public var description: String {
        switch self {
        case .arcball:
            return "Free rotation in any direction"
        case .turntable:
            return "Rotate around vertical axis, tilt up/down"
        case .firstPerson:
            return "Look around from camera position"
        }
    }

    /// Whether this style constrains rotation to prevent gimbal lock issues.
    public var hasConstraints: Bool {
        switch self {
        case .arcball:
            return false
        case .turntable, .firstPerson:
            return true
        }
    }

    /// Recommended default for CAD applications.
    public static let cadDefault: RotationStyle = .turntable

    /// Recommended default for artistic/modeling applications.
    public static let modelingDefault: RotationStyle = .arcball
}
