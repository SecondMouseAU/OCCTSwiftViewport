// ControllerSceneBoundsTests.swift
// OCCTSwiftViewport Tests
//
// Issue #252: `ViewportController.sceneBounds(of:)` hands an app the world bounds of the visible
// geometry-layer bodies from the controller's own per-bounds-key cache, so a camera that reads
// them on every move does not rescan vertices and needs no cache of its own.
//
// "Without a rescan" is proved by counting: a body that draws `CountingContent` reports its local
// box through `contentBounds`, which `ViewportBody.boundingBox` calls exactly once per scan, so
// the number of reads is the number of rescans. Moving the body by `transform` must leave it
// unchanged, and so must reading the bounds through another path that uses the controller's
// cache (`orthographicEyeBounds`), which is what makes the cache shared and not a second one.

import Foundation
import Testing
import os
import simd

@testable import OCCTSwiftViewport

/// Content drawn in place that counts how often it is measured.
///
/// Its box is `(0, 0, 0)` to `(2, 2, top)`. Raising `top` bumps `boundsVersion`, as a heightfield
/// edit does.
private final class CountingContent: InPlaceBodyContent {
    private struct State {
        var reads = 0
        var top: Float
        var version: UInt64 = 1
    }
    private let state: OSAllocatedUnfairLock<State>

    init(top: Float = 1) { state = OSAllocatedUnfairLock(initialState: State(top: top)) }

    /// How many times the body's geometry was scanned for its bounds.
    var reads: Int { state.withLock(\.reads) }

    func raise(to top: Float) {
        state.withLock {
            $0.top = top
            $0.version &+= 1
        }
    }

    var contentBounds: BoundingBox? {
        state.withLock {
            $0.reads += 1
            return BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(2, 2, $0.top))
        }
    }

    var boundsVersion: UInt64 { state.withLock(\.version) }
}

private func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
    var matrix = matrix_identity_float4x4
    matrix.columns.3 = SIMD4<Float>(offset, 1)
    return matrix
}

/// A body that draws `content` and has no mesh arrays of its own.
private func countedBody(
    id: String, content: CountingContent, layer: RenderLayer = .geometry,
    transform: simd_float4x4 = matrix_identity_float4x4
) -> ViewportBody {
    var body = ViewportBody(
        id: id, vertexData: [], indices: [], edges: [], color: SIMD4<Float>(1, 1, 1, 1),
        renderLayer: layer)
    body.inPlaceContent = content
    body.transform = transform
    return body
}

@Suite("Controller scene bounds (#252)")
@MainActor
struct ControllerSceneBoundsTests {

    // MARK: Value

    @Test("a plain body's bounds are its own box moved by its transform")
    func matchesTransformedBoundingBox() throws {
        var body = ViewportBody.box(id: "box", width: 2, height: 4, depth: 6, up: .z)
        let local = try #require(body.boundingBox)
        let controller = ViewportController()

        #expect(controller.sceneBounds(of: [body]) == local)

        body.transform =
            translation(SIMD3(10, -3, 5))
            * simd_matrix4x4(
                simd_quatf(angle: .pi / 6, axis: SIMD3(0, 0, 1)))
        let world = try #require(controller.sceneBounds(of: [body]))
        #expect(world == local.transformed(by: body.transform))
        #expect(world != local, "the transform must have moved the box")
    }

