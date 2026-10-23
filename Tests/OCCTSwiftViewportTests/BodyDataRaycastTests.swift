// BodyDataRaycastTests.swift
// OCCTSwiftViewport Tests
//
// Regression tests for:
// - #166: mutating a body's geometry in place never reached the GPU, because `generation` was a
//   `let` and both renderers key their buffer caches on it.
// - #167: `boundingBox` ignored `meshPositions`, and `SceneRaycast` indexed the empty `vertices`
//   of a direct-mesh body built through `init`.
// - #163: `SceneRaycast` (and so the dynamic pivot) hit geometry removed by section planes.
// - #173: the documented `SceneRaycast` call compiles against the public API.

import CoreGraphics
import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Helpers

/// Mutable body list a live renderer reads through a binding, so a test can change the scene
/// between frames the way a SwiftUI app would.
@MainActor
private final class MutableBodies {
    var bodies: [ViewportBody]
    init(_ bodies: [ViewportBody]) { self.bodies = bodies }
    var binding: Binding<[ViewportBody]> {
        Binding(get: { self.bodies }, set: { self.bodies = $0 })
    }
}

/// Interleaved stride-6 vertex data for a quad in the plane `z`, facing +Z, centred on `x`.
private func quadVertexData(x: Float = 0, z: Float = 0, half: Float = 1.5) -> [Float] {
    var data: [Float] = []
    for c: SIMD2<Float> in [[-half, -half], [half, -half], [half, half], [-half, half]] {
        data += [c.x + x, c.y, z, 0, 0, 1]
    }
    return data
}

private let quadIndices: [UInt32] = [0, 1, 2, 0, 2, 3]

private func quadBody(id: String, x: Float = 0, z: Float = 0) -> ViewportBody {
    ViewportBody(
        id: id, vertexData: quadVertexData(x: x, z: z), indices: quadIndices, edges: [],
        color: SIMD4<Float>(1, 0.2, 0.2, 1))
}

/// Camera on +Z looking down -Z at the origin.
private let frontCamera = CameraState(
    rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return 255 }
    var m = 0
    for i in 0..<a.count { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
    return m
}

private func bgra(_ image: CGImage) -> [UInt8] {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let info =
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return buffer
}

// MARK: - #166 generation on mutation

@Suite("ViewportBody generation tracks geometry mutation (#166)")
struct BodyGenerationMutationTests {

    /// Every geometry field, as a mutation applied to a fresh body.
    private static let geometryMutations: [(String, @Sendable (inout ViewportBody) -> Void)] = [
        ("vertexData", { $0.vertexData[0] += 1 }),
        ("indices", { $0.indices.append(contentsOf: [0, 1, 2]) }),
        ("edges", { $0.edges = [[.zero, SIMD3(1, 0, 0)]] }),
        (
            "arcs",
            {
                $0.arcs = [
                    ViewportArc(center: .zero, radius: 1, xAxis: [1, 0, 0], yAxis: [0, 1, 0])
                ]
            }
        ),
        ("faceIndices", { $0.faceIndices = [0, 0] }),
        ("edgeIndices", { $0.edgeIndices = [0] }),
        ("vertices", { $0.vertices.append(.zero) }),
        ("vertexIndices", { $0.vertexIndices = [0] }),
        ("vertexColors", { $0.vertexColors = [SIMD4(1, 1, 1, 1)] }),
        ("meshPositions", { $0.meshPositions = [0, 0, 0] }),
        ("meshNormals", { $0.meshNormals = [0, 0, 1] }),
    ]

    @Test("Each geometry field bumps generation when mutated", arguments: 0..<11)
    func geometryFieldBumps(index: Int) {
        let (name, mutate) = Self.geometryMutations[index]
        var body = quadBody(id: "q")
        let before = body.generation
        mutate(&body)
        #expect(body.generation > before, "\(name) did not bump generation")
    }

    @Test("Appearance and placement fields leave generation alone")
    func nonGeometryFieldsKeepGeneration() {
        var body = quadBody(id: "q")
        let before = body.generation
        body.color = SIMD4(0, 1, 0, 1)
        body.roughness = 0.1
        body.metallic = 1
        body.material = PBRMaterial()
        body.isVisible = false
        body.isPickable = false
        body.transform.columns.3 = SIMD4(1, 2, 3, 1)
        body.pointRadius = 1
        body.renderLayer = .overlay
        body.pickLayer = .widget
        body.triangleStyles = [.none, .none]
        body.id = "renamed"
        #expect(body.generation == before)
    }

