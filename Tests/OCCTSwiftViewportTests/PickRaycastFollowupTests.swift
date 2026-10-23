// PickRaycastFollowupTests.swift
// OCCTSwiftViewport Tests
//
// Follow-ups from the issue #136 audit:
// - #180: the CPU raycast (dynamic pivot, focus-on-point) skips overlay and non-pickable bodies.
// - #182: native edge picks carry the drawn edge's depth bias, so they win over a tilted face.
// - #183: the shadow frustum ignores overlay bodies.
// - #184: overlapping picks each read back into their own buffer.

import CoreGraphics
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

private let quadIndices: [UInt32] = [0, 1, 2, 0, 2, 3]

/// A 3 x 3 quad facing +Z, centred on (`x`, 0, `z`).
private func quad(id: String, x: Float = 0, z: Float = 0) -> ViewportBody {
    var data: [Float] = []
    for c: SIMD2<Float> in [[-1.5, -1.5], [1.5, -1.5], [1.5, 1.5], [-1.5, 1.5]] {
        data += [c.x + x, c.y, z, 0, 0, 1]
    }
    return ViewportBody(
        id: id, vertexData: data, indices: quadIndices, edges: [],
        color: SIMD4<Float>(1, 0.2, 0.2, 1))
}

/// Camera on +Z looking down -Z at the origin.
private let frontCamera = CameraState(
    rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

private struct RenderUnavailable: Error {}

// MARK: - #180 CPU raycast filtering

@Suite("SceneRaycast skips overlay and non-pickable bodies by default (#180)")
struct SceneRaycastFilteringTests {

    private let ray = Ray(origin: SIMD3(0.2, 0.1, 10), direction: SIMD3(0, 0, -1))

    /// The model at z = 0 behind a widget at z = 1.
    private func scene(_ configure: (inout ViewportBody) -> Void) -> [ViewportBody] {
        var widget = quad(id: "widget", z: 1)
        configure(&widget)
        return [widget, quad(id: "model")]
    }

    @Test("An overlay body in front of the model is skipped unless included")
    func overlaySkipped() {
        let bodies = scene { $0.renderLayer = .overlay }
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies)?.bodyID == "model")
        #expect(
            SceneRaycast.cast(ray: ray, bodies: bodies, includeWidgets: true)?.bodyID == "widget")
    }

    @Test("A non-pickable body in front of the model is skipped unless included")
    func nonPickableSkipped() {
        let bodies = scene { $0.isPickable = false }
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies)?.bodyID == "model")
        #expect(
            SceneRaycast.cast(ray: ray, bodies: bodies, includeNonPickable: true)?.bodyID
                == "widget")
    }

    @Test("The explicit-cache overload filters the same way")
    func explicitCacheOverloadFilters() {
        let bodies = scene { $0.renderLayer = .overlay }
        let cache = Dictionary(
            uniqueKeysWithValues: bodies.compactMap { b in b.boundingBox.map { (b.id, $0) } })
        #expect(
            SceneRaycast.cast(ray: ray, bodies: bodies, boundingBoxCache: cache)?.bodyID
                == "model")
        #expect(
            SceneRaycast.cast(
                ray: ray, bodies: bodies, boundingBoxCache: cache, includeWidgets: true)?
                .bodyID == "widget")
    }

    @Test("A widget-pick-layer body on the geometry layer is skipped unless included")
    func widgetPickLayerSkipped() {
        let bodies = scene { $0.pickLayer = .widget }
        #expect(SceneRaycast.cast(ray: ray, bodies: bodies)?.bodyID == "model")
        #expect(
            SceneRaycast.cast(ray: ray, bodies: bodies, includeWidgets: true)?.bodyID == "widget")
    }

    @Test("Hidden bodies stay skipped even when widgets and non-pickables are included")
    func hiddenStillSkipped() {
        let bodies = scene { $0.isVisible = false }
        #expect(
            SceneRaycast.cast(
                ray: ray, bodies: bodies, includeWidgets: true, includeNonPickable: true)?
                .bodyID == "model")
    }
}

@MainActor
@Suite("Dynamic pivot ignores widgets and hidden bodies (#180)")
struct PivotStrategyFilteringTests {

