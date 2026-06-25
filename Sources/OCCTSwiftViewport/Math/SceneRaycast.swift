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
/// 1. **Broadphase** — ray-AABB test for each visible body
/// 2. **Narrowphase** — Moller-Trumbore triangle intersection on surviving bodies
public enum SceneRaycast {

    /// Casts a ray against the given bodies.
    ///
    /// - Parameters:
    ///   - ray: The ray to cast.
    ///   - bodies: Scene bodies to test.
    ///   - boundingBoxCache: Pre-computed bounding boxes keyed by body ID.
    /// - Returns: The nearest hit, or `nil` on miss.
    public static func cast(
        ray: Ray,
        bodies: [ViewportBody],
        boundingBoxCache: [String: BoundingBox]
    ) -> RaycastHit? {
        // Broadphase: collect (body, aabbEntry) for visible bodies that the ray hits
        var candidates: [(body: ViewportBody, aabbEntry: Float)] = []

        for body in bodies {
            guard body.isVisible else { continue }
            guard let bb = boundingBoxCache[body.id] else { continue }
            if let entry = ray.intersects(bb) {
                candidates.append((body, entry))
            }
        }

        // Sort by AABB entry distance (nearest first)
        candidates.sort { $0.aabbEntry < $1.aabbEntry }

        // Narrowphase: test triangles, early-out when AABB entry exceeds best hit
        var bestHit: RaycastHit?
        var bestDistance: Float = .infinity

        for (body, aabbEntry) in candidates {
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

                if let t = ray.intersectsTriangle(v0: v0, v1: v1, v2: v2), t < bestDistance {
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
}
