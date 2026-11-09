// HeightfieldUpdateTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 2: the update path. `Heightfield.replace` edits a CPU mirror and logs the
// rectangle; each renderer uploads only the 64 x 64 tiles those edits touched since the version it
// last drew, rebuilds the pyramid over them, and draws correctly however many edits piled up.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
enum HeightfieldUpdates {

    /// A deterministic `count`-value patch, distinct per `seed`.
    static func patch(_ region: HeightfieldRegion, seed: Int, amplitude: Float = 30) -> [Float] {
        (0..<region.cellCount).map {
            amplitude
                * HeightfieldScene.noise($0 % region.width + seed * 7, $0 / region.width + seed)
                + Float(seed % 13)
        }
    }

    static func attributes(_ region: HeightfieldRegion, seed: Int) -> [UInt8] {
        (0..<region.cellCount).map { UInt8(1 + (($0 / 5 + seed) % 250)) }
    }

    /// The field's current heights and attributes.
    static func mirrors(_ field: Heightfield) -> (heights: [Float], attributes: [UInt8]) {
        field.withMirrors { h, a in (Array(h), Array(a)) }
    }

    /// A fresh field holding exactly `field`'s current contents.
    static func copy(of field: Heightfield) -> Heightfield {
        let m = mirrors(field)
        return Heightfield(
            width: field.width, height: field.height, origin: field.origin,
            cellSize: field.cellSize, heights: m.heights, attributes: m.attributes)
    }

    /// `count` regions of `size`, spread over the field without overlap (a grid, row by row).
    static func disjointRegions(
        count: Int, size: SIMD2<Int>, in field: Heightfield
    ) -> [HeightfieldRegion] {
        var out: [HeightfieldRegion] = []
        var y = 0
        while y + size.y <= field.height, out.count < count {
            var x = 0
            while x + size.x <= field.width, out.count < count {
                out.append(HeightfieldRegion(x: x, y: y, width: size.x, height: size.y))
                x += size.x
            }
            y += size.y
        }
        return out
    }

    /// `count` regions of `size` that slide by one cell each, so almost all of each overlaps the
    /// last.
    static func overlappingRegions(
        count: Int, size: SIMD2<Int>, from start: SIMD2<Int>
    ) -> [HeightfieldRegion] {
        (0..<count).map {
            HeightfieldRegion(
                x: start.x + $0 % 40, y: start.y + $0 / 40, width: size.x, height: size.y)
        }
    }

    /// A projector for a top-down orthographic camera: world XY to pixel.
    @MainActor
    struct TopDown {
        var camera: CameraState
        var width: Int
        var height: Int

        init(pivot: SIMD3<Float>, scale: Float, width: Int, height: Int) {
            camera = HeightfieldScene.camera(
                pivot: pivot, distance: 500, tilt: 0, orthographicScale: scale)
            self.width = width
            self.height = height
        }

        var viewProjection: simd_float4x4 {
            camera.projectionMatrix(
                aspectRatio: Float(width) / Float(height), near: 1, far: 10_000) * camera.viewMatrix
        }

        func pixel(_ x: Float, _ y: Float, z: Float = 0) -> SIMD2<Float> {
            let p = ProjectionUtility.worldToScreen(
                point: SIMD3(x, y, z), vpMatrix: viewProjection,
                viewportSize: CGSize(width: width, height: height))!
            return SIMD2(Float(p.x), Float(p.y))
        }
    }

    /// Pixels that differ between two BGRA buffers and lie outside `keep` (a pixel rectangle).
    static func differingPixels(
        _ a: [UInt8], _ b: [UInt8], width: Int, height: Int,
        outside keep: (x0: Int, y0: Int, x1: Int, y1: Int)
    ) -> (outside: Int, inside: Int) {
        var outside = 0
        var inside = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                guard a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] else { continue }
                if x >= keep.x0 && x <= keep.x1 && y >= keep.y0 && y <= keep.y1 {
                    inside += 1
                } else {
                    outside += 1
                }
            }
        }
        return (outside, inside)
    }
}

@MainActor
@Suite("Heightfield update path (#139)")
struct HeightfieldUpdateTests {

    private func options(_ view: HeightfieldUpdates.TopDown, displayMode: DisplayMode = .shaded)
        -> OffscreenRenderOptions
    {
        HeightfieldScene.options(
            width: view.width, height: view.height, camera: view.camera, displayMode: displayMode)
    }

    // MARK: Change log

