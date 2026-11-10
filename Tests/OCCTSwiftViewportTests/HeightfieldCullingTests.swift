// HeightfieldCullingTests.swift
// OCCTSwiftViewport Tests
//
// Which tiles of a heightfield each pass draws: the camera's plan, the shadow plan against the
// light, and section planes that remove whole tiles.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield tile culling (#139)")
struct HeightfieldCullingTests {

    // MARK: Section planes

    @Test("A section plane drops the tiles wholly behind it from the plan")
    func clipPlaneCullsTiles() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // 640 x 640 cells: 10 x 10 tiles.
        let field = try Heightfield(width: 640, height: 640)
        let body = HeightfieldScene.body(field)
        var options = HeightfieldScene.options(
            width: 128, height: 128,
            camera: CameraState(
                distance: 2000, pivot: SIMD3(320, 320, 0), orthographicScale: 700,
                isOrthographic: true))
        func tiles() throws -> Int {
            _ = try #require(renderer.render(bodies: [body], options: options))
            return try #require(renderer.heightfieldState(forBodyID: "field")?.lastPlan).tileCount
        }
        let whole = try tiles()
        #expect(whole == 100)

        // Keeps x <= 300: the plane's positive side is where dot(N, P) + distance >= 0.
        options.clipPlanes = [ClipPlane(normal: SIMD3(-1, 0, 0), distance: 300)]
        let clipped = try tiles()
        #expect(clipped == 50, "half the tile columns lie wholly behind the plane, got \(clipped)")

        // A plane through the middle of a tile column keeps that column: culling is conservative.
        options.clipPlanes = [ClipPlane(normal: SIMD3(-1, 0, 0), distance: 340)]
        #expect(try tiles() == 60)

        // Everything clipped: nothing to draw, and the background shows.
        options.clipPlanes = [ClipPlane(normal: SIMD3(-1, 0, 0), distance: -10)]
        #expect(try tiles() == 0)
    }

    // MARK: Shadows

    private func lighting(direction: SIMD3<Float>, shadows: Bool) -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = shadows
        lighting.shadowIntensity = 0.8
        lighting.shadowMapSize = 2048
        lighting.enableSSAO = false
        lighting.keyLight.direction = simd_normalize(direction)
        return lighting
    }

    @Test("The shadow plan keeps off-screen casters whose shadows reach the view, and culls the rest")
    func shadowPlanKeepsOffscreenCasters() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // 1280 x 1280 cells: 20 x 20 tiles. The camera sees the lower-left corner, 5 x 5 tiles.
        let field = try Heightfield(width: 1280, height: 1280)
        let body = HeightfieldScene.body(field)
        var options = HeightfieldScene.options(
            width: 128, height: 128,
            camera: CameraState(
                distance: 4000, pivot: SIMD3(160, 160, 0), orthographicScale: 300,
                isOrthographic: true))
        // The light travels toward -x, so a shadow falls toward the view from tiles to its right,
        // but never sideways from the rows above it.
        options.lightingConfiguration = lighting(direction: SIMD3(-1, 0, -0.5), shadows: true)
        _ = try #require(renderer.render(bodies: [body], options: options))
        let state = try #require(renderer.heightfieldState(forBodyID: "field"))
        let camera = try #require(state.lastPlan).tileCount
        let shadow = try #require(state.lastShadowPlan).tileCount
        #expect(camera == 25)
        #expect(shadow == 100, "5 rows of 20 tiles can shadow the view, got \(shadow)")

        // Shadows off: no shadow plan at all.
        options.lightingConfiguration = lighting(direction: SIMD3(-1, 0, -0.5), shadows: false)
        _ = try #require(renderer.render(bodies: [body], options: options))
        #expect(renderer.heightfieldState(forBodyID: "field")?.lastShadowPlan == nil)
    }

    @Test("A block off screen throws a shadow into the view")
    func offscreenBlockShadowsTheView() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // A flat 512 x 128 sheet with a 100-high block at x 400...420, beyond the right edge of
        // the view (x 0...300). Lit from the right, its 200-long shadow reaches x = 200.
        var heights = [Float](repeating: 0, count: 512 * 128)
        for y in 40..<80 { for x in 400..<420 { heights[y * 512 + x] = 100 } }
        let field = try Heightfield(width: 512, height: 128, heights: heights)
        let body = HeightfieldScene.body(field)
        func render(shadows: Bool) throws -> [UInt8] {
            var options = HeightfieldScene.options(
                width: 256, height: 256,
                camera: CameraState(
                    distance: 2000, pivot: SIMD3(150, 64, 0), orthographicScale: 300,
                    isOrthographic: true))
            options.lightingConfiguration = lighting(
                direction: SIMD3(-1, 0, -0.5), shadows: shadows)
            return HeightfieldScene.pixels(
                try #require(renderer.render(bodies: [body], options: options))
            ).pixels
        }
        let lit = try render(shadows: false)
        let shadowed = try render(shadows: true)
        var darker = 0
        for i in stride(from: 0, to: lit.count, by: 4) {
            let a = Int(lit[i]) + Int(lit[i + 1]) + Int(lit[i + 2])
            let b = Int(shadowed[i]) + Int(shadowed[i + 1]) + Int(shadowed[i + 2])
            if b * 100 < a * 94 { darker += 1 }
        }
        #expect(darker > 500, "the off-screen block cast almost no shadow into view (\(darker) px)")
    }
}
