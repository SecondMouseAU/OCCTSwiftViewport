// MeshVertexColorTests.swift
// OCCTSwiftViewport Tests
//
// Per-vertex colours for mesh bodies (issue #142). `ViewportBody.vertexColors` was read only by the
// point-cloud pass; with `vertexColorMode` set to `.multiply` or `.replace` the shaded pass now
// interpolates them across each triangle, on every mesh path (interleaved, direct-mesh, PN
// tessellation, mesh shaders), in the opaque, translucent and x-ray passes, for overlay bodies, and
// in both renderers. The default (`.ignored`) leaves every render unchanged.

import CoreGraphics
import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Scene

/// A red / green / blue triangle in the z = 0 plane seen by the orthographic front camera.
///
/// `ParityRender.frontCamera` shows 10 world units over the 128-pixel height, so the triangle's
/// corners and the points a little way inside them land on known pixels.
@MainActor
enum VertexColorScene {

    static let width = 128
    static let height = 128

    /// Corners, counter-clockwise seen from +Z.
    static let corners: [SIMD3<Float>] = [SIMD3(-4, -3, 0), SIMD3(4, -3, 0), SIMD3(0, 4, 0)]

    static let red = SIMD4<Float>(1, 0, 0, 1)
    static let green = SIMD4<Float>(0, 1, 0, 1)
    static let blue = SIMD4<Float>(0, 0, 1, 1)
    static let white = SIMD4<Float>(1, 1, 1, 1)

    static let gradient: [SIMD4<Float>] = [red, green, blue]

    /// Interleaved triangle with one colour per corner.
    static func triangle(
        id: String = "tri",
        color: SIMD4<Float> = white,
        vertexColors: [SIMD4<Float>] = gradient,
        mode: VertexColorMode = .replace,
        layer: RenderLayer = .geometry
    ) -> ViewportBody {
        var data: [Float] = []
        for c in corners { data += [c.x, c.y, c.z, 0, 0, 1] }
        return ViewportBody(
            id: id, vertexData: data, indices: [0, 1, 2], edges: [],
            vertexColors: vertexColors, vertexColorMode: mode,
            color: color, renderLayer: layer)
    }

    /// The same triangle through the direct-mesh path.
    static func directTriangle(
        id: String = "direct",
        color: SIMD4<Float> = white,
        vertexColors: [SIMD4<Float>] = gradient,
        mode: VertexColorMode = .replace
    ) -> ViewportBody {
        var positions: [Float] = []
        var normals: [Float] = []
        for c in corners {
            positions += [c.x, c.y, c.z]
            normals += [0, 0, 1]
        }
        return ViewportBody.directMesh(
            id: id, positions: positions, normals: normals, indices: [0, 1, 2], color: color,
            vertexColors: vertexColors, vertexColorMode: mode)
    }

    /// Pixel at barycentric weights `w` of the three corners.
    static func pixel(_ w: SIMD3<Float>) -> (x: Int, y: Int) {
        let p = corners[0] * w.x + corners[1] * w.y + corners[2] * w.z
        // 128 px over 10 world units, y up, centred on the origin.
        let scale: Float = Float(height) / 10
        return (
            Int((Float(width) / 2 + p.x * scale).rounded()),
            Int((Float(height) / 2 - p.y * scale).rounded())
        )
    }

    /// Weights close to corner `index`, still well inside the triangle.
    static func nearCorner(_ index: Int) -> SIMD3<Float> {
        var w = SIMD3<Float>(repeating: 0.06)
        w[index] = 0.88
        return w
    }

    static let centroid = SIMD3<Float>(repeating: 1.0 / 3.0)

    static func sample(
        _ image: (pixels: [UInt8], width: Int, height: Int), _ w: SIMD3<Float>
    ) -> SIMD3<Int> {
        let p = pixel(w)
        return ParityRender.rgb(image.pixels, width: image.width, x: p.x, y: p.y)
    }

    /// Unlit options for the tests: no composite pass, black background.
    static func options(
        quality: RenderingQuality = .standard, displayMode: DisplayMode = .unlit
    ) -> OffscreenRenderOptions {
        var options = ParityRender.options(displayMode: displayMode)
        options.renderingQuality = quality
        options.tessellationMaxFactor = 16
        return options
    }

