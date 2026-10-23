// OffscreenTessellationTests.swift
// OCCTSwiftViewport Tests
//
// OffscreenRenderer honours `renderingQuality` (issue #165): PN-triangle tessellation at
// `.enhanced`, mesh shaders at `.maximum` on Apple9, deterministic factors, and the headless
// `.system` appearance following the app's own appearance (issue #186).

import Foundation
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

#if os(macOS)
    import AppKit
#endif

@MainActor
@Suite("Offscreen tessellation and mesh shaders")
struct OffscreenTessellationTests {

    /// A coarse sphere seen along its pole axis, so its outline is a 14-gon until PN triangles
    /// round it.
    ///
    /// Neighbouring normals are ~26 degrees apart, inside the patch builder's 30-degree
    /// crease threshold, so every edge is refined.
    static func coarseSphere() -> ViewportBody {
        ViewportBody.sphere(
            id: "ball", radius: 3, segments: 14, rings: 10, color: SIMD4(0.9, 0.2, 0.2, 1),
            up: .z)
    }

    static func options(
        _ quality: RenderingQuality, adaptive: Bool = true,
        uniform: UniformTessellationFactor = .loadAdaptive()
    ) -> OffscreenRenderOptions {
        var options = ParityRender.options(displayMode: .unlit)
        options.renderingQuality = quality
        options.adaptiveTessellation = adaptive
        options.uniformTessellationFactor = uniform
        options.tessellationMaxFactor = 16
        return options
    }

    /// Pixels covered by the red sphere.
    static func coverage(_ pixels: [UInt8], width: Int, height: Int) -> Int {
        ParityRender.count(pixels, width: width, height: height) { $0.x > 120 && $0.y < 100 }
    }

    @Test("Options default to the live defaults and init(matching:) copies the quality settings")
    func optionsFollowConfiguration() {
        let defaults = OffscreenRenderOptions()
        let live = ViewportController.defaultConfiguration
        #expect(defaults.renderingQuality == live.renderingQuality)
        #expect(defaults.tessellationMaxFactor == live.tessellationMaxFactor)
        #expect(defaults.adaptiveTessellation == live.adaptiveTessellation)
        #expect(defaults.uniformTessellationFactor == live.uniformTessellationFactor)

        var config = ViewportConfiguration.cadHighQuality
        config.adaptiveTessellation = false
        config.uniformTessellationFactor = .fixed(6)
        let controller = ViewportController(configuration: config)
        let matched = OffscreenRenderOptions(matching: controller, width: 64, height: 64)
        #expect(matched.renderingQuality == .enhanced)
        #expect(matched.tessellationMaxFactor == 48)
        #expect(matched.adaptiveTessellation == false)
        #expect(matched.uniformTessellationFactor == .fixed(6))

        // The debug switch turns the live view's refinement off, so the snapshot follows it.
        controller.debugDisableTessellation = true
        let debug = OffscreenRenderOptions(matching: controller, width: 64, height: 64)
        #expect(debug.renderingQuality == .standard)
    }