    @Test("several bodies are unioned, each in its own place")
    func unionOfBodies() throws {
        var a = ViewportBody.box(id: "a", width: 2, height: 2, depth: 2, up: .z)
        var b = ViewportBody.sphere(id: "b", up: .z)
        a.transform = translation(SIMD3(-20, 0, 0))
        b.transform = translation(SIMD3(0, 30, 4))
        let expected = try #require(a.boundingBox).transformed(by: a.transform)
            .union(try #require(b.boundingBox).transformed(by: b.transform))

        #expect(ViewportController().sceneBounds(of: [a, b]) == expected)
    }

    // MARK: No rescan

    @Test("a transform change moves the bounds without scanning the body again")
    func transformChangeDoesNotRescan() throws {
        let content = CountingContent()
        var body = countedBody(id: "part", content: content)
        let controller = ViewportController()

        let first = try #require(controller.sceneBounds(of: [body]))
        #expect(first == BoundingBox(min: SIMD3(0, 0, 0), max: SIMD3(2, 2, 1)))
        #expect(content.reads == 1)

        for step in 1...30 {
            body.transform = translation(SIMD3(Float(step), 0, 0))
            let moved = try #require(controller.sceneBounds(of: [body]))
            #expect(moved.min.x == Float(step) && moved.max.x == Float(step) + 2)
            #expect(moved.min.y == 0 && moved.max.y == 2)
        }
        #expect(content.reads == 1, "moving the body rescanned it")

        // The cache is still live afterwards: a bounds change is noticed once, then cached again.
        content.raise(to: 8)
        #expect(controller.sceneBounds(of: [body])?.max.z == 8)
        #expect(content.reads == 2)
        body.transform = translation(SIMD3(0, 0, 100))
        #expect(controller.sceneBounds(of: [body])?.max.z == 108)
        #expect(content.reads == 2)
    }

    @Test("it shares the controller's cache with its own scene-bounds reads")
    func sharesTheControllersCache() throws {
        let content = CountingContent()
        let body = countedBody(id: "part", content: content)
        let controller = ViewportController()

        // Warmed by the public method, read by the controller's orthographic eye placement.
        _ = controller.sceneBounds(of: [body])
        _ = controller.orthographicEyeBounds(of: [body])
        #expect(content.reads == 1, "the controller's own read scanned a body the public one had")

        // And the other way round, on a body the controller read first.
        let other = CountingContent()
        let otherBody = countedBody(id: "other", content: other)
        _ = controller.orthographicEyeBounds(of: [body, otherBody])
        _ = controller.sceneBounds(of: [body, otherBody])
        #expect(other.reads == 1, "the public read scanned a body the controller's had")
        #expect(content.reads == 1)
        #expect(controller.pivotStrategy.boundingBoxCache.keys.sorted() == ["other", "part"])
    }

    @Test("a call with part of a scene leaves the rest cached")
    func subsetKeepsTheRest() throws {
        let contents = (0..<40).map { _ in CountingContent() }
        let bodies = contents.enumerated().map {
            countedBody(
                id: "body\($0)", content: $1, transform: translation(SIMD3(Float($0) * 10, 0, 0)))
        }
        let controller = ViewportController()
        _ = controller.sceneBounds(of: bodies)

        #expect(
            controller.sceneBounds(of: [bodies[3]])?.max.x == 32, "a subset is bounded as itself")
        #expect(controller.sceneBounds(of: [bodies[7], bodies[9]])?.min.x == 70)
        let all = try #require(controller.sceneBounds(of: bodies))
        #expect(all.max.x == 392)
        #expect(contents.allSatisfy { $0.reads == 1 }, "a subset made a later call rescan")
        #expect(controller.pivotStrategy.boundingBoxCache.count == 40)
    }

    @Test("the controller's own calls still drop the bodies the scene no longer has")
    func viewportCallsPrune() {
        let contents = (0..<5).map { _ in CountingContent() }
        var bodies = contents.enumerated().map { countedBody(id: "body\($0)", content: $1) }
        bodies.append(
            ViewportBody(
                id: "nothing", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1)))
        let controller = ViewportController()
        _ = controller.sceneBounds(of: bodies)
        #expect(controller.pivotStrategy.boundsKeyCache.count == 6, "a body with no bounds counts")

