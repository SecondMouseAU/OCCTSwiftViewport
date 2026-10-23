// OffscreenParityTests.swift
// OCCTSwiftViewport Tests
//
// OffscreenRenderer features that used to exist only in the live ViewportRenderer (issue #136,
// M15): clip planes, edge intensity, analytic arcs, per-triangle highlights, the selection outline,
// the overlay render layer, crease-aware normal smoothing, and the SSAO / silhouette composite.
// Each test renders a small deterministic scene headlessly and checks pixels; the last suite
// compares offscreen output with a headless frame from the live renderer.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
import simd

@testable import OCCTSwiftViewport

// MARK: - Helpers

/// Pixel helpers shared by the parity tests.
@MainActor
enum ParityRender {

    struct Unavailable: Error {}

    /// Camera at +Z looking down -Z at the origin, orthographic so world units map evenly to pixels.
    static let frontCamera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero,
        orthographicScale: 10,
        isOrthographic: true
    )

    /// Lighting with no shadow pass and no SSAO, so pixel values depend only on what is tested.
    static var plainLighting: LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        return lighting
    }

    /// Options for a 128 x 128 front view on black, with the composite pass off.
    static func options(displayMode: DisplayMode = .unlit) -> OffscreenRenderOptions {
        OffscreenRenderOptions(
            width: 128, height: 128, cameraState: frontCamera, displayMode: displayMode,
            lightingConfiguration: plainLighting, backgroundColor: SIMD4<Float>(0, 0, 0, 1),
            appearance: .light, showGrid: false, showAxes: false, enableSilhouettes: false)
    }

    /// A flat quad in the plane `z` facing +Z, from `(x0, y0)` to `(x1, y1)`.
    static func quad(
        id: String, x0: Float, y0: Float, x1: Float, y1: Float, z: Float = 0,
        color: SIMD4<Float>
    ) -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        return ViewportBody(
            id: id, vertexData: v(x0, y0) + v(x1, y0) + v(x1, y1) + v(x0, y1),
            indices: [0, 1, 2, 0, 2, 3], edges: [], color: color)
    }

    static func render(
        _ bodies: [ViewportBody], _ options: OffscreenRenderOptions,
        renderer: OffscreenRenderer? = nil
    ) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard let renderer = renderer ?? OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw Unavailable()
        }
        guard let image = renderer.render(bodies: bodies, options: options) else {
            Issue.record("renderer returned nil image")
            throw Unavailable()
        }
        return bgra(image)
    }

    /// Row-major BGRA8 bytes of `image`.
    static func bgra(_ image: CGImage) -> ([UInt8], Int, Int) {
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

    /// `(r, g, b)` of the pixel at `(x, y)`.
    static func rgb(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> SIMD3<Int> {
        let i = (y * width + x) * 4
        return SIMD3(Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
    }

    /// Number of pixels in the column range `xs` for which `predicate` holds.
    static func count(
        _ pixels: [UInt8], width: Int, height: Int, xs: Range<Int>? = nil,
        where predicate: (SIMD3<Int>) -> Bool
    ) -> Int {
        var n = 0
        for y in 0..<height {
            for x in xs ?? 0..<width where predicate(rgb(pixels, width: width, x: x, y: y)) {
                n += 1
            }
        }
        return n
    }

    /// Expects a selection ring around a centred radius-2 sphere: outline-coloured pixels exist, but
    /// far fewer than the body's area, and the body's centre is not outline-coloured.
    static func expectRing(_ pixels: [UInt8], width: Int, height: Int, _ label: String) {
        let isOutline: (SIMD3<Int>) -> Bool = { $0.z > 200 && $0.x < 80 }
        let ring = count(pixels, width: width, height: height, where: isOutline)
        let quadArea = Int(Float(width) * 0.4) * Int(Float(height) * 0.4)
        #expect(ring > 20, "\(label): no outline ring (\(ring) px)")
        #expect(ring < quadArea / 2, "\(label): outline filled the body (\(ring) px)")
        // Off the axes, where a wireframe sphere's edge lines run.
        #expect(
            !isOutline(rgb(pixels, width: width, x: width / 2 + 9, y: height / 2 + 7)),
            "\(label): body interior painted in the outline colour")
    }

    /// A uniform green 16 x 8 equirectangular environment in the raw `environmentMapData` format
    /// (width, height as `Int32`, then RGBA `Float` pixels).
    static func greenEnvironment() -> Data {
        var data = Data()
        withUnsafeBytes(of: Int32(16)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(8)) { data.append(contentsOf: $0) }
        let pixels = [Float](repeating: 0, count: 16 * 8 * 4).enumerated().map { i, _ in
            i % 4 == 1 || i % 4 == 3 ? Float(1) : 0
        }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Writes BGRA8 bytes as a PNG when `OFFSCREEN_PARITY_DUMP_DIR` is set; a no-op otherwise.
    static func dump(_ pixels: [UInt8], width: Int, height: Int, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["OFFSCREEN_PARITY_DUMP_DIR"],
            !dir.isEmpty
        else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
            let dest = CGImageDestinationCreateWithURL(
                url.appendingPathComponent("\(name).png") as CFURL,
                UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - Offscreen features

@MainActor
@Suite("Offscreen render parity features")
struct OffscreenParityFeatureTests {

    private let white = SIMD4<Float>(1, 1, 1, 1)

    @Test("A clip plane removes the clipped half of a body")
    func clipPlaneRemovesHalf() throws {
        let body = ParityRender.quad(id: "q", x0: -4, y0: -4, x1: 4, y1: 4, color: white)
        var options = ParityRender.options()
        let (open, w, h) = try ParityRender.render([body], options)
        // Keep x > 0: the plane's normal points along +X through the origin.
        options.clipPlanes = [ClipPlane(normal: SIMD3(1, 0, 0), distance: 0)]
        let (clipped, _, _) = try ParityRender.render([body], options)

        let lit: (SIMD3<Int>) -> Bool = { $0.x > 128 }
        let leftOpen = ParityRender.count(open, width: w, height: h, xs: 0..<(w / 2), where: lit)
        let leftClipped = ParityRender.count(
            clipped, width: w, height: h, xs: 0..<(w / 2 - 2), where: lit)
        let rightClipped = ParityRender.count(
            clipped, width: w, height: h, xs: (w / 2 + 2)..<w, where: lit)
        #expect(leftOpen > 1000, "unclipped quad should cover the left half")
        #expect(leftClipped == 0, "clipped half still drew \(leftClipped) lit pixels")
        #expect(rightClipped > 1000, "kept half disappeared")
    }

    @Test("A clipped-away caster casts no shadow offscreen")
    func clippedCasterCastsNoShadow() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        // Ground slab under a box caster, lit and viewed as in ShadowTransformTests.
        var ground = ViewportBody.box(
            id: "ground", width: 6, height: 0.2, depth: 6, color: SIMD4(0.8, 0.8, 0.8, 1))
        ground.transform.columns.3 = SIMD4(0.6, -1.0, 0.4, 1)
        var caster = ViewportBody.box(
            id: "caster", width: 1, height: 1, depth: 1, color: SIMD4(0.8, 0.4, 0.2, 1))
        caster.transform.columns.3 = SIMD4(-0.5, 0.2, 0.3, 1)
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.7
        lighting.enableSSAO = false
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: -1.45, axis: SIMD3<Float>(1, 0, 0))
        camera.distance = 9
        camera.pivot = SIMD3<Float>(0, -0.9, 0)
        var options = OffscreenRenderOptions(
            width: 160, height: 160, cameraState: camera, displayMode: .shaded,
            lightingConfiguration: lighting, backgroundColor: SIMD4(0, 0, 0, 1),
            appearance: .light, showGrid: false, showAxes: false, enableSilhouettes: false)
        // Keeps y <= -0.5: the whole ground stays, the whole caster (y -0.3...0.7) goes.
        let cut = ClipPlane(normal: SIMD3(0, -1, 0), distance: -0.5)

        func image(_ bodies: [ViewportBody], clipped: Bool) throws -> [UInt8] {
            options.clipPlanes = clipped ? [cut] : []
            return try ParityRender.render(bodies, options, renderer: renderer).pixels
        }
        func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
            stride(from: 0, to: a.count, by: 4).filter { p in
                (0..<3).contains { abs(Int(a[p + $0]) - Int(b[p + $0])) > 20 }
            }.count
        }
        let groundOnly = try image([ground], clipped: true)
        let withCaster = try image([ground, caster], clipped: false)
        let casterClipped = try image([ground, caster], clipped: true)
        #expect(differing(withCaster, groundOnly) > 200, "scene shows no caster or shadow")
        let leftover = differing(casterClipped, groundOnly)
        #expect(leftover < 20, "clipped caster still left \(leftover) px (its shadow?)")
    }

    @Test("Disabled clip planes and planes past the fourth are ignored")
    func clipPlaneLimits() {
        let off = ClipPlane(normal: SIMD3(1, 0, 0), isEnabled: false)
        let on = ClipPlane(normal: SIMD3(0, 1, 0), distance: 2)
        let packed = RendererSharedSetup.packClipPlanes([off] + Array(repeating: on, count: 6))
        #expect(packed.count == 4)
        #expect(packed.planes.0 == on.asFloat4)
        #expect(RendererSharedSetup.packClipPlanes([off]).count == 0)
    }

    @Test("edgeIntensity 0 hides the edges of a meshed body")
    func edgeIntensityHidesEdges() throws {
        // Dark quad well away from the edge polyline, so the line's row is background unless the
        // edge is drawn. Native lines: the only edge path whose shader reads the intensity.
        let line: [SIMD3<Float>] = [SIMD3(-4, 0, 0), SIMD3(4, 0, 0)]
        var body = ParityRender.quad(
            id: "m", x0: -1, y0: 3, x1: 1, y1: 4, color: SIMD4(0.1, 0.1, 0.1, 1))
        body.edges = [line]
        var options = ParityRender.options(displayMode: .shadedWithEdges)
        options.edgeLineConfiguration = EdgeLineConfiguration(useQuadExpansion: false)

        func edgePixels(_ intensity: Float) throws -> Int {
            options.edgeIntensity = intensity
            let (px, w, h) = try ParityRender.render([body], options)
            // Only the line's band of rows; the dark quad sits well above it.
            var n = 0
            for y in (h / 2 - 4)...(h / 2 + 4) {
                for x in 0..<w where ParityRender.rgb(px, width: w, x: x, y: y).x > 50 { n += 1 }
            }
            return n
        }
        let visible = try edgePixels(1)
        let hidden = try edgePixels(0)
        #expect(visible > 40, "edge should be visible at intensity 1 (\(visible) px)")
        #expect(hidden == 0, "edge still drawn at intensity 0 (\(hidden) px)")
    }

    @Test("Analytic arcs are drawn")
    func arcsAreDrawn() throws {
        let circle = ViewportArc.circle(
            center: .zero, radius: 3, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let body = ViewportBody(
            id: "arc", vertexData: [], indices: [], edges: [], arcs: [circle],
            color: SIMD4(1, 0.2, 0.2, 1))
        let (px, w, h) = try ParityRender.render([body], ParityRender.options())
        let red = ParityRender.count(px, width: w, height: h) { $0.x > 150 && $0.y < 100 }
        #expect(red > 60, "expected the circle's outline in red, got \(red) px")
        // The centre of the circle is empty.
        #expect(ParityRender.rgb(px, width: w, x: w / 2, y: h / 2).x < 30)
    }

    @Test("Per-triangle styles are composited over the surface")
    func triangleStylesHighlight() throws {
        var body = ParityRender.quad(
            id: "q", x0: -4, y0: -4, x1: 4, y1: 4, color: SIMD4(0.5, 0.5, 0.5, 1))
        body.triangleStyles = [TriangleStyle(color: SIMD4(1, 0, 0, 1)), .none]
        let (px, w, h) = try ParityRender.render([body], ParityRender.options())
        // Triangle 0 is (x0,y0)-(x1,y0)-(x1,y1): the lower-right half. Image y runs down.
        let styled = ParityRender.rgb(px, width: w, x: w * 3 / 4, y: h * 3 / 4)
        let plain = ParityRender.rgb(px, width: w, x: w / 4, y: h / 4)
        #expect(styled.x > 200 && styled.y < 40, "styled triangle not red: \(styled)")
        #expect(abs(plain.x - plain.y) < 10, "unstyled triangle was tinted: \(plain)")
    }

    @Test("Mutating triangleStyles on an existing body is picked up")
    func triangleStylesMutationPickedUp() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        var body = ParityRender.quad(
            id: "q", x0: -4, y0: -4, x1: 4, y1: 4, color: SIMD4(0.5, 0.5, 0.5, 1))
        _ = try ParityRender.render([body], ParityRender.options(), renderer: renderer)
        // Same body (same generation), styles added afterwards.
        body.triangleStyles = [TriangleStyle(color: SIMD4(0, 1, 0, 1)), .none]
        let (px, w, h) = try ParityRender.render([body], ParityRender.options(), renderer: renderer)
        let styled = ParityRender.rgb(px, width: w, x: w * 3 / 4, y: h * 3 / 4)
        #expect(styled.y > 200 && styled.x < 40, "mutated style not drawn: \(styled)")
    }

    @Test("A selected body gets an outline ring; an unselected one does not")
    func selectionOutline() throws {
        // The outline pushes vertices 0.015 world units along their normals, so frame a small
        // sphere tightly enough for that to cover a few pixels.
        let body = ViewportBody.sphere(id: "q", radius: 0.3, color: SIMD4(0.5, 0.5, 0.5, 1))
        let isOutline: (SIMD3<Int>) -> Bool = { $0.z > 200 && $0.x < 80 }
        var options = ParityRender.options()
        options.cameraState.orthographicScale = 0.8
        let (plain, w, h) = try ParityRender.render([body], options)
        options.selectedBodyIDs = ["q"]
        let (selected, _, _) = try ParityRender.render([body], options)
        #expect(ParityRender.count(plain, width: w, height: h, where: isOutline) == 0)
        let ring = ParityRender.count(selected, width: w, height: h, where: isOutline)
        #expect(ring > 0, "no outline pixels around the selected body")
        // A ring, not a fill: the body's centre keeps its own colour.
        #expect(!isOutline(ParityRender.rgb(selected, width: w, x: w / 2, y: h / 2)))
    }

    @Test("Wireframe-mode and translucent selections get a ring, not a blob")
    func selectionRingWithoutOpaqueSurface() throws {
        let opaque = ViewportBody.sphere(id: "q", radius: 2, color: SIMD4(0.5, 0.5, 0.5, 1))
        var wireframe = ParityRender.options(displayMode: .wireframe)
        wireframe.selectedBodyIDs = ["q"]
        let (wirePx, w, h) = try ParityRender.render([opaque], wireframe)
        ParityRender.expectRing(wirePx, width: w, height: h, "wireframe")

        let glass = ViewportBody.sphere(id: "q", radius: 2, color: SIMD4(0.5, 0.5, 0.5, 0.4))
        var shaded = ParityRender.options()
        shaded.selectedBodyIDs = ["q"]
        let (glassPx, _, _) = try ParityRender.render([glass], shaded)
        ParityRender.expectRing(glassPx, width: w, height: h, "translucent")
    }

    @Test("Overlay bodies draw on top of nearer geometry")
    func overlayDrawsOnTop() throws {
        let front = ParityRender.quad(
            id: "front", x0: -4, y0: -4, x1: 4, y1: 4, z: 1, color: SIMD4(0, 0, 1, 1))
        var overlay = ParityRender.quad(
            id: "widget", x0: -1, y0: -1, x1: 1, y1: 1, z: -1, color: SIMD4(1, 0, 0, 1))
        overlay.renderLayer = .overlay
        let (px, w, h) = try ParityRender.render([front, overlay], ParityRender.options())
        let centre = ParityRender.rgb(px, width: w, x: w / 2, y: h / 2)
        #expect(centre.x > 200 && centre.z < 40, "overlay hidden behind geometry: \(centre)")
    }

    @Test("Overlay point bodies are drawn on top")
    func overlayPointsDrawn() throws {
        let front = ParityRender.quad(
            id: "front", x0: -4, y0: -4, x1: 4, y1: 4, z: 1, color: SIMD4(0, 0, 1, 1))
        let marker = ViewportBody(
            id: "marker", vertexData: [], indices: [], edges: [],
            vertices: [SIMD3(0, 0, -1)], color: SIMD4(0, 1, 0, 1), pointRadius: 0.5,
            primitiveKind: .point, renderLayer: .overlay)
        let (px, w, h) = try ParityRender.render([front, marker], ParityRender.options())
        let green = ParityRender.count(px, width: w, height: h) { $0.y > 200 && $0.z < 60 }
        #expect(green > 10, "overlay point marker not drawn (\(green) px)")
    }

    @Test("autoSmoothNormals rounds a faceted mesh")
    func autoSmoothNormals() throws {
        let smooth = ViewportBody.sphere(id: "s", radius: 3, color: SIMD4(0.8, 0.8, 0.8, 1))
        // Same sphere with flat per-triangle normals (vertices unshared).
        var flatData: [Float] = []
        var flatIndices: [UInt32] = []
        let vd = smooth.vertexData
        for t in stride(from: 0, to: smooth.indices.count - 2, by: 3) {
            let p = (0..<3).map { k -> SIMD3<Float> in
                let i = Int(smooth.indices[t + k]) * 6
                return SIMD3(vd[i], vd[i + 1], vd[i + 2])
            }
            var n = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            if simd_dot(n, p[0] + p[1] + p[2]) < 0 { n = -n }  // outward, whatever the winding
            for q in p {
                flatIndices.append(UInt32(flatData.count / 6))
                flatData += [q.x, q.y, q.z, n.x, n.y, n.z]
            }
        }
        let faceted = ViewportBody(
            id: "s", vertexData: flatData, indices: flatIndices, edges: [],
            color: SIMD4(0.8, 0.8, 0.8, 1))

        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        var options = ParityRender.options(displayMode: .shaded)
        let (reference, _, _) = try ParityRender.render([smooth], options, renderer: renderer)
        let (rawFacets, _, _) = try ParityRender.render([faceted], options, renderer: renderer)
        options.autoSmoothNormals = true
        let (smoothed, _, _) = try ParityRender.render([faceted], options, renderer: renderer)

        func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
            zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        let before = distance(rawFacets, reference)
        let after = distance(smoothed, reference)
        #expect(after * 2 < before, "smoothing barely helped: \(before) -> \(after)")
    }

    @Test("Silhouettes and SSAO run through the composite pass")
    func compositeRuns() throws {
        var box = ViewportBody.box(
            id: "b", width: 4, height: 4, depth: 4, color: SIMD4(0.8, 0.8, 0.8, 1))
        box.transform = matrix_identity_float4x4
        var camera = CameraState()
        camera.rotation = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(1, 1, 0)))
        camera.distance = 14
        var options = ParityRender.options(displayMode: .shaded)
        options.cameraState = camera
        options.backgroundColor = SIMD4(1, 1, 1, 1)

        let (off, w, h) = try ParityRender.render([box], options)
        options.enableSilhouettes = true
        let (silhouettes, _, _) = try ParityRender.render([box], options)
        var ssaoOptions = options
        ssaoOptions.enableSilhouettes = false
        ssaoOptions.lightingConfiguration.enableSSAO = true
        let (ssao, _, _) = try ParityRender.render([box], ssaoOptions)

        // Silhouettes darken the box's outline against the white background.
        var darkened = 0
        for y in 0..<h {
            for x in 0..<w {
                let before = ParityRender.rgb(off, width: w, x: x, y: y)
                let after = ParityRender.rgb(silhouettes, width: w, x: x, y: y)
                if before.x - after.x > 40 { darkened += 1 }
            }
        }
        #expect(darkened > 30, "silhouette pass darkened only \(darkened) pixels")
        #expect(off != ssao, "SSAO / tone-map composite left the image unchanged")
    }

    @Test("drawBackground draws the environment map as a skybox")
    func skyboxDrawn() throws {
        let body = ParityRender.quad(
            id: "q", x0: -1, y0: -1, x1: 1, y1: 1, color: SIMD4(0.5, 0.5, 0.5, 1))
        var options = ParityRender.options(displayMode: .shaded)
        options.lightingConfiguration.environmentMapData = ParityRender.greenEnvironment()
        let (plain, w, _) = try ParityRender.render([body], options)
        options.lightingConfiguration.drawBackground = true
        let (sky, _, _) = try ParityRender.render([body], options)
        let plainCorner = ParityRender.rgb(plain, width: w, x: 2, y: 2)
        let skyCorner = ParityRender.rgb(sky, width: w, x: 2, y: 2)
        #expect(plainCorner == SIMD3(0, 0, 0), "background should be the clear colour")
        #expect(skyCorner.y > 60 && skyCorner.y > skyCorner.x + 40, "no skybox: \(skyCorner)")
    }

    @Test("The composite is skipped in unlit mode")
    func compositeSkippedWhenUnlit() throws {
        let body = ParityRender.quad(
            id: "q", x0: -4, y0: -4, x1: 4, y1: 4, color: SIMD4(0.2, 0.6, 0.9, 1))
        var options = ParityRender.options(displayMode: .unlit)
        let (plain, w, _) = try ParityRender.render([body], options)
        options.enableSilhouettes = true
        options.lightingConfiguration.enableSSAO = true
        let (composited, _, _) = try ParityRender.render([body], options)
        #expect(plain == composited, "unlit colours were altered by the composite")
        let c = ParityRender.rgb(plain, width: w, x: w / 2, y: w / 2)
        #expect(abs(c.x - 51) <= 2 && abs(c.y - 153) <= 2 && abs(c.z - 230) <= 2)
    }

    @Test("Default options show what a default ViewportController shows")
    func defaultsFollowLiveDefaults() {
        let controller = ViewportController()
        let config = controller.configuration
        let options = OffscreenRenderOptions()
        #expect(options.displayMode == controller.displayMode)
        #expect(options.xrayOpacity == controller.xrayOpacity)
        #expect(options.showGrid == controller.showGrid)
        #expect(options.showAxes == controller.showAxes)
        #expect(options.cameraState == controller.cameraState)
        #expect(options.edgeIntensity == controller.edgeIntensity)
        #expect(options.backgroundColor == config.backgroundColor)
        #expect(options.msaaSampleCount == config.msaaSampleCount)
        #expect(options.enableSilhouettes == config.enableSilhouettes)
        #expect(options.autoSmoothNormals == config.autoSmoothNormals)
        #expect(options.selectionOutline == config.selectionOutline)
        #expect(options.edgeLineConfiguration.width == config.edgeLineConfiguration.width)
        #expect(options.darkModeBackgroundColor == config.darkModeBackgroundColor)
        #expect(options.appearance == .system)
        #expect(options.gridStyle == config.gridStyle)
        #expect(options.gridSize == config.gridSize)
        #expect(options.axisLength == config.axisLength)
        #expect(options.axisStyle == config.axisStyle)
        #expect(
            options.lightingConfiguration.enableSSAO
                == controller.lightingConfiguration.enableSSAO)
    }

    @Test("init(matching:) copies the controller's live settings")
    func matchingController() {
        var config = ViewportConfiguration()
        config.enableSilhouettes = false
        config.autoSmoothNormals = true
        config.normalSmoothingCreaseAngle = 0.3
        config.backgroundColor = SIMD4(0.1, 0.2, 0.3, 1)
        let controller = ViewportController(configuration: config)
        controller.displayMode = .wireframe
        controller.xrayOpacity = 0.25
        controller.edgeIntensity = 1.7
        controller.clipPlanes = [ClipPlane()]
        controller.selectedBodyIDs = ["a"]
        controller.hoveredBodyID = "b"

        let options = OffscreenRenderOptions(matching: controller, width: 320, height: 200)
        #expect(options.width == 320 && options.height == 200)
        #expect(options.displayMode == .wireframe)
        #expect(options.xrayOpacity == 0.25)
        #expect(options.edgeIntensity == 1.7)
        #expect(options.clipPlanes == [ClipPlane()])
        #expect(options.selectedBodyIDs == ["a"])
        #expect(options.hoveredBodyID == "b")
        #expect(!options.enableSilhouettes)
        #expect(options.autoSmoothNormals)
        #expect(options.normalSmoothingCreaseAngle == 0.3)
        #expect(options.backgroundColor == SIMD4(0.1, 0.2, 0.3, 1))
        #expect(options.cameraState == controller.cameraState)
    }
}

