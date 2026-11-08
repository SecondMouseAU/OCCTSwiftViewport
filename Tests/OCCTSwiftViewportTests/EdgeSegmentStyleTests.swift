// EdgeSegmentStyleTests.swift
// OCCTSwiftViewport Tests
//
// Per-segment colour and visible range for edge polylines (issue #140): `ViewportBody.edgeColors`
// and `ViewportBody.edgeDrawRange`. The data and the slice maths are checked without a GPU; the
// rendering suites use a 12,000-segment raster of short horizontal segments (100 rows of 120,
// one pixel per world unit) and sample pixels at known segments, in both edge paths (quad strips
// and native lines), on the offscreen renderer, the live renderer, and the live pick pass.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import SwiftUI
import Testing
import UniformTypeIdentifiers
import simd

@testable import OCCTSwiftViewport

// MARK: - Scene

/// A 512 x 512 orthographic view where one world unit is one pixel, over a raster of
/// 12,000 four-pixel segments: segment `i` is in row `i / 120` at column `i % 120`.
private enum SegmentRaster {
    static let rows = 100
    static let perRow = 120
    static let count = rows * perRow
    static let size = 512

    static let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10, pivot: .zero, orthographicScale: Float(size), isOrthographic: true)

    /// Four distinct sRGB colours, the last a mid-grey: drawn as given it reads 128, where a
    /// linear-to-sRGB encode would read 188.
    static let palette: [SIMD4<Float>] = [
        SIMD4(0.9, 0.2, 0.1, 1), SIMD4(0.1, 0.7, 0.3, 1),
        SIMD4(0.2, 0.3, 0.9, 1), SIMD4(0.5, 0.5, 0.5, 1),
    ]

    static func color(_ segment: Int) -> SIMD4<Float> { palette[segment % palette.count] }

    static var colors: [SIMD4<Float>] { (0..<count).map(color) }

    /// 100 polylines of 120 segments, rows from the top down.
    ///
    /// The lines sit half a pixel off the pixel grid so a 1 px native line and a 2 px quad both
    /// fully cover the pixel row at `pixel`.
    static func polylines() -> [[SIMD3<Float>]] {
        (0..<rows).map { row in
            let y = 200.5 - 4 * Float(row)
            return (0...perRow).map { SIMD3<Float>(-240 + 4 * Float($0), y, 0) }
        }
    }

    static func body(
        id: String = "raster",
        color: SIMD4<Float> = SIMD4(1, 1, 1, 1),
        edgeColors: [SIMD4<Float>] = SegmentRaster.colors,
        edgeDrawRange: Range<Int>? = nil,
        edgeColorSpace: AuthoredColorSpace = .sRGB
    ) -> ViewportBody {
        ViewportBody(
            id: id, vertexData: [], indices: [], edges: polylines(),
            edgeIndices: (0..<Int32(count)).map { $0 },
            edgeColors: edgeColors, edgeDrawRange: edgeDrawRange,
            edgeColorSpace: edgeColorSpace, color: color)
    }

    /// IEC 61966-2-1 encode of a linear colour: what a `.linear` segment colour reads as.
    static func displayColor(_ c: SIMD4<Float>) -> SIMD4<Float> {
        func encode(_ v: Float) -> Float {
            v <= 0.003_130_8 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return SIMD4(encode(c.x), encode(c.y), encode(c.z), c.w)
    }

    /// The pixel in the middle of a segment's run, on its line's row.
    static func pixel(_ segment: Int) -> (x: Int, y: Int) {
        (18 + 4 * (segment % perRow), 55 + 4 * (segment / perRow))
    }
}

private struct RenderUnavailable: Error {}

private func rgb(_ pixels: [UInt8], width: Int, at p: (x: Int, y: Int)) -> SIMD3<Int> {
    let i = (p.y * width + p.x) * 4
    return SIMD3(Int(pixels[i + 2]), Int(pixels[i + 1]), Int(pixels[i]))
}

/// Whether `actual` (0-255) is within `tolerance` of the 0-1 colour `expected`.
private func matches(_ actual: SIMD3<Int>, _ expected: SIMD4<Float>, tolerance: Int = 4) -> Bool {
    let e = SIMD3<Int>(
        Int((expected.x * 255).rounded()), Int((expected.y * 255).rounded()),
        Int((expected.z * 255).rounded()))
    return abs(actual.x - e.x) <= tolerance && abs(actual.y - e.y) <= tolerance
        && abs(actual.z - e.z) <= tolerance
}

private func isBackground(_ actual: SIMD3<Int>) -> Bool {
    max(actual.x, actual.y, actual.z) <= 3
}

