// VertexColorSpaceTests.swift
// OCCTSwiftViewport Tests
//
// `ViewportBody.vertexColorSpace` (issue #142): `vertexColors` are sRGB display values by default,
// exactly as before, and `.linear` takes them as linear light. One property governs mesh bodies on
// every path (interleaved, direct-mesh, PN tessellation, mesh shaders) and point clouds, in both
// renderers.

import CoreGraphics
import Foundation
import Metal
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Helpers

/// Colour conversions and scenes shared by the colour-space suites.
@MainActor
enum VertexColorSpaceScene {

    /// IEC 61966-2-1 sRGB to linear, per channel.
    static func decode(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func decode(_ c: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(decode(c.x), decode(c.y), decode(c.z), c.w)
    }

    /// The same grey at all three corners.
    static func grey(_ v: Float) -> [SIMD4<Float>] {
        [SIMD4<Float>(v, v, v, 1), SIMD4<Float>(v, v, v, 1), SIMD4<Float>(v, v, v, 1)]
    }

    /// An sRGB colour at all three corners.
    static func flat(_ c: SIMD4<Float>) -> [SIMD4<Float>] { [c, c, c] }

    /// A body for `path` with `colors` in `space`.
    static func body(
        _ path: MeshPath, colors: [SIMD4<Float>], mode: VertexColorMode = .replace,
        space: AuthoredColorSpace, color: SIMD4<Float> = VertexColorScene.white
    ) -> ViewportBody {
        path.direct
            ? VertexColorScene.directTriangle(
                color: color, vertexColors: colors, mode: mode, space: space)
            : VertexColorScene.triangle(
                color: color, vertexColors: colors, mode: mode, space: space)
    }

    /// The centre of the triangle.
    static func centre(_ image: (pixels: [UInt8], width: Int, height: Int)) -> SIMD3<Int> {
        VertexColorScene.sample(image, VertexColorScene.centroid)
    }

    /// Two points a point-cloud body draws as sprites, at pixels (38, 64) and (90, 64).
    static func cloud(
        colors: [SIMD4<Float>], space: AuthoredColorSpace = .sRGB,
        color: SIMD4<Float> = SIMD4(1, 0, 1, 1)
    ) -> ViewportBody {
        ViewportBody(
            id: "cloud", vertexData: [], indices: [], edges: [],
            vertices: [SIMD3<Float>(-2, 0, 0), SIMD3<Float>(2, 0, 0)],
            vertexColors: colors, vertexColorSpace: space, color: color, pointRadius: 0.4,
            primitiveKind: .point)
    }

    static func leftPoint(_ image: (pixels: [UInt8], width: Int, height: Int)) -> SIMD3<Int> {
        ParityRender.rgb(image.pixels, width: image.width, x: 38, y: 64)
    }

    static func expect(
        _ value: SIMD3<Int>, near expected: Int, within tolerance: Int, _ label: String
    ) {
        for channel in [value.x, value.y, value.z] {
            #expect(
                abs(channel - expected) <= tolerance, "\(label): \(value), expected ~\(expected)")
        }
    }

    static func expect(
        _ a: SIMD3<Int>, matches b: SIMD3<Int>, within tolerance: Int, _ label: String
    ) {
        let d = a &- b
        #expect(
            abs(d.x) <= tolerance && abs(d.y) <= tolerance && abs(d.z) <= tolerance,
            "\(label): \(a) vs \(b)")
    }
}

// MARK: - Model

@MainActor
@Suite("Vertex colour space: model")
struct VertexColorSpaceModelTests {

    @Test("AuthoredColorSpace has sRGB and linear, and sRGB is the body default")
    func cases() {
        #expect(AuthoredColorSpace.allCases == [.sRGB, .linear])
        let body = ViewportBody(id: "b", vertexData: [], indices: [], edges: [], color: .one)
        #expect(body.vertexColorSpace == .sRGB)
        let linear = ViewportBody(
            id: "l", vertexData: [], indices: [], edges: [], vertexColorSpace: .linear, color: .one)
        #expect(linear.vertexColorSpace == .linear)
    }

    @Test("The shader's mode word packs the mode and the space")
    func packedMode() {
        typealias Binding = RendererSharedSetup.VertexColorBinding
        // Bits 0-1: VertexColorMode. Bit 2: linear light.
        #expect(Binding.packedMode(mode: .multiply, space: .sRGB) == 1)
        #expect(Binding.packedMode(mode: .replace, space: .sRGB) == 2)
        #expect(Binding.packedMode(mode: .multiply, space: .linear) == 5)
        #expect(Binding.packedMode(mode: .replace, space: .linear) == 6)
        // Ignored is always 0, whatever the space, so it shades exactly as before.
        #expect(Binding.packedMode(mode: .ignored, space: .sRGB) == 0)
        #expect(Binding.packedMode(mode: .ignored, space: .linear) == 0)
        #expect(AuthoredColorSpace.sRGB.shaderValue == 0)
        #expect(AuthoredColorSpace.linear.shaderValue == 1)
    }

