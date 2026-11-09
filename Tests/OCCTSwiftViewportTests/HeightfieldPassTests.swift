// HeightfieldPassTests.swift
// OCCTSwiftViewport Tests
//
// Issue #139 spike, phase 4: the heightfield in the passes beyond the shaded one. Every pass's
// vertex function calls the same displacement function, so the positions must agree to the bit;
// the depth-equality test proves it by drawing one field through the shaded, shadow and depth-only
// pipelines under the same matrix and comparing the depth they leave. The rest check that the
// shadow and SSAO / silhouette depth passes draw the field in both renderers.

import CoreGraphics
import Foundation
@preconcurrency import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Heightfield in the shadow and depth passes (#139)")
struct HeightfieldPassTests {

    // MARK: Depth equality across vertex functions

    /// Draws `body` through the shaded, shadow and depth-only heightfield pipelines under the same
    /// view-projection and returns the depth each left, as `Float`s.
    private func depths(
        of body: ViewportBody, size: Int, forcedLevel: Int? = nil
    ) throws -> [String: [Float]] {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = RendererSharedSetup.loadLibrary(device: device)
        else {
            Issue.record("Metal device unavailable; skipping")
            throw HeightfieldPickRig.Unavailable()
        }
        let cache = HeightfieldRenderCache(device: device, library: library)
        cache.forcedLevel = forcedLevel
        let camera = CameraState(
            rotation: simd_quatf(angle: 0.9, axis: SIMD3(1, 0, 0))
                * simd_quatf(angle: 0.3, axis: SIMD3(0, 0, 1)),
            distance: 900, pivot: SIMD3(250, 250, 0))
        let view = camera.viewMatrix
        let projection = camera.projectionMatrix(aspectRatio: 1, near: 100, far: 4000)
        let viewProjection = projection * view

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw HeightfieldPickRig.Unavailable()
        }
        let entries = cache.prepare(
            bodies: [body], commandBuffer: commandBuffer, view: view, projection: projection,
            viewportHeight: Float(size))
        let entry = try #require(entries.first)

        func depthTexture(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: size, height: size, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        func pass(depth: MTLTexture, color: MTLTexture? = nil) -> MTLRenderPassDescriptor {
            let p = MTLRenderPassDescriptor()
            p.depthAttachment.texture = depth
            p.depthAttachment.loadAction = .clear
            p.depthAttachment.storeAction = .store
            p.depthAttachment.clearDepth = 1
            if let color {
                p.colorAttachments[0].texture = color
                p.colorAttachments[0].loadAction = .clear
                p.colorAttachments[0].storeAction = .dontCare
                p.stencilAttachment.texture = depth
                p.stencilAttachment.loadAction = .clear
                p.stencilAttachment.storeAction = .dontCare
            }
            return p
        }
        let depthState = try #require(
            RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .less, isDepthWriteEnabled: true))
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        var uniforms = Uniforms(
            viewProjection: viewProjection, viewMatrix: view, cameraPosition: camera.position,
            nearPlane: 100, farPlane: 4000, lighting: lighting,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false)
        uniforms.modelMatrix = body.transform
        var bodyUniforms = BodyUniforms(body: body)

        // Shaded: the real shaded pipeline, colour attachment and all.
        let shadedDepth = depthTexture(.depth32Float_stencil8)
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private
        let color = device.makeTexture(descriptor: colorDesc)!
        let matcap = try #require(RendererSharedSetup.makeMatcapTexture(device: device))
        let shadowDummyDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 4, height: 4, mipmapped: false)
        shadowDummyDesc.usage = [.shaderRead]
        shadowDummyDesc.storageMode = .private
        let shadowDummy = device.makeTexture(descriptor: shadowDummyDesc)!
        let shadedPipelines = try #require(
            cache.pipelines(sampleCount: 1, depthFormat: .depth32Float_stencil8))
        do {
            let enc = try #require(
                commandBuffer.makeRenderCommandEncoder(
                    descriptor: pass(depth: shadedDepth, color: color)))
            enc.setDepthStencilState(depthState)
            enc.setRenderPipelineState(shadedPipelines.shaded)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            enc.setFragmentBytes(&bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            enc.setFragmentTexture(matcap, index: 0)
            enc.setFragmentTexture(shadowDummy, index: 1)
            entry.state.encodeShadedDraws(encoder: enc, plan: entry.plan)
            enc.endEncoding()
        }
        // Shadow: the light matrix is the camera's, so its depth must equal the shaded depth.
        let shadowDepth = depthTexture(.depth32Float)
        do {
            let enc = try #require(
                commandBuffer.makeRenderCommandEncoder(descriptor: pass(depth: shadowDepth)))
            enc.setDepthStencilState(depthState)
            enc.setRenderPipelineState(try #require(cache.shadowPipelineState()))
            var shadowUniforms = ShadowUniformsSwift(
                lightViewProjectionMatrix: viewProjection, modelMatrix: body.transform)
            enc.setVertexBytes(
                &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            entry.state.encodeDepthDraws(encoder: enc, plan: entry.plan)
            enc.endEncoding()
        }
        // Depth-only (SSAO / silhouette prepass).
        let prepassDepth = depthTexture(.depth32Float)
        do {
            let enc = try #require(
                commandBuffer.makeRenderCommandEncoder(descriptor: pass(depth: prepassDepth)))
            enc.setDepthStencilState(depthState)
            enc.setRenderPipelineState(try #require(cache.depthPipelineState()))
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            entry.state.encodeDepthDraws(encoder: enc, plan: entry.plan)
            enc.endEncoding()
        }

        // Read each depth back.
        func readback(_ texture: MTLTexture, stencilCombined: Bool) -> MTLBuffer {
            let buffer = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: size, height: size, depth: 1), to: buffer,
                destinationOffset: 0, destinationBytesPerRow: size * 4,
                destinationBytesPerImage: size * size * 4,
                options: stencilCombined ? .depthFromDepthStencil : [])
            blit.endEncoding()
            return buffer
        }
        let shadedBuffer = readback(shadedDepth, stencilCombined: true)
        let shadowBuffer = readback(shadowDepth, stencilCombined: false)
        let prepassBuffer = readback(prepassDepth, stencilCombined: false)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        func floats(_ b: MTLBuffer) -> [Float] {
            Array(
                UnsafeBufferPointer(
                    start: b.contents().bindMemory(to: Float.self, capacity: size * size),
                    count: size * size))
        }
        return [
            "shaded": floats(shadedBuffer), "shadow": floats(shadowBuffer),
            "depth": floats(prepassBuffer),
        ]
    }

    @Test(
        "The shaded, shadow and depth-only vertex functions leave identical depth",
        arguments: [Int?.none, 0, 3])
    func depthEqualAcrossPasses(forcedLevel: Int?) throws {
        let field = HeightfieldScene.terrainField(width: 500, height: 500)
        var body = HeightfieldScene.body(field)
        // A transform with rotation, scale and translation, so the model matrix matters.
        body.transform =
            simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3(0, 0, 1)))
            * simd_float4x4(diagonal: SIMD4(1.2, 0.9, 1, 1))
        body.transform.columns.3 = SIMD4(-30, 20, 5, 1)
        let result = try depths(of: body, size: 256, forcedLevel: forcedLevel)
        let shaded = try #require(result["shaded"])
        let shadow = try #require(result["shadow"])
        let prepass = try #require(result["depth"])

        let covered = shaded.filter { $0 < 1 }.count
        #expect(covered > 10_000, "the field covers only \(covered) pixels; the test is vacuous")
        var worstShadow: Float = 0
        var worstPrepass: Float = 0
        var exact = 0
        for i in shaded.indices {
            worstShadow = max(worstShadow, abs(shaded[i] - shadow[i]))
            worstPrepass = max(worstPrepass, abs(shaded[i] - prepass[i]))
            if shaded[i] == shadow[i] && shaded[i] == prepass[i] { exact += 1 }
        }
        print(
            "DEPTH EQUALITY level \(String(describing: forcedLevel)): \(covered) covered, "
                + "\(exact) of \(shaded.count) pixels bit-identical, worst |shaded - shadow| "
                + "\(worstShadow), |shaded - depth| \(worstPrepass)")
        #expect(worstShadow <= 1e-6, "shadow depth differs from shaded depth by \(worstShadow)")
        #expect(worstPrepass <= 1e-6, "depth-only differs from shaded depth by \(worstPrepass)")
        #expect(exact == shaded.count)
    }

    @Test("The depth comparison sees a different level of detail, so equality is not vacuous")
    func differentLevelsDiffer() throws {
        let field = HeightfieldScene.terrainField(width: 500, height: 500)
        let body = HeightfieldScene.body(field)
        let a = try #require(try depths(of: body, size: 128, forcedLevel: 0)["depth"])
        let b = try #require(try depths(of: body, size: 128, forcedLevel: 4)["depth"])
        let differing = zip(a, b).filter { abs($0 - $1) > 1e-6 }.count
        #expect(differing > 500, "level 0 and level 4 left the same depth (\(differing) px differ)")
    }

    // MARK: Shadow pass

    /// A flat 100 x 100 base with a 40-high block, lit from the side so the block throws a long
    /// shadow across the base.
    private func blockField() -> Heightfield {
        var heights = [Float](repeating: 0, count: 100 * 100)
        for y in 40..<60 { for x in 40..<60 { heights[y * 100 + x] = 40 } }
        return Heightfield(width: 100, height: 100, heights: heights)
    }

    private func sideLit(shadows: Bool) -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = shadows
        lighting.shadowIntensity = 0.7
        lighting.shadowMapSize = 1024
        lighting.enableSSAO = false
        lighting.keyLight.direction = simd_normalize(SIMD3(-1, -0.3, -0.7))
        return lighting
    }

    private func luminance(_ c: SIMD3<Int>) -> Int { c.x + c.y + c.z }

    @Test("A heightfield casts a shadow, offscreen")
    func castsShadowOffscreen() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let body = HeightfieldScene.body(blockField())
        func render(shadows: Bool) throws -> [UInt8] {
            var options = HeightfieldScene.options(
                width: 256, height: 256,
                camera: CameraState(
                    distance: 400, pivot: SIMD3(50, 50, 0), orthographicScale: 130,
                    isOrthographic: true))
            options.lightingConfiguration = sideLit(shadows: shadows)
            return HeightfieldScene.pixels(
                try #require(renderer.render(bodies: [body], options: options))
            )
            .pixels
        }
        let lit = try render(shadows: false)
        let shadowed = try render(shadows: true)
        if let dir = ProcessInfo.processInfo.environment["VIEWPORT_SPIKE_PNG_DIR"] {
            for (name, px) in [("shadow-off", lit), ("shadow-on", shadowed)] {
                HeightfieldScene.writePNG(px, width: 256, height: 256, to: "\(dir)/hf-\(name).png")
            }
        }
        var darker = 0
        for i in stride(from: 0, to: lit.count, by: 4) {
            let a = Int(lit[i]) + Int(lit[i + 1]) + Int(lit[i + 2])
            let b = Int(shadowed[i]) + Int(shadowed[i + 1]) + Int(shadowed[i + 2])
            if b * 100 < a * 94 { darker += 1 }
        }
        print("SHADOW offscreen: \(darker) pixels at least 6% darker with shadows on")
        #expect(darker > 800, "the block cast almost no shadow (\(darker) px darker)")
    }

    @Test("A heightfield casts a shadow, in the live renderer")
    func castsShadowLive() throws {
        let body = HeightfieldScene.body(blockField())
        func render(shadows: Bool) throws -> [UInt8] {
            var config = ViewportConfiguration()
            config.initialCameraState = CameraState(
                distance: 400, pivot: SIMD3(50, 50, 0), orthographicScale: 130, isOrthographic: true
            )
            config.backgroundColor = HeightfieldScene.background
            config.showViewCube = false
            config.msaaSampleCount = 1
            config.enableSilhouettes = false
            let controller = ViewportController(configuration: config)
            controller.displayMode = .shaded
            controller.lightingConfiguration = sideLit(shadows: shadows)
            controller.showGrid = false
            controller.showAxes = false
            controller.enableTAA = false
            guard
                let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
            else {
                Issue.record("Metal device unavailable; skipping")
                throw HeightfieldPickRig.Unavailable()
            }
            return try #require(
                renderer.renderHeadlessBGRA(
                    width: 256, height: 256, backgroundColor: HeightfieldScene.background))
        }
        let lit = try render(shadows: false)
        let shadowed = try render(shadows: true)
        var darker = 0
        for i in stride(from: 0, to: lit.count, by: 4) {
            let a = Int(lit[i]) + Int(lit[i + 1]) + Int(lit[i + 2])
            let b = Int(shadowed[i]) + Int(shadowed[i + 1]) + Int(shadowed[i + 2])
            if b * 100 < a * 94 { darker += 1 }
        }
        print("SHADOW live: \(darker) pixels at least 6% darker with shadows on")
        #expect(darker > 800, "the block cast almost no shadow (\(darker) px darker)")
    }

    // MARK: Section planes

    @Test("A section plane hides the half of the field behind it, in the shaded pass")
    func clipPlaneHidesHalf() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = Heightfield(width: 100, height: 100, initialHeight: 0)
        var options = HeightfieldScene.options(
            width: 128, height: 128,
            camera: CameraState(
                distance: 300, pivot: SIMD3(50, 50, 0), orthographicScale: 120, isOrthographic: true
            ))
        let whole = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [HeightfieldScene.body(field)], options: options)))
        // Keeps x < 50: the plane's positive side is where dot(N, P) + distance >= 0.
        options.clipPlanes = [ClipPlane(normal: SIMD3(-1, 0, 0), distance: 50)]
        let cut = HeightfieldScene.pixels(
            try #require(renderer.render(bodies: [HeightfieldScene.body(field)], options: options)))
        let wholeCount = ParityRender.count(whole.pixels, width: 128, height: 128) {
            !HeightfieldScene.isBackground($0)
        }
        let cutCount = ParityRender.count(cut.pixels, width: 128, height: 128) {
            !HeightfieldScene.isBackground($0)
        }
        print("CLIP: \(wholeCount) pixels whole, \(cutCount) after the section plane")
        #expect(cutCount > wholeCount * 4 / 10 && cutCount < wholeCount * 6 / 10)
    }

    // MARK: Live against offscreen

    @Test("The live renderer draws a heightfield as the offscreen renderer does")
    func liveMatchesOffscreen() throws {
        let field = HeightfieldScene.terrainField(width: 300, height: 300)
        var heights = [Float](repeating: 0, count: 16)
        heights[0] = 1
        field.replace(
            region: HeightfieldRegion(x: 100, y: 100, width: 4, height: 4),
            heights: heights.map { $0 * 20 }, attributes: [UInt8](repeating: 3, count: 16))
        let body = HeightfieldScene.body(field)
        let camera = CameraState(
            rotation: simd_quatf(angle: 0.8, axis: SIMD3(1, 0, 0)), distance: 600,
            pivot: SIMD3(150, 150, 0))
        guard let offscreen = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var options = HeightfieldScene.options(width: 256, height: 256, camera: camera)
        options.lightingConfiguration.shadowsEnabled = true
        let off = HeightfieldScene.pixels(
            try #require(offscreen.render(bodies: [body], options: options)))

        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.backgroundColor = HeightfieldScene.background
        config.showViewCube = false
        config.msaaSampleCount = 1
        config.enableSilhouettes = false
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shaded
        controller.lightingConfiguration = options.lightingConfiguration
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let live = ViewportRenderer(controller: controller, bodies: .constant([body])) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let pixels = try #require(
            live.renderHeadlessBGRA(
                width: 256, height: 256, backgroundColor: HeightfieldScene.background))
        var worst = 0
        var differing = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let d = max(
                abs(Int(pixels[i]) - Int(off.pixels[i])),
                abs(Int(pixels[i + 1]) - Int(off.pixels[i + 1])),
                abs(Int(pixels[i + 2]) - Int(off.pixels[i + 2])))
            worst = max(worst, d)
            if d > 0 { differing += 1 }
        }
        print("PARITY live vs offscreen: \(differing) pixels differ, worst channel delta \(worst)")
        #expect(worst <= 2, "live and offscreen differ by up to \(worst)/255")
    }

    // MARK: SSAO / silhouette depth prepass

    @Test("The silhouette pass sees a heightfield's depth discontinuities, in both renderers")
    func silhouettesSeeTheField() throws {
        let body = HeightfieldScene.body(blockField())
        let camera = CameraState(
            rotation: simd_quatf(angle: 0.7, axis: SIMD3(1, 0, 0)), distance: 300,
            pivot: SIMD3(50, 50, 20))

        guard let offscreen = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        func offscreenRender(silhouettes: Bool) throws -> [UInt8] {
            var options = HeightfieldScene.options(width: 256, height: 256, camera: camera)
            options.enableSilhouettes = silhouettes
            options.silhouetteThickness = 2
            options.silhouetteIntensity = 1
            return HeightfieldScene.pixels(
                try #require(offscreen.render(bodies: [body], options: options))
            ).pixels
        }
        func liveRender(silhouettes: Bool) throws -> [UInt8] {
            var config = ViewportConfiguration()
            config.initialCameraState = camera
            config.backgroundColor = HeightfieldScene.background
            config.showViewCube = false
            config.msaaSampleCount = 1
            config.enableSilhouettes = silhouettes
            config.silhouetteThickness = 2
            config.silhouetteIntensity = 1
            let controller = ViewportController(configuration: config)
            controller.displayMode = .shaded
            var lighting = LightingConfiguration.threePoint
            lighting.shadowsEnabled = false
            lighting.enableSSAO = false
            controller.lightingConfiguration = lighting
            controller.showGrid = false
            controller.showAxes = false
            controller.enableTAA = false
            guard
                let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
            else {
                Issue.record("Metal device unavailable; skipping")
                throw HeightfieldPickRig.Unavailable()
            }
            return try #require(
                renderer.renderHeadlessBGRA(
                    width: 256, height: 256, backgroundColor: HeightfieldScene.background))
        }
        for (name, render) in [
            ("offscreen", offscreenRender), ("live", liveRender),
        ] {
            let plain = try render(false)
            let outlined = try render(true)
            var changed = 0
            for i in stride(from: 0, to: plain.count, by: 4)
            where plain[i] != outlined[i] || plain[i + 1] != outlined[i + 1]
                || plain[i + 2] != outlined[i + 2]
            {
                changed += 1
            }
            print("SILHOUETTE \(name): \(changed) pixels changed")
            #expect(changed > 100, "\(name): the silhouette pass drew nothing for the field")
        }
    }
}
