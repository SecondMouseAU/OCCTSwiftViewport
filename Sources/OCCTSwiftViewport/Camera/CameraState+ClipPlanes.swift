// CameraState+ClipPlanes.swift
// ViewportKit
//
// Scene-adaptive near/far clip planes (issue #57). A fixed near=0.01 / far=10000
// range (ratio 1e6) collapses hyperbolic depth precision onto distant geometry,
// causing z-fighting. Deriving the range from the camera distance and scene
// radius keeps far/near ~1e3 at any model scale, preserving depth precision.

import simd

extension CameraState {

    /// Returns near/far clip planes fitted to the scene the camera is viewing.
    ///
    /// - Parameter sceneBounds: World-space AABB of the visible geometry, or `nil`
    ///   when unknown (e.g. an empty scene or before the first frame's buffers
    ///   exist), in which case a wide default is returned.
    /// - Returns: A `(near, far)` pair with a bounded ratio, so perspective depth
    ///   precision stays usable regardless of model scale.
    public func clipPlanes(sceneBounds: BoundingBox?) -> (near: Float, far: Float) {
        guard let bounds = sceneBounds else { return (0.01, 10_000) }

        let center = bounds.center
        let radius = max(bounds.diagonalLength * 0.5, 1e-4)
        let camDist = simd_length(position - center)

        // The near plane is a plane at a view-space depth, so fit it to the smallest view-space
        // depth of the AABB (a linear function, so its minimum is at a corner), not the Euclidean
        // distance to it. The distance is the depth only straight ahead: an AABB off to the side
        // of the view axis is nearer in depth than in distance, so a near plane at that distance
        // clipped the front of an obliquely viewed scene. A corner at or behind the camera plane
        // (camera inside the box, or beside it) gives depth 0, so the floor below takes over,
        // which also avoids the section-view artifact of #116.
        let forward = simd_normalize(viewDirection)
        var minDepthToBox = Float.greatestFiniteMagnitude
        for corner in 0..<8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? bounds.min.x : bounds.max.x,
                corner & 2 == 0 ? bounds.min.y : bounds.max.y,
                corner & 4 == 0 ? bounds.min.z : bounds.max.z)
            minDepthToBox = min(minDepthToBox, simd_dot(point - position, forward))
        }
        minDepthToBox = max(minDepthToBox, 0)

        // Far reaches past the back of the scene with margin; near sits just in front of the
        // scene but is clamped so far/near never exceeds ~1e4. Without the margin, geometry on
        // the camera-facing face of the AABB (a top-view box face, a flat panel, an edge-only
        // body) lands exactly on the near plane at NDC z = 0, and rounding clips it (#156).
        var far = (camDist + radius) * 2.0
        far = max(far, radius * 2.0)
        var near = max(minDepthToBox * (1 - Self.nearPlaneMargin), far * 1e-4)
        near = max(near, 1e-4)
        if near >= far { near = far * 1e-4 }
        return (near, far)
    }

    /// Fraction of the camera-to-scene distance the near plane is pulled back from the front of
    /// the scene bounds, so geometry on the AABB's camera-facing face sits at a small positive
    /// depth rather than exactly on the near plane. 1% costs a negligible share of depth
    /// precision (the far/near ratio rises by ~1%).
    static let nearPlaneMargin: Float = 0.01
}