    @Test("The point-cloud shader's parameter struct keeps its 32-byte layout")
    func pointParamsLayout() {
        #expect(MemoryLayout<PointParamsSwift>.size == 32)
        #expect(MemoryLayout<PointParamsSwift>.offset(of: \.vertexColorSpace) == 28)
        #expect(
            PointParamsSwift(
                baseColor: .zero, worldRadius: 1, pxPerWorldFactor: 1, useVertexColors: 0
            )
            .vertexColorSpace == 0)
    }
}

// MARK: - Offscreen rendering

@MainActor
@Suite("Vertex colour space: offscreen rendering")
struct VertexColorSpaceOffscreenTests {

    @Test("A mid-grey is brighter as linear light than as an sRGB value", arguments: MeshPath.all)
    func midGrey(path: MeshPath) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options(quality: path.quality)
        let grey = VertexColorSpaceScene.grey(0.5)
        let srgb = try ParityRender.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .sRGB)], options,
            renderer: renderer)
        let linear = try ParityRender.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .linear)], options,
            renderer: renderer)
        // Unlit shows the display value: 0.5 as given is 128; 0.5 linear encodes to 0.735 = 188.
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(srgb), near: 128, within: 3, "\(path.name) sRGB")
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(linear), near: 188, within: 4, "\(path.name) linear")

        // Lit, the linear albedo is brighter too (0.5 against 0.214 once decoded).
        let lit = VertexColorScene.options(quality: path.quality, displayMode: .shaded)
        let litSRGB = try ParityRender.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .sRGB)], lit, renderer: renderer)
        let litLinear = try ParityRender.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .linear)], lit,
            renderer: renderer)
        #expect(
            VertexColorSpaceScene.centre(litLinear).x > VertexColorSpaceScene.centre(litSRGB).x
                + 25,
            "\(path.name) lit: linear \(VertexColorSpaceScene.centre(litLinear)) vs sRGB \(VertexColorSpaceScene.centre(litSRGB))"
        )
    }

    @Test(
        "A linear colour equals the sRGB colour it decodes from, unlit and lit",
        arguments: MeshPath.all)
    func decodedLinearMatchesSRGB(path: MeshPath) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let srgbColour = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        for displayMode in [DisplayMode.unlit, .shaded] {
            let options = VertexColorScene.options(quality: path.quality, displayMode: displayMode)
            let srgb = try ParityRender.render(
                [
                    VertexColorSpaceScene.body(
                        path, colors: VertexColorSpaceScene.flat(srgbColour), space: .sRGB)
                ], options, renderer: renderer)
            let linear = try ParityRender.render(
                [
                    VertexColorSpaceScene.body(
                        path,
                        colors: VertexColorSpaceScene.flat(
                            VertexColorSpaceScene.decode(srgbColour)),
                        space: .linear)
                ], options, renderer: renderer)
            VertexColorSpaceScene.expect(
                VertexColorSpaceScene.centre(linear), matches: VertexColorSpaceScene.centre(srgb),
                within: 2, "\(path.name) \(displayMode)")
        }
    }

    @Test("Linear colours interpolate in linear light", arguments: MeshPath.all)
    func interpolatesInLinear(path: MeshPath) throws {
        let options = VertexColorScene.options(quality: path.quality)
        let srgb = try ParityRender.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorScene.gradient, space: .sRGB)
            ], options)
        let linear = try ParityRender.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorScene.gradient, space: .linear)
            ], options)
        // A third of each channel: 85 stored as sRGB, but 1/3 linear encodes to 0.611 = 156.
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(srgb), near: 85, within: 10, "\(path.name) sRGB centre")
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(linear), near: 156, within: 12,
            "\(path.name) linear centre")
        // 0 and 1 are the same in both spaces, so the corners still read as their colour.
        let nearRed = VertexColorScene.sample(linear, VertexColorScene.nearCorner(0))
        #expect(
            nearRed.x > 220 && nearRed.y < 130 && nearRed.z < 130,
            "\(path.name) near red \(nearRed)")
    }

    @Test("Multiply with linear colours combines in linear light", arguments: MeshPath.all)
    func multiplyInLinear(path: MeshPath) throws {
        let options = VertexColorScene.options(quality: path.quality)
        let body = SIMD4<Float>(0.5, 0.5, 0.5, 1)
        // A white linear colour leaves the body colour as it was.
        let white = try ParityRender.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorSpaceScene.flat(VertexColorScene.white),
                    mode: .multiply, space: .linear, color: body)
            ], options)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(white), near: 128, within: 3, "\(path.name) x white")
        // Half linear light: decode(0.5) * 0.5 = 0.107, which encodes to 0.353 = 90 (an sRGB
        // multiply of 0.5 by 0.5 would give 0.25 = 64).
        let half = try ParityRender.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorSpaceScene.grey(0.5), mode: .multiply,
                    space: .linear, color: body)
            ], options)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(half), near: 90, within: 4, "\(path.name) x half")
        let srgbHalf = try ParityRender.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorSpaceScene.grey(0.5), mode: .multiply,
                    space: .sRGB, color: body)
            ], options)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(srgbHalf), near: 64, within: 3, "\(path.name) sRGB x half")
    }

    @Test(
        "The space changes nothing without usable colours or without a mode",
        arguments: MeshPath.all)
    func spaceIsInertWithoutColours(path: MeshPath) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let base = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        let lit: OffscreenRenderOptions = {
            var o = OffscreenRenderOptions(
                width: 128, height: 128, cameraState: ParityRender.frontCamera,
                displayMode: .shadedWithEdges)
            o.renderingQuality = path.quality
            o.tessellationMaxFactor = 16
            return o
        }()
        for (label, options) in [
            ("unlit", VertexColorScene.options(quality: path.quality)), ("lit", lit),
        ] {
            let baseline = try ParityRender.render(
                [
                    VertexColorSpaceScene.body(
                        path, colors: [], mode: .ignored, space: .sRGB, color: base)
                ], options, renderer: renderer)
            let variants: [(String, ViewportBody)] = [
                (
                    "colours set, mode ignored, linear",
                    VertexColorSpaceScene.body(
                        path, colors: VertexColorScene.gradient, mode: .ignored, space: .linear,
                        color: base)
                ),
                (
                    "empty colours, replace, linear",
                    VertexColorSpaceScene.body(
                        path, colors: [], mode: .replace, space: .linear, color: base)
                ),
                (
                    "short colours, multiply, linear",
                    VertexColorSpaceScene.body(
                        path, colors: [VertexColorScene.red], mode: .multiply, space: .linear,
                        color: base)
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

    @Test("Switching the colour space on a cached body needs no new geometry")
    func spaceSwitchIsPerFrame() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options()
        var body = VertexColorScene.triangle(vertexColors: VertexColorSpaceScene.grey(0.5))
        let generation = body.generation
        let srgb = try ParityRender.render([body], options, renderer: renderer)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(srgb), near: 128, within: 3, "sRGB")

        body.vertexColorSpace = .linear
        #expect(body.generation == generation)
        let linear = try ParityRender.render([body], options, renderer: renderer)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(linear), near: 188, within: 4, "after switching to linear")

        body.vertexColorSpace = .sRGB
        let back = try ParityRender.render([body], options, renderer: renderer)
        #expect(back.pixels == srgb.pixels)
    }

    @Test("Point clouds take their colours in the body's colour space")
    func pointCloud() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let options = VertexColorScene.options()
        let grey = VertexColorSpaceScene.grey(0.5)
        let colors = [grey[0], SIMD4<Float>(0, 0, 1, 1)]

        // The default is sRGB and unchanged: the explicit and the implicit render are identical,
        // and the point is the display value as given.
        let implicit = try ParityRender.render(
            [
                ViewportBody(
                    id: "cloud", vertexData: [], indices: [], edges: [],
                    vertices: [SIMD3<Float>(-2, 0, 0), SIMD3<Float>(2, 0, 0)],
                    vertexColors: colors, color: SIMD4(1, 0, 1, 1), pointRadius: 0.4,
                    primitiveKind: .point)
            ], options, renderer: renderer)
        let srgb = try ParityRender.render(
            [VertexColorSpaceScene.cloud(colors: colors, space: .sRGB)], options,
            renderer: renderer)
        #expect(implicit.pixels == srgb.pixels)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(srgb), near: 128, within: 3, "sRGB point")

        // Linear light is encoded for display: 0.5 becomes 188, and pure blue is still blue.
        let linear = try ParityRender.render(
            [VertexColorSpaceScene.cloud(colors: colors, space: .linear)], options,
            renderer: renderer)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(linear), near: 188, within: 4, "linear point")
        let right = ParityRender.rgb(linear.pixels, width: linear.width, x: 90, y: 64)
        #expect(right.z > 240 && right.x < 15 && right.y < 15, "linear blue point \(right)")

        // A linear colour equals the sRGB colour it decodes from.
        let amber = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        let amberSRGB = try ParityRender.render(
            [VertexColorSpaceScene.cloud(colors: [amber, amber], space: .sRGB)], options,
            renderer: renderer)
        let amberLinear = try ParityRender.render(
            [
                VertexColorSpaceScene.cloud(
                    colors: [
                        VertexColorSpaceScene.decode(amber), VertexColorSpaceScene.decode(amber),
                    ],
                    space: .linear)
            ], options, renderer: renderer)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(amberLinear),
            matches: VertexColorSpaceScene.leftPoint(amberSRGB), within: 2, "amber")

        // The space governs `vertexColors` only: the body colour fallback is an sRGB value.
        let fallbackSRGB = try ParityRender.render(
            [VertexColorSpaceScene.cloud(colors: [], space: .sRGB)], options, renderer: renderer)
        let fallbackLinear = try ParityRender.render(
            [VertexColorSpaceScene.cloud(colors: [], space: .linear)], options, renderer: renderer)
        #expect(fallbackSRGB.pixels == fallbackLinear.pixels)
        let magenta = VertexColorSpaceScene.leftPoint(fallbackLinear)
        #expect(magenta.x > 240 && magenta.y < 15 && magenta.z > 240, "fallback \(magenta)")
    }
}

