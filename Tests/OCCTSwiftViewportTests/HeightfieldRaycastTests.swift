// HeightfieldRaycastTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 3 stretch: the CPU grid-march that casts a ray against the full-resolution
// surface (`Heightfield.raycast`, used by `SceneRaycast`), and the bounds a heightfield body reports.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield ray cast and bounds (#139)")
struct HeightfieldRaycastTests {

    /// The nearest hit of a ray against every quad's two triangles, with no acceleration.
    private static func bruteForce(_ field: Heightfield, _ ray: Ray) -> Float? {
        let cs = field.cellSize
        var best: Float?
        for qy in 0..<(field.height - 1) {
            for qx in 0..<(field.width - 1) {
                let x0 = field.origin.x + (Float(qx) + 0.5) * cs.x
                let y0 = field.origin.y + (Float(qy) + 0.5) * cs.y
                func h(_ x: Int, _ y: Int) -> Float { field.sample(x: x, y: y)!.height }
                let p00 = SIMD3(x0, y0, h(qx, qy))
                let p10 = SIMD3(x0 + cs.x, y0, h(qx + 1, qy))
                let p01 = SIMD3(x0, y0 + cs.y, h(qx, qy + 1))
                let p11 = SIMD3(x0 + cs.x, y0 + cs.y, h(qx + 1, qy + 1))
                for t in [
                    ray.intersectsTriangle(v0: p00, v1: p10, v2: p11),
                    ray.intersectsTriangle(v0: p00, v1: p11, v2: p01),
                ] {
                    if let t, t >= 0, best == nil || t < best! { best = t }
                }
            }
        }
        return best
    }

    @Test(
        "The grid march finds exactly the brute-force hit, from above, at grazing angles and from below"
    )
    func gridMarchMatchesBruteForce() {
        let width = 70
        let height = 55
        let heights = (0..<(width * height)).map {
            12 * HeightfieldScene.noise($0 % width, $0 / width) + Float($0 % width) * 0.3
        }
        let field = Heightfield(
            width: width, height: height, origin: SIMD2(5, -3), cellSize: SIMD2(1.5, 0.75),
            heights: heights)
        var rng = SystemRandomNumberGenerator()
        var compared = 0
        var hits = 0
        for _ in 0..<600 {
            let target = SIMD3<Float>(
                Float.random(in: 0...105, using: &rng), Float.random(in: -3...38, using: &rng),
                Float.random(in: -10...25, using: &rng))
            let source = SIMD3<Float>(
                Float.random(in: -80...190, using: &rng), Float.random(in: -80...120, using: &rng),
                Float.random(in: -40...120, using: &rng))
            let direction = simd_normalize(target - source)
            let expected = Self.bruteForce(field, Ray(origin: source, direction: direction))
            let got = field.raycast(origin: source, direction: direction)
            compared += 1
            if let expected {
                hits += 1
                #expect(got != nil, "march missed a hit at \(expected)")
                if let got { #expect(abs(got.distance - expected) < 1e-3 * max(1, expected)) }
            } else {
                #expect(got == nil)
            }
        }
        #expect(hits > 150, "only \(hits) of \(compared) rays hit")
    }

    @Test("The cell reported by the march matches the point it hits")
    func cellMatchesPoint() throws {
        let field = HeightfieldScene.terrainField(width: 400, height: 300)
        let ray = Ray(
            origin: SIMD3(120.3, 80.7, 500), direction: simd_normalize(SIMD3(0.2, 0.1, -1)))
        let hit = try #require(field.raycast(origin: ray.origin, direction: ray.direction))
        let point = ray.origin + ray.direction * hit.distance
        #expect(hit.cell == SIMD2(Int(point.x.rounded(.down)), Int(point.y.rounded(.down))))
        #expect(field.cell(atLocal: SIMD2(point.x, point.y)) == hit.cell)
    }

    @Test("SceneRaycast hits a heightfield body through its transform and honours clip planes")
    func sceneRaycast() throws {
        let field = HeightfieldScene.terrainField(width: 200, height: 200)
        var body = HeightfieldScene.body(field)
        // Scaled by 2 in XY and moved: a world ray must be mapped into the field's local space.
        body.transform = simd_float4x4(
            columns: (
                SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(1000, 500, 0, 1)
            ))
        let ray = Ray(origin: SIMD3(1100, 700, 300), direction: SIMD3(0, 0, -1))
        let hit = try #require(SceneRaycast.cast(ray: ray, bodies: [body]))
        #expect(hit.bodyID == "field")
        // Local (50, 100), the cell (49 or 50, 99 or 100) region.
        let local = field.raycast(origin: SIMD3(50, 100, 300), direction: SIMD3(0, 0, -1))
        let expected = try #require(local)
        #expect(abs(hit.distance - expected.distance) < 1e-3)
        #expect(abs(hit.point.z - (300 - expected.distance)) < 1e-3)
        // A ray beside the field misses; a clip plane that removes the hit point drops it.
        #expect(
            SceneRaycast.cast(
                ray: Ray(origin: SIMD3(2000, 700, 300), direction: SIMD3(0, 0, -1)), bodies: [body])
                == nil)
        let clip = ClipPlane(normal: SIMD3(0, 0, -1), distance: -1000)
        #expect(SceneRaycast.cast(ray: ray, bodies: [body], clipPlanes: [clip]) == nil)
    }

