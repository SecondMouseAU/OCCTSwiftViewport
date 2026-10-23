// PickResult.swift
// ViewportKit
//
// Decoded GPU pick result from the pick ID buffer.

import Foundation

/// Sub-shape kind that a pick can resolve to.
///
/// Encoded into the top 2 bits of the GPU pick texture so a single readback
/// disambiguates faces / edges / vertices. The renderer's pick pass renders
/// each kind with a distinct fragment shader that stamps the appropriate tag.
public enum PrimitiveKind: UInt8, Sendable, Hashable {
    case face = 0
    case edge = 1
    case vertex = 2
}

/// Result of a GPU-accelerated pick operation.
///
/// Decodes the raw R32Uint value from the pick ID buffer into a body ID,
/// primitive index, and primitive kind. The encoding is:
///
///     bits  0-15 : objectIndex   (16 bits)
///     bits 16-29 : primitiveID   (14 bits, triangle/segment/point index)
///     bits 30-31 : kind          ( 2 bits, 0=face, 1=edge, 2=vertex)
///
/// `triangleIndex` is preserved as the historical name; semantically it is the
/// **primitive index** for the matched kind (triangle for face picks, line
/// segment for edge picks, point for vertex picks).
///
/// ## Limits of the 32-bit encoding
///
/// - **Bodies:** at most `maxPickableBodies` (65,536) visible bodies get a pick ID per frame,
///   counted in draw order. A body past that limit still occludes in the pick pass but reads back
///   as a miss (`nil`), so it can never be confused with another body.
/// - **Primitives:** the primitive field holds `maxPrimitivesPerKind` (16,384) values. On a body
///   with more primitives of the picked kind, the GPU reports the true index modulo 16,384, and
///   `isPrimitiveIndexAmbiguous` is `true`. The built-in tap path resolves ambiguous **face** picks
///   back to the exact triangle with a CPU ray test (see
///   `ViewportBody.resolveWrappedTriangleIndex(_:ray:)`); edge and vertex picks stay ambiguous.
public struct PickResult: Sendable, Equatable {

    /// Sentinel value indicating no hit (background or non-pickable overlay).
    public static let sentinel: UInt32 = 0xFFFF_FFFF

    /// Number of visible bodies that can receive a pick ID in one frame (object indices
    /// `0...0xFFFF`).
    ///
    /// Bodies beyond this count, in draw order, are drawn into the pick pass with the no-hit
    /// sentinel: they still hide what is behind them, but picking them returns `nil`.
    public static let maxPickableBodies = 1 << 16

    /// Number of distinct primitive indices the 14-bit primitive field can carry per kind.
    ///
    /// A pick on a body with more primitives of that kind reports `index % maxPrimitivesPerKind`
    /// and sets `isPrimitiveIndexAmbiguous`.
    public static let maxPrimitivesPerKind = 1 << 14

    /// The ID string of the picked body.
    public let bodyID: String

    /// The zero-based index of the body in the draw order.
    public let bodyIndex: Int

    /// The primitive index within the body, interpreted according to `kind`:
    /// triangle for `.face`, line segment for `.edge`, point for `.vertex`.
    ///
    /// When `isPrimitiveIndexAmbiguous` is `true`, this is only the true index modulo
    /// `maxPrimitivesPerKind`: the real primitive is one of `triangleIndex + k * 16_384`.
    public let triangleIndex: Int

    /// `true` when the picked body has more than `maxPrimitivesPerKind` primitives of the picked
    /// kind, so `triangleIndex` may have wrapped.
    ///
    /// Do not map an ambiguous index through `faceIndices` or `edgeIndices` directly. For face
    /// picks, resolve it with `ViewportBody.resolveWrappedTriangleIndex(_:ray:)`. The built-in tap
    /// path already does this before publishing `ViewportController.pickResult`, and leaves the
    /// flag set only when the CPU ray test could not settle it.
    public let isPrimitiveIndexAmbiguous: Bool

    /// Sub-shape kind the picked primitive belongs to.
    public let kind: PrimitiveKind

    /// The raw encoded value read from the pick buffer.
    public let rawValue: UInt32

    /// Which pick stream this result belongs to.
    ///
    /// `ViewportController` reads it to route the result to either `pickResult` or
    /// `widgetPickResult`, so widget hits never leak into the user selection stream.
    public let pickLayer: PickLayer

