// HeightfieldRenderingTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 1: the heightfield render core. A grid of cell heights is drawn as
// 64 x 64-cell tiles at per-tile levels of detail from a min-height pyramid, with crack-free
// seams between tiles of different levels. Every test renders through `OffscreenRenderer`.

import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Helpers

@MainActor
enum HeightfieldScene {

    /// Magenta: a colour no shaded surface here produces, so any such pixel is a hole.
    static let background = SIMD4<Float>(1, 0, 1, 1)

    static func isBackground(_ c: SIMD3<Int>) -> Bool { c.x > 245 && c.y < 10 && c.z > 245 }

    static func options(
        width: Int, height: Int, camera: CameraState, displayMode: DisplayMode = .shaded
    ) -> OffscreenRenderOptions {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        return OffscreenRenderOptions(
            width: width, height: height, cameraState: camera, displayMode: displayMode,
            lightingConfiguration: lighting, backgroundColor: background, appearance: .light,
            showGrid: false, showAxes: false, msaaSampleCount: 1, enableSilhouettes: false)
    }

    static func body(
        _ field: Heightfield, id: String = "field",
        color: SIMD4<Float> = SIMD4(0.25, 0.65, 0.3, 1)
    ) -> ViewportBody {
        ViewportBody(
            id: id, vertexData: [], indices: [], edges: [], color: color, heightfield: field)
    }

    /// A hash in -1...1, the same for a cell every time.
    static func noise(_ x: Int, _ y: Int) -> Float {
        var h =
            UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y)
            &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 32_767.5 - 1
    }

    /// Rolling terrain with cell-scale roughness, in cells, so every level of detail has
    /// something different to represent and a seam that did not match would open a visible gap.
    static func terrain(_ x: Int, _ y: Int) -> Float {
        40 * sin(Float(x) * 0.004) * cos(Float(y) * 0.005)
            + 15 * sin(Float(x) * 0.02 + Float(y) * 0.015) + 10 * noise(x, y)
    }

    static func terrainField(width: Int, height: Int) throws -> Heightfield {
        var heights = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { heights[y * width + x] = terrain(x, y) }
        }
        return try Heightfield(width: width, height: height, heights: heights)
    }

    /// A camera `elevation` radians off straight down, `distance` away, about +X.
    static func camera(
        pivot: SIMD3<Float>, distance: Float, tilt: Float, orthographicScale: Float? = nil
    ) -> CameraState {
        CameraState(
            rotation: simd_quatf(angle: tilt, axis: SIMD3(1, 0, 0)), distance: distance,
            pivot: pivot, orthographicScale: orthographicScale ?? 10,
            isOrthographic: orthographicScale != nil)
    }

    /// `mask` with every `true` grown by `radius` pixels in each direction (a box dilation).
    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for xx in max(0, x - radius)...min(width - 1, x + radius) {
                    horizontal[y * width + xx] = true
                }
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where horizontal[y * width + x] {
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    out[yy * width + x] = true
                }
            }
        }
        return out
    }

    /// Writes BGRA8 `pixels` as a PNG, for looking at a failing render.
    static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) {
        var copy = pixels
        let image = copy.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ).rawValue
            )?.makeImage()
        }
        guard let image,
            let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static func pixels(_ image: CGImage) -> (pixels: [UInt8], width: Int, height: Int) {
        let (p, w, h) = ParityRender.bgra(image)
        return (p, w, h)
    }
}

// MARK: - Pyramid

@MainActor
@Suite("Heightfield min pyramid (#139)")
struct HeightfieldPyramidTests {

    /// The reference: level L texel k = min of level L-1 texels 2k-1...2k+1 (both axes), clamped.
    static func referencePyramid(heights: [Float], width: Int, height: Int) -> [[Float]] {
        func maxTexel(_ extent: Int, _ level: Int) -> Int {
            (extent - 1 + (1 << level) - 1) >> level
        }
        var levels: [[Float]] = [heights]
        var previousWidth = width
        var previousHeight = height
        for level in 1...HeightfieldLayout.maxLevel {
            let w = maxTexel(width, level) + 1
            let h = maxTexel(height, level) + 1
            let pw = maxTexel(width, level - 1) + 1
            let ph = maxTexel(height, level - 1) + 1
            _ = (previousWidth, previousHeight)
            var out = [Float](repeating: 0, count: w * h)
            let previous = levels[level - 1]
            let stride = level == 1 ? width : maxTexel(width, level - 1) + 1
            for y in 0..<h {
                for x in 0..<w {
                    var m = Float.infinity
                    for yy in max(2 * y - 1, 0)...min(2 * y + 1, ph - 1) {
                        for xx in max(2 * x - 1, 0)...min(2 * x + 1, pw - 1) {
                            m = min(m, previous[yy * stride + xx])
                        }
                    }
                    out[y * w + x] = m
                }
            }
            levels.append(out)
            previousWidth = w
            previousHeight = h
        }
        return levels
    }

