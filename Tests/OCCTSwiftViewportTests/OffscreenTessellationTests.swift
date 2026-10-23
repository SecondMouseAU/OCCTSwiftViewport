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

    @Test("Live and offscreen tessellate the faceted sphere identically")
    func liveMatchesOffscreenTessellation() throws {
        let sphere = Self.coarseSphere()
        let options = Self.options(.enhanced, adaptive: false, uniform: .fixed(8))
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: .unlit,
            lightingConfiguration: ParityRender.plainLighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        config.showAxes = false
        config.renderingQuality = .enhanced
        config.tessellationMaxFactor = options.tessellationMaxFactor
        config.adaptiveTessellation = false
        config.uniformTessellationFactor = .fixed(8)
        let controller = ViewportController(configuration: config)
        guard
            let live = ViewportRenderer(controller: controller, bodies: .constant([sphere])),
            let livePixels = live.renderHeadlessBGRA(
                width: options.width, height: options.height,
                backgroundColor: config.backgroundColor, frameCount: 2)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(live.tessellationEnabled)
        let offscreen = try ParityRender.render([sphere], options)
        let flat = try ParityRender.render([sphere], Self.options(.standard))
        let liveArea = Self.coverage(livePixels, width: options.width, height: options.height)
        let offscreenArea = Self.coverage(
            offscreen.pixels, width: offscreen.width, height: offscreen.height)
        let flatArea = Self.coverage(flat.pixels, width: flat.width, height: flat.height)
        #expect(liveArea == offscreenArea)
        #expect(offscreenArea != flatArea, "the comparison would pass without tessellation")
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

    @Test("Shaded, shadowed and composited tessellated renders complete at every quality")
    func fullPipelineAtEveryQuality() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        for quality in [RenderingQuality.standard, .enhanced, .maximum] {
            let bodies = ViewportRenderBattery.shadowBodies()
            var options = Self.options(quality)
            options.cameraState = ViewportRenderBattery.fittedCamera(for: bodies)
            options.displayMode = .shadedWithEdges
            options.lightingConfiguration = ViewportRenderBattery.shadowLighting()
            options.lightingConfiguration.enableSSAO = true
            options.enableSilhouettes = true
            let result = try ParityRender.render(bodies, options, renderer: renderer)
            let lit = ParityRender.count(result.pixels, width: result.width, height: result.height)
            {
                $0.x + $0.y + $0.z > 60
            }
            #expect(lit > 500, "\(quality): almost nothing drawn (\(lit) px)")
        }
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