    /// Expects the unlit gradient: each corner's colour dominates near it, and the centroid is the
    /// average (a third of each channel, as interpolated sRGB values).
    static func expectGradient(
        _ image: (pixels: [UInt8], width: Int, height: Int), _ label: String
    ) {
        let nearRed = sample(image, nearCorner(0))
        let nearGreen = sample(image, nearCorner(1))
        let nearBlue = sample(image, nearCorner(2))
        let middle = sample(image, centroid)
        #expect(
            nearRed.x > 200 && nearRed.y < 40 && nearRed.z < 40, "\(label): near red \(nearRed)")
        #expect(
            nearGreen.y > 200 && nearGreen.x < 40 && nearGreen.z < 40,
            "\(label): near green \(nearGreen)")
        #expect(
            nearBlue.z > 200 && nearBlue.x < 40 && nearBlue.y < 40,
            "\(label): near blue \(nearBlue)")
        // Interpolated, not banded: the middle is a mix of all three.
        for channel in [middle.x, middle.y, middle.z] {
            #expect(abs(channel - 85) <= 10, "\(label): centroid \(middle) is not an even mix")
        }
    }

    /// Whether the device runs mesh shaders (Apple9: M3, A17 and later).
    static var supportsMeshShaders: Bool {
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false
    }
}

// MARK: - Paths

/// One way a mesh body reaches the shaded pass.
struct MeshPath: Sendable, CustomStringConvertible {
    let name: String
    let quality: RenderingQuality
    /// Whether the body is built with `ViewportBody.directMesh`.
    let direct: Bool

    var description: String { name }

    static let all: [MeshPath] = [
        MeshPath(name: "interleaved", quality: .standard, direct: false),
        MeshPath(name: "tessellated", quality: .enhanced, direct: false),
        MeshPath(name: "meshlets", quality: .maximum, direct: false),
        MeshPath(name: "direct-mesh", quality: .standard, direct: true),
    ]
}

// MARK: - Model

@MainActor
@Suite("Mesh vertex colours: model")
struct MeshVertexColorModelTests {

    @Test("Vertex colours are ignored by default")
    func defaultIsIgnored() {
        let plain = ViewportBody.box(id: "b", width: 1, height: 1, depth: 1, color: .one)
        #expect(plain.vertexColorMode == .ignored)
        #expect(plain.vertexColors.isEmpty)
        // A body that carries colours but no mode still ignores them.
        let carrying = ViewportBody(
            id: "c", vertexData: [], indices: [], edges: [],
            vertexColors: [VertexColorScene.red], color: .one)
        #expect(carrying.vertexColorMode == .ignored)
    }

    @Test("The mode's raw values are the ones Shaders.metal switches on")
    func rawValuesMatchTheShader() {
        // surfaceAlbedo(): 0 = ignored, 1 = multiply, 2 = replace.
        #expect(VertexColorMode.ignored.rawValue == 0)
        #expect(VertexColorMode.multiply.rawValue == 1)
        #expect(VertexColorMode.replace.rawValue == 2)
        #expect(VertexColorMode.allCases.count == 3)
    }

    @Test("Changing the mode leaves generation alone; changing the colours takes a new one")
    func generationRules() {
        var body = VertexColorScene.triangle(mode: .ignored)
        let before = body.generation
        body.vertexColorMode = .replace
        body.vertexColorMode = .multiply
        #expect(body.generation == before, "the mode is read per frame and needs no re-upload")
        body.vertexColors = [VertexColorScene.blue, VertexColorScene.blue, VertexColorScene.blue]
        #expect(body.generation > before, "new colours must re-upload")
    }

    @Test("directMesh forwards vertex colours and the mode")
    func directMeshForwards() {
        let body = VertexColorScene.directTriangle(mode: .multiply)
        #expect(body.usesDirectMesh)
        #expect(body.vertexColors == VertexColorScene.gradient)
        #expect(body.vertexColorMode == .multiply)
        // Defaults stay as before.
        let plain = ViewportBody.directMesh(
            id: "p", positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2], color: .one)
        #expect(plain.vertexColors.isEmpty && plain.vertexColorMode == .ignored)
    }

    @Test("The mesh colour buffer needs a mode, and a count that matches the mesh")
    func colourBufferRules() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable")
            return
        }
        func buffer(_ body: ViewportBody, vertexCount: Int = 3) -> MTLBuffer? {
            RendererSharedBuffers.makeMeshColorBuffer(
                device: device, body: body, vertexCount: vertexCount)
        }
        let replace = buffer(VertexColorScene.triangle(mode: .replace))
        #expect(replace?.length == 3 * MemoryLayout<SIMD4<Float>>.stride)
        #expect(buffer(VertexColorScene.triangle(mode: .multiply)) != nil)
        #expect(buffer(VertexColorScene.triangle(mode: .ignored)) == nil, "mode ignored: lazy")
        #expect(buffer(VertexColorScene.triangle(vertexColors: [])) == nil, "empty falls back")
        #expect(
            buffer(VertexColorScene.triangle(vertexColors: [VertexColorScene.red])) == nil,
            "a short array falls back rather than reading out of bounds")
        #expect(
            buffer(VertexColorScene.triangle(), vertexCount: 4) == nil,
            "a count that doesn't match the uploaded mesh falls back")
    }
}