    @Test("Every pyramid level holds the min of the level below, on an awkward size")
    func pyramidMatchesReference() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let width = 213
        let height = 131
        var heights = [Float](repeating: 0, count: width * height)
        var seed: UInt32 = 12345
        for i in heights.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            heights[i] = Float(seed >> 8) / Float(1 << 24) * 40 - 20
        }
        let field = try Heightfield(width: width, height: height, heights: heights)
        let body = HeightfieldScene.body(field)
        let options = HeightfieldScene.options(
            width: 64, height: 64,
            camera: HeightfieldScene.camera(pivot: SIMD3(100, 60, 0), distance: 300, tilt: 0))
        _ = renderer.render(bodies: [body], options: options)
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))

        let reference = Self.referencePyramid(heights: heights, width: width, height: height)
        func maxTexel(_ extent: Int, _ level: Int) -> Int {
            (extent - 1 + (1 << level) - 1) >> level
        }
        for level in 0...HeightfieldLayout.maxLevel {
            let readback = try #require(
                state.readLevel(level, commandQueue: renderer.testCommandQueue))
            let w = maxTexel(width, level) + 1
            let h = maxTexel(height, level) + 1
            var worst: Float = 0
            for y in 0..<h {
                for x in 0..<w {
                    let got = readback.values[y * readback.width + x]
                    let expected = reference[level][y * w + x]
                    worst = max(worst, abs(got - expected))
                }
            }
            #expect(
                worst == 0, "level \(level): GPU pyramid differs from the min reference by \(worst)"
            )
        }
    }

    @Test("A coarse level never rises above the fine cell it stands for")
    func coarseNeverAboveCentre() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try HeightfieldScene.terrainField(width: 300, height: 200)
        let options = HeightfieldScene.options(
            width: 64, height: 64,
            camera: HeightfieldScene.camera(pivot: SIMD3(150, 100, 0), distance: 400, tilt: 0))
        _ = renderer.render(bodies: [HeightfieldScene.body(field)], options: options)
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        for level in 1...HeightfieldLayout.maxLevel {
            let s = 1 << level
            let readback = try #require(
                state.readLevel(level, commandQueue: renderer.testCommandQueue))
            for ty in 0..<(199 / s + 1) {
                for tx in 0..<(299 / s + 1) {
                    let fine = field.sample(x: min(tx * s, 299), y: min(ty * s, 199))!.height
                    #expect(readback.values[ty * readback.width + tx] <= fine)
                }
            }
        }
    }
}

// MARK: - Rendering

@MainActor
@Suite("Heightfield rendering (#139)")
struct HeightfieldRenderingTests {

