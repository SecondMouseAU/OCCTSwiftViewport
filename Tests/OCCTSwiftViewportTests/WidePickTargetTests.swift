// WidePickTargetTests.swift
// OCCTSwiftViewport Tests
//
// The RG32Uint pick target (issue #160). The pick texel is two 32-bit channels: R = the full
// 32-bit object index, G = a 30-bit primitive index plus 2 kind bits. This replaces the R32Uint
// `objectIndex (16) | primitiveID (14) << 16 | kind (2) << 30` packing, which capped a scene at
// 65,536 bodies and a body at 16,384 primitives per kind. These tests pin:
//   - the encode/decode functions at the old and new field boundaries;
//   - headless renders that pick primitives past 16,383 and past 65,535, through every pick
//     fragment (face, tessellated face, meshlet face, native and quad edge, arc, vertex) and every
//     readback (single pixel, neighborhood, region);
//   - bodies past index 65,535 end to end;
//   - normal small-scene picks, and the cleared (no-hit) texel, still work.

import CoreGraphics
import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Encoding

/// (body, primitive) pairs at the old 16-bit body field and 14-bit primitive field, and the
/// values just past each.
private let boundaryPairs: [(UInt32, UInt32)] = [
    (0, 0), (1, 1), (0xFFFF, 16_383), (0x1_0000, 16_384), (0x1_0001, 65_535),
    (65_536, 65_536), (70_000, 70_000), (1 << 24, 1 << 20), (0xFFFF_FFFE, (1 << 30) - 1),
]

@Suite("Wide pick ID encoding")
struct WidePickEncodingTests {

    /// Packs a pick texel the way `packPickID` in Shaders.metal does, written out longhand so the
    /// test does not just call the function it checks.
    private static func shaderPack(object: UInt32, primitive: UInt32, kind: UInt32) -> UInt64 {
        let r = object
        let g = (primitive & 0x3FFF_FFFF) | (kind << 30)
        return UInt64(g) << 32 | UInt64(r)
    }

    @Test("Limits are the 32-bit object index and the 30-bit primitive index")
    func limits() {
        #expect(PickResult.maxPickableBodies == 4_294_967_295)
        #expect(PickResult.maxPrimitivesPerKind == 1_073_741_824)
        #expect(PickEncoding.primitiveMask == 0x3FFF_FFFF)
        #expect(PickEncoding.bytesPerTexel == 8)
        #expect(PickResult.noHit == UInt64.max)
    }

