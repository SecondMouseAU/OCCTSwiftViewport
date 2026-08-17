// ViewportRendererHeadless.swift
// OCCTSwiftViewport
//
// Off-screen render targets that let ViewportRenderer's own draw path run without an MTKView.

import CoreGraphics
import Foundation
@preconcurrency import Metal

// MARK: - HeadlessRenderTargets

/// Renderer-owned off-screen attachments that stand in for a live drawable.
///
/// Built to the specification `MetalViewRepresentable` configures on the live view — BGRA8 colour,
/// `depth32Float_stencil8` depth/stencil, matching sample count — so a frame encoded into them
/// binds the very same pipeline states the on-screen path uses.
@MainActor
final class HeadlessRenderTargets {

    private let device: MTLDevice

    /// Multisample colour attachment, or `resolveTexture` itself when `sampleCount` is 1.
    private(set) var colorTexture: MTLTexture?

    /// Combined depth/stencil attachment, matching the live view's `depth32Float_stencil8`.
    private(set) var depthStencilTexture: MTLTexture?

    /// Single-sample texture the frame's final composite lands in — the drawable stand-in.
    private(set) var resolveTexture: MTLTexture?

    private(set) var width = 0
    private(set) var height = 0
    private(set) var sampleCount = 0

    init(device: MTLDevice) {
        self.device = device
    }

    /// Allocates, or reuses, attachments for the given size and sample count.
    ///
    /// - Returns: `true` when every attachment is available.
    func ensure(width: Int, height: Int, sampleCount: Int) -> Bool {
        guard width > 0, height > 0, sampleCount > 0 else { return false }
        if width == self.width, height == self.height, sampleCount == self.sampleCount,
            colorTexture != nil, depthStencilTexture != nil, resolveTexture != nil
        {
            return true
        }

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .private
        let resolve = device.makeTexture(descriptor: resolveDesc)

        // With MSAA the main pass targets a multisample attachment and resolves into `resolve`;
        // at 1x sample the drawable itself is the render target, so the two coincide.
        let color: MTLTexture?
        if sampleCount > 1 {
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            colorDesc.textureType = .type2DMultisample
            colorDesc.sampleCount = sampleCount
            colorDesc.usage = [.renderTarget]
            colorDesc.storageMode = .private
            color = device.makeTexture(descriptor: colorDesc)
        } else {
            color = resolve
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        if sampleCount > 1 {
            depthDesc.textureType = .type2DMultisample
            depthDesc.sampleCount = sampleCount
        }
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        let depth = device.makeTexture(descriptor: depthDesc)

        guard let color, let depth, let resolve else { return false }
        colorTexture = color
        depthStencilTexture = depth
        resolveTexture = resolve
        self.width = width
        self.height = height
        self.sampleCount = sampleCount
        return true
    }

    /// Builds the main-pass descriptor an `MTKView` would hand its delegate for these attachments.
    ///
    /// A fresh descriptor is returned per call because the frame encoder mutates the one it is
    /// given (second colour attachment, SSAO/TAA resolve redirection).
    func makeMainPassDescriptor(clearColor: MTLClearColor) -> MTLRenderPassDescriptor? {
        guard let colorTexture, let depthStencilTexture, let resolveTexture else { return nil }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture = colorTexture
        desc.colorAttachments[0].loadAction = .clear
        desc.colorAttachments[0].clearColor = clearColor
        if sampleCount > 1 {
            desc.colorAttachments[0].resolveTexture = resolveTexture
            desc.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            desc.colorAttachments[0].storeAction = .store
        }
        desc.depthAttachment.texture = depthStencilTexture
        desc.depthAttachment.loadAction = .clear
        desc.depthAttachment.storeAction = .dontCare
        desc.depthAttachment.clearDepth = 1.0
        desc.stencilAttachment.texture = depthStencilTexture
        desc.stencilAttachment.loadAction = .clear
        desc.stencilAttachment.storeAction = .dontCare
        desc.stencilAttachment.clearStencil = 0
        return desc
    }
}

// MARK: - ViewportRenderer off-screen entry points

extension ViewportRenderer {

    /// Renders `frameCount` frames off-screen and returns the last one's BGRA8 pixels.
    ///
    /// Every pass `draw(in:)` runs — shadow map, skybox, grid, axes, opaque and transparent
    /// surfaces, arcs, point clouds, highlights, selection outline, overlays, the pick texture,
    /// TAA resolve and the SSAO/tone-map composite — runs here too, because both entry points call
    /// the same `encodeFrame(into:)`. Render more than one frame to warm up TAA history.
    ///
    /// - Returns: Row-major BGRA8 bytes, or `nil` if the targets or command buffers cannot be made.
    func renderHeadlessBGRA(
        width: Int,
        height: Int,
        backgroundColor: SIMD4<Float>,
        frameCount: Int = 1
    ) -> [UInt8]? {
        guard frameCount > 0 else { return nil }

        let targets = headlessTargets ?? HeadlessRenderTargets(device: metalDevice)
        headlessTargets = targets
        guard targets.ensure(width: width, height: height, sampleCount: pipelineSampleCount),
            let resolve = targets.resolveTexture
        else { return nil }

        let clearColor = MTLClearColor(
            red: Double(backgroundColor.x),
            green: Double(backgroundColor.y),
            blue: Double(backgroundColor.z),
            alpha: Double(backgroundColor.w)
        )

        for _ in 0..<frameCount {
            guard let passDescriptor = targets.makeMainPassDescriptor(clearColor: clearColor) else {
                return nil
            }
            encodeFrame(
                into: FrameRenderTargets(
                    mainPassDescriptor: passDescriptor,
                    finalColorTexture: resolve,
                    size: CGSize(width: width, height: height),
                    presentable: nil
                ))
        }

        return readBackBGRA(from: resolve, width: width, height: height)
    }

    /// Renders `frameCount` frames off-screen and returns the last one as a `CGImage`.
    func renderHeadless(
        width: Int,
        height: Int,
        backgroundColor: SIMD4<Float>,
        frameCount: Int = 1
    ) -> CGImage? {
        guard
            let pixels = renderHeadlessBGRA(
                width: width, height: height, backgroundColor: backgroundColor,
                frameCount: frameCount)
        else { return nil }
        return Self.makeImage(bgra: pixels, width: width, height: height)
    }

    /// Copies a private texture into host memory once the frames queued before it have completed.
    ///
    /// The blit is submitted on the renderer's own queue, so in-order execution guarantees the
    /// preceding frame command buffers finished before `waitUntilCompleted` returns.
    private func readBackBGRA(from texture: MTLTexture, width: Int, height: Int) -> [UInt8]? {
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        guard byteCount > 0,
            let buffer = metalDevice.makeBuffer(length: byteCount, options: .storageModeShared),
            let commandBuffer = renderCommandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }

        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let raw = buffer.contents().bindMemory(to: UInt8.self, capacity: byteCount)
        return Array(UnsafeBufferPointer(start: raw, count: byteCount))
    }

    /// Wraps row-major BGRA8 bytes in a `CGImage`.
    private static func makeImage(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
