// MeasurementPicking.swift
// ViewportKit
//
// Reconstructs a world-space surface point from a GPU pick result, for
// tap-to-measure interaction.

import simd

extension ViewportBody {
    /// World-space position where `ray` intersects the triangle at `triangleIndex`,
    /// accounting for this body's `transform`.
    ///
    /// The triangle vertices are looked up from `indices` and the positions the renderer draws:
    /// `meshPositions` (stride 3) for a direct-mesh body (``usesDirectMesh``), otherwise
    /// `vertexData` (stride 6: position + normal). `vertices` is the vertex-pick array, so it is
    /// read only for a body that has neither. They are transformed into world space, then
    /// intersected with the ray via Moller-Trumbore. Returns `nil` if the index is out of range
    /// or the ray misses the (transformed) triangle.
    ///
    /// `triangleIndex` matches `PickResult.triangleIndex` for a `.face` pick, which is always the
    /// exact triangle index, however many triangles the body has.
    public func worldHitPoint(ray: Ray, triangleIndex: Int) -> SIMD3<Float>? {
        let base = triangleIndex * 3
        guard base >= 0, base + 2 < indices.count,
            let positions = SceneRaycast.TrianglePositions(self)
        else { return nil }

        func worldVertex(_ index: UInt32) -> SIMD3<Float>? {
            guard let local = positions[index] else { return nil }
            let world = transform * SIMD4<Float>(local, 1)
            return SIMD3<Float>(world.x, world.y, world.z)
        }

        guard let v0 = worldVertex(indices[base]),
            let v1 = worldVertex(indices[base + 1]),
            let v2 = worldVertex(indices[base + 2])
        else { return nil }

        guard let t = ray.intersectsTriangle(v0: v0, v1: v1, v2: v2) else { return nil }
        return ray.origin + ray.direction * t
    }

    /// Resolves a wrapped face-pick triangle index to the exact triangle under `ray`.
    ///
    /// Pre-#160 GPU pick targets had 14 bits for the primitive index, so on a body with more than
    /// 16,384 triangles a pick reported the true index modulo 16,384. The pick target is now
    /// RG32Uint and `PickResult.triangleIndex` is always exact, so there is nothing to resolve.
    /// This stays for callers that still hold a wrapped index: it tests each congruent candidate
    /// (`wrappedIndex`, `wrappedIndex + 16_384`, ...) against `ray`, in world space, and returns the
    /// one hit nearest the ray origin.
    ///
    /// - Parameters:
    ///   - wrappedIndex: A triangle index in `0..<16_384`, the true index modulo 16,384.
    ///   - ray: The world-space ray through the picked pixel, e.g. from `Ray.fromCamera(...)`.
    /// - Returns: The exact triangle index, or `nil` when the ray hits no candidate.
    @available(
        *, deprecated,
        message: "Pick indices no longer wrap; PickResult.triangleIndex is exact."
    )
    public func resolveWrappedTriangleIndex(_ wrappedIndex: Int, ray: Ray) -> Int? {
        let modulus = 1 << 14
        guard wrappedIndex >= 0, wrappedIndex < modulus else { return nil }
        let triangleCount = indices.count / 3
        var best: (index: Int, distance: Float)?
        var candidate = wrappedIndex
        while candidate < triangleCount {
            if let point = worldHitPoint(ray: ray, triangleIndex: candidate) {
                let distance = simd_dot(point - ray.origin, ray.direction)
                if distance < (best?.distance ?? .infinity) {
                    best = (candidate, distance)
                }
            }
            candidate += modulus
        }
        return best?.index
    }
}