    @Test("Copies share a generation until one is mutated")
    func copiesDivergeOnMutation() {
        let original = quadBody(id: "q")
        var copy = original
        #expect(copy.generation == original.generation)
        copy.vertexData = quadVertexData(x: 1)
        #expect(copy.generation != original.generation)
    }

    @Test("Generations stay unique when bodies are built and mutated concurrently")
    func concurrentGenerationsAreUnique() async {
        let generations = await withTaskGroup(of: [UInt64].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var seen: [UInt64] = []
                    for _ in 0..<200 {
                        var body = quadBody(id: "c")
                        seen.append(body.generation)
                        body.edges = []
                        seen.append(body.generation)
                    }
                    return seen
                }
            }
            var all: [UInt64] = []
            for await chunk in group { all += chunk }
            return all
        }
        #expect(Set(generations).count == generations.count)
    }
}

@MainActor
@Suite("Mutated geometry reaches the GPU (#166)")
struct MutatedGeometryRenderTests {

    /// A box with depth, so the fitted near plane cannot graze it (a head-on zero-depth quad
    /// sits exactly on the near plane the renderers fit to the scene bounds).
    private func box(x: Float) -> ViewportBody {
        var body = ViewportBody.box(
            id: "b", width: 2, height: 2, depth: 2, color: SIMD4<Float>(1, 0.2, 0.2, 1))
        body.vertexData = shifted(body.vertexData, x: x)
        return body
    }

    /// Moves stride-6 interleaved vertex data along x.
    private func shifted(_ data: [Float], x: Float) -> [Float] {
        var out = data
        for i in stride(from: 0, to: out.count, by: 6) { out[i] += x }
        return out
    }

    private func liveRenderer(_ store: MutableBodies) -> (ViewportController, ViewportRenderer)? {
        let configuration = ViewportConfiguration(
            initialCameraState: frontCamera, lightingConfiguration: .flat, showViewCube: false,
            showGrid: false, backgroundColor: SIMD4<Float>(0, 0, 0, 1), enableSilhouettes: false)
        let controller = ViewportController(configuration: configuration)
        controller.showGrid = false
        controller.showAxes = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: store.binding)
        else { return nil }
        return (controller, renderer)
    }

    private func frame(_ renderer: ViewportRenderer) -> [UInt8]? {
        // Two frames, so near/far come from the cached bounds in every image compared.
        renderer.renderHeadlessBGRA(
            width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1), frameCount: 2)
    }

    @Test("Live renderer redraws a body whose vertexData was mutated in place")
    func liveRendererPicksUpMutation() throws {
        let store = MutableBodies([box(x: -2)])
        guard let (controller, renderer) = liveRenderer(store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = controller
        let before = try #require(frame(renderer))

        // Same id, mutated in place, handed back: the GPU must see the moved box.
        var body = store.bodies[0]
        body.vertexData = shifted(body.vertexData, x: 4)
        store.bodies[0] = body
        let after = try #require(frame(renderer))

        // Reference: a renderer that only ever saw the moved box.
        let (freshController, freshRenderer) = try #require(liveRenderer(MutableBodies([body])))
        _ = freshController
        let reference = try #require(frame(freshRenderer))

        #expect(maxDelta(before, after) > 0, "mutation never reached the GPU")
        #expect(maxDelta(after, reference) == 0, "stale buffers drawn after mutation")
    }

    @Test("OffscreenRenderer redraws a body whose vertexData was mutated in place")
    func offscreenRendererPicksUpMutation() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var options = OffscreenRenderOptions(
            width: 120, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1), appearance: .light)
        options.cameraState = frontCamera
        var body = box(x: -2)
        let before = try #require(renderer.render(bodies: [body], options: options))
        body.vertexData = shifted(body.vertexData, x: 4)
        let after = try #require(renderer.render(bodies: [body], options: options))
        let reference = try #require(
            OffscreenRenderer()?.render(bodies: [body], options: options))

        #expect(maxDelta(bgra(before), bgra(after)) > 0, "mutation never reached the GPU")
        #expect(maxDelta(bgra(after), bgra(reference)) == 0, "stale buffers drawn after mutation")
    }

    @Test("PivotStrategy's bounding-box cache follows in-place geometry mutation")
    func pivotCacheFollowsMutation() throws {
        let strategy = PivotStrategy()
        let config = DynamicPivotConfiguration(zoomThreshold: 0.5, blendBand: 0.3)
        let far = CameraState(distance: 1000)
        var body = quadBody(id: "q")
        _ = strategy.computePivot(cameraState: far, bodies: [body], aspectRatio: 1, config: config)
        body.vertexData = quadVertexData(x: 40)
        let pivot = try #require(
            strategy.computePivot(cameraState: far, bodies: [body], aspectRatio: 1, config: config))
        #expect(simd_distance(pivot, [40, 0, 0]) < 1e-3, "pivot \(pivot)")
    }

    @Test("Hidden and overlay bodies don't move the zoomed-out pivot")
    func pivotIgnoresHiddenAndOverlayBodies() throws {
        let config = DynamicPivotConfiguration(zoomThreshold: 0.5, blendBand: 0.3)
        let far = CameraState(distance: 1000)
        var hidden = quadBody(id: "hidden", x: 100)
        hidden.isVisible = false
        var widget = quadBody(id: "widget", x: -100)
        widget.renderLayer = .overlay
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: far, bodies: [quadBody(id: "model", x: 5), hidden, widget],
                aspectRatio: 1, config: config))
        #expect(simd_distance(pivot, [5, 0, 0]) < 1e-3, "pivot \(pivot)")
    }
}

