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
public struct PickResult: Sendable, Equatable {

    /// Sentinel value indicating no hit (background or non-pickable overlay).
    public static let sentinel: UInt32 = 0xFFFF_FFFF

    /// The ID string of the picked body.
    public let bodyID: String

    /// The zero-based index of the body in the draw order.
    public let bodyIndex: Int

    /// The primitive index within the body, interpreted according to `kind`:
    /// triangle for `.face`, line segment for `.edge`, point for `.vertex`.
    public let triangleIndex: Int

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
    public init?(rawValue: UInt32, indexMap: [Int: String], layerMap: [String: PickLayer] = [:]) {
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
    }
}