    @Test("The offscreen factor is never load-governed")
    func deterministicFactor() {
        // `.loadAdaptive` has no load to follow offscreen: it tessellates at the maximum.
        #expect(
            RendererSharedBuffers.deterministicTessellationFactor(
                requestedMaxFactor: 16, pipelineMaxFactor: 16, adaptive: false,
                policy: .loadAdaptive(minimum: 4)) == 16)
        #expect(
            RendererSharedBuffers.deterministicTessellationFactor(
                requestedMaxFactor: 16, pipelineMaxFactor: 16, adaptive: false,
                policy: .fixed(6)) == 6)
        // Adaptive: the maximum, capped to what the pipelines were built with.
        #expect(
            RendererSharedBuffers.deterministicTessellationFactor(
                requestedMaxFactor: 64, pipelineMaxFactor: 32, adaptive: true,
                policy: .fixed(6)) == 32)
        // Odd and out-of-range requests are clamped as the pipelines clamp them.
        #expect(
            RendererSharedBuffers.deterministicTessellationFactor(
                requestedMaxFactor: 7, pipelineMaxFactor: 64, adaptive: true,
                policy: .loadAdaptive()) == 8)
    }

    @Test("renderingQuality selects the offscreen surface path")
    func surfacePaths() throws {
        guard let renderer = OffscreenRenderer(), let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable")
            return
        }
        let standard = renderer.surfacePaths(for: Self.options(.standard))
        #expect(!standard.tessellation && !standard.meshShaders)

        let enhanced = renderer.surfacePaths(for: Self.options(.enhanced))
        #expect(enhanced.tessellation)
        #expect(!enhanced.meshShaders)

        let maximum = renderer.surfacePaths(for: Self.options(.maximum))
        #expect(maximum.tessellation)
        #expect(maximum.meshShaders == device.supportsFamily(.apple9))
    }

    @Test("Bodies get patches only when tessellating, and direct-mesh bodies never do")
    func refinementBuffers() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        let direct = ViewportRenderBattery.directMeshBodies()[0]
        _ = try ParityRender.render([sphere, direct], Self.options(.enhanced), renderer: renderer)
        #expect(renderer.refinementBuffers(forBodyID: sphere.id).tessellation)
        #expect(!renderer.refinementBuffers(forBodyID: direct.id).tessellation)
        #expect(!renderer.refinementBuffers(forBodyID: direct.id).meshlets)

        // Back to `.standard`: the cached patches are dropped rather than drawn.
        _ = try ParityRender.render([sphere, direct], Self.options(.standard), renderer: renderer)
        #expect(!renderer.refinementBuffers(forBodyID: sphere.id).tessellation)
    }

    @Test("Tessellation rounds a faceted silhouette offscreen")
    func tessellationRoundsSilhouette() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        let flat = try ParityRender.render([sphere], Self.options(.standard), renderer: renderer)
        let refined = try ParityRender.render(
            [sphere], Self.options(.enhanced, adaptive: false, uniform: .fixed(8)),
            renderer: renderer)
        let flatArea = Self.coverage(flat.pixels, width: flat.width, height: flat.height)
        let refinedArea = Self.coverage(
            refined.pixels, width: refined.width, height: refined.height)
        // The inscribed 14-gon covers ~97% of the circle; PN triangles bulge it outwards.
        #expect(flatArea > 1000)
        #expect(
            refinedArea > flatArea + flatArea / 100,
            "tessellated sphere covers \(refinedArea) px, the flat one \(flatArea) px")
    }

    @Test(
        "Live and offscreen refine the faceted sphere identically",
        arguments: [RenderingQuality.enhanced, .maximum])
    func liveMatchesOffscreenRefinement(quality: RenderingQuality) throws {
        let sphere = Self.coarseSphere()
        let options = Self.options(quality, adaptive: false, uniform: .fixed(8))
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: .unlit,
            lightingConfiguration: ParityRender.plainLighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        config.showAxes = false
        config.renderingQuality = quality
        config.tessellationMaxFactor = options.tessellationMaxFactor
        config.adaptiveTessellation = false
        config.uniformTessellationFactor = .fixed(8)
        let controller = ViewportController(configuration: config)
        guard let renderer = OffscreenRenderer(),
            let live = ViewportRenderer(controller: controller, bodies: .constant([sphere])),
            let livePixels = live.renderHeadlessBGRA(
                width: options.width, height: options.height,
                backgroundColor: config.backgroundColor, frameCount: 2)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let paths = renderer.surfacePaths(for: options)
        #expect(paths.tessellation == live.tessellationEnabled)
        #expect(paths.meshShaders == live.meshShadersEnabled)

        let offscreen = try ParityRender.render([sphere], options, renderer: renderer)
        #expect(offscreen.pixels == livePixels, "\(quality): offscreen differs from live")

        // Each path must leave a mark, or the comparison would pass with it switched off.
        let tessellated = try ParityRender.render(
            [sphere], Self.options(.enhanced, adaptive: false, uniform: .fixed(8)),
            renderer: renderer)
        let flat = try ParityRender.render([sphere], Self.options(.standard), renderer: renderer)
        if paths.meshShaders {
            // Meshlets draw the mesh as given: no PN rounding, unlike the tessellated fallback.
            #expect(offscreen.pixels != tessellated.pixels)
        } else {
            #expect(offscreen.pixels != flat.pixels)
        }
    }

    @Test("Tessellated offscreen output is deterministic")
    func tessellatedOutputIsDeterministic() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        let loadAdaptive = Self.options(.enhanced, adaptive: false, uniform: .loadAdaptive())
        let first = try ParityRender.render([sphere], loadAdaptive, renderer: renderer)
        let second = try ParityRender.render([sphere], loadAdaptive, renderer: renderer)
        #expect(first.pixels == second.pixels)
        // `.loadAdaptive` offscreen is exactly the maximum factor.
        let fixedMax = try ParityRender.render(
            [sphere], Self.options(.enhanced, adaptive: false, uniform: .fixed(16)),
            renderer: renderer)
        #expect(first.pixels == fixedMax.pixels)
    }

    @Test(
        "Tessellated shadow map and silhouette prepass match live",
        arguments: ["shadow", "silhouette"])
    func refinedShadowAndDepthMatchLive(pass: String) throws {
        // The faceted sphere casts its shadow on a wall behind it, or is outlined by the
        // depth-based silhouette. Both renderers tessellate the main pass, so any difference
        // comes from a shadow or depth pass drawing the unrefined mesh.
        let sphere = Self.coarseSphere()
        let wall = ParityRender.quad(
            id: "wall", x0: -8, y0: -8, x1: 8, y1: 8, z: -4, color: SIMD4(0.8, 0.8, 0.8, 1))
        let bodies = [sphere, wall]
        var lighting = ParityRender.plainLighting
        lighting.shadowsEnabled = pass == "shadow"
        lighting.shadowIntensity = 0.8
        lighting.keyLight.direction = simd_normalize(SIMD3<Float>(-0.5, -0.4, -1))
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: .shaded,
            lightingConfiguration: lighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: pass == "silhouette")
        config.showAxes = false
        config.renderingQuality = .enhanced
        config.tessellationMaxFactor = 16
        config.adaptiveTessellation = false
        config.uniformTessellationFactor = .fixed(8)
        config.silhouetteThickness = 2
        config.silhouetteIntensity = 1
        let controller = ViewportController(configuration: config)
        var options = OffscreenRenderOptions(matching: controller, width: 128, height: 128)
        options.appearance = .light
        guard
            let live = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let livePixels = live.renderHeadlessBGRA(
                width: 128, height: 128, backgroundColor: config.backgroundColor, frameCount: 2)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        let offscreen = try ParityRender.render(bodies, options)
        var differing = 0
        for p in stride(from: 0, to: livePixels.count, by: 4) {
            let delta =
                (0..<3).map { abs(Int(livePixels[p + $0]) - Int(offscreen.pixels[p + $0])) }.max()
                ?? 0
            if delta > 8 { differing += 1 }
        }
        #expect(differing == 0, "\(pass): \(differing) px differ from the live frame")
    }
}

