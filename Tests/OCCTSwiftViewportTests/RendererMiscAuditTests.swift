// RendererMiscAuditTests.swift
// OCCTSwiftViewport Tests
//
// Regression tests for the renderer audit fixes in issue #136: stale buffers for emptied bodies
// (M10), the SSAO depth prepass (M11), depth-of-field autofocus (M12), MSAA clamping (L2), the
// clip-plane limit (L3), the screen-space selection outline (L4), triangleStyles count checks
// and re-upload (L9), and the dynamic pivot's world-space bounds.

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
private final class BodyStore {
    var bodies: [ViewportBody]
    init(_ bodies: [ViewportBody]) { self.bodies = bodies }
    var binding: Binding<[ViewportBody]> {
        Binding(get: { self.bodies }, set: { self.bodies = $0 })
    }
}

private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4<Float>(x, y, z, 1)
    return m
}

/// Quad in the z = 0 plane facing +Z, as interleaved vertex data.
private func quadBody(
    id: String, half: Float = 2, color: SIMD4<Float> = SIMD4<Float>(1, 0, 0, 1)
) -> ViewportBody {
    var vd: [Float] = []
    for c: SIMD2<Float> in [[-half, -half], [half, -half], [half, half], [-half, half]] {
        vd += [c.x, c.y, 0, 0, 0, 1]
    }
    return ViewportBody(
        id: id, vertexData: vd, indices: [0, 1, 2, 0, 2, 3], edges: [], color: color)
}

/// Camera on +Z looking down -Z at the origin.
private let frontCamera = CameraState(
    rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

@MainActor
private func makeLiveRenderer(
    store: BodyStore,
    configure: (inout ViewportConfiguration) -> Void = { _ in },
    controllerSetup: (ViewportController) -> Void = { _ in }
) -> (ViewportController, ViewportRenderer)? {
    var config = ViewportConfiguration(
        initialCameraState: frontCamera,
        lightingConfiguration: .flat,
        showViewCube: false,
        showGrid: false,
        backgroundColor: SIMD4<Float>(0, 0, 0, 1),
        enableSilhouettes: false
    )
    configure(&config)
    let controller = ViewportController(configuration: config)
    controller.showGrid = false
    controller.showAxes = false
    controller.lightingConfiguration = config.lightingConfiguration
    controllerSetup(controller)
    guard let renderer = ViewportRenderer(controller: controller, bodies: store.binding) else {
        return nil
    }
    return (controller, renderer)
}

private let liveW = 160
private let liveH = 120

@MainActor
private func renderLive(_ renderer: ViewportRenderer, frames: Int = 1) -> [UInt8]? {
    renderer.renderHeadlessBGRA(
        width: liveW, height: liveH, backgroundColor: SIMD4<Float>(0, 0, 0, 1),
        frameCount: frames)
}

private func centerBGRA(_ px: [UInt8], width: Int, height: Int) -> (b: Int, g: Int, r: Int) {
    let o = ((height / 2) * width + width / 2) * 4
    return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
}

private func maxDelta(_ a: [UInt8], _ b: [UInt8]) -> Int {
    guard a.count == b.count else { return 255 }
    var m = 0
    for i in 0..<a.count { m = max(m, abs(Int(a[i]) - Int(b[i]))) }
    return m
}

// MARK: - M10: stale buffers for an emptied body

@MainActor
@Suite("Renderer audit #136 — M10 emptied bodies")
struct EmptiedBodyTests {

    @Test("OffscreenRenderer stops drawing a body that keeps its id but loses its geometry")
    func offscreenDropsEmptiedBody() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var opts = OffscreenRenderOptions(
            width: 64, height: 64, cameraState: frontCamera,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            appearance: .light)
        opts.displayMode = .unlit

        let full = try #require(renderer.render(bodies: [quadBody(id: "a")], options: opts))
        #expect(centerPixel(full).r > 200, "the quad should cover the centre first")

        let emptied = ViewportBody(
            id: "a", vertexData: [], indices: [], edges: [], color: SIMD4<Float>(1, 0, 0, 1))
        let after = try #require(renderer.render(bodies: [emptied], options: opts))
        let c = centerPixel(after)
        #expect(c.r < 10 && c.g < 10 && c.b < 10, "emptied body still drew: \(c)")
    }

    @Test("OffscreenRenderer prunes cached buffers for bodies no longer rendered")
    func offscreenPrunesCache() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let opts = OffscreenRenderOptions(
            width: 32, height: 32, cameraState: frontCamera, appearance: .light)
        _ = renderer.render(bodies: [quadBody(id: "a"), quadBody(id: "b")], options: opts)
        #expect(renderer.cachedBodyCount == 2)
        _ = renderer.render(bodies: [quadBody(id: "a")], options: opts)
        #expect(renderer.cachedBodyCount == 1)
    }

    @Test("ViewportRenderer stops drawing a body that keeps its id but loses its geometry")
    func liveDropsEmptiedBody() throws {
        let store = BodyStore([quadBody(id: "a")])
        guard let (controller, renderer) = makeLiveRenderer(store: store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = controller
        let first = try #require(renderLive(renderer))
        #expect(centerBGRA(first, width: liveW, height: liveH).r > 100)

        store.bodies = [
            ViewportBody(
                id: "a", vertexData: [], indices: [], edges: [], color: SIMD4<Float>(1, 0, 0, 1))
        ]
        let after = try #require(renderLive(renderer))

        let emptyStore = BodyStore([])
        let (emptyController, emptyRenderer) = try #require(makeLiveRenderer(store: emptyStore))
        _ = emptyController
        let reference = try #require(renderLive(emptyRenderer))
        #expect(maxDelta(after, reference) == 0, "emptied body still drew")
    }
}

