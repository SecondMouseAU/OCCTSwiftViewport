// PivotStrategy.swift
// ViewportKit
//
// Dynamic pivot heuristic: adjusts orbit center based on visible geometry.

import simd

/// Configuration for automatic pivot adjustment.
public struct DynamicPivotConfiguration: Sendable {

    /// Whether dynamic pivot adjustment is enabled.
    public var isEnabled: Bool

    /// Duration of the pivot animation in seconds.
    public var animationDuration: Float

    /// Zoom ratio at which the pivot switches from the scene center to the raycast hit point.
    ///
    /// Measured as `cameraDistance / sceneDiagonalLength`, so it is scene-size independent:
    /// above the threshold the camera is "zoomed out" and orbits the whole scene, below it the
    /// camera orbits whatever is under the cursor.
    public var zoomThreshold: Float

    /// Fraction of `zoomThreshold` used for the smoothstep blend band.
    public var blendBand: Float

    public init(
        isEnabled: Bool = true,
        animationDuration: Float = 0.15,
        zoomThreshold: Float = 0.5,
        blendBand: Float = 0.3
    ) {
        self.isEnabled = isEnabled
        self.animationDuration = animationDuration
        self.zoomThreshold = zoomThreshold
        self.blendBand = blendBand
    }

    /// Default configuration.
    public static let `default` = DynamicPivotConfiguration()
}

/// Computes a dynamic orbit pivot based on camera zoom level and visible geometry.
@MainActor
public final class PivotStrategy {

    /// Cached body-local bounding boxes keyed by body ID.
    ///
    /// Local, not world: the cache is keyed on `generation`, which does not change when only a
    /// body's `transform` does, so the transform is applied at use instead.
    private var bbCache: [String: BoundingBox] = [:]

    /// Generation counter per body for cache invalidation.
    private var generationCache: [String: UInt64] = [:]

    public init() {}

    /// Computes the ideal pivot point.
    ///
    /// The result is always on the line of sight through the view centre: the view-centre
    /// raycast hit when zoomed in, the point at the scene centre's depth when zoomed out, and a
    /// blend of the two between. Moving the pivot there therefore never moves the view.
    ///
    /// - Parameters:
    ///   - cameraState: Current camera state.
    ///   - bodies: Visible scene bodies.
    ///   - aspectRatio: Viewport width / height.
    ///   - config: Dynamic pivot configuration.
    ///   - clipPlanes: Section planes in effect. The view-centre raycast skips geometry they
    ///     remove, so the pivot lands on what is actually drawn (issue #163). Defaults to none.
    /// - Returns: The computed pivot, or `nil` if disabled, no geometry is visible, the scene
    ///   centre is behind the camera, or the raycast misses closer in.
    public func computePivot(
        cameraState: CameraState,
        bodies: [ViewportBody],
        aspectRatio: Float,
        config: DynamicPivotConfiguration,
        clipPlanes: [ClipPlane] = []
    ) -> SIMD3<Float>? {
        guard config.isEnabled else { return nil }

        // Update bounding box cache
        updateCache(bodies: bodies)

        // Compute scene bounding box
        guard let sceneBB = sceneBoundingBox(bodies: bodies) else { return nil }
        let diagonal = sceneBB.diagonalLength
        guard diagonal > 0 else { return nil }

        // The scene centre at its depth on the line of sight, not the centre itself: moving the
        // pivot to an off-axis centre moved the camera across with it, which undid a pan on
        // every release (issue #204). On the line of sight, a pivot change never moves the view.
        let forward = cameraState.viewDirection
        let sceneDepth = simd_dot(sceneBB.center - cameraState.position, forward)
        guard sceneDepth > 0 else { return nil }
        let sceneCenter = cameraState.position + forward * sceneDepth
        let zoomRatio = cameraState.distance / diagonal
        let halfBand = config.zoomThreshold * config.blendBand * 0.5

        // Fully zoomed out: orbit about the scene's depth.
        if zoomRatio > config.zoomThreshold + halfBand {
            return sceneCenter
        }

        // Cast ray through view center
        let ray = Ray.throughViewCenter(cameraState: cameraState, aspectRatio: aspectRatio)
        let hit = SceneRaycast.cast(
            ray: ray, bodies: bodies, boundingBoxCache: bbCache, clipPlanes: clipPlanes)

        // A miss closer in keeps the current pivot (the user may have panned away on purpose).
        guard let hitPoint = hit?.point else { return nil }

        // Fully zoomed in: use raycast hit
        if zoomRatio < config.zoomThreshold - halfBand {
            return hitPoint
        }

        // Blend zone: smoothstep between hit and scene center
        let t = smoothstep(
            edge0: config.zoomThreshold - halfBand,
            edge1: config.zoomThreshold + halfBand,
            x: zoomRatio
        )
        return hitPoint + (sceneCenter - hitPoint) * t
    }

