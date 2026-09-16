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

        // Compute actual minimum distance from camera to the AABB.
        // This correctly handles the case when the camera is inside the scene bounds
        // (returns 0), avoiding the section-view artifact where the near plane
        // cut through geometry as the camera entered the bounding sphere.
        let minDistToBox = bounds.distance(to: position)

        // Far reaches past the back of the scene with margin; near hugs the front
        // of the scene but is clamped so far/near never exceeds ~1e4.
        var far = (camDist + radius) * 2.0
        far = max(far, radius * 2.0)
        var near = max(minDistToBox, far * 1e-4)
        near = max(near, 1e-4)
        if near >= far { near = far * 1e-4 }
        return (near, far)
    }
}
