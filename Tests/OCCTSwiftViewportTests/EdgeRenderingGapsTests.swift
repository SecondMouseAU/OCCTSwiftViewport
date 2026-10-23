// EdgeRenderingGapsTests.swift
// OCCTSwiftViewport Tests
//
// Edge rendering gaps from the issue #136 audit:
// - Quad-expanded edges honour edge intensity (`ViewportController.edgeIntensity`,
//   `OffscreenRenderOptions.edgeIntensity`) and carry the native path's depth bias, so an edge
//   lying on a face is not lost to z-fighting.
// - Analytic arcs and overlay-layer edges honour `EdgeLineConfiguration` width and dashes.
// - Edge and arc pick footprints match the visible edge width; the vertex pick sprite is 8 pt,
//   not 8 drawable pixels.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import SwiftUI
import Testing
import UniformTypeIdentifiers
import simd

@testable import OCCTSwiftViewport

// MARK: - Pure buffer layout

@Suite("Arc quad-strip generation")
struct ArcQuadEdgeVertexTests {

    private let circle = ViewportArc.circle(
        center: SIMD3<Float>(1, 2, 3), radius: 2,
        xAxis: SIMD3<Float>(1, 0, 0), yAxis: SIMD3<Float>(0, 1, 0))

    @Test("Sampling an arc yields segmentCount + 1 points from start to end")
    func sampledPolyline() {
        let points = RendererSharedBuffers.sampledArcPolyline(circle, segmentCount: 8)
        #expect(points.count == 9)
        #expect(simd_distance(points[0], circle.point(at: 0)) < 1e-5)
        #expect(simd_distance(points[8], circle.point(at: 1)) < 1e-5)
        #expect(simd_distance(points[2], circle.point(at: 0.25)) < 1e-5)
    }

    @Test("An arc expands to six stride-9 vertices per segment with continuous arc length")
    func arcQuadLayout() {
        let segments = 12
        let flat = RendererSharedBuffers.arcQuadEdgeVertices(circle, segmentCount: segments)
        #expect(flat.count == segments * 6 * 9)

        // Each segment's end arc length is the next segment's start arc length, and the last one
        // is the polyline's total chord length — so dashes run on round the whole arc.
        let chord = simd_distance(circle.point(at: 0), circle.point(at: 1.0 / Float(segments)))
        for s in 0..<segments {
            let startArc = flat[(s * 6) * 9 + 3]
            let endArc = flat[(s * 6 + 5) * 9 + 3]
            #expect(abs(startArc - Float(s) * chord) < 1e-4)
            #expect(abs(endArc - Float(s + 1) * chord) < 1e-4)
        }
        // First vertex sits on the arc's start point.
        let first = SIMD3<Float>(flat[0], flat[1], flat[2])
        #expect(simd_distance(first, circle.point(at: 0)) < 1e-5)
    }

