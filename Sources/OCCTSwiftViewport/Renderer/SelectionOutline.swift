// SelectionOutline.swift
// OCCTSwiftViewport
//
// The selection outline shared by ViewportRenderer and OffscreenRenderer (#209): a single-sample
// selection-mask pass before the main pass, then a screen-space dilation of that mask drawn in
// the main pass. Also builds the preserve-invariance shader library the tessellated pipelines use.

import Foundation
@preconcurrency import Metal
import simd

/// One body the selection-mask pass rasterises.
struct SelectionMaskDraw {
    /// Mask code: `SelectionMaskCode.selected` or `.hovered`.
    let code: UInt32
    let modelMatrix: simd_float4x4
    let vertexBuffer: MTLBuffer
    /// Direct-mesh normals (position@0 / normal@2), or `nil` for an interleaved body.
    let normalBuffer: MTLBuffer?
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// The PN patches the body's surface is drawn from, or `nil` for its plain mesh.
    let patches: TessellationBuffers?
    /// World-space bounds, for the outline's scissor rectangle; `nil` means unknown.
    let worldBounds: BoundingBox?

    /// World-space bounds for `worldBounds`: `local` moved by `transform`, grown by a quarter of
    /// its diagonal when the surface is tessellated, since PN patches bulge past the flat mesh.
    nonisolated static func worldBounds(
        local: BoundingBox?, transform: simd_float4x4, tessellated: Bool
    ) -> BoundingBox? {
        guard let world = local?.transformed(by: transform) else { return nil }
        guard tessellated else { return world }
        let pad = SIMD3<Float>(repeating: world.diagonalLength * 0.25)
        return BoundingBox(min: world.min - pad, max: world.max + pad)
    }
}

/// The values `selection_mask_fragment` writes into the selection mask.
enum SelectionMaskCode {
    static let selected: UInt32 = 1
    static let hovered: UInt32 = 2
}

/// The selection-mask pipelines (single sample, `.r8Uint` colour, no depth).
struct SelectionMaskPipelines {
    let plain: MTLRenderPipelineState
    let direct: MTLRenderPipelineState
    /// `nil` when tessellation is unavailable; tessellated bodies then mask their plain mesh.
    var tessellated: MTLRenderPipelineState?
}

extension RendererSharedSetup {

    /// Pixel format of the selection mask.
    static let selectionMaskPixelFormat: MTLPixelFormat = .r8Uint

    /// Largest outline width, in drawable pixels, the outline pass searches.
    ///
    /// The dilation reads every mask texel within the width, so its cost grows with the square
    /// of the width; wider styles are drawn this wide.
    static let maxSelectionOutlineWidth: Float = 32

    // MARK: Library

    /// Shader libraries compiled with `preserveInvariance`, one per device.
    @MainActor private static var invariantLibraries: [UInt64: MTLLibrary] = [:]