// MARK: - Live renderer

@MainActor
@Suite("Vertex colour space: live renderer")
struct VertexColorSpaceLiveTests {

    @Test("Live: linear versus sRGB mid-grey on every mesh path", arguments: MeshPath.all)
    func midGrey(path: MeshPath) throws {
        let grey = VertexColorSpaceScene.grey(0.5)
        let srgb = try MeshVertexColorLiveTests.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .sRGB)], quality: path.quality)
        let linear = try MeshVertexColorLiveTests.render(
            [VertexColorSpaceScene.body(path, colors: grey, space: .linear)], quality: path.quality)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(srgb), near: 128, within: 3, "live \(path.name) sRGB")
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(linear), near: 188, within: 4, "live \(path.name) linear")

        // The decoded linear colour equals the sRGB one, lit.
        let amber = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        let litSRGB = try MeshVertexColorLiveTests.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorSpaceScene.flat(amber), space: .sRGB)
            ], quality: path.quality, displayMode: .shaded)
        let litLinear = try MeshVertexColorLiveTests.render(
            [
                VertexColorSpaceScene.body(
                    path, colors: VertexColorSpaceScene.flat(VertexColorSpaceScene.decode(amber)),
                    space: .linear)
            ], quality: path.quality, displayMode: .shaded)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.centre(litLinear), matches: VertexColorSpaceScene.centre(litSRGB),
            within: 2, "live \(path.name) lit")
    }

    @Test(
        "Live: the space is inert without usable colours or a mode", arguments: MeshPath.all)
    func spaceIsInertWithoutColours(path: MeshPath) throws {
        let base = SIMD4<Float>(0.8, 0.4, 0.1, 1)
        for displayMode in [DisplayMode.unlit, .shadedWithEdges] {
            let baseline = try MeshVertexColorLiveTests.render(
                [
                    VertexColorSpaceScene.body(
                        path, colors: [], mode: .ignored, space: .sRGB, color: base)
                ], quality: path.quality, displayMode: displayMode)
            for (name, variant) in [
                (
                    "colours set, mode ignored, linear",
                    VertexColorSpaceScene.body(
                        path, colors: VertexColorScene.gradient, mode: .ignored, space: .linear,
                        color: base)
                ),
                (
                    "empty colours, replace, linear",
                    VertexColorSpaceScene.body(
                        path, colors: [], mode: .replace, space: .linear, color: base)
                ),
            ] {
                let image = try MeshVertexColorLiveTests.render(
                    [variant], quality: path.quality, displayMode: displayMode)
                #expect(
                    image.pixels == baseline.pixels,
                    "live \(path.name), \(displayMode), \(name): differs from the body-colour render"
                )
            }
        }
    }

    @Test("Live: point clouds take their colours in the body's colour space")
    func pointCloud() throws {
        let colors = [VertexColorSpaceScene.grey(0.5)[0], SIMD4<Float>(0, 0, 1, 1)]
        let srgb = try MeshVertexColorLiveTests.render(
            [VertexColorSpaceScene.cloud(colors: colors, space: .sRGB)], quality: .standard)
        let linear = try MeshVertexColorLiveTests.render(
            [VertexColorSpaceScene.cloud(colors: colors, space: .linear)], quality: .standard)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(srgb), near: 128, within: 3, "live sRGB point")
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(linear), near: 188, within: 4, "live linear point")

        // An overlay point cloud goes through the same shader with the same parameter.
        var overlay = VertexColorSpaceScene.cloud(colors: colors, space: .linear)
        overlay.renderLayer = .overlay
        let overlaid = try MeshVertexColorLiveTests.render([overlay], quality: .standard)
        VertexColorSpaceScene.expect(
            VertexColorSpaceScene.leftPoint(overlaid), near: 188, within: 4, "live overlay point")
    }
}