    @Test("A zero-length segment keeps its six vertices so segment k starts at vertex 6k")
    func zeroLengthSegmentKeepsSlot() {
        let polyline: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0),
        ]
        let flat = RendererSharedBuffers.quadEdgeLineVertices(from: [polyline])
        // Two segments → twelve vertices, matching the native buffer's two line segments, so the
        // quad pick shader's `primitive_id / 6` is the same segment index the line pick reports.
        #expect(flat.count == 2 * 6 * 9)
        #expect(
            RendererSharedBuffers.nativeEdgeLineVertices(from: [polyline]).count / 6 / 2
                == flat.count / 9 / 6)
        // The second segment's start vertex is the (1, 0, 0) segment's start, (0, 0, 0).
        let secondStart = (1 * 6) * 9
        #expect(Array(flat[secondStart..<secondStart + 3]) == [0, 0, 0])
        #expect(Array(flat[secondStart + 6..<secondStart + 9]) == [1, 0, 0])
        // The zero-length one has a finite direction (no NaN reaching the shader).
        #expect(flat[6...8].allSatisfy { $0.isFinite })
    }

    @Test("EdgeUniforms carries width, edge intensity and clip planes from the scene uniforms")
    func edgeUniformsFromSceneUniforms() {
        var uniforms = Uniforms(
            viewProjection: matrix_identity_float4x4,
            viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero,
            nearPlane: 0.1,
            farPlane: 100,
            lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4,
            shadowParams: SIMD4<Float>(0, 0, 0, 0.35),
            shadowParams2: .zero,
            iblParams: .zero,
            clipPlaneCount: 2,
            unlit: false
        )
        uniforms.modelMatrix = matrix_identity_float4x4
        let config = EdgeLineConfiguration(
            width: 4, dashPattern: EdgeLineDashPattern(kind: .dashed, dashLength: 3, gapLength: 2))
        let edge = EdgeUniforms(
            uniforms: uniforms, configuration: config, viewportSize: SIMD2(0, 50))
        #expect(edge.edgeParams.x == 4)
        #expect(edge.edgeParams.y == 0.35)
        #expect(edge.clipPlaneCount == 2)
        #expect(edge.dashPatternType == EdgeLineDashKind.dashed.rawValue)
        #expect(edge.dashPatternParams.x == 3 && edge.dashPatternParams.y == 2)
        #expect(edge.viewportSize == SIMD2(1, 50))  // guarded against a zero-size target
        #expect(
            EdgeUniforms(
                uniforms: uniforms, configuration: config, viewportSize: SIMD2(10, 10), width: 9
            ).edgeParams.x == 9)
    }
}

// MARK: - Arc buffer pool

@Suite("Per-frame buffer pool")
struct FrameBufferPoolTests {

    @Test("A buffer still in flight is never handed out again until it is released")
    func inFlightBuffersAreNotReused() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FrameBufferPool(device: device)
        let first = try #require(pool.acquire(byteCount: 64))
        let second = try #require(pool.acquire(byteCount: 64))
        #expect(first !== second, "two in-flight frames shared one arc buffer")
        pool.release(first)
        let third = try #require(pool.acquire(byteCount: 64))
        #expect(third === first, "a released buffer was not reused")
        #expect(pool.allocatedCount == 2)
    }

    @Test("A released buffer too small for the request is skipped, not overrun")
    func smallBufferIsSkipped() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = FrameBufferPool(device: device)
        let small = try #require(pool.acquire(byteCount: 64))
        pool.release(small)
        let big = try #require(pool.acquire(byteCount: 64 * 1024))
        #expect(big !== small)
        #expect(big.length >= 64 * 1024)
    }
}

// MARK: - Rendering

@MainActor
@Suite("Edge rendering gaps (issue #136)")
struct EdgeRenderingGapsTests {

