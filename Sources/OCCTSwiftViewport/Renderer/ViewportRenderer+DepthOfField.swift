// ViewportRenderer+DepthOfField.swift
// OCCTSwiftViewport
//
// The manual depth-of-field focus the composite pass is given (issue #217).

extension ViewportRenderer {

    /// The depth from the frame's eye the composite pass focuses at for a manual
    /// `dofFocalDistance`.
    ///
    /// In perspective that is `focalDistance`, measured from the eye. In orthographic the eye is
    /// only placed in front of the scene, and moves back whenever the scene's bounds grow, so a
    /// distance from it put the focal plane wherever the eye happened to be (#217). There
    /// `focalDistance` is measured from a reference eye `PivotStrategy.zoomDistance(of:)` in
    /// front of the pivot, the distance a perspective camera showing the same height would sit
    /// at. The focal plane stays put as the eye moves, a matching perspective framing focuses on
    /// the same plane, and the plane follows the pivot: a dynamic pivot slide moves it with the
    /// pivot, by the depth slid. A focal plane behind the eye focuses just in front of it.
    nonisolated static func manualFocusDistance(
        _ focalDistance: Float, cameraState: CameraState
    ) -> Float {
        guard cameraState.isOrthographic else { return focalDistance }
        let pastPivot = focalDistance - PivotStrategy.zoomDistance(of: cameraState)
        return max(cameraState.distance + pastPivot, 1e-3)
    }
}