    /// The renderers' shader library: the build-time `default.metallib`, else the bundled source
    /// compiled at run time.
    static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        if let compiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            return compiled
        }
        guard let source = shaderSource() else { return nil }
        return try? device.makeLibrary(source: source, options: nil)
    }

    /// `Shaders.metal` as shipped in the resource bundle (Package.swift copies it next to the
    /// `default.metallib` that `ShadersPrecompiled.metal` builds from it).
    static func shaderSource() -> String? {
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// The shader library compiled with `MTLCompileOptions.preserveInvariance`, which the
    /// tessellated pipelines are built from (#209).
    ///
    /// The tessellated shaded, shadow, depth, pick, highlight and mask passes evaluate the same
    /// patch through different post-tessellation vertex functions and rely on bit-identical
    /// positions (the `.lessEqual` highlight's depth tie with the shaded surface). Metal
    /// guarantees that only for `[[invariant]]` positions compiled with preserve-invariance, an
    /// option the package's build-time `default.metallib` cannot carry, so this compiles the
    /// bundled source at run time. The first compile on a device takes about a second; Metal
    /// caches it across launches, and this caches it for the process. Only renderers that build
    /// tessellation pipelines (`RenderingQuality.enhanced` or `.maximum`) ask for it.
    ///
    /// - Returns: The library, or `nil` if the source is missing or fails to compile (the
    ///   caller then falls back to its default library).
    @MainActor
    static func invariantLibrary(device: MTLDevice) -> MTLLibrary? {
        if let cached = invariantLibraries[device.registryID] { return cached }
        guard let source = shaderSource() else { return nil }
        let options = MTLCompileOptions()
        options.preserveInvariance = true
        guard let library = try? device.makeLibrary(source: source, options: options) else {
            return nil
        }
        invariantLibraries[device.registryID] = library
        return library
    }

    // MARK: Pipelines

    /// Builds the selection-mask pipelines; the tessellated one only when `maxTessellationFactor`
    /// is given.
    static func makeSelectionMaskPipelines(
        device: MTLDevice, library: MTLLibrary, tessellationLibrary: MTLLibrary? = nil,
        maxTessellationFactor: Int? = nil, label: String = "selection_mask"
    ) -> SelectionMaskPipelines? {
        guard
            let plain = makePipelineState(
                device: device, label: label, library: library,
                vertexFunction: "depth_only_vertex", fragmentFunction: "selection_mask_fragment",
                colorPixelFormat: selectionMaskPixelFormat, depthPixelFormat: .invalid,
                vertexDescriptor: interleavedVertexDescriptor()),
            let direct = makePipelineState(
                device: device, label: label + "_direct", library: library,
                vertexFunction: "depth_only_vertex", fragmentFunction: "selection_mask_fragment",
                colorPixelFormat: selectionMaskPixelFormat, depthPixelFormat: .invalid,
                vertexDescriptor: directMeshVertexDescriptor())
        else { return nil }
        var pipelines = SelectionMaskPipelines(plain: plain, direct: direct)
        if let maxTessellationFactor {
            pipelines.tessellated = try? makeTessellatedPipelineState(
                device: device, library: tessellationLibrary ?? library,
                label: label + "_tessellated", vertexFunction: "tessellated_depth_vertex",
                fragmentFunction: "selection_mask_fragment",
                colorPixelFormat: selectionMaskPixelFormat, depthPixelFormat: .invalid,
                maxFactor: maxTessellationFactor)
        }
        return pipelines
    }

    /// The outline pipeline: a full-screen triangle that dilates the selection mask.
    ///
    /// It draws into the main pass; paired with `makeStencilTestState(device:)` it lands only where the stencil is not 1.
    static func makeSelectionOutlinePipelineState(
        device: MTLDevice, library: MTLLibrary, sampleCount: Int, depthFormat: MTLPixelFormat,
        label: String? = nil
    ) -> MTLRenderPipelineState? {
        makePipelineState(
            device: device, label: label, library: library,
            vertexFunction: "fullscreen_vertex", fragmentFunction: "selection_outline_fragment",
            colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat, sampleCount: sampleCount, blending: .sourceOver)
    }

    /// A drawable-sized selection mask, reusing `existing` when it already fits.
    static func selectionMaskTexture(
        device: MTLDevice, width: Int, height: Int, reusing existing: MTLTexture?
    ) -> MTLTexture? {
        if let existing, existing.width == width, existing.height == height { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: selectionMaskPixelFormat, width: max(width, 1), height: max(height, 1),
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "selection_mask"
        return texture
    }

    // MARK: Encoding

    /// Encodes the selection-mask pass: clears `mask` and rasterises each draw's code into it,
    /// ignoring depth, so bodies hidden behind others are marked too (#177).
    ///
    /// Hovered bodies are drawn first, so a selected body wins where the two overlap.
    ///
    /// - Parameters:
    ///   - commandBuffer: The frame's command buffer, ahead of the main pass that reads `mask`.
    ///   - mask: The drawable-sized `.r8Uint` selection mask.
    ///   - draws: The selected and hovered bodies.
    ///   - pipelines: The selection-mask pipelines.
    ///   - uniforms: The frame's scene uniforms (for the view-projection and clip planes); each
    ///     draw sets its own model matrix.
    static func encodeSelectionMaskPass(
        commandBuffer: MTLCommandBuffer, mask: MTLTexture, draws: [SelectionMaskDraw],
        pipelines: SelectionMaskPipelines, uniforms: Uniforms
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = mask
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "selection_mask"
        let ordered =
            draws.filter { $0.code == SelectionMaskCode.hovered }
            + draws.filter { $0.code != SelectionMaskCode.hovered }
        for draw in ordered {
            var bodyUniforms = uniforms
            bodyUniforms.modelMatrix = draw.modelMatrix
            var code = draw.code
            encoder.setFragmentBytes(&bodyUniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.setFragmentBytes(&code, length: MemoryLayout<UInt32>.size, index: 2)
            if let patches = draw.patches, let tessellated = pipelines.tessellated {
                encodeTessellatedDraw(
                    encoder: encoder, pipeline: tessellated, tessellation: patches,
                    uniforms: &bodyUniforms)
                continue
            }
            encoder.setRenderPipelineState(
                draw.normalBuffer != nil ? pipelines.direct : pipelines.plain)
            encoder.setVertexBuffer(draw.vertexBuffer, offset: 0, index: 0)
            if let normals = draw.normalBuffer {
                encoder.setVertexBuffer(normals, offset: 0, index: 2)
            }
            encoder.setVertexBytes(&bodyUniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: draw.indexCount, indexType: .uint32,
                indexBuffer: draw.indexBuffer, indexBufferOffset: 0)
        }
        encoder.endEncoding()
    }

    /// The outline parameters for the two styles, with widths clamped to
    /// `0...maxSelectionOutlineWidth`.
    static func selectionOutlineParams(
        selected: SelectionOutlineStyle, hovered: SelectionOutlineStyle
    ) -> SelectionOutlineParamsSwift {
        func clamped(_ width: Float) -> Float {
            width.isFinite ? min(max(width, 0), maxSelectionOutlineWidth) : 0
        }
        return SelectionOutlineParamsSwift(
            selected: SIMD4(selected.color, clamped(selected.width)),
            hovered: SIMD4(hovered.color, clamped(hovered.width)))
    }

    /// Draws the outline into the main pass from the dilated `mask`.
    ///
    /// It lands only where the stencil is not 1, within `scissor`, and restores the full
    /// `targetSize` scissor after. The caller sets the stencil-test depth state and reference
    /// value.
    static func encodeSelectionOutline(
        encoder: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, mask: MTLTexture,
        params: SelectionOutlineParamsSwift, scissor: MTLScissorRect, targetSize: SIMD2<Int>
    ) {
        var params = params
        encoder.setScissorRect(scissor)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(mask, index: 0)
        encoder.setFragmentBytes(
            &params, length: MemoryLayout<SelectionOutlineParamsSwift>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setScissorRect(
            MTLScissorRect(x: 0, y: 0, width: targetSize.x, height: targetSize.y))
    }

    /// The pixel rectangle the outline can touch: the drawn bodies' projected bounds grown by
    /// `margin` pixels and clipped to the target.
    ///
    /// - Parameters:
    ///   - bounds: World-space bounds of the outlined bodies; a `nil` entry (unknown bounds) or a
    ///     box reaching behind the camera makes the whole target the rectangle.
    ///   - viewProjection: The frame's view-projection matrix.
    ///   - size: Target size in pixels.
    ///   - margin: The outline width, in pixels.
    /// - Returns: The rectangle, or `nil` when no outline pixel can be on screen.
    nonisolated static func selectionOutlineScissor(
        bounds: [BoundingBox?], viewProjection: simd_float4x4, size: SIMD2<Int>, margin: Float
    ) -> MTLScissorRect? {
        guard size.x > 0, size.y > 0, !bounds.isEmpty else { return nil }
        let full = MTLScissorRect(x: 0, y: 0, width: size.x, height: size.y)
        var lo = SIMD2<Float>(repeating: .infinity)
        var hi = SIMD2<Float>(repeating: -.infinity)
        for box in bounds {
            guard let box else { return full }
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    i & 1 == 0 ? box.min.x : box.max.x,
                    i & 2 == 0 ? box.min.y : box.max.y,
                    i & 4 == 0 ? box.min.z : box.max.z)
                let clip = viewProjection * SIMD4(corner, 1)
                guard clip.w > 1e-6 else { return full }
                let ndc = SIMD2(clip.x, clip.y) / clip.w
                // NDC y is up, pixel rows run down.
                let pixel = SIMD2(
                    (ndc.x * 0.5 + 0.5) * Float(size.x), (0.5 - ndc.y * 0.5) * Float(size.y))
                lo = simd_min(lo, pixel)
                hi = simd_max(hi, pixel)
            }
        }
        let pad = margin.isFinite ? max(margin, 0) + 2 : 2
        // Clamp in floating point first: a corner near the eye plane projects arbitrarily far.
        let limit = SIMD2<Float>(Float(size.x), Float(size.y))
        let low = simd_clamp(lo - pad, .zero, limit).rounded(.down)
        let high = simd_clamp(hi + pad, .zero, limit).rounded(.up)
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else { return full }
        let x0 = Int(low.x)
        let y0 = Int(low.y)
        let x1 = Int(high.x)
        let y1 = Int(high.y)
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