// MARK: - Offscreen vs live

@MainActor
@Suite("Offscreen vs live renderer parity")
struct OffscreenLiveParityTests {

    static let width = 160
    static let height = 120

    /// One scene rendered by both renderers.
    struct Scene {
        let name: String
        var configuration = ViewportConfiguration()
        var bodies: [ViewportBody] = ViewportRenderBattery.standardBodies()
        var displayMode: DisplayMode = .shaded
        var lighting: LightingConfiguration = .threePoint
        var clipPlanes: [ClipPlane] = []
        var selectedBodyIDs: Set<String> = []
    }

    static func scenes() -> [Scene] {
        var arcBody = ViewportBody(
            id: "ring", vertexData: [], indices: [], edges: [],
            arcs: [
                ViewportArc.circle(
                    center: SIMD3(0, 0.9, 0), radius: 0.9, xAxis: SIMD3(1, 0, 0),
                    yAxis: SIMD3(0, 0, 1))
            ],
            color: SIMD4(0.1, 0.6, 0.2, 1))
        arcBody.transform = matrix_identity_float4x4
        var highlighted = ViewportRenderBattery.standardBodies()
        highlighted[0].triangleStyles = (0..<(highlighted[0].indices.count / 3)).map {
            $0 % 2 == 0 ? TriangleStyle(color: SIMD4(1, 0.9, 0, 0.8)) : .none
        }
        var smoothing = ViewportConfiguration()
        smoothing.autoSmoothNormals = true
        // Refined surface paths (#165), grid and axes off so only the bodies are compared. The
        // sphere is coarse enough that PN triangles visibly round it.
        var faceted = ViewportRenderBattery.standardBodies()
        faceted[1] = ViewportBody.sphere(
            id: "sphere", radius: 0.6, segments: 14, rings: 10, color: faceted[1].color)
        faceted[1].transform = ViewportRenderBattery.standardBodies()[1].transform
        func quality(
            _ quality: RenderingQuality, adaptive: Bool = true,
            uniform: UniformTessellationFactor = .loadAdaptive()
        ) -> ViewportConfiguration {
            var config = ViewportConfiguration()
            config.renderingQuality = quality
            config.adaptiveTessellation = adaptive
            config.uniformTessellationFactor = uniform
            config.showGrid = false
            config.showAxes = false
            return config
        }
        var skyLighting = LightingConfiguration.threePoint
        skyLighting.environmentMapData = ParityRender.greenEnvironment()
        skyLighting.drawBackground = true

        return [
            Scene(name: "default-shaded"),
            Scene(name: "shaded-with-edges", displayMode: .shadedWithEdges),
            Scene(name: "selection", selectedBodyIDs: ["sphere"]),
            Scene(
                name: "clip-plane",
                clipPlanes: [ClipPlane(normal: SIMD3(-1, 0, 0), distance: 0.6)]),
            Scene(
                name: "arcs", bodies: ViewportRenderBattery.standardBodies() + [arcBody],
                displayMode: .shadedWithEdges),
            Scene(name: "highlight", bodies: highlighted),
            Scene(
                name: "transparency", bodies: ViewportRenderBattery.transparentBodies(),
                displayMode: .shadedWithEdges),
            Scene(name: "auto-smooth", configuration: smoothing),
            // Silhouettes alone: the composite must not apply SSAO when it is disabled.
            Scene(name: "silhouettes-only", lighting: ViewportRenderBattery.lighting(ssao: false)),
            Scene(
                name: "selected-translucent", bodies: ViewportRenderBattery.transparentBodies(),
                selectedBodyIDs: ["front"]),
            // Image-based lighting and the skybox from `environmentMapData`.
            Scene(name: "environment-skybox", lighting: skyLighting),
            Scene(name: "selected-wireframe", displayMode: .wireframe, selectedBodyIDs: ["box"]),
            // Section plane through a shadow caster: the clipped part casts no shadow (#190).
            Scene(
                name: "clipped-shadows", bodies: ViewportRenderBattery.shadowBodies(),
                lighting: ViewportRenderBattery.shadowLighting(),
                clipPlanes: [ClipPlane(normal: SIMD3(1, 0, 0), distance: 0)]),
            Scene(name: "xray", displayMode: .xray, selectedBodyIDs: ["sphere"]),
            Scene(name: "enhanced", configuration: quality(.enhanced), bodies: faceted),
            Scene(
                name: "enhanced-uniform",
                configuration: quality(.enhanced, adaptive: false, uniform: .fixed(6)),
                bodies: faceted),
            Scene(
                name: "enhanced-shadows", configuration: quality(.enhanced),
                bodies: faceted + [ViewportRenderBattery.shadowBodies()[2]],
                lighting: ViewportRenderBattery.shadowLighting()),
            Scene(name: "maximum", configuration: quality(.maximum), bodies: faceted),
        ]
    }