// MARK: - #167 direct-mesh bodies built through init

@Suite("Direct-mesh bodies built through init (#167)")
struct DirectMeshInitBodyTests {

    /// Direct-mesh quad at z = `z`, built through `init` so `vertices` stays empty, with a
    /// feature edge so its bounding box would be non-nil even before the fix.
    private func directInitBody(id: String = "d", z: Float = 0) -> ViewportBody {
        let h: Float = 1.5
        let positions: [Float] = [-h, -h, z, h, -h, z, h, h, z, -h, h, z]
        let normals: [Float] = [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1]
        return ViewportBody(
            id: id, vertexData: [], indices: quadIndices,
            edges: [[SIMD3(-0.1, 0, z), SIMD3(0.1, 0, z)]],
            color: SIMD4(0.5, 0.5, 0.5, 1),
            meshPositions: positions, meshNormals: normals)
    }

    @Test("boundingBox covers meshPositions")
    func boundingBoxIncludesMeshPositions() throws {
        var body = directInitBody(z: 0.25)
        body.edges = []
        #expect(body.vertices.isEmpty)
        let box = try #require(body.boundingBox, "direct-mesh body built via init had no bounds")
        #expect(box.min == SIMD3<Float>(-1.5, -1.5, 0.25))
        #expect(box.max == SIMD3<Float>(1.5, 1.5, 0.25))
    }

    @Test("boundingBox prefers meshPositions over a stale vertexData, like the renderer")
    func boundingBoxFollowsRenderedPath() throws {
        var body = directInitBody()
        body.vertexData = quadVertexData(x: 100)
        let box = try #require(body.boundingBox)
        #expect(box.max.x < 2, "bounds came from vertexData, which the renderer does not draw")
    }

    @Test("SceneRaycast hits a direct-mesh body with empty vertices instead of trapping")
    func raycastReadsMeshPositions() throws {
        let body = directInitBody(z: 0.5)
        let ray = Ray(origin: SIMD3(0.7, 0.3, 5), direction: SIMD3(0, 0, -1))
        let hit = try #require(SceneRaycast.cast(ray: ray, bodies: [body]))
        #expect(hit.bodyID == "d")
        #expect(abs(hit.point.z - 0.5) < 1e-4)
        #expect(abs(hit.distance - 4.5) < 1e-4)
    }

    @Test("SceneRaycast skips out-of-range indices and partial triples instead of trapping")
    func raycastToleratesMalformedIndices() {
        var body = quadBody(id: "bad")
        body.indices = [0, 1, 99, 0, 2]
        let ray = Ray(origin: SIMD3(0.5, -0.5, 5), direction: SIMD3(0, 0, -1))
        #expect(SceneRaycast.cast(ray: ray, bodies: [body]) == nil)
    }
}

// MARK: - #163 clip planes

@MainActor
@Suite("SceneRaycast honours section planes (#163)")
struct SceneRaycastClipPlaneTests {

    /// Removes everything with z > 0.2, the same plane `ClipPlanePassTests` checks the GPU
    /// pick pass against: `dot((0, 0, -1), p) + 0.2 < 0` exactly when `p.z > 0.2`.
    private let section = ClipPlane(normal: SIMD3<Float>(0, 0, -1), distance: 0.2)

    /// A quad at z = 1 in front of a quad at z = -1, both under a ray along -Z.
    private var bodies: [ViewportBody] {
        [quadBody(id: "front", z: 1), quadBody(id: "back", z: -1)]
    }
    private let ray = Ray(origin: SIMD3(0.2, 0.1, 10), direction: SIMD3(0, 0, -1))

