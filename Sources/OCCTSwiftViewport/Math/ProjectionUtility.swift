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
    /// - Returns: The screen-space CGPoint, or `nil` if the point is behind the camera (see
    ///   ``worldToNDC(point:vpMatrix:)`` for how that is decided).
    public static func worldToScreen(
        point: SIMD3<Float>,
        vpMatrix: simd_float4x4,
        viewportSize: CGSize
    ) -> CGPoint? {
        guard let ndc = worldToNDC(point: point, vpMatrix: vpMatrix) else { return nil }

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
    ///
    /// "Behind the camera" is decided by view-space depth. Under a perspective projection the
    /// clip-space `w` is that depth, so a point at `w <= 0.001` is behind. Under an orthographic
    /// projection `w` is always 1, which said every point was in front, so a point behind an
    /// orthographic camera was drawn mirrored onto the view (issue #208). There the depth is read
    /// from NDC z instead: a point with z < 0 is nearer than the near plane, which for the
    /// matrices this library builds sits in front of the camera, so it is culled with
    /// everything behind the camera, as the renderer clips it.
    public static func worldToNDC(
        point: SIMD3<Float>,
        vpMatrix: simd_float4x4
    ) -> SIMD3<Float>? {
        let clip = vpMatrix * SIMD4<Float>(point.x, point.y, point.z, 1.0)
        let affine = isAffine(vpMatrix)
        if affine {
            // Orthographic: w carries no depth, so cull by NDC z (view-space depth, linearly).
            guard clip.w > 0 else { return nil }
        }
        guard frontDistance(clip, affine: affine) >= 0 else { return nil }
        return SIMD3<Float>(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    /// A world-space segment projected to the screen, cut where it passes behind the camera.
    struct ScreenSegment: Equatable {
        /// Screen point of the segment's first end, or of where it is cut.
        var start: CGPoint
        /// Screen point of the segment's second end, or of where it is cut.
        var end: CGPoint
        /// Whether `start` is the first end itself (`worldToScreen` projects it).
        var startIsEndpoint: Bool
        /// Whether `end` is the second end itself.
        var endIsEndpoint: Bool

        /// The screen point halfway between `start` and `end`.
        var midpoint: CGPoint {
            CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        }
    }

    /// Projects the segment from `a` to `b` to the screen, keeping the part in front of the
    /// camera.
    ///
    /// "In front" is what ``worldToNDC(point:vpMatrix:)`` projects: in front of the near plane
    /// in orthographic, just in front of the eye in perspective. A segment with one end behind
    /// is cut where it crosses that plane, so a measurement whose endpoint is culled still draws
    /// its visible part instead of vanishing (issue #211). The cut is made in clip space, which
    /// is linear in the world point, so the cut point lies on the segment.
    ///
    /// - Returns: The visible part, or `nil` when the whole segment is behind.
    static func clippedSegmentToScreen(
        from a: SIMD3<Float>, to b: SIMD3<Float>, vpMatrix: simd_float4x4, viewportSize: CGSize
    ) -> ScreenSegment? {
        let affine = isAffine(vpMatrix)
        let clipA = vpMatrix * SIMD4<Float>(a, 1)
        let clipB = vpMatrix * SIMD4<Float>(b, 1)
        let frontA = frontDistance(clipA, affine: affine)
        let frontB = frontDistance(clipB, affine: affine)
        guard frontA >= 0 || frontB >= 0 else { return nil }

        // Where the segment crosses frontDistance = 0, from the end in front toward the other.
        func cut(from front: SIMD4<Float>, _ f: Float, to behind: SIMD4<Float>, _ b: Float)
            -> SIMD4<Float>
        {
            front + (behind - front) * (f / (f - b))
        }
        let visibleA = frontA >= 0 ? clipA : cut(from: clipB, frontB, to: clipA, frontA)
        let visibleB = frontB >= 0 ? clipB : cut(from: clipA, frontA, to: clipB, frontB)
        guard visibleA.w > 0, visibleB.w > 0 else { return nil }
        return ScreenSegment(
            start: screenPoint(visibleA, viewportSize: viewportSize),
            end: screenPoint(visibleB, viewportSize: viewportSize),
            startIsEndpoint: frontA >= 0, endIsEndpoint: frontB >= 0)
    }

    /// How far `clip` is in front of where projection stops, in clip units.
    ///
    /// NDC z (the near plane) in orthographic, `w − 0.001` (just in front of the eye) in
    /// perspective. Linear in the clip coordinates, so a segment can be cut where it is zero.
    private static func frontDistance(_ clip: SIMD4<Float>, affine: Bool) -> Float {
        affine ? clip.z : clip.w - 0.001
    }

    /// Clip coordinates to a top-left-origin screen point.
    private static func screenPoint(_ clip: SIMD4<Float>, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: CGFloat((clip.x / clip.w + 1) * 0.5) * viewportSize.width,
            y: CGFloat((1 - clip.y / clip.w) * 0.5) * viewportSize.height)
    }

    /// Whether `matrix` leaves `w` alone (bottom row `0 0 0 1`), as an orthographic
    /// view-projection does and a perspective one does not.
    private static func isAffine(_ matrix: simd_float4x4) -> Bool {
        let tolerance: Float = 1e-6
        return abs(matrix.columns.0.w) < tolerance && abs(matrix.columns.1.w) < tolerance
            && abs(matrix.columns.2.w) < tolerance && abs(matrix.columns.3.w - 1) < tolerance
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
