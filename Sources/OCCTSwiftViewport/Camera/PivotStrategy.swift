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

    /// Cached bounding boxes keyed by body ID.
    private var bbCache: [String: BoundingBox] = [:]

    /// Generation counter per body for cache invalidation.
    private var generationCache: [String: UInt64] = [:]

    public init() {}

    /// Computes the ideal pivot point.
    ///
    /// - Parameters:
    ///   - cameraState: Current camera state.
    ///   - bodies: Visible scene bodies.
    ///   - aspectRatio: Viewport width / height.
    ///   - config: Dynamic pivot configuration.
    /// - Returns: The computed pivot, or `nil` if disabled or no geometry is visible.
    public func computePivot(
        cameraState: CameraState,
        bodies: [ViewportBody],
        aspectRatio: Float,
        config: DynamicPivotConfiguration
    ) -> SIMD3<Float>? {
        guard config.isEnabled else { return nil }

        // Update bounding box cache
        updateCache(bodies: bodies)

        // Compute scene bounding box
        guard let sceneBB = sceneBoundingBox() else { return nil }
        let diagonal = sceneBB.diagonalLength
        guard diagonal > 0 else { return nil }

        let sceneCenter = sceneBB.center
        let zoomRatio = cameraState.distance / diagonal
        let halfBand = config.zoomThreshold * config.blendBand * 0.5

        // Fully zoomed out: use scene center
        if zoomRatio > config.zoomThreshold + halfBand {
            return sceneCenter
        }

        // Cast ray through view center
        let ray = Ray.throughViewCenter(cameraState: cameraState, aspectRatio: aspectRatio)
        let hit = SceneRaycast.cast(ray: ray, bodies: bodies, boundingBoxCache: bbCache)

        // When the raycast misses geometry:
        // - Fully zoomed out: safe to use scene center (user sees the whole scene)
        // - Closer in: keep current pivot (user may have panned away intentionally)
        guard let hitPoint = hit?.point else {
            if zoomRatio > config.zoomThreshold + halfBand {
                return sceneCenter
            }
            return nil
        }

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

    private func sceneBoundingBox() -> BoundingBox? {
        var result: BoundingBox?
        for bb in bbCache.values {
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