    @Test(
        "Encode matches the shader packing and decode round-trips, at the old and new boundaries",
        arguments: boundaryPairs)
    func roundTrips(object: UInt32, primitive: UInt32) {
        for kind in [PrimitiveKind.face, .edge, .vertex] {
            let texel = PickEncoding.encode(
                objectIndex: object, primitiveIndex: primitive, kind: kind)
            #expect(
                texel
                    == Self.shaderPack(
                        object: object, primitive: primitive, kind: UInt32(kind.rawValue)))
            let decoded = PickEncoding.decode(texel)
            #expect(decoded?.objectIndex == object)
            #expect(decoded?.primitiveIndex == Int(primitive))
            #expect(decoded?.kind == kind)
        }
    }

    @Test("R holds the object index and G the primitive and kind, in the layout the GPU writes")
    func channelLayout() {
        let texel = PickEncoding.encode(objectIndex: 0xAABB_CCDD, primitiveIndex: 7, kind: .edge)
        #expect(UInt32(truncatingIfNeeded: texel) == 0xAABB_CCDD)  // R
        #expect(UInt32(truncatingIfNeeded: texel >> 32) == (1 << 30) | 7)  // G
    }

    @Test("An object index of 0xFFFF_FFFF is the no-object marker and always decodes to a miss")
    func noObjectIsAMiss() {
        for kind: UInt32 in 0...2 {
            // The shader writes the cleared texel for it whatever the primitive and kind.
            #expect(
                PickEncoding.encode(objectIndex: 0xFFFF_FFFF, primitiveIndex: 9, kindBits: kind)
                    == PickEncoding.noHit)
            // And the decoder rejects R == 0xFFFF_FFFF however G reads.
            let raw = Self.shaderPack(object: 0xFFFF_FFFF, primitive: 9, kind: kind)
            #expect(PickEncoding.decode(raw) == nil)
        }
        #expect(PickEncoding.decode(PickEncoding.noHit) == nil)
        #expect(!PickEncoding.isHit(PickEncoding.noHit))
        #expect(
            PickEncoding.isHit(PickEncoding.encode(objectIndex: 0, primitiveIndex: 0, kind: .face)))
    }

    @Test("A primitive index past 30 bits wraps without touching the kind")
    func primitiveWrapsInsideItsField() {
        let texel = PickEncoding.encode(
            objectIndex: 3, primitiveIndex: (1 << 30) + 5, kind: .vertex)
        let decoded = PickEncoding.decode(texel)
        #expect(decoded?.primitiveIndex == 5)
        #expect(decoded?.kind == .vertex)
        #expect(decoded?.objectIndex == 3)
    }

    @Test("Kind bits 3 name no PrimitiveKind and decode to a miss")
    func reservedKindIsAMiss() {
        #expect(PickEncoding.decode(Self.shaderPack(object: 1, primitive: 1, kind: 3)) == nil)
    }

    @Test("The old 16-bit aliasing is gone: body 65,537 no longer reads back as body 1")
    func noBodyAliasing() {
        let indexMap = [1: "body-1", 65_537: "body-65537"]
        let texel = PickEncoding.encode(objectIndex: 65_537, primitiveIndex: 4, kind: .face)
        let result = PickResult(pickValue: texel, indexMap: indexMap)
        #expect(result?.bodyID == "body-65537")
        #expect(result?.bodyIndex == 65_537)
        // And a body past the old limit that is not in the map is a miss, not another body.
        #expect(PickResult(pickValue: texel, indexMap: [1: "body-1"]) == nil)
    }

    @Test("BodyUniforms passes the draw-order ordinal through whole")
    func bodyUniformsKeepWideOrdinals() {
        let body = ViewportBody.box(id: "b")
        #expect(BodyUniforms(body: body, objectIndex: 42).objectIndex == 42)
        #expect(BodyUniforms(body: body, objectIndex: 0x1_0001).objectIndex == 0x1_0001)
        #expect(BodyUniforms(body: body, objectIndex: 0xFFFF_FFFE).objectIndex == 0xFFFF_FFFE)
    }

    @Test("Region decoding de-duplicates by the full 64-bit texel")
    func regionDedupeUsesWideTexel() {
        let indexMap = [0: "a", 1: "b"]
        // Same low 16 bits of body and primitive, different high bits: four distinct primitives.
        let a = PickEncoding.encode(objectIndex: 0, primitiveIndex: 5, kind: .face)
        let b = PickEncoding.encode(objectIndex: 0, primitiveIndex: 5 + 16_384, kind: .face)
        let c = PickEncoding.encode(objectIndex: 0, primitiveIndex: 5 + 65_536, kind: .face)
        let d = PickEncoding.encode(objectIndex: 1, primitiveIndex: 5, kind: .face)
        let results = ViewportRenderer.decodeRegionPickResults(
            [a, b, a, c, d, PickResult.noHit, c], indexMap: indexMap, layerMap: [:])
        #expect(results.map(\.triangleIndex) == [5, 5 + 16_384, 5 + 65_536, 5])
        #expect(results.map(\.bodyID) == ["a", "a", "a", "b"])
    }

    @Test("Neighborhood decoding keeps the exact wide index")
    func neighborhoodKeepsWideIndex() {
        let indexMap = [0: "a"]
        let far = PickEncoding.encode(objectIndex: 0, primitiveIndex: 100_000, kind: .face)
        let best = ViewportRenderer.bestNeighborhoodPickResult(
            [PickResult.noHit, far, PickResult.noHit, PickResult.noHit], width: 2,
            center: SIMD2(0, 0), indexMap: indexMap, layerMap: [:])
        #expect(best?.triangleIndex == 100_000)
    }
}

// MARK: - Headless rig

/// A square orthographic frame looking down -Z: `scale` world units span `size` pixels.
private struct OrthoFrame {
    let size: Int
    let scale: Float

    var pixelsPerUnit: Float { Float(size) / scale }

    var camera: CameraState {
        CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10,
            pivot: .zero, orthographicScale: scale, isOrthographic: true)
    }

    /// The pixel containing world point `p` (on the z = 0 plane).
    func pixel(_ p: SIMD2<Float>) -> SIMD2<Int> {
        SIMD2(
            Int((Float(size) / 2 + p.x * pixelsPerUnit).rounded(.down)),
            Int((Float(size) / 2 - p.y * pixelsPerUnit).rounded(.down)))
    }

    /// The world position of the centre of `pixel`.
    func world(_ pixel: SIMD2<Int>) -> SIMD2<Float> {
        SIMD2(
            (Float(pixel.x) + 0.5 - Float(size) / 2) / pixelsPerUnit,
            (Float(size) / 2 - (Float(pixel.y) + 0.5)) / pixelsPerUnit)
    }
}

private struct RigUnavailable: Error {}

@MainActor
private struct PickRig {
    let controller: ViewportController
    let renderer: ViewportRenderer
    let size: Int

    init(
        bodies: [ViewportBody], frame: OrthoFrame, displayMode: DisplayMode = .shaded,
        quality: RenderingQuality = .standard, edge: EdgeLineConfiguration = .default,
        pickRadius: Int = 0
    ) throws {
        var config = ViewportConfiguration()
        config.initialCameraState = frame.camera
        config.edgeLineConfiguration = edge
        config.backgroundColor = SIMD4(0, 0, 0, 1)
        config.showViewCube = false
        config.renderingQuality = quality
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: pickRadius)
        let controller = ViewportController(configuration: config)
        controller.displayMode = displayMode
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping")
            throw RigUnavailable()
        }
        guard
            renderer.renderHeadlessBGRA(
                width: frame.size, height: frame.size, backgroundColor: SIMD4(0, 0, 0, 1)) != nil
        else {
            Issue.record("headless render returned nil")
            throw RigUnavailable()
        }
        self.controller = controller
        self.renderer = renderer
        self.size = frame.size
    }

    func pick(_ pixel: SIMD2<Int>) async -> PickResult? {
        await withCheckedContinuation { continuation in
            renderer.performPick(at: pixel) { continuation.resume(returning: $0) }
        }
    }

    func region(_ rect: CGRect) async -> [PickResult] {
        await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
    }

    func wholeFrame() async -> [PickResult] {
        await region(CGRect(x: 0, y: 0, width: size, height: size))
    }
}

