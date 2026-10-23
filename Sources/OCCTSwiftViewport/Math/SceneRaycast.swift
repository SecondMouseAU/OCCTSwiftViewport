// SceneRaycast.swift
// ViewportKit
//
// Two-phase raycast against an array of bodies.

import simd

/// Result of a successful raycast hit.
public struct RaycastHit: Sendable {
    /// Identifier of the body that was hit.
    public let bodyID: String
    /// World-space hit point.
    public let point: SIMD3<Float>
    /// Distance from ray origin.
    public let distance: Float
}

/// CPU-side raycasting against viewport geometry.
///
/// Uses a two-phase approach:
/// 1. **Broadphase**: ray-AABB test for each visible body
/// 2. **Narrowphase**: Moller-Trumbore triangle intersection on surviving bodies
public enum SceneRaycast {

    /// Casts a ray against the given bodies.
    ///
    /// Each body is tested in its own local space: the world-space ray goes through the
    /// inverse of `body.transform`, and the hit point and distance come back in world space.
    /// Bodies whose transform is not invertible are skipped.
    ///
    /// Hits on geometry removed by a section plane are skipped and the search continues behind
    /// them, matching the GPU pick pass: only the enabled planes the renderer applies count
    /// (the first ``ClipPlane/maxActivePlanes``), and a world point `p` is clipped when
    /// `dot(normal, p) + distance < 0` (issue #163).
    ///
    /// By default the cast only tests the bodies a user would orbit around or focus on: hidden
    /// bodies, ``ViewportBody/isPickable`` `== false` bodies (which GPU picking never reports)
    /// and widgets are skipped, so the dynamic pivot and focus-on-point never land on a gizmo or
    /// datum (issue #180). A widget is a body drawn on the ``RenderLayer/overlay`` layer or
    /// picked on the ``PickLayer/widget`` layer. Pass `includeWidgets` or `includeNonPickable`
    /// to test those too.
    ///
    /// - Parameters:
    ///   - ray: The world-space ray to cast.
    ///   - bodies: Scene bodies to test.
    ///   - boundingBoxCache: Pre-computed **local-space** bounding boxes keyed by body ID (as
    ///     returned by `ViewportBody.boundingBox`, before `transform`). Bodies without an entry
    ///     are skipped.
    ///   - clipPlanes: Section planes to honour, typically `ViewportController.clipPlanes`.
    ///     Defaults to none.
    ///   - includeWidgets: Also test ``RenderLayer/overlay`` and ``PickLayer/widget`` bodies.
    ///     Defaults to `false`.
    ///   - includeNonPickable: Also test bodies with ``ViewportBody/isPickable`` `== false`.
    ///     Defaults to `false`.
    /// - Returns: The nearest unclipped hit, or `nil` on miss.
    public static func cast(
        ray: Ray,
        bodies: [ViewportBody],
        boundingBoxCache: [String: BoundingBox],
        clipPlanes: [ClipPlane] = [],
        includeWidgets: Bool = false,
        includeNonPickable: Bool = false
    ) -> RaycastHit? {
        let planes = ClipPlane.activePlanes(in: clipPlanes).applied

        // Broadphase: collect (body, local ray, world-units-per-local-t, world aabbEntry) for
        // visible bodies whose local-space box the ray hits.
        var candidates: [(body: ViewportBody, localRay: Ray, tScale: Float, aabbEntry: Float)] = []

        for body in bodies {
            guard
                isCandidate(
                    body, includeWidgets: includeWidgets,
                    includeNonPickable: includeNonPickable)
            else { continue }
            guard let bb = boundingBoxCache[body.id] else { continue }
            guard let (localRay, tScale) = localRay(ray, transform: body.transform) else {
                continue
            }
            if let entry = localRay.intersects(bb) {
                candidates.append((body, localRay, tScale, entry * tScale))
            }
        }

        // Sort by AABB entry distance (nearest first)
        candidates.sort { $0.aabbEntry < $1.aabbEntry }

        // Narrowphase: test triangles, early-out when AABB entry exceeds best hit
        var bestHit: RaycastHit?
        var bestDistance: Float = .infinity

        for (body, localRay, tScale, aabbEntry) in candidates {
            // Early-out: no triangle in this body can be closer
            if aabbEntry > bestDistance { break }

            guard let positions = TrianglePositions(body) else { continue }
            let indices = body.indices
            // Whole triangles only: a trailing partial triple would read past the end.
            let indexCount = indices.count - indices.count % 3

            var i = 0
            while i < indexCount {
                defer { i += 3 }
                // Skip triangles with out-of-range indices rather than trapping.
                guard let v0 = positions[indices[i]],
                    let v1 = positions[indices[i + 1]],
                    let v2 = positions[indices[i + 2]],
                    let localT = localRay.intersectsTriangle(v0: v0, v1: v1, v2: v2)
                else { continue }

                let t = localT * tScale
                guard t < bestDistance else { continue }
                let point = ray.origin + ray.direction * t
                if isClipped(point, by: planes) { continue }
                bestDistance = t
                bestHit = RaycastHit(bodyID: body.id, point: point, distance: t)
            }
        }

        return bestHit
    }

