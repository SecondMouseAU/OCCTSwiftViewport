// HeightfieldLevelOfDetailTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 1: at a coarse level of detail a step or a pit must not smear or
// vanish. Coarse levels take the MINIMUM height of the cells they cover, so a pit one cell wide
// keeps its full depth and a step's rendered position stays within one mesh cell of the truth.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

/// A 45-degree orthographic view along +Y of a field that varies only in X, so the lowest drawn
/// pixel of each image column is the surface's height profile `z(x)`, seen through the view's
/// vertical axis. That makes a step's rendered position, and whether a one-cell pit survives, a
/// measurement on the image.
@MainActor
struct HeightfieldProfileView {
    let width = 512
    let height = 512
    /// World units over the image's height, and so over its width.
    var scale: Float
    var pivotX: Float
    var pivotZ: Float = 50
    /// Vertical screen axis per unit of z (sin 45 degrees).
    static let zToScreen: Float = 0.70710678

    var camera: CameraState {
        HeightfieldScene.camera(
            pivot: SIMD3(pivotX, 32, pivotZ), distance: 400, tilt: .pi / 4, orthographicScale: scale
        )
    }

    func options() -> OffscreenRenderOptions {
        var options = HeightfieldScene.options(
            width: width, height: height, camera: camera, displayMode: .unlit)
        options.edgeIntensity = 0
        return options
    }

    /// World units per pixel.
    var unitsPerPixel: Float { scale / Float(height) }

    /// The row of the lowest non-background pixel in each column, or `nil` for an empty column.
    func bottomRows(_ image: CGImage) -> [Int?] {
        let (pixels, w, h) = HeightfieldScene.pixels(image)
        return (0..<w).map { x in
            for y in stride(from: h - 1, through: 0, by: -1)
            where !HeightfieldScene.isBackground(ParityRender.rgb(pixels, width: w, x: x, y: y)) {
                return y
            }
            return nil
        }
    }

    /// World X of the centre of image column `x`.
    func worldX(column x: Double) -> Double {
        Double(pivotX) + (x + 0.5 - Double(width) / 2) * Double(unitsPerPixel)
    }

    /// The world X at which the profile `rows` crosses `level` (a row), by linear interpolation
    /// between the two columns that straddle it, scanning left to right.
    func crossing(_ rows: [Int?], level: Double) -> Double? {
        for x in 1..<rows.count {
            guard let a = rows[x - 1], let b = rows[x] else { continue }
            let da = Double(a) - level
            let db = Double(b) - level
            if da * db <= 0, da != db {
                return worldX(column: Double(x - 1) + da / (da - db))
            }
        }
        return nil
    }
}

@MainActor
@Suite("Heightfield level of detail keeps steps and pits (#139)")
struct HeightfieldLevelOfDetailTests {

    private static let stepX = 1000
    private static let stepHeight: Float = 100

