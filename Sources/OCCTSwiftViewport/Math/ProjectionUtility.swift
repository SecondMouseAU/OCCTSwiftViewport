// ProjectionUtility.swift
// ViewportKit
//
// Utility for projecting 3D world points to 2D screen coordinates.

import CoreGraphics
import simd

/// Utility for converting between world coordinates and screen coordinates.
public enum ProjectionUtility {

    /// Projects a 3D world point to 2D screen coordinates.
    ///
    /// - Parameters:
    ///   - point: The 3D world position.
    ///   - vpMatrix: The combined view-projection matrix.
    ///   - viewportSize: The viewport size in points.
    /// - Returns: The screen-space CGPoint, or `nil` if the point is behind the camera.
    public static func worldToScreen(
        point: SIMD3<Float>,
        vpMatrix: simd_float4x4,
        viewportSize: CGSize
    ) -> CGPoint? {
        let clip = vpMatrix * SIMD4<Float>(point.x, point.y, point.z, 1.0)

        // Behind the camera
        guard clip.w > 0.001 else { return nil }

        // Perspective divide → NDC [-1, 1]
        let ndc = SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)

        // NDC to screen (origin at top-left, Y-down)
        let x = CGFloat((ndc.x + 1.0) * 0.5) * viewportSize.width
        let y = CGFloat((1.0 - ndc.y) * 0.5) * viewportSize.height

        return CGPoint(x: x, y: y)
    }

    /// Projects a 3D world point to normalized device coordinates.
    ///
    /// - Parameters:
    ///   - point: The 3D world position.
    ///   - vpMatrix: The combined view-projection matrix.
    /// - Returns: NDC coordinates (x, y in [-1,1], z for depth), or `nil` if behind camera.
    public static func worldToNDC(
        point: SIMD3<Float>,
        vpMatrix: simd_float4x4
    ) -> SIMD3<Float>? {
        let clip = vpMatrix * SIMD4<Float>(point.x, point.y, point.z, 1.0)
        guard clip.w > 0.001 else { return nil }
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    /// Computes the distance between two 3D points.
    public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_length(b - a)
    }

    /// Computes the angle (in degrees) between three 3D points (vertex at `b`).
    public static func angle(_ a: SIMD3<Float>, vertex b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float
    {
        let ba = simd_normalize(a - b)
        let bc = simd_normalize(c - b)
        let cosAngle = simd_clamp(simd_dot(ba, bc), -1.0, 1.0)
        return acosf(cosAngle) * (180.0 / .pi)
    }

    /// Computes the midpoint between two 3D points.
    public static func midpoint(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        (a + b) * 0.5
    }
}
