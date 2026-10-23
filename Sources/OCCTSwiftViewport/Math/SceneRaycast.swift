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
    /// - Parameters:
    ///   - ray: The world-space ray to cast.
    ///   - bodies: Scene bodies to test.
    ///   - boundingBoxCache: Pre-computed **local-space** bounding boxes keyed by body ID (as
    ///     returned by `ViewportBody.boundingBox`, before `transform`).
    /// - Returns: The nearest hit, or `nil` on miss.
    public static func cast(
        ray: Ray,
        bodies: [ViewportBody],
        boundingBoxCache: [String: BoundingBox]
    ) -> RaycastHit? {
        // Broadphase: collect (body, local ray, world-units-per-local-t, world aabbEntry) for
        // visible bodies whose local-space box the ray hits.
        var candidates: [(body: ViewportBody, localRay: Ray, tScale: Float, aabbEntry: Float)] = []

        for body in bodies {
            guard body.isVisible else { continue }
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

            let indexCount = body.indices.count
            guard indexCount >= 3 else { continue }

            // Position accessor for either layout: interleaved bodies carry stride-6 `vertexData`;
            // direct-mesh bodies (Option A) carry de-interleaved positions reshaped into `vertices`
            // and leave `vertexData` empty. Reading the wrong one here would index an empty array.
            let stride = 6
            let direct = body.vertexData.isEmpty
            func position(_ idx: Int) -> SIMD3<Float> {
                if direct {
                    return body.vertices[idx]
                }
                return SIMD3<Float>(
                    body.vertexData[idx * stride],
                    body.vertexData[idx * stride + 1],
                    body.vertexData[idx * stride + 2]
                )
            }

            var i = 0
            while i < indexCount {
                let i0 = Int(body.indices[i])
                let i1 = Int(body.indices[i + 1])
                let i2 = Int(body.indices[i + 2])

                let v0 = position(i0)
                let v1 = position(i1)
                let v2 = position(i2)

                if let localT = localRay.intersectsTriangle(v0: v0, v1: v1, v2: v2),
                    localT * tScale < bestDistance
                {
                    let t = localT * tScale
                    bestDistance = t
                    bestHit = RaycastHit(
                        bodyID: body.id,
                        point: ray.origin + ray.direction * t,
                        distance: t
                    )
                }

                i += 3
            }
        }

        return bestHit
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