    /// Casts a ray against the given bodies, computing their bounding boxes on the spot.
    ///
    /// Convenience for one-off casts. It walks every body's geometry to build the boxes, so
    /// code that casts repeatedly against the same bodies should keep its own cache and call
    /// ``cast(ray:bodies:boundingBoxCache:clipPlanes:includeWidgets:includeNonPickable:)``
    /// instead. Skips the same bodies that overload does, without computing their boxes.
    public static func cast(
        ray: Ray,
        bodies: [ViewportBody],
        clipPlanes: [ClipPlane] = [],
        includeWidgets: Bool = false,
        includeNonPickable: Bool = false
    ) -> RaycastHit? {
        var cache: [String: BoundingBox] = [:]
        for body in bodies
        where isCandidate(
            body, includeWidgets: includeWidgets, includeNonPickable: includeNonPickable)
        {
            if let bb = body.boundingBox { cache[body.id] = bb }
        }
        return cast(
            ray: ray, bodies: bodies, boundingBoxCache: cache, clipPlanes: clipPlanes,
            includeWidgets: includeWidgets, includeNonPickable: includeNonPickable)
    }

    /// Whether `body` takes part in a cast: visible, and pickable and not a widget unless the
    /// caller opted in to those.
    static func isCandidate(
        _ body: ViewportBody, includeWidgets: Bool, includeNonPickable: Bool
    ) -> Bool {
        body.isVisible
            && (includeWidgets || (body.renderLayer != .overlay && body.pickLayer != .widget))
            && (includeNonPickable || body.isPickable)
    }

    /// Whether `point` is on the removed side of any of `planes`.
    ///
    /// Same test as `isClippedBySectionPlanes` in `Shaders.metal`.
    static func isClipped(_ point: SIMD3<Float>, by planes: [ClipPlane]) -> Bool {
        planes.contains { simd_dot($0.normal, point) + $0.distance < 0 }
    }

    /// Reads a body's triangle-vertex positions from whichever layout the renderer draws.
    ///
    /// Direct-mesh bodies (``ViewportBody/usesDirectMesh``) draw `meshPositions` (stride 3),
    /// interleaved bodies draw `vertexData` (stride 6). `vertices` is the fallback for a body
    /// with neither. Reading the wrong one indexed an empty array (issue #167).
    private struct TrianglePositions {
        private enum Source {
            case stride3([Float])
            case stride6([Float])
            case points([SIMD3<Float>])
        }
        private let source: Source

        init?(_ body: ViewportBody) {
            if body.usesDirectMesh {
                source = .stride3(body.meshPositions)
            } else if !body.vertexData.isEmpty {
                source = .stride6(body.vertexData)
            } else if !body.vertices.isEmpty {
                source = .points(body.vertices)
            } else {
                return nil
            }
        }

        /// The position of vertex `index`, or `nil` when it is out of range.
        subscript(index: UInt32) -> SIMD3<Float>? {
            let i = Int(index)
            switch source {
            case .stride3(let data):
                guard i * 3 + 2 < data.count else { return nil }
                return SIMD3<Float>(data[i * 3], data[i * 3 + 1], data[i * 3 + 2])
            case .stride6(let data):
                guard i * 6 + 2 < data.count else { return nil }
                return SIMD3<Float>(data[i * 6], data[i * 6 + 1], data[i * 6 + 2])
            case .points(let points):
                return i < points.count ? points[i] : nil
            }
        }
    }

    /// Maps a world-space ray into a body's local space.
    ///
    /// Returns the local ray (normalised direction) and the factor that converts a local ray
    /// parameter into a world distance, or `nil` when `transform` is not invertible.
    static func localRay(_ ray: Ray, transform: simd_float4x4) -> (Ray, Float)? {
        if transform == matrix_identity_float4x4 { return (ray, 1) }
        guard abs(simd_determinant(transform)) > 1e-12 else { return nil }
        let inverse = transform.inverse
        let origin = inverse * SIMD4<Float>(ray.origin, 1)
        let direction = inverse * SIMD4<Float>(ray.direction, 0)
        let localDirection = SIMD3<Float>(direction.x, direction.y, direction.z)
        let length = simd_length(localDirection)
        guard length > 0, origin.w != 0 else { return nil }
        // A unit step along the normalised local direction is 1 / length world units.
        return (
            Ray(
                origin: SIMD3<Float>(origin.x, origin.y, origin.z) / origin.w,
                direction: localDirection),
            1 / length
        )
    }
}