    /// Renders `scene` through the live renderer's headless path, then offscreen with options
    /// copied from the same controller.
    static func renderBoth(_ scene: Scene) -> (live: [UInt8], offscreen: [UInt8])? {
        var config = scene.configuration
        config.initialCameraState = ViewportRenderBattery.fittedCamera(for: scene.bodies)
        let controller = ViewportController(configuration: config)
        controller.displayMode = scene.displayMode
        controller.lightingConfiguration = scene.lighting
        controller.clipPlanes = scene.clipPlanes
        controller.selectedBodyIDs = scene.selectedBodyIDs
        // The headless live frame always clears to the light background, so pin it here too
        // rather than following the host's appearance.
        var options = OffscreenRenderOptions(matching: controller, width: width, height: height)
        options.appearance = .light
        guard
            let live = ViewportRenderer(controller: controller, bodies: .constant(scene.bodies)),
            // Two frames: the live renderer fits its near/far planes to the bounds it cached on
            // the previous frame.
            let livePixels = live.renderHeadlessBGRA(
                width: width, height: height, backgroundColor: config.backgroundColor,
                frameCount: 2),
            let offscreen = OffscreenRenderer(),
            let image = offscreen.render(bodies: scene.bodies, options: options)
        else { return nil }
        return (livePixels, ParityRender.bgra(image).0)
    }

