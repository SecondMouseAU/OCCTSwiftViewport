// HeightfieldPickRefinementTests.swift
// OCCTSwiftViewport Tests
//
// A heightfield pick through the offscreen renderer, and the CPU refinement that makes a click on
// a coarse level of detail land on the exact cell.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield pick refinement (#139)")
struct HeightfieldPickRefinementTests {

    // MARK: Offscreen pick

    /// 120 x 120 field with a distinct attribute and id per cell, top-down.
    private static func smallField() throws -> Heightfield {
        let n = 120
        var heights = [Float](repeating: 0, count: n * n)
        var attributes = [UInt8](repeating: 0, count: n * n)
        var ids = [UInt32](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                heights[y * n + x] = Float(x + y) * 0.05
                attributes[y * n + x] = UInt8((x / 10 + y / 10) % 5)
                ids[y * n + x] = UInt32(x * 1000 + y)
            }
        }
        return try Heightfield(
            width: n, height: n, heights: heights, attributes: attributes, ids: ids)
    }

    private static let topDown = CameraState(
        distance: 400, pivot: SIMD3(60, 60, 0), orthographicScale: 130, isOrthographic: true)

    private static func options(
        displayMode: DisplayMode = .shaded, camera: CameraState = topDown, size: Int = 256
    ) -> OffscreenRenderOptions {
        var options = HeightfieldScene.options(
            width: size, height: size, camera: camera, displayMode: displayMode)
        options.pickRadius = 0
        return options
    }

    @Test("The offscreen renderer picks a heightfield cell with its height, attribute and id")
    func offscreenPickReturnsCell() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try Self.smallField()
        let bodies = [HeightfieldScene.body(field)]
        let options = Self.options()
        var checked = 0
        for pixel in [SIMD2(128, 128), SIMD2(60, 90), SIMD2(200, 40), SIMD2(30, 220)] {
            // Centre of the pixel in world units: 130 units over 256 px, y down.
            let scale: Float = 130 / 256
            let world = SIMD2<Float>(
                60 + (Float(pixel.x) + 0.5 - 128) * scale, 60 - (Float(pixel.y) + 0.5 - 128) * scale)
            let cell = SIMD2(Int(world.x.rounded(.down)), Int(world.y.rounded(.down)))
            let result = try #require(
                renderer.performPick(bodies: bodies, at: pixel, options: options),
                "no hit at \(pixel)")
            let hit = try #require(result.heightfield)
            #expect(result.bodyID == "field")
            #expect(result.kind == .face)
            #expect(hit.cell == cell, "pixel \(pixel): \(hit.cell), expected \(cell)")
            #expect(result.triangleIndex == cell.y * 120 + cell.x)
            let truth = try #require(field.sample(x: cell.x, y: cell.y))
            #expect(hit.height == truth.height)
            #expect(hit.attribute == truth.attribute)
            #expect(hit.id == UInt32(cell.x * 1000 + cell.y))
            checked += 1
        }
        #expect(checked == 4)
        // A pixel off the field misses.
        #expect(renderer.performPick(bodies: bodies, at: SIMD2(2, 2), options: options) == nil)
    }

    @Test("An offscreen region pick returns each distinct cell, and a mesh in front still wins")
    func offscreenRegionPickAndOcclusion() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try Self.smallField()
        var box = ViewportBody.box(
            id: "box", width: 20, height: 20, depth: 20, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(60, 60, 40, 1)
        let bodies = [HeightfieldScene.body(field), box]
        let options = Self.options()
        let region = renderer.performRegionPick(
            bodies: bodies, rect: CGRect(x: 20, y: 150, width: 40, height: 40), options: options)
        let cells = Set(region.compactMap { $0.heightfield?.cell })
        #expect(cells.count > 300, "\(cells.count) distinct cells")
        #expect(region.allSatisfy { $0.bodyID == "field" })

        let over = try #require(
            renderer.performPick(bodies: bodies, at: SIMD2(128, 128), options: options))
        #expect(over.bodyID == "box")
        #expect(over.heightfield == nil)
    }

    @Test("A heightfield is not picked where the display mode draws no surface")
    func wireframeIsNotPicked() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let bodies = [HeightfieldScene.body(try Self.smallField())]
        let shaded = renderer.performPick(
            bodies: bodies, at: SIMD2(128, 128), options: Self.options())
        let wireframe = renderer.performPick(
            bodies: bodies, at: SIMD2(128, 128), options: Self.options(displayMode: .wireframe))
        #expect(shaded?.heightfield != nil)
        #expect(wireframe == nil)
    }

    @Test("Offscreen and live picks of the same scene agree")
    func offscreenMatchesLive() async throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try Self.smallField()
        let bodies = [HeightfieldScene.body(field)]
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: Self.topDown, width: 256, height: 256)
        for pixel in [SIMD2(128, 128), SIMD2(70, 190), SIMD2(210, 60)] {
            let live = try #require(await rig.pick(pixel))
            let offscreen = try #require(
                renderer.performPick(bodies: bodies, at: pixel, options: Self.options()))
            #expect(live.heightfield == offscreen.heightfield)
            #expect(live.triangleIndex == offscreen.triangleIndex)
            #expect(live.bodyIndex == offscreen.bodyIndex)
        }
    }

    // MARK: Refinement

    /// Plateaus 30 units apart in blocks of 50 cells: beside a step the drawn, min-lowered surface
    /// is far below the true one.
    private static func steppedField() throws -> Heightfield {
        let n = 1000
        let heights = (0..<(n * n)).map { i in
            Float((((i % n) / 50) + ((i / n) / 50)) % 3) * 30
        }
        return try Heightfield(width: n, height: n, heights: heights)
    }

    @Test("Refining a coarse-level pick lands on the exact cell, which the raw pick often misses")
    func refinementIsExact() async throws {
        let field = try Self.steppedField()
        let camera = CameraState(
            rotation: simd_quatf(angle: 1.0, axis: SIMD3(1, 0, 0)), distance: 900,
            pivot: SIMD3(500, 500, 0))
        let bodies = [HeightfieldScene.body(field)]
        let size = 512
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: camera, width: size, height: size, forcedLevel: 3)
        var rawOff = 0
        var refinedOff = 0
        var checked = 0
        for py in stride(from: 90, to: 440, by: 29) {
            for px in stride(from: 60, to: 460, by: 31) {
                let ndc = SIMD2(
                    (Float(px) + 0.5) / Float(size) * 2 - 1, 1 - (Float(py) + 0.5) / Float(size) * 2
                )
                let ray = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: 1)
                guard let truth = field.raycast(origin: ray.origin, direction: ray.direction)?.cell,
                    let raw = await rig.pick(SIMD2(px, py))
                else { continue }
                let refined = try #require(
                    rig.controller.refinePick(raw, ndc: ndc, bodies: bodies))
                if raw.heightfield?.cell != truth { rawOff += 1 }
                if refined.heightfield?.cell != truth { refinedOff += 1 }
                // The refined result is a consistent pick of the true cell.
                #expect(refined.triangleIndex == truth.y * 1000 + truth.x)
                #expect(refined.heightfield?.cellIndex == refined.triangleIndex)
                #expect(refined.bodyID == raw.bodyID)
                #expect(refined.kind == .face)
                #expect(
                    PickResult(
                        pickValue: refined.pickValue, indexMap: [raw.bodyIndex: raw.bodyID])?
                        .triangleIndex == refined.triangleIndex)
                checked += 1
            }
        }
        #expect(checked > 60, "only \(checked) rays were checked")
        #expect(rawOff > 5, "the raw GPU pick was off for only \(rawOff) of \(checked) rays")
        #expect(refinedOff == 0, "refinement left \(refinedOff) of \(checked) picks off")
    }

    @Test("A tap on a heightfield reaches the pick stream refined")
    func tapPickIsRefined() async throws {
        let field = try Self.steppedField()
        let camera = CameraState(
            rotation: simd_quatf(angle: 1.0, axis: SIMD3(1, 0, 0)), distance: 900,
            pivot: SIMD3(500, 500, 0))
        let bodies = [HeightfieldScene.body(field)]
        let size = 512
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: camera, width: size, height: size, forcedLevel: 3)
        let controller = rig.controller
        var delivered: PickResult?
        controller.onPick = { delivered = $0 }
        let px = 300
        let py = 330
        let ndc = SIMD2(
            (Float(px) + 0.5) / Float(size) * 2 - 1, 1 - (Float(py) + 0.5) / Float(size) * 2)
        let raw = try #require(await rig.pick(SIMD2(px, py)))
        controller.handleTapPick(result: raw, ndc: ndc, bodies: bodies, aspectRatio: 1)
        let ray = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: 1)
        let truth = try #require(field.raycast(origin: ray.origin, direction: ray.direction)).cell
        #expect(delivered?.heightfield?.cell == truth)
        #expect(controller.pickResult?.heightfield?.cell == truth)
    }

    @Test("Refinement leaves other results, misses and mesh picks alone")
    func refinementPassesThrough() async throws {
        let field = try Self.smallField()
        var box = ViewportBody.box(
            id: "box", width: 20, height: 20, depth: 20, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(60, 60, 40, 1)
        let bodies = [HeightfieldScene.body(field), box]
        let rig = try HeightfieldPickRig(
            bodies: bodies, camera: Self.topDown, width: 256, height: 256)
        #expect(rig.controller.refinePick(nil, ndc: .zero, bodies: bodies) == nil)

        // A pick of the box has no heightfield payload and comes back untouched.
        let meshPick = try #require(await rig.pick(SIMD2(128, 128)))
        #expect(meshPick.bodyID == "box")
        #expect(rig.controller.refinePick(meshPick, ndc: .zero, bodies: bodies) == meshPick)

        // A heightfield pick whose ray no longer meets the field keeps its drawn cell.
        let fieldPick = try #require(await rig.pick(SIMD2(40, 200)))
        #expect(fieldPick.heightfield != nil)
        let missing = SIMD2<Float>(-5, -5)
        #expect(rig.controller.refinePick(fieldPick, ndc: missing, bodies: bodies) == fieldPick)
    }
}
