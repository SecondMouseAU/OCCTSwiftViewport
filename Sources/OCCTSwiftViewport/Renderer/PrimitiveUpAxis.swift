// PrimitiveUpAxis.swift
// OCCTSwiftViewport
//
// The axis the primitive factories in Primitives.swift build "up" along.

import simd

/// The world axis a primitive factory treats as "up" (its height axis).
///
/// The viewport's world is Z-up (turntable orbit, standard views, the lighting hemisphere and the
/// grid all assume it), but `ViewportBody.box(...)`, `.cylinder(...)` and `.sphere(...)` were
/// written Y-up and keep `.y` as their default so existing callers see no change. Pass `.z` to
/// build a primitive that stands on the Z-up grid.
///
/// Each factory builds its geometry Y-up and then applies a proper rotation (determinant +1, so
/// triangle winding and outward normals are preserved) that carries +Y onto the chosen axis:
///
/// | `up` | +Y maps to | Box `width` / `height` / `depth` run along |
/// |------|-----------|--------------------------------------------|
/// | `.y` | +Y (no-op) | X / Y / Z |
/// | `.z` | +Z | X / Z / Y |
/// | `.x` | +X | Y / X / Z |
///
/// ```swift
/// // A 2 × 1 footprint, 0.5 tall, resting on the Z-up grid.
/// var slab = ViewportBody.box(id: "slab", width: 2, height: 0.5, depth: 1, up: .z)
/// ```
public enum PrimitiveUpAxis: Sendable, Hashable, CaseIterable {
    /// Height along +X.
    case x
    /// Height along +Y. The factories' default, kept for source compatibility.
    case y
    /// Height along +Z, matching the viewport's Z-up world.
    case z

    /// Rotates a direction or position from the factories' Y-up frame into this axis's frame.
    func orient(_ v: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .y: return v
        // +90° about X: +Y → +Z, +Z → −Y.
        case .z: return SIMD3<Float>(v.x, -v.z, v.y)
        // −90° about Z: +Y → +X, +X → −Y.
        case .x: return SIMD3<Float>(v.y, -v.x, v.z)
        }
    }

    /// Rotates interleaved `[px, py, pz, nx, ny, nz, ...]` vertex data in place.
    func orient(vertexData: inout [Float]) {
        guard self != .y else { return }
        var i = 0
        while i + 5 < vertexData.count {
            let p = orient(SIMD3<Float>(vertexData[i], vertexData[i + 1], vertexData[i + 2]))
            let n = orient(SIMD3<Float>(vertexData[i + 3], vertexData[i + 4], vertexData[i + 5]))
            vertexData[i] = p.x
            vertexData[i + 1] = p.y
            vertexData[i + 2] = p.z
            vertexData[i + 3] = n.x
            vertexData[i + 4] = n.y
            vertexData[i + 5] = n.z
            i += 6
        }
    }

    /// Rotates edge polylines.
    func orient(edges: [[SIMD3<Float>]]) -> [[SIMD3<Float>]] {
        guard self != .y else { return edges }
        return edges.map { $0.map(orient) }
    }
}