    @Test(
        "Offscreen output matches a live headless frame",
        arguments: [
            "default-shaded", "shaded-with-edges", "selection", "clip-plane", "arcs", "highlight",
            "transparency", "auto-smooth", "silhouettes-only", "selected-translucent",
            "environment-skybox", "selected-wireframe", "clipped-shadows", "xray", "enhanced",
            "enhanced-uniform", "enhanced-shadows", "maximum",
        ])
    func matchesLive(sceneName: String) throws {
        let scene = try #require(Self.scenes().first { $0.name == sceneName })
        guard let (live, offscreen) = Self.renderBoth(scene) else {
            Issue.record("Metal device unavailable; skipping parity check")
            return
        }
        ParityRender.dump(live, width: Self.width, height: Self.height, name: "\(sceneName)-live")
        ParityRender.dump(
            offscreen, width: Self.width, height: Self.height, name: "\(sceneName)-offscreen")

        // Pixels that differ by more than a few levels in any channel. The two paths share
        // shaders, so only MSAA edge coverage should disagree.
        var differing = 0
        for p in stride(from: 0, to: live.count, by: 4) {
            let delta = (0..<3).map { abs(Int(live[p + $0]) - Int(offscreen[p + $0])) }.max() ?? 0
            if delta > 8 { differing += 1 }
        }
        let fraction = Double(differing) / Double(Self.width * Self.height)
        print("[offscreen-parity] \(sceneName): \(differing) px differ (\(fraction * 100)%)")
        // Tessellation only moves a faceted silhouette by a pixel or two, ~0.7% of the frame for
        // these scenes, so they get a tighter budget that a missing offscreen path would exceed.
        let refinedScene = sceneName.hasPrefix("enhanced") || sceneName == "maximum"
        let budget = refinedScene ? 0.002 : 0.01
        #expect(
            fraction < budget, "\(sceneName): \(differing) pixels differ from the live frame")
    }
}