    private func stepField() throws -> Heightfield {
        let width = 2000
        let height = 64
        var heights = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in Self.stepX..<width { heights[y * width + x] = Self.stepHeight }
        }
        return try Heightfield(width: width, height: height, heights: heights)
    }

    /// The measured step position minus the true one (the cell boundary at X = 1000), in cells.
    private func stepError(
        renderer: OffscreenRenderer, field: Heightfield, view: HeightfieldProfileView
    ) throws -> Double {
        let image = try #require(
            renderer.render(bodies: [HeightfieldScene.body(field)], options: view.options()))
        let rows = view.bottomRows(image)
        let valid = rows.compactMap { $0 }
        let low = Double(valid.max() ?? 0)  // the left plateau is lower on screen
        let high = Double(valid.min() ?? 0)
        let crossed = try #require(view.crossing(rows, level: (low + high) / 2))
        return crossed - Double(Self.stepX)
    }

    @Test(
        "A step is rendered within a mesh cell and a half of its true position at every level",
        arguments: [0, 1, 2, 3, 4])
    func stepWithinOneMeshCell(level: Int) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        renderer.heightfieldForcedLevel = level
        // Zoomed in on the step so a cell is several pixels and the position can be read to a
        // fraction of one; the coarse mesh is forced.
        let view = HeightfieldProfileView(scale: 160, pivotX: Float(Self.stepX))
        let error = try stepError(renderer: renderer, field: try stepField(), view: view)
        let stride = Double(1 << level)
        print("STEP level \(level) (stride \(Int(stride))): error \(error) cells")
        // The min pyramid only ever lowers the surface, so the low side grows into the high one:
        // the error is positive. Its windows reach `stride - 1` cells either side of a vertex, so
        // the step lands within 1.5 mesh cells (measured: 0, 1.5, 2.5, 4.5, 16.5 cells at strides
        // 1, 2, 4, 8, 16); a window of `stride / 2` would hold it to one mesh cell but lets a
        // one-cell pit between two vertices lose part of its depth.
        #expect(error >= -0.75, "level \(level): the step moved toward the low side by \(-error)")
        #expect(error <= 1.5 * stride, "level \(level): the step moved \(error) cells")
    }

    @Test("At a zoomed-out view the step stays within 1.5 mesh cells and a few pixels")
    func zoomedOutStep() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let view = HeightfieldProfileView(scale: 2400, pivotX: 1000)
        let field = try stepField()
        let error = try stepError(renderer: renderer, field: field, view: view)
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        let histogram = state.lastPlan?.levelHistogram ?? []
        let level = try #require(histogram.firstIndex { $0 > 0 })
        let cellsPerPixel = Double(view.unitsPerPixel)
        print("ZOOMED-OUT STEP: level \(level), error \(error) cells = \(error / cellsPerPixel) px")
        #expect(level >= 2, "expected a coarse level at this zoom, got \(histogram)")
        #expect(error >= -1 - cellsPerPixel)
        #expect(error <= 1.5 * Double(1 << level) + cellsPerPixel)
        // A mesh cell is at most `heightfieldTargetPixels` wide, and the step moves by up to one and
        // a half of them.
        let limit = 1.5 * Double(Heightfield.defaultMeshCellPixels)
        #expect(error / cellsPerPixel <= limit, "the step moved \(error / cellsPerPixel) pixels")
    }

    @Test("A one-cell-wide pit survives a coarse level, at full depth")
    func pitSurvives() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let width = 2000
        let height = 64
        let pitX = 500
        var heights = [Float](repeating: 0, count: width * height)
        for y in 0..<height { heights[y * width + pitX] = -50 }
        let field = try Heightfield(width: width, height: height, heights: heights)
        let view = HeightfieldProfileView(scale: 160, pivotX: Float(pitX), pivotZ: -20)

        var dips: [Int: Double] = [:]
        for level in [0, 3] {
            renderer.heightfieldForcedLevel = level
            let image = try #require(
                renderer.render(bodies: [HeightfieldScene.body(field)], options: view.options()))
            let rows = view.bottomRows(image).compactMap { $0 }
            let base = Double(rows.min() ?? 0)
            // Rows the pit adds below the flat surface's lowest row, as world units of z.
            let deepest = Double(rows.max() ?? 0)
            dips[level] =
                (deepest - base) * Double(view.unitsPerPixel)
                / Double(HeightfieldProfileView.zToScreen)
        }
        print("PIT dips", dips)
        let expected = 50.0
        #expect(
            abs((dips[0] ?? 0) - expected) < 3, "full resolution shows a dip of \(dips[0] ?? 0)")
        // Point sampling at stride 8 would miss a pit at cell 500 entirely (500 is not a multiple
        // of 8); the min pyramid keeps its full depth.
        #expect((dips[3] ?? 0) > 0.9 * expected, "stride 8 shows a dip of \(dips[3] ?? 0)")
    }
}
