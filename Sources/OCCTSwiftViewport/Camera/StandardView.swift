// StandardView.swift
// ViewportKit
//
// Predefined standard viewing angles for CAD applications.

import Foundation
import simd

/// Standard view orientations commonly used in CAD applications.
///
/// Each case represents a predefined camera orientation. Views can be
/// animated to using `ViewportController.animateTo(_:)`.
///
/// ## Example
///
/// ```swift
/// // Animate to top view
/// controller.animateTo(StandardView.top.cameraState())
///
/// // Get isometric from a specific direction
/// let state = StandardView.isometricFrontRight.cameraState(distance: 50)
/// ```
public enum StandardView: String, CaseIterable, Sendable {

    // MARK: - Orthographic Views

    /// Top view (plan view) - looking down Z axis.
    case top

    /// Bottom view - looking up Z axis.
    case bottom

    /// Front view (elevation) - looking along -Y axis.
    case front

    /// Back view - looking along +Y axis.
    case back

    /// Right view - looking along -X axis.
    case right

    /// Left view - looking along +X axis.
    case left

    // MARK: - Isometric Views

    /// Isometric view from front-right-top corner.
    case isometricFrontRight

    /// Isometric view from front-left-top corner.
    case isometricFrontLeft

    /// Isometric view from back-right-top corner.
    case isometricBackRight

    /// Isometric view from back-left-top corner.
    case isometricBackLeft

    // MARK: - Properties

    /// Human-readable name for this view.
    public var displayName: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .front: return "Front"
        case .back: return "Back"
        case .right: return "Right"
        case .left: return "Left"
        case .isometricFrontRight: return "Isometric"
        case .isometricFrontLeft: return "Isometric (Front Left)"
        case .isometricBackRight: return "Isometric (Back Right)"
        case .isometricBackLeft: return "Isometric (Back Left)"
        }
    }

    /// Single-character keyboard shortcut for this view.
    public var keyboardShortcut: Character? {
        switch self {
        case .top: return "t"
        case .front: return "f"
        case .right: return "r"
        case .left: return "l"
        case .isometricFrontRight: return "i"
        default: return nil
        }
    }

    /// Whether this is an orthographic projection view.
    public var isOrthographic: Bool {
        switch self {
        case .top, .bottom, .front, .back, .right, .left:
            return true
        case .isometricFrontRight, .isometricFrontLeft, .isometricBackRight, .isometricBackLeft:
            return false
        }
    }

    // MARK: - Rotation

    /// Rotation quaternion for this view.
    ///
    /// The rotation represents the camera orientation such that:
    /// - Camera looks along its local -Z axis
    /// - Camera up is along its local +Y axis
    public var rotation: simd_quatf {
        // Z-UP world (the turntable orbits Z; the navigation cube's top face is +Z). Rotation maps
        // CAMERA space → world: look = rotation.act(0,0,-1), up = rotation.act(0,1,0).
        //
        // Identity therefore IS the top view (camera above, looking down −Z, +Y north). Side views
        // tilt the camera onto the horizon first (rotX π/2 → front), then yaw around world-Z. The
        // previous implementation mixed a Y-up front-is-identity convention with Z-axis yaws — a yaw
        // about Z does NOTHING to a −Z look direction, so front/back/left/right were all the same
        // top-down view (the "every cube click goes to top" bug).
        let front = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))   // look +Y, up +Z
        func yawed(_ angle: Float) -> simd_quatf {
            simd_normalize(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)) * front)
        }
        // Isometric: tilt 54.7356° from the zenith (35.264° above the horizon), then yaw to a corner.
        let isoTilt = simd_quatf(angle: .pi / 2 - Float(atan(1.0 / sqrt(2.0))), axis: SIMD3<Float>(1, 0, 0))
        func iso(_ yaw: Float) -> simd_quatf {
            simd_normalize(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 0, 1)) * isoTilt)
        }

        switch self {
        case .top:    return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))        // look −Z
        case .bottom: return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))      // look +Z
        case .front:  return front                                                    // look +Y
        case .back:   return yawed(.pi)                                               // look −Y
        case .left:   return yawed(-.pi / 2)                                          // look +X
        case .right:  return yawed(.pi / 2)                                           // look −X
        case .isometricFrontRight: return iso(.pi / 4)
        case .isometricFrontLeft:  return iso(-.pi / 4)
        case .isometricBackRight:  return iso(.pi * 3 / 4)
        case .isometricBackLeft:   return iso(-.pi * 3 / 4)
        }
    }

    // MARK: - Camera State

    /// Creates a CameraState for this standard view.
    ///
    /// - Parameters:
    ///   - pivot: The point to look at (default: origin)
    ///   - distance: Distance from pivot (default: 10)
    ///   - fieldOfView: Field of view for perspective (default: 45°)
    ///   - orthographicScale: Scale for orthographic (default: 10)
    /// - Returns: A CameraState positioned for this view
    public func cameraState(
        pivot: SIMD3<Float> = .zero,
        distance: Float = 10.0,
        fieldOfView: Float = 45.0,
        orthographicScale: Float = 10.0
    ) -> CameraState {
        CameraState(
            rotation: rotation,
            distance: distance,
            pivot: pivot,
            fieldOfView: fieldOfView,
            orthographicScale: orthographicScale,
            isOrthographic: isOrthographic,
            panOffset: .zero
        )
    }
}

// MARK: - ViewCube Region Mapping

extension StandardView {
    /// Maps ViewCube face regions to standard views.
    public static func fromViewCubeFace(_ face: ViewCubeFace) -> StandardView {
        switch face {
        case .top: return .top
        case .bottom: return .bottom
        case .front: return .front
        case .back: return .back
        case .right: return .right
        case .left: return .left
        }
    }
}

/// ViewCube face identifiers.
public enum ViewCubeFace: String, CaseIterable, Sendable {
    case top, bottom, front, back, right, left
}
