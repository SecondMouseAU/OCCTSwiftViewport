// ViewportController+SceneBounds.swift
// OCCTSwiftViewport
//
// The viewport's own cached world bounds of the scene, for an app that needs them on each camera
// move (issue #252).

extension ViewportController {

    /// World-space bounds of the visible geometry-layer `bodies`, from the controller's own cache.
    ///
    /// A body is rescanned only when its bounds change, never for a `transform` change alone, so
    /// this is cheap on every camera move. See `docs/reference/Views.md`.
    ///
    /// - Returns: The union of the bounds, or `nil` when no visible geometry-layer body has any
    ///   geometry, an empty array included.
    public func sceneBounds(of bodies: [ViewportBody]) -> BoundingBox? {
        pivotStrategy.sceneBounds(of: bodies, pruning: false)
    }
}