// MARK: - Sparse bodies: few primitives on screen, many off it

/// `count` +Z normals as a flat `[x, y, z, ...]` array.
private func upNormals(count: Int) -> [Float] {
    var normals: [Float] = []
    normals.reserveCapacity(count * 3)
    for _ in 0..<count { normals += [0, 0, 1] }
    return normals
}

/// Primitive indices that straddle the old limits: 16,384 per kind (14 bits) and 65,536.
private let wideTargets = [5, 16_383, 16_384, 16_385, 40_000, 65_535, 65_536, 69_999]

/// A body of `count` triangles, nearly all off to the right of the frame. Triangle `targets[k]`
/// sits on screen at slot `k`, so a pick there must report exactly that index.
private func sparseTriangleBody(
    count: Int, targets: [Int], direct: Bool
) -> (body: ViewportBody, centroids: [SIMD2<Float>]) {
    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(count * 3)
    var centroids = [SIMD2<Float>](repeating: .zero, count: targets.count)
    let slot = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1, $0) })
    let side: Float = 0.25
    for t in 0..<count {
        if let k = slot[t] {
            let x0 = -1.5 + 0.38 * Float(k)
            let y0: Float = -0.1
            positions += [SIMD3(x0, y0, 0), SIMD3(x0 + side, y0, 0), SIMD3(x0, y0 + side, 0)]
            centroids[k] = SIMD2(x0 + side / 3, y0 + side / 3)
        } else {
            let x = 5 + Float(t % 100) * 0.01
            positions += [SIMD3(x, 0, 0), SIMD3(x + 0.05, 0, 0), SIMD3(x, 0.05, 0)]
        }
    }
    let indices = (0..<UInt32(positions.count)).map { $0 }
    let color = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    if direct {
        var body = ViewportBody.directMesh(
            id: "big", positions: positions.flatMap { [$0.x, $0.y, $0.z] },
            normals: upNormals(count: positions.count), indices: indices, color: color)
        // directMesh derives pickable vertices; drop them so only faces are stamped.
        body.vertices = []
        body.vertexIndices = []
        return (body, centroids)
    }
    var vertexData: [Float] = []
    vertexData.reserveCapacity(positions.count * 6)
    for p in positions { vertexData += [p.x, p.y, p.z, 0, 0, 1] }
    return (
        ViewportBody(
            id: "big", vertexData: vertexData, indices: indices, edges: [], color: color),
        centroids
    )
}

@MainActor
@Suite("Face picks past the old 16-bit and 14-bit limits")
struct WideFacePickTests {

    fileprivate static let frame = OrthoFrame(size: 256, scale: 4)

    /// Picks every target's centroid and the whole frame, and checks both name the same set.
    private func checkTargets(
        direct: Bool, quality: RenderingQuality = .standard, count: Int = 70_000,
        requireMeshShaders: Bool = false, requireTessellation: Bool = false, pickRadius: Int = 0
    ) async throws {
        let frame = Self.frame
        let sparse = sparseTriangleBody(count: count, targets: wideTargets, direct: direct)
        let rig = try PickRig(
            bodies: [sparse.body], frame: frame, quality: quality, pickRadius: pickRadius)
        if requireMeshShaders, rig.renderer.meshShaderPickPipeline == nil { return }
        if requireTessellation, rig.renderer.tessellatedPickPipeline == nil { return }

        for (k, target) in wideTargets.enumerated() {
            let pixel = frame.pixel(sparse.centroids[k])
            let hit = await rig.pick(pixel)
            #expect(hit?.bodyID == "big", "target \(target)")
            #expect(hit?.kind == .face, "target \(target)")
            #expect(hit?.triangleIndex == target, "single-pixel pick of triangle \(target)")
        }

        let faces = await rig.wholeFrame().filter { $0.kind == .face }
        #expect(Set(faces.map(\.triangleIndex)) == Set(wideTargets), "region pick")
        #expect(faces.allSatisfy { $0.bodyID == "big" })
    }

    @Test("Interleaved mesh: exact triangle index at 16,383 / 16,384 / 65,535 / 65,536 / 69,999")
    func interleavedMesh() async throws {
        try await checkTargets(direct: false)
    }

    @Test("Direct mesh: exact triangle index past both limits")
    func directMesh() async throws {
        try await checkTargets(direct: true)
    }

    @Test("Neighborhood pick (pickRadius > 0) reports the exact index too")
    func neighborhoodPick() async throws {
        try await checkTargets(direct: false, pickRadius: 2)
    }

