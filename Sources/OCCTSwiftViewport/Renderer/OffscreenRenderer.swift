// OffscreenRenderer.swift
// OCCTSwiftViewport
//
// Headless Metal renderer that produces CGImage from ViewportBody arrays
// without requiring MTKView or a window.

import CoreGraphics
import ImageIO
@preconcurrency import Metal
import UniformTypeIdentifiers
import simd

/// Explicit orthographic projection bounds in world units.
///
/// When supplied to `OffscreenRenderOptions.explicitOrthoBounds`, the renderer
/// uses these exact bounds for the projection instead of fitting to scene extent
/// or deriving from `CameraState.orthographicScale`. This is required when the
/// output must be pixel-registered against an external reference (e.g. a drawing
/// view for SSIM reprojection diff).
public struct OrthoBounds: Sendable, Hashable, Codable {
    public var left: Float
    public var right: Float
    public var bottom: Float
    public var top: Float

    public init(left: Float, right: Float, bottom: Float, top: Float) {
        self.left = left
        self.right = right
        self.bottom = bottom
        self.top = top
    }
}

/// Configuration for an offscreen render.
public struct OffscreenRenderOptions: Sendable {
    public var width: Int
    public var height: Int
    public var cameraState: CameraState
    public var displayMode: DisplayMode
    public var lightingConfiguration: LightingConfiguration
    public var backgroundColor: SIMD4<Float>
    public var showGrid: Bool
    public var showAxes: Bool
    public var msaaSampleCount: Int

    /// Fundamental grid unit in world units, matching `ViewportConfiguration.gridBaseSpacing`.
    public var gridBaseSpacing: Float

    /// Subdivision factor between grid spacing levels, matching
    /// `ViewportConfiguration.gridSubdivisions`.
    public var gridSubdivisions: Int

    /// Optional explicit orthographic projection bounds (world units).
    ///
    /// When set, overrides `cameraState.projectionMatrix(...)` and forces
    /// orthographic projection with these exact bounds. Use for pixel-registered
    /// renders where the output frame must match a specific world-space region.
    public var explicitOrthoBounds: OrthoBounds?

    /// Optional screen-space pan offset in pixels, applied after projection.
    ///
    /// Positive x pans the image right, positive y pans it down (screen-space
    /// convention). Intended as a lightweight alternative to recomputing
    /// `cameraState.pivot` or `explicitOrthoBounds` for small registration nudges.
    public var pixelPan: SIMD2<Float>?

    /// Measurement annotations to overlay on the rendered image.
    ///
    /// After the Metal pass produces the base CGImage, each measurement is
    /// drawn on top via Core Graphics + Core Text using the same visual
    /// semantics as the interactive `MeasurementOverlay` SwiftUI Canvas.
    /// World-space anchors must already be resolved on the input
    /// `ViewportMeasurement` values; the headless path performs no topology
    /// lookups.
    public var measurements: [ViewportMeasurement]

    public init(
        width: Int = 1024,
        height: Int = 768,
        cameraState: CameraState = CameraState(),
        displayMode: DisplayMode = .shadedWithEdges,
        lightingConfiguration: LightingConfiguration = .threePoint,
        backgroundColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.95, 0.95, 1.0),
        showGrid: Bool = false,
        showAxes: Bool = false,
        msaaSampleCount: Int = 4,
        gridBaseSpacing: Float = 1.0,
        gridSubdivisions: Int = 10,
        explicitOrthoBounds: OrthoBounds? = nil,
        pixelPan: SIMD2<Float>? = nil,
        measurements: [ViewportMeasurement] = []
    ) {
        self.width = width
        self.height = height
        self.cameraState = cameraState
        self.displayMode = displayMode
        self.lightingConfiguration = lightingConfiguration
        self.backgroundColor = backgroundColor
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.msaaSampleCount = msaaSampleCount
        self.gridBaseSpacing = gridBaseSpacing
        self.gridSubdivisions = gridSubdivisions
        self.explicitOrthoBounds = explicitOrthoBounds
        self.pixelPan = pixelPan
        self.measurements = measurements
    }
}

/// Error type for offscreen rendering failures.
public enum OffscreenRenderError: Error, Sendable {
    case renderFailed
    case fileCreationFailed
    case writeFailed
}

// MARK: - OffscreenRenderer

