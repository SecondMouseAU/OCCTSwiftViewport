// BoundingBox.swift
// ViewportKit
//
// Axis-aligned bounding box value type.

import simd

/// An axis-aligned bounding box (AABB).
public struct BoundingBox: Hashable, Sendable {

    /// Minimum corner.
    public var min: SIMD3<Float>

    /// Maximum corner.
    public var max: SIMD3<Float>

    /// Center point of the box.
    public var center: SIMD3<Float> {
        (min + max) * 0.5
    }

    /// Size along each axis.
    public var size: SIMD3<Float> {
        max - min
    }

    /// Length of the diagonal.
    public var diagonalLength: Float {
        simd_length(size)
    }

    /// Creates a bounding box from minimum and maximum corners.
    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// Returns the smallest box enclosing both `self` and `other`.
    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(
            min: simd_min(self.min, other.min),
            max: simd_max(self.max, other.max)
        )
    }

    /// Returns the minimum distance from `point` to the box.
    ///
    /// If the point is inside the box, returns 0.
    public func distance(to point: SIMD3<Float>) -> Float {
        let dx = Swift.max(0, Swift.max(min.x - point.x, point.x - max.x))
        let dy = Swift.max(0, Swift.max(min.y - point.y, point.y - max.y))
        let dz = Swift.max(0, Swift.max(min.z - point.z, point.z - max.z))
        return simd_length(SIMD3<Float>(dx, dy, dz))
    }
}