    @Test("The change log reports edits since a version, and falls back to full when trimmed")
    func changeLog() {
        let field = Heightfield(width: 300, height: 300)
        let v0 = field.version
        #expect(field.changes(since: v0).changes.isNone)
        field.replace(
            region: HeightfieldRegion(x: 10, y: 20, width: 5, height: 6),
            heights: [Float](repeating: 1, count: 30))
        field.replace(
            region: HeightfieldRegion(x: 100, y: 120, width: 2, height: 2),
            heights: [Float](repeating: 2, count: 4))
        guard case .regions(let regions) = field.changes(since: v0).changes else {
            Issue.record("expected regions")
            return
        }
        #expect(regions.count == 2)
        #expect(regions[0] == HeightfieldRegion(x: 10, y: 20, width: 5, height: 6))
        // A renderer that never drew gets everything.
        if case .full = field.changes(since: 0).changes {} else { Issue.record("expected full") }
        // After more than the log holds, an old version can no longer be caught up from.
        for i in 0..<(Heightfield.logCapacity * 2 + 10) {
            field.replace(
                region: HeightfieldRegion(x: i % 200, y: 0, width: 1, height: 1), heights: [3])
        }
        if case .full = field.changes(since: v0).changes {} else { Issue.record("expected full") }
        // The newest edits are still logged.
        let recent = field.version - 5
        guard case .regions(let tail) = field.changes(since: recent).changes else {
            Issue.record("expected regions")
            return
        }
        #expect(tail.count == 5)
    }

    @Test("A region reaching past the field is clipped, and the height range grows with edits")
    func clippingAndRange() {
        let field = Heightfield(width: 100, height: 100, initialHeight: 5)
        #expect(field.heightRange == 5...5)
        let before = field.boundsVersion
        field.replace(
            region: HeightfieldRegion(x: 90, y: 95, width: 20, height: 20),
            heights: [Float](repeating: 9, count: 400))
        #expect(field.sample(x: 99, y: 99)?.height == 9)
        #expect(field.sample(x: 89, y: 99)?.height == 5)
        #expect(field.heightRange == 5...9)
        #expect(field.boundsVersion != before)
        field.replace(
            region: HeightfieldRegion(x: 0, y: 0, width: 2, height: 2), heights: [6, 6, 6, 6])
        #expect(field.heightRange == 5...9, "the running range does not shrink")
        field.recomputeHeightRange()
        #expect(field.heightRange == 5...9)
        #expect(field.localBounds.max.z == 9)
    }

    // MARK: Pyramid after partial updates

