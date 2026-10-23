// PickEncodingLimitsTests.swift
// OCCTSwiftViewport Tests
//
// Limits of the 32-bit GPU pick ID (issue #136, H4/H7/L10). The pick value packs
// `objectIndex (16) | primitiveID (14) << 16 | kind (2) << 30`. These tests pin:
//   - the object-index guard: bodies past 0xFFFF read back as misses instead of corrupting the
//     primitive bits of another pick;
//   - primitive-index wrap detection (`isPrimitiveIndexAmbiguous`) and the CPU resolution of
//     wrapped face picks;
//   - headless: the tessellated (`.enhanced`) and mesh-shader (`.maximum`) pick paths report the
//     input triangle index, not the B-Rep face index or a meshlet-local index.

import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

/// Packs a pick value exactly as the pick fragment shaders do.
private func shaderEncode(objectIndex: UInt32, primitive: UInt32, kind: UInt32) -> UInt32 {
    objectIndex | ((primitive & 0x3FFF) << 16) | (kind << 30)
}

@Suite("Pick ID object-index guard")
struct PickObjectIndexGuardTests {

    @Test("Ordinals that fit the 16-bit field are used as-is")
    func inRangeOrdinals() {
        #expect(PickResult.pickObjectIndex(forOrdinal: 0) == 0)
        #expect(PickResult.pickObjectIndex(forOrdinal: 1234) == 1234)
        #expect(PickResult.pickObjectIndex(forOrdinal: 0xFFFF) == 0xFFFF)
        #expect(PickResult.maxPickableBodies == 65_536)
    }

    @Test("Ordinals past 0xFFFF become the sentinel")
    func outOfRangeOrdinals() {
        #expect(PickResult.pickObjectIndex(forOrdinal: 0x1_0000) == PickResult.sentinel)
        #expect(PickResult.pickObjectIndex(forOrdinal: 70_000) == PickResult.sentinel)
        #expect(PickResult.pickObjectIndex(forOrdinal: .max) == PickResult.sentinel)
    }

    @Test("BodyUniforms applies the guard, so the pick shaders never see an overflowing index")
    func bodyUniformsApplyGuard() {
        let body = ViewportBody.box(id: "b")
        #expect(BodyUniforms(body: body, objectIndex: 42).objectIndex == 42)
        #expect(BodyUniforms(body: body, objectIndex: 0x1_0001).objectIndex == PickResult.sentinel)
    }

    @Test("An overflowed body reads back as a miss, not as another body's primitive")
    func overflowedBodyDecodesAsMiss() {
        // Body 65,537 (ordinal 0x10001) and body 1 both exist in a 70k-body scene.
        let indexMap = [1: "body-1"]
        // Unguarded, ordinal 0x10001 bleeds bit 16 into the primitive field and decodes as body 1.
        let unguarded = shaderEncode(objectIndex: 0x1_0001, primitive: 4, kind: 0)
        #expect(PickResult(rawValue: unguarded, indexMap: indexMap)?.bodyID == "body-1")

        // Guarded, every kind and primitive collapses to the sentinel: no hit.
        let guarded = PickResult.pickObjectIndex(forOrdinal: 0x1_0001)
        for kind: UInt32 in 0...2 {
            let raw = shaderEncode(objectIndex: guarded, primitive: 4, kind: kind)
            #expect(raw == PickResult.sentinel)
            #expect(PickResult(rawValue: raw, indexMap: indexMap) == nil)
        }
    }
}

@Suite("Pick ID primitive-index wrap detection")
struct PickPrimitiveWrapTests {

    @Test("A kind is ambiguous only above 16,384 primitives")
    func ambiguousKindThresholds() {
        #expect(PickResult.maxPrimitivesPerKind == 16_384)
        #expect(
            PickResult.ambiguousKinds(
                triangleCount: 16_384, edgeSegmentCount: 16_384, pointCount: 16_384
            )
            .isEmpty)
        #expect(
            PickResult.ambiguousKinds(triangleCount: 16_385, edgeSegmentCount: 0, pointCount: 0)
                == [.face])
        #expect(
            PickResult.ambiguousKinds(triangleCount: 0, edgeSegmentCount: 20_000, pointCount: 0)
                == [.edge])
        #expect(
            PickResult.ambiguousKinds(triangleCount: 0, edgeSegmentCount: 0, pointCount: 99_999)
                == [.vertex])
    }

    @Test("Decode flags only picks of an ambiguous kind on an ambiguous body")
    func decodeFlagsAmbiguity() {
        let indexMap = [0: "big", 1: "small"]
        let ambiguous: [String: Set<PrimitiveKind>] = ["big": [.face]]

        let bigFace = PickResult(
            rawValue: shaderEncode(objectIndex: 0, primitive: 5, kind: 0),
            indexMap: indexMap, ambiguousKinds: ambiguous)
        #expect(bigFace?.isPrimitiveIndexAmbiguous == true)
        #expect(bigFace?.triangleIndex == 5)

        let bigEdge = PickResult(
            rawValue: shaderEncode(objectIndex: 0, primitive: 5, kind: 1),
            indexMap: indexMap, ambiguousKinds: ambiguous)
        #expect(bigEdge?.isPrimitiveIndexAmbiguous == false)

        let smallFace = PickResult(
            rawValue: shaderEncode(objectIndex: 1, primitive: 5, kind: 0),
            indexMap: indexMap, ambiguousKinds: ambiguous)
        #expect(smallFace?.isPrimitiveIndexAmbiguous == false)

        // Without the map (the historical call shape) nothing is flagged.
        let plain = PickResult(
            rawValue: shaderEncode(objectIndex: 0, primitive: 5, kind: 0), indexMap: indexMap)
        #expect(plain?.isPrimitiveIndexAmbiguous == false)
    }

    @Test("Region and neighborhood decoders forward the ambiguity map")
    func batchDecodersForwardMap() {
        let indexMap = [0: "big"]
        let ambiguous: [String: Set<PrimitiveKind>] = ["big": [.face]]
        let raw = shaderEncode(objectIndex: 0, primitive: 9, kind: 0)

        let region = ViewportRenderer.decodeRegionPickResults(
            [raw], indexMap: indexMap, layerMap: [:], ambiguousKinds: ambiguous)
        #expect(region.first?.isPrimitiveIndexAmbiguous == true)

        let best = ViewportRenderer.bestNeighborhoodPickResult(
            [raw], width: 1, center: SIMD2(0, 0), indexMap: indexMap, layerMap: [:],
            ambiguousKinds: ambiguous)
        #expect(best?.isPrimitiveIndexAmbiguous == true)
    }
}

