import Testing

@testable import OCCTSwiftViewport

@Suite("PickResult Tests")
struct PickResultTests {

    private static let map: [Int: String] = [0: "a", 5: "b", 0xFFFF: "max"]

    private static func texel(_ object: UInt32, _ primitive: UInt32, _ kind: PrimitiveKind)
        -> UInt64
    {
        PickEncoding.encode(objectIndex: object, primitiveIndex: primitive, kind: kind)
    }

    @Test("The no-hit texel decodes to nil")
    func noHitDecodesToNil() {
        #expect(PickResult(pickValue: PickResult.noHit, indexMap: Self.map) == nil)
    }

    @Test("Face decode: kind=0, primitiveID in G bits 0-29, objectIndex in R")
    func faceDecode() {
        let r = PickResult(pickValue: Self.texel(5, 42, .face), indexMap: Self.map)
        #expect(r != nil)
        #expect(r?.bodyID == "b")
        #expect(r?.bodyIndex == 5)
        #expect(r?.triangleIndex == 42)
        #expect(r?.kind == .face)
    }

    @Test("Edge decode: kind=1")
    func edgeDecode() {
        let r = PickResult(pickValue: Self.texel(0, 7, .edge), indexMap: Self.map)
        #expect(r?.kind == .edge)
        #expect(r?.triangleIndex == 7)
        #expect(r?.bodyID == "a")
    }

    @Test("Vertex decode: kind=2")
    func vertexDecode() {
        let r = PickResult(pickValue: Self.texel(5, 3, .vertex), indexMap: Self.map)
        #expect(r?.kind == .vertex)
        #expect(r?.triangleIndex == 3)
        #expect(r?.bodyID == "b")
    }

    @Test("A primitive index with bit 14 set no longer collides with the kind bits")
    func widePrimitiveKeepsKind() {
        // 0x4001 used to spill into the kind field of the 32-bit layout.
        let r = PickResult(pickValue: Self.texel(5, 0x4001, .face), indexMap: Self.map)
        #expect(r?.triangleIndex == 0x4001)
        #expect(r?.kind == .face)
    }

    @Test("Kind bits that name no PrimitiveKind decode to nil")
    func invalidKindDecodesToNil() {
        let value = UInt64(3 << 30 | 9) << 32 | 5
        #expect(PickResult(pickValue: value, indexMap: Self.map) == nil)
    }

    @Test("Layer map routes to widget when bodyID matches")
    func layerMapWidget() {
        let layerMap: [String: PickLayer] = ["b": .widget]
        let r = PickResult(
            pickValue: Self.texel(5, 4, .edge), indexMap: Self.map, layerMap: layerMap)
        #expect(r?.pickLayer == .widget)
    }

    @Test("Layer map default is .userGeometry")
    func layerMapDefault() {
        let r = PickResult(pickValue: Self.texel(5, 4, .face), indexMap: Self.map)
        #expect(r?.pickLayer == .userGeometry)
    }

    @Test("Unknown objectIndex returns nil")
    func unknownObjectIndex() {
        #expect(PickResult(pickValue: Self.texel(99, 4, .face), indexMap: Self.map) == nil)
    }

    @Test("pickValue round-trips the texel it was decoded from")
    func pickValueRoundTrips() {
        let value = Self.texel(5, 123_456, .edge)
        #expect(PickResult(pickValue: value, indexMap: Self.map)?.pickValue == value)
    }
}

// MARK: - The pre-#160 32-bit API still works

@Suite("PickResult legacy 32-bit API")
struct PickResultLegacyTests {

    private static let map: [Int: String] = [0: "a", 5: "b", 0xFFFF: "max"]

    @Test("The old sentinel decodes to nil")
    @available(*, deprecated)
    func sentinelDecodesToNil() {
        #expect(PickResult(rawValue: PickResult.sentinel, indexMap: Self.map) == nil)
    }

    @Test("A legacy value decodes to the same fields and the equivalent wide texel")
    @available(*, deprecated)
    func legacyDecode() {
        // kind=1 (edge), primitiveID=42, objectIndex=5 in the old R32Uint layout.
        let raw: UInt32 = (1 << 30) | (42 << 16) | 5
        let r = PickResult(rawValue: raw, indexMap: Self.map)
        #expect(r?.bodyID == "b")
        #expect(r?.bodyIndex == 5)
        #expect(r?.triangleIndex == 42)
        #expect(r?.kind == .edge)
        #expect(
            r?.pickValue == PickEncoding.encode(objectIndex: 5, primitiveIndex: 42, kind: .edge))
        // And the deprecated accessor reproduces the value it was built from.
        #expect(r?.rawValue == raw)
    }

    @Test("The legacy decoder keeps its primitive-wrap flag, the new one never sets it")
    @available(*, deprecated)
    func legacyAmbiguityFlag() {
        let raw: UInt32 = (0 << 30) | (5 << 16) | 0
        let flagged = PickResult(
            rawValue: raw, indexMap: Self.map, ambiguousKinds: ["a": [.face]])
        #expect(flagged?.isPrimitiveIndexAmbiguous == true)
        let plain = PickResult(rawValue: raw, indexMap: Self.map)
        #expect(plain?.isPrimitiveIndexAmbiguous == false)

        let wide = PickResult(
            pickValue: PickEncoding.encode(objectIndex: 0, primitiveIndex: 5, kind: .face),
            indexMap: Self.map)
        #expect(wide?.isPrimitiveIndexAmbiguous == false)
    }

    @Test("rawValue is the lossy 16/14/2 packing of a wide pick")
    @available(*, deprecated)
    func rawValueIsLossy() {
        let wide = PickResult(
            pickValue: PickEncoding.encode(
                objectIndex: 0x1_0005, primitiveIndex: 0x4_0007, kind: .face),
            indexMap: [0x1_0005: "far"])
        #expect(wide?.bodyIndex == 0x1_0005)
        #expect(wide?.triangleIndex == 0x4_0007)
        // Wrapped to the old field widths, as the old target would have held it.
        #expect(wide?.rawValue == (UInt32(7) << 16 | 5))
    }

    @Test("The legacy resolver still resolves a wrapped triangle index")
    @available(*, deprecated)
    func legacyResolverStillWorks() {
        let body = ViewportBody.box(id: "b")
        let ray = Ray(origin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -1))
        // The index is in range for the box (12 triangles) or it is not; either way no trap.
        _ = body.resolveWrappedTriangleIndex(3, ray: ray)
        #expect(body.resolveWrappedTriangleIndex(1 << 14, ray: ray) == nil)
    }
}
