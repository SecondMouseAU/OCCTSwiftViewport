// BoundingBoxTests.swift
// OCCTSwiftViewport Tests

import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("BoundingBox Tests")
struct BoundingBoxTests {

    @Test("Construction from min/max")
    func testConstruction() {
        let bb = BoundingBox(
            min: SIMD3<Float>(-1, -2, -3),
            max: SIMD3<Float>(1, 2, 3)
        )

        #expect(bb.center == SIMD3<Float>(0, 0, 0))
        #expect(bb.size == SIMD3<Float>(2, 4, 6))
        #expect(abs(bb.diagonalLength - simd_length(SIMD3<Float>(2, 4, 6))) < 0.001)
    }

    @Test("ViewportBody.box() has correct bounding box")
    func testBoxBoundingBox() {
        let body = ViewportBody.box(id: "cube")
        let bb = body.boundingBox

        #expect(bb != nil)
        if let bb = bb {
            // Default box is 1x1x1 centered at origin
            #expect(abs(bb.min.x - (-0.5)) < 0.001)
            #expect(abs(bb.min.y - (-0.5)) < 0.001)
            #expect(abs(bb.min.z - (-0.5)) < 0.001)
            #expect(abs(bb.max.x - 0.5) < 0.001)
            #expect(abs(bb.max.y - 0.5) < 0.001)
            #expect(abs(bb.max.z - 0.5) < 0.001)
        }
    }

    @Test("Union of two disjoint boxes")
    func testUnion() {
        let a = BoundingBox(
            min: SIMD3<Float>(0, 0, 0),
            max: SIMD3<Float>(1, 1, 1)
        )
        let b = BoundingBox(
            min: SIMD3<Float>(2, 2, 2),
            max: SIMD3<Float>(3, 3, 3)
        )

        let u = a.union(b)
        #expect(u.min == SIMD3<Float>(0, 0, 0))
        #expect(u.max == SIMD3<Float>(3, 3, 3))
    }

    @Test("Empty vertex data returns nil bounding box")
    func testEmptyVertexData() {
        let body = ViewportBody(
            id: "empty",
            vertexData: [],
            indices: [],
            edges: [],
            color: SIMD4<Float>(1, 1, 1, 1)
        )

        #expect(body.boundingBox == nil)
    }

    // MARK: - Edges count toward ViewportBody.boundingBox, issue #135

    @Test("An edge-only body has bounds spanning its polylines")
    func edgeOnlyBodyHasBounds() {
        let body = ViewportBody(
            id: "wire", vertexData: [], indices: [],
            edges: [[SIMD3(-4, 0, 1), SIMD3(4, 0, 1)], [SIMD3(0, -2, 0), SIMD3(0, 3, 0)]],
            color: SIMD4<Float>(1, 1, 1, 1))
        let bb = body.boundingBox
        #expect(bb?.min == SIMD3<Float>(-4, -2, 0))
        #expect(bb?.max == SIMD3<Float>(4, 3, 1))
    }

    @Test("Edges outside the mesh extend a meshed body's bounds")
    func edgesExtendMeshBounds() {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        let body = ViewportBody(
            id: "meshed", vertexData: v(-1, -1) + v(1, -1) + v(1, 1), indices: [0, 1, 2],
            edges: [[SIMD3(0, 0, 0), SIMD3(0, 0, 5)]], color: SIMD4<Float>(1, 1, 1, 1))
        let bb = body.boundingBox
        #expect(bb?.min == SIMD3<Float>(-1, -1, 0))
        #expect(bb?.max == SIMD3<Float>(1, 1, 5))
    }

    @Test("A direct-mesh body's bounds still come from its positions")
    func directMeshBounds() {
        let body = ViewportBody.directMesh(
            id: "direct", positions: [0, 0, 0, 2, 0, 0, 0, 3, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2], color: SIMD4<Float>(1, 1, 1, 1))
        #expect(body.boundingBox?.max == SIMD3<Float>(2, 3, 0))
    }

    @Test("The near clip plane is fitted to an edge in front of the mesh")
    func nearPlaneCoversEdgeInFrontOfMesh() {
        // Camera at +Z, distance 10. Mesh at z = 0, an edge at z = 1 (camera distance 9).
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        let body = ViewportBody(
            id: "meshed", vertexData: v(-1, 3) + v(1, 3) + v(1, 4), indices: [0, 1, 2],
            edges: [[SIMD3(-4, 0, 1), SIMD3(4, 0, 1)]], color: SIMD4<Float>(1, 1, 1, 1))
        let camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)
        let near = camera.clipPlanes(sceneBounds: body.boundingBox).near
        #expect(near <= 9, "near \(near) would clip the edge at distance 9")
    }

    // MARK: - distance(to:), issue #116

    @Test("A point inside the box is zero distance away")
    func distanceInsideIsZero() {
        let bb = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))

        #expect(bb.distance(to: .zero) == 0)
        #expect(bb.distance(to: SIMD3<Float>(0.9, -0.9, 0.5)) == 0)
    }

    @Test("A point on the boundary is zero distance away")
    func distanceOnSurfaceIsZero() {
        let bb = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))

        #expect(bb.distance(to: SIMD3<Float>(1, 0, 0)) == 0)
        #expect(bb.distance(to: SIMD3<Float>(-1, -1, -1)) == 0)
    }

    @Test("A point off one face measures along that axis only")
    func distanceOffOneFace() {
        let bb = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))

        #expect(abs(bb.distance(to: SIMD3<Float>(4, 0, 0)) - 3) < 1e-5)
        #expect(abs(bb.distance(to: SIMD3<Float>(0, -6, 0)) - 5) < 1e-5)
    }

    @Test("A point off a corner measures the diagonal, not an axis")
    func distanceOffCorner() {
        let bb = BoundingBox(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))

        // (4, 5, 1) is 3 past +x, 4 past +y, inside on z → 3-4-5 triangle.
        #expect(abs(bb.distance(to: SIMD3<Float>(4, 5, 1)) - 5) < 1e-5)
    }

    @Test("Distance is measured to the box, not to its bounding sphere")
    func distanceIsToBoxNotSphere() {
        // A flat slab: its circumscribed sphere is far larger than the slab itself.
        let slab = BoundingBox(min: SIMD3<Float>(-10, -10, -1), max: SIMD3<Float>(10, 10, 1))
        let camera = SIMD3<Float>(0, 0, 5)

        // Sphere approximation would call this negative (i.e. "inside"); the box says 4.
        let sphereRadius = slab.diagonalLength * 0.5
        #expect(simd_length(camera - slab.center) < sphereRadius)
        #expect(abs(slab.distance(to: camera) - 4) < 1e-5)
    }
}
