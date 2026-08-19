// Frustum.swift
// ViewportKit
//
// View-frustum extraction + AABB intersection for per-body culling (issue #42).

import simd

/// The six planes of a view frustum, extracted from a view-projection matrix.
///
/// Each plane is stored as `SIMD4(a, b, c, d)` with the normal `(a, b, c)`
/// pointing **inward**; a world point `p` is inside the plane when
/// `dot(normal, p) + d >= 0`. Uses the Gribb–Hartmann method with Metal's
/// `[0, 1]` clip-space depth convention.
public struct Frustum: Sendable {

    /// left, right, bottom, top, near, far.
    public let planes: [SIMD4<Float>]

    /// Extracts the frustum from a world→clip `viewProjection` matrix.
    public init(viewProjection m: simd_float4x4) {
        // simd matrices are column-major: m[col][row]. Row i across columns:
        func row(_ i: Int) -> SIMD4<Float> {
            SIMD4<Float>(m[0][i], m[1][i], m[2][i], m[3][i])
        }
        let r0 = row(0)
        let r1 = row(1)
        let r2 = row(2)
        let r3 = row(3)

        var planes = [
            r3 + r0,  // left
            r3 - r0,  // right
            r3 + r1,  // bottom
            r3 - r1,  // top
            r2,  // near  (Metal [0,1] depth: near = row2, not row3+row2)
            r3 - r2,  // far
        ]
        for i in planes.indices {
            let len = simd_length(SIMD3<Float>(planes[i].x, planes[i].y, planes[i].z))
            if len > 0 { planes[i] /= len }
        }
        self.planes = planes
    }

    /// Whether `box` might be visible, answered conservatively in favour of drawing.
    ///
    /// Returns `false` only when the box lies entirely outside at least one plane, which is
    /// the case where culling it is provably safe. A box straddling a plane returns `true`,
    /// as does one outside the frustum but not outside any single plane, so the test can keep
    /// a body that is not actually visible but never drops one that is.
    public func intersects(_ box: BoundingBox) -> Bool {
        for plane in planes {
            let n = SIMD3<Float>(plane.x, plane.y, plane.z)
            // p-vertex: the AABB corner furthest along the (inward) plane normal.
            let p = SIMD3<Float>(
                n.x >= 0 ? box.max.x : box.min.x,
                n.y >= 0 ? box.max.y : box.min.y,
                n.z >= 0 ? box.max.z : box.min.z
            )
            if simd_dot(n, p) + plane.w < 0 {
                return false  // fully outside this plane → cull
            }
        }
        return true
    }
}

extension BoundingBox {

    /// The world-space AABB enclosing this box after `transform`.
    ///
    /// Transforms all eight corners and takes their extent. Returns `self`
    /// unchanged for an identity transform (the common case) without work.
    public func transformed(by transform: simd_float4x4) -> BoundingBox {
        if transform == matrix_identity_float4x4 { return self }

        var newMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var newMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for xi in [min.x, max.x] {
            for yi in [min.y, max.y] {
                for zi in [min.z, max.z] {
                    let c = transform * SIMD4<Float>(xi, yi, zi, 1)
                    let p = SIMD3<Float>(c.x, c.y, c.z)
                    newMin = simd_min(newMin, p)
                    newMax = simd_max(newMax, p)
                }
            }
        }
        return BoundingBox(min: newMin, max: newMax)
    }
}
