// HeightfieldLatticeBorderTests.swift
// OCCTSwiftViewport Tests
//
// A `.wireframe` lattice line on a tile border is as wide as any other (#262). From a pitch of 64
// cells a tile's lines fall on its borders, where each of the two tiles draws its half of the line.
// A neighbour with a coarser pitch that does not reach the border used to leave the finer tile's half
// alone, half as wide. These render fields whose tiles differ in pitch (a perspective camera), find
// the borders where only one side's pitch reaches the line, and measure the line there.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield lattice borders (#262)")
struct HeightfieldLatticeBorderTests {

    // MARK: Which borders a tile draws for its neighbours

    @Test(
        "A tile draws a neighbour's border line only when the neighbour's pitch reaches it and its own does not"
    )
    func latticeBorderRules() {
        let cols = 3
        let rows = 3
        // The edges a tile draws for its neighbour, as bits 0-3: -X, +X, -Y, +Y.
        func borders(_ tx: Int, _ ty: Int, _ pitches: [UInt8]) -> UInt32 {
            HeightfieldLayout.latticeBorders(
                tx: tx, ty: ty, cols: cols, rows: rows, pitches: pitches)
        }
        let none: UInt32 = 0
        let minusX: UInt32 = 1
        let plusX: UInt32 = 2
        let minusY: UInt32 = 4
        let plusY: UInt32 = 8

        // Nothing unless the tile's own pitch is coarser than 64 cells, whatever its neighbours.
        let fine: [UInt8] = [6, 6, 6, 6, 5, 6, 6, 6, 6]
        for ty in 0..<rows {
            for tx in 0..<cols { #expect(borders(tx, ty, fine) == none, "tile \(tx), \(ty)") }
        }
        // An equal pitch reaches the same borders: none.
        let equal = [UInt8](repeating: 8, count: 9)
        for ty in 0..<rows { for tx in 0..<cols { #expect(borders(tx, ty, equal) == none) } }

        // The middle tile has pitch 7 (128 cells); the borders are at 64 and 128 on both axes.
        // Its neighbours at -X and -Y (border 64) have pitch 6, which reaches 64 and 128; at +X
        // pitch 7 and +Y pitch 5. Pitch 7 reaches 128 itself, not 64.
        var pitches = [UInt8](repeating: 7, count: 9)
        pitches[1 * cols + 0] = 6  // -X
        pitches[0 * cols + 1] = 6  // -Y
        pitches[1 * cols + 2] = 7  // +X
        pitches[2 * cols + 1] = 5  // +Y
        // -X and -Y: border 64, the neighbour draws it and the tile does not. +X and +Y: border
        // 128, which the tile draws itself.
        #expect(borders(1, 1, pitches) == minusX | minusY)

        // The first tile has no neighbour at -X and -Y, and its +X and +Y borders are at 64. Its
        // pitch, 512 cells, reaches neither. The +X neighbour's pitch of 64 draws the border; the
        // +Y neighbour's 128 does not.
        var corner = [UInt8](repeating: 9, count: 9)
        corner[0 * cols + 1] = 6  // +X
        corner[1 * cols + 0] = 7  // +Y
        #expect(borders(0, 0, corner) == plusX)

        // Pitches more than a level apart: a tile at 256 cells and its +X neighbour at 32, which
        // reaches the border at 64 as every pitch up to 64 does. The finer tile draws no border.
        let wide: [UInt8] = [8, 5, 8, 8, 8, 8, 8, 8, 8]
        #expect(borders(0, 0, wide) == plusX)
        #expect(borders(1, 0, wide) == none)

        // The border at 128 between tiles 1 and 2: pitch 7 (128 cells) reaches it, pitch 8 (256)
        // does not. The coarser tile draws it, the finer has nothing to add. The border at 64
        // between tiles 0 and 1 is reached by neither.
        let pair: [UInt8] = [8, 8, 7, 8, 8, 8, 8, 8, 8]
        #expect(borders(1, 0, pair) == plusX)
        #expect(borders(2, 0, pair) == none)
        #expect(borders(0, 0, pair) == none)

        // Across Y: tile (0, 1) at 512 cells, the tile below it (0, 0) at 128, which does not
        // reach the border at 64 either, and the tile above it (0, 2) at 64, which does.
        var column = [UInt8](repeating: 9, count: 9)
        column[0 * cols + 0] = 7
        column[2 * cols + 0] = 6
        #expect(borders(0, 1, column) == plusY)
    }

    // MARK: Rig

    /// A field one tile wide and 64 tiles long, seen along its length.
    ///
    /// The perspective camera is at one end, on a `Side`, 1.1 radians off straight down, so the
    /// tiles along the field have different pitches. The lattice target is 64 px, so a tile is
    /// tens of pixels across and the borders are far enough apart to measure.
    enum Side: CaseIterable {
        case minusY, plusY, minusX, plusX

        var longIsY: Bool { self == .minusY || self == .plusY }

        func field() throws -> Heightfield {
            longIsY
                ? try Heightfield(width: 64, height: 4096, initialHeight: 0)
                : try Heightfield(width: 4096, height: 64, initialHeight: 0)
        }

        /// Pivots along the field that put a border between a finer and a coarser tile, the
        /// finer one nearer the camera, with the border at an odd multiple of 64.
        var pivots: [Float] {
            switch self {
            case .minusY, .minusX: [512, 1024]
            case .plusY, .plusX: [3584, 3072]
            }
        }

        func camera(pivot: Float) -> CameraState {
            let rotation =
                switch self {
                case .minusY: simd_quatf(angle: 1.1, axis: SIMD3(1, 0, 0))
                case .plusY: simd_quatf(angle: -1.1, axis: SIMD3(1, 0, 0))
                case .minusX: simd_quatf(angle: -1.1, axis: SIMD3(0, 1, 0))
                case .plusX: simd_quatf(angle: 1.1, axis: SIMD3(0, 1, 0))
                }
            return CameraState(
                rotation: rotation, distance: 700,
                pivot: longIsY ? SIMD3(32, pivot, 0) : SIMD3(pivot, 32, 0))
        }

        /// The point on the field's middle line at grid position `border` along its length.
        func point(border: Float) -> SIMD3<Float> {
            longIsY ? SIMD3(32.5, border + 0.5, 0) : SIMD3(border + 0.5, 32.5, 0)
        }
    }

    static let size = 512
    static let latticePixels: Float = 64

    static func body(_ side: Side) throws -> ViewportBody {
        LatticeScene.body(try side.field(), id: "strip-\(side)")
    }

    static func options(
        camera: CameraState, width: Float, mode: DisplayMode = .wireframe
    ) -> OffscreenRenderOptions {
        var options = HeightfieldScene.options(
            width: size, height: size, camera: camera, displayMode: mode)
        options.msaaSampleCount = 1
        options.edgeLineConfiguration = EdgeLineConfiguration(width: width)
        options.heightfieldLatticePixels = latticePixels
        options.pickRadius = 0
        return options
    }

    /// Each tile of the plan the renderer last drew, by tile column and row.
    static func tiles(_ renderer: OffscreenRenderer, bodyID: String) throws -> [SIMD2<Int>:
        HeightfieldTileInstance]
    {
        let plan = try #require(renderer.heightfieldState(forBodyID: bodyID)?.lastPlan)
        var tiles: [SIMD2<Int>: HeightfieldTileInstance] = [:]
        guard let buffer = plan.instanceBuffer else { return tiles }
        for level in 0..<HeightfieldLayout.levelCount where plan.ranges[level].count > 0 {
            let instances = buffer.contents().advanced(
                by: plan.ranges[level].first * MemoryLayout<HeightfieldTileInstance>.stride
            ).bindMemory(to: HeightfieldTileInstance.self, capacity: plan.ranges[level].count)
            for i in 0..<plan.ranges[level].count {
                let tile = instances[i]
                tiles[SIMD2(Int(tile.origin.x) / 64, Int(tile.origin.y) / 64)] = tile
            }
        }
        return tiles
    }

    /// A border between two tiles along a field's length, and what draws a line there.
    struct Border {
        /// Grid position along the field's length: a multiple of 64.
        var position: Int
        /// The pitch of the tile before it and the one after it, as a power of two of cells.
        var before: Int
        var after: Int

        var drawnByBefore: Bool { position % (1 << before) == 0 }
        var drawnByAfter: Bool { position % (1 << after) == 0 }
        /// Only one of the two tiles' own pitches reaches the line.
        var oneSided: Bool { drawnByBefore != drawnByAfter }
        var bothSides: Bool { drawnByBefore && drawnByAfter }
    }

    static func borders(_ tiles: [SIMD2<Int>: HeightfieldTileInstance], side: Side) -> [Border] {
        func pitch(_ k: Int) -> Int? {
            tiles[side.longIsY ? SIMD2(0, k) : SIMD2(k, 0)].map { Int($0.lattice) }
        }
        return (1..<63).compactMap { k in
            guard let before = pitch(k - 1), let after = pitch(k) else { return nil }
            return Border(position: k * 64, before: before, after: after)
        }
    }

    /// The pixel of a point under a perspective `camera`, in a view `size` pixels square.
    static func pixel(_ point: SIMD3<Float>, camera: CameraState) -> SIMD2<Float> {
        let clip = camera.projectionMatrix(aspectRatio: 1) * camera.viewMatrix * SIMD4(point, 1)
        return SIMD2(
            (clip.x / clip.w * 0.5 + 0.5) * Float(size), (0.5 - clip.y / clip.w * 0.5) * Float(size)
        )
    }

    /// Where a border's line is on screen, if it can be measured: in the view, and at least 14
    /// pixels from the lines either side.
    static func measurable(_ border: Border, side: Side, camera: CameraState) -> SIMD2<Float>? {
        let p = pixel(side.point(border: Float(border.position)), camera: camera)
        let before = pixel(side.point(border: Float(border.position - 64)), camera: camera)
        let after = pixel(side.point(border: Float(border.position + 64)), camera: camera)
        let spacing = min(simd_distance(p, before), simd_distance(p, after))
        guard spacing >= 14, p.x >= 8, p.x < Float(size) - 8, p.y >= 8, p.y < Float(size) - 8
        else { return nil }
        return p
    }

    /// The line's width in pixels: the coverage summed across it at `p`.
    ///
    /// The field's body colour is green on a magenta background, so the green channel is the
    /// coverage. A camera that turns about Y rolls the picture a quarter turn, so a border across
    /// X runs down the screen and is crossed along a row, one across Y runs along it and is
    /// crossed down a column.
    static func ink(_ pixels: [UInt8], at p: SIMD2<Float>, side: Side) -> Float {
        let green = LatticeScene.green.y * 255
        var sum: Float = 0
        for offset in -6...6 {
            let x = Int(p.x) + (side.longIsY ? 0 : offset)
            let y = Int(p.y) + (side.longIsY ? offset : 0)
            sum += Float(HeightfieldIntegrationTests.rgb(pixels, x, y, width: size).y) / green
        }
        return sum
    }

    typealias Render = (Side, Float, Float) throws -> [UInt8]

    static func offscreenRender(_ renderer: OffscreenRenderer) -> Render {
        { side, pivot, width in
            let camera = side.camera(pivot: pivot)
            return HeightfieldScene.pixels(
                try #require(
                    renderer.render(
                        bodies: [try body(side)], options: options(camera: camera, width: width)))
            ).pixels
        }
    }

    static func liveRender() -> Render {
        { side, pivot, width in
            var setup = LatticeSetup()
            setup.camera = side.camera(pivot: pivot)
            setup.edge = EdgeLineConfiguration(width: width)
            setup.latticePixels = latticePixels
            let rig = try LatticeScene.liveRig([try body(side)], setup)
            return try #require(
                rig.renderer.renderHeadlessBGRA(
                    width: size, height: size, backgroundColor: HeightfieldScene.background))
        }
    }

    // MARK: Width

    @Test(
        "A lattice line on a tile border is as wide as one that both tiles draw, whichever side is finer"
    )
    func borderLineIsFullWidth() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            var oneSided = 0
            var bothSides = 0
            for pivot in side.pivots {
                let camera = side.camera(pivot: pivot)
                for width: Float in [4, 1] {
                    let pixels = try Self.offscreenRender(renderer)(side, pivot, width)
                    let tiles = try Self.tiles(renderer, bodyID: "strip-\(side)")
                    for border in Self.borders(tiles, side: side) {
                        guard border.oneSided || border.bothSides,
                            let p = Self.measurable(border, side: side, camera: camera)
                        else { continue }
                        let ink = Self.ink(pixels, at: p, side: side)
                        // Whichever pitch reaches the line, it is `width` wide: the coverage across
                        // it sums to the width, to a few percent, as a pixel grid allows.
                        #expect(
                            abs(ink - width) < 0.1 * width,
                            "\(side) pivot \(pivot) width \(width): border \(border.position) pitches \(border.before)|\(border.after) is \(ink) px"
                        )
                        if width == 4 {
                            if border.oneSided { oneSided += 1 } else { bothSides += 1 }
                        }
                    }
                }
            }
            // The scene has to contain what it tests: borders only one tile's pitch reaches, and
            // borders both reach, to compare with.
            #expect(oneSided >= 1, "\(side): no border drawn by one tile's pitch alone")
            #expect(bothSides >= 1, "\(side): no border drawn by both tiles' pitches")
        }
    }

    @Test("The live renderer draws the border line as wide too")
    func liveBorderLineIsFullWidth() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            let pivot = side.pivots[0]
            let camera = side.camera(pivot: pivot)
            // The plan is the same for both renderers: find the borders with the offscreen one.
            _ = try Self.offscreenRender(renderer)(side, pivot, 4)
            let tiles = try Self.tiles(renderer, bodyID: "strip-\(side)")
            let pixels = try Self.liveRender()(side, pivot, 4)
            var measured = 0
            for border in Self.borders(tiles, side: side) where border.oneSided {
                guard let p = Self.measurable(border, side: side, camera: camera) else { continue }
                let ink = Self.ink(pixels, at: p, side: side)
                #expect(abs(ink - 4) < 0.4, "\(side): border \(border.position) is \(ink) px")
                measured += 1
            }
            #expect(measured >= 1, "\(side): no border measured")
        }
    }

    // MARK: Picking

    @Test(
        "A border line is picked on both sides of it, as a line inside a tile is, and the gaps are not"
    )
    func borderLineIsPickedFromBothTiles() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            let pivot = side.pivots[0]
            let camera = side.camera(pivot: pivot)
            let options = Self.options(camera: camera, width: 4)
            let bodies = [try Self.body(side)]
            _ = try #require(renderer.render(bodies: bodies, options: options))
            let borders = Self.borders(
                try Self.tiles(renderer, bodyID: "strip-\(side)"), side: side)
            let map = try #require(renderer.renderPickMap(bodies: bodies, options: options))
            var checked = 0
            for border in borders where border.oneSided || border.bothSides {
                guard let p = Self.measurable(border, side: side, camera: camera) else { continue }
                // The pixel along the field's length: a row for a field along Y, a column for X.
                // The line is 4 px wide, so a pixel whose centre is within 1.5 px of its middle is
                // on it, and there are some either side of the border: one in each of the tiles.
                let along = side.longIsY ? p.y : p.x
                func pixel(_ a: Int) -> SIMD2<Int> {
                    side.longIsY ? SIMD2(Int(p.x), a) : SIMD2(a, Int(p.y))
                }
                let onLine = (Int(along) - 3...Int(along) + 3).filter {
                    abs(Float($0) + 0.5 - along) <= 1.5
                }
                #expect(Set(onLine.map { Float($0) + 0.5 < along }) == [true, false])
                // A cell is under at most a few cells of the border.
                let next = Self.pixel(
                    side.point(border: Float(border.position + 64)), camera: camera)
                let tolerance = Int(3 * 64 / simd_distance(p, next)) + 2
                for a in onLine {
                    let hit = try #require(
                        map.pick(at: pixel(a)),
                        "\(side): border \(border.position) pitches \(border.before)|\(border.after) not picked at \(pixel(a))"
                    )
                    #expect(hit.kind == .face)
                    #expect(hit.bodyID == "strip-\(side)")
                    let cell = try #require(hit.heightfield)
                    #expect(hit.triangleIndex == cell.cellIndex)
                    #expect(
                        abs((side.longIsY ? cell.cell.y : cell.cell.x) - border.position)
                            <= tolerance,
                        "\(side): cell \(cell.cell) for border \(border.position)")
                }
                // Between this line and the next the surface is not picked.
                for a in [Int(along) - 6, Int(along) + 6] {
                    #expect(map.pick(at: pixel(a)) == nil, "\(side): \(pixel(a)) picked off a line")
                }
                checked += 1
            }
            #expect(checked >= 2, "\(side): only \(checked) borders checked")
        }
    }

    // MARK: Where nothing changes

    @Test("Tiles whose neighbours share their pitch draw no border for them, at any zoom")
    func sharedPitchDrawsNoBorder() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // Orthographic: every tile has the one pitch, finer than a tile for small scales and past
        // it, from 64 cells, for large ones.
        let body = LatticeScene.body(
            try Heightfield(width: 2048, height: 2048, initialHeight: 0), id: "flat")
        var pitches = Set<UInt32>()
        for scale: Float in [75, 600, 4000, 16000] {
            let camera = CameraState(
                distance: 5000, pivot: SIMD3(1024, 1024, 0), orthographicScale: scale,
                isOrthographic: true)
            var options = HeightfieldScene.options(
                width: 160, height: 160, camera: camera, displayMode: .wireframe)
            options.msaaSampleCount = 1
            _ = try #require(renderer.render(bodies: [body], options: options))
            let tiles = try Self.tiles(renderer, bodyID: "flat")
            #expect(!tiles.isEmpty)
            for tile in tiles.values {
                #expect(tile.levels >> 24 == 0, "scale \(scale): levels \(tile.levels)")
                pitches.insert(tile.lattice)
            }
        }
        #expect(pitches.contains { $0 >= 7 }, "no zoom reached a pitch of 128 cells: \(pitches)")
        #expect(pitches.contains { $0 < 6 })
    }

    @Test("The plan has a tile draw a border exactly where a neighbour's line is not its own")
    func planCarriesTheBorders() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        for side in Side.allCases {
            _ = try Self.offscreenRender(renderer)(side, side.pivots[0], 1)
            let tiles = try Self.tiles(renderer, bodyID: "strip-\(side)")
            var set = 0
            for (position, tile) in tiles {
                let own = Int(tile.lattice)
                for (slot, step) in [SIMD2(-1, 0), SIMD2(1, 0), SIMD2(0, -1), SIMD2(0, 1)]
                    .enumerated()
                {
                    let bit = (tile.levels >> UInt32(24 + slot)) & 1
                    // A neighbour that is not in the plan was culled, and the plan does not say.
                    guard let neighbour = tiles[position &+ step].map({ Int($0.lattice) }) else {
                        continue
                    }
                    let border =
                        (step.x != 0
                            ? max(position.x, position.x + step.x)
                            : max(position.y, position.y + step.y)) * 64
                    let expected: UInt32 =
                        border % (1 << neighbour) == 0 && border % (1 << own) != 0 ? 1 : 0
                    #expect(bit == expected, "\(side): tile \(position) edge \(step)")
                    set += Int(bit)
                }
            }
            #expect(set >= 1, "\(side): no tile draws a border for a neighbour")
        }
    }
}
