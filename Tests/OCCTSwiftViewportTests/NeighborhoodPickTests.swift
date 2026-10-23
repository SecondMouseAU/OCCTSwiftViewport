// NeighborhoodPickTests.swift
// OCCTSwiftViewport Tests
//
// Pick tolerance radius (issue #118). With `PickingConfiguration.pickRadius > 0`, `performPick`
// reads the square around the cursor and chooses one hit from it. The GPU blit needs a live
// drawable to populate the pick texture (same caveat as RegionPickTests), so these tests cover
// the two pure functions it delegates to: neighborhood clamping (`clampPickNeighborhood`) and
// best-hit selection (`bestNeighborhoodPickResult`).

import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Neighborhood pick clamping")
struct NeighborhoodPickClampTests {

    @Test("A neighborhood fully inside the texture is (2r+1) square around the pixel")
    func fullyInside() {
        let region = ViewportRenderer.clampPickNeighborhood(
            around: SIMD2(50, 40), radius: 3, textureWidth: 200, textureHeight: 100)
        #expect(region?.x == 47)
        #expect(region?.y == 37)
        #expect(region?.width == 7)
        #expect(region?.height == 7)
    }

    @Test("A pixel at the top-left corner is clamped to the texture origin")
    func clampedAtOrigin() {
        let region = ViewportRenderer.clampPickNeighborhood(
            around: SIMD2(1, 0), radius: 3, textureWidth: 200, textureHeight: 100)
        #expect(region?.x == 0)
        #expect(region?.y == 0)
        #expect(region?.width == 5)
        #expect(region?.height == 4)
    }

    @Test("A pixel at the far corner is clamped to the texture bounds")
    func clampedAtFarCorner() {
        let region = ViewportRenderer.clampPickNeighborhood(
            around: SIMD2(199, 99), radius: 2, textureWidth: 200, textureHeight: 100)
        #expect(region?.x == 197)
        #expect(region?.y == 97)
        #expect(region?.width == 3)
        #expect(region?.height == 3)
    }

    @Test("A neighborhood entirely outside the texture returns nil")
    func entirelyOutside() {
        #expect(
            ViewportRenderer.clampPickNeighborhood(
                around: SIMD2(300, 50), radius: 2, textureWidth: 200, textureHeight: 100) == nil)
    }

    @Test("Zero-size texture (no frame drawn yet) returns nil")
    func zeroSizeTexture() {
        #expect(
            ViewportRenderer.clampPickNeighborhood(
                around: SIMD2(0, 0), radius: 2, textureWidth: 0, textureHeight: 0) == nil)
    }
}

@Suite("Neighborhood pick best-hit selection")
struct NeighborhoodPickSelectionTests {

    private static let map: [Int: String] = [0: "a", 1: "b", 2: "c"]
    private static let bg = PickResult.sentinel

    private static func face(_ body: UInt32, _ primitive: UInt32) -> UInt32 {
        (UInt32(PrimitiveKind.face.rawValue) << 30) | (primitive << 16) | body
    }
    private static func edge(_ body: UInt32, _ primitive: UInt32) -> UInt32 {
        (UInt32(PrimitiveKind.edge.rawValue) << 30) | (primitive << 16) | body
    }
    private static func vertex(_ body: UInt32, _ primitive: UInt32) -> UInt32 {
        (UInt32(PrimitiveKind.vertex.rawValue) << 30) | (primitive << 16) | body
    }

    private static func pick(_ values: [UInt32], width: Int, center: SIMD2<Int>) -> PickResult? {
        ViewportRenderer.bestNeighborhoodPickResult(
            values, width: width, center: center, indexMap: map, layerMap: [:])
    }

    @Test("An all-background neighborhood picks nothing")
    func allBackground() {
        #expect(
            Self.pick(Array(repeating: Self.bg, count: 9), width: 3, center: SIMD2(1, 1)) == nil)
    }

    @Test("A thin edge beside the cursor is picked although the cursor pixel is background")
    func edgeBesideBackgroundCursor() {
        let values = [
            Self.bg, Self.bg, Self.edge(1, 4),
            Self.bg, Self.bg, Self.edge(1, 4),
            Self.bg, Self.bg, Self.edge(1, 4),
        ]
        let hit = Self.pick(values, width: 3, center: SIMD2(1, 1))
        #expect(hit?.kind == .edge)
        #expect(hit?.bodyID == "b")
        #expect(hit?.triangleIndex == 4)
    }

    @Test("An edge beats the face under the cursor")
    func edgeBeatsFace() {
        let f = Self.face(0, 7)
        let values = [
            f, f, f,
            f, f, f,
            f, f, Self.edge(0, 2),
        ]
        let hit = Self.pick(values, width: 3, center: SIMD2(1, 1))
        #expect(hit?.kind == .edge)
        #expect(hit?.triangleIndex == 2)
    }

    @Test("A vertex beats an edge, even when the edge is nearer the cursor")
    func vertexBeatsNearerEdge() {
        let values = [
            Self.vertex(2, 9), Self.bg, Self.bg,
            Self.bg, Self.edge(0, 1), Self.bg,
            Self.bg, Self.bg, Self.bg,
        ]
        let hit = Self.pick(values, width: 3, center: SIMD2(1, 1))
        #expect(hit?.kind == .vertex)
        #expect(hit?.bodyID == "c")
    }

    @Test("Among hits of the same kind, the one nearest the cursor wins")
    func nearestOfSameKindWins() {
        // 5 wide; cursor at column 2. Edge 3 sits two columns away, edge 5 one column away.
        let values = [
            Self.edge(0, 3), Self.bg, Self.bg, Self.edge(1, 5), Self.bg,
        ]
        let hit = Self.pick(values, width: 5, center: SIMD2(2, 0))
        #expect(hit?.bodyID == "b")
        #expect(hit?.triangleIndex == 5)
    }

    @Test("Distance is measured in 2D: row offset counts, not just column")
    func distanceUsesRowAndColumn() {
        // 3x3, cursor at (0, 0). Edge 1 at (2, 0) is distSq 4; edge 2 at (1, 1) is distSq 2.
        let values = [
            Self.bg, Self.bg, Self.edge(0, 1),
            Self.bg, Self.edge(0, 2), Self.bg,
            Self.bg, Self.bg, Self.bg,
        ]
        #expect(Self.pick(values, width: 3, center: SIMD2(0, 0))?.triangleIndex == 2)
    }

    @Test("An exact distance tie keeps the first hit in row-major order")
    func tieKeepsFirst() {
        let values = [
            Self.bg, Self.edge(0, 1), Self.bg,
            Self.bg, Self.bg, Self.bg,
            Self.bg, Self.edge(0, 2), Self.bg,
        ]
        #expect(Self.pick(values, width: 3, center: SIMD2(1, 1))?.triangleIndex == 1)
    }

    @Test("A raw value whose body is not in the index map is skipped, not picked")
    func unknownBodySkipped() {
        let values = [Self.vertex(42, 0), Self.face(0, 3)]
        let hit = Self.pick(values, width: 2, center: SIMD2(0, 0))
        #expect(hit?.kind == .face)
        #expect(hit?.bodyID == "a")
    }

    @Test("The layer map is applied to the chosen hit")
    func respectsLayerMap() {
        let hit = ViewportRenderer.bestNeighborhoodPickResult(
            [Self.edge(1, 0)], width: 1, center: SIMD2(0, 0),
            indexMap: Self.map, layerMap: ["b": .widget])
        #expect(hit?.pickLayer == .widget)
    }
}