// MARK: - M11: SSAO / silhouette depth prepass

@MainActor
@Suite("Renderer audit #136 — M11 SSAO depth prepass")
struct SSAODepthPrepassTests {

    @Test("Only opaque geometry-layer mesh bodies write SSAO depth")
    func classification() {
        let opaque = quadBody(id: "o")
        #expect(ViewportRenderer.writesSSAODepth(opaque))

        var overlay = quadBody(id: "ov")
        overlay.renderLayer = .overlay
        #expect(!ViewportRenderer.writesSSAODepth(overlay))

        let glass = quadBody(id: "g", color: SIMD4<Float>(0.5, 0.8, 1, 0.4))
        #expect(!ViewportRenderer.writesSSAODepth(glass))

        var points = quadBody(id: "p")
        points.primitiveKind = .point
        #expect(!ViewportRenderer.writesSSAODepth(points))
    }

    /// Renders `body` alone with silhouettes on and off; the two frames match only when the body
    /// stays out of the depth the composite reads.
    private func silhouetteDelta(_ body: ViewportBody) throws -> Int? {
        func frame(silhouettes: Bool) -> [UInt8]? {
            let store = BodyStore([body])
            guard
                let (controller, renderer) = makeLiveRenderer(
                    store: store, configure: { $0.enableSilhouettes = silhouettes })
            else { return nil }
            _ = controller
            return renderLive(renderer)
        }
        guard let on = frame(silhouettes: true), let off = frame(silhouettes: false) else {
            return nil
        }
        return maxDelta(on, off)
    }

    @Test("Silhouettes change an opaque body (control)")
    func opaqueGetsSilhouettes() throws {
        guard
            let delta = try silhouetteDelta(.sphere(id: "s", radius: 3, color: [0.8, 0.8, 0.8, 1]))
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(delta > 0)
    }

    @Test("Translucent bodies get no silhouette or AO")
    func translucentExcluded() throws {
        guard
            let delta = try silhouetteDelta(
                .sphere(id: "s", radius: 3, color: [0.8, 0.8, 0.8, 0.4]))
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(delta == 0, "translucent body was post-processed (delta \(delta))")
    }

    @Test("Overlay-layer bodies get no silhouette or AO")
    func overlayExcluded() throws {
        var gizmo = ViewportBody.sphere(id: "s", radius: 3, color: [0.8, 0.8, 0.8, 1])
        gizmo.renderLayer = .overlay
        guard let delta = try silhouetteDelta(gizmo) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(delta == 0, "overlay body was post-processed (delta \(delta))")
    }
}

// MARK: - M12: depth-of-field autofocus

@Suite("Renderer audit #136 — M12 DoF autofocus")
struct DoFAutofocusTests {

    @Test("Autofocus uses world-space bounds")
    func usesTransform() {
        var body = ViewportBody.box(id: "b", width: 1, height: 1, depth: 1, color: [1, 1, 1, 1])
        body.transform = translation(0, 0, -10)
        let d = ViewportRenderer.autoFocusDistance(
            bodies: [body], cameraPosition: [0, 0, 10], fallback: 1)
        #expect(abs(d - 20) < 1e-4, "focused at \(d), expected 20")
    }

    @Test("Autofocus ignores overlay and hidden bodies, and falls back when nothing has bounds")
    func ignoresOverlayAndFallsBack() {
        var gizmo = ViewportBody.box(id: "g", width: 1, height: 1, depth: 1, color: [1, 1, 1, 1])
        gizmo.renderLayer = .overlay
        gizmo.transform = translation(0, 0, -100)
        var hidden = ViewportBody.box(id: "h", width: 1, height: 1, depth: 1, color: [1, 1, 1, 1])
        hidden.isVisible = false
        let d = ViewportRenderer.autoFocusDistance(
            bodies: [gizmo, hidden], cameraPosition: [0, 0, 10], fallback: 7)
        #expect(d == 7)
    }
}

