// PickResult.swift
// ViewportKit
//
// Decoded GPU pick result from the pick ID buffer.

import Foundation

/// Sub-shape kind that a pick can resolve to.
///
/// Encoded into the top 2 bits of the pick texture's G channel, so a single readback
/// disambiguates faces / edges / vertices. The renderer's pick pass renders
/// each kind with a distinct fragment shader that stamps the appropriate tag.
public enum PrimitiveKind: UInt8, Sendable, Hashable {
    case face = 0
    case edge = 1
    case vertex = 2
}

/// Result of a GPU-accelerated pick operation.
///
/// Decodes a texel of the RG32Uint pick texture into a body ID, primitive index, and primitive
/// kind. The texel is two 32-bit channels, kept together as one `UInt64` (`pickValue`):
///
///     R (low 32 bits)  : objectIndex   (32 bits, draw-order body index; 0xFFFF_FFFF = none)
///     G (high 32 bits) : bits  0-29 primitiveID (30 bits, triangle/segment/point index)
///                        bits 30-31 kind        ( 2 bits, 0=face, 1=edge, 2=vertex)
///
/// `triangleIndex` is preserved as the historical name; semantically it is the
/// **primitive index** for the matched kind (triangle for face picks, line
/// segment for edge picks, point for vertex picks).
///
/// ## Limits
///
/// - **Bodies:** up to `maxPickableBodies` (4,294,967,295) visible bodies get a pick ID per frame,
///   counted in draw order.
/// - **Primitives:** the primitive field holds `maxPrimitivesPerKind` (1,073,741,824) values per
///   kind, far past any mesh the renderer can hold.
///
/// Before issue #160 the target was R32Uint and these were 65,536 bodies and 16,384 primitives,
/// with `isPrimitiveIndexAmbiguous` flagging a wrapped index. The index is now always exact.
public struct PickResult: Sendable, Equatable {

    /// The pre-#160 R32Uint "no hit" value.
    ///
    /// The pick texture is now RG32Uint and is cleared to `noHit`. This constant remains only
    /// for code that still builds legacy 32-bit values for `init(rawValue:...)`.
    @available(
        *, deprecated,
        message: "The pick texture is RG32Uint now; use PickResult.noHit with pickValue."
    )
    public static let sentinel: UInt32 = 0xFFFF_FFFF

    /// The pick texel of a pixel with no pickable geometry: both channels `0xFFFF_FFFF`.
    ///
    /// `init?(pickValue:indexMap:layerMap:)` returns `nil` for this value, and for any value
    /// whose object index is `0xFFFF_FFFF`.
    public static let noHit: UInt64 = PickEncoding.noHit

    /// Number of visible bodies that can receive a pick ID in one frame (object indices
    /// `0...0xFFFF_FFFE`; `0xFFFF_FFFF` means "no object").
    public static let maxPickableBodies = Int(PickEncoding.noObject)

    /// Number of distinct primitive indices the 30-bit primitive field can carry per kind.
    ///
    /// A primitive index past this wraps modulo `maxPrimitivesPerKind`. No mesh the renderer can
    /// hold gets near it.
    public static let maxPrimitivesPerKind = 1 << Int(PickEncoding.primitiveBits)

    /// The ID string of the picked body.
    public let bodyID: String

    /// The zero-based index of the body in the draw order.
    public let bodyIndex: Int

    /// The primitive index within the body, interpreted according to `kind`:
    /// triangle for `.face`, line segment for `.edge`, point for `.vertex`.
    ///
    /// Always the exact index: it maps through `indices`, `faceIndices`, `edgeIndices` and
    /// `vertexIndices` directly, however many primitives the body has.
    public let triangleIndex: Int

    /// Sub-shape kind the picked primitive belongs to.
    public let kind: PrimitiveKind

    /// The pick texel this result was decoded from, as `G << 32 | R`.
    ///
    /// See the type's layout.
    public let pickValue: UInt64

    /// Which pick stream this result belongs to.
    ///
    /// `ViewportController` reads it to route the result to either `pickResult` or
    /// `widgetPickResult`, so widget hits never leak into the user selection stream.
    public let pickLayer: PickLayer

    /// `true` only for a result decoded from a legacy 32-bit value with `init(rawValue:...)`.
    private let legacyWrapped: Bool