// MARK: - Offscreen rendering

@MainActor
@Suite("Mesh vertex colours: offscreen rendering")
struct MeshVertexColorOffscreenTests {

    typealias Path = MeshPath

    /// Every mesh path: plain, PN tessellation and mesh shaders for an interleaved body (mesh
    /// shaders run only on Apple9 and fall back to tessellation elsewhere), and direct-mesh.
    static let paths: [Path] = MeshPath.all

    static func body(_ path: Path, mode: VertexColorMode = .replace) -> ViewportBody {
        path.direct
            ? VertexColorScene.directTriangle(mode: mode)
            : VertexColorScene.triangle(mode: mode)
    }

    @Test("Red, green and blue vertices render an interpolated gradient", arguments: MeshPath.all)
    func gradient(path: Path) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options(quality: path.quality)
        let body = Self.body(path)
        let image = try ParityRender.render([body], options, renderer: renderer)
        ParityRender.dump(
            image.pixels, width: image.width, height: image.height,
            name: "vertex-colours-\(path.name)")
        VertexColorScene.expectGradient(image, path.name)

        // The refined path was the one drawn, when the body can take it.
        let buffers = renderer.refinementBuffers(forBodyID: body.id)
        if !path.direct, path.quality != .standard {
            #expect(buffers.tessellation || buffers.meshlets, "\(path.name): no refined buffers")
        }
        if !path.direct, path.quality == .maximum, VertexColorScene.supportsMeshShaders {
            #expect(buffers.meshlets, "meshlets were not built on an Apple9 GPU")
        }
    }

    /// A sphere (~1,000 triangles, so many meshlets and patches that share vertices) coloured by
    /// height: blue at the bottom, red at the top, a scalar-field ramp as an analysis map would use.
    static func rampSphere(direct: Bool, mode: VertexColorMode = .replace) -> ViewportBody {
        let radius: Float = 3
        let base = ViewportBody.sphere(
            id: "ramp", radius: radius, segments: 32, rings: 16, color: .one, up: .y)
        var colors: [SIMD4<Float>] = []
        var positions: [Float] = []
        var normals: [Float] = []
        var i = 0
        while i + 5 < base.vertexData.count {
            let t = (base.vertexData[i + 1] / radius + 1) / 2
            colors.append(SIMD4(t, 0, 1 - t, 1))
            positions += Array(base.vertexData[i..<i + 3])
            normals += Array(base.vertexData[i + 3..<i + 6])
            i += 6
        }
        if direct {
            return ViewportBody.directMesh(
                id: "ramp", positions: positions, normals: normals, indices: base.indices,
                color: .one, vertexColors: colors, vertexColorMode: mode)
        }
        var body = base
        body.vertexColors = colors
        body.vertexColorMode = mode
        return body
    }

    @Test(
        "A height ramp on a many-triangle mesh follows each vertex's own colour",
        arguments: MeshPath.all)
    func rampSphere(path: Path) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options(quality: path.quality)
        let image = try ParityRender.render(
            [Self.rampSphere(direct: path.direct)], options, renderer: renderer)
        // 12.8 px per world unit, y up: the sphere's front at world y = +2, 0, -2.
        func rgb(worldY: Float) -> SIMD3<Int> {
            ParityRender.rgb(
                image.pixels, width: image.width, x: 64, y: Int((64 - worldY * 12.8).rounded()))
        }
        let top = rgb(worldY: 2)
        let middle = rgb(worldY: 0)
        let bottom = rgb(worldY: -2)
        // Unlit shows the interpolated sRGB value: t = 0.83, 0.5, 0.17.
        #expect(top.x > 190 && top.z < 70 && top.y < 20, "\(path.name) top: \(top)")
        #expect(
            abs(middle.x - 128) < 20 && abs(middle.z - 128) < 20, "\(path.name) middle: \(middle)")
        #expect(bottom.z > 190 && bottom.x < 70 && bottom.y < 20, "\(path.name) bottom: \(bottom)")

        // Before / after pictures for review, lit: `OFFSCREEN_PARITY_DUMP_DIR=<dir> swift test`.
        let lit = VertexColorScene.options(quality: path.quality, displayMode: .shaded)
        let before = try ParityRender.render(
            [Self.rampSphere(direct: path.direct, mode: .ignored)], lit, renderer: renderer)
        let after = try ParityRender.render(
            [Self.rampSphere(direct: path.direct)], lit, renderer: renderer)
        ParityRender.dump(
            before.pixels, width: before.width, height: before.height,
            name: "ramp-before-\(path.name)")
        ParityRender.dump(
            after.pixels, width: after.width, height: after.height,
            name: "ramp-after-\(path.name)")
        #expect(before.pixels != after.pixels)
    }

    @Test(
        "Empty or mismatched vertexColors, or the default mode, render exactly as before",
        arguments: MeshPath.all)
    func fallbacksMatchBaseline(path: Path) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let base = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        func make(colors: [SIMD4<Float>], mode: VertexColorMode) -> ViewportBody {
            path.direct
                ? VertexColorScene.directTriangle(color: base, vertexColors: colors, mode: mode)
                : VertexColorScene.triangle(color: base, vertexColors: colors, mode: mode)
        }
        // Lit, with the default composite pass and shadows on, so every pass that could be
        // disturbed is in the picture.
        for (label, options) in [
            ("unlit", VertexColorScene.options(quality: path.quality)),
            (
                "lit, SSAO and shadows",
                {
                    var o = OffscreenRenderOptions(
                        width: 128, height: 128, cameraState: ParityRender.frontCamera,
                        displayMode: .shadedWithEdges)
                    o.renderingQuality = path.quality
                    o.tessellationMaxFactor = 16
                    return o
                }()
            ),
        ] {
            let baseline = try ParityRender.render(
                [make(colors: [], mode: .ignored)], options, renderer: renderer)
            let variants: [(String, ViewportBody)] = [
                (
                    "colours set, mode ignored",
                    make(colors: VertexColorScene.gradient, mode: .ignored)
                ),
                ("empty colours, replace", make(colors: [], mode: .replace)),
                ("empty colours, multiply", make(colors: [], mode: .multiply)),
                (
                    "short colours, replace",
                    make(colors: [VertexColorScene.red, VertexColorScene.blue], mode: .replace)
                ),
                (
                    "long colours, multiply",
                    make(
                        colors: VertexColorScene.gradient + [VertexColorScene.red], mode: .multiply)
                ),
            ]
            for (name, variant) in variants {
                let image = try ParityRender.render([variant], options, renderer: renderer)
                #expect(
                    image.pixels == baseline.pixels,
                    "\(path.name), \(label), \(name): differs from the body-colour render")
            }
        }
    }

    @Test("Multiply tints the vertex colours with the body colour", arguments: MeshPath.all)
    func multiplyTints(path: Path) throws {
        let options = VertexColorScene.options(quality: path.quality)
        // A red body: red vertices stay red, green and blue vertices go black.
        let body: ViewportBody = {
            let red = SIMD4<Float>(1, 0, 0, 1)
            return path.direct
                ? VertexColorScene.directTriangle(color: red, mode: .multiply)
                : VertexColorScene.triangle(color: red, mode: .multiply)
        }()
        let image = try ParityRender.render([body], options)
        let nearRed = VertexColorScene.sample(image, VertexColorScene.nearCorner(0))
        let nearGreen = VertexColorScene.sample(image, VertexColorScene.nearCorner(1))
        #expect(nearRed.x > 200 && nearRed.y < 20 && nearRed.z < 20, "\(path.name): \(nearRed)")
        #expect(
            nearGreen.x < 40 && nearGreen.y < 20 && nearGreen.z < 20, "\(path.name): \(nearGreen)")

        // A white body leaves them as authored: multiply == replace.
        let white =
            path.direct
            ? VertexColorScene.directTriangle(mode: .multiply)
            : VertexColorScene.triangle(mode: .multiply)
        VertexColorScene.expectGradient(try ParityRender.render([white], options), path.name)
    }

    @Test("Lit surfaces take their albedo from the vertex colours", arguments: MeshPath.all)
    func litSurface(path: Path) throws {
        let image = try ParityRender.render(
            [Self.body(path)], VertexColorScene.options(quality: path.quality, displayMode: .shaded)
        )
        ParityRender.dump(
            image.pixels, width: image.width, height: image.height,
            name: "vertex-colours-lit-\(path.name)")
        let nearRed = VertexColorScene.sample(image, VertexColorScene.nearCorner(0))
        let nearGreen = VertexColorScene.sample(image, VertexColorScene.nearCorner(1))
        let nearBlue = VertexColorScene.sample(image, VertexColorScene.nearCorner(2))
        #expect(nearRed.x > nearRed.y + 40 && nearRed.x > nearRed.z + 40, "red: \(nearRed)")
        #expect(
            nearGreen.y > nearGreen.x + 40 && nearGreen.y > nearGreen.z + 40, "green: \(nearGreen)")
        #expect(nearBlue.z > nearBlue.x + 40 && nearBlue.z > nearBlue.y + 40, "blue: \(nearBlue)")
    }

    @Test("Translucent bodies and x-ray keep the vertex colours", arguments: MeshPath.all)
    func translucentAndXray(path: Path) throws {
        // Opacity 0.5 over black halves the interpolated colour.
        let half = SIMD4<Float>(1, 1, 1, 0.5)
        let body: ViewportBody =
            path.direct
            ? VertexColorScene.directTriangle(color: half)
            : VertexColorScene.triangle(color: half)
        let translucent = try ParityRender.render(
            [body], VertexColorScene.options(quality: path.quality))
        let nearRed = VertexColorScene.sample(translucent, VertexColorScene.nearCorner(0))
        let nearBlue = VertexColorScene.sample(translucent, VertexColorScene.nearCorner(2))
        #expect(nearRed.x > 90 && nearRed.x < 135 && nearRed.y < 30, "translucent red: \(nearRed)")
        #expect(
            nearBlue.z > 90 && nearBlue.z < 135 && nearBlue.x < 30, "translucent blue: \(nearBlue)")

        // x-ray makes every surface translucent.
        let opaque = Self.body(path)
        let xray = try ParityRender.render(
            [opaque], VertexColorScene.options(quality: path.quality, displayMode: .xray))
        let xrayRed = VertexColorScene.sample(xray, VertexColorScene.nearCorner(0))
        #expect(xrayRed.x > xrayRed.y + 20 && xrayRed.x > xrayRed.z + 20, "x-ray red: \(xrayRed)")
    }

    @Test("Overlay bodies honour vertex colours too")
    func overlay() throws {
        let body = VertexColorScene.triangle(layer: .overlay)
        let image = try ParityRender.render([body], VertexColorScene.options())
        VertexColorScene.expectGradient(image, "overlay")
    }

    @Test("Switching the mode on a cached body uploads the colours without new geometry")
    func modeSwitchUploadsLazily() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options()
        var body = VertexColorScene.triangle(mode: .ignored)
        let generation = body.generation

        let plain = try ParityRender.render([body], options, renderer: renderer)
        let plainRed = VertexColorScene.sample(plain, VertexColorScene.nearCorner(0))
        #expect(plainRed.x > 200 && plainRed.y > 200 && plainRed.z > 200, "white body: \(plainRed)")

        body.vertexColorMode = .replace
        #expect(body.generation == generation, "the mode switch must hit the cached buffers")
        let coloured = try ParityRender.render([body], options, renderer: renderer)
        VertexColorScene.expectGradient(coloured, "after switching on")

        // New colours change the generation and the picture.
        body.vertexColors = [
            VertexColorScene.green, VertexColorScene.green, VertexColorScene.green,
        ]
        let green = try ParityRender.render([body], options, renderer: renderer)
        let nearRed = VertexColorScene.sample(green, VertexColorScene.nearCorner(0))
        #expect(nearRed.y > 200 && nearRed.x < 40, "re-uploaded colours: \(nearRed)")

        // And switching back restores the body colour.
        body.vertexColorMode = .ignored
        let back = try ParityRender.render([body], options, renderer: renderer)
        #expect(back.pixels == plain.pixels)
    }

    @Test("A point cloud keeps using its vertex colours whatever the mode")
    func pointCloudUnaffected() throws {
        let points = [SIMD3<Float>(-2, 0, 0), SIMD3<Float>(2, 0, 0)]
        func cloud(_ mode: VertexColorMode) -> ViewportBody {
            ViewportBody(
                id: "cloud", vertexData: [], indices: [], edges: [], vertices: points,
                vertexColors: [VertexColorScene.red, VertexColorScene.blue],
                vertexColorMode: mode, color: VertexColorScene.white, pointRadius: 0.4,
                primitiveKind: .point)
        }
        let options = VertexColorScene.options()
        let ignored = try ParityRender.render([cloud(.ignored)], options)
        let replaced = try ParityRender.render([cloud(.replace)], options)
        #expect(ignored.pixels == replaced.pixels)
        let left = ParityRender.rgb(ignored.pixels, width: ignored.width, x: 38, y: 64)
        #expect(left.x > 200 && left.z < 40, "left point should be red: \(left)")
    }
}