        _ = controller.orthographicEyeBounds(of: [bodies[0]])
        #expect(controller.pivotStrategy.boundingBoxCache.keys.sorted() == ["body0"])
        #expect(controller.pivotStrategy.boundsKeyCache.keys.sorted() == ["body0"])
    }

    @Test("the pivot and the focus raycast, the other readers of the cache, prune too")
    func pivotAndRaycastPrune() {
        let bodies = (0..<5).map { countedBody(id: "body\($0)", content: CountingContent()) }
        let strategy = PivotStrategy()

        _ = strategy.sceneBounds(of: bodies)
        _ = strategy.computePivot(
            cameraState: CameraState(distance: 100), bodies: [bodies[0]], aspectRatio: 1,
            config: .default)
        #expect(strategy.boundsKeyCache.keys.sorted() == ["body0"], "computePivot did not prune")

        _ = strategy.sceneBounds(of: bodies)
        let ray = Ray(origin: SIMD3(1, 1, 10), direction: SIMD3(0, 0, -1))
        _ = strategy.raycast(ray: ray, bodies: [bodies[1]], clipPlanes: [])
        #expect(strategy.boundsKeyCache.keys.sorted() == ["body1"], "raycast did not prune")
    }

    @Test("a call that does not prune still bounds the cache by the scene's size")
    func retainedEntriesAreBounded() {
        let contents = (0..<5).map { _ in CountingContent() }
        let scene = contents.enumerated().map { countedBody(id: "scene\($0)", content: $1) }
        let controller = ViewportController()
        _ = controller.sceneBounds(of: scene)

        // Bodies come and go under fresh ids, each call listing only the one it has.
        func listFresh(_ indices: Range<Int>) {
            for index in indices {
                let body = countedBody(id: "temp\(index)", content: CountingContent())
                _ = controller.sceneBounds(of: [body])
            }
        }
        listFresh(0..<10)
        _ = controller.sceneBounds(of: scene)
        #expect(contents.allSatisfy { $0.reads == 1 }, "the scene was dropped under the bound")

        listFresh(10..<60)
        let count = controller.pivotStrategy.boundsKeyCache.count
        #expect(count <= 2 * scene.count + 16, "removed bodies piled up: \(count) entries")
        #expect(count >= 1)
    }

    @Test("a geometry edit is noticed through the public method")
    func geometryEditIsMeasuredAgain() throws {
        var body = ViewportBody.box(id: "box", width: 2, height: 2, depth: 2, up: .z)
        let controller = ViewportController()
        let before = try #require(controller.sceneBounds(of: [body]))

        body.vertexData[0] += 40
        #expect(body.boundingBox != before)
        #expect(controller.sceneBounds(of: [body]) == body.boundingBox)
    }

    // MARK: Which bodies count

    @Test("hidden and overlay bodies are left out and not scanned")
    func hiddenAndOverlayBodiesAreLeftOut() throws {
        let model = ViewportBody.box(id: "model", width: 2, height: 2, depth: 2, up: .z)
        let hiddenContent = CountingContent()
        let overlayContent = CountingContent()
        let hidden = {
            var body = countedBody(
                id: "hidden", content: hiddenContent, transform: translation(SIMD3(500, 0, 0)))
            body.isVisible = false
            return body
        }()
        let overlay = countedBody(
            id: "gizmo", content: overlayContent, layer: .overlay,
            transform: translation(SIMD3(0, 500, 0)))
        let controller = ViewportController()

        let bounds = try #require(controller.sceneBounds(of: [model, hidden, overlay]))
        #expect(bounds == model.boundingBox)
        #expect(hiddenContent.reads == 0 && overlayContent.reads == 0)

        // A hidden body that is shown again is measured and counted.
        var shown = hidden
        shown.isVisible = true
        let withShown = try #require(controller.sceneBounds(of: [model, shown, overlay]))
        let shownBox = BoundingBox(min: SIMD3(500, 0, 0), max: SIMD3(502, 2, 1))
        #expect(withShown == model.boundingBox?.union(shownBox))
        #expect(hiddenContent.reads == 1)
    }

    @Test("with nothing visible to bound the result is nil")
    func nothingToBound() {
        let controller = ViewportController()
        #expect(controller.sceneBounds(of: []) == nil, "an empty scene")

        var hidden = ViewportBody.box(id: "hidden", up: .z)
        hidden.isVisible = false
        #expect(controller.sceneBounds(of: [hidden]) == nil, "only hidden bodies")

        var overlay = ViewportBody.box(id: "widget", up: .z)
        overlay.renderLayer = .overlay
        #expect(controller.sceneBounds(of: [overlay]) == nil, "only overlay bodies")

        let nothing = ViewportBody(
            id: "nothing", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1))
        #expect(controller.sceneBounds(of: [nothing]) == nil, "a body with no geometry")

        let model = ViewportBody.box(id: "model", up: .z)
        #expect(
            controller.sceneBounds(of: [nothing, hidden, overlay, model]) == model.boundingBox,
            "a body that draws nothing does not disturb the others")
    }

    // MARK: Heightfield

    @Test("a heightfield body is bounded by its field, follows its transform and in-place edits")
    func heightfieldBody() throws {
        let field = try Heightfield(width: 64, height: 32, initialHeight: 1)
        var body = ViewportBody(
            id: "terrain", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1),
            heightfield: field)
        let controller = ViewportController()

        #expect(controller.sceneBounds(of: [body]) == field.localBounds)

        body.transform = translation(SIMD3(0, 0, 50))
        #expect(
            controller.sceneBounds(of: [body]) == field.localBounds.transformed(by: body.transform))

        // Raised through the shared handle: the body value is untouched, its generation too.
        let generation = body.generation
        field.replace(
            region: HeightfieldRegion(x: 4, y: 4, width: 8, height: 8),
            heights: [Float](repeating: 25, count: 64))
        #expect(body.generation == generation)
        #expect(controller.sceneBounds(of: [body])?.max.z == 75)
    }
}