    @Test("Partial updates leave the pyramid and attributes exactly as a full rebuild would")
    func partialUpdatesKeepPyramidExact() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let width = 413
        let height = 301
        let field = HeightfieldScene.terrainField(width: width, height: height)
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(200, 150, 0), scale: 450, width: 64, height: 64)
        _ = renderer.render(bodies: [HeightfieldScene.body(field)], options: options(view))

        // Across tile edges, at the borders and at the far corner, in several frames.
        let edits: [[HeightfieldRegion]] = [
            [HeightfieldRegion(x: 60, y: 60, width: 10, height: 10)],
            [
                HeightfieldRegion(x: 0, y: 0, width: 3, height: 3),
                HeightfieldRegion(x: 400, y: 290, width: 13, height: 11),
            ],
            [HeightfieldRegion(x: 127, y: 127, width: 2, height: 2)],
            [HeightfieldRegion(x: 130, y: 100, width: 130, height: 120)],
        ]
        for (round, regions) in edits.enumerated() {
            for (i, region) in regions.enumerated() {
                field.replace(
                    region: region,
                    heights: HeightfieldUpdates.patch(region, seed: round * 10 + i, amplitude: 60),
                    attributes: HeightfieldUpdates.attributes(region, seed: round))
            }
            _ = renderer.render(bodies: [HeightfieldScene.body(field)], options: options(view))
        }

        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        let current = HeightfieldUpdates.mirrors(field)
        let reference = HeightfieldPyramidTests.referencePyramid(
            heights: current.heights, width: width, height: height)
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
                    worst = max(
                        worst,
                        abs(readback.values[y * readback.width + x] - reference[level][y * w + x]))
                }
            }
            #expect(worst == 0, "level \(level) differs from a full rebuild by \(worst)")
        }
        let attributes = try #require(state.readAttributes(commandQueue: renderer.testCommandQueue))
        #expect(attributes == current.attributes)
        #expect(state.fullUploads == 1, "only the first draw should upload everything")
    }

    // MARK: Upload cost

    @Test("Upload scales with the dirty tiles, not with the number of edits or the field size")
    func uploadScalesWithDirtyTiles() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(1000, 1000, 0), scale: 2200, width: 128, height: 128)
        let body = HeightfieldScene.body(field)
        _ = renderer.render(bodies: [body], options: options(view))
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        #expect(state.uploadedTiles == 32 * 32, "the first draw uploads every tile")
        // Every tile row is one run, so one block per row; heights and attributes are each padded
        // to 16 bytes (the last tile row holds 16 rows of cells, not 64).
        var expectedFirst = 0
        for ty in 0..<32 {
            let cells = 2000 * min(64, 2000 - ty * 64)
            expectedFirst += (cells * 4 + 15) / 16 * 16 + (cells + 15) / 16 * 16
        }
        #expect(state.uploadedBytes == expectedFirst)

        func upload(_ regions: [HeightfieldRegion]) -> (tiles: Int, bytes: Int) {
            let tiles = state.uploadedTiles
            let bytes = state.uploadedBytes
            for (i, region) in regions.enumerated() {
                field.replace(region: region, heights: HeightfieldUpdates.patch(region, seed: i))
            }
            _ = renderer.render(bodies: [body], options: options(view))
            return (state.uploadedTiles - tiles, state.uploadedBytes - bytes)
        }

        // One 130 x 120 region at (500, 500): columns 500...629 touch tiles 7...9, rows 500...619
        // tiles 7...9.
        let one = upload([HeightfieldRegion(x: 500, y: 500, width: 130, height: 120)])
        #expect(one.tiles == 9)
        // Staging holds each tile's heights and attributes, each block padded to 16 bytes.
        #expect(one.bytes == 9 * (64 * 64 * 4 + 64 * 64))

        // 200 regions that slide by a cell each: the same 9 tiles, plus the neighbours the slide
        // reaches into (up to 40 cells right, 5 rows down).
        let sliding = upload(
            HeightfieldUpdates.overlappingRegions(
                count: 200, size: SIMD2(130, 120), from: SIMD2(500, 500)))
        print("UPLOAD sliding x200: \(sliding.tiles) tiles, \(sliding.bytes) bytes")
        #expect(sliding.tiles <= 16)
        #expect(sliding.bytes < 20 * 1024 * 16)

        // 200 disjoint regions cover most of the field: upload approaches the whole field once,
        // and is still bounded by it however many edits there were.
        let disjoint = upload(
            HeightfieldUpdates.disjointRegions(
                count: 200, size: SIMD2(130, 120), in: field))
        print("UPLOAD disjoint x200: \(disjoint.tiles) tiles, \(disjoint.bytes) bytes")
        #expect(disjoint.tiles <= 32 * 32)
        #expect(disjoint.tiles > 500)
        #expect(disjoint.bytes <= 32 * 32 * 5 * 64 * 64)
        #expect(state.fullUploads == 1)
    }

    // MARK: Acceptance 2, correctness half

    @Test("Replacing 130 x 120 cells changes no pixel outside the region and its one-cell halo")
    func replaceChangesOnlyTheRegion() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let size = 400
        var heights = [Float](repeating: 0, count: size * size)
        for i in heights.indices { heights[i] = 3 * HeightfieldScene.noise(i % size, i / size) }
        let field = Heightfield(width: size, height: size, heights: heights)
        // Top-down orthographic, 3 px per cell: a vertical edit moves no pixel sideways.
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(200, 200, 0), scale: 420, width: 1024, height: 1024)
        let body = HeightfieldScene.body(field)
        let opts = options(view)

        let a = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))
        let region = HeightfieldRegion(x: 120, y: 90, width: 130, height: 120)
        field.replace(
            region: region, heights: HeightfieldUpdates.patch(region, seed: 4, amplitude: 8),
            attributes: HeightfieldUpdates.attributes(region, seed: 4))
        let b = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))

        // The region's cells, one cell wider on every side (central-difference normals and the
        // quads between the edited and untouched vertices reach one cell out), projected.
        let lo = view.pixel(Float(region.x) - 1, Float(region.maxY) + 1)
        let hi = view.pixel(Float(region.maxX) + 1, Float(region.y) - 1)
        let keep = (
            x0: Int(lo.x.rounded(.down)) - 1, y0: Int(lo.y.rounded(.down)) - 1,
            x1: Int(hi.x.rounded(.up)) + 1, y1: Int(hi.y.rounded(.up)) + 1
        )
        let diff = HeightfieldUpdates.differingPixels(
            a.pixels, b.pixels, width: a.width, height: a.height, outside: keep)
        print("REPLACE diff: \(diff.outside) outside, \(diff.inside) inside, keep \(keep)")
        #expect(diff.outside == 0, "\(diff.outside) pixels changed outside the edited region")
        #expect(diff.inside > 10_000, "the edit changed only \(diff.inside) pixels")
    }

    // MARK: Many edits per frame

    @Test(
        "200 edits of 130 x 120 cells in one frame render exactly like a fresh field",
        arguments: ["disjoint", "overlapping"])
    func manyEditsRenderCorrectly(kind: String) throws {
        guard let renderer = OffscreenRenderer(), let fresh = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(1000, 1000, 0), scale: 2200, width: 256, height: 256)
        let body = HeightfieldScene.body(field)
        let opts = options(view)
        let before = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))

        let regions =
            kind == "disjoint"
            ? HeightfieldUpdates.disjointRegions(count: 200, size: SIMD2(130, 120), in: field)
            : HeightfieldUpdates.overlappingRegions(
                count: 200, size: SIMD2(130, 120), from: SIMD2(700, 800))
        for (i, region) in regions.enumerated() {
            field.replace(
                region: region, heights: HeightfieldUpdates.patch(region, seed: i, amplitude: 90),
                attributes: HeightfieldUpdates.attributes(region, seed: i))
        }
        let updated = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))

        // The reference: a new field and a new renderer that see only the final contents.
        let copy = HeightfieldUpdates.copy(of: field)
        let reference = HeightfieldScene.pixels(
            try #require(fresh.render(bodies: [HeightfieldScene.body(copy)], options: opts)))
        #expect(
            updated.pixels == reference.pixels,
            "\(kind): the edited field does not match a fresh one")
        let visible = HeightfieldUpdates.differingPixels(
            before.pixels, updated.pixels, width: 256, height: 256, outside: (0, 0, 0, 0))
        #expect(visible.outside > 100, "the edits should be visible at all (\(visible.outside) px)")
    }

    // MARK: Several renderers on one handle

    @Test("Two renderers on one handle, one of them far behind, both draw the current field")
    func twoRenderersOneHandle() throws {
        guard let first = OffscreenRenderer(), let second = OffscreenRenderer(),
            let fresh = OffscreenRenderer()
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = HeightfieldScene.terrainField(width: 500, height: 500)
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(250, 250, 0), scale: 540, width: 200, height: 200)
        let body = HeightfieldScene.body(field)
        let opts = options(view)

        _ = first.render(bodies: [body], options: opts)
        _ = second.render(bodies: [body], options: opts)
        // The first keeps up with every edit; the second skips a while.
        for i in 0..<5 {
            let region = HeightfieldRegion(x: 30 + i * 60, y: 40 + i * 50, width: 70, height: 60)
            field.replace(region: region, heights: HeightfieldUpdates.patch(region, seed: i))
            _ = first.render(bodies: [body], options: opts)
        }
        let secondState = try #require(second.heightfieldState(forBodyID: "field"))
        let secondFull = secondState.fullUploads
        let a = HeightfieldScene.pixels(try #require(first.render(bodies: [body], options: opts)))
        let b = HeightfieldScene.pixels(try #require(second.render(bodies: [body], options: opts)))
        #expect(
            a.pixels == b.pixels, "a renderer that skipped five edits differs from one that did not"
        )
        #expect(
            secondState.fullUploads == secondFull, "catching up from the log needs no full upload")

        // Past the change log's capacity a renderer re-uploads everything, and is still right.
        for i in 0..<(Heightfield.logCapacity * 2 + 20) {
            field.replace(
                region: HeightfieldRegion(x: i % 400, y: (i / 400) % 400, width: 3, height: 2),
                heights: [Float](repeating: Float(i % 17), count: 6))
        }
        let c = HeightfieldScene.pixels(try #require(second.render(bodies: [body], options: opts)))
        #expect(secondState.fullUploads == secondFull + 1)
        let reference = HeightfieldScene.pixels(
            try #require(
                fresh.render(
                    bodies: [HeightfieldScene.body(HeightfieldUpdates.copy(of: field))],
                    options: opts)))
        #expect(c.pixels == reference.pixels)
    }

    @Test("Changing the ramp recolours without touching the textures")
    func rampChangeUploadsNothing() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let attributes = [UInt8](repeating: 9, count: 100 * 100)
        let field = Heightfield(
            width: 100, height: 100, heights: [Float](repeating: 0, count: 100 * 100),
            attributes: attributes)
        var ramp = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: 256)
        ramp[9] = SIMD4(1, 0, 0, 1)
        field.ramp = ramp
        let view = HeightfieldUpdates.TopDown(
            pivot: SIMD3(50, 50, 0), scale: 110, width: 64, height: 64)
        let body = HeightfieldScene.body(field, color: SIMD4(0, 1, 0, 1))
        let opts = options(view, displayMode: .unlit)
        let red = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        let bytes = state.uploadedBytes
        ramp[9] = SIMD4(0, 0, 1, 1)
        field.ramp = ramp
        let blue = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [body], options: opts)))
        #expect(ParityRender.rgb(red.pixels, width: 64, x: 32, y: 32) == SIMD3(255, 0, 0))
        #expect(ParityRender.rgb(blue.pixels, width: 64, x: 32, y: 32) == SIMD3(0, 0, 255))
        #expect(state.uploadedBytes == bytes, "a ramp change uploaded height or attribute data")
    }
}

extension Heightfield.Changes {
    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}
