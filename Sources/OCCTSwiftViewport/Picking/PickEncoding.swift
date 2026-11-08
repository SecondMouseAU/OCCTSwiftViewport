// PickEncoding.swift
// ViewportKit
//
// The wide GPU pick-ID layout, in one place. The pick fragment shaders pack with `packPickID` in
// Shaders.metal; this file is its CPU mirror and the only place Swift reads the layout from.

import Foundation

/// Packing of the RG32Uint pick texture (issue #160).
///
/// One texel is two 32-bit channels:
///
///     R (bits  0-31 of `value`) : objectIndex, the draw-order index of the body.
///                                 `0xFFFF_FFFF` means "no object".
///     G (bits 32-63 of `value`) : bits 0-29 primitive index (triangle / line segment / arc /
///                                 point), bits 30-31 kind (0 face, 1 edge, 2 vertex).
///
/// Metal lays an RG32Uint texel out as R then G in memory, so reading the texel as one
/// little-endian `UInt64` gives `value = G << 32 | R`. That is the form the CPU keeps: it is
/// `Hashable` for de-duplicating region picks and compares as one integer.
///
/// The texture is cleared to `noHit` (both channels `0xFFFF_FFFF`). The shaders write the same
/// value for a body whose object index is `noObject`, and the decoder treats any texel whose R is
/// `noObject` as a miss.
enum PickEncoding {

    /// Object index meaning "no object".
    ///
    /// Never assigned to a body, so a texel carrying it is a miss however its primitive bits
    /// read.
    static let noObject: UInt32 = 0xFFFF_FFFF

    /// The texel the pick pass clears to: no object, no primitive, no kind.
    static let noHit: UInt64 = 0xFFFF_FFFF_FFFF_FFFF

    /// Number of bits of the G channel that carry the primitive index.
    static let primitiveBits: UInt32 = 30

    /// Mask of the primitive index in G. Larger indices wrap, as `% 2^30`.
    static let primitiveMask: UInt32 = (1 << primitiveBits) - 1

    /// Bytes per texel of the RG32Uint pick texture.
    static let bytesPerTexel = MemoryLayout<UInt64>.size

    /// The fields of a decoded pick texel.
    struct Decoded: Equatable {
        var objectIndex: UInt32
        var primitiveIndex: Int
        var kind: PrimitiveKind
    }

    /// Packs a pick texel exactly as `packPickID` in Shaders.metal does.
    ///
    /// - Parameters:
    ///   - objectIndex: Draw-order body index, or `noObject`.
    ///   - primitiveIndex: Triangle, segment, arc or point index. Only the low 30 bits are kept.
    ///   - kindBits: `PrimitiveKind.rawValue`; only the low 2 bits are kept.
    /// - Returns: The texel as `G << 32 | R`, or `noHit` when `objectIndex` is `noObject`.
    static func encode(objectIndex: UInt32, primitiveIndex: UInt32, kindBits: UInt32) -> UInt64 {
        guard objectIndex != noObject else { return noHit }
        let g = (primitiveIndex & primitiveMask) | ((kindBits & 0x3) << primitiveBits)
        return UInt64(g) << 32 | UInt64(objectIndex)
    }

    static func encode(objectIndex: UInt32, primitiveIndex: UInt32, kind: PrimitiveKind) -> UInt64 {
        encode(
            objectIndex: objectIndex, primitiveIndex: primitiveIndex,
            kindBits: UInt32(kind.rawValue))
    }

    /// Unpacks a pick texel.
    ///
    /// Returns `nil` for a miss (`noObject` in R) and for kind bits that name no
    /// `PrimitiveKind`.
    static func decode(_ value: UInt64) -> Decoded? {
        let r = UInt32(truncatingIfNeeded: value)
        let g = UInt32(truncatingIfNeeded: value >> 32)
        guard r != noObject, let kind = PrimitiveKind(rawValue: UInt8(g >> primitiveBits)) else {
            return nil
        }
        return Decoded(objectIndex: r, primitiveIndex: Int(g & primitiveMask), kind: kind)
    }

    /// The objectIndex-or-miss test the batch decoders use before building a `PickResult`.
    static func isHit(_ value: UInt64) -> Bool {
        UInt32(truncatingIfNeeded: value) != noObject
    }

    // MARK: - Legacy 32-bit layout

    /// Decodes the pre-#160 R32Uint layout: `objectIndex (16) | primitive (14) << 16 | kind (2) << 30`.
    ///
    /// Only for `PickResult.init(rawValue:...)`, which keeps decoding values from that layout.
    static func decodeLegacy(_ value: UInt32) -> Decoded? {
        guard value != 0xFFFF_FFFF,
            let kind = PrimitiveKind(rawValue: UInt8((value >> 30) & 0x3))
        else { return nil }
        return Decoded(
            objectIndex: value & 0xFFFF, primitiveIndex: Int((value >> 16) & 0x3FFF), kind: kind)
    }

    /// Packs the pre-#160 R32Uint layout, truncating what it cannot hold.
    static func encodeLegacy(objectIndex: Int, primitiveIndex: Int, kind: PrimitiveKind) -> UInt32 {
        UInt32(truncatingIfNeeded: objectIndex & 0xFFFF)
            | (UInt32(truncatingIfNeeded: primitiveIndex & 0x3FFF) << 16)
            | (UInt32(kind.rawValue) << 30)
    }

    // MARK: - Readback

    /// Copies a blitted `width x height` block of RG32Uint texels out of `base`, whose rows are
    /// `bytesPerRow` apart, into one flat row-major array.
    ///
    /// Reads exactly `width * 8` live bytes from each (padded) row. The bytes of one texel are R
    /// then G, so a native-endian `UInt64` load is `G << 32 | R` on every Apple platform (all of
    /// them little-endian).
    static func texels(
        from base: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int
    ) -> [UInt64] {
        var values: [UInt64] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let rowValues = (base + row * bytesPerRow).assumingMemoryBound(to: UInt64.self)
            values.append(contentsOf: UnsafeBufferPointer(start: rowValues, count: width))
        }
        return values
    }
}