    @Test("Tessellated surfaces (.enhanced) report the exact input triangle index")
    func tessellatedMesh() async throws {
        try await checkTargets(direct: false, quality: .enhanced, requireTessellation: true)
    }

    @Test("Mesh-shader surfaces (.maximum) report the exact global triangle index")
    func meshShaderMesh() async throws {
        try await checkTargets(direct: false, quality: .maximum, requireMeshShaders: true)
    }
}

// MARK: - A real >100k-triangle direct-mesh grid

@MainActor
@Suite("Picking a 135,200-triangle direct-mesh grid")
struct LargeGridPickTests {

    static let cells = 260
    static let cellSize: Float = 0.01
    fileprivate static let frame = OrthoFrame(size: 1024, scale: 2.8)

    static var triangleCount: Int { cells * cells * 2 }

    /// `cells x cells` quads in the z = 0 plane, centred on the origin: quad (i, j) owns
    /// triangles `2 * (j * cells + i)` (lower right) and `+ 1` (upper left).
    static func grid() -> ViewportBody {
        let n = cells
        var positions: [Float] = []
        positions.reserveCapacity((n + 1) * (n + 1) * 3)
        for j in 0...n {
            for i in 0...n {
                positions += [
                    (Float(i) - Float(n) / 2) * cellSize, (Float(j) - Float(n) / 2) * cellSize, 0,
                ]
            }
        }
        let normals = upNormals(count: (n + 1) * (n + 1))
        var indices: [UInt32] = []
        indices.reserveCapacity(n * n * 6)
        for j in 0..<n {
            for i in 0..<n {
                let v00 = UInt32(j * (n + 1) + i)
                let v10 = v00 + 1
                let v01 = v00 + UInt32(n + 1)
                let v11 = v01 + 1
                indices += [v00, v10, v11, v00, v11, v01]
            }
        }
        var body = ViewportBody.directMesh(
            id: "grid", positions: positions, normals: normals, indices: indices,
            color: SIMD4(0.7, 0.7, 0.75, 1))
        body.vertices = []
        body.vertexIndices = []
        return body
    }

    /// The triangle covering `pixel`'s centre, with whether the centre sits clear of every
    /// triangle edge (so the GPU's tie-breaking rules cannot change the answer).
    fileprivate static func expectedTriangle(at pixel: SIMD2<Int>) -> (index: Int, isClear: Bool)? {
        let w = frame.world(pixel)
        let half = Float(cells) / 2
        let gx = w.x / cellSize + half
        let gy = w.y / cellSize + half
        let i = Int(gx.rounded(.down))
        let j = Int(gy.rounded(.down))
        guard i >= 0, i < cells, j >= 0, j < cells else { return nil }
        let fx = gx - Float(i)
        let fy = gy - Float(j)
        let index = 2 * (j * cells + i) + (fy > fx ? 1 : 0)
        let margin: Float = 0.12
        let clear =
            fx > margin && fx < 1 - margin && fy > margin && fy < 1 - margin
            && abs(fx - fy) > margin
        return (index, clear)
    }

    @Test("Pixels across the grid pick the analytically expected triangle, past 100,000")
    func singlePixelPicks() async throws {
        let frame = Self.frame
        let rig = try PickRig(bodies: [Self.grid()], frame: frame)
        var checked = 0
        var beyond16Bit = 0
        var beyond14Bit = 0
        // A lattice of pixels over the whole grid, skipping those too close to a triangle edge.
        for py in stride(from: 3, to: frame.size, by: 37) {
            for px in stride(from: 5, to: frame.size, by: 41) {
                guard let expected = Self.expectedTriangle(at: SIMD2(px, py)), expected.isClear
                else { continue }
                let hit = await rig.pick(SIMD2(px, py))
                #expect(hit?.bodyID == "grid")
                #expect(hit?.triangleIndex == expected.index, "pixel (\(px), \(py))")
                checked += 1
                if expected.index > 65_535 { beyond16Bit += 1 }
                if expected.index > 16_383 { beyond14Bit += 1 }
            }
        }
        #expect(checked > 150)
        #expect(beyond14Bit > 50)
        #expect(beyond16Bit > 30)
    }