    private func rgb(_ p: (pixels: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> SIMD3<
        Int
    > {
        ParityRender.rgb(p.pixels, width: p.width, x: x, y: y)
    }

    @Test("A flat field renders as a lit plane, with the whole footprint covered")
    func flatFieldRenders() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try Heightfield(width: 100, height: 100, initialHeight: 2)
        let options = HeightfieldScene.options(
            width: 128, height: 128,
            camera: HeightfieldScene.camera(
                pivot: SIMD3(50, 50, 2), distance: 100, tilt: 0, orthographicScale: 120))
        let image = try #require(
            renderer.render(bodies: [HeightfieldScene.body(field)], options: options))
        let p = HeightfieldScene.pixels(image)
        #expect(!HeightfieldScene.isBackground(rgb(p, 64, 64)))
        #expect(HeightfieldScene.isBackground(rgb(p, 2, 2)))
        // 120 world units over 128 px: the field's mesh spans cell centres 0.5...99.5.
        let covered = ParityRender.count(p.pixels, width: p.width, height: p.height) {
            !HeightfieldScene.isBackground($0)
        }
        let expected = Int((99.0 / 120.0 * 128.0) * (99.0 / 120.0 * 128.0))
        #expect(
            abs(covered - expected) < expected / 20,
            "covered \(covered), expected about \(expected)")
    }

    @Test("A single cell at a different height changes the shading around it, not elsewhere")
    func normalsFromHeightDifferences() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var heights = [Float](repeating: 0, count: 64 * 64)
        for y in 28..<36 { for x in 28..<36 { heights[y * 64 + x] = 4 } }
        let field = try Heightfield(width: 64, height: 64, heights: heights)
        let options = HeightfieldScene.options(
            width: 256, height: 256,
            camera: HeightfieldScene.camera(
                pivot: SIMD3(32, 32, 0), distance: 100, tilt: 0.5, orthographicScale: 80))
        let image = try #require(
            renderer.render(bodies: [HeightfieldScene.body(field)], options: options))
        let p = HeightfieldScene.pixels(image)
        // Far from the bump the plane is flat: neighbouring pixels agree exactly.
        #expect(rgb(p, 60, 128) == rgb(p, 61, 128))
        // Across the bump the shading changes.
        var distinct = Set<Int>()
        for x in 100..<160 {
            let c = rgb(p, x, 128)
            distinct.insert(c.x * 65_536 + c.y * 256 + c.z)
        }
        #expect(distinct.count >= 3, "the bump left the shading flat (\(distinct.count) shades)")
    }

    @Test("Attribute 0 shades as the material; other values take their ramp colour")
    func attributeRamp() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let width = 64
        var attributes = [UInt8](repeating: 0, count: width * width)
        for y in 0..<width {
            for x in 32..<48 { attributes[y * width + x] = 7 }
            for x in 48..<64 { attributes[y * width + x] = 200 }
        }
        let field = try Heightfield(
            width: width, height: width, heights: [Float](repeating: 0, count: width * width),
            attributes: attributes)
        var ramp = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 256)
        ramp[7] = SIMD4(1, 0, 0, 1)
        ramp[200] = SIMD4(0, 0, 1, 1)
        field.ramp = ramp
        var options = HeightfieldScene.options(
            width: 128, height: 128,
            camera: HeightfieldScene.camera(
                pivot: SIMD3(32, 32, 0), distance: 100, tilt: 0, orthographicScale: 70),
            displayMode: .unlit)
        options.backgroundColor = SIMD4(0, 0, 0, 1)
        let body = HeightfieldScene.body(field, color: SIMD4(0, 1, 0, 1))
        let image = try #require(renderer.render(bodies: [body], options: options))
        let p = HeightfieldScene.pixels(image)
        // Unlit draws the albedo as authored: pure colours.
        let scale = 128.0 / 70.0
        func pixel(forCell x: Int) -> Int { 64 + Int((Double(x) + 0.5 - 32) * scale) }
        #expect(rgb(p, pixel(forCell: 8), 64) == SIMD3(0, 255, 0))
        #expect(rgb(p, pixel(forCell: 40), 64) == SIMD3(255, 0, 0))
        #expect(rgb(p, pixel(forCell: 56), 64) == SIMD3(0, 0, 255))
    }

    // MARK: Phase 1 gate

    /// The rolling terrain at 2000 x 2000 cells, seen obliquely from near one corner so tiles
    /// span several levels of detail.
    private func obliqueOptions() -> OffscreenRenderOptions {
        HeightfieldScene.options(
            width: 512, height: 512,
            // From below, so that a crack lets the background through instead of more surface.
            camera: HeightfieldScene.camera(
                pivot: SIMD3(700, 700, 0), distance: 1700, tilt: Float.pi - 1.0))
    }

    @Test("2000 x 2000 cells: three or more levels, no cracks against the full-resolution render")
    func noCracks() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try HeightfieldScene.terrainField(width: 2000, height: 2000)
        let body = HeightfieldScene.body(field)
        let options = obliqueOptions()

        // The reference: every tile at level 0, so there are no seams at all.
        renderer.heightfieldForcedLevel = 0
        let referenceImage = try #require(renderer.render(bodies: [body], options: options))
        let reference = HeightfieldScene.pixels(referenceImage)
        renderer.heightfieldForcedLevel = nil
        let image = try #require(renderer.render(bodies: [body], options: options))
        let lod = HeightfieldScene.pixels(image)
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))

        if let dir = ProcessInfo.processInfo.environment["VIEWPORT_SPIKE_PNG_DIR"] {
            for (name, img) in [("hf-cracks-ref", referenceImage), ("hf-cracks-lod", image)] {
                if let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: "\(dir)/\(name).png") as CFURL, "public.png" as CFString,
                    1, nil)
                {
                    CGImageDestinationAddImage(dest, img, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
        }
        let histogram = state.lastPlan?.levelHistogram ?? []
        let usedLevels = histogram.filter { $0 > 0 }.count
        #expect(usedLevels >= 3, "only \(usedLevels) levels in use: \(histogram)")

        // A pixel the reference covers, with everything within `margin` pixels covered too
        // (clear of the silhouette, which the coarse levels' min heights shift by a few pixels),
        // must not be background in the level-of-detail render.
        let margin = 8
        let w = reference.width
        let h = reference.height
        let background = (0..<(w * h)).map {
            HeightfieldScene.isBackground(rgb(reference, $0 % w, $0 / w))
        }
        let nearBackground = HeightfieldScene.dilate(
            background, width: w, height: h, radius: margin)
        var interior = 0
        var holes = 0
        for y in 0..<h {
            for x in 0..<w where !nearBackground[y * w + x] {
                interior += 1
                if HeightfieldScene.isBackground(rgb(lod, x, y)) { holes += 1 }
            }
        }
        #expect(interior > 50_000, "the reference covers only \(interior) interior pixels")
        #expect(holes == 0, "\(holes) background pixels inside the surface (levels \(histogram))")
    }

    @Test("A far tile at the coarsest level is two triangles")
    func coarsestLevelIsOneQuad() {
        #expect(HeightfieldLayout.tileCells >> HeightfieldLayout.maxLevel == 1)
        #expect(
            HeightfieldLayout.level(cellPixels: 0.01, targetPixels: 2) == HeightfieldLayout.maxLevel
        )
        #expect(HeightfieldLayout.level(cellPixels: 3, targetPixels: 2) == 0)
        #expect(HeightfieldLayout.level(cellPixels: 0.5, targetPixels: 2) == 2)
    }
}