    @Test("Without planes the nearer body is hit")
    func control() {
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies)?.bodyID == "front")
    }

    @Test("A hit on clipped-away geometry is skipped and the search continues behind it")
    func skipsClippedHit() throws {
        let hit = try #require(SceneRaycast.cast(ray: ray, bodies: bodies, clipPlanes: [section]))
        #expect(hit.bodyID == "back")
        #expect(abs(hit.point.z + 1) < 1e-4)
    }

    @Test("Clipping uses the world-space hit, after the body transform")
    func clipsInWorldSpace() throws {
        // Both quads authored at z = 0; the front one is moved past the plane by transform.
        var front = quadBody(id: "front")
        front.transform.columns.3 = SIMD4(0, 0, 1, 1)
        var back = quadBody(id: "back")
        back.transform.columns.3 = SIMD4(0, 0, -1, 1)
        let hit = try #require(
            SceneRaycast.cast(ray: ray, bodies: [front, back], clipPlanes: [section]))
        #expect(hit.bodyID == "back")
    }

    @Test("Disabled planes and planes past maxActivePlanes are ignored, as on the GPU")
    func onlyAppliedPlanesCount() {
        var disabled = section
        disabled.isEnabled = false
        #expect(
            SceneRaycast.cast(ray: ray, bodies: bodies, clipPlanes: [disabled])?.bodyID == "front")

        let harmless = ClipPlane(normal: SIMD3(0, 0, 1), distance: 100)
        let planes = Array(repeating: harmless, count: ClipPlane.maxActivePlanes) + [section]
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies, clipPlanes: planes)?.bodyID == "front")
    }

    @Test("Everything clipped yields no hit")
    func everythingClipped() {
        let all = ClipPlane(normal: SIMD3(0, 0, 1), distance: -100)
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies, clipPlanes: [all]) == nil)
    }

    @Test("The CPU clip test and the GPU pick pass agree on which side a plane removes")
    func matchesGPUPickConvention() async throws {
        let scene = bodies
        let configuration = ViewportConfiguration(
            initialCameraState: frontCamera, lightingConfiguration: .flat, showViewCube: false,
            showGrid: false, backgroundColor: SIMD4<Float>(0, 0, 0, 1), enableSilhouettes: false,
            pickingConfiguration: PickingConfiguration(isEnabled: true))
        let controller = ViewportController(configuration: configuration)
        controller.showGrid = false
        controller.showAxes = false
        controller.clipPlanes = [section]
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(scene))
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = try #require(
            renderer.renderHeadlessBGRA(
                width: 160, height: 120, backgroundColor: SIMD4<Float>(0, 0, 0, 1)))
        let rect = CGRect(x: 0, y: 0, width: 160, height: 120)
        let results: [PickResult] = await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
        let gpuPicked = Set(results.map(\.bodyID))
        let cpuHit = SceneRaycast.cast(ray: ray, bodies: scene, clipPlanes: controller.clipPlanes)

        #expect(gpuPicked == ["back"], "GPU picked \(gpuPicked)")
        #expect(cpuHit?.bodyID == "back")
    }

    @Test("Dynamic pivot lands on the visible geometry behind a section")
    func pivotSkipsClippedGeometry() throws {
        let camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 0.5,
            pivot: SIMD3(0, 0, 3))
        let config = DynamicPivotConfiguration(zoomThreshold: 0.5, blendBand: 0.3)
        let unclipped = try #require(
            PivotStrategy().computePivot(
                cameraState: camera, bodies: bodies, aspectRatio: 1, config: config))
        #expect(abs(unclipped.z - 1) < 1e-3, "control pivot \(unclipped)")

        let clipped = try #require(
            PivotStrategy().computePivot(
                cameraState: camera, bodies: bodies, aspectRatio: 1, config: config,
                clipPlanes: [section]))
        #expect(abs(clipped.z + 1) < 1e-3, "pivot \(clipped)")
    }
}

// MARK: - #173 documented raycast call

@Suite("Documented SceneRaycast usage (#173)")
struct SceneRaycastDocsTests {

    @Test("The Picking.md example's explicit cache matches the convenience overload")
    func documentedCacheCompiles() {
        let bodies = [ViewportBody.box(id: "cube")]
        let ray = Ray(origin: SIMD3(0, 0, -5), direction: SIMD3(0, 0, 1))
        let cache = Dictionary(
            uniqueKeysWithValues: bodies.compactMap { b in b.boundingBox.map { (b.id, $0) } })
        let explicit = SceneRaycast.cast(ray: ray, bodies: bodies, boundingBoxCache: cache)
        let convenience = SceneRaycast.cast(ray: ray, bodies: bodies)
        #expect(explicit?.bodyID == "cube")
        #expect(explicit?.distance == convenience?.distance)
    }
}