    @Test("A region over the grid reports exactly the triangles under its pixels")
    func regionPicks() async throws {
        let frame = Self.frame
        let rig = try PickRig(bodies: [Self.grid()], frame: frame)
        // Rectangles over the upper rows of the grid, where indices exceed 65,535.
        for rect in [
            CGRect(x: 600, y: 120, width: 9, height: 7),
            CGRect(x: 300, y: 200, width: 12, height: 5),
            CGRect(x: 880, y: 60, width: 6, height: 6),
        ] {
            var strong = Set<Int>()
            var possible = Set<Int>()
            for py in Int(rect.minY)..<Int(rect.maxY) {
                for px in Int(rect.minX)..<Int(rect.maxX) {
                    guard let expected = Self.expectedTriangle(at: SIMD2(px, py)) else { continue }
                    if expected.isClear { strong.insert(expected.index) }
                    // Within a margin of an edge either neighbour may win: allow the cell and
                    // the cells around it.
                    let cell = expected.index / 2 * 2
                    for rowOffset in [-2 * Self.cells, 0, 2 * Self.cells] {
                        for columnOffset in [-2, 0, 2] {
                            let n = cell + rowOffset + columnOffset
                            if n >= 0 { possible.formUnion([n, n + 1]) }
                        }
                    }
                }
            }
            let reported = Set(await rig.region(rect).map(\.triangleIndex))
            #expect(
                strong.isSubset(of: reported),
                "rect \(rect): missing \(strong.subtracting(reported))")
            #expect(
                reported.isSubset(of: possible),
                "rect \(rect): unexpected \(reported.subtracting(possible))")
            #expect((reported.max() ?? 0) > 16_383)
        }
    }

    @Test("A full-frame region pick sees most of the grid, with indices up to the last triangle")
    func wholeFrameRegionPick() async throws {
        let rig = try PickRig(bodies: [Self.grid()], frame: Self.frame)
        let faces = await rig.wholeFrame().filter { $0.kind == .face }
        let indices = Set(faces.map(\.triangleIndex))
        #expect(faces.allSatisfy { $0.bodyID == "grid" })
        #expect(indices.allSatisfy { $0 >= 0 && $0 < Self.triangleCount })
        #expect(indices.count > Self.triangleCount * 2 / 3, "saw only \(indices.count) triangles")
        #expect((indices.max() ?? 0) > Self.triangleCount - 1000)
        #expect(indices.filter { $0 > 65_535 }.count > 20_000)
    }
}

// MARK: - Edges, arcs and vertices

/// Pixel-centre rows for edge and vertex slots: row `rows[k]` carries target `k`.
private func slotRows(count: Int) -> [Int] {
    (0..<count).map { 20 + 28 * $0 }
}

@MainActor
@Suite("Edge, arc and vertex picks past the old limits")
struct WideEdgeVertexPickTests {

    fileprivate static let frame = OrthoFrame(size: 256, scale: 4)
    static let segmentTargets = [3, 16_383, 16_384, 40_000, 65_535, 65_536, 69_999]

    /// 70,000 one-segment polylines. Segment `targets[k]` is a horizontal line through the centre
    /// of pixel row `rows[k]`; the rest are off the right of the frame.
    static func edgeBody() -> ViewportBody {
        let frame = Self.frame
        let rows = slotRows(count: segmentTargets.count)
        let slot = Dictionary(uniqueKeysWithValues: segmentTargets.enumerated().map { ($1, $0) })
        var polylines: [[SIMD3<Float>]] = []
        polylines.reserveCapacity(70_000)
        for t in 0..<70_000 {
            if let k = slot[t] {
                let y = frame.world(SIMD2(128, rows[k])).y
                polylines.append([SIMD3(-1.5, y, 0), SIMD3(1.5, y, 0)])
            } else {
                let x = 5 + Float(t % 100) * 0.01
                polylines.append([SIMD3(x, 0, 0), SIMD3(x + 0.05, 0, 0)])
            }
        }
        return ViewportBody(
            id: "edges", vertexData: [], indices: [], edges: polylines,
            edgeIndices: (0..<70_000).map { Int32($0) }, color: SIMD4(1, 1, 1, 1))
    }