    private let config = DynamicPivotConfiguration(zoomThreshold: 0.5, blendBand: 0.3)
    /// Zoomed right in on the view centre, so the pivot is the raycast hit.
    private let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 0.5,
        pivot: SIMD3(0, 0, 3))

    @Test("The zoomed-in pivot lands on the model behind an overlay or non-pickable body")
    func pivotSkipsWidgets() throws {
        var overlay = quad(id: "overlay", z: 2)
        overlay.renderLayer = .overlay
        var datum = quad(id: "datum", z: 1)
        datum.isPickable = false
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: camera, bodies: [overlay, datum, quad(id: "model")], aspectRatio: 1,
                config: config))
        #expect(abs(pivot.z) < 1e-3, "pivot \(pivot) landed on a widget")
    }

    @Test("Bounds are not computed for hidden or overlay bodies")
    func cacheSkipsUnusedBodies() {
        var hidden = quad(id: "hidden", x: 10)
        hidden.isVisible = false
        var overlay = quad(id: "overlay", x: -10)
        overlay.renderLayer = .overlay
        var datum = quad(id: "datum", z: 1)
        datum.isPickable = false
        var handle = quad(id: "handle", z: 2)
        handle.pickLayer = .widget
        let strategy = PivotStrategy()
        _ = strategy.computePivot(
            cameraState: camera, bodies: [hidden, overlay, datum, handle, quad(id: "model")],
            aspectRatio: 1, config: config)
        // Non-pickable and widget-pick-layer geometry still count toward the zoomed-out scene
        // bounds, as in the renderer's clip fit.
        #expect(Set(strategy.boundingBoxCache.keys) == ["model", "datum", "handle"])
    }

    @Test("Focus raycasts share the pivot's cache and skip widgets")
    func focusRaycastUsesCache() throws {
        var handle = quad(id: "handle", z: 2)
        handle.pickLayer = .widget
        let bodies = [handle, quad(id: "model")]
        let strategy = PivotStrategy()
        let ray = Ray(origin: SIMD3(0.2, 0.1, 10), direction: SIMD3(0, 0, -1))
        let hit = try #require(strategy.raycast(ray: ray, bodies: bodies, clipPlanes: []))
        #expect(hit.bodyID == "model")
        #expect(Set(strategy.boundingBoxCache.keys) == ["handle", "model"])
        // A second cast reuses the cached boxes and finds the same hit.
        #expect(
            strategy.raycast(ray: ray, bodies: bodies, clipPlanes: [])?.distance == hit.distance)
    }

    @Test("A body that becomes visible again gets bounds on the next pivot")
    func reshownBodyIsCached() throws {
        var body = quad(id: "q", x: 40)
        body.isVisible = false
        let strategy = PivotStrategy()
        // Looking down -z at a pivot 5 above the quad, so the quad's depth is a new pivot.
        let far = CameraState(distance: 1000, pivot: SIMD3(0, 0, 5))
        #expect(
            strategy.computePivot(cameraState: far, bodies: [body], aspectRatio: 1, config: config)
                == nil)
        body.isVisible = true
        let pivot = try #require(
            strategy.computePivot(cameraState: far, bodies: [body], aspectRatio: 1, config: config))
        // The quad's centre at its depth on the line of sight (issue #204), not the centre.
        #expect(simd_distance(pivot, [0, 0, 0]) < 1e-3, "pivot \(pivot)")
    }
}

// MARK: - Live renderer helpers

@MainActor
private func makeRenderer(
    bodies: [ViewportBody],
    camera: CameraState = frontCamera,
    displayMode: DisplayMode = .shaded,
    edge: EdgeLineConfiguration = .default,
    lighting: LightingConfiguration = .flat
) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
    var config = ViewportConfiguration()
    config.initialCameraState = camera
    config.edgeLineConfiguration = edge
    config.lightingConfiguration = lighting
    config.backgroundColor = SIMD4(0, 0, 0, 1)
    config.showViewCube = false
    config.pickingConfiguration = PickingConfiguration(isEnabled: true)
    let controller = ViewportController(configuration: config)
    controller.displayMode = displayMode
    controller.showGrid = false
    controller.showAxes = false
    controller.enableTAA = false
    guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
    else {
        Issue.record("Metal device unavailable; skipping headless render test")
        throw RenderUnavailable()
    }
    return (controller, renderer)
}

@MainActor
private func pick(_ renderer: ViewportRenderer, at pixel: SIMD2<Int>) async -> PickResult? {
    await withCheckedContinuation { continuation in
        renderer.performPick(at: pixel) { continuation.resume(returning: $0) }
    }
}

// MARK: - #182 native edge pick bias

@MainActor
@Suite("Native edge picks win over the tilted face they lie on (#182)")
struct NativeEdgePickBiasTests {

    /// Large enough that the bias, a fixed fraction of the NDC height, covers the half-pixel
    /// depth spread of this face's slope; at 128 px it does not, for the drawn edge either.
    static let size = 512

