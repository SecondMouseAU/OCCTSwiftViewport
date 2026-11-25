import OCCTSwiftViewport
import Testing
import simd

@testable import MeshVertexReaderCheck

private func deinterleave(_ vd: [Float]) -> (pos: [Float], nrm: [Float]) {
    var pos: [Float] = []
    var nrm: [Float] = []
    var i = 0
    while i + 5 < vd.count {
        pos += [vd[i], vd[i + 1], vd[i + 2]]
        nrm += [vd[i + 3], vd[i + 4], vd[i + 5]]
        i += 6
    }
    return (pos, nrm)
}

/// The same box twice, interleaved and as a direct-mesh body.
///
/// Triangle `t` belongs to face `t / 2`.
private func boxPair() -> (interleaved: ViewportBody, direct: ViewportBody, faces: [Int32]) {
    var ref = ViewportBody.box(id: "ref", width: 2, height: 3, depth: 4, up: .z)
    let faces = (0..<(ref.indices.count / 3)).map { Int32($0 / 2) }
    ref.faceIndices = faces
    let d = deinterleave(ref.vertexData)
    let direct = ViewportBody.directMesh(
        id: "direct", positions: d.pos, normals: d.nrm, indices: ref.indices,
        color: ref.color, faceIndices: faces)
    return (ref, direct, faces)
}

@Suite("MeshVertexReader")
struct MeshVertexReaderTests {
    @Test("Precondition: the direct-mesh body has empty vertexData (what broke #264)")
    func directBodyHasNoVertexData() {
        let (interleaved, direct, _) = boxPair()
        #expect(!interleaved.usesDirectMesh)
        #expect(!interleaved.vertexData.isEmpty)
        #expect(direct.usesDirectMesh)
        #expect(direct.vertexData.isEmpty)
    }

    @Test("Direct and interleaved read the same positions and normals")
    func samePositionsAndNormals() throws {
        let (interleaved, direct, _) = boxPair()
        let a = try #require(MeshVertexReader(interleaved))
        let b = try #require(MeshVertexReader(direct))
        let count = interleaved.vertexData.count / 6
        #expect(count == 24)
        for i in 0..<count {
            let va = try #require(a.vertex(at: i))
            let vb = try #require(b.vertex(at: i))
            #expect(va.position == vb.position)
            #expect(va.normal == vb.normal)
            #expect(a.position(at: i) == va.position)
            #expect(b.position(at: i) == vb.position)
        }
        // Out of range, either side
        #expect(a.vertex(at: count) == nil)
        #expect(b.vertex(at: count) == nil)
        #expect(a.position(at: -1) == nil)
        #expect(b.position(at: -1) == nil)
    }

    @Test("No mesh means no reader; a half-populated direct body falls back to vertexData")
    func noMesh() {
        let empty = ViewportBody(id: "e", vertexData: [], indices: [], edges: [], color: .one)
        #expect(MeshVertexReader(empty) == nil)
        var (_, direct, _) = boxPair()
        direct.meshNormals = Array(direct.meshNormals.dropLast(3))
        #expect(!direct.usesDirectMesh)
        #expect(MeshVertexReader(direct) == nil)  // empty vertexData, same as the renderer
    }

    @Test("faceHighlightMesh is identical for interleaved and direct-mesh bodies, and non-empty")
    func faceHighlightMatches() throws {
        let (interleaved, direct, faces) = boxPair()
        for face in Int32(0)..<6 {
            let a = try #require(
                MeshVertexReader.faceHighlightMesh(of: interleaved, faceIndices: faces, face: face))
            let b = try #require(
                MeshVertexReader.faceHighlightMesh(of: direct, faceIndices: faces, face: face))
            #expect(a.vertexData == b.vertexData)
            #expect(a.indices == b.indices)
            #expect(a.indices == [0, 1, 2, 3, 4, 5])  // two triangles, six overlay vertices
            #expect(a.vertexData.count == 6 * 6)
            // Each overlay vertex sits 0.002 above the surface along its (unit) normal.
            for v in stride(from: 0, to: a.vertexData.count, by: 6) {
                let p = SIMD3(a.vertexData[v], a.vertexData[v + 1], a.vertexData[v + 2])
                let n = SIMD3(a.vertexData[v + 3], a.vertexData[v + 4], a.vertexData[v + 5])
                #expect(abs(simd_length(n) - 1) < 1e-4)
                // half extents are 1, 2, 1.5 about the origin: |p . n| = half-extent + 0.002
                let h = abs(simd_dot(p, n))
                #expect([1.002, 1.502, 2.002].contains { abs($0 - h) < 1e-4 })
            }
        }
        // A face no triangle belongs to has no highlight.
        #expect(MeshVertexReader.faceHighlightMesh(of: direct, faceIndices: faces, face: 99) == nil)
    }

    @Test("A triangle with a corner out of range is skipped whole")
    func skipsBrokenTriangles() throws {
        var (_, direct, faces) = boxPair()
        var idx = direct.indices
        idx[3] = 9999  // break triangle 1 (face 0)
        direct.indices = idx
        let mesh = try #require(
            MeshVertexReader.faceHighlightMesh(of: direct, faceIndices: faces, face: 0))
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.vertexData.count == 3 * 6)
        // Face 1 is untouched.
        let other = try #require(
            MeshVertexReader.faceHighlightMesh(of: direct, faceIndices: faces, face: 1))
        #expect(other.indices == [0, 1, 2, 3, 4, 5])
    }
}

@Suite("GeometryUtils.hitPointOnTriangle")
struct HitPointTests {
    @Test("Same hit point on interleaved and direct-mesh bodies; nil when out of range")
    func hitPointMatches() throws {
        let (interleaved, direct, _) = boxPair()
        // width 2 (x), depth 4 (y), height 3 (z, up): faces at z = +-1.5. Shoot straight down.
        let ray = Ray(origin: SIMD3(0.2, 0.1, 10), direction: SIMD3(0, 0, -1))
        var found = 0
        for t in 0..<(interleaved.indices.count / 3) {
            let a = GeometryUtils.hitPointOnTriangle(ray: ray, body: interleaved, triangleIndex: t)
            let b = GeometryUtils.hitPointOnTriangle(ray: ray, body: direct, triangleIndex: t)
            #expect(a == b)
            if let b {
                found += 1
                #expect(abs(abs(b.z) - 1.5) < 1e-4)
                #expect(abs(b.x - 0.2) < 1e-4 && abs(b.y - 0.1) < 1e-4)
            }
        }
        #expect(found == 2)  // the top and bottom faces
        let count = interleaved.indices.count / 3
        #expect(
            GeometryUtils.hitPointOnTriangle(ray: ray, body: direct, triangleIndex: count) == nil)
        #expect(GeometryUtils.hitPointOnTriangle(ray: ray, body: direct, triangleIndex: -1) == nil)
    }
}
