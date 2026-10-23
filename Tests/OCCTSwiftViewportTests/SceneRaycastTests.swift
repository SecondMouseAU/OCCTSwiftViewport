// SceneRaycastTests.swift
// OCCTSwiftViewport Tests

import Testing
import simd
@testable import OCCTSwiftViewport

@Suite("SceneRaycast Tests")
struct SceneRaycastTests {

    @Test("Hit on a unit box body at known distance")
    func testHitBox() {
        let body = ViewportBody.box(id: "cube")
        let bb = body.boundingBox!
        let cache: [String: BoundingBox] = ["cube": bb]

        // Ray from z = -5 toward origin, should hit front face at z = 0.5
        let ray = Ray(
            origin: SIMD3<Float>(0, 0, -5),
            direction: SIMD3<Float>(0, 0, 1)
        )

        let hit = SceneRaycast.cast(ray: ray, bodies: [body], boundingBoxCache: cache)
        #expect(hit != nil)
        if let hit = hit {
            #expect(hit.bodyID == "cube")
            // Front face of default box is at z = 0.5
            #expect(abs(hit.point.z - (-0.5)) < 0.01)
            #expect(abs(hit.distance - 4.5) < 0.01)
        }
    }

    @Test("Miss returns nil")
    func testMiss() {
        let body = ViewportBody.box(id: "cube")
        let bb = body.boundingBox!
        let cache: [String: BoundingBox] = ["cube": bb]

        // Ray pointing away
        let ray = Ray(
            origin: SIMD3<Float>(10, 10, 10),
            direction: SIMD3<Float>(1, 1, 1)
        )

        let hit = SceneRaycast.cast(ray: ray, bodies: [body], boundingBoxCache: cache)
        #expect(hit == nil)
    }

    @Test("Multiple bodies: returns nearest")
    func testNearest() {
        let near = ViewportBody.box(id: "near")
        let far = ViewportBody(
            id: "far",
            vertexData: shiftedBoxVertexData(z: 5),
            indices: near.indices,
            edges: [],
            color: SIMD4<Float>(1, 0, 0, 1)
        )

        var cache: [String: BoundingBox] = [:]
        cache["near"] = near.boundingBox!
        cache["far"] = far.boundingBox!

        let ray = Ray(
            origin: SIMD3<Float>(0, 0, -10),
            direction: SIMD3<Float>(0, 0, 1)
        )

        let hit = SceneRaycast.cast(ray: ray, bodies: [near, far], boundingBoxCache: cache)
        #expect(hit != nil)
        #expect(hit?.bodyID == "near")
    }

    @Test("Translated body is hit where it is drawn, not at its local position")
    func testTranslatedBody() {
        var body = ViewportBody.box(id: "cube")
        body.transform = simd_float4x4(
            columns: (
                SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(3, 0, 0, 1)
            ))
        let cache: [String: BoundingBox] = ["cube": body.boundingBox!]

        // Through the local position: must miss now.
        let throughOrigin = Ray(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        #expect(
            SceneRaycast.cast(ray: throughOrigin, bodies: [body], boundingBoxCache: cache) == nil)

        // Through the world position: hits the front face at z = -0.5.
        let throughBody = Ray(origin: SIMD3<Float>(3, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        let hit = SceneRaycast.cast(ray: throughBody, bodies: [body], boundingBoxCache: cache)
        #expect(hit?.bodyID == "cube")
        #expect(abs((hit?.point.x ?? 0) - 3) < 0.01)
        #expect(abs((hit?.point.z ?? 0) - (-0.5)) < 0.01)
        #expect(abs((hit?.distance ?? 0) - 4.5) < 0.01)
    }

    @Test("Scaled and rotated body returns world-space point and distance")
    func testScaledRotatedBody() {
        var body = ViewportBody.box(id: "cube")
        let rotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
        let scale = simd_float4x4(diagonal: SIMD4<Float>(2, 2, 2, 1))
        body.transform = rotation * scale
        let cache: [String: BoundingBox] = ["cube": body.boundingBox!]

        // Scaled ×2, the front face sits at z = -1 in world space.
        let ray = Ray(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        let hit = SceneRaycast.cast(ray: ray, bodies: [body], boundingBoxCache: cache)
        #expect(hit?.bodyID == "cube")
        #expect(abs((hit?.point.z ?? 0) - (-1)) < 0.01)
        #expect(abs((hit?.distance ?? 0) - 4) < 0.01)
    }

    @Test("Nearest-body ordering uses world distances across transforms")
    func testNearestAcrossTransforms() {
        // "far" is local-near but moved back; "near" is local-far but moved forward.
        var far = ViewportBody.box(id: "far")
        far.transform = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        far.transform.columns.3 = SIMD4<Float>(0, 0, 4, 1)
        var near = ViewportBody.box(id: "near")
        near.transform = simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        near.transform.columns.3 = SIMD4<Float>(0, 0, -2, 1)
        let cache: [String: BoundingBox] = [
            "far": far.boundingBox!, "near": near.boundingBox!,
        ]
        let ray = Ray(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        let hit = SceneRaycast.cast(ray: ray, bodies: [far, near], boundingBoxCache: cache)
        #expect(hit?.bodyID == "near")
        #expect(abs((hit?.distance ?? 0) - 2.5) < 0.01)
    }

    @Test("Bodies with a singular transform are skipped")
    func testSingularTransform() {
        var body = ViewportBody.box(id: "cube")
        body.transform = simd_float4x4(diagonal: SIMD4<Float>(0, 1, 1, 1))
        let cache: [String: BoundingBox] = ["cube": body.boundingBox!]
        let ray = Ray(origin: SIMD3<Float>(0, 0, -5), direction: SIMD3<Float>(0, 0, 1))
        #expect(SceneRaycast.cast(ray: ray, bodies: [body], boundingBoxCache: cache) == nil)
    }

    @Test("Invisible bodies are skipped")
    func testInvisibleSkipped() {
        var body = ViewportBody.box(id: "hidden")
        body.isVisible = false
        let cache: [String: BoundingBox] = ["hidden": body.boundingBox!]

        let ray = Ray(
            origin: SIMD3<Float>(0, 0, -5),
            direction: SIMD3<Float>(0, 0, 1)
        )

        let hit = SceneRaycast.cast(ray: ray, bodies: [body], boundingBoxCache: cache)
        #expect(hit == nil)
    }

    // MARK: - Helpers

    /// Creates vertex data for a unit box shifted along Z.
    private func shiftedBoxVertexData(z: Float) -> [Float] {
        let source = ViewportBody.box(id: "tmp")
        var data = source.vertexData
        let stride = 6
        let vertexCount = data.count / stride
        for i in 0..<vertexCount {
            data[i * stride + 2] += z  // shift position Z
        }
        return data
    }
}