/// Headless Metal renderer that renders [ViewportBody] to CGImage without MTKView.
@MainActor
public final class OffscreenRenderer: Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let shadedPipeline: MTLRenderPipelineState

    /// Direct-mesh shaded pipeline (Option A spike).
    ///
    /// Same shaders as `shadedPipeline`, but its vertex descriptor reads position from buffer 0 and
    /// normal from buffer 2 (de-interleaved), so bodies built via `ViewportBody.directMesh(...)`
    /// render without a CPU interleave.
    private let directMeshPipeline: MTLRenderPipelineState
    private let wireframePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let axisPipeline: MTLRenderPipelineState

    /// Visible point-cloud pipeline (issue #28).
    ///
    /// Mirrors the live renderer's `visiblePointPipeline`. Optional only because pipeline
    /// construction could fail on a degenerate device.
    private let visiblePointPipeline: MTLRenderPipelineState?
    private let shadowPipeline: MTLRenderPipelineState

    /// Direct-mesh shadow pipeline (Option A).
    ///
    /// `shadow_vertex` with the two-buffer descriptor (position@0 / normal@2) so direct-mesh bodies
    /// cast shadows in the headless path too.
    private let shadowDirectPipeline: MTLRenderPipelineState
    private let shadowMapManager: ShadowMapManager
    private let depthState: MTLDepthStencilState
    private let transparentDepthState: MTLDepthStencilState
    private let matcapTexture: MTLTexture
    private let axisVertexBuffer: MTLBuffer

    // Cached textures (recreated if size changes)
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0
    private var cachedSampleCount: Int = 0
    private var msaaColorTexture: MTLTexture?
    private var msaaDepthTexture: MTLTexture?
    private var resolveTexture: MTLTexture?

    // Body buffer cache
    private var bodyBufferCache: [String: BodyBuffersOffscreen] = [:]
    private var bodyGeneration: [String: UInt64] = [:]

    // MARK: - Init

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue

        let sampleCount = 4
        let depthFormat: MTLPixelFormat = .depth32Float_stencil8

        // Load shader library
        let library: MTLLibrary
        if let compiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            library = compiled
        } else if let metalURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
            let src = try? String(contentsOf: metalURL, encoding: .utf8),
            let fromSource = try? device.makeLibrary(source: src, options: nil)
        {
            library = fromSource
        } else {
            return nil
        }

        let vertexDesc = RendererSharedSetup.interleavedVertexDescriptor()
        let directVertexDesc = RendererSharedSetup.directMeshVertexDescriptor()

        guard
            let shadedPipeline = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        else { return nil }
        self.shadedPipeline = shadedPipeline

        guard
            let directMeshPipeline = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc)
        else { return nil }
        self.directMeshPipeline = directMeshPipeline

        guard
            let wireframePipeline = RendererSharedSetup.makeWireframePipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        else { return nil }
        self.wireframePipeline = wireframePipeline

        guard
            let gridPipeline = RendererSharedSetup.makeGridPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else { return nil }
        self.gridPipeline = gridPipeline

        guard
            let axisPipeline = RendererSharedSetup.makeAxisPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else { return nil }
        self.axisPipeline = axisPipeline

        self.visiblePointPipeline = RendererSharedSetup.makeVisiblePointPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, label: "offscreen_visible_point")

        guard
            let shadowPipeline = RendererSharedSetup.makeShadowPipelineState(
                device: device, library: library, vertexDescriptor: vertexDesc,
                label: "offscreen_shadow")
        else { return nil }
        self.shadowPipeline = shadowPipeline

        guard
            let shadowDirectPipeline = RendererSharedSetup.makeShadowPipelineState(
                device: device, library: library, vertexDescriptor: directVertexDesc,
                label: "offscreen_shadow_direct")
        else { return nil }
        self.shadowDirectPipeline = shadowDirectPipeline
        self.shadowMapManager = ShadowMapManager(device: device)

        guard
            let depthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .less, isDepthWriteEnabled: true)
        else { return nil }
        self.depthState = depthState

        // Transparent surface depth state (#53): test on, write off.
        guard
            let transparentDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .less, isDepthWriteEnabled: false)
        else { return nil }
        self.transparentDepthState = transparentDepthState

        guard let axisVB = RendererSharedSetup.makeAxisVertexBuffer(device: device) else {
            return nil
        }
        self.axisVertexBuffer = axisVB

        guard let matcap = RendererSharedSetup.makeMatcapTexture(device: device) else { return nil }
        self.matcapTexture = matcap
    }

    // MARK: - Public API

    /// Renders bodies to a CGImage.
    public func render(bodies: [ViewportBody], options: OffscreenRenderOptions = .init())
        -> CGImage?
    {
        let w = options.width
        let h = options.height
        let sampleCount = options.msaaSampleCount

        ensureTextures(width: w, height: h, sampleCount: sampleCount)
        guard let msaaColor = msaaColorTexture,
            let msaaDepth = msaaDepthTexture,
            let resolve = resolveTexture
        else { return nil }

        // Ensure buffers for all bodies
        for body in bodies where body.isVisible {
            ensureBuffers(for: body)
        }

        let cameraState = options.cameraState
        let aspectRatio = Float(w) / Float(h)
        let viewMatrix = cameraState.viewMatrix

        // Scene-adaptive clip planes (issue #57): fit near/far to the visible
        // geometry so depth precision isn't crushed by a fixed 0.01/10000 range.
        var sceneBounds: BoundingBox? = nil
        for body in bodies where body.isVisible && body.renderLayer == .geometry {
            guard let box = body.boundingBox?.transformed(by: body.transform) else { continue }
            sceneBounds = sceneBounds.map { $0.union(box) } ?? box
        }
        let clip = cameraState.clipPlanes(sceneBounds: sceneBounds)
        let nearClip: Float = clip.near
        let farClip: Float = clip.far

        let baseProjMatrix: simd_float4x4
        if let bounds = options.explicitOrthoBounds {
            baseProjMatrix = simd_float4x4.orthographic(
                left: bounds.left,
                right: bounds.right,
                bottom: bounds.bottom,
                top: bounds.top,
                near: nearClip,
                far: farClip
            )
        } else {
            baseProjMatrix = cameraState.projectionMatrix(
                aspectRatio: aspectRatio, near: nearClip, far: farClip)
        }

        let projMatrix: simd_float4x4
        if let pan = options.pixelPan, pan != .zero, w > 0, h > 0 {
            // Screen-space pixels → NDC translation. Screen y is down, NDC y is up.
            let ndcX = (2.0 * pan.x) / Float(w)
            let ndcY = (-2.0 * pan.y) / Float(h)
            var panMatrix = matrix_identity_float4x4
            panMatrix.columns.3 = SIMD4<Float>(ndcX, ndcY, 0, 1)
            projMatrix = panMatrix * baseProjMatrix
        } else {
            projMatrix = baseProjMatrix
        }

        let viewProjection = projMatrix * viewMatrix

        let lighting = options.lightingConfiguration

        // Shadow setup
        let shadowEnabled = lighting.shadowsEnabled
        let lightVP: simd_float4x4
        if shadowEnabled {
            lightVP = RendererSharedSetup.lightViewProjection(
                lightDirection: lighting.keyLight.direction,
                sceneBounds: RendererSharedSetup.sceneBounds(of: bodies, applyingTransforms: true)
            )
        } else {
            lightVP = matrix_identity_float4x4
        }
        let shadowParams = SIMD4<Float>(
            lighting.shadowBias, lighting.shadowIntensity, shadowEnabled ? 1.0 : 0.0, 1.0)
        let shadowParams2 = SIMD4<Float>(
            lighting.shadowLightSize, lighting.shadowSearchRadius, 0, 0)

        func makeUniforms() -> Uniforms {
            Uniforms(
                viewProjection: viewProjection,
                viewMatrix: viewMatrix,
                cameraPosition: cameraState.position,
                nearPlane: nearClip,
                farPlane: farClip,
                lighting: lighting,
                lightViewProjection: lightVP,
                shadowParams: shadowParams,
                shadowParams2: shadowParams2,
                unlit: options.displayMode == .unlit
            )
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Shadow pass
        if shadowEnabled {
            shadowMapManager.ensureSize(lighting.shadowMapSize)
            if let shadowTex = shadowMapManager.texture {
                let shadowPass = MTLRenderPassDescriptor()
                shadowPass.depthAttachment.texture = shadowTex
                shadowPass.depthAttachment.loadAction = .clear
                shadowPass.depthAttachment.storeAction = .store
                shadowPass.depthAttachment.clearDepth = 1.0

                if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPass) {
                    enc.setDepthStencilState(depthState)
                    enc.setCullMode(.front)
                    enc.setDepthBias(0.01, slopeScale: 1.5, clamp: 0.02)

                    for body in bodies where body.isVisible {
                        guard let buffers = bodyBufferCache[body.id],
                            let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                            buffers.indexCount > 0
                        else { continue }
                        var shadowUniforms = ShadowUniformsSwift(
                            lightViewProjectionMatrix: lightVP, modelMatrix: body.transform)
                        if let nb = buffers.normalBuffer {
                            // Direct-mesh body (Option A): position@0 + normal@2.
                            enc.setRenderPipelineState(shadowDirectPipeline)
                            enc.setVertexBuffer(vb, offset: 0, index: 0)
                            enc.setVertexBuffer(nb, offset: 0, index: 2)
                        } else {
                            enc.setRenderPipelineState(shadowPipeline)
                            enc.setVertexBuffer(vb, offset: 0, index: 0)
                        }
                        enc.setVertexBytes(
                            &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size,
                            index: 1)
                        enc.drawIndexedPrimitives(
                            type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                            indexBuffer: ib, indexBufferOffset: 0)
                    }
                    enc.endEncoding()
                }
            }
        }

        // Main pass
        let bg = options.backgroundColor
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = msaaColor
        passDesc.colorAttachments[0].resolveTexture = resolve
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .multisampleResolve
        passDesc.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        passDesc.depthAttachment.texture = msaaDepth
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 1.0
        passDesc.stencilAttachment.texture = msaaDepth
        passDesc.stencilAttachment.loadAction = .clear
        passDesc.stencilAttachment.storeAction = .dontCare

        guard let mainEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return nil
        }
        mainEncoder.setDepthStencilState(depthState)

        // Grid
        if options.showGrid {
            RendererSharedSetup.encodeGrid(
                encoder: mainEncoder,
                pipeline: gridPipeline,
                viewProjection: viewProjection,
                cameraState: cameraState,
                baseSpacing: options.gridBaseSpacing,
                subdivisions: options.gridSubdivisions
            )
        }

        // Axes
        if options.showAxes {
            RendererSharedSetup.encodeAxes(
                encoder: mainEncoder,
                pipeline: axisPipeline,
                vertexBuffer: axisVertexBuffer,
                viewProjection: viewProjection
            )
        }

        // Bodies
        let displayMode = options.displayMode
        // Translucent bodies (issue #53) are deferred to a sorted back-to-front pass.
        var transparentBodies: [(body: ViewportBody, buffers: BodyBuffersOffscreen)] = []
        for body in bodies where body.isVisible {
            guard let buffers = bodyBufferCache[body.id] else { continue }
            // Point-cloud bodies are drawn in the dedicated pass below — skip
            // the mesh + wireframe paths entirely.
            if body.primitiveKind == .point { continue }

            let hasMesh =
                buffers.vertexBuffer != nil && buffers.indexBuffer != nil && buffers.indexCount > 0

            // Defer translucent mesh bodies to the transparent pass.
            if body.renderLayer == .geometry, body.effectiveMaterial.opacity < 1.0, hasMesh {
                transparentBodies.append((body, buffers))
                continue
            }

            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            var bodyUniforms = BodyUniforms(body: body, objectIndex: 0, isSelected: 0)

            let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0

            // Shaded
            if displayMode.showsSurfaces, hasMesh, let vb = buffers.vertexBuffer,
                let ib = buffers.indexBuffer
            {
                if let nb = buffers.normalBuffer {
                    // Direct-mesh path (Option A): position@0 + normal@2, no interleave.
                    mainEncoder.setRenderPipelineState(directMeshPipeline)
                    mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                    mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                } else {
                    mainEncoder.setRenderPipelineState(shadedPipeline)
                    mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                }
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.setFragmentTexture(matcapTexture, index: 0)
                if shadowEnabled, let shadowTex = shadowMapManager.texture {
                    mainEncoder.setFragmentTexture(shadowTex, index: 1)
                }
                mainEncoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                    indexBuffer: ib, indexBufferOffset: 0)
            }

            // Wireframe
            let shouldDrawEdges = hasEdges && (displayMode.showsEdges || !hasMesh)
            if shouldDrawEdges, let edgeVB = buffers.edgeVertexBuffer {
                var edgeBodyUniforms = bodyUniforms
                if !hasMesh { edgeBodyUniforms.metallic = -1.0 }
                mainEncoder.setRenderPipelineState(wireframePipeline)
                mainEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.drawPrimitives(
                    type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
            }
        }

        // Transparent surface pass (issue #53): deferred translucent bodies,
        // back-to-front, depth test on / write off, composited over the opaque set.
        if displayMode.showsSurfaces, !transparentBodies.isEmpty {
            let camPos = cameraState.position
            func centerDistanceSq(_ t: (body: ViewportBody, buffers: BodyBuffersOffscreen)) -> Float
            {
                let localCenter = t.body.boundingBox?.center ?? SIMD3<Float>(0, 0, 0)
                let c = t.body.transform * SIMD4<Float>(localCenter, 1)
                return simd_length_squared(SIMD3<Float>(c.x, c.y, c.z) - camPos)
            }
            let sorted = transparentBodies.sorted { centerDistanceSq($0) > centerDistanceSq($1) }

            mainEncoder.setDepthStencilState(transparentDepthState)
            mainEncoder.setFragmentTexture(matcapTexture, index: 0)
            if shadowEnabled, let shadowTex = shadowMapManager.texture {
                mainEncoder.setFragmentTexture(shadowTex, index: 1)
            }
            for t in sorted {
                guard let vb = t.buffers.vertexBuffer, let ib = t.buffers.indexBuffer,
                    t.buffers.indexCount > 0
                else { continue }
                var uniforms = makeUniforms()
                uniforms.modelMatrix = t.body.transform
                var bodyUniforms = BodyUniforms(body: t.body, objectIndex: 0, isSelected: 0)
                // Direct-mesh bodies (Option A) bind position@0 + normal@2 via directMeshPipeline;
                // both pipelines share the same alpha-blend config so compositing is identical.
                if let nb = t.buffers.normalBuffer {
                    mainEncoder.setRenderPipelineState(directMeshPipeline)
                    mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                    mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                } else {
                    mainEncoder.setRenderPipelineState(shadedPipeline)
                    mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                }
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: t.buffers.indexCount,
                    indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }
        }

        // Point-cloud pass (issue #28). Walks `.point` bodies and draws them
        // as MTL point primitives via `visiblePointPipeline`. See
        // Shaders.metal `visible_point_vertex` for `pxPerWorldFactor` derivation.
        if let pointPipeline = visiblePointPipeline {
            let pxPerWorldFactor = Float(h) * projMatrix.columns.1.y * 0.5
            var didBindPipeline = false
            for body in bodies where body.isVisible && body.primitiveKind == .point {
                guard let buffers = bodyBufferCache[body.id],
                    let positionBuf = buffers.pointPositionBuffer,
                    buffers.pointVertexCount > 0
                else { continue }

                if !didBindPipeline {
                    mainEncoder.setRenderPipelineState(pointPipeline)
                    mainEncoder.setDepthStencilState(depthState)
                    didBindPipeline = true
                }

                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                let useColors = (buffers.pointColorBuffer != nil) ? UInt32(1) : UInt32(0)
                var params = PointParamsSwift(
                    baseColor: body.color,
                    worldRadius: body.pointRadius,
                    pxPerWorldFactor: pxPerWorldFactor,
                    useVertexColors: useColors
                )

                mainEncoder.setVertexBuffer(positionBuf, offset: 0, index: 0)
                if let colorBuf = buffers.pointColorBuffer {
                    mainEncoder.setVertexBuffer(colorBuf, offset: 0, index: 1)
                } else {
                    // Placeholder binding so the shader's `vertexColors`
                    // argument is non-null (some validation layers care).
                    mainEncoder.setVertexBuffer(positionBuf, offset: 0, index: 1)
                }
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                mainEncoder.setVertexBytes(
                    &params, length: MemoryLayout<PointParamsSwift>.size, index: 3)

                mainEncoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
            }
        }

        mainEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Readback: blit resolve texture to shared buffer
        let bytesPerRow = w * 4
        let bufferSize = bytesPerRow * h
        guard
            let readbackBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        else { return nil }

        guard let blitCB = commandQueue.makeCommandBuffer(),
            let blit = blitCB.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(
            from: resolve, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: readbackBuffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bufferSize)
        blit.endEncoding()
        blitCB.commit()
        blitCB.waitUntilCompleted()

        // Build CGImage from BGRA8 buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard
            let context = CGContext(
                data: readbackBuffer.contents(),
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo.rawValue
            )
        else { return nil }

        guard let baseImage = context.makeImage() else { return nil }

        if options.measurements.isEmpty {
            return baseImage
        }
        return MeasurementCompositor.composite(
            baseImage: baseImage,
            measurements: options.measurements,
            viewProjection: viewProjection,
            viewportSize: CGSize(width: w, height: h)
        )
    }

    /// Renders and writes a PNG to disk.
    ///
    /// - Returns: The written file's size in bytes.
    @discardableResult
    public func renderToPNG(
        bodies: [ViewportBody], url: URL, options: OffscreenRenderOptions = .init()
    ) throws -> Int {
        guard let image = render(bodies: bodies, options: options) else {
            throw OffscreenRenderError.renderFailed
        }
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw OffscreenRenderError.fileCreationFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw OffscreenRenderError.writeFailed
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }

    // MARK: - Private

    private func ensureTextures(width: Int, height: Int, sampleCount: Int) {
        guard width != cachedWidth || height != cachedHeight || sampleCount != cachedSampleCount
        else { return }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.textureType = .type2DMultisample
        colorDesc.sampleCount = sampleCount
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private
        msaaColorTexture = device.makeTexture(descriptor: colorDesc)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDesc.textureType = .type2DMultisample
        depthDesc.sampleCount = sampleCount
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        msaaDepthTexture = device.makeTexture(descriptor: depthDesc)

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .private
        resolveTexture = device.makeTexture(descriptor: resolveDesc)

        cachedWidth = width
        cachedHeight = height
        cachedSampleCount = sampleCount
    }

    private func ensureBuffers(for body: ViewportBody) {
        let currentGen = body.generation
        if let cachedGen = bodyGeneration[body.id], cachedGen == currentGen { return }

        let mesh = RendererSharedBuffers.makeMeshBuffers(device: device, body: body)

        let edgeVertices = RendererSharedBuffers.edgeLineVertices(from: body.edges)
        let edgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: edgeVertices)
        let edgeVertexCount = edgeVertices.count / 6

        // Point-cloud buffers (issue #28), built only when `body.vertices` is non-empty.
        let pointPositionVB = RendererSharedBuffers.makePointPositionBuffer(
            device: device, vertices: body.vertices)
        let pointColorVB = RendererSharedBuffers.makePointColorBuffer(
            device: device, vertexColors: body.vertexColors, vertexCount: body.vertices.count)

        guard mesh.vertexBuffer != nil || edgeVB != nil || pointPositionVB != nil else { return }

        bodyBufferCache[body.id] = BodyBuffersOffscreen(
            vertexBuffer: mesh.vertexBuffer,
            normalBuffer: mesh.normalBuffer,
            indexBuffer: mesh.indexBuffer,
            indexCount: mesh.indexCount,
            edgeVertexBuffer: edgeVB,
            edgeVertexCount: edgeVertexCount,
            vertexCount: mesh.vertexCount,
            pointPositionBuffer: pointPositionVB,
            pointVertexCount: pointPositionVB != nil ? body.vertices.count : 0,
            pointColorBuffer: pointColorVB
        )
        bodyGeneration[body.id] = currentGen
    }
}

// MARK: - Private Types

private struct BodyBuffersOffscreen {
    let vertexBuffer: MTLBuffer?

    /// De-interleaved normal buffer (stride 12) for the direct-mesh path.
    ///
    /// When non-nil, `vertexBuffer` holds positions only (stride 12) and the body draws via
    /// `directMeshPipeline`.
    var normalBuffer: MTLBuffer? = nil
    let indexBuffer: MTLBuffer?
    let indexCount: Int
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int
    let vertexCount: Int

    /// Tight position buffer (stride 12) for the visible point-cloud pass.
    ///
    /// Built from `body.vertices` only when non-empty.
    let pointPositionBuffer: MTLBuffer?
    let pointVertexCount: Int

    /// Per-point colour buffer (stride 16).
    ///
    /// Nil when `body.vertexColors` is empty or its length doesn't match `body.vertices` — the pass
    /// falls back to `body.color` in that case.
    let pointColorBuffer: MTLBuffer?
}
