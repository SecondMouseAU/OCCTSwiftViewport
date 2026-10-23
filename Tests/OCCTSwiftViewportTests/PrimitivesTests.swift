// PrimitivesTests.swift
// OCCTSwiftViewport Tests
//
// Orientation of the primitive factories (issue #169): the default stays Y-up for source
// compatibility, and `up:` rotates the geometry onto the requested axis without changing its
// topology, winding or face IDs.

import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Primitive factory orientation")
struct PrimitivesTests {

    private static let tolerance: Float = 1e-4

    private func positions(_ body: ViewportBody) -> [SIMD3<Float>] {
        stride(from: 0, to: body.vertexData.count, by: 6).map {
            SIMD3<Float>(body.vertexData[$0], body.vertexData[$0 + 1], body.vertexData[$0 + 2])
        }
    }

    private func normals(_ body: ViewportBody) -> [SIMD3<Float>] {
        stride(from: 0, to: body.vertexData.count, by: 6).map {
            SIMD3<Float>(body.vertexData[$0 + 3], body.vertexData[$0 + 4], body.vertexData[$0 + 5])
        }
    }

    /// The signed volume the triangles enclose, by the divergence theorem.
    ///
    /// Positive when the triangles wind counter-clockwise seen from outside.
    private func signedVolume(_ body: ViewportBody) -> Float {
        let p = positions(body)
        var sum: Float = 0
        for t in stride(from: 0, to: body.indices.count, by: 3) {
            let a = p[Int(body.indices[t])]
            let b = p[Int(body.indices[t + 1])]
            let c = p[Int(body.indices[t + 2])]
            sum += simd_dot(a, simd_cross(b, c))
        }
        return sum / 6
    }

    private func expectClose(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(simd_length(a - b) < Self.tolerance, "\(a) != \(b)", sourceLocation: sourceLocation)
    }

    // MARK: - Defaults are unchanged

    @Test("Defaults stay Y-up: cylinder axis and box height run along Y")
    func defaultsAreYUp() throws {
        let cyl = try #require(ViewportBody.cylinder(id: "c", radius: 0.5, height: 3).boundingBox)
        expectClose(cyl.size, SIMD3<Float>(1, 3, 1))

        let box = try #require(
            ViewportBody.box(id: "b", width: 1, height: 2, depth: 3).boundingBox)
        expectClose(box.size, SIMD3<Float>(1, 2, 3))

        let sphere = ViewportBody.sphere(id: "s", radius: 1, segments: 8, rings: 4)
        // The first ring is the +Y pole.
        expectClose(positions(sphere)[0], SIMD3<Float>(0, 1, 0))
    }

    @Test("Passing up: .y is identical to the default")
    func explicitYMatchesDefault() {
        #expect(
            ViewportBody.cylinder(id: "c", segments: 12).vertexData
                == ViewportBody.cylinder(id: "c", segments: 12, up: .y).vertexData)
        #expect(
            ViewportBody.box(id: "b").vertexData == ViewportBody.box(id: "b", up: .y).vertexData)
        #expect(
            ViewportBody.sphere(id: "s", segments: 8, rings: 4).edges
                == ViewportBody.sphere(id: "s", segments: 8, rings: 4, up: .y).edges)
    }

    // MARK: - Z-up

    @Test("up: .z stands the cylinder on the XY plane")
    func cylinderZUp() throws {
        let body = ViewportBody.cylinder(id: "c", radius: 0.5, height: 3, segments: 16, up: .z)
        let bb = try #require(body.boundingBox)
        expectClose(bb.size, SIMD3<Float>(1, 1, 3))
        expectClose(bb.center, .zero)

        // The top cap (face 1) faces +Z; the bottom cap (face 2) faces -Z.
        let n = normals(body)
        let topCap = body.indices[16 * 6]  // first index after the side's 16 quads
        expectClose(n[Int(topCap)], SIMD3<Float>(0, 0, 1))
        #expect(body.faceIndices[16 * 2] == 1)

        // Every edge ring lies at z = ±height/2.
        for point in body.edges[0] { #expect(abs(point.z - 1.5) < Self.tolerance) }
        for point in body.edges[1] { #expect(abs(point.z + 1.5) < Self.tolerance) }
    }

    @Test("up: .z makes box height the Z extent and depth the Y extent")
    func boxZUp() throws {
        let body = ViewportBody.box(id: "b", width: 1, height: 2, depth: 3, up: .z)
        let bb = try #require(body.boundingBox)
        expectClose(bb.size, SIMD3<Float>(1, 3, 2))

        // Face 4 ("top") faces +Z, face 5 ("bottom") faces -Z; four vertices per face.
        let n = normals(body)
        expectClose(n[4 * 4], SIMD3<Float>(0, 0, 1))
        expectClose(n[5 * 4], SIMD3<Float>(0, 0, -1))
        // Face 0 ("front") faces -Y, the Z-up front view's direction toward the viewer.
        expectClose(n[0], SIMD3<Float>(0, -1, 0))
    }

    @Test("up: .z puts the sphere's poles on Z and its equator in the XY plane")
    func sphereZUp() {
        let body = ViewportBody.sphere(id: "s", radius: 2, segments: 8, rings: 4, up: .z)
        let p = positions(body)
        expectClose(p[0], SIMD3<Float>(0, 0, 2))
        expectClose(p[p.count - 1], SIMD3<Float>(0, 0, -2))
        for point in body.edges[0] { #expect(abs(point.z) < Self.tolerance) }
    }

    // MARK: - X-up

    @Test("up: .x lays the cylinder along X")
    func cylinderXUp() throws {
        let bb = try #require(
            ViewportBody.cylinder(id: "c", radius: 0.5, height: 3, up: .x).boundingBox)
        expectClose(bb.size, SIMD3<Float>(3, 1, 1))
    }

    // MARK: - Invariants under reorientation

    @Test(
        "Reorienting keeps topology, face IDs, unit normals and winding",
        arguments: PrimitiveUpAxis.allCases)
    func reorientationIsARotation(up: PrimitiveUpAxis) {
        let pairs: [(ViewportBody, ViewportBody)] = [
            (
                ViewportBody.box(id: "b", width: 1, height: 2, depth: 3),
                ViewportBody.box(id: "b", width: 1, height: 2, depth: 3, up: up)
            ),
            (
                ViewportBody.cylinder(id: "c", segments: 16),
                ViewportBody.cylinder(id: "c", segments: 16, up: up)
            ),
            (
                ViewportBody.sphere(id: "s", segments: 12, rings: 6),
                ViewportBody.sphere(id: "s", segments: 12, rings: 6, up: up)
            ),
        ]
        for (reference, oriented) in pairs {
            #expect(oriented.indices == reference.indices)
            #expect(oriented.faceIndices == reference.faceIndices)
            #expect(oriented.vertexData.count == reference.vertexData.count)
            #expect(oriented.edges.map(\.count) == reference.edges.map(\.count))
            for normal in normals(oriented) {
                #expect(abs(simd_length(normal) - 1) < Self.tolerance)
            }
            // A proper rotation leaves the signed volume (and so the winding) unchanged.
            #expect(abs(signedVolume(oriented) - signedVolume(reference)) < 1e-3)
        }
    }

    @Test("Every primitive winds counter-clockwise seen from outside")
    func outwardWinding() {
        #expect(signedVolume(ViewportBody.box(id: "b", width: 1, height: 2, depth: 3)) > 5.9)
        #expect(signedVolume(ViewportBody.cylinder(id: "c", segments: 32)) > 0)
        #expect(signedVolume(ViewportBody.sphere(id: "s", segments: 16, rings: 8)) > 0)
    }
}
