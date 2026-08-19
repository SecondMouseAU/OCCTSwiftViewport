// ClipPlane.swift
// ViewportKit
//
// Value type representing a clipping/section plane.

import simd

/// A clipping plane that removes geometry on its negative side.
///
/// The plane equation is `dot(normal, point) + distance = 0`.
/// Fragments where `dot(normal, point) + distance < 0` are discarded.
///
/// ## Example
///
/// ```swift
/// // Clip everything below Y = 0
/// let plane = ClipPlane(normal: SIMD3(0, 1, 0), distance: 0)
///
/// // Clip everything to the left of X = 2
/// let plane = ClipPlane(normal: SIMD3(1, 0, 0), distance: -2)
/// ```
public struct ClipPlane: Sendable, Equatable {
    /// Outward-facing normal of the clip plane (unit vector).
    public var normal: SIMD3<Float>

    /// Signed distance from the origin along the normal.
    /// `dot(normal, P) + distance < 0` clips fragment P.
    public var distance: Float

    /// Whether this clip plane is active.
    public var isEnabled: Bool

    /// Creates a clip plane.
    ///
    /// - Parameters:
    ///   - normal: Outward-facing normal (will be normalized).
    ///   - distance: Signed distance from origin.
    ///   - isEnabled: Whether the plane is active.
    public init(normal: SIMD3<Float> = SIMD3(0, 1, 0), distance: Float = 0, isEnabled: Bool = true)
    {
        self.normal = simd_normalize(normal)
        self.distance = distance
        self.isEnabled = isEnabled
    }

    /// Returns the plane equation as a float4 (xyz = normal, w = distance).
    public var asFloat4: SIMD4<Float> {
        SIMD4<Float>(normal.x, normal.y, normal.z, distance)
    }

    /// A clip plane that cuts at Y = 0 (removes geometry below the ground plane).
    public static let groundPlane = ClipPlane(normal: SIMD3(0, 1, 0), distance: 0)

    /// A clip plane that cuts at X = 0 (removes geometry on the negative-X side).
    public static let xPlane = ClipPlane(normal: SIMD3(1, 0, 0), distance: 0)

    /// A clip plane that cuts at Z = 0 (removes geometry on the negative-Z side).
    public static let zPlane = ClipPlane(normal: SIMD3(0, 0, 1), distance: 0)
}