// MARK: - Live renderer

@MainActor
@Suite("Mesh vertex colours: live renderer")
struct MeshVertexColorLiveTests {

    static func makeRenderer(
        bodies: [ViewportBody], quality: RenderingQuality, displayMode: DisplayMode = .unlit,
        shadows: Bool = false, picking: Bool = false
    ) -> (controller: ViewportController, renderer: ViewportRenderer)? {
        makeRenderer(
            binding: .constant(bodies), quality: quality, displayMode: displayMode,
            shadows: shadows, picking: picking)
    }

    static func makeRenderer(
        binding: Binding<[ViewportBody]>, quality: RenderingQuality,
        displayMode: DisplayMode = .unlit, shadows: Bool = false, picking: Bool = false
    ) -> (controller: ViewportController, renderer: ViewportRenderer)? {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = shadows
        lighting.enableSSAO = false
        var configuration = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera,
            displayMode: displayMode,
            lightingConfiguration: lighting,
            showAxes: false,
            showGrid: false,
            enableSilhouettes: false,
            pickingConfiguration: PickingConfiguration(isEnabled: picking),
            renderingQuality: quality
        )
        configuration.backgroundColor = SIMD4<Float>(0, 0, 0, 1)
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = displayMode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: binding)
        else { return nil }
        return (controller, renderer)
    }

    static func render(
        _ bodies: [ViewportBody], quality: RenderingQuality, displayMode: DisplayMode = .unlit,
        shadows: Bool = false, picking: Bool = false
    ) throws -> (pixels: [UInt8], width: Int, height: Int) {
        guard
            let pair = makeRenderer(
                bodies: bodies, quality: quality, displayMode: displayMode, shadows: shadows,
                picking: picking),
            let pixels = pair.renderer.renderHeadlessBGRA(
                width: VertexColorScene.width, height: VertexColorScene.height,
                backgroundColor: pair.controller.configuration.backgroundColor)
        else {
            Issue.record("Metal device unavailable")
            throw ParityRender.Unavailable()
        }
        return (pixels, VertexColorScene.width, VertexColorScene.height)
    }

    @Test("The live renderer draws the gradient on every mesh path", arguments: MeshPath.all)
    func gradient(path: MeshPath) throws {
        let body = MeshVertexColorOffscreenTests.body(path)
        let image = try Self.render([body], quality: path.quality)
        VertexColorScene.expectGradient(image, "live \(path.name)")
    }

    @Test(
        "Live: empty or mismatched colours, and the default mode, match the body-colour render",
        arguments: MeshPath.all)
    func fallbacksMatchBaseline(path: MeshPath) throws {
        let base = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        func make(colors: [SIMD4<Float>], mode: VertexColorMode) -> ViewportBody {
            path.direct
                ? VertexColorScene.directTriangle(color: base, vertexColors: colors, mode: mode)
                : VertexColorScene.triangle(color: base, vertexColors: colors, mode: mode)
        }
        for displayMode in [DisplayMode.unlit, .shadedWithEdges] {
            let baseline = try Self.render(
                [make(colors: [], mode: .ignored)], quality: path.quality, displayMode: displayMode)
            for (name, variant) in [
                (
                    "colours set, mode ignored",
                    make(colors: VertexColorScene.gradient, mode: .ignored)
                ),
                ("empty colours, replace", make(colors: [], mode: .replace)),
                ("short colours, multiply", make(colors: [VertexColorScene.red], mode: .multiply)),
            ] {
                let image = try Self.render(
                    [variant], quality: path.quality, displayMode: displayMode)
                #expect(
                    image.pixels == baseline.pixels,
                    "live \(path.name), \(displayMode), \(name): differs from the body-colour render"
                )
            }
        }
    }

    @Test(
        "Shadow, SSAO-depth and pick passes run with vertex colours bound",
        arguments: [
            RenderingQuality.standard, .enhanced, .maximum,
        ])
    func otherPassesUnaffected(quality: RenderingQuality) async throws {
        let body = VertexColorScene.triangle()
        guard
            let pair = Self.makeRenderer(
                bodies: [body], quality: quality, displayMode: .shaded, shadows: true, picking: true
            ),
            let pixels = pair.renderer.renderHeadlessBGRA(
                width: VertexColorScene.width, height: VertexColorScene.height,
                backgroundColor: pair.controller.configuration.backgroundColor)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // Lit with shadows on: the red corner is still red.
        let red = ParityRender.rgb(
            pixels, width: VertexColorScene.width,
            x: VertexColorScene.pixel(VertexColorScene.nearCorner(0)).x,
            y: VertexColorScene.pixel(VertexColorScene.nearCorner(0)).y)
        #expect(red.x > red.y + 40 && red.x > red.z + 40, "red: \(red)")

        // The pick pass stamped the body, so a region pick over the frame finds it.
        let rect = CGRect(
            x: 0, y: 0, width: VertexColorScene.width, height: VertexColorScene.height)
        let results: [PickResult] = await withCheckedContinuation { continuation in
            pair.renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
        #expect(Set(results.map(\.bodyID)).contains(body.id), "the pick pass lost the body")
    }

    @Test(
        "Live: translucent and x-ray bodies keep the vertex colours",
        arguments: [
            RenderingQuality.standard, .enhanced, .maximum,
        ])
    func translucent(quality: RenderingQuality) throws {
        let half = VertexColorScene.triangle(color: SIMD4(1, 1, 1, 0.5))
        let image = try Self.render([half], quality: quality)
        let nearRed = VertexColorScene.sample(image, VertexColorScene.nearCorner(0))
        #expect(nearRed.x > 90 && nearRed.x < 135 && nearRed.y < 30, "translucent: \(nearRed)")

        let xray = try Self.render(
            [VertexColorScene.triangle()], quality: quality, displayMode: .xray)
        let xrayRed = VertexColorScene.sample(xray, VertexColorScene.nearCorner(0))
        #expect(xrayRed.x > xrayRed.y + 20 && xrayRed.x > xrayRed.z + 20, "x-ray: \(xrayRed)")
    }

    @Test("Live: overlay bodies honour vertex colours and a mode switch uploads them")
    func overlayAndModeSwitch() throws {
        let overlay = VertexColorScene.triangle(layer: .overlay)
        VertexColorScene.expectGradient(
            try Self.render([overlay], quality: .standard), "live overlay")

        // A bound body array: change the mode after the first frame, as an app would. The
        // generation is untouched, so the second frame hits the cached buffers.
        let box = BodyBox([VertexColorScene.triangle(mode: .ignored)])
        let binding = Binding(get: { box.bodies }, set: { box.bodies = $0 })
        guard
            let pair = Self.makeRenderer(binding: binding, quality: .standard),
            let first = pair.renderer.renderHeadlessBGRA(
                width: VertexColorScene.width, height: VertexColorScene.height,
                backgroundColor: pair.controller.configuration.backgroundColor)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let corner = VertexColorScene.pixel(VertexColorScene.nearCorner(0))
        let before = ParityRender.rgb(
            first, width: VertexColorScene.width, x: corner.x, y: corner.y)
        #expect(before.x > 200 && before.y > 200 && before.z > 200, "white body: \(before)")

        let generation = box.bodies[0].generation
        box.bodies[0].vertexColorMode = .replace
        #expect(box.bodies[0].generation == generation)
        guard
            let second = pair.renderer.renderHeadlessBGRA(
                width: VertexColorScene.width, height: VertexColorScene.height,
                backgroundColor: pair.controller.configuration.backgroundColor)
        else {
            Issue.record("renderer returned nil")
            return
        }
        VertexColorScene.expectGradient(
            (second, VertexColorScene.width, VertexColorScene.height), "live after switching on")
    }

    /// Mutable body storage behind a `Binding`.
    final class BodyBox {
        var bodies: [ViewportBody]
        init(_ bodies: [ViewportBody]) { self.bodies = bodies }
    }
}