    @Test("Along a native edge on a steeply tilted face, the pick resolves to the edge")
    func edgeBeatsTiltedFace() async throws {
        // A face tilted away from a perspective camera (its depth changes down the screen), with
        // an edge lying on it running across the screen, slightly slanted so it crosses rows.
        // A 1 px line takes its depth at the line, the face at each pixel centre up to half a
        // pixel up or down the slope, so unbiased the face is nearer on part of the edge.
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        var plane = ViewportBody(
            id: "plane", vertexData: v(-7, -9) + v(13, -5) + v(9, 11) + v(-11, 6),
            indices: quadIndices, edges: [[SIMD3(-3, 0.1, 0), SIMD3(3, -0.1, 0)]],
            color: SIMD4<Float>(1, 1, 1, 1))
        plane.edgeIndices = [0]
        let camera = CameraState(
            rotation: simd_quatf(angle: 1.1, axis: SIMD3<Float>(1, 0, 0)),
            distance: 30, pivot: .zero, fieldOfView: 30)
        let pair = try makeRenderer(
            bodies: [plane], camera: camera, displayMode: .shadedWithEdges,
            edge: EdgeLineConfiguration(useQuadExpansion: false))
        guard
            pair.renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1)) != nil
        else { throw RenderUnavailable() }

        // For each column, does any pixel in a band round the centre row pick as the edge?
        var edgeColumns: [Int] = []
        for x in 0..<Self.size {
            let rect = CGRect(x: x, y: Self.size / 2 - 8, width: 1, height: 16)
            let kinds: Set<PrimitiveKind> = await withCheckedContinuation { continuation in
                pair.renderer.performRegionPick(rect: rect) {
                    continuation.resume(returning: Set($0.map(\.kind)))
                }
            }
            if kinds.contains(.edge) { edgeColumns.append(x) }
        }
        let span = (edgeColumns.last ?? 0) - (edgeColumns.first ?? 0) + 1
        #expect(span > 30, "the edge picked across only \(span) columns")
        #expect(
            edgeColumns.count == span,
            "the face won \(span - edgeColumns.count) of the edge's \(span) columns")
    }
}

// MARK: - #183 shadow frustum

@MainActor
@Suite("Overlay bodies don't enlarge the shadow frustum (#183)")
struct ShadowFrustumOverlayTests {

    static let size = 160

    /// A ground slab and a box caster, seen near top-down so the cast shadow is visible.
    static func scene(withFarOverlay: Bool) -> [ViewportBody] {
        var ground = ViewportBody.box(
            id: "ground", width: 6, height: 0.2, depth: 6, color: SIMD4<Float>(0.8, 0.8, 0.8, 1))
        ground.transform.columns.3 = SIMD4(0, -1, 0, 1)
        let caster = ViewportBody.box(
            id: "caster", width: 1, height: 1, depth: 1, color: SIMD4<Float>(0.8, 0.4, 0.2, 1))
        guard withFarOverlay else { return [ground, caster] }
        // Far outside the view, so it changes no pixel itself, only the frustum (before #183).
        var gizmo = ViewportBody.box(
            id: "gizmo", width: 1, height: 1, depth: 1, color: SIMD4<Float>(0, 1, 0, 1))
        gizmo.transform.columns.3 = SIMD4(300, 0, 300, 1)
        gizmo.renderLayer = .overlay
        return [ground, caster, gizmo]
    }

    static var lighting: LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.7
        return lighting
    }

    static var camera: CameraState {
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: -1.45, axis: SIMD3<Float>(1, 0, 0))
        camera.distance = 9
        camera.pivot = SIMD3<Float>(0, -0.9, 0)
        return camera
    }

    @Test("ViewportRenderer: a far overlay body leaves the shadowed image unchanged")
    func liveRendererIgnoresOverlay() throws {
        func render(_ bodies: [ViewportBody], shadows: Bool = true) throws -> [UInt8] {
            var lighting = Self.lighting
            lighting.shadowsEnabled = shadows
            let pair = try makeRenderer(bodies: bodies, camera: Self.camera, lighting: lighting)
            guard
                let pixels = pair.renderer.renderHeadlessBGRA(
                    width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
            else { throw RenderUnavailable() }
            return pixels
        }
        let plain = try render(Self.scene(withFarOverlay: false))
        let unshadowed = try render(Self.scene(withFarOverlay: false), shadows: false)
        let withGizmo = try render(Self.scene(withFarOverlay: true))
        #expect(differingPixels(plain, unshadowed) > 200, "no visible shadow to compare")
        let changed = differingPixels(plain, withGizmo)
        #expect(changed == 0, "an off-screen overlay changed \(changed) shadowed pixels")
    }

    @Test("OffscreenRenderer: a far overlay body leaves the shadowed image unchanged")
    func offscreenRendererIgnoresOverlay() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let options = OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: Self.camera, displayMode: .shaded,
            lightingConfiguration: Self.lighting, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        var unshadowedOptions = options
        unshadowedOptions.lightingConfiguration.shadowsEnabled = false
        guard
            let plain = renderer.render(
                bodies: Self.scene(withFarOverlay: false), options: options),
            let unshadowed = renderer.render(
                bodies: Self.scene(withFarOverlay: false), options: unshadowedOptions),
            let withGizmo = renderer.render(
                bodies: Self.scene(withFarOverlay: true), options: options)
        else { throw RenderUnavailable() }
        #expect(differingPixels(bgra(plain), bgra(unshadowed)) > 200, "no visible shadow")
        let changed = differingPixels(bgra(plain), bgra(withGizmo))
        #expect(changed == 0, "an off-screen overlay changed \(changed) shadowed pixels")
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) / 4 }
        var n = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            var d = 0
            for c in 0..<3 { d = max(d, abs(Int(a[p + c]) - Int(b[p + c]))) }
            if d > 8 { n += 1 }
        }
        return n
    }

    private func bgra(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: info.rawValue)
            {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return buffer
    }
}