// MARK: - L2: MSAA clamping on the live renderer

@MainActor
@Suite("Renderer audit #136 — L2 live MSAA clamp")
struct LiveSampleCountTests {

    @Test("An unsupported msaaSampleCount is clamped instead of failing renderer creation")
    func clampsUnsupportedCount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for requested in [3, 16, 0] {
            let store = BodyStore([quadBody(id: "a")])
            let pair = makeLiveRenderer(store: store, configure: { $0.msaaSampleCount = requested })
            let renderer = try #require(pair?.1, "renderer nil for msaaSampleCount \(requested)")
            let expected = OffscreenRenderer.supportedSampleCount(requested) {
                device.supportsTextureSampleCount($0)
            }
            #expect(renderer.pipelineSampleCount == expected)
            #expect(renderLive(renderer) != nil)
        }
    }
}

// MARK: - L3: clip-plane limit

@Suite("Renderer audit #136 — L3 clip-plane limit")
struct ClipPlaneLimitTests {

    @Test("At most maxActivePlanes enabled planes apply; extras are counted as dropped")
    func activePlanes() {
        var planes = (0..<6).map { ClipPlane(normal: [1, 0, 0], distance: Float($0)) }
        planes.insert(ClipPlane(normal: [0, 1, 0], distance: 0, isEnabled: false), at: 1)
        let result = ClipPlane.activePlanes(in: planes)
        #expect(ClipPlane.maxActivePlanes == 4)
        #expect(result.applied.count == 4)
        #expect(result.applied.allSatisfy { $0.isEnabled })
        #expect(result.applied.map(\.distance) == [0, 1, 2, 3])
        #expect(result.dropped == 2)
    }

    @Test("Disabled planes don't count toward the limit")
    func disabledDontCount() {
        let planes =
            [ClipPlane(isEnabled: false), ClipPlane(isEnabled: false)]
            + (0..<4).map { ClipPlane(normal: [0, 0, 1], distance: Float($0)) }
        let result = ClipPlane.activePlanes(in: planes)
        #expect(result.applied.count == 4)
        #expect(result.dropped == 0)
    }
}

// MARK: - L4: screen-space selection outline

@MainActor
@Suite("Renderer audit #136 — L4 selection outline")
struct SelectionOutlineTests {

    private static let outlineGreen = SIMD3<Float>(0, 1, 0)

    /// Counts outline-coloured pixels around a selected sphere of `radius`, framed to the same
    /// screen size whatever its world size.
    private func outlinePixels(radius: Float, width: Float = 3, hover: Bool = false) -> Int? {
        let sphere = ViewportBody.sphere(id: "s", radius: radius, color: [1, 0, 0, 1])
        let store = BodyStore([sphere])
        var camera = frontCamera
        if let fitted = camera.fit(
            to: [sphere], aspectRatio: Float(liveW) / Float(liveH), padding: 1.6)
        {
            camera = fitted
        }
        guard
            let (controller, renderer) = makeLiveRenderer(
                store: store,
                configure: {
                    $0.initialCameraState = camera
                    $0.minDistance = 1e-6
                    $0.selectionOutline = SelectionOutlineStyle(
                        color: Self.outlineGreen, width: width)
                    $0.hoverOutline = SelectionOutlineStyle(color: [0, 0, 1], width: width)
                    $0.lightingConfiguration.enableSSAO = false
                    $0.lightingConfiguration.shadowsEnabled = false
                },
                controllerSetup: {
                    if hover { $0.hoveredBodyID = "s" } else { $0.selectedBodyIDs = ["s"] }
                }),
            let px = renderLive(renderer)
        else { return nil }
        _ = controller
        var n = 0
        for p in stride(from: 0, to: px.count, by: 4) {
            let (b, g, r) = (Int(px[p]), Int(px[p + 1]), Int(px[p + 2]))
            if hover {
                if b > 150 && g < 80 && r < 80 { n += 1 }
            } else if g > 150 && r < 80 && b < 80 {
                n += 1
            }
        }
        return n
    }

    @Test("Outline width is in pixels, independent of model scale")
    func scaleIndependent() throws {
        guard let tiny = outlinePixels(radius: 0.01), let huge = outlinePixels(radius: 500) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(tiny > 50, "tiny part has almost no outline (\(tiny) px)")
        #expect(huge > 50, "huge part has almost no outline (\(huge) px)")
        let ratio = Double(max(tiny, huge)) / Double(max(min(tiny, huge), 1))
        #expect(ratio < 1.25, "outline pixel counts differ by scale: \(tiny) vs \(huge)")
    }

