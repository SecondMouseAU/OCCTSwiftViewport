// BodyTransformUpdateTests.swift
// OCCTSwiftViewport Tests
//
// Issue #141: moving a body every frame by changing `ViewportBody.transform` (and re-assigning the
// bodies array the view reads) must cost a uniform update, not a re-upload.
//
// What the library documents, and what these tests pin:
//
// - `transform` is placement, not geometry. `ViewportBody.generation` says a `transform` change
//   leaves the generation unchanged (ViewportBody.swift), and a body's `boundsKey` is its
//   generation plus any in-place content version, so it does not move either.
// - Every cache of bounds therefore holds the body's *local* box and applies `transform` at use
//   (`PivotStrategy.bbCache`), so the world bounds still follow the body.
// - GPU buffers are keyed by `id` and `generation` (`ViewportRenderer.ensureBuffers`), so a
//   transform change takes the "geometry still valid" early return and builds nothing.
//
// The renderer exposes the identity of each body's cached buffers to tests: the mesh buffers
// through `cachedMeshBuffers(for:)` (added for #141) and the edge buffers through
// `cachedEdgeBuffers(for:)` (#140). `ensureBuffers` builds them in one `BodyBuffers` value and
// replaces it whole. Every body below has edges, and the control test proves both kinds of buffer
// do change when the mesh does, so the checks can fail.
//
// The live tests drive the renderer's own `encodeFrame` headlessly, as `draw(in:)` does.

import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
private final class TransformBodyStore {
    var bodies: [ViewportBody]
    init(_ bodies: [ViewportBody]) { self.bodies = bodies }
    var binding: Binding<[ViewportBody]> {
        Binding(get: { self.bodies }, set: { self.bodies = $0 })
    }
}

/// A renderer holds its controller weakly and draws nothing once it is gone, so the controllers
/// the tests make live as long as the test process.
@MainActor
private var retainedTransformControllers: [ViewportController] = []

/// The identity of each buffer a body has cached, `nil` for one it has none of.
private struct BufferIdentities: Equatable {
    var vertex: ObjectIdentifier?
    var index: ObjectIdentifier?
    var native: ObjectIdentifier?
    var quad: ObjectIdentifier?
    var colors: ObjectIdentifier?
}

private struct RenderUnavailable: Error {}

@MainActor
private enum TransformScene {
    static let size = 96

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    /// One moving red sphere plus `staticCount` blue boxes on a grid above it.
    static func bodies(staticCount: Int) -> [ViewportBody] {
        var out = [
            ViewportBody.sphere(
                id: "mover", radius: 0.5, segments: 24, rings: 12,
                color: SIMD4(1, 0.1, 0.1, 1), up: .z)
        ]
        for i in 0..<staticCount {
            var box = ViewportBody.box(
                id: "static-\(i)", width: 0.4, height: 0.4, depth: 0.4,
                color: SIMD4(0.2, 0.5, 0.9, 1), up: .z)
            box.transform = translation(
                SIMD3(Float(i % 10) * 0.6 - 2.7, 2 + Float(i / 10) * 0.6, 0))
            out.append(box)
        }
        return out
    }

    static func make(_ store: TransformBodyStore) throws -> ViewportRenderer {
        var config = ViewportConfiguration()
        config.initialCameraState = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)), distance: 10, pivot: .zero)
        config.backgroundColor = SIMD4(0, 0, 0, 1)
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shadedWithEdges
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: store.binding)
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        retainedTransformControllers.append(controller)
        return renderer
    }

    static func render(_ renderer: ViewportRenderer) throws -> [UInt8] {
        guard
            let pixels = renderer.renderHeadlessBGRA(
                width: size, height: size, backgroundColor: SIMD4(0, 0, 0, 1))
        else {
            Issue.record("headless render returned nil")
            throw RenderUnavailable()
        }
        return pixels
    }

    /// Mean column of the strongly red pixels (the mover), or `nil` when there are none.
    static func redCentroidX(_ bgra: [UInt8]) -> Double? {
        var sum = 0.0
        var count = 0.0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let b = Int(bgra[i])
                let g = Int(bgra[i + 1])
                let r = Int(bgra[i + 2])
                if r > 60, r > 2 * max(g, b) {
                    sum += Double(x)
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count : nil
    }
}

@MainActor
@Suite("Body transform updates re-create no buffer (#141)")
struct BodyTransformUpdateTests {

    private func edgeBuffers(
        _ renderer: ViewportRenderer, _ bodies: [ViewportBody]
    ) -> [String: BufferIdentities] {
        var out: [String: BufferIdentities] = [:]
        for body in bodies {
            guard let edges = renderer.cachedEdgeBuffers(for: body.id),
                let mesh = renderer.cachedMeshBuffers(for: body.id)
            else { continue }
            out[body.id] = BufferIdentities(
                vertex: mesh.vertex.map { ObjectIdentifier($0) },
                index: mesh.index.map { ObjectIdentifier($0) },
                native: edges.native.map { ObjectIdentifier($0) },
                quad: edges.quad.map { ObjectIdentifier($0) },
                colors: edges.colors.map { ObjectIdentifier($0) })
        }
        return out
    }

    // MARK: Value semantics: no GPU needed