// MARK: - #184 overlapping picks

@Suite("FrameBufferPool trims what a burst leaves behind (#184)")
struct FrameBufferPoolTrimTests {

    @Test("Beyond maxRetainedBytes, the largest other free buffers are dropped")
    func trimsLargestOthers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FrameBufferPool(device: device, maxRetainedBytes: 64 * 1024)
        let big1 = try #require(pool.acquire(byteCount: 1 << 20))
        let big2 = try #require(pool.acquire(byteCount: 1 << 20))
        let small = try #require(pool.acquire(byteCount: 16))
        pool.release(small)
        pool.release(big1)
        // big1 is kept (the latest release); small fits beside it only under the cap, so it goes.
        #expect(pool.retainedBytes == big1.length)
        pool.release(big2)
        #expect(pool.retainedBytes == big2.length, "two full-size buffers were retained")
        // The kept buffer is still reused.
        #expect(pool.acquire(byteCount: 1 << 20) === big2)
    }

    @Test("Under the cap every released buffer is kept")
    func keepsUnderCap() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FrameBufferPool(device: device, maxRetainedBytes: 1 << 20)
        let a = try #require(pool.acquire(byteCount: 16))
        let b = try #require(pool.acquire(byteCount: 16))
        pool.release(a)
        pool.release(b)
        #expect(pool.retainedBytes == a.length + b.length)
    }
}

@MainActor
@Suite("Overlapping picks read back into their own buffers (#184)")
struct OverlappingPickTests {

    /// A quad left of centre and one right of it, seen head-on in a 160 x 120 frame.
    private func renderTwoQuads() throws -> ViewportRenderer {
        let pair = try makeRenderer(bodies: [quad(id: "left", x: -3), quad(id: "right", x: 3)])
        guard
            pair.renderer.renderHeadlessBGRA(
                width: 160, height: 120, backgroundColor: SIMD4(0, 0, 0, 1)) != nil
        else { throw RenderUnavailable() }
        return pair.renderer
    }

    /// Issues every request before any completes, then waits for all of them.
    private func overlapping<T: Sendable>(
        _ count: Int, _ issue: (Int, @escaping @Sendable (T) -> Void) -> Void
    ) async -> [Int: T] {
        await withCheckedContinuation { continuation in
            let collector = Collector<T>()
            for i in 0..<count {
                issue(i) { value in
                    MainActor.assumeIsolated {
                        collector.values[i] = value
                        if collector.values.count == count {
                            continuation.resume(returning: collector.values)
                        }
                    }
                }
            }
        }
    }

    @Test("Region picks issued back to back each return their own rectangle's bodies")
    func overlappingRegionPicks() async throws {
        let renderer = try renderTwoQuads()
        let rects = [
            CGRect(x: 0, y: 0, width: 70, height: 120), CGRect(x: 90, y: 0, width: 70, height: 120),
        ]
        for _ in 0..<8 {
            let ids = await overlapping(2) { (i, done: @escaping @Sendable (Set<String>) -> Void) in
                renderer.performRegionPick(rect: rects[i]) { done(Set($0.map(\.bodyID))) }
            }
            #expect(ids[0] == ["left"], "left rect read \(String(describing: ids[0]))")
            #expect(ids[1] == ["right"], "right rect read \(String(describing: ids[1]))")
        }
        // Buffers go back to the pool once read, so repeated picks don't keep allocating.
        #expect(renderer.pickReadbackPool.allocatedCount <= 4)
    }

    @Test("Exact picks issued back to back each return their own pixel's body")
    func overlappingExactPicks() async throws {
        let renderer = try renderTwoQuads()
        let pixels = [SIMD2(36, 60), SIMD2(124, 60)]
        for _ in 0..<8 {
            let ids = await overlapping(2) { (i, done: @escaping @Sendable (String?) -> Void) in
                renderer.performPick(at: pixels[i]) { done($0?.bodyID) }
            }
            #expect(ids[0] == "left", "left pixel read \(String(describing: ids[0]))")
            #expect(ids[1] == "right", "right pixel read \(String(describing: ids[1]))")
        }
    }
}

@MainActor
private final class Collector<T> {
    var values: [Int: T] = [:]
}
