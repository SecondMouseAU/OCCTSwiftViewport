// ViewCubeRegion.swift
// ViewportKit
//
// Defines the 26 clickable regions of a ViewCube.

import Foundation
import simd

/// A clickable region on the ViewCube.
///
/// The ViewCube has 26 regions:
/// - 6 faces (top, bottom, front, back, left, right)
/// - 12 edges (connections between adjacent faces)
/// - 8 corners (where three faces meet)
public enum ViewCubeRegion: String, CaseIterable, Sendable {

    // MARK: - Faces (6)

    case top
    case bottom
    case front
    case back
    case left
    case right

    // MARK: - Edges (12)

    case topFront
    case topBack
    case topLeft
    case topRight
    case bottomFront
    case bottomBack
    case bottomLeft
    case bottomRight
    case frontLeft
    case frontRight
    case backLeft
    case backRight

    // MARK: - Corners (8)

    case topFrontLeft
    case topFrontRight
    case topBackLeft
    case topBackRight
    case bottomFrontLeft
    case bottomFrontRight
    case bottomBackLeft
    case bottomBackRight

    // MARK: - Properties

    /// Whether this region is a face.
    public var isFace: Bool {
        switch self {
        case .top, .bottom, .front, .back, .left, .right:
            return true
        default:
            return false
        }
    }

    /// Whether this region is an edge.
    public var isEdge: Bool {
        switch self {
        case .topFront, .topBack, .topLeft, .topRight,
            .bottomFront, .bottomBack, .bottomLeft, .bottomRight,
            .frontLeft, .frontRight, .backLeft, .backRight:
            return true
        default:
            return false
        }
    }

    /// Whether this region is a corner.
    public var isCorner: Bool {
        switch self {
        case .topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight,
            .bottomFrontLeft, .bottomFrontRight, .bottomBackLeft, .bottomBackRight:
            return true
        default:
            return false
        }
    }

    /// Display name for the region.
    public var displayName: String {
        switch self {
        // Faces
        case .top: return "Top"
        case .bottom: return "Bottom"
        case .front: return "Front"
        case .back: return "Back"
        case .left: return "Left"
        case .right: return "Right"

        // Edges
        case .topFront: return "Top-Front"
        case .topBack: return "Top-Back"
        case .topLeft: return "Top-Left"
        case .topRight: return "Top-Right"
        case .bottomFront: return "Bottom-Front"
        case .bottomBack: return "Bottom-Back"
        case .bottomLeft: return "Bottom-Left"
        case .bottomRight: return "Bottom-Right"
        case .frontLeft: return "Front-Left"
        case .frontRight: return "Front-Right"
        case .backLeft: return "Back-Left"
        case .backRight: return "Back-Right"

        // Corners
        case .topFrontLeft: return "Top-Front-Left"
        case .topFrontRight: return "Top-Front-Right"
        case .topBackLeft: return "Top-Back-Left"
        case .topBackRight: return "Top-Back-Right"
        case .bottomFrontLeft: return "Bottom-Front-Left"
        case .bottomFrontRight: return "Bottom-Front-Right"
        case .bottomBackLeft: return "Bottom-Back-Left"
        case .bottomBackRight: return "Bottom-Back-Right"
        }
    }

    /// The standard view associated with this region (for faces only).
    public var standardView: StandardView? {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .front: return .front
        case .back: return .back
        case .left: return .left
        case .right: return .right
        default: return nil
        }
    }

    /// Camera state for this region.
    ///
    /// - Parameters:
    ///   - pivot: The point to look at
    ///   - distance: Distance from pivot
    /// - Returns: A camera state positioned for this view
    public func cameraState(
        pivot: SIMD3<Float> = .zero,
        distance: Float = 10.0
    ) -> CameraState {
        let rotation: simd_quatf

        switch self {
        // Faces - same as standard views
        case .top:
            rotation = StandardView.top.rotation
        case .bottom:
            rotation = StandardView.bottom.rotation
        case .front:
            rotation = StandardView.front.rotation
        case .back:
            rotation = StandardView.back.rotation
        case .left:
            rotation = StandardView.left.rotation
        case .right:
            rotation = StandardView.right.rotation

        // Edges - combinations of two views
        case .topFront:
            rotation = interpolateRotation(
                StandardView.top.rotation, StandardView.front.rotation, 0.5)
        case .topBack:
            rotation = interpolateRotation(
                StandardView.top.rotation, StandardView.back.rotation, 0.5)
        case .topLeft:
            rotation = interpolateRotation(
                StandardView.top.rotation, StandardView.left.rotation, 0.5)
        case .topRight:
            rotation = interpolateRotation(
                StandardView.top.rotation, StandardView.right.rotation, 0.5)
        case .bottomFront:
            rotation = interpolateRotation(
                StandardView.bottom.rotation, StandardView.front.rotation, 0.5)
        case .bottomBack:
            rotation = interpolateRotation(
                StandardView.bottom.rotation, StandardView.back.rotation, 0.5)
        case .bottomLeft:
            rotation = interpolateRotation(
                StandardView.bottom.rotation, StandardView.left.rotation, 0.5)
        case .bottomRight:
            rotation = interpolateRotation(
                StandardView.bottom.rotation, StandardView.right.rotation, 0.5)
        case .frontLeft:
            rotation = interpolateRotation(
                StandardView.front.rotation, StandardView.left.rotation, 0.5)
        case .frontRight:
            rotation = interpolateRotation(
                StandardView.front.rotation, StandardView.right.rotation, 0.5)
        case .backLeft:
            rotation = interpolateRotation(
                StandardView.back.rotation, StandardView.left.rotation, 0.5)
        case .backRight:
            rotation = interpolateRotation(
                StandardView.back.rotation, StandardView.right.rotation, 0.5)

        // Corners - isometric-like views
        case .topFrontLeft:
            rotation = StandardView.isometricFrontLeft.rotation
        case .topFrontRight:
            rotation = StandardView.isometricFrontRight.rotation
        case .topBackLeft:
            rotation = StandardView.isometricBackLeft.rotation
        case .topBackRight:
            rotation = StandardView.isometricBackRight.rotation
        case .bottomFrontLeft:
            rotation = bottomCornerRotation(frontLeft: true)
        case .bottomFrontRight:
            rotation = bottomCornerRotation(frontRight: true)
        case .bottomBackLeft:
            rotation = bottomCornerRotation(backLeft: true)
        case .bottomBackRight:
            rotation = bottomCornerRotation(backRight: true)
        }

        return CameraState(
            rotation: rotation,
            distance: distance,
            pivot: pivot
        )
    }
}

// MARK: - Helper Functions

private func interpolateRotation(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
    simd_slerp(a, b, t)
}

private func bottomCornerRotation(
    frontLeft: Bool = false,
    frontRight: Bool = false,
    backLeft: Bool = false,
    backRight: Bool = false
) -> simd_quatf {
    // Bottom corners look up from below
    let tiltAngle = Float(atan(1.0 / sqrt(2.0)))  // ~35.264°

    let zAngle: Float
    if frontRight {
        zAngle = -.pi / 4
    } else if frontLeft {
        zAngle = .pi / 4
    } else if backRight {
        zAngle = -.pi * 3 / 4
    } else {  // backLeft
        zAngle = .pi * 3 / 4
    }

    let rotZ = simd_quatf(angle: zAngle, axis: SIMD3<Float>(0, 0, 1))
    let rotX = simd_quatf(angle: .pi / 2 + tiltAngle, axis: SIMD3<Float>(1, 0, 0))

    return rotX * rotZ
}