    @Test("A transform change keeps generation and boundsKey; the world bounds still move")
    func transformKeepsGenerationAndBoundsKey() throws {
        var body = ViewportBody.box(id: "box", width: 2, height: 2, depth: 2, up: .z)
        let generation = body.generation
        let key = body.boundsKey
        let local = try #require(body.boundingBox)

        let strategy = PivotStrategy()
        let before = try #require(strategy.sceneBounds(of: [body]))
        #expect(before == local, "an identity transform leaves the world box at the local one")

        for step in 1...60 {
            body.transform = TransformScene.translation(SIMD3(Float(step) * 0.5, 0, 0))
        }
        #expect(body.generation == generation, "a transform change took a new generation")
        #expect(body.boundsKey == key, "a transform change changed the bounds key")
        #expect(body.boundingBox == local, "the body's own bounds are local, not world")

        // The bounds cache is keyed on boundsKey, so it still holds the local box, and the
        // transform is applied at use: the world box has to follow the body regardless.
        let after = try #require(strategy.sceneBounds(of: [body]))
        #expect(after.min.x == local.min.x + 30)
        #expect(after.max.x == local.max.x + 30)
        #expect(after.min.y == local.min.y && after.max.y == local.max.y)
        #expect(strategy.boundingBoxCache["box"] == local, "the cache holds a world box")
    }

    @Test("Copies share a generation until geometry changes, whatever their transform")
    func copiesShareGenerationAcrossTransforms() {
        let a = ViewportBody.sphere(id: "s", up: .z)
        var b = a
        b.transform = TransformScene.translation(SIMD3(5, 0, 0))
        #expect(b.generation == a.generation)
        #expect(b.boundsKey == a.boundsKey)

        b.vertexData[0] += 0.01
        #expect(b.generation != a.generation, "a geometry edit must take a new generation")
        #expect(b.boundsKey != a.boundsKey, "a geometry edit must change the bounds key")
    }

    // MARK: Live renderer

    @Test("Mutating transform 60 times keeps generation and every cached buffer")
    func transformKeepsBuffers() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 20))
        let renderer = try TransformScene.make(store)
        let first = try TransformScene.render(renderer)
        let generations = store.bodies.map(\.generation)
        let identities = edgeBuffers(renderer, store.bodies)
        #expect(identities.count == 21, "every body should have cached buffers")
        #expect(
            identities.values.allSatisfy {
                $0.vertex != nil && $0.index != nil && $0.native != nil && $0.quad != nil
            },
            "the check needs every body to have mesh and edge buffers")

        var last = first
        for step in 1...60 {
            // The body moves; the array is mutated in place and so re-assigned through the binding.
            store.bodies[0].transform = TransformScene.translation(SIMD3(Float(step) * 0.04, 0, 0))
            last = try TransformScene.render(renderer)
        }

        #expect(store.bodies.map(\.generation) == generations, "a transform changed a generation")
        #expect(edgeBuffers(renderer, store.bodies) == identities, "a cached buffer was replaced")
        let startX = try #require(TransformScene.redCentroidX(first), "the mover is not drawn")
        let endX = try #require(TransformScene.redCentroidX(last), "the mover left the frame")
        #expect(abs(endX - startX) > 15, "the body did not move: \(startX) -> \(endX)")
    }

    @Test("Re-assigning the whole bodies array each frame re-creates nothing")
    func arrayReassignmentKeepsBuffers() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 99))
        let renderer = try TransformScene.make(store)
        _ = try TransformScene.render(renderer)
        let identities = edgeBuffers(renderer, store.bodies)
        let generations = store.bodies.map(\.generation)
        #expect(identities.count == 100)
        #expect(
            identities.values.allSatisfy {
                $0.vertex != nil && $0.index != nil && $0.native != nil && $0.quad != nil
            })

        for step in 1...30 {
            var next = store.bodies.map { $0 }
            next[0].transform = TransformScene.translation(SIMD3(Float(step) * 0.04, 0, 0))
            store.bodies = next
            _ = try TransformScene.render(renderer)
        }
        #expect(store.bodies.map(\.generation) == generations)
        #expect(edgeBuffers(renderer, store.bodies) == identities)
    }

    @Test("Control: a geometry change takes a new generation and rebuilds that body alone")
    func geometryChangeDoesRebuild() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 3))
        let renderer = try TransformScene.make(store)
        _ = try TransformScene.render(renderer)
        let identities = edgeBuffers(renderer, store.bodies)
        let generation = store.bodies[0].generation
        let key = store.bodies[0].boundsKey

        // Nudge one vertex position only: the edges are not touched, yet the whole cached entry
        // (the mesh buffers and the edge buffers sharing it) must be rebuilt.
        var changed = store.bodies[0].vertexData
        changed[0] += 0.01
        store.bodies[0].vertexData = changed
        _ = try TransformScene.render(renderer)

        #expect(store.bodies[0].generation != generation)
        #expect(store.bodies[0].boundsKey != key)
        let after = edgeBuffers(renderer, store.bodies)
        let mover = try #require(after["mover"])
        let moverBefore = try #require(identities["mover"])
        #expect(mover.vertex != moverBefore.vertex, "the changed body kept its old vertex buffer")
        #expect(mover.index != moverBefore.index, "the changed body kept its old index buffer")
        #expect(mover.native != moverBefore.native, "the changed body kept its old buffers")
        #expect(mover.quad != moverBefore.quad, "the changed body kept its old buffers")
        #expect(after["static-0"] == identities["static-0"], "an untouched body was rebuilt")
        #expect(after["static-1"] == identities["static-1"], "an untouched body was rebuilt")
        #expect(after["static-2"] == identities["static-2"], "an untouched body was rebuilt")
    }
}
