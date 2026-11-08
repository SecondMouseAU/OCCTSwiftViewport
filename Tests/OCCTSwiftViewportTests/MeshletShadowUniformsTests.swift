// MeshletShadowUniformsTests.swift
// OCCTSwiftViewport Tests
//
// The mesh-shader shadow pass bound the 128-byte `ShadowUniforms` at the object function's
// buffer 1, where `meshlet_object` declares the whole `Uniforms` struct (issue #229). Metal's
// argument validation rejects a buffer smaller than the struct the function declares, so a shadowed
// box at `.maximum` aborted the process under `MTL_DEBUG_LAYER=1`; without the layer the shader
// read past the bound range, which is undefined behaviour that merely happens to work on current
// hardware.
//
// Two guards, because the abort only shows with API validation on, and that is an environment
// variable Metal reads when the process starts:
//
//  - the reflection test always runs. It asks each mesh pipeline for the size its object and mesh
//    functions declare at the uniform buffers and checks the pass binds at least that many bytes.
//    It does not depend on `Uniforms` or `ShadowUniforms` keeping any size.
//  - the render tests draw a shadowed box through both renderers. CI runs this suite again with
//    `MTL_DEBUG_LAYER=1` (see .github/workflows/tests.yml), and so can you:
//
//        MTL_DEBUG_LAYER=1 swift test --filter MeshletShadowUniformsTests
//
// Mesh shaders need an Apple9 GPU; on any other device these tests return without checking.