    /// Decodes a raw pick-buffer value into a result, naming the body through `indexMap`.
    ///
    /// Fails with `nil` in three cases: `rawValue` is the no-hit sentinel, its packed kind bits
    /// do not name a `PrimitiveKind`, or its object index is absent from `indexMap`.
    ///
    /// - Parameters:
    ///   - rawValue: The R32Uint value read back from the GPU.
    ///   - indexMap: Mapping from objectIndex (Int) to body ID (String).
    ///   - layerMap: Optional mapping from body ID to its `PickLayer`. Bodies
    ///     not present in the map are treated as `.userGeometry`.
    ///   - ambiguousKinds: Optional mapping from body ID to the primitive kinds whose count on that
    ///     body exceeds `maxPrimitivesPerKind`. The renderer builds it each frame. A pick of a
    ///     listed kind on a listed body sets `isPrimitiveIndexAmbiguous`.
    public init?(
        rawValue: UInt32,
        indexMap: [Int: String],
        layerMap: [String: PickLayer] = [:],
        ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
    ) {
        guard rawValue != Self.sentinel else { return nil }

        let objectIndex = Int(rawValue & 0xFFFF)
        let primitiveID = Int((rawValue >> 16) & 0x3FFF)
        let rawKind = UInt8((rawValue >> 30) & 0x3)
        guard let kind = PrimitiveKind(rawValue: rawKind) else { return nil }

        guard let bodyID = indexMap[objectIndex] else { return nil }

        self.bodyID = bodyID
        self.bodyIndex = objectIndex
        self.triangleIndex = primitiveID
        self.kind = kind
        self.rawValue = rawValue
        self.pickLayer = layerMap[bodyID] ?? .userGeometry
        self.isPrimitiveIndexAmbiguous = ambiguousKinds[bodyID]?.contains(kind) ?? false
    }

    private init(copying other: PickResult, triangleIndex: Int, isPrimitiveIndexAmbiguous: Bool) {
        self.bodyID = other.bodyID
        self.bodyIndex = other.bodyIndex
        self.triangleIndex = triangleIndex
        self.kind = other.kind
        self.rawValue = other.rawValue
        self.pickLayer = other.pickLayer
        self.isPrimitiveIndexAmbiguous = isPrimitiveIndexAmbiguous
    }

    /// Returns a copy whose `triangleIndex` is the exact, resolved `index` and whose
    /// `isPrimitiveIndexAmbiguous` is `false`.
    func resolvingPrimitiveIndex(_ index: Int) -> PickResult {
        PickResult(copying: self, triangleIndex: index, isPrimitiveIndexAmbiguous: false)
    }

    // MARK: - Encoding guards

    /// Object index a body at draw-order position `ordinal` writes into the pick pass.
    ///
    /// The ordinal itself while it fits the 16-bit object field, otherwise `sentinel`. The pick
    /// shaders OR the object index into the packed value, so a sentinel object index reads back
    /// as a miss for every primitive instead of bleeding into the primitive bits of another pick.
    static func pickObjectIndex(forOrdinal ordinal: UInt32) -> UInt32 {
        ordinal < UInt32(maxPickableBodies) ? ordinal : sentinel
    }

    /// Primitive kinds whose count exceeds `maxPrimitivesPerKind`, so picks of that kind wrap.
    ///
    /// - Parameters:
    ///   - triangleCount: Triangles drawn in the face pick pass.
    ///   - edgeSegmentCount: Largest edge primitive index range: line segments, or arcs for the
    ///     analytic arc pass, whichever is larger.
    ///   - pointCount: Points drawn in the vertex pick pass.
    /// - Returns: The kinds whose picks on this body can wrap; empty for most bodies.
    static func ambiguousKinds(
        triangleCount: Int, edgeSegmentCount: Int, pointCount: Int
    ) -> Set<PrimitiveKind> {
        var kinds: Set<PrimitiveKind> = []
        if triangleCount > maxPrimitivesPerKind { kinds.insert(.face) }
        if edgeSegmentCount > maxPrimitivesPerKind { kinds.insert(.edge) }
        if pointCount > maxPrimitivesPerKind { kinds.insert(.vertex) }
        return kinds
    }
}