private func readBGRA(_ image: CGImage) -> ([UInt8], Int) {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
    buffer.withUnsafeMutableBytes { raw in
        if let ctx = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue)
        {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    return (buffer, width)
}

// MARK: - Data

@Suite("Edge segment style: data")
struct EdgeSegmentStyleDataTests {

    private func body() -> ViewportBody {
        ViewportBody(
            id: "b", vertexData: [], indices: [],
            edges: [
                [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)],
                [SIMD3(0, 1, 0)],
                [SIMD3(0, 2, 0), SIMD3(1, 2, 0)],
            ],
            color: SIMD4(1, 1, 1, 1))
    }

    @Test("All three default to off, so existing bodies are unchanged")
    func defaults() {
        let body = body()
        #expect(body.edgeColors.isEmpty)
        #expect(body.edgeDrawRange == nil)
        #expect(body.edgeColorSpace == .sRGB)
    }

    @Test("AuthoredColorSpace has the two spaces, sRGB first, and distinct shader codes")
    func colourSpaceCases() {
        #expect(AuthoredColorSpace.allCases == [.sRGB, .linear])
        #expect(AuthoredColorSpace.sRGB.shaderCode == 0)
        #expect(AuthoredColorSpace.linear.shaderCode == 1)
    }

    @Test("Changing edgeColorSpace takes no new generation and re-uploads nothing")
    func colourSpaceIsCheap() {
        var body = body()
        body.edgeColors = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1)]
        let generation = body.generation
        let colourTag = body.edgeColorsGeneration
        body.edgeColorSpace = .linear
        #expect(body.generation == generation)
        #expect(body.edgeColorsGeneration == colourTag, "the colour buffer would be re-uploaded")
    }

    @Test("The init takes the colour space")
    func initTakesColourSpace() {
        let body = ViewportBody(
            id: "l", vertexData: [], indices: [], edges: [], edgeColorSpace: .linear,
            color: SIMD4(1, 1, 1, 1))
        #expect(body.edgeColorSpace == .linear)
    }

    @Test("edgeSegmentCount flattens the polylines the way edgeIndices does")
    func segmentCount() {
        #expect(body().edgeSegmentCount == 3)  // 2 + 0 (a lone point) + 1
        #expect(
            ViewportBody(
                id: "e", vertexData: [], indices: [], edges: [], color: SIMD4(1, 1, 1, 1)
            ).edgeSegmentCount == 0)
        #expect(SegmentRaster.body().edgeSegmentCount == 12_000)
    }

    @Test("Assigning edgeColors or edgeDrawRange does not take a new generation (#166)")
    func cheapUpdatesKeepGeneration() {
        var body = body()
        let generation = body.generation
        body.edgeColors = [SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1)]
        body.edgeDrawRange = 1..<3
        body.edgeDrawRange = nil
        body.edgeColors[1] = SIMD4(1, 1, 0, 1)  // in-place mutation, too
        #expect(body.generation == generation, "the renderers would re-upload every buffer")
    }

    @Test("Geometry mutation still takes a new generation")
    func geometryStillBumps() {
        var body = body()
        let generation = body.generation
        body.edges.append([SIMD3(0, 3, 0), SIMD3(1, 3, 0)])
        #expect(body.generation != generation)
    }

    @Test("edgeColors has its own change tag, which edgeDrawRange and geometry leave alone")
    func colourGeneration() {
        var body = body()
        let initial = body.edgeColorsGeneration
        body.edgeDrawRange = 0..<1
        body.edges.append([SIMD3(0, 3, 0), SIMD3(1, 3, 0)])
        #expect(body.edgeColorsGeneration == initial)
        body.edgeColors = [SIMD4(1, 0, 0, 1)]
        #expect(body.edgeColorsGeneration != initial)
        let afterAssign = body.edgeColorsGeneration
        body.edgeColors[0] = SIMD4(0, 1, 0, 1)
        #expect(body.edgeColorsGeneration != afterAssign, "in-place mutation must be seen")
    }

    @Test("Copies share the colour tag until one is recoloured")
    func copiesShareTag() {
        var a = body()
        a.edgeColors = [SIMD4(1, 0, 0, 1)]
        var b = a
        #expect(a.edgeColorsGeneration == b.edgeColorsGeneration)
        b.edgeColors = [SIMD4(0, 1, 0, 1)]
        #expect(a.edgeColorsGeneration != b.edgeColorsGeneration)
    }

    @Test("The range clamps to the segments that exist")
    func rangeClamping() {
        func clamp(_ r: Range<Int>?, _ n: Int = 10) -> Range<Int> {
            EdgeSegmentStyle.drawnRange(r, segmentCount: n)
        }
        #expect(clamp(nil) == 0..<10)
        #expect(clamp(2..<5) == 2..<5)
        #expect(clamp(0..<0).isEmpty)
        #expect(clamp(5..<5).isEmpty)
        #expect(clamp(8..<50) == 8..<10, "overhang is cut at the last segment")
        #expect(clamp(-4..<3) == 0..<3, "a negative start is cut at the first")
        #expect(clamp(12..<20).isEmpty, "wholly past the end draws nothing")
        #expect(clamp(-9 ..< -2).isEmpty)
        #expect(clamp(nil, 0).isEmpty)
        #expect(clamp(0..<5, 0).isEmpty)
    }

    @Test("Colours are used only with exactly one per segment")
    func colourCountRule() {
        #expect(EdgeSegmentStyle.colorsMatch(colorCount: 5, segmentCount: 5))
        #expect(!EdgeSegmentStyle.colorsMatch(colorCount: 0, segmentCount: 5))
        #expect(!EdgeSegmentStyle.colorsMatch(colorCount: 4, segmentCount: 5))
        #expect(!EdgeSegmentStyle.colorsMatch(colorCount: 6, segmentCount: 5))
        #expect(!EdgeSegmentStyle.colorsMatch(colorCount: 0, segmentCount: 0))
    }

    @Test("Vertex slices land on segment boundaries of both edge buffers")
    func vertexSlices() {
        let polylines = [[SIMD3<Float>(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(3, 0, 0)]]
        let native = RendererSharedBuffers.nativeEdgeLineVertices(from: polylines)
        let quad = RendererSharedBuffers.quadEdgeLineVertices(from: polylines)
        let segments = 3
        #expect(native.count / 6 == segments * EdgeSegmentStyle.nativeVerticesPerSegment)
        #expect(quad.count / 9 == segments * EdgeSegmentStyle.quadVerticesPerSegment)

        let slice = 1..<3
        let n = EdgeSegmentStyle.nativeVertexSlice(slice)
        #expect(n.start == 2 && n.count == 4)
        // The slice opens on segment 1's start point (x = 1) in both layouts.
        #expect(native[n.start * 6] == 1)
        let q = EdgeSegmentStyle.quadVertexSlice(slice)
        #expect(q.start == 6 && q.count == 12)
        #expect(quad[q.start * 9] == 1)
    }
}