// MARK: - Headless appearance (#186)

@MainActor
@Suite("Headless system appearance")
struct HeadlessAppearanceTests {

    #if os(macOS)
        @Test("The app's own appearance wins over the user default")
        func appAppearanceWins() {
            let dark = NSAppearance(named: .darkAqua)
            let light = NSAppearance(named: .aqua)
            #expect(RenderAppearance.isDark(appAppearance: dark, interfaceStyle: nil))
            #expect(!RenderAppearance.isDark(appAppearance: light, interfaceStyle: "Dark"))
            #expect(RenderAppearance.isDark(appAppearance: dark, interfaceStyle: "Light"))
            // High-contrast variants match their base appearance.
            let contrastDark = NSAppearance(named: .accessibilityHighContrastDarkAqua)
            #expect(RenderAppearance.isDark(appAppearance: contrastDark, interfaceStyle: nil))
        }

        @Test("Without an application the user default decides")
        func userDefaultFallback() {
            #expect(RenderAppearance.isDark(appAppearance: nil, interfaceStyle: "Dark"))
            #expect(!RenderAppearance.isDark(appAppearance: nil, interfaceStyle: nil))
        }

        @Test(".system follows NSApp.effectiveAppearance once an application exists")
        func systemReadsApplication() {
            let app = NSApplication.shared
            // Not mutated here: other suites render `.system` concurrently.
            let expected = RenderAppearance.isDark(
                appAppearance: app.effectiveAppearance, interfaceStyle: nil)
            #expect(RenderAppearance.system.isDark == expected)
        }
    #endif

    @Test("Pinned appearances ignore the host")
    func pinnedAppearances() {
        #expect(RenderAppearance.dark.isDark)
        #expect(!RenderAppearance.light.isDark)
    }
}
