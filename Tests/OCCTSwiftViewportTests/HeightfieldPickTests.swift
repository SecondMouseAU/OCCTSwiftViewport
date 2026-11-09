// HeightfieldPickTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 3: picking a heightfield. The GPU pick pass stamps the CELL index of the
// surface under each pixel (kind face, `triangleIndex` = `y * width + x`); the pick decoder reads the
// cell's height, attribute and optional id from the field's CPU mirror into
// `PickResult.heightfield`. Every test drives `ViewportRenderer`'s real frame encoder through its
// headless entry point and reads the pick texture back with `performPick`.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
struct HeightfieldPickRig {
    struct Unavailable: Error {}

    let controller: ViewportController
    let renderer: ViewportRenderer
    let width: Int
    let height: Int

    init(
        bodies: [ViewportBody], camera: CameraState, width: Int = 512, height: Int = 512,
        forcedLevel: Int? = nil, pickRadius: Int = 0, sampleCount: Int = 4
    ) throws {
        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.backgroundColor = HeightfieldScene.background
        config.showViewCube = false
        config.msaaSampleCount = sampleCount
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        config.lightingConfiguration = lighting
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: pickRadius)
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shaded
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping")
            throw Unavailable()
        }
        renderer.heightfieldCache.forcedLevel = forcedLevel
        guard
            renderer.renderHeadlessBGRA(
                width: width, height: height, backgroundColor: HeightfieldScene.background) != nil
        else {
            Issue.record("headless render returned nil")
            throw Unavailable()
        }
        self.controller = controller
        self.renderer = renderer
        self.width = width
        self.height = height
    }

    func pick(_ pixel: SIMD2<Int>) async -> PickResult? {
        await withCheckedContinuation { continuation in
            renderer.performPick(at: pixel) { continuation.resume(returning: $0) }
        }
    }

    func region(_ rect: CGRect) async -> [PickResult] {
        await withCheckedContinuation { continuation in
            renderer.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
    }
}

@MainActor
@Suite("Heightfield picking (#139)")
struct HeightfieldPickTests {