import Foundation
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Meshlet shadow pass uniforms (#229)")
struct MeshletShadowUniformsTests {

    /// Whether this machine draws the mesh-shader path at all.
    static var deviceSupportsMeshShaders: Bool {
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false
    }

    // MARK: - Scene

    /// A box in front of a wall, lit from the upper left so it casts a shadow on the wall.
    static func bodies() -> [ViewportBody] {
        let box = ViewportBody.box(
            id: "box", width: 3, height: 3, depth: 3, color: SIMD4(0.9, 0.3, 0.2, 1))
        let wall = ParityRender.quad(
            id: "wall", x0: -8, y0: -8, x1: 8, y1: 8, z: -4, color: SIMD4(0.8, 0.8, 0.8, 1))
        return [box, wall]
    }

    static func lighting(shadows: Bool) -> LightingConfiguration {
        var lighting = ParityRender.plainLighting
        lighting.shadowsEnabled = shadows
        lighting.shadowIntensity = 0.9
        lighting.keyLight.direction = simd_normalize(SIMD3<Float>(0.6, -0.5, -1))
        return lighting
    }

    static func options(shadows: Bool) -> OffscreenRenderOptions {
        var options = ParityRender.options(displayMode: .shaded)
        options.lightingConfiguration = lighting(shadows: shadows)
        options.renderingQuality = .maximum
        return options
    }

    /// Pixels of the wall that are darker than the unshadowed frame's by a clear margin.
    static func shadowedPixels(lit: [UInt8], shadowed: [UInt8]) -> Int {
        var count = 0
        for p in stride(from: 0, to: lit.count, by: 4)
        where Int(lit[p + 1]) - Int(shadowed[p + 1]) > 25 {
            count += 1
        }
        return count
    }

    // MARK: - Rendering

    @Test("A shadowed box renders at .maximum offscreen, and under MTL_DEBUG_LAYER=1")
    func offscreenShadowedBox() throws {
        guard Self.deviceSupportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let bodies = Self.bodies()
        let lit = try ParityRender.render(bodies, Self.options(shadows: false), renderer: renderer)
        let shadowed = try ParityRender.render(
            bodies, Self.options(shadows: true), renderer: renderer)

        // The meshlet path must be the one drawing the shadow map.
        #expect(renderer.surfacePaths(for: Self.options(shadows: true)).meshShaders)
        #expect(renderer.refinementBuffers(forBodyID: "box").meshlets)
        let dark = Self.shadowedPixels(lit: lit.pixels, shadowed: shadowed.pixels)
        #expect(dark > 200, "the box cast no shadow through the meshlet shadow pass (\(dark) px)")
    }

    @Test("A shadowed box renders at .maximum live, and under MTL_DEBUG_LAYER=1")
    func liveShadowedBox() throws {
        guard Self.deviceSupportsMeshShaders else { return }
        var frames: [[UInt8]] = []
        for shadows in [false, true] {
            var config = ViewportConfiguration(
                initialCameraState: ParityRender.frontCamera, displayMode: .shaded,
                lightingConfiguration: Self.lighting(shadows: shadows), showGrid: false,
                backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
            config.showAxes = false
            config.renderingQuality = .maximum
            let controller = ViewportController(configuration: config)
            guard
                let live = ViewportRenderer(
                    controller: controller, bodies: .constant(Self.bodies())),
                let pixels = live.renderHeadlessBGRA(
                    width: 128, height: 128, backgroundColor: config.backgroundColor,
                    frameCount: 2)
            else {
                Issue.record("Metal device unavailable")
                return
            }
            #expect(live.meshShadersEnabled)
            frames.append(pixels)
        }
        let dark = Self.shadowedPixels(lit: frames[0], shadowed: frames[1])
        #expect(dark > 200, "the box cast no shadow through the meshlet shadow pass (\(dark) px)")
    }

    // MARK: - Reflection

    /// The bytes a mesh pipeline's functions declare at one buffer slot, or `nil` if unbound.
    private static func declaredSize(_ bindings: [any MTLBinding], at index: Int) -> Int? {
        bindings.lazy.compactMap { $0 as? MTLBufferBinding }.first { $0.index == index }?
            .bufferDataSize
    }

    @Test("Each mesh pipeline binds at least the bytes its functions declare")
    func boundUniformsCoverTheDeclaredStructs() throws {
        guard Self.deviceSupportsMeshShaders else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = RendererSharedSetup.loadLibrary(device: device)
        else {
            Issue.record("Metal device unavailable")
            return
        }
        // What each pass hands to `encodeMeshletDraw`, bound at object buffer 1 and mesh buffer 4.
        let sceneBytes = MemoryLayout<Uniforms>.size
        let shadowBytes = MemoryLayout<ShadowUniformsSwift>.size
        typealias Reflected = (MTLRenderPipelineReflection) -> Void
        let passes: [(name: String, bound: Int, build: (@escaping Reflected) throws -> Void)] = [
            (
                "shaded", sceneBytes,
                {
                    _ = try RendererSharedSetup.makeMeshShaderShadedPipelineState(
                        device: device, library: library, sampleCount: 1,
                        depthFormat: .depth32Float_stencil8, reflected: $0)
                }
            ),
            (
                "shadow", shadowBytes,
                {
                    _ = try RendererSharedSetup.makeMeshShaderShadowPipelineState(
                        device: device, library: library, reflected: $0)
                }
            ),
            (
                "depth", sceneBytes,
                {
                    _ = try RendererSharedSetup.makeMeshShaderDepthOnlyPipelineState(
                        device: device, library: library, reflected: $0)
                }
            ),
            (
                "pick", sceneBytes,
                {
                    _ = try RendererSharedSetup.makeMeshShaderPipelineState(
                        device: device, library: library, meshFunction: "meshlet_pick_mesh",
                        fragmentFunction: "meshlet_pick_fragment", colorPixelFormat: .r32Uint,
                        depthPixelFormat: .depth32Float, label: "mesh_pick", reflected: $0)
                }
            ),
        ]
        for (name, bound, build) in passes {
            var captured: MTLRenderPipelineReflection?
            try build { captured = $0 }
            let reflection = try #require(captured, "\(name): no reflection")
            let object = try #require(
                Self.declaredSize(reflection.objectBindings, at: 1),
                "\(name): object function declares no buffer 1")
            let mesh = try #require(
                Self.declaredSize(reflection.meshBindings, at: 4),
                "\(name): mesh function declares no buffer 4")
            #expect(
                bound >= object,
                "\(name): binds \(bound) B where the object function declares \(object) B")
            #expect(
                bound >= mesh,
                "\(name): binds \(bound) B where the mesh function declares \(mesh) B")
        }
    }
}