    private func checkEdges(quad: Bool) async throws {
        let frame = Self.frame
        let rig = try PickRig(
            bodies: [Self.edgeBody()], frame: frame, displayMode: .wireframe,
            edge: EdgeLineConfiguration(useQuadExpansion: quad))
        let rows = slotRows(count: Self.segmentTargets.count)
        for (k, target) in Self.segmentTargets.enumerated() {
            let hit = await rig.pick(SIMD2(128, rows[k]))
            #expect(hit?.kind == .edge, "segment \(target), quad: \(quad)")
            #expect(hit?.bodyID == "edges")
            #expect(
                hit?.triangleIndex == target, "single-pixel edge pick of \(target), quad: \(quad)")
        }
        let column = await rig.region(CGRect(x: 128, y: 0, width: 1, height: frame.size))
        #expect(
            Set(column.filter { $0.kind == .edge }.map(\.triangleIndex))
                == Set(Self.segmentTargets),
            "quad: \(quad)")
    }

    @Test("Quad-expanded edge pick reports segment indices 16,383 ... 69,999")
    func quadEdges() async throws {
        try await checkEdges(quad: true)
    }

    @Test("Native line edge pick reports segment indices 16,383 ... 69,999")
    func nativeEdges() async throws {
        try await checkEdges(quad: false)
    }

    @Test("Vertex picks report point indices 16,383 ... 69,999")
    func vertices() async throws {
        let frame = Self.frame
        let targets = Self.segmentTargets
        let rows = slotRows(count: targets.count)
        let slot = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1, $0) })
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(70_000)
        for t in 0..<70_000 {
            if let k = slot[t] {
                let w = frame.world(SIMD2(128, rows[k]))
                points.append(SIMD3(w.x, w.y, 0))
            } else {
                points.append(SIMD3(5 + Float(t % 100) * 0.01, 0, 0))
            }
        }
        let body = ViewportBody(
            id: "pts", vertexData: [], indices: [], edges: [], vertices: points,
            color: SIMD4(1, 1, 1, 1))
        let rig = try PickRig(bodies: [body], frame: frame)
        for (k, target) in targets.enumerated() {
            let hit = await rig.pick(SIMD2(128, rows[k]))
            #expect(hit?.kind == .vertex, "vertex \(target)")
            #expect(hit?.triangleIndex == target, "single-pixel vertex pick of \(target)")
        }
        let column = await rig.region(CGRect(x: 124, y: 0, width: 9, height: frame.size))
        #expect(
            Set(column.filter { $0.kind == .vertex }.map(\.triangleIndex)) == Set(targets))
    }

    @Test("Arc picks report arc indices past 16,383 (native and quad)")
    func arcs() async throws {
        let frame = Self.frame
        let targets = [2, 16_383, 16_384, 17_499]
        let slot = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($1, $0) })
        var centres = [SIMD2<Float>](repeating: .zero, count: targets.count)
        var arcs: [ViewportArc] = []
        for t in 0..<17_500 {
            if let k = slot[t] {
                let c = SIMD2<Float>(-1.2 + 0.8 * Float(k), 0)
                centres[k] = c
                arcs.append(
                    .circle(
                        center: SIMD3(c.x, c.y, 0), radius: 0.25, xAxis: SIMD3(1, 0, 0),
                        yAxis: SIMD3(0, 1, 0)))
            } else {
                arcs.append(
                    .circle(
                        center: SIMD3(5 + Float(t % 100) * 0.01, 0, 0), radius: 0.01,
                        xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)))
            }
        }
        let body = ViewportBody(
            id: "arcs", vertexData: [], indices: [], edges: [], arcs: arcs,
            color: SIMD4(1, 1, 1, 1))
        for quad in [true, false] {
            let rig = try PickRig(
                bodies: [body], frame: frame, displayMode: .wireframe,
                edge: EdgeLineConfiguration(useQuadExpansion: quad))
            for (k, target) in targets.enumerated() {
                // A box round the circle's rightmost point, where the arc is vertical.
                let p = frame.pixel(SIMD2(centres[k].x + 0.25, centres[k].y))
                let hits = await rig.region(CGRect(x: p.x - 3, y: p.y - 3, width: 7, height: 7))
                #expect(
                    Set(hits.map(\.triangleIndex)) == [target], "arc \(target), quad: \(quad)")
                #expect(hits.allSatisfy { $0.kind == .edge && $0.bodyID == "arcs" })
            }
        }
    }
}

// MARK: - Many bodies

@MainActor
@Suite("Body indices past the old 65,535 limit")
struct WideBodyIndexPickTests {

    fileprivate static let frame = OrthoFrame(size: 256, scale: 4)

    static func quad(id: String, centre: SIMD2<Float>, half: Float = 0.12) -> ViewportBody {
        var data: [Float] = []
        for c: SIMD2<Float> in [[-1, -1], [1, -1], [1, 1], [-1, 1]] {
            data += [centre.x + c.x * half, centre.y + c.y * half, 0, 0, 0, 1]
        }
        return ViewportBody(
            id: id, vertexData: data, indices: [0, 1, 2, 0, 2, 3], edges: [],
            color: SIMD4(0.8, 0.5, 0.3, 1))
    }

    /// A body with no geometry: it takes a draw-order ordinal and nothing else.
    static func empty(_ i: Int) -> ViewportBody {
        ViewportBody(
            id: "empty-\(i)", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1))
    }

    @Test("Bodies at draw-order index 0, 65,535, 65,536, 65,537 and 70,000 each pick as themselves")
    func bodiesPastTheOldLimit() async throws {
        let frame = Self.frame
        let real: [Int: SIMD2<Float>] = [
            0: SIMD2(-1.5, 0.6), 65_535: SIMD2(-0.75, 0.6), 65_536: SIMD2(0, 0.6),
            65_537: SIMD2(0.75, 0.6), 70_000: SIMD2(1.5, 0.6),
        ]
        let total = 70_001
        var bodies: [ViewportBody] = []
        bodies.reserveCapacity(total)
        for i in 0..<total {
            if let centre = real[i] {
                bodies.append(Self.quad(id: "body-\(i)", centre: centre))
            } else {
                bodies.append(Self.empty(i))
            }
        }
        let rig = try PickRig(bodies: bodies, frame: frame)
        for (index, centre) in real.sorted(by: { $0.key < $1.key }) {
            let hit = await rig.pick(frame.pixel(centre))
            #expect(hit?.bodyID == "body-\(index)", "body \(index)")
            #expect(hit?.bodyIndex == index, "body \(index)")
            #expect(hit?.kind == .face)
            #expect(hit?.triangleIndex != nil)
        }
        let all = await rig.wholeFrame()
        #expect(Set(all.map(\.bodyID)) == Set(real.keys.map { "body-\($0)" }))
        // Empty ground between the quads is still a miss.
        let miss = await rig.pick(frame.pixel(SIMD2(0, -1)))
        #expect(miss == nil)
    }

    @Test("A non-pickable body still advances the draw-order index")
    func nonPickableAdvancesIndex() async throws {
        let frame = Self.frame
        var bodies = (0..<65_540).map { Self.empty($0) }
        var hidden = Self.quad(id: "hidden", centre: SIMD2(-0.5, 0))
        hidden.isPickable = false
        bodies[65_538] = hidden
        bodies[65_539] = Self.quad(id: "after", centre: SIMD2(0.5, 0))
        let rig = try PickRig(bodies: bodies, frame: frame)
        let after = await rig.pick(frame.pixel(SIMD2(0.5, 0)))
        #expect(after?.bodyID == "after")
        #expect(after?.bodyIndex == 65_539)
        let skipped = await rig.pick(frame.pixel(SIMD2(-0.5, 0)))
        #expect(skipped == nil)
    }

    @Test("Three thousand real bodies are all individually pickable")
    func thousandsOfBodies() async throws {
        let frame = OrthoFrame(size: 512, scale: 8)
        let columns = 60
        let rows = 50
        var bodies: [ViewportBody] = []
        var centres: [SIMD2<Float>] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let centre = SIMD2<Float>(-3.5 + Float(c) * 0.12, -3 + Float(r) * 0.12)
                centres.append(centre)
                bodies.append(Self.quad(id: "q\(r * columns + c)", centre: centre, half: 0.04))
            }
        }
        let rig = try PickRig(bodies: bodies, frame: frame)
        for index in Array(stride(from: 0, to: bodies.count, by: 97)) + [bodies.count - 1] {
            let hit = await rig.pick(frame.pixel(centres[index]))
            #expect(hit?.bodyID == "q\(index)")
            #expect(hit?.bodyIndex == index)
        }
        let all = await rig.wholeFrame()
        #expect(Set(all.map(\.bodyID)).count == bodies.count)
    }
}

