// MeshletSubdivisionTests.swift
// OCCTSwiftViewport Tests
//
// PN-triangle subdivision on the mesh-shader path (issue #175). At `.maximum` on an Apple9 GPU the
// meshlet pipeline used to draw the input triangles unrefined, so a low-poly body looked faceted
// next to `.enhanced`, and `tessellationMaxFactor`, `adaptiveTessellation` and
// `uniformTessellationFactor` did nothing for it. The mesh stage now evaluates the same PN patch
// as the hardware tessellator on a barycentric grid, from the same per-frame factors.
//
// These tests pin what that must do:
//  - `.maximum` rounds a faceted body and agrees with `.enhanced` (pixel-identical when both use
//    the same even uniform factor, where the two grids coincide);
//  - the factor settings now act on meshlets;
//  - neighbouring triangles subdivided at different levels meet without cracks;
//  - every pass draws the same surface: shadow map, SSAO / silhouette depth, selection outline
//    and highlight follow the subdivided surface, so no shadow acne, ring gap or lost highlight.
//
// Mesh shaders need an Apple9 GPU; on any other device these tests return without checking. Run
// them under the Metal API validation layer too:
//
//     MTL_DEBUG_LAYER=1 swift test --filter MeshletSubdivisionTests

import Foundation
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Meshlet PN subdivision (#175)")
struct MeshletSubdivisionTests {

    static var supportsMeshShaders: Bool {
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false
    }

    // MARK: - Scenes and measurements

    /// A coarse sphere seen along its pole axis: a 14-gon outline until PN triangles round it.
    static func coarseSphere(color: SIMD4<Float> = SIMD4(0.9, 0.2, 0.2, 1)) -> ViewportBody {
        ViewportBody.sphere(
            id: "ball", radius: 3, segments: 14, rings: 10, color: color, up: .z)
    }

    static func options(
        _ quality: RenderingQuality, mode: DisplayMode = .unlit, adaptive: Bool = true,
        uniform: UniformTessellationFactor = .loadAdaptive(), maxFactor: Int = 16
    ) -> OffscreenRenderOptions {
        var options = ParityRender.options(displayMode: mode)
        options.renderingQuality = quality
        options.adaptiveTessellation = adaptive
        options.uniformTessellationFactor = uniform
        options.tessellationMaxFactor = maxFactor
        return options
    }

    /// How two same-size BGRA frames differ.
    struct Difference: CustomStringConvertible {
        /// Mean over pixels of the largest channel delta.
        var mean = 0.0
        /// Fraction of pixels whose largest channel delta exceeds 16 levels.
        var fractionOver16 = 0.0
        var description: String { "mean \(mean), \(fractionOver16 * 100)% over 16 levels" }
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Difference {
        precondition(a.count == b.count)
        var sum = 0
        var over = 0
        let count = a.count / 4
        for p in stride(from: 0, to: a.count, by: 4) {
            let delta = (0..<3).map { abs(Int(a[p + $0]) - Int(b[p + $0])) }.max() ?? 0
            sum += delta
            if delta > 16 { over += 1 }
        }
        return Difference(
            mean: Double(sum) / Double(count), fractionOver16: Double(over) / Double(count))
    }

    /// Pixels covered by the red sphere.
    static func coverage(_ frame: (pixels: [UInt8], width: Int, height: Int)) -> Int {
        ParityRender.count(frame.pixels, width: frame.width, height: frame.height) {
            $0.x > 120 && $0.y < 100
        }
    }

    // MARK: - Rounds like .enhanced

    @Test("A faceted body is rounded at .maximum, as at .enhanced and unlike .standard")
    func roundsTheSilhouette() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        let standard = try ParityRender.render(
            [sphere], Self.options(.standard), renderer: renderer)
        let maximum = try ParityRender.render(
            [sphere], Self.options(.maximum), renderer: renderer)
        let enhanced = try ParityRender.render(
            [sphere], Self.options(.enhanced), renderer: renderer)
        #expect(renderer.surfacePaths(for: Self.options(.maximum)).meshShaders)

        // The inscribed 14-gon covers ~97% of the circle; PN triangles bulge it outwards.
        let flatArea = Self.coverage(standard)
        let roundedArea = Self.coverage(maximum)
        #expect(flatArea > 1000)
        #expect(
            roundedArea > flatArea + flatArea / 100,
            "maximum covers \(roundedArea) px, the flat mesh \(flatArea) px")
        // ... and the area is what the hardware tessellator gets.
        #expect(
            abs(roundedArea - Self.coverage(enhanced)) <= max(roundedArea / 200, 4),
            "maximum \(roundedArea) px vs enhanced \(Self.coverage(enhanced)) px")
    }

    @Test(
        "With one even uniform factor the mesh path draws exactly the tessellated surface",
        arguments: [DisplayMode.unlit, .shaded], [4, 8, 16])
    func matchesEnhancedAtUniformFactor(mode: DisplayMode, factor: Int) throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        // With every factor equal and even, the tessellator's grid and the mesh stage's coincide,
        // so the two paths evaluate the same patch at the same points.
        let sphere = Self.coarseSphere()
        let uniform = UniformTessellationFactor.fixed(factor)
        let enhanced = try ParityRender.render(
            [sphere], Self.options(.enhanced, mode: mode, adaptive: false, uniform: uniform),
            renderer: renderer)
        let maximum = try ParityRender.render(
            [sphere], Self.options(.maximum, mode: mode, adaptive: false, uniform: uniform),
            renderer: renderer)
        let difference = Self.difference(enhanced.pixels, maximum.pixels)
        #expect(difference.mean < 0.1, "\(mode) factor \(factor): \(difference)")
        #expect(difference.fractionOver16 < 0.001, "\(mode) factor \(factor): \(difference)")
    }

    @Test("With adaptive factors .maximum agrees with .enhanced to within a pixel's coverage")
    func matchesEnhancedAdaptively() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        // The hardware path rounds a factor up to the next even number and morphs the vertices
        // in; the mesh stage rounds up to an integer, so the two sample the same surface a little
        // differently.
        let sphere = Self.coarseSphere()
        for mode in [DisplayMode.unlit, .shaded] {
            let enhanced = try ParityRender.render(
                [sphere], Self.options(.enhanced, mode: mode), renderer: renderer)
            let maximum = try ParityRender.render(
                [sphere], Self.options(.maximum, mode: mode), renderer: renderer)
            let difference = Self.difference(enhanced.pixels, maximum.pixels)
            #expect(difference.mean < 0.5, "\(mode): \(difference)")
            #expect(difference.fractionOver16 < 0.005, "\(mode): \(difference)")
        }
    }

    // MARK: - The factor settings act on meshlets

    @Test(
        "tessellationMaxFactor, adaptiveTessellation and uniformTessellationFactor reach meshlets")
    func factorSettingsReachMeshlets() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        func area(_ options: OffscreenRenderOptions) throws -> Int {
            Self.coverage(try ParityRender.render([sphere], options, renderer: renderer))
        }
        let coarse = try area(
            Self.options(.maximum, adaptive: false, uniform: .fixed(2)))
        let fine = try area(Self.options(.maximum, adaptive: false, uniform: .fixed(8)))
        // A finer grid follows the bulge better: its outline encloses more of the circle.
        #expect(fine > coarse, "factor 8 covers \(fine) px, factor 2 \(coarse) px")

        // The adaptive maximum caps every triangle's factor.
        let capped = try area(Self.options(.maximum, adaptive: true, maxFactor: 2))
        let uncapped = try area(Self.options(.maximum, adaptive: true, maxFactor: 16))
        #expect(uncapped > capped, "max 16 covers \(uncapped) px, max 2 \(capped) px")
        #expect(capped == coarse, "max factor 2 should equal the uniform factor 2")

        // Factors above the mesh stage's cap draw as the cap, with no overflow of the output.
        let beyond = try area(
            Self.options(.maximum, adaptive: false, uniform: .fixed(64), maxFactor: 64))
        let atCap = try area(
            Self.options(
                .maximum, adaptive: false, uniform: .fixed(kMeshletMaxSegments),
                maxFactor: kMeshletMaxSegments))
        #expect(beyond == atCap, "factor 64 covers \(beyond) px, the cap \(atCap) px")
    }

    @Test("A mesh limit of 16 segments holds one triangle in one threadgroup's output")
    func segmentCapFitsTheMeshOutput() {
        let m = kMeshletMaxSegments
        #expect((m + 1) * (m + 2) / 2 <= 256, "vertices of one triangle at the cap")
        #expect(m * m <= 512, "primitives of one triangle at the cap")
        #expect(kMeshletMaxSegments <= TessellationManager.clampedMaxFactor(64))
    }

    @Test("Meshlets are built together with the PN patches they subdivide from")
    func meshletsCarryPatches() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        _ = try ParityRender.render([sphere], Self.options(.maximum), renderer: renderer)
        let buffers = renderer.refinementBuffers(forBodyID: sphere.id)
        #expect(buffers.meshlets)
        #expect(buffers.tessellation)
    }

    // MARK: - No cracks

    /// Mask pixels left empty inside a sphere whose triangles are subdivided at wildly different
    /// levels.
    ///
    /// Adaptive factors keep a triangle's segments a few pixels long, so a mismatch between two
    /// neighbours is sub-pixel and no ordinary render shows it. This drives the mesh stage
    /// directly instead: it writes each edge a factor from a hash of its end positions, so the two
    /// triangles that share an edge agree on it, as the factor kernel guarantees, while a
    /// triangle's grid is as fine as its finest edge (1 to 16 segments next to each other). The
    /// selection-mask pipeline marks every pixel a triangle covers, so an empty pixel inside the
    /// disc is a crack or a missing triangle.
    ///
    /// - Returns: The number of empty pixels, or `nil` when the render could not run.
    static func emptyPixelsInside(
        sphere: ViewportBody, edgeFactor: (UInt32) -> Float16
    ) -> Int? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = RendererSharedSetup.loadLibrary(device: device),
            let queue = device.makeCommandQueue(),
            let manager = TessellationManager(device: device, library: library),
            let pipeline = RendererSharedSetup.makeMeshShaderSelectionMaskPipelineState(
                device: device, library: library),
            let vertexBuffer = device.makeBuffer(
                bytes: sphere.vertexData, length: sphere.vertexData.count * 4,
                options: .storageModeShared),
            let indexBuffer = device.makeBuffer(
                bytes: sphere.indices, length: sphere.indices.count * 4,
                options: .storageModeShared),
            var meshlets = MeshletBuilder.build(
                vertexData: sphere.vertexData, indices: sphere.indices, device: device)
        else { return nil }
        let triangles = sphere.indices.count / 3
        guard
            let patches = manager.buildPatches(
                vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, triangleCount: triangles,
                creaseAngle: .pi, commandQueue: queue)
        else { return nil }
        meshlets.tessellation = patches

        // One factor per undirected edge, keyed by the end positions so triangles that meet at a
        // duplicated vertex (a seam, a pole) still agree.
        func position(_ vertex: UInt32) -> SIMD3<Float> {
            let i = Int(vertex) * 6
            return SIMD3(sphere.vertexData[i], sphere.vertexData[i + 1], sphere.vertexData[i + 2])
        }
        func factor(_ a: UInt32, _ b: UInt32) -> Float16 {
            var pa = position(a)
            var pb = position(b)
            if (pb.x, pb.y, pb.z) < (pa.x, pa.y, pa.z) { swap(&pa, &pb) }
            var hash: UInt32 = 2_166_136_261
            for v in [pa.x, pa.y, pa.z, pb.x, pb.y, pb.z] {
                hash = (hash ^ UInt32((v * 1000).rounded().magnitude)) &* 16_777_619
                hash ^= hash >> 13
            }
            return edgeFactor(hash)
        }
        let factors = patches.tessFactorBuffer.contents().bindMemory(
            to: Float16.self, capacity: triangles * 4)
        for t in 0..<triangles {
            let v0 = sphere.indices[t * 3]
            let v1 = sphere.indices[t * 3 + 1]
            let v2 = sphere.indices[t * 3 + 2]
            // Edge 0 joins vertices 1 and 2, edge 1 vertices 0 and 2, edge 2 vertices 0 and 1.
            factors[t * 4] = factor(v1, v2)
            factors[t * 4 + 1] = factor(v0, v2)
            factors[t * 4 + 2] = factor(v0, v1)
            factors[t * 4 + 3] = 1
        }

        let size = 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RendererSharedSetup.selectionMaskPixelFormat, width: size, height: size,
            mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let mask = device.makeTexture(descriptor: descriptor),
            let commands = queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        // Orthographic: x and y from [-5, 5] to the target, z from [-10, 10] into [0, 1].
        var viewProjection = simd_float4x4(diagonal: SIMD4(0.2, 0.2, 0.05, 1))
        viewProjection.columns.3.z = 0.5
        var uniforms = Uniforms(
            viewProjection: viewProjection, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: true, viewportSize: SIMD2(Float(size), Float(size)))
        var code: UInt32 = 1
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&code, length: MemoryLayout<UInt32>.size, index: 2)
        RendererSharedSetup.encodeMeshletDraw(
            encoder: encoder, pipeline: pipeline, meshlets: meshlets, uniforms: &uniforms)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size)
        mask.getBytes(
            &pixels, bytesPerRow: size, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        // The sphere's disc: radius 3 of 5 half-widths. Stay inside its inscribed polygon.
        let centre = Float(size) / 2
        let radius = 3.0 / 5.0 * centre * 0.9
        var empty = 0
        var covered = 0
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - centre
                let dy = Float(y) + 0.5 - centre
                guard dx * dx + dy * dy < radius * radius else { continue }
                if pixels[y * size + x] == 0 { empty += 1 } else { covered += 1 }
            }
        }
        return covered > 5000 ? empty : nil
    }

    @Test("Triangles subdivided at mismatched levels meet without cracks or lost triangles")
    func noCracksBetweenMismatchedLevels() {
        guard Self.supportsMeshShaders else { return }
        let sphere = Self.coarseSphere()
        // 1 to 16 segments on neighbouring edges, odd counts, a uniform control, and every factor
        // at the cap, which puts each triangle of a meshlet in its own chunk.
        let patterns: [(String, (UInt32) -> Float16)] = [
            ("mixed", { [1, 2, 3, 5, 8, 13, 16][Int($0 % 7)] }),
            ("1 or 16", { $0 % 2 == 0 ? 1 : 16 }),
            ("odd", { [1, 3, 5, 7][Int($0 % 4)] }),
            ("uniform 4", { _ in 4 }),
            ("all 16", { _ in 16 }),
        ]
        for (name, factor) in patterns {
            guard let empty = Self.emptyPixelsInside(sphere: sphere, edgeFactor: factor) else {
                Issue.record("\(name): the mesh-stage render did not run")
                continue
            }
            #expect(empty == 0, "\(name): \(empty) pixels inside the sphere were never drawn")
        }
    }

    // MARK: - Every pass draws the same surface

    @Test("The shadow map is cast by the subdivided surface, as at .enhanced")
    func shadowMapFollowsTheSubdividedSurface() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let bodies = [
            Self.coarseSphere(),
            ParityRender.quad(
                id: "wall", x0: -8, y0: -8, x1: 8, y1: 8, z: -4, color: SIMD4(0.8, 0.8, 0.8, 1)),
        ]
        var lighting = ParityRender.plainLighting
        lighting.shadowsEnabled = true
        lighting.shadowIntensity = 0.8
        lighting.keyLight.direction = simd_normalize(SIMD3<Float>(-0.5, -0.4, -1))
        func render(_ quality: RenderingQuality) throws -> [UInt8] {
            var options = Self.options(
                quality, mode: .shaded, adaptive: false, uniform: .fixed(8))
            options.lightingConfiguration = lighting
            return try ParityRender.render(bodies, options, renderer: renderer).pixels
        }
        let maximum = try render(.maximum)
        let enhanced = try render(.enhanced)
        let flat = try render(.standard)
        let difference = Self.difference(enhanced, maximum)
        #expect(difference.mean < 0.12, "maximum vs enhanced: \(difference)")
        #expect(difference.fractionOver16 < 0.002, "maximum vs enhanced: \(difference)")
        // The comparison is only meaningful if the shadow and the rounding show up at all.
        #expect(Self.difference(flat, maximum).mean > difference.mean)
    }

    @Test("A translucent body composites far wall then near wall, as at .enhanced")
    func translucentBodyKeepsTheInputWinding() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        // The translucent pass draws the far-facing triangles with one cull mode and then the
        // camera-facing ones with the other, so a sub-triangle wound against its input triangle
        // composites in the wrong order.
        let glass = Self.coarseSphere(color: SIMD4(0.9, 0.2, 0.2, 0.5))
        func render(_ quality: RenderingQuality) throws -> [UInt8] {
            let options = Self.options(
                quality, mode: .shaded, adaptive: false, uniform: .fixed(8))
            return try ParityRender.render([glass], options, renderer: renderer).pixels
        }
        let difference = Self.difference(try render(.enhanced), try render(.maximum))
        #expect(difference.mean < 0.2, "maximum vs enhanced: \(difference)")
        #expect(difference.fractionOver16 < 0.002, "maximum vs enhanced: \(difference)")
    }

    @Test("The depth prepass the silhouettes read follows the subdivided surface")
    func depthPrepassFollowsTheSubdividedSurface() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        func render(_ quality: RenderingQuality) throws -> [UInt8] {
            var options = Self.options(
                quality, mode: .shaded, adaptive: false, uniform: .fixed(8))
            options.enableSilhouettes = true
            options.silhouetteThickness = 2
            options.silhouetteIntensity = 1
            var lighting = ParityRender.plainLighting
            lighting.enableSSAO = true
            options.lightingConfiguration = lighting
            return try ParityRender.render([sphere], options, renderer: renderer).pixels
        }
        let maximum = try render(.maximum)
        let enhanced = try render(.enhanced)
        let difference = Self.difference(enhanced, maximum)
        #expect(difference.mean < 0.2, "maximum vs enhanced: \(difference)")
        #expect(difference.fractionOver16 < 0.002, "maximum vs enhanced: \(difference)")
    }

    @Test("The selection ring hugs the subdivided silhouette")
    func selectionOutlineFollowsTheSubdividedSurface() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        let sphere = Self.coarseSphere()
        func render(_ quality: RenderingQuality) throws -> [UInt8] {
            var options = Self.options(
                quality, mode: .shaded, adaptive: false, uniform: .fixed(8))
            options.selectedBodyIDs = [sphere.id]
            options.selectionOutline = SelectionOutlineStyle(color: SIMD3(0, 1, 0), width: 3)
            return try ParityRender.render([sphere], options, renderer: renderer).pixels
        }
        let maximum = try render(.maximum)
        let enhanced = try render(.enhanced)
        func ring(_ pixels: [UInt8]) -> Int {
            ParityRender.count(pixels, width: 128, height: 128) { $0.y > 150 && $0.x < 100 }
        }
        #expect(ring(maximum) > 100, "test premise: the ring is drawn (\(ring(maximum)) px)")
        // The mask, the stencil and the shaded surface are the same subdivided triangles: the
        // ring neither overlaps the body nor leaves a gap, so it matches the tessellated frame.
        let difference = Self.difference(enhanced, maximum)
        #expect(difference.mean < 0.3, "maximum vs enhanced: \(difference)")
        #expect(difference.fractionOver16 < 0.004, "maximum vs enhanced: \(difference)")
        #expect(abs(ring(maximum) - ring(enhanced)) <= max(ring(enhanced) / 20, 4))
    }

    @Test("Per-triangle highlights land on the subdivided surface they style")
    func highlightFollowsTheSubdividedSurface() throws {
        guard Self.supportsMeshShaders else { return }
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable")
            return
        }
        var sphere = Self.coarseSphere(color: SIMD4(0.3, 0.3, 0.9, 1))
        let red = TriangleStyle(color: SIMD4(1, 0, 0, 1))
        sphere.triangleStyles = [TriangleStyle](repeating: red, count: sphere.indices.count / 3)
        var options = Self.options(.maximum, mode: .shaded, adaptive: false, uniform: .fixed(8))
        let frame = try ParityRender.render([sphere], options, renderer: renderer)
        // Fully highlighted: no pixel of the body may still show its blue base colour. The
        // highlight is drawn from the same subdivided triangles as the surface, so none of them
        // loses its depth test to the PN bulge.
        let blue = ParityRender.count(frame.pixels, width: frame.width, height: frame.height) {
            $0.z > 120 && $0.x < 100
        }
        let highlighted = ParityRender.count(
            frame.pixels, width: frame.width, height: frame.height
        ) { $0.x > 200 && $0.y < 60 && $0.z < 60 }
        #expect(highlighted > 1000, "test premise: the highlight is drawn (\(highlighted) px)")
        #expect(blue == 0, "\(blue) pixels lost the highlight")
        // And on the rounded silhouette, not the flat polygon under it.
        options.renderingQuality = .standard
        let flat = try ParityRender.render([sphere], options, renderer: renderer)
        let flatHighlighted = ParityRender.count(
            flat.pixels, width: flat.width, height: flat.height
        ) { $0.x > 200 && $0.y < 60 && $0.z < 60 }
        #expect(highlighted > flatHighlighted + flatHighlighted / 100)
    }

    // MARK: - Live renderer

    @Test("The live renderer subdivides meshlets and matches the offscreen frame")
    func liveRendererSubdivides() throws {
        guard Self.supportsMeshShaders else { return }
        let sphere = Self.coarseSphere()
        var config = ViewportConfiguration(
            initialCameraState: ParityRender.frontCamera, displayMode: .unlit,
            lightingConfiguration: ParityRender.plainLighting, showGrid: false,
            backgroundColor: SIMD4(0, 0, 0, 1), enableSilhouettes: false)
        config.showAxes = false
        config.renderingQuality = .maximum
        config.tessellationMaxFactor = 16
        config.adaptiveTessellation = false
        config.uniformTessellationFactor = .fixed(8)
        let controller = ViewportController(configuration: config)
        guard
            let live = ViewportRenderer(controller: controller, bodies: .constant([sphere])),
            let livePixels = live.renderHeadlessBGRA(
                width: 128, height: 128, backgroundColor: config.backgroundColor, frameCount: 2),
            let renderer = OffscreenRenderer()
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(live.meshShadersEnabled)
        let flat = try ParityRender.render(
            [sphere], Self.options(.standard), renderer: renderer)
        let liveArea = Self.coverage((livePixels, 128, 128))
        let flatArea = Self.coverage(flat)
        #expect(
            liveArea > flatArea + flatArea / 100,
            "live maximum covers \(liveArea) px, the flat mesh \(flatArea) px")
    }
}