    /// Casts `ray` against `bodies` using this strategy's bounding-box cache.
    ///
    /// Same defaults as ``SceneRaycast/cast(ray:bodies:clipPlanes:includeWidgets:includeNonPickable:)``,
    /// but a body's box is only recomputed when its `generation` changes, so focus-on-point does
    /// not rescan every body's geometry on each double-tap.
    func raycast(ray: Ray, bodies: [ViewportBody], clipPlanes: [ClipPlane]) -> RaycastHit? {
        updateCache(bodies: bodies)
        return SceneRaycast.cast(
            ray: ray, bodies: bodies, boundingBoxCache: bbCache, clipPlanes: clipPlanes)
    }

    /// Invalidates the bounding box cache.
    public func invalidateCache() {
        bbCache.removeAll()
        generationCache.removeAll()
    }

    /// Exposes the current bounding box cache (for SceneRaycast).
    internal var boundingBoxCache: [String: BoundingBox] {
        bbCache
    }

    // MARK: - Private

    private func updateCache(bodies: [ViewportBody]) {
        // Track which IDs are still present
        var activeIDs = Set<String>()

        for body in bodies {
            activeIDs.insert(body.id)
            // Hidden and overlay bodies are used by neither the scene bounds nor the raycast, so
            // they are not scanned (issue #180). A stale entry left from when one was used is
            // harmless: it is never read, and a body that becomes visible again is refreshed by
            // its generation check here.
            guard body.isVisible && body.renderLayer == .geometry else { continue }

            // Skip if generation hasn't changed
            if generationCache[body.id] == body.generation { continue }

            // Recompute BB
            if let bb = body.boundingBox {
                bbCache[body.id] = bb
            } else {
                bbCache.removeValue(forKey: body.id)
            }
            generationCache[body.id] = body.generation
        }

        // Prune stale entries
        for key in bbCache.keys where !activeIDs.contains(key) {
            bbCache.removeValue(forKey: key)
            generationCache.removeValue(forKey: key)
        }
    }

    /// World-space union of the cached bounds of `bodies`, each moved by its current `transform`.
    ///
    /// Hidden and `.overlay` bodies are left out, as in the renderer's scene bounds, so a hidden
    /// part or an always-on-top widget doesn't drag the zoomed-out pivot off the visible model.
    private func sceneBoundingBox(bodies: [ViewportBody]) -> BoundingBox? {
        var result: BoundingBox?
        for body in bodies where body.isVisible && body.renderLayer == .geometry {
            guard let bb = bbCache[body.id]?.transformed(by: body.transform) else { continue }
            if let existing = result {
                result = existing.union(bb)
            } else {
                result = bb
            }
        }
        return result
    }

    private func smoothstep(edge0: Float, edge1: Float, x: Float) -> Float {
        let t = simd_clamp((x - edge0) / (edge1 - edge0), 0, 1)
        return t * t * (3 - 2 * t)
    }
}
