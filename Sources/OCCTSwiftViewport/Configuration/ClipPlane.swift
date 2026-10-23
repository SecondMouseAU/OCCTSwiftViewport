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
/// Every pass that draws scene geometry applies the test, the GPU pick pass included, so
/// clipped geometry is neither visible nor pickable. CPU `SceneRaycast` skips clipped hits when
/// passed the planes, which the dynamic pivot does. The shadow map and `OffscreenRenderer` do
/// not apply clip planes.
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
///
/// The renderer applies at most ``maxActivePlanes`` (4) enabled planes at once, taken in array
/// order from `ViewportController.clipPlanes`. Enabled planes beyond that are not applied, and
/// debug builds log a warning when `clipPlanes` is set with more.
public struct ClipPlane: Sendable, Equatable {
    /// Maximum number of enabled clip planes the renderer applies at once.
    ///
    /// The shader uniform holds four planes; enabled planes past the fourth are dropped.
    public static let maxActivePlanes = 4

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

    /// A clip plane that cuts at Z = 0 (removes geometry below the ground plane).
    ///
    /// The world is Z-up (the turntable orbits Z and the grid lies in the XY plane), so the ground
    /// is Z = 0 and this equals `zPlane`. Up to v1.2.2 it cut at Y = 0; use `yPlane` for that.
    public static let groundPlane = ClipPlane(normal: SIMD3(0, 0, 1), distance: 0)

    /// A clip plane that cuts at Y = 0 (removes geometry on the negative-Y side).
    public static let yPlane = ClipPlane(normal: SIMD3(0, 1, 0), distance: 0)

    /// A clip plane that cuts at X = 0 (removes geometry on the negative-X side).
    public static let xPlane = ClipPlane(normal: SIMD3(1, 0, 0), distance: 0)

    /// A clip plane that cuts at Z = 0 (removes geometry on the negative-Z side).
    public static let zPlane = ClipPlane(normal: SIMD3(0, 0, 1), distance: 0)

    /// Splits `planes` into the enabled planes the renderer applies and how many enabled planes
    /// it drops for exceeding ``maxActivePlanes``.
    static func activePlanes(in planes: [ClipPlane]) -> (applied: [ClipPlane], dropped: Int) {
        let enabled = planes.filter(\.isEnabled)
        let applied = Array(enabled.prefix(maxActivePlanes))
        return (applied, enabled.count - applied.count)
    }
}