// MARK: - Offscreen rendering

@MainActor
@Suite("Edge segment style: offscreen rendering")
struct EdgeSegmentStyleOffscreenTests {

    private func render(
        _ bodies: [ViewportBody], quad: Bool, displayMode: DisplayMode = .shadedWithEdges,
        renderer sharedRenderer: OffscreenRenderer? = nil
    ) throws -> ([UInt8], Int) {
        guard let renderer = sharedRenderer ?? OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw RenderUnavailable()
        }
        let options = OffscreenRenderOptions(
            width: SegmentRaster.size, height: SegmentRaster.size,
            cameraState: SegmentRaster.camera, displayMode: displayMode,
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, msaaSampleCount: 1,
            edgeLineConfiguration: EdgeLineConfiguration(width: 2, useQuadExpansion: quad))
        guard let image = renderer.render(bodies: bodies, options: options) else {
            Issue.record("renderer returned nil image")
            throw RenderUnavailable()
        }
        return readBGRA(image)
    }

    @Test(
        "A 12,000-segment body draws each sampled segment in its own colour",
        arguments: [true, false])
    func segmentsDrawInTheirColours(quad: Bool) throws {
        let (pixels, width) = try render([SegmentRaster.body()], quad: quad)
        // Four segments, one per palette colour: the first row, mid-body and the last segment.
        let samples = [8, 773, 4810, 11_999]
        #expect(Set(samples.map { $0 % 4 }).count == 4)
        for segment in samples {
            let actual = rgb(pixels, width: width, at: SegmentRaster.pixel(segment))
            #expect(
                matches(actual, SegmentRaster.color(segment)),
                "segment \(segment): \(actual) vs \(SegmentRaster.color(segment))")
        }
    }

    @Test("Colours are sRGB display values drawn as given: mid-grey reads 128, not 188")
    func coloursAreNotReEncoded() throws {
        let (pixels, width) = try render([SegmentRaster.body()], quad: true)
        let grey = rgb(pixels, width: width, at: SegmentRaster.pixel(3))
        #expect(
            abs(grey.x - 128) <= 3 && abs(grey.y - 128) <= 3 && abs(grey.z - 128) <= 3, "\(grey)")
    }

    @Test(
        "Linear edge colours are converted for display: mid-grey 0.5 reads about 188",
        arguments: [true, false])
    func linearColoursAreConverted(quad: Bool) throws {
        let body = SegmentRaster.body(edgeColorSpace: .linear)
        let (pixels, width) = try render([body], quad: quad)
        let grey = rgb(pixels, width: width, at: SegmentRaster.pixel(3))
        #expect(
            abs(grey.x - 188) <= 3 && abs(grey.y - 188) <= 3 && abs(grey.z - 188) <= 3,
            "quad \(quad): \(grey)")
        for segment in [0, 1, 2, 773, 4810, 11_999] {
            let actual = rgb(pixels, width: width, at: SegmentRaster.pixel(segment))
            let expected = SegmentRaster.displayColor(SegmentRaster.color(segment))
            #expect(matches(actual, expected), "quad \(quad) segment \(segment): \(actual)")
        }
    }

    @Test(
        "A linear body with a range converts each slice colour, and alpha is not converted",
        arguments: [true, false])
    func linearWithRangeAndAlpha(quad: Bool) throws {
        var colors = SegmentRaster.colors
        colors[102] = SIMD4(1, 0, 0, 0.5)
        let body = SegmentRaster.body(
            edgeColors: colors, edgeDrawRange: 101..<222, edgeColorSpace: .linear)
        let (pixels, width) = try render([body], quad: quad)
        func pixel(_ i: Int) -> SIMD3<Int> { rgb(pixels, width: width, at: SegmentRaster.pixel(i)) }
        for inside in [101, 150, 221] {
            #expect(
                matches(pixel(inside), SegmentRaster.displayColor(SegmentRaster.color(inside))),
                "quad \(quad) segment \(inside): \(pixel(inside))")
        }
        #expect(isBackground(pixel(100)) && isBackground(pixel(222)))
        // Alpha 0.5 over black is half of the converted red (255), whether or not alpha were
        // (wrongly) encoded: 0.5 would encode to 0.74 and read 188.
        let half = pixel(102)
        #expect(abs(half.x - 128) <= 6 && half.y <= 3 && half.z <= 3, "quad \(quad): \(half)")
    }

    @Test("A meshed body's linear segment colours are converted too")
    func linearMeshedBody() throws {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 1, 0, 0, 1] }
        let verts = v(-20, 100) + v(20, 100) + v(20, 140) + v(-20, 140)
        let body = ViewportBody(
            id: "meshed", vertexData: verts, indices: [0, 1, 2, 0, 2, 3],
            edges: [[SIMD3(-40, 0.5, 0), SIMD3(40, 0.5, 0)]],
            edgeColors: [SIMD4(0.5, 0.5, 0.5, 1)], edgeColorSpace: .linear,
            color: SIMD4(0.1, 0.1, 0.1, 1))
        for quad in [true, false] {
            let (pixels, width) = try render([body], quad: quad)
            let actual = rgb(pixels, width: width, at: (SegmentRaster.size / 2, 255))
            #expect(matches(actual, SIMD4(0.735, 0.735, 0.735, 1), tolerance: 8), "\(actual)")
        }
    }

    @Test("A range draws only its segments, and the colours stay with their segments")
    func rangeDrawsOnlyTheSlice() throws {
        for quad in [true, false] {
            // 101 is not a multiple of the palette size: a draw that forgot where its slice
            // starts would colour segment 101 as segment 0.
            let body = SegmentRaster.body(edgeDrawRange: 101..<222)
            let (pixels, width) = try render([body], quad: quad)
            func pixel(_ i: Int) -> SIMD3<Int> {
                rgb(pixels, width: width, at: SegmentRaster.pixel(i))
            }
            for inside in [101, 119, 120, 150, 221] {
                #expect(
                    matches(pixel(inside), SegmentRaster.color(inside)),
                    "quad \(quad) segment \(inside): \(pixel(inside))")
            }
            for outside in [0, 50, 100, 222, 223, 5_000, 11_999] {
                #expect(
                    isBackground(pixel(outside)),
                    "quad \(quad) segment \(outside) is outside the range: \(pixel(outside))")
            }
        }
    }

    @Test("An empty range draws nothing, and a range past the end is cut at the last segment")
    func emptyAndOverhangingRanges() throws {
        for quad in [true, false] {
            let (empty, width) = try render([SegmentRaster.body(edgeDrawRange: 7..<7)], quad: quad)
            for i in [0, 7, 11_999] {
                #expect(isBackground(rgb(empty, width: width, at: SegmentRaster.pixel(i))))
            }
            let (tail, _) = try render(
                [SegmentRaster.body(edgeDrawRange: 11_990..<20_000)], quad: quad)
            #expect(
                matches(
                    rgb(tail, width: width, at: SegmentRaster.pixel(11_999)),
                    SegmentRaster.color(11_999)))
            #expect(isBackground(rgb(tail, width: width, at: SegmentRaster.pixel(11_989))))
        }
    }

    @Test(
        "A colour count that does not match falls back to the body colour",
        arguments: [true, false])
    func mismatchedColoursFallBack(quad: Bool) throws {
        let body = SegmentRaster.body(
            color: SIMD4(0.25, 0.6, 0.75, 1), edgeColors: Array(SegmentRaster.colors.dropLast()))
        let (pixels, width) = try render([body], quad: quad)
        for segment in [0, 5_000, 11_999] {
            let actual = rgb(pixels, width: width, at: SegmentRaster.pixel(segment))
            #expect(matches(actual, SIMD4(0.25, 0.6, 0.75, 1)), "segment \(segment): \(actual)")
        }
        // Too many, and none at all, fall back the same way.
        let tooMany = SegmentRaster.body(
            color: SIMD4(0.25, 0.6, 0.75, 1), edgeColors: SegmentRaster.colors + [SIMD4(1, 0, 0, 1)]
        )
        let none = SegmentRaster.body(color: SIMD4(0.25, 0.6, 0.75, 1), edgeColors: [])
        for fallback in [tooMany, none] {
            let (px, w) = try render([fallback], quad: quad)
            #expect(
                matches(rgb(px, width: w, at: SegmentRaster.pixel(42)), SIMD4(0.25, 0.6, 0.75, 1)))
        }
    }

    @Test("Recolouring a body that keeps its generation is picked up on the next render")
    func recolourIsPickedUp() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        var body = SegmentRaster.body()
        let (before, width) = try render([body], quad: true, renderer: renderer)
        let generation = body.generation
        body.edgeColors = SegmentRaster.colors.map { SIMD4(1 - $0.x, 1 - $0.y, 1 - $0.z, 1) }
        #expect(body.generation == generation)
        let (after, _) = try render([body], quad: true, renderer: renderer)
        let a = rgb(before, width: width, at: SegmentRaster.pixel(8))
        let b = rgb(after, width: width, at: SegmentRaster.pixel(8))
        let inverted = SegmentRaster.color(8)
        #expect(matches(a, inverted))
        #expect(matches(b, SIMD4(1 - inverted.x, 1 - inverted.y, 1 - inverted.z, 1)), "\(b)")
    }

    @Test("A meshed body's edges take the segment colour instead of the contrast edge colour")
    func meshedBodyEdges() throws {
        // A dark quad well away from the row, as in the other edge tests, so the row is
        // background except for the edge.
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 1, 0, 0, 1] }
        let verts = v(-20, 100) + v(20, 100) + v(20, 140) + v(-20, 140)
        func body(_ colors: [SIMD4<Float>]) -> ViewportBody {
            ViewportBody(
                id: "meshed", vertexData: verts, indices: [0, 1, 2, 0, 2, 3],
                edges: [[SIMD3(-40, 0.5, 0), SIMD3(0, 0.5, 0), SIMD3(40, 0.5, 0)]],
                edgeColors: colors, color: SIMD4(0.1, 0.1, 0.1, 1))
        }
        let row = SegmentRaster.size / 2 - 1  // world y = 0.5 is the middle of this pixel row
        for quad in [true, false] {
            let (pixels, width) = try render(
                [body([SIMD4(0.9, 0.2, 0.1, 1), SIMD4(0.1, 0.7, 0.3, 1)])], quad: quad)
            let left = rgb(pixels, width: width, at: (SegmentRaster.size / 2 - 20, row))
            let right = rgb(pixels, width: width, at: (SegmentRaster.size / 2 + 20, row))
            #expect(
                matches(left, SIMD4(0.9, 0.2, 0.1, 1), tolerance: 8), "quad \(quad) left \(left)")
            #expect(
                matches(right, SIMD4(0.1, 0.7, 0.3, 1), tolerance: 8), "quad \(quad) right \(right)"
            )

            // Without colours the same edge is the contrast colour: light on a dark body.
            let (plain, _) = try render([body([])], quad: quad)
            let contrast = rgb(plain, width: width, at: (SegmentRaster.size / 2 - 20, row))
            #expect(!matches(contrast, SIMD4(0.9, 0.2, 0.1, 1), tolerance: 20), "\(contrast)")
            #expect(max(contrast.x, contrast.y, contrast.z) > 100, "\(contrast)")
        }
    }

    @Test("A segment colour's alpha scales the edge: alpha 0 hides that segment")
    func segmentAlpha() throws {
        var colors = SegmentRaster.colors
        colors[8] = SIMD4(1, 0, 0, 0)
        colors[9] = SIMD4(1, 0, 0, 0.5)
        for quad in [true, false] {
            let (pixels, width) = try render([SegmentRaster.body(edgeColors: colors)], quad: quad)
            let hidden = rgb(pixels, width: width, at: SegmentRaster.pixel(8))
            let half = rgb(pixels, width: width, at: SegmentRaster.pixel(9))
            let shown = rgb(pixels, width: width, at: SegmentRaster.pixel(10))
            #expect(isBackground(hidden), "quad \(quad): \(hidden)")
            #expect(abs(half.x - 128) <= 6 && half.y <= 3 && half.z <= 3, "quad \(quad): \(half)")
            #expect(matches(shown, SegmentRaster.color(10)))
        }
    }

    /// Writes review PNGs when `EDGE_SEGMENTS_PNG_DIR` is set; otherwise a no-op.
    @Test("Dump review images when EDGE_SEGMENTS_PNG_DIR is set")
    func dumpImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["EDGE_SEGMENTS_PNG_DIR"] else {
            return
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let renderer = OffscreenRenderer() else { throw RenderUnavailable() }

        // A 12,000-segment spiral, coloured by move kind in runs of 1,000 segments.
        let segments = 12_000
        let points = (0...segments).map { i -> SIMD3<Float> in
            let t = Float(i) / Float(segments)
            let angle = t * 40 * .pi
            let radius = 20 + 220 * t
            return SIMD3(radius * cos(angle), radius * sin(angle), 0)
        }
        let kinds: [SIMD4<Float>] = [
            SIMD4(0.55, 0.55, 0.60, 1), SIMD4(0.15, 0.75, 0.35, 1), SIMD4(0.90, 0.30, 0.15, 1),
        ]
        var spiral = ViewportBody(
            id: "spiral", vertexData: [], indices: [], edges: [points],
            color: SIMD4(1, 1, 1, 1))
        spiral.edgeColors = (0..<segments).map { kinds[($0 / 1_000) % kinds.count] }

        let options = OffscreenRenderOptions(
            width: 512, height: 512, cameraState: SegmentRaster.camera,
            displayMode: .shadedWithEdges, backgroundColor: SIMD4(0.08, 0.08, 0.10, 1),
            appearance: .light, showGrid: false, showAxes: false,
            edgeLineConfiguration: EdgeLineConfiguration(width: 3))

        // Before: one colour for the whole path. After: per-segment colours, then a playhead.
        var plain = spiral
        plain.edgeColors = []
        for (name, body) in [("single-colour", plain), ("per-segment-colours", spiral)] {
            if let image = renderer.render(bodies: [body], options: options) {
                try Self.writePNG(image, to: url.appendingPathComponent("\(name).png"))
            }
        }
        var playhead = spiral
        playhead.edgeDrawRange = 0..<7_000
        if let image = renderer.render(bodies: [playhead], options: options) {
            try Self.writePNG(image, to: url.appendingPathComponent("draw-range-7000.png"))
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    @Test("Body without per-segment style renders exactly as before")
    func unstyledBodyUnchanged() throws {
        let plain = SegmentRaster.body(edgeColors: [])
        let ranged = SegmentRaster.body(edgeColors: [], edgeDrawRange: 0..<SegmentRaster.count)
        for quad in [true, false] {
            let (a, _) = try render([plain], quad: quad)
            let (b, _) = try render([ranged], quad: quad)
            #expect(a == b, "an explicit full range changed the image (quad \(quad))")
        }
    }
}

// MARK: - Live renderer

@MainActor
private final class BodyStore {
    var bodies: [ViewportBody]
    init(_ bodies: [ViewportBody]) { self.bodies = bodies }
    var binding: Binding<[ViewportBody]> {
        Binding(get: { self.bodies }, set: { self.bodies = $0 })
    }
}

/// A renderer holds its controller weakly and draws nothing once it is gone, so the controllers
/// the tests make live as long as the test process.
@MainActor
private var retainedControllers: [ViewportController] = []

@MainActor
private func makeLive(
    store: BodyStore, quad: Bool
) throws -> (ViewportController, ViewportRenderer) {
    var config = ViewportConfiguration()
    config.initialCameraState = SegmentRaster.camera
    config.edgeLineConfiguration = EdgeLineConfiguration(width: 2, useQuadExpansion: quad)
    config.backgroundColor = SIMD4(0, 0, 0, 1)
    config.pickingConfiguration = PickingConfiguration(isEnabled: true)
    let controller = ViewportController(configuration: config)
    controller.displayMode = .shadedWithEdges
    controller.showGrid = false
    controller.showAxes = false
    controller.enableTAA = false
    guard let renderer = ViewportRenderer(controller: controller, bodies: store.binding) else {
        Issue.record("Metal device unavailable; skipping headless render test")
        throw RenderUnavailable()
    }
    retainedControllers.append(controller)
    return (controller, renderer)
}

@MainActor
private func renderLive(_ renderer: ViewportRenderer) throws -> [UInt8] {
    guard
        let pixels = renderer.renderHeadlessBGRA(
            width: SegmentRaster.size, height: SegmentRaster.size,
            backgroundColor: SIMD4(0, 0, 0, 1))
    else {
        Issue.record("headless render returned nil")
        throw RenderUnavailable()
    }
    return pixels
}

@MainActor
@Suite("Edge segment style: live renderer")
struct EdgeSegmentStyleLiveTests {

    @Test(
        "The live renderer draws each sampled segment in its colour",
        arguments: [true, false])
    func liveColours(quad: Bool) throws {
        let store = BodyStore([SegmentRaster.body()])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        let pixels = try renderLive(renderer)
        for segment in [8, 773, 4810, 11_999] {
            let actual = rgb(pixels, width: SegmentRaster.size, at: SegmentRaster.pixel(segment))
            #expect(
                matches(actual, SegmentRaster.color(segment)),
                "quad \(quad) segment \(segment): \(actual)")
        }
    }

    @Test(
        "Scrubbing edgeDrawRange 60 times draws just the range and re-creates no buffer",
        arguments: [true, false])
    func scrubbingTouchesNoBuffers(quad: Bool) throws {
        let store = BodyStore([SegmentRaster.body(edgeDrawRange: 0..<0)])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        _ = try renderLive(renderer)
        let first = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        let generation = store.bodies[0].generation

        var last: [UInt8] = []
        for step in 1...60 {
            store.bodies[0].edgeDrawRange = 0..<(step * 150)
            last = try renderLive(renderer)
        }
        #expect(store.bodies[0].generation == generation)
        let after = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        #expect(after.native === first.native, "the native edge buffer was re-created")
        #expect(after.quad === first.quad, "the quad edge buffer was re-created")
        #expect(after.colors === first.colors, "the colour buffer was re-created by a range change")

        // 60 * 150 = 9000: the range now ends at segment 8999.
        let width = SegmentRaster.size
        #expect(
            matches(
                rgb(last, width: width, at: SegmentRaster.pixel(8_999)), SegmentRaster.color(8_999))
        )
        #expect(isBackground(rgb(last, width: width, at: SegmentRaster.pixel(9_000))))
        #expect(isBackground(rgb(last, width: width, at: SegmentRaster.pixel(11_999))))
    }

    @Test("Recolouring re-uploads only the colour buffer", arguments: [true, false])
    func recolourTouchesOnlyColours(quad: Bool) throws {
        let store = BodyStore([SegmentRaster.body()])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        let before = try renderLive(renderer)
        let first = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        let generation = store.bodies[0].generation

        store.bodies[0].edgeColors = SegmentRaster.colors.map { SIMD4($0.z, $0.x, $0.y, 1) }
        #expect(store.bodies[0].generation == generation)
        let after = try renderLive(renderer)
        let second = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        #expect(second.native === first.native)
        #expect(second.quad === first.quad)
        #expect(second.colors !== first.colors, "the colour buffer was not re-uploaded")

        let p = SegmentRaster.pixel(8)
        let c = SegmentRaster.color(8)
        let width = SegmentRaster.size
        #expect(matches(rgb(before, width: width, at: p), c))
        #expect(matches(rgb(after, width: width, at: p), SIMD4(c.z, c.x, c.y, 1)))

        // Dropping the colours returns the edges to the body colour.
        store.bodies[0].edgeColors = []
        let plain = try renderLive(renderer)
        #expect(matches(rgb(plain, width: width, at: p), SIMD4(1, 1, 1, 1)))
        #expect(try #require(renderer.cachedEdgeBuffers(for: "raster")).colors == nil)
    }

    @Test(
        "Flipping edgeColorSpace re-colours the next frame and touches no buffer",
        arguments: [true, false])
    func colourSpaceFlipTouchesNoBuffers(quad: Bool) throws {
        let store = BodyStore([SegmentRaster.body()])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        let srgb = try renderLive(renderer)
        let first = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        let generation = store.bodies[0].generation

        store.bodies[0].edgeColorSpace = .linear
        let linear = try renderLive(renderer)
        let second = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        #expect(store.bodies[0].generation == generation)
        #expect(second.native === first.native && second.quad === first.quad)
        #expect(second.colors === first.colors, "a colour-space change re-uploaded the colours")

        let width = SegmentRaster.size
        let p = SegmentRaster.pixel(3)  // the mid-grey segment
        let a = rgb(srgb, width: width, at: p)
        let b = rgb(linear, width: width, at: p)
        #expect(abs(a.x - 128) <= 3, "sRGB \(a)")
        #expect(abs(b.x - 188) <= 3, "linear \(b)")
        for segment in [8, 773, 11_999] {
            #expect(
                matches(
                    rgb(linear, width: width, at: SegmentRaster.pixel(segment)),
                    SegmentRaster.displayColor(SegmentRaster.color(segment))))
        }
    }

    @Test("Overlay-layer linear edge colours are converted", arguments: [true, false])
    func overlayLinear(quad: Bool) throws {
        var body = SegmentRaster.body(edgeDrawRange: 101..<222, edgeColorSpace: .linear)
        body.renderLayer = .overlay
        let store = BodyStore([body])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        let pixels = try renderLive(renderer)
        let actual = rgb(pixels, width: SegmentRaster.size, at: SegmentRaster.pixel(103))
        #expect(
            matches(actual, SegmentRaster.displayColor(SegmentRaster.color(103))),
            "quad \(quad): \(actual)")
    }

    @Test("Changing the edges themselves still rebuilds the buffers (#166)")
    func geometryChangeStillRebuilds() throws {
        let store = BodyStore([SegmentRaster.body()])
        let (_, renderer) = try makeLive(store: store, quad: true)
        _ = try renderLive(renderer)
        let first = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        store.bodies[0].edges = SegmentRaster.polylines().reversed()
        _ = try renderLive(renderer)
        let second = try #require(renderer.cachedEdgeBuffers(for: "raster"))
        #expect(second.quad !== first.quad)
    }

    @Test("Overlay-layer edges honour the colours and the range", arguments: [true, false])
    func overlayEdges(quad: Bool) throws {
        var body = SegmentRaster.body(edgeDrawRange: 101..<222)
        body.renderLayer = .overlay
        let store = BodyStore([body])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        let pixels = try renderLive(renderer)
        let width = SegmentRaster.size
        #expect(
            matches(
                rgb(pixels, width: width, at: SegmentRaster.pixel(101)), SegmentRaster.color(101)))
        #expect(
            matches(
                rgb(pixels, width: width, at: SegmentRaster.pixel(221)), SegmentRaster.color(221)))
        #expect(isBackground(rgb(pixels, width: width, at: SegmentRaster.pixel(100))))
        #expect(isBackground(rgb(pixels, width: width, at: SegmentRaster.pixel(222))))
    }
}