    /// Always `false` for a result decoded from the RG32Uint pick texture: `triangleIndex` is
    /// exact.
    ///
    /// Before issue #160 this flagged an index that had wrapped modulo 16,384.
    @available(
        *, deprecated,
        message: "Pick indices no longer wrap; triangleIndex is always exact."
    )
    public var isPrimitiveIndexAmbiguous: Bool { legacyWrapped }

    /// The value the pre-#160 R32Uint pick target would have held for this pick, packed as
    /// `objectIndex (16) | primitiveID (14) << 16 | kind (2) << 30`.
    ///
    /// Lossy: a body index past 65,535 or a primitive index past 16,383 wraps. Use `pickValue`,
    /// which is exact.
    @available(*, deprecated, message: "Lossy; use pickValue, which is exact.")
    public var rawValue: UInt32 {
        PickEncoding.encodeLegacy(
            objectIndex: bodyIndex, primitiveIndex: triangleIndex, kind: kind)
    }

    /// Decodes a pick texel into a result, naming the body through `indexMap`.
    ///
    /// Fails with `nil` in three cases: the object index is `0xFFFF_FFFF` (the no-hit texel,
    /// `noHit`), the packed kind bits do not name a `PrimitiveKind`, or the object index is absent
    /// from `indexMap`.
    ///
    /// - Parameters:
    ///   - pickValue: The RG32Uint texel read back from the GPU, as `G << 32 | R`.
    ///   - indexMap: Mapping from objectIndex (Int) to body ID (String).
    ///   - layerMap: Optional mapping from body ID to its `PickLayer`. Bodies
    ///     not present in the map are treated as `.userGeometry`.
    public init?(
        pickValue: UInt64,
        indexMap: [Int: String],
        layerMap: [String: PickLayer] = [:]
    ) {
        self.init(
            decoded: PickEncoding.decode(pickValue), pickValue: pickValue, indexMap: indexMap,
            layerMap: layerMap, legacyWrapped: false)
    }

    /// Decodes a value in the pre-#160 R32Uint layout, `objectIndex (16) | primitiveID (14) << 16 |
    /// kind (2) << 30`, naming the body through `indexMap`.
    ///
    /// The renderer no longer produces this layout; use `init(pickValue:indexMap:layerMap:)`. The
    /// decoded result carries the equivalent wide `pickValue`.
    ///
    /// - Parameters:
    ///   - rawValue: A legacy 32-bit pick value. `0xFFFF_FFFF` is the no-hit value.
    ///   - indexMap: Mapping from objectIndex (Int) to body ID (String).
    ///   - layerMap: Optional mapping from body ID to its `PickLayer`.
    ///   - ambiguousKinds: Optional mapping from body ID to the primitive kinds whose count on that
    ///     body exceeds 16,384. A pick of a listed kind on a listed body reports
    ///     `isPrimitiveIndexAmbiguous`, as the legacy decoder did.
    @available(*, deprecated, message: "Use init(pickValue:indexMap:layerMap:).")
    public init?(
        rawValue: UInt32,
        indexMap: [Int: String],
        layerMap: [String: PickLayer] = [:],
        ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
    ) {
        let decoded = PickEncoding.decodeLegacy(rawValue)
        let wide = decoded.map {
            PickEncoding.encode(
                objectIndex: $0.objectIndex, primitiveIndex: UInt32($0.primitiveIndex),
                kind: $0.kind)
        }
        var wrapped = false
        if let decoded, let bodyID = indexMap[Int(decoded.objectIndex)] {
            wrapped = ambiguousKinds[bodyID]?.contains(decoded.kind) ?? false
        }
        self.init(
            decoded: decoded, pickValue: wide ?? PickEncoding.noHit, indexMap: indexMap,
            layerMap: layerMap, legacyWrapped: wrapped)
    }

    private init?(
        decoded: PickEncoding.Decoded?, pickValue: UInt64, indexMap: [Int: String],
        layerMap: [String: PickLayer], legacyWrapped: Bool
    ) {
        guard let decoded, let bodyID = indexMap[Int(decoded.objectIndex)] else { return nil }

        self.bodyID = bodyID
        self.bodyIndex = Int(decoded.objectIndex)
        self.triangleIndex = decoded.primitiveIndex
        self.kind = decoded.kind
        self.pickValue = pickValue
        self.pickLayer = layerMap[bodyID] ?? .userGeometry
        self.legacyWrapped = legacyWrapped
    }
}