    @Test("A long ray across 2000 cells costs microseconds, not milliseconds")
    func longRayCost() throws {
        let field = HeightfieldScene.terrainField(width: 2000, height: 2000)
        let direction = simd_normalize(SIMD3<Float>(1, 0.8, -0.01))
        var hit: (distance: Float, cell: SIMD2<Int>)?
        let start = DispatchTime.now().uptimeNanoseconds
        let rays = 200
        for i in 0..<rays {
            hit = field.raycast(origin: SIMD3(0, Float(i), 30), direction: direction)
        }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e3 / Double(rays)
        print(
            "RAYCAST near-grazing ray across 2000 cells: \(micros) us per ray (last hit \(String(describing: hit)))"
        )
        #expect(hit != nil)
    }

    @Test("A cached bounding box does not go stale when an edit raises the surface")
    func pivotCacheFollowsEdits() {
        let field = Heightfield(width: 100, height: 100, initialHeight: 0)
        let body = HeightfieldScene.body(field)
        let strategy = PivotStrategy()
        // A horizontal ray at z = 25, above the flat surface.
        let ray = Ray(origin: SIMD3(-20, 50, 25), direction: SIMD3(1, 0, 0))
        #expect(strategy.raycast(ray: ray, bodies: [body], clipPlanes: []) == nil)
        field.replace(
            region: HeightfieldRegion(x: 40, y: 40, width: 20, height: 20),
            heights: [Float](repeating: 60, count: 400))
        let hit = strategy.raycast(ray: ray, bodies: [body], clipPlanes: [])
        #expect(hit?.bodyID == "field", "the cached box still had the old top")
    }

    // MARK: Bounds

    @Test("The body's bounds follow the field's extents and its running height range")
    func boundsFollowTheField() {
        let field = Heightfield(
            width: 100, height: 50, origin: SIMD2(10, 20), cellSize: SIMD2(0.5, 2), initialHeight: 3
        )
        var body = HeightfieldScene.body(field)
        var box = body.boundingBox
        #expect(box?.min == SIMD3(10, 20, 3))
        #expect(box?.max == SIMD3(60, 120, 3))
        // An edit that raises the surface widens the bounds without touching the body.
        let generation = body.generation
        field.replace(
            region: HeightfieldRegion(x: 4, y: 4, width: 2, height: 2), heights: [9, 9, 9, 9])
        box = body.boundingBox
        #expect(box?.max.z == 9)
        #expect(body.generation == generation, "an edit must not look like a new body")
        // A body that swaps in another field takes a new generation.
        body.heightfield = Heightfield(width: 10, height: 10)
        #expect(body.generation != generation)
        #expect(RendererSharedSetup.sceneBounds(of: [body])?.max == SIMD3(10, 10, 0))
    }
}