    /// 300 x 200 field with distinct height, attribute and id in every cell.
    private static func field() -> Heightfield {
        let width = 300
        let height = 200
        var heights = [Float](repeating: 0, count: width * height)
        var attributes = [UInt8](repeating: 0, count: width * height)
        var ids = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                heights[i] = 0.5 * HeightfieldScene.noise(x, y) + Float(x) * 0.01
                attributes[i] = UInt8((x / 20 + y / 20) % 7)
                ids[i] = UInt32(x * 1000 + y)
            }
        }
        return Heightfield(
            width: width, height: height, heights: heights, attributes: attributes, ids: ids)
    }

    /// Top-down orthographic camera over the field: 512 px for 260 world units.
    private static let topDown = CameraState(
        distance: 400, pivot: SIMD3(150, 100, 0), orthographicScale: 260, isOrthographic: true)

    /// World XY of the centre of `pixel` for `topDown` at 512 x 512.
    private static func world(_ pixel: SIMD2<Int>) -> SIMD2<Float> {
        let scale: Float = 260 / 512
        return SIMD2(
            150 + (Float(pixel.x) + 0.5 - 256) * scale, 100 - (Float(pixel.y) + 0.5 - 256) * scale)
    }

    @Test("A pick returns the cell, its height, its attribute and its id")
    func pickReturnsCellHeightAttributeAndID() async throws {
        let field = Self.field()
        let rig = try HeightfieldPickRig(
            bodies: [HeightfieldScene.body(field)], camera: Self.topDown)
        var checked = 0
        for py in stride(from: 40, to: 480, by: 37) {
            for px in stride(from: 40, to: 480, by: 41) {
                let pixel = SIMD2(px, py)
                let w = Self.world(pixel)
                // Stay off cell boundaries, where the GPU's rounding could go either way.
                let fx = w.x - w.x.rounded(.down)
                let fy = w.y - w.y.rounded(.down)
                guard fx > 0.15, fx < 0.85, fy > 0.15, fy < 0.85 else { continue }
                let cell = SIMD2(Int(w.x.rounded(.down)), Int(w.y.rounded(.down)))
                guard cell.x >= 0, cell.y >= 0, cell.x < 300, cell.y < 200 else { continue }
                let result = try #require(await rig.pick(pixel), "no hit at \(pixel)")
                let hit = try #require(result.heightfield, "no heightfield payload at \(pixel)")
                #expect(result.bodyID == "field")
                #expect(result.kind == .face)
                #expect(hit.cell == cell, "pixel \(pixel): cell \(hit.cell), expected \(cell)")
                #expect(result.triangleIndex == cell.y * 300 + cell.x)
                #expect(hit.cellIndex == result.triangleIndex)
                let truth = try #require(field.sample(x: cell.x, y: cell.y))
                #expect(hit.height == truth.height)
                #expect(hit.attribute == truth.attribute)
                #expect(hit.id == UInt32(cell.x * 1000 + cell.y))
                checked += 1
            }
        }
        #expect(checked > 40, "only \(checked) pixels were checked")
    }

    @Test("A pick off the surface misses, and a mesh body beside it is unaffected")
    func missesAndOtherBodies() async throws {
        let field = Self.field()
        var box = ViewportBody.box(
            id: "box", width: 20, height: 20, depth: 20, color: SIMD4(0.8, 0.2, 0.2, 1))
        box.transform.columns.3 = SIMD4(150, 100, 40, 1)
        let rig = try HeightfieldPickRig(
            bodies: [HeightfieldScene.body(field), box], camera: Self.topDown)
        // The corner of the frame, outside the 300 x 200 field.
        #expect(await rig.pick(SIMD2(2, 2)) == nil)
        // The box sits above the field in the middle: it wins, and carries no heightfield payload.
        let over = try #require(await rig.pick(SIMD2(256, 256)))
        #expect(over.bodyID == "box")
        #expect(over.heightfield == nil)
        // Away from the box the field is hit, with its draw-order index (the field is body 0).
        let beside = try #require(await rig.pick(SIMD2(100, 400)))
        #expect(beside.bodyID == "field")
        #expect(beside.bodyIndex == 0)
        #expect(beside.heightfield != nil)
    }

    @Test("A field without ids reports none, and a region pick returns every distinct cell")
    func regionPickAndNoIDs() async throws {
        let width = 120
        let heights = [Float](repeating: 0, count: width * width)
        let field = Heightfield(width: width, height: width, heights: heights)
        let camera = CameraState(
            distance: 400, pivot: SIMD3(60, 60, 0), orthographicScale: 130, isOrthographic: true)
        let rig = try HeightfieldPickRig(
            bodies: [HeightfieldScene.body(field)], camera: camera, width: 256, height: 256)
        let single = try #require(await rig.pick(SIMD2(128, 128)))
        #expect(single.heightfield?.id == nil)
        #expect(single.heightfield?.attribute == 0)
        let results = await rig.region(CGRect(x: 100, y: 100, width: 40, height: 40))
        let cells = Set(results.compactMap { $0.heightfield?.cell })
        // 40 px at 130 / 256 world units per pixel is about 20 cells across.
        #expect(cells.count > 300 && cells.count < 500, "\(cells.count) distinct cells")
        #expect(results.allSatisfy { $0.bodyID == "field" })
    }

    @Test("An edit shows in the next pick without rebuilding the body")
    func editShowsInNextPick() async throws {
        let field = Self.field()
        let rig = try HeightfieldPickRig(
            bodies: [HeightfieldScene.body(field)], camera: Self.topDown)
        let pixel = SIMD2(256, 256)
        let w = Self.world(pixel)
        let cell = SIMD2(Int(w.x.rounded(.down)), Int(w.y.rounded(.down)))
        let before = try #require(await rig.pick(pixel)?.heightfield)
        field.replace(
            region: HeightfieldRegion(x: cell.x, y: cell.y, width: 1, height: 1), heights: [77],
            attributes: [200], ids: [4242])
        // No new frame yet: the pick decodes against the CPU mirror as it is now.
        let after = try #require(await rig.pick(pixel)?.heightfield)
        #expect(before.height != 77)
        #expect(after.height == 77)
        #expect(after.attribute == 200)
        #expect(after.id == 4242)
    }

    // MARK: Accuracy at coarse levels of detail

    /// The cell a view ray hits on the full-resolution surface: the exact CPU grid march.
    private static func trueCell(_ ray: Ray, field: Heightfield) -> SIMD2<Int>? {
        field.raycast(origin: ray.origin, direction: ray.direction)?.cell
    }

    /// The pick-error terrains: smooth hills, the same with cell-scale roughness, and plateaus
    /// with steps (blocks of 50 cells, 30 units apart).
    private static func terrain(_ name: String, _ x: Int, _ y: Int) -> Float {
        let hills =
            40 * sin(Float(x) * 0.004) * cos(Float(y) * 0.005)
            + 15 * sin(Float(x) * 0.02 + Float(y) * 0.015)
        switch name {
        case "smooth": return hills
        case "rough": return hills + 10 * HeightfieldScene.noise(x, y)
        default: return Float(((x / 50) + (y / 50)) % 3) * 30
        }
    }

    @Test(
        "Pick error in cells at forced levels and at the natural level",
        arguments: ["smooth", "rough", "stepped"])
    func accuracyAtCoarseLevels(terrain: String) async throws {
        let width = 1000
        let heights = (0..<(width * width)).map { Self.terrain(terrain, $0 % width, $0 / width) }
        let field = Heightfield(width: width, height: width, heights: heights)
        // Oblique perspective, 57 degrees off vertical: a height error moves the hit sideways.
        let camera = CameraState(
            rotation: simd_quatf(angle: 1.0, axis: SIMD3(1, 0, 0)), distance: 900,
            pivot: SIMD3(500, 500, 0))
        let size = 512
        for level in [0, 1, 2, 3, 4, Int?.none] {
            let rig = try HeightfieldPickRig(
                bodies: [HeightfieldScene.body(field)], camera: camera, width: size, height: size,
                forcedLevel: level)
            var errors: [Double] = []
            var misses = 0
            for py in stride(from: 90, to: 440, by: 35) {
                for px in stride(from: 60, to: 460, by: 37) {
                    let ndc = SIMD2(
                        (Float(px) + 0.5) / Float(size) * 2 - 1,
                        1 - (Float(py) + 0.5) / Float(size) * 2)
                    let ray = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: 1)
                    guard let truth = Self.trueCell(ray, field: field) else { continue }
                    guard let hit = await rig.pick(SIMD2(px, py))?.heightfield else {
                        misses += 1
                        continue
                    }
                    let d = SIMD2<Double>(
                        Double(hit.cell.x - truth.x), Double(hit.cell.y - truth.y))
                    errors.append((d * d).sum().squareRoot())
                }
            }
            let sorted = errors.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p90 = sorted.isEmpty ? 0 : sorted[sorted.count * 9 / 10]
            let worst = sorted.last ?? 0
            let name = level.map { "forced level \($0)" } ?? "natural level"
            print(
                "PICK ERROR \(terrain) \(name): median \(median), p90 \(p90), max \(worst) cells over \(errors.count) picks, \(misses) misses"
            )
            if level == 0 {
                #expect(p90 <= 1.5, "\(terrain): full resolution picked \(p90) cells off (p90)")
            }
            #expect(misses <= 8)
        }
    }
}