// MARK: - Regression: ordinary scenes

@MainActor
@Suite("Normal picks are unchanged")
struct OrdinaryPickRegressionTests {

    fileprivate static let frame = OrthoFrame(size: 160, scale: 4)

    @Test("Two bodies pick as themselves, with in-range triangle indices and the wide texel")
    func twoBodies() async throws {
        var box = ViewportBody.box(id: "box", width: 1, height: 1, depth: 1, color: .one)
        box.transform.columns.3 = SIMD4(-1.2, 0, 0, 1)
        var sphere = ViewportBody.sphere(id: "sphere", radius: 0.5, color: .one)
        sphere.transform.columns.3 = SIMD4(1.2, 0, 0, 1)
        let frame = Self.frame
        let rig = try PickRig(bodies: [box, sphere], frame: frame)

        let onBox = await rig.pick(frame.pixel(SIMD2(-1.2, 0)))
        #expect(onBox?.bodyID == "box")
        #expect(onBox?.bodyIndex == 0)
        #expect(onBox?.kind == .face)
        #expect((onBox?.triangleIndex ?? -1) < box.indices.count / 3)

        let onSphere = await rig.pick(frame.pixel(SIMD2(1.2, 0)))
        #expect(onSphere?.bodyID == "sphere")
        #expect(onSphere?.bodyIndex == 1)
        #expect((onSphere?.triangleIndex ?? -1) < sphere.indices.count / 3)
        // The result carries the texel it came from, and decoding it again gives the same pick.
        if let onSphere {
            let again = PickResult(
                pickValue: onSphere.pickValue, indexMap: [0: "box", 1: "sphere"])
            #expect(again == onSphere)
        }

        let all = await rig.wholeFrame()
        #expect(Set(all.map(\.bodyID)) == ["box", "sphere"])
    }

    @Test("Background pixels are the cleared texel: no result, single pixel or region")
    func backgroundIsAMiss() async throws {
        let frame = Self.frame
        let rig = try PickRig(
            bodies: [ViewportBody.box(id: "box", width: 0.4, height: 0.4, depth: 0.4, color: .one)],
            frame: frame)
        let corner = await rig.pick(SIMD2(2, 2))
        #expect(corner == nil)
        let cornerRegion = await rig.region(CGRect(x: 0, y: 0, width: 12, height: 12))
        #expect(cornerRegion.isEmpty)
        let centre = await rig.pick(SIMD2(80, 80))
        #expect(centre?.bodyID == "box")
    }
}

// MARK: - The deprecated wrap-resolution helper

/// A body with `triangleCount` triangles, all tiny and off to the side, except the triangles
/// listed in `facing`, which are 2x2 triangles centred on the Z axis at the given depth.
private func bodyWithTriangles(_ triangleCount: Int, facing: [Int: Float]) -> ViewportBody {
    var vertexData: [Float] = []
    vertexData.reserveCapacity(triangleCount * 18)
    for t in 0..<triangleCount {
        let corners: [SIMD3<Float>]
        if let z = facing[t] {
            corners = [SIMD3(-1, -1, z), SIMD3(1, -1, z), SIMD3(0, 1, z)]
        } else {
            let x = 100 + Float(t % 100)
            corners = [SIMD3(x, 0, 0), SIMD3(x + 0.1, 0, 0), SIMD3(x, 0.1, 0)]
        }
        for p in corners { vertexData += [p.x, p.y, p.z, 0, 0, 1] }
    }
    return ViewportBody(
        id: "big", vertexData: vertexData, indices: (0..<UInt32(triangleCount * 3)).map { $0 },
        edges: [], color: SIMD4<Float>(1, 1, 1, 1))
}