/// A body with `triangleCount` triangles, all tiny and off to the side, except the triangles
/// listed in `facing`, which are 2x2 quads' halves centred on the Z axis at the given depth.
private func bodyWithTriangles(
    _ triangleCount: Int, facing: [Int: Float], interleaved: Bool = true
) -> ViewportBody {
    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(triangleCount * 3)
    for t in 0..<triangleCount {
        if let z = facing[t] {
            positions += [SIMD3(-1, -1, z), SIMD3(1, -1, z), SIMD3(0, 1, z)]
        } else {
            let x = 100 + Float(t % 100)
            positions += [SIMD3(x, 0, 0), SIMD3(x + 0.1, 0, 0), SIMD3(x, 0.1, 0)]
        }
    }
    let indices = (0..<UInt32(positions.count)).map { $0 }
    if interleaved {
        var vertexData: [Float] = []
        vertexData.reserveCapacity(positions.count * 6)
        for p in positions { vertexData += [p.x, p.y, p.z, 0, 0, 1] }
        return ViewportBody(
            id: "big", vertexData: vertexData, indices: indices, edges: [],
            color: SIMD4<Float>(1, 1, 1, 1))
    }
    let flat: [Float] = positions.flatMap { [$0.x, $0.y, $0.z] }
    let normals: [Float] = positions.flatMap { _ in [Float(0), 0, 1] }
    return ViewportBody.directMesh(
        id: "big", positions: flat, normals: normals, indices: indices,
        color: SIMD4<Float>(1, 1, 1, 1))
}

@Suite("Wrapped face-pick resolution")
struct WrappedFacePickResolutionTests {

    let ray = Ray(origin: SIMD3(0, 0, 10), direction: SIMD3(0, 0, -1))

    @Test("The nearest congruent triangle under the ray wins")
    func resolvesNearestCandidate() {
        // Triangle 5 and triangle 16,389 are congruent mod 16,384; 16,389 is nearer the camera.
        let body = bodyWithTriangles(20_000, facing: [5: -10, 16_389: -5])
        #expect(body.resolveWrappedTriangleIndex(5, ray: ray) == 16_389)

        // Only triangle 5 is under the ray: it resolves to itself.
        let lone = bodyWithTriangles(20_000, facing: [5: -10])
        #expect(lone.resolveWrappedTriangleIndex(5, ray: ray) == 5)
    }

    @Test("No candidate under the ray, or an out-of-range index, resolves to nil")
    func unresolvable() {
        let body = bodyWithTriangles(20_000, facing: [5: -10])
        #expect(body.resolveWrappedTriangleIndex(6, ray: ray) == nil)
        #expect(body.resolveWrappedTriangleIndex(-1, ray: ray) == nil)
        #expect(body.resolveWrappedTriangleIndex(16_384, ray: ray) == nil)
    }

    @Test(
        "Direct-mesh bodies resolve too (worldHitPoint reads `vertices` when vertexData is empty)")
    func directMeshBody() {
        let body = bodyWithTriangles(20_000, facing: [3: -10, 16_387: -2], interleaved: false)
        #expect(body.usesDirectMesh)
        #expect(body.worldHitPoint(ray: ray, triangleIndex: 3) != nil)
        #expect(body.resolveWrappedTriangleIndex(3, ray: ray) == 16_387)
    }

    @Test("The controller replaces an ambiguous face pick with the exact triangle")
    func controllerResolution() {
        let body = bodyWithTriangles(20_000, facing: [5: -10, 16_389: -5])
        let ambiguous = PickResult(
            rawValue: shaderEncode(objectIndex: 0, primitive: 5, kind: 0),
            indexMap: [0: "big"], ambiguousKinds: ["big": [.face]])
        let pick = try? #require(ambiguous)
        guard let pick else { return }

        let resolved = ViewportController.resolveAmbiguousFacePick(pick, ray: ray, bodies: [body])
        #expect(resolved.triangleIndex == 16_389)
        #expect(resolved.isPrimitiveIndexAmbiguous == false)
        #expect(resolved.bodyID == "big")
        #expect(resolved.kind == .face)

        // A miss leaves the result flagged rather than guessing.
        let off = Ray(origin: SIMD3(50, 50, 10), direction: SIMD3(0, 0, -1))
        let unresolved = ViewportController.resolveAmbiguousFacePick(pick, ray: off, bodies: [body])
        #expect(unresolved.isPrimitiveIndexAmbiguous)
        #expect(unresolved.triangleIndex == 5)
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
