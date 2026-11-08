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
    ///   precision stays usable regardless of model scale. In orthographic the pair is
    ///   fitted to the scene's depth and is the same distance from the scene for every eye
    ///   position (`near` may be negative: see `orthographicClipPlanes`).
    public func clipPlanes(sceneBounds: BoundingBox?) -> (near: Float, far: Float) {
        guard let bounds = sceneBounds else { return (0.01, 10_000) }
        if isOrthographic { return orthographicClipPlanes(for: bounds) }

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
        let minDepthToBox = max(
            Self.nearestDepth(of: bounds, from: position, along: viewDirection), 0)

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

    /// How far past the front of the scene an orthographic far plane is, in scene diagonals.
    ///
    /// Three diagonals puts the back of a scene that is as deep as it is wide about a third of the
    /// way through the range, which is where a perspective view puts it, so the edge depth fade
    /// (and the SSAO and silhouette thresholds measured against the range) look as they do there.
    static let orthographicDepthSpan: Float = 3

    /// The orthographic near/far planes: fitted to the scene's own depth, not to the eye.
    ///
    /// An orthographic view looks the same wherever the eye is on the line of sight, and its
    /// depth is linear, so none of perspective's reasons for a far/near ratio apply and neither
    /// plane has to be in front of the eye. `near` sits `nearPlaneMargin` of the scene's radius in
    /// front of its nearest corner and `far` a fixed `orthographicDepthSpan` scene diagonals
    /// behind that. Both depend on the scene alone: the distance from the front of the scene to
    /// each plane is the same for every eye, so the edge depth fade and the SSAO / silhouette
    /// thresholds are too (they used to follow `far = 2 * (eyeDistance + radius)`, and a
    /// dragged eye changed them, #217). `near` is negative when the eye is inside the scene,
    /// which a projection matrix allows: nothing is cut away, and the eye needn't be moved back
    /// out of the model to avoid it (`placingOrthographicEye` still does, for a camera built
    /// before this fit).
    private func orthographicClipPlanes(for bounds: BoundingBox) -> (near: Float, far: Float) {
        let diagonal = max(bounds.diagonalLength, 2e-4)
        let nearest = Self.nearestDepth(of: bounds, from: position, along: viewDirection)
        let near = nearest - diagonal * 0.5 * Self.nearPlaneMargin
        return (near, near + diagonal * Self.orthographicDepthSpan)
    }

    /// Fraction of the camera-to-scene distance the near plane is pulled back from the front of
    /// the scene bounds, so geometry on the AABB's camera-facing face sits at a small positive
    /// depth rather than exactly on the near plane. 1% costs a negligible share of depth
    /// precision (the far/near ratio rises by ~1%).
    static let nearPlaneMargin: Float = 0.01

    /// Returns an orthographic copy whose eye sits in front of `bounds`, so nothing in them is
    /// behind the eye or near-clipped (issue #211).
    ///
    /// An orthographic view does not depend on where the eye is along the view axis: it shows
    /// `orthographicScale` wherever the eye is. The clip planes `clipPlanes(sceneBounds:)` fits
    /// no longer depend on it either (they follow the scene, and `near` may sit behind the eye,
    /// #217), but an eye inside the scene is still a bad place for everything else that reads
    /// `position`, such as a ray that starts at the eye. This moves the eye back along the line
    /// of sight, by raising `distance` with the pivot and rotation kept, until the nearest
    /// corner of `bounds` is one scene radius (half the box's diagonal) in front of it. The
    /// picture and the depth range are the same.
    ///
    /// An eye already that far in front, a perspective camera (whose eye is the view) or `nil`
    /// bounds return the camera unchanged. The eye is only ever moved back, never forward.
    ///
    /// `CameraController` applies this after every camera change when it has a
    /// `sceneBoundsProvider` (`MetalViewportView` sets one), so an orthographic zoom, orbit or
    /// pan never takes the eye into the model. `OffscreenRenderer` applies it to the camera it
    /// renders (#215). Call it yourself before using a camera you built some other way.
    ///
    /// - Parameter bounds: World-space bounds of the scene, or `nil` when unknown.
    /// - Returns: The camera with its eye in front of `bounds`.
    public func placingOrthographicEye(inFrontOf bounds: BoundingBox?) -> CameraState {
        guard isOrthographic, let bounds else { return self }
        let nearest = Self.nearestDepth(of: bounds, from: position, along: viewDirection)
        let clearance = max(bounds.diagonalLength * 0.5, 1e-4)
        guard nearest.isFinite, nearest < clearance else { return self }
        var copy = self
        copy.distance += clearance - nearest
        return copy
    }

    /// The smallest view-space depth of the corners of `bounds` seen from `eye` along `forward`.
    ///
    /// Depth is linear, so its minimum over the box is at a corner. Negative when part of the
    /// box is behind the eye.
    static func nearestDepth(
        of bounds: BoundingBox, from eye: SIMD3<Float>, along forward: SIMD3<Float>
    ) -> Float {
        let forward = simd_normalize(forward)
        var nearest = Float.greatestFiniteMagnitude
        for corner in 0..<8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? bounds.min.x : bounds.max.x,
                corner & 2 == 0 ? bounds.min.y : bounds.max.y,
                corner & 4 == 0 ? bounds.min.z : bounds.max.z)
            nearest = min(nearest, simd_dot(point - eye, forward))
        }
        return nearest
    }
}