// MARK: - Live renderer fixes

@MainActor
@Suite("Live renderer overlay and outline fixes")
struct LiveOverlayOutlineTests {

    /// Renders `bodies` through the live renderer's headless path, front view on black.
    private func renderLive(
        _ bodies: [ViewportBody], selected: Set<String> = [], displayMode: DisplayMode = .unlit
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        let config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: displayMode,
            lightingConfiguration: ParityRender.plainLighting,
            showGrid: false, backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        let controller = ViewportController(configuration: config)
        controller.selectedBodyIDs = selected
        guard
            let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let pixels = renderer.renderHeadlessBGRA(
                width: 128, height: 128, backgroundColor: config.backgroundColor, frameCount: 2)
        else { return nil }
        return (pixels, 128, 128)
    }

    @Test("Overlay point bodies are drawn by the live renderer")
    func liveOverlayPoints() throws {
        let front = ParityRender.quad(
            id: "front", x0: -4, y0: -4, x1: 4, y1: 4, z: 1, color: SIMD4(0, 0, 1, 1))
        let marker = ViewportBody(
            id: "marker", vertexData: [], indices: [], edges: [],
            vertices: [SIMD3(0, 0, -1)], color: SIMD4(0, 1, 0, 1), pointRadius: 0.5,
            primitiveKind: .point, renderLayer: .overlay)
        guard let (px, w, h) = renderLive([front, marker]) else {
            Issue.record("Metal device unavailable")
            return
        }
        let green = ParityRender.count(px, width: w, height: h) { $0.y > 200 && $0.z < 60 }
        #expect(green > 10, "live renderer dropped the overlay point marker (\(green) px)")
    }

    @Test("Selecting a translucent body draws a ring, not a solid blob")
    func liveTranslucentSelection() throws {
        let body = ViewportBody.sphere(id: "glass", radius: 2, color: SIMD4(0.5, 0.5, 0.5, 0.4))
        guard let (px, w, h) = renderLive([body], selected: ["glass"]) else {
            Issue.record("Metal device unavailable")
            return
        }
        ParityRender.expectRing(px, width: w, height: h, "live translucent")
    }

    @Test("Selecting a body in wireframe mode draws a ring, not a solid blob")
    func liveWireframeSelection() throws {
        let body = ViewportBody.sphere(id: "q", radius: 2, color: SIMD4(0.5, 0.5, 0.5, 1))
        guard let (px, w, h) = renderLive([body], selected: ["q"], displayMode: .wireframe)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        ParityRender.expectRing(px, width: w, height: h, "live wireframe")
    }
}
