// RendererSharedSetup+Orthographic.swift
// OCCTSwiftViewport
//
// Orthographic helpers shared by ViewportRenderer and OffscreenRenderer (issue #215): the bounds
// the eye is placed in front of, the view vector lit shading takes, and the transparent sort key.

import simd

extension RendererSharedSetup {

    /// The bounds an orthographic eye is kept in front of: the model, the axes and the overlays.
    ///
    /// The eye was placed in front of the geometry-layer bounds alone, while the clip planes are
    /// fitted to those plus the axes and the in-view overlays, so an overlay widget or the axes
    /// reaching toward the camera past the model could be in front of the eye and near-clipped
    /// (#215). None of these depends on the pivot, so a pivot that slides along the line of sight
    /// still never moves the eye:
    ///
    /// - the model (`modelBounds`);
    /// - the axes when they show;
    /// - every visible overlay, in view or not. The frustum test needs the camera being placed,
    ///   which the camera's provider does not get.
    ///
    /// The overlays count only up to four model diagonals past the model, as `clipFitBounds`
    /// caps them for the clip fit: both cap around `overlayCapBasis` (the model and the axes), so
    /// an overlay the clip fit takes in is never in front of the eye, and a huge widget can't
    /// push the eye, and with it the far plane and the edge depth fade, far back. The axes count
    /// at their full length, with their base radius: `.constantScreenWidth` axes zoomed far out
    /// are drawn thicker than that (see `overlayCapBasis`).
    /// The grid is left out: the window drawn follows the pivot, which would move the eye on a
    /// pivot update, and the whole `gridSize` square moved the eye of every orthographic scene
    /// far back.
    ///
    /// - Parameters:
    ///   - modelBounds: World bounds of the visible geometry-layer bodies.
    ///   - bodies: Scene bodies; only visible overlay-layer ones are read.
    ///   - settings: The axis settings the frame draws with.
    ///   - showAxes: Whether the axes are drawn.
    ///   - localBounds: A body's local-space box, before `transform`.
    /// - Returns: The bounds to pass to `CameraState.placingOrthographicEye(inFrontOf:)`.
    static func orthographicEyeBounds(
        modelBounds: BoundingBox?,
        bodies: [ViewportBody],
        settings: GridAxisSettings,
        showAxes: Bool,
        localBounds: (ViewportBody) -> BoundingBox? = { $0.boundingBox }
    ) -> BoundingBox? {
        clipFitBounds(
            overlayCapBasis(modelBounds: modelBounds, settings: settings, showAxes: showAxes),
            includingOverlaysOf: bodies, in: nil, localBounds: localBounds)
    }

    /// The model and, when they show, the axes: the box both the orthographic clip fit and the
    /// eye placement cap overlays around (see `clipFitBounds`).
    ///
    /// The clip fit capped them around its whole fit, grid window included, which grows with
    /// zoom and the pivot, while the eye can't use the grid window; an overlay between the two
    /// caps was fitted but left in front of the eye (#215). The axes count at their full length,
    /// as `GridAxisGeometry.clipBounds` takes them, but with their base radius: the world radius
    /// of `.constantScreenWidth` axes follows the camera being placed, which the camera's
    /// provider does not get.
    ///
    /// `nil` with no model and the axes hidden: the eye placement then counts overlays uncapped,
    /// while the clip fit caps them around its own bounds, so the eye is still in front of all
    /// the clip fit takes in.
    static func overlayCapBasis(
        modelBounds: BoundingBox?, settings: GridAxisSettings, showAxes: Bool
    ) -> BoundingBox? {
        guard showAxes, settings.axisLength > 0, settings.axisLength.isFinite else {
            return modelBounds
        }
        let axes = BoundingBox(
            min: SIMD3(repeating: -settings.axisRadius),
            max: SIMD3(repeating: settings.axisLength + settings.axisRadius))
        return modelBounds.map { $0.union(axes) } ?? axes
    }

    /// The eye position the shaders take the view vector of lit shading from (`cameraPosition`).
    ///
    /// The shaded fragment computes the vector toward the viewer as
    /// `normalize(cameraPosition - worldPosition)`. In orthographic every view ray is parallel,
    /// so that vector is the same everywhere, minus the view direction; from the real eye it bent
    /// toward the eye like a perspective one, and specular, Fresnel rim and environment lighting
    /// changed wherever the eye was placed along the line of sight, which in orthographic only
    /// fits the clip planes (#215). This returns a point so far back along the line of sight
    /// that the vector is constant to a small fraction of a degree, scaled with the eye's
    /// distance and the pivot's magnitude, so float precision keeps up with large scenes. In
    /// perspective it is the eye.
    ///
    /// - Parameters:
    ///   - cameraState: The camera the frame is drawn with.
    ///   - orthographic: Whether the frame's projection is orthographic.
    /// - Returns: The world position to pass as `cameraPosition`.
    static func shadingEyePosition(
        of cameraState: CameraState, orthographic: Bool
    ) -> SIMD3<Float> {
        guard orthographic else { return cameraState.position }
        let scale = max(cameraState.distance, simd_length(cameraState.pivot), 1)
        return cameraState.pivot - simd_normalize(cameraState.viewDirection) * scale * 1e4
    }

    /// The depth a translucent body is sorted back-to-front by: its world-space centre's
    /// distance from the eye in perspective, its depth along the line of sight in orthographic.
    ///
    /// Orthographic rays are parallel, so what is behind what is decided by depth alone; the
    /// distance from the eye also counted how far off-axis a centre lies, and sorted a nearer
    /// body off to the side behind a deeper one on the axis (#215). It also depended on where
    /// the eye sits, which in orthographic is only clip-plane placement.
    static func transparentSortDepth(center: SIMD3<Float>, cameraState: CameraState) -> Float {
        let offset = center - cameraState.position
        guard cameraState.isOrthographic else { return simd_length(offset) }
        return simd_dot(offset, simd_normalize(cameraState.viewDirection))
    }
}