// MARK: - Pick pass

@MainActor
@Suite("Edge segment style: pick pass")
struct EdgeSegmentStylePickTests {

    private static func pick(_ renderer: ViewportRenderer, at pixel: SIMD2<Int>) async
        -> PickResult?
    {
        await withCheckedContinuation { continuation in
            renderer.performPick(at: pixel) { continuation.resume(returning: $0) }
        }
    }

    /// Picks at the pixel of a segment's line.
    ///
    /// Tries the rows either side of it too, as a native 1 px line is rasterised into one of them.
    private static func pickSegment(_ renderer: ViewportRenderer, _ i: Int) async -> PickResult? {
        let p = SegmentRaster.pixel(i)
        for dy in [0, 1, -1] {
            if let hit = await pick(renderer, at: SIMD2(p.x, p.y + dy)) { return hit }
        }
        return nil
    }

    @Test(
        "Only the segments the range shows can be picked, and they report their own index",
        arguments: [true, false])
    func pickHonoursRange(quad: Bool) async throws {
        let store = BodyStore([SegmentRaster.body(edgeDrawRange: 101..<222)])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        _ = try renderLive(renderer)

        for inside in [101, 119, 120, 180, 221] {
            let hit = await Self.pickSegment(renderer, inside)
            #expect(
                hit?.kind == .edge && hit?.triangleIndex == inside,
                "quad \(quad) segment \(inside): \(String(describing: hit))")
        }
        for outside in [0, 100, 222, 5_000] {
            let hit = await Self.pickSegment(renderer, outside)
            #expect(
                hit == nil, "quad \(quad) segment \(outside) is hidden: \(String(describing: hit))")
        }

        // Moving the range moves what is pickable, with no new frame of geometry.
        store.bodies[0].edgeDrawRange = 0..<10
        _ = try renderLive(renderer)
        let early = await Self.pickSegment(renderer, 7)
        #expect(early?.kind == .edge && early?.triangleIndex == 7, "\(String(describing: early))")
        #expect(await Self.pickSegment(renderer, 150) == nil)
    }

    @Test("Picking does not depend on the colour space", arguments: [true, false])
    func pickIgnoresColourSpace(quad: Bool) async throws {
        let store = BodyStore([
            SegmentRaster.body(edgeDrawRange: 101..<222, edgeColorSpace: .linear)
        ])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        _ = try renderLive(renderer)
        for inside in [101, 150, 221] {
            let hit = await Self.pickSegment(renderer, inside)
            #expect(
                hit?.kind == .edge && hit?.triangleIndex == inside,
                "quad \(quad) segment \(inside): \(String(describing: hit))")
        }
        #expect(await Self.pickSegment(renderer, 100) == nil)
        #expect(await Self.pickSegment(renderer, 222) == nil)
    }

    @Test("An empty range makes the body's edges unpickable", arguments: [true, false])
    func emptyRangeIsUnpickable(quad: Bool) async throws {
        let store = BodyStore([SegmentRaster.body(edgeDrawRange: 0..<0)])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        _ = try renderLive(renderer)
        #expect(await Self.pickSegment(renderer, 0) == nil)
        #expect(await Self.pickSegment(renderer, 11_999) == nil)
    }

    @Test("Without a range every segment is pickable, as before", arguments: [true, false])
    func fullRangePicks(quad: Bool) async throws {
        let store = BodyStore([SegmentRaster.body()])
        let (_, renderer) = try makeLive(store: store, quad: quad)
        _ = try renderLive(renderer)
        for segment in [0, 777, 11_999] {
            let hit = await Self.pickSegment(renderer, segment)
            #expect(
                hit?.kind == .edge && hit?.triangleIndex == segment,
                "quad \(quad) segment \(segment): \(String(describing: hit))")
        }
    }
}