@Suite("Deprecated wrapped face-pick resolution")
struct WrappedFacePickResolutionTests {

    let ray = Ray(origin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -1))

    @Test("The nearest congruent triangle under the ray wins")
    @available(*, deprecated)
    func resolvesNearestCandidate() {
        // Triangle 5 and triangle 16,389 are congruent mod 16,384; 16,389 is nearer the camera.
        let body = bodyWithTriangles(20_000, facing: [5: -10, 16_389: -5])
        #expect(body.resolveWrappedTriangleIndex(5, ray: ray) == 16_389)

        // Only triangle 5 is under the ray: it resolves to itself.
        let lone = bodyWithTriangles(20_000, facing: [5: -10])
        #expect(lone.resolveWrappedTriangleIndex(5, ray: ray) == 5)
    }

    @Test("No candidate under the ray, or an out-of-range index, resolves to nil")
    @available(*, deprecated)
    func unresolvable() {
        let body = bodyWithTriangles(20_000, facing: [5: -10])
        #expect(body.resolveWrappedTriangleIndex(6, ray: ray) == nil)
        #expect(body.resolveWrappedTriangleIndex(-1, ray: ray) == nil)
        #expect(body.resolveWrappedTriangleIndex(16_384, ray: ray) == nil)
    }
}

// MARK: - Headless: tessellated and mesh-shader pick paths

@MainActor
@Suite("Pick triangle index under enhanced/maximum rendering quality")
struct HighQualityPickIndexTests {

    static let width = 160
    static let height = 120
    /// Face index stamped on every triangle: far above the sphere's triangle count, so a pick that
    /// reports the face index instead of the triangle index is out of range.
    static let faceIndexStamp: Int32 = 7_777

    static func sphere() -> ViewportBody {
        var body = ViewportBody.sphere(
            id: "sphere", radius: 0.8, color: SIMD4<Float>(0.4, 0.7, 0.9, 1))
        body.faceIndices = [Int32](repeating: faceIndexStamp, count: body.indices.count / 3)
        return body
    }

    /// Renders one frame at `quality` and returns the renderer plus every face triangle index in
    /// the pick texture.
    static func pickTriangles(
        quality: RenderingQuality
    ) async -> (renderer: ViewportRenderer, controller: ViewportController, triangles: Set<Int>)? {
        let body = sphere()
        let camera = ViewportRenderBattery.fittedCamera(for: [body])
        let configuration = ViewportConfiguration(
            initialCameraState: camera,
            pickingConfiguration: PickingConfiguration(isEnabled: true),
            renderingQuality: quality)
        let controller = ViewportController(configuration: configuration)
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
        else { return nil }
        guard
            renderer.renderHeadlessBGRA(
                width: width, height: height, backgroundColor: configuration.backgroundColor) != nil
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let results: [PickResult] = await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
        let triangles = Set(results.filter { $0.kind == .face }.map(\.triangleIndex))
        return (renderer, controller, triangles)
    }

    @Test("Tessellated pick reports the input triangle index, not the B-Rep face index")
    func tessellatedPickReportsTriangle() async throws {
        guard let reference = await Self.pickTriangles(quality: .standard),
            let enhanced = await Self.pickTriangles(quality: .enhanced)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        guard enhanced.renderer.tessellatedPickPipeline != nil else {
            Issue.record("Tessellation unsupported on this device; the H7 path was not exercised")
            return
        }
        let triangleCount = Self.sphere().indices.count / 3
        #expect(!enhanced.triangles.isEmpty)
        #expect(!enhanced.triangles.contains(Int(Self.faceIndexStamp)))
        #expect(enhanced.triangles.allSatisfy { $0 < triangleCount })
        // PN smoothing shifts silhouettes slightly, so compare overlap rather than equality.
        let shared = enhanced.triangles.intersection(reference.triangles).count
        #expect(Double(shared) / Double(reference.triangles.count) > 0.8)
    }

    @Test("Mesh-shader pick reports the global triangle index, not the meshlet-local one")
    func meshShaderPickReportsGlobalTriangle() async throws {
        guard let reference = await Self.pickTriangles(quality: .standard),
            let maximum = await Self.pickTriangles(quality: .maximum)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        guard maximum.renderer.meshShaderPickPipeline != nil else {
            // Pre-Apple9 GPUs fall back to the tessellated path, covered above.
            return
        }
        let triangleCount = Self.sphere().indices.count / 3
        #expect(maximum.triangles.allSatisfy { $0 < triangleCount })
        // Meshlet-local IDs never exceed 63; the visible hemisphere spans far more triangles.
        #expect((maximum.triangles.max() ?? 0) >= 64)
        let shared = maximum.triangles.intersection(reference.triangles).count
        #expect(Double(shared) / Double(reference.triangles.count) > 0.8)
    }
}