    @Test("Wider outline covers more pixels; zero width hides it")
    func widthIsHonoured() throws {
        guard let thin = outlinePixels(radius: 1, width: 2),
            let thick = outlinePixels(radius: 1, width: 6),
            let none = outlinePixels(radius: 1, width: 0)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(thick > thin * 2, "6 px (\(thick)) should be well over twice 2 px (\(thin))")
        #expect(none == 0)
    }

    @Test("Hover outline uses the configured hover colour")
    func hoverColour() throws {
        guard let hover = outlinePixels(radius: 1, hover: true) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(hover > 50)
    }

    @Test("Defaults keep today's colours")
    func defaults() {
        let config = ViewportConfiguration()
        #expect(config.selectionOutline.color == SIMD3<Float>(0.1, 0.5, 1.0))
        #expect(config.hoverOutline.color == SIMD3<Float>(0.4, 0.7, 1.0))
        #expect(config.selectionOutline.width == 3)
        #expect(config.hoverOutline.width == 3)
    }
}

// MARK: - L9: triangleStyles count

@Suite("Renderer audit #136 — L9 triangleStyles count")
struct TriangleStylesCountTests {

    @Test("Only a non-empty, exactly matching triangleStyles array is used")
    func matching() {
        #expect(ViewportRenderer.triangleStylesMatch(styleCount: 4, triangleCount: 4))
        #expect(!ViewportRenderer.triangleStylesMatch(styleCount: 3, triangleCount: 4))
        #expect(!ViewportRenderer.triangleStylesMatch(styleCount: 5, triangleCount: 4))
        #expect(!ViewportRenderer.triangleStylesMatch(styleCount: 0, triangleCount: 4))
        #expect(!ViewportRenderer.triangleStylesMatch(styleCount: 0, triangleCount: 0))
    }
}

@MainActor
@Suite("Renderer audit #136 — L9 triangleStyles mutation")
struct TriangleStylesMutationTests {

    @Test("Reassigning triangleStyles on an existing body re-uploads the style buffer")
    func mutationIsPickedUp() throws {
        let store = BodyStore([quadBody(id: "a", color: [0.5, 0.5, 0.5, 1])])
        guard let (controller, renderer) = makeLiveRenderer(store: store) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        _ = controller
        let before = try #require(renderLive(renderer))

        let generation = store.bodies[0].generation
        store.bodies[0].triangleStyles = Array(
            repeating: TriangleStyle(color: [0, 1, 0, 1]), count: 2)
        #expect(store.bodies[0].generation == generation, "geometry generation should not move")
        let after = try #require(renderLive(renderer))

        // Reference: a fresh renderer that sees the styled body from its first frame.
        let fresh = BodyStore(store.bodies)
        let (freshController, freshRenderer) = try #require(makeLiveRenderer(store: fresh))
        _ = freshController
        let reference = try #require(renderLive(freshRenderer))

        #expect(maxDelta(before, after) > 0, "highlight never appeared")
        #expect(maxDelta(after, reference) == 0)

        // Clearing the styles removes the highlight again.
        store.bodies[0].triangleStyles = []
        let cleared = try #require(renderLive(renderer))
        #expect(maxDelta(cleared, before) == 0)
    }
}

// MARK: - Dynamic pivot: world-space scene bounds

@MainActor
@Suite("Renderer audit #136 — dynamic pivot world bounds")
struct PivotWorldBoundsTests {

    private let farCamera = CameraState(distance: 1000)
    private let config = DynamicPivotConfiguration(zoomThreshold: 0.5, blendBand: 0.3)

    @Test("Zoomed-out pivot is the world-space centre of a transformed body")
    func transformedBody() throws {
        var body = ViewportBody.box(id: "b")
        body.transform = translation(50, 0, 0)
        let pivot = try #require(
            PivotStrategy().computePivot(
                cameraState: farCamera, bodies: [body], aspectRatio: 1, config: config))
        #expect(simd_distance(pivot, [50, 0, 0]) < 1e-3, "pivot \(pivot)")
    }

    @Test("Moving a body by transform alone moves the pivot (no stale cache)")
    func transformOnlyChange() throws {
        let strategy = PivotStrategy()
        var body = ViewportBody.box(id: "b")
        _ = strategy.computePivot(
            cameraState: farCamera, bodies: [body], aspectRatio: 1, config: config)
        let generation = body.generation
        body.transform = translation(0, 0, -30)
        #expect(body.generation == generation)
        let pivot = try #require(
            strategy.computePivot(
                cameraState: farCamera, bodies: [body], aspectRatio: 1, config: config))
        #expect(simd_distance(pivot, [0, 0, -30]) < 1e-3, "pivot \(pivot)")
    }
}

// MARK: - Pixel helper

private func centerPixel(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
    let w = image.width
    let h = image.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(
        data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let o = ((h / 2) * w + w / 2) * 4
    return (Int(buf[o]), Int(buf[o + 1]), Int(buf[o + 2]))
}