    // Camera at +Z looking down -Z at the origin; 10 world units span the 128 px frame.
    static let size = 128
    static let pxPerUnit = Float(size) / 10
    static let orthoCamera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero,
        orthographicScale: 10,
        isOrthographic: true
    )

    private struct RenderUnavailable: Error {}

    // MARK: Edge intensity (M6)

    @Test("Quad edges honour edge intensity: 0 hides a meshed body's edges")
    func quadEdgesHonourEdgeIntensity() throws {
        let visible = try offscreenRowLitCount(edgeIntensity: 1)
        let hidden = try offscreenRowLitCount(edgeIntensity: 0)
        #expect(visible > 40, "edge not drawn at intensity 1 (\(visible) lit pixels)")
        #expect(hidden == 0, "edge still drawn at intensity 0 (\(hidden) lit pixels)")
    }

    @Test("The live renderer's quad edges honour ViewportController.edgeIntensity")
    func liveQuadEdgesHonourEdgeIntensity() throws {
        let body = Self.meshedBodyWithLine()
        let lit = try liveRender(bodies: [body], edge: EdgeLineConfiguration(width: 3))
        let dim = try liveRender(
            bodies: [body], edge: EdgeLineConfiguration(width: 3), edgeIntensity: 0)
        let row = Self.size / 2
        #expect(Self.litCount(lit, row: row) > 40)
        #expect(Self.litCount(dim, row: row) == 0)
    }

    // MARK: Depth bias (M6)

    @Test(
        "A wide quad edge lying on a tilted face keeps its full width",
        arguments: [false, true])
    func coplanarEdgeWinsOverFace(acrossSlope: Bool) throws {
        let image = try Self.renderCoplanar(acrossSlope: acrossSlope)
        let (pixels, width, height) = Self.readBGRA(image)
        // Without a depth bias, the face wins part of the edge's pixels, so the edge comes out
        // thinner than its 4 px. Measure its thickness across its length.
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return max(pixels[i], pixels[i + 1], pixels[i + 2]) < 110
        }
        var thickness: [Int] = []
        for along in 0..<(acrossSlope ? width : height) {
            let count = (0..<(acrossSlope ? height : width)).filter { across in
                acrossSlope ? dark(along, across) : dark(across, along)
            }.count
            if count > 0 { thickness.append(count) }
        }
        let mean = Float(thickness.reduce(0, +)) / Float(max(thickness.count, 1))
        #expect(thickness.count > 20, "edge spans only \(thickness.count) pixels")
        #expect(mean >= 3.5, "a 4 px edge on a face is \(mean) px thick on average")
    }

    @Test("The edge depth bias does not show an edge through a face just in front of it")
    func hiddenEdgeStaysHidden() throws {
        // A white face at z = 1.5 hides an edge at z = 0. A constant NDC bias (the native path's
        // 0.0001) spans world units under a wide near/far range, as on a first frame, and drew
        // the edge through the face.
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 1.5, 0, 0, 1] }
        let verts = v(-5, -2) + v(5, -2) + v(5, 2) + v(-5, 2)
        let body = ViewportBody(
            id: "plate", vertexData: verts, indices: [0, 1, 2, 0, 2, 3],
            edges: [[SIMD3(-3, 0, 0), SIMD3(3, 0, 0)]], color: SIMD4<Float>(1, 1, 1, 1))
        var camera = CameraState()
        camera.distance = 400
        camera.fieldOfView = 2
        let pair = try makeLive(
            bodies: [body], edge: EdgeLineConfiguration(width: 4), camera: camera,
            background: SIMD4(1, 1, 1, 1))
        guard
            let pixels = pair.renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(1, 1, 1, 1))
        else { throw RenderUnavailable() }
        let dark = (0..<Self.size).filter { x in
            let i = (Self.size / 2 * Self.size + x) * 4
            return max(pixels[i], pixels[i + 1], pixels[i + 2]) < 110
        }.count
        #expect(dark == 0, "hidden edge drew \(dark) pixels through the face")
    }

    // MARK: Arcs and overlay edges (M7)

    @Test("Arcs are drawn at the configured edge width")
    func arcsHonourWidth() throws {
        let pixels = try liveRender(
            bodies: [Self.arcBody()], edge: EdgeLineConfiguration(width: 7))
        // Radial scans across the circle at several angles: each crossing is ~7 px thick.
        let thickness = Self.radialThickness(pixels, radius: 3)
        #expect(thickness.min() ?? 0 >= 5, "arc thickness \(thickness)")
    }

    @Test("Arcs are dashed by the configured dash pattern")
    func arcsHonourDashes() throws {
        let solid = try liveRender(
            bodies: [Self.arcBody()], edge: EdgeLineConfiguration(width: 5))
        let dashed = try liveRender(
            bodies: [Self.arcBody()],
            edge: EdgeLineConfiguration(
                width: 5,
                dashPattern: EdgeLineDashPattern(kind: .dashed, dashLength: 1, gapLength: 1)))
        let solidLit = Self.circleLitFraction(solid, radius: 3)
        let dashedLit = Self.circleLitFraction(dashed, radius: 3)
        #expect(solidLit > 0.95, "solid arc only \(solidLit) lit")
        #expect(dashedLit > 0.3 && dashedLit < 0.7, "dashed arc \(dashedLit) lit")
    }

    @Test("Overlay-layer edges are drawn at the configured edge width")
    func overlayEdgesHonourWidth() throws {
        var body = Self.wire()
        body.renderLayer = .overlay
        let pixels = try liveRender(bodies: [body], edge: EdgeLineConfiguration(width: 7))
        let column = (0..<Self.size).filter { y in
            let i = (y * Self.size + Self.size / 2 + 20) * 4
            return max(pixels[i], pixels[i + 1], pixels[i + 2]) > 100
        }
        #expect(column.count >= 6, "overlay edge is \(column.count) px thick")
    }

    @Test("Arc frames take buffers from the pool and return them, so it stays small")
    func arcBuffersAreRecycled() throws {
        let pair = try makeLive(bodies: [Self.arcBody()], edge: EdgeLineConfiguration(width: 5))
        for _ in 0..<12 {
            _ = pair.renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        }
        // Line + quad buffers per frame; each headless frame completes before the next, so a
        // handful of buffers serve every frame instead of one per frame.
        let allocated = pair.renderer.arcBufferPool.allocatedCount
        #expect(allocated >= 2 && allocated <= 6, "\(allocated) arc buffers for 12 frames")
    }

    // MARK: Pick footprints (L5)

    @Test("Edge picks cover the visible edge width and report the segment index")
    func edgePickFollowsWidth() async throws {
        var body = Self.wire()
        body.edges = [[SIMD3(-4, 0, 0), SIMD3(0, 0, 0), SIMD3(4, 0, 0)]]
        body.edgeIndices = [0, 1]
        let renderer = try makeLive(bodies: [body], edge: EdgeLineConfiguration(width: 9))
        _ = renderer.renderer.renderHeadlessBGRA(
            width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        let mid = Self.size / 2
        let right = await Self.pick(renderer.renderer, at: SIMD2(mid + 20, mid + 3))
        let left = await Self.pick(renderer.renderer, at: SIMD2(mid - 20, mid - 3))
        #expect(
            right?.kind == .edge && right?.triangleIndex == 1,
            "right: \(String(describing: right))")
        #expect(
            left?.kind == .edge && left?.triangleIndex == 0,
            "left: \(String(describing: left))")
        // Well outside the 9 px band, nothing.
        #expect(await Self.pick(renderer.renderer, at: SIMD2(mid + 20, mid + 12)) == nil)
    }

    @Test("Arc picks cover the visible arc width and report the arc index")
    func arcPickFollowsWidth() async throws {
        let renderer = try makeLive(
            bodies: [Self.arcBody()], edge: EdgeLineConfiguration(width: 9))
        _ = renderer.renderer.renderHeadlessBGRA(
            width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        // The circle's rightmost point, 3 px outward.
        let x = Self.size / 2 + Int((3 * Self.pxPerUnit).rounded()) + 3
        let hit = await Self.pick(renderer.renderer, at: SIMD2(x, Self.size / 2))
        #expect(hit?.kind == .edge && hit?.triangleIndex == 0, "\(String(describing: hit))")
    }

    @Test("The vertex pick sprite is 8 pt: 16 drawable pixels at content scale 2")
    func vertexSpriteScalesWithContentScale() async throws {
        let body = ViewportBody(
            id: "verts", vertexData: [], indices: [], edges: [],
            vertices: [SIMD3<Float>(0, 0, 0)], color: SIMD4<Float>(1, 1, 1, 1))
        let renderer = try makeLive(bodies: [body], edge: .default)
        renderer.renderer.pickContentScale = 2
        _ = renderer.renderer.renderHeadlessBGRA(
            width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        let mid = Self.size / 2
        // 6 px off-centre: inside a 16 px sprite, outside the old fixed 8 px one.
        let hit = await Self.pick(renderer.renderer, at: SIMD2(mid + 6, mid))
        #expect(hit?.kind == .vertex, "\(String(describing: hit))")
        #expect(await Self.pick(renderer.renderer, at: SIMD2(mid + 12, mid)) == nil)
    }

    // MARK: Before/after images

    /// Writes the review PNGs when `EDGE_GAPS_PNG_DIR` is set; otherwise a no-op.
    @Test("Dump review images when EDGE_GAPS_PNG_DIR is set")
    func dumpImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["EDGE_GAPS_PNG_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Wide dashed edges on a box with arcs on its front face, live renderer.
        var box = ViewportBody.box(
            id: "box", width: 6, height: 6, depth: 2, color: SIMD4<Float>(0.75, 0.75, 0.78, 1))
        box.arcs = [
            .circle(
                center: SIMD3(0, 0, 1), radius: 2, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            .circle(
                center: SIMD3(0, 0, 1), radius: 1, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
        ]
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: 0.5, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        camera.distance = 16
        let size = 512
        let edge = EdgeLineConfiguration(
            width: 4,
            dashPattern: EdgeLineDashPattern(kind: .dashed, dashLength: 0.4, gapLength: 0.25))
        let pair = try makeLive(
            bodies: [box], edge: edge, camera: camera, background: SIMD4(1, 1, 1, 1))
        if let image = pair.renderer.renderHeadless(
            width: size, height: size, backgroundColor: SIMD4(1, 1, 1, 1))
        {
            try Self.writePNG(image, to: url.appendingPathComponent("wide-dashed-arcs.png"))
        }

        for acrossSlope in [false, true] {
            let name =
                acrossSlope ? "coplanar-edge-across-slope.png" : "coplanar-edge-into-depth.png"
            try Self.writePNG(
                Self.renderCoplanar(size: 512, acrossSlope: acrossSlope),
                to: url.appendingPathComponent(name))
        }
    }

    // MARK: - Scenes

    /// A horizontal edge-only polyline through the frame centre.
    static func wire() -> ViewportBody {
        ViewportBody(
            id: "wire", vertexData: [], indices: [],
            edges: [[SIMD3(-4, 0, 0), SIMD3(4, 0, 0)]], color: SIMD4<Float>(1, 1, 1, 1))
    }

    /// An edge-only body holding one analytic circle of radius 3 about the origin.
    static func arcBody() -> ViewportBody {
        var body = ViewportBody(
            id: "arc", vertexData: [], indices: [], edges: [], color: SIMD4<Float>(1, 1, 1, 1))
        body.arcs = [
            .circle(center: .zero, radius: 3, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        ]
        return body
    }

    /// A dark quad well away from a horizontal line, so the line row is background except for
    /// the edge, and the edge takes the contrast edge colour (not the edge-only body colour).
    static func meshedBodyWithLine() -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 1, 0, 0, 1] }
        let verts = v(-1, 3) + v(1, 3) + v(1, 4) + v(-1, 4)
        return ViewportBody(
            id: "meshed", vertexData: verts, indices: [0, 1, 2, 0, 2, 3],
            edges: [[SIMD3(-4, 0, 0), SIMD3(4, 0, 0)]], color: SIMD4<Float>(0.1, 0.1, 0.1, 1))
    }

    /// A white face tilted away from a perspective camera, with an edge lying on it that runs
    /// into depth.
    /// `acrossSlope` lays the edge horizontally on screen, across the face's depth slope, rather
    /// than running up the screen and into depth.
    static func renderCoplanar(size: Int = 128, acrossSlope: Bool = false) throws -> CGImage {
        guard let renderer = OffscreenRenderer() else { throw RenderUnavailable() }
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        let verts = v(-7, -9) + v(13, -5) + v(9, 11) + v(-11, 6)
        let plane = ViewportBody(
            id: "plane", vertexData: verts, indices: [0, 1, 2, 0, 2, 3],
            edges: acrossSlope
                ? [[SIMD3(-3, 0.1, 0), SIMD3(3, -0.1, 0)]]
                : [[SIMD3(0.1, -3, 0), SIMD3(-0.1, 3, 0)]],
            color: SIMD4<Float>(1, 1, 1, 1))
        let camera = CameraState(
            rotation: simd_quatf(angle: 0.6, axis: SIMD3<Float>(1, 0, 0)),
            distance: 30, pivot: .zero, fieldOfView: 30)
        let options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera, displayMode: .shadedWithEdges,
            lightingConfiguration: .flat, backgroundColor: SIMD4<Float>(1, 1, 1, 1),
            msaaSampleCount: 1,
            edgeLineConfiguration: EdgeLineConfiguration(width: 4 * Float(size) / 128))
        guard let image = renderer.render(bodies: [plane], options: options) else {
            throw RenderUnavailable()
        }
        return image
    }

    // MARK: - Helpers

    private func offscreenRowLitCount(edgeIntensity: Float) throws -> Int {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        let options = OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: Self.orthoCamera,
            displayMode: .shadedWithEdges, backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            edgeLineConfiguration: EdgeLineConfiguration(width: 3),
            edgeIntensity: edgeIntensity)
        guard let image = renderer.render(bodies: [Self.meshedBodyWithLine()], options: options)
        else {
            Issue.record("renderer returned nil image")
            throw RenderUnavailable()
        }
        let (pixels, _, _) = Self.readBGRA(image)
        return Self.litCount(pixels, row: Self.size / 2)
    }

    private func makeLive(
        bodies: [ViewportBody],
        edge: EdgeLineConfiguration,
        camera: CameraState = EdgeRenderingGapsTests.orthoCamera,
        background: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        edgeIntensity: Float = 1
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.edgeLineConfiguration = edge
        config.backgroundColor = background
        config.pickingConfiguration = PickingConfiguration(isEnabled: true)
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shadedWithEdges
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        controller.edgeIntensity = edgeIntensity
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        return (controller, renderer)
    }

    private func liveRender(
        bodies: [ViewportBody], edge: EdgeLineConfiguration, edgeIntensity: Float = 1
    ) throws -> [UInt8] {
        let pair = try makeLive(bodies: bodies, edge: edge, edgeIntensity: edgeIntensity)
        guard
            let pixels = pair.renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        else {
            Issue.record("headless render returned nil")
            throw RenderUnavailable()
        }
        return pixels
    }

    static func pick(_ renderer: ViewportRenderer, at pixel: SIMD2<Int>) async -> PickResult? {
        await withCheckedContinuation { continuation in
            renderer.performPick(at: pixel) { continuation.resume(returning: $0) }
        }
    }

    static func isLit(_ pixels: [UInt8], x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        let i = (y * size + x) * 4
        return max(pixels[i], pixels[i + 1], pixels[i + 2]) > 100
    }

    static func litCount(_ pixels: [UInt8], row: Int) -> Int {
        (0..<size).filter { isLit(pixels, x: $0, y: row) }.count
    }

    /// Lit-run length along rays from the centre, across the circle at `radius` world units.
    static func radialThickness(_ pixels: [UInt8], radius: Float) -> [Int] {
        let c = Float(size) / 2
        let r = radius * pxPerUnit
        return stride(from: Float(0.3), to: 2 * .pi, by: .pi / 4).map { angle in
            let dir = SIMD2<Float>(cos(angle), -sin(angle))
            return stride(from: r - 10, through: r + 10, by: 1).filter { t in
                let p = SIMD2<Float>(c, c) + dir * t
                return isLit(pixels, x: Int(p.x), y: Int(p.y))
            }.count
        }
    }

    /// Fraction of 720 samples on the circle at `radius` world units that are lit.
    static func circleLitFraction(_ pixels: [UInt8], radius: Float) -> Float {
        let c = Float(size) / 2
        let r = radius * pxPerUnit
        let samples = 720
        let lit = (0..<samples).filter { i in
            let a = Float(i) / Float(samples) * 2 * .pi
            return isLit(pixels, x: Int(c + r * cos(a)), y: Int(c - r * sin(a)))
        }.count
        return Float(lit) / Float(samples)
    }

    static func readBGRA(_ image: CGImage) -> ([UInt8], Int, Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return (buffer, width, height)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
