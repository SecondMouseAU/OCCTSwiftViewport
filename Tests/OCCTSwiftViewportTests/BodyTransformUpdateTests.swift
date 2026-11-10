// BodyTransformUpdateTests.swift
// OCCTSwiftViewport Tests
//
// Issue #141: moving a body every frame by changing `ViewportBody.transform` (and re-assigning the
// bodies array the view reads) must cost a uniform update, not a re-upload. A body's GPU buffers
// are keyed by `id` and `generation`; `transform` is applied in the vertex shader and is not
// geometry, so it leaves `generation` alone. These tests drive the live renderer's own draw path
// headlessly and check object identity of the cached buffers plus the renderer's build counter.
// Each has a control (a real geometry change) so the counters are known to be able to move.

import Foundation
import Metal
import SwiftUI
import Testing
import simd

@_spi(Bench) @testable import OCCTSwiftViewport

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

@MainActor
private enum TransformScene {
    static let size = 96

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    /// One moving sphere plus `staticCount` boxes on a grid behind it.
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

    static func make(_ store: TransformBodyStore) -> (ViewportController, ViewportRenderer)? {
        var config = ViewportConfiguration()
        config.initialCameraState = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3(1, 0, 0)), distance: 10, pivot: .zero)
        config.backgroundColor = SIMD4(0, 0, 0, 1)
        let controller = ViewportController(configuration: config)
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: store.binding)
        else { return nil }
        retainedTransformControllers.append(controller)
        return (controller, renderer)
    }

    static func render(_ renderer: ViewportRenderer) -> [UInt8]? {
        renderer.renderHeadlessBGRA(
            width: size, height: size, backgroundColor: SIMD4(0, 0, 0, 1))
    }
}

@MainActor
@Suite("Body transform updates re-create no buffer (#141)")
struct BodyTransformUpdateTests {

    private func bufferIdentities(
        _ renderer: ViewportRenderer, _ store: TransformBodyStore
    ) -> [String: [ObjectIdentifier?]] {
        var out: [String: [ObjectIdentifier?]] = [:]
        for body in store.bodies {
            guard let buffers = renderer.cachedMeshBuffers(for: body.id) else { continue }
            out[body.id] = [buffers.vertex, buffers.normal, buffers.index].map {
                $0.map { ObjectIdentifier($0) }
            }
        }
        return out
    }

    @Test("Mutating transform at 60 Hz keeps generation and every cached buffer")
    func transformKeepsBuffers() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 20))
        guard let (_, renderer) = TransformScene.make(store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let first = try #require(TransformScene.render(renderer))
        let generations = store.bodies.map(\.generation)
        let identities = bufferIdentities(renderer, store)
        #expect(identities.count == 21, "every body should have cached buffers")
        let builds = renderer.benchBodyBufferBuilds
        #expect(builds == 21)

        var last = first
        for step in 1...60 {
            // The body moves; the array is mutated in place and so re-assigned through the binding.
            store.bodies[0].transform = TransformScene.translation(SIMD3(Float(step) * 0.04, 0, 0))
            last = try #require(TransformScene.render(renderer))
        }

        #expect(store.bodies.map(\.generation) == generations, "transform changed a generation")
        #expect(renderer.benchBodyBufferBuilds == builds, "a transform change rebuilt buffers")
        #expect(bufferIdentities(renderer, store) == identities, "a cached buffer was replaced")
        #expect(last != first, "the body did not move")
    }

    @Test("Re-assigning the whole bodies array each frame re-creates nothing")
    func arrayReassignmentKeepsBuffers() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 99))
        guard let (_, renderer) = TransformScene.make(store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = try #require(TransformScene.render(renderer))
        let identities = bufferIdentities(renderer, store)
        let builds = renderer.benchBodyBufferBuilds
        #expect(builds == 100)

        for step in 1...30 {
            var next = store.bodies.map { $0 }
            next[0].transform = TransformScene.translation(SIMD3(Float(step) * 0.04, 0, 0))
            store.bodies = next
            _ = try #require(TransformScene.render(renderer))
        }
        #expect(renderer.benchBodyBufferBuilds == builds)
        #expect(bufferIdentities(renderer, store) == identities)
    }

    @Test("Control: a geometry change does take a new generation and rebuild the body")
    func geometryChangeDoesRebuild() throws {
        let store = TransformBodyStore(TransformScene.bodies(staticCount: 3))
        guard let (_, renderer) = TransformScene.make(store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = try #require(TransformScene.render(renderer))
        let identities = bufferIdentities(renderer, store)
        let builds = renderer.benchBodyBufferBuilds
        let generation = store.bodies[0].generation

        var changed = store.bodies[0].vertexData
        changed[0] += 0.01
        store.bodies[0].vertexData = changed
        _ = try #require(TransformScene.render(renderer))

        #expect(store.bodies[0].generation != generation)
        #expect(renderer.benchBodyBufferBuilds == builds + 1)
        let after = bufferIdentities(renderer, store)
        #expect(after["mover"] != identities["mover"], "the moved body kept its old buffers")
        #expect(after["static-0"] == identities["static-0"], "an untouched body was rebuilt")
    }
}
