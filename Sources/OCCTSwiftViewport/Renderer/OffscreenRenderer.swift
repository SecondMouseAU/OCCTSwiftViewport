// OffscreenRenderer.swift
// OCCTSwiftViewport
//
// Headless Metal renderer that produces CGImage from ViewportBody arrays
// without requiring MTKView or a window.

@preconcurrency import Metal
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

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
    private let wireframePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let axisPipeline: MTLRenderPipelineState
    /// Visible point-cloud pipeline (issue #28). Mirrors the live renderer's
    /// `visiblePointPipeline`. Optional only because pipeline construction
    /// could fail on a degenerate device.
    private let visiblePointPipeline: MTLRenderPipelineState?
    private let shadowPipeline: MTLRenderPipelineState
    private let shadowMapManager: ShadowMapManager
    private let depthState: MTLDepthStencilState
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
              let commandQueue = device.makeCommandQueue() else {
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
                  let fromSource = try? device.makeLibrary(source: src, options: nil) {
            library = fromSource
        } else {
            return nil
        }

        // Vertex descriptor (stride 6: position + normal)
        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format = .float3
        vertexDesc.attributes[0].offset = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format = .float3
        vertexDesc.attributes[1].offset = MemoryLayout<Float>.size * 3
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.layouts[0].stride = MemoryLayout<Float>.size * 6

        // Shaded pipeline
        let shadedDesc = MTLRenderPipelineDescriptor()
        shadedDesc.vertexFunction = library.makeFunction(name: "shaded_vertex")
        shadedDesc.fragmentFunction = library.makeFunction(name: "shaded_fragment")
        shadedDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        shadedDesc.colorAttachments[1].pixelFormat = .invalid
        shadedDesc.depthAttachmentPixelFormat = depthFormat
        shadedDesc.stencilAttachmentPixelFormat = depthFormat
        shadedDesc.rasterSampleCount = sampleCount
        shadedDesc.vertexDescriptor = vertexDesc

        guard let shadedPipeline = try? device.makeRenderPipelineState(descriptor: shadedDesc) else { return nil }
        self.shadedPipeline = shadedPipeline

        // Wireframe pipeline
        let wireDesc = MTLRenderPipelineDescriptor()
        wireDesc.vertexFunction = library.makeFunction(name: "wireframe_vertex")
        wireDesc.fragmentFunction = library.makeFunction(name: "wireframe_fragment")
        wireDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        wireDesc.colorAttachments[1].pixelFormat = .invalid
        wireDesc.colorAttachments[0].isBlendingEnabled = true
        wireDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        wireDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wireDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        wireDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        wireDesc.depthAttachmentPixelFormat = depthFormat
        wireDesc.stencilAttachmentPixelFormat = depthFormat
        wireDesc.rasterSampleCount = sampleCount
        wireDesc.vertexDescriptor = vertexDesc

        guard let wireframePipeline = try? device.makeRenderPipelineState(descriptor: wireDesc) else { return nil }
        self.wireframePipeline = wireframePipeline

        // Grid pipeline
        let gridDesc = MTLRenderPipelineDescriptor()
        gridDesc.vertexFunction = library.makeFunction(name: "grid_vertex")
        gridDesc.fragmentFunction = library.makeFunction(name: "grid_fragment")
        gridDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        gridDesc.colorAttachments[1].pixelFormat = .invalid
        gridDesc.depthAttachmentPixelFormat = depthFormat
        gridDesc.stencilAttachmentPixelFormat = depthFormat
        gridDesc.rasterSampleCount = sampleCount

        guard let gridPipeline = try? device.makeRenderPipelineState(descriptor: gridDesc) else { return nil }
        self.gridPipeline = gridPipeline

        // Axis pipeline
        let axisDesc = MTLRenderPipelineDescriptor()
        axisDesc.vertexFunction = library.makeFunction(name: "axis_vertex")
        axisDesc.fragmentFunction = library.makeFunction(name: "axis_fragment")
        axisDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        axisDesc.colorAttachments[1].pixelFormat = .invalid
        axisDesc.depthAttachmentPixelFormat = depthFormat
        axisDesc.stencilAttachmentPixelFormat = depthFormat
        axisDesc.rasterSampleCount = sampleCount

        let axisVertexDesc = MTLVertexDescriptor()
        axisVertexDesc.attributes[0].format = .float3
        axisVertexDesc.attributes[0].offset = 0
        axisVertexDesc.attributes[0].bufferIndex = 0
        axisVertexDesc.attributes[1].format = .float4
        axisVertexDesc.attributes[1].offset = MemoryLayout<Float>.size * 3
        axisVertexDesc.attributes[1].bufferIndex = 0
        axisVertexDesc.layouts[0].stride = MemoryLayout<Float>.size * 7
        axisDesc.vertexDescriptor = axisVertexDesc

        guard let axisPipeline = try? device.makeRenderPipelineState(descriptor: axisDesc) else { return nil }
        self.axisPipeline = axisPipeline

        // Visible point-cloud pipeline (issue #28). No vertex descriptor —
        // shader reads positions and per-point colours via [[vertex_id]].
        let visiblePointDesc = MTLRenderPipelineDescriptor()
        visiblePointDesc.label = "offscreen_visible_point"
        visiblePointDesc.vertexFunction = library.makeFunction(name: "visible_point_vertex")
        visiblePointDesc.fragmentFunction = library.makeFunction(name: "visible_point_fragment")
        visiblePointDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        visiblePointDesc.colorAttachments[1].pixelFormat = .invalid
        visiblePointDesc.colorAttachments[0].isBlendingEnabled = true
        visiblePointDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        visiblePointDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        visiblePointDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        visiblePointDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        visiblePointDesc.depthAttachmentPixelFormat = depthFormat
        visiblePointDesc.stencilAttachmentPixelFormat = depthFormat
        visiblePointDesc.rasterSampleCount = sampleCount
        self.visiblePointPipeline = try? device.makeRenderPipelineState(descriptor: visiblePointDesc)

        // Shadow pipeline
        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label = "offscreen_shadow"
        shadowDesc.vertexFunction = library.makeFunction(name: "shadow_vertex")
        shadowDesc.fragmentFunction = library.makeFunction(name: "depth_only_fragment")
        shadowDesc.depthAttachmentPixelFormat = .depth32Float
        shadowDesc.rasterSampleCount = 1
        shadowDesc.vertexDescriptor = vertexDesc

        guard let shadowPipeline = try? device.makeRenderPipelineState(descriptor: shadowDesc) else { return nil }
        self.shadowPipeline = shadowPipeline
        self.shadowMapManager = ShadowMapManager(device: device)

        // Depth stencil state
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .less
        depthDesc.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDesc) else { return nil }
        self.depthState = depthState

        // Axis vertex buffer
        let axisLength: Float = 1000.0
        let axisData: [Float] = [
            0, 0, 0,  1, 0, 0, 1,   axisLength, 0, 0,  1, 0, 0, 1,
            0, 0, 0,  0, 1, 0, 1,   0, axisLength, 0,  0, 1, 0, 1,
            0, 0, 0,  0, 0, 1, 1,   0, 0, axisLength,  0, 0, 1, 1,
        ]
        guard let axisVB = device.makeBuffer(bytes: axisData, length: axisData.count * MemoryLayout<Float>.size, options: .storageModeShared) else { return nil }
        self.axisVertexBuffer = axisVB

        // Matcap texture (procedural 256x256)
        let matcapSize = 256
        let matcapDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: matcapSize, height: matcapSize, mipmapped: false)
        matcapDesc.usage = [.shaderRead]
        guard let matcap = device.makeTexture(descriptor: matcapDesc) else { return nil }

        var matcapPixels = [UInt8](repeating: 0, count: matcapSize * matcapSize * 4)
        for y in 0..<matcapSize {
            for x in 0..<matcapSize {
                let u = (Float(x) + 0.5) / Float(matcapSize) * 2.0 - 1.0
                let v = (Float(y) + 0.5) / Float(matcapSize) * 2.0 - 1.0
                let r2 = u * u + v * v
                var r: Float = 0.1, g: Float = 0.1, b: Float = 0.1
                if r2 <= 1.0 {
                    let nz = sqrt(1.0 - r2)
                    let nx = u, ny = -v
                    let keyDir = simd_normalize(SIMD3<Float>(-0.5, 0.7, 0.5))
                    let fillDir = simd_normalize(SIMD3<Float>(0.6, 0.2, 0.7))
                    let normal = SIMD3<Float>(nx, ny, nz)
                    let keyDiff = max(simd_dot(normal, keyDir), 0.0) * 0.8
                    let fillDiff = max(simd_dot(normal, fillDir), 0.0) * 0.3
                    let rim = pow(1.0 - nz, 3.0) * 0.25
                    let brightness = min(keyDiff + fillDiff + rim + 0.18, 1.0)
                    r = brightness * 1.0; g = brightness * 0.97; b = brightness * 0.95
                }
                let idx = (y * matcapSize + x) * 4
                matcapPixels[idx] = UInt8(min(max(r * 255, 0), 255))
                matcapPixels[idx + 1] = UInt8(min(max(g * 255, 0), 255))
                matcapPixels[idx + 2] = UInt8(min(max(b * 255, 0), 255))
                matcapPixels[idx + 3] = 255
            }
        }
        matcap.replace(region: MTLRegionMake2D(0, 0, matcapSize, matcapSize), mipmapLevel: 0, withBytes: matcapPixels, bytesPerRow: matcapSize * 4)
        self.matcapTexture = matcap
    }

    // MARK: - Public API

    /// Renders bodies to a CGImage.
    public func render(bodies: [ViewportBody], options: OffscreenRenderOptions = .init()) -> CGImage? {
        let w = options.width
        let h = options.height
        let sampleCount = options.msaaSampleCount

        ensureTextures(width: w, height: h, sampleCount: sampleCount)
        guard let msaaColor = msaaColorTexture,
              let msaaDepth = msaaDepthTexture,
              let resolve = resolveTexture else { return nil }

        // Ensure buffers for all bodies
        for body in bodies where body.isVisible {
            ensureBuffers(for: body)
        }

        let cameraState = options.cameraState
        let aspectRatio = Float(w) / Float(h)
        let viewMatrix = cameraState.viewMatrix
        let nearClip: Float = 0.01
        let farClip: Float = 10000.0

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
            baseProjMatrix = cameraState.projectionMatrix(aspectRatio: aspectRatio, near: nearClip, far: farClip)
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
        let nearPlane = nearClip
        let farPlane = farClip

        let lightSources = [lighting.keyLight, lighting.fillLight, lighting.backLight]
        func packLight(_ ls: LightSettings) -> LightDataSwift {
            let typeVal: Float
            let radiusVal: Float
            switch ls.lightType {
            case .directional: typeVal = 0.0; radiusVal = 0.0
            case .point(let radius): typeVal = 1.0; radiusVal = radius
            }
            return LightDataSwift(
                directionAndIntensity: SIMD4<Float>(ls.direction.x, ls.direction.y, ls.direction.z, ls.intensity),
                colorAndEnabled: SIMD4<Float>(ls.color.x, ls.color.y, ls.color.z, ls.isEnabled ? 1.0 : 0.0),
                typeAndParams: SIMD4<Float>(typeVal, radiusVal, 0, 0),
                positionAndPad: SIMD4<Float>(ls.position.x, ls.position.y, ls.position.z, 0)
            )
        }

        // Shadow setup
        let shadowEnabled = lighting.shadowsEnabled
        let lightVP: simd_float4x4
        if shadowEnabled {
            lightVP = computeLightViewProjection(lightDir: lighting.keyLight.direction, bodies: bodies)
        } else {
            lightVP = matrix_identity_float4x4
        }
        let shadowParams = SIMD4<Float>(lighting.shadowBias, lighting.shadowIntensity, shadowEnabled ? 1.0 : 0.0, 1.0)
        let shadowParams2 = SIMD4<Float>(lighting.shadowLightSize, lighting.shadowSearchRadius, 0, 0)

        func makeUniforms() -> Uniforms {
            Uniforms(
                viewProjectionMatrix: viewProjection,
                modelMatrix: matrix_identity_float4x4,
                viewMatrix: viewMatrix,
                cameraPosition: SIMD4<Float>(cameraState.position.x, cameraState.position.y, cameraState.position.z, nearPlane),
                light0: packLight(lightSources[0]),
                light1: packLight(lightSources[1]),
                light2: packLight(lightSources[2]),
                ambientSkyColor: SIMD4<Float>(lighting.ambientSkyColor.x, lighting.ambientSkyColor.y, lighting.ambientSkyColor.z, lighting.specularPower),
                ambientGroundColor: SIMD4<Float>(lighting.ambientGroundColor.x, lighting.ambientGroundColor.y, lighting.ambientGroundColor.z, lighting.specularIntensity),
                materialParams: SIMD4<Float>(lighting.fresnelPower, lighting.fresnelIntensity, lighting.matcapBlend, farPlane),
                lightViewProjectionMatrix: lightVP,
                shadowParams: shadowParams,
                shadowParams2: shadowParams2,
                iblParams: .zero
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
                              buffers.indexCount > 0 else { continue }
                        var shadowUniforms = ShadowUniformsSwift(lightViewProjectionMatrix: lightVP, modelMatrix: matrix_identity_float4x4)
                        enc.setRenderPipelineState(shadowPipeline)
                        enc.setVertexBuffer(vb, offset: 0, index: 0)
                        enc.setVertexBytes(&shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size, index: 1)
                        enc.drawIndexedPrimitives(type: .triangle, indexCount: buffers.indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
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
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        passDesc.depthAttachment.texture = msaaDepth
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 1.0
        passDesc.stencilAttachment.texture = msaaDepth
        passDesc.stencilAttachment.loadAction = .clear
        passDesc.stencilAttachment.storeAction = .dontCare

        guard let mainEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return nil }
        mainEncoder.setDepthStencilState(depthState)

        // Grid
        if options.showGrid {
            let spacing = computeGridSpacing(cameraState: cameraState)
            let halfCount: Int32 = 15
            let pivot = cameraState.pivot
            let centerX = (pivot.x / spacing).rounded() * spacing
            let centerZ = (pivot.z / spacing).rounded() * spacing
            var gridUniforms = GridUniforms(
                viewProjectionMatrix: viewProjection,
                gridOrigin: SIMD3<Float>(centerX, -0.01, centerZ),
                spacing: spacing, halfCount: halfCount,
                dotSize: max(2.0, 4.0 / cameraState.distance),
                dotColor: SIMD4<Float>(0.6, 0.6, 0.6, 1.0)
            )
            let count = Int(halfCount) * 2 + 1
            mainEncoder.setRenderPipelineState(gridPipeline)
            mainEncoder.setVertexBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.size, index: 0)
            mainEncoder.setFragmentBytes(&gridUniforms, length: MemoryLayout<GridUniforms>.size, index: 0)
            mainEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1, instanceCount: count * count)
        }

        // Axes
        if options.showAxes {
            var axisUniforms = AxisUniforms(viewProjectionMatrix: viewProjection)
            mainEncoder.setRenderPipelineState(axisPipeline)
            mainEncoder.setVertexBuffer(axisVertexBuffer, offset: 0, index: 0)
            mainEncoder.setVertexBytes(&axisUniforms, length: MemoryLayout<AxisUniforms>.size, index: 1)
            mainEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 6)
        }

        // Bodies
        let displayMode = options.displayMode
        for body in bodies where body.isVisible {
            guard let buffers = bodyBufferCache[body.id] else { continue }
            // Point-cloud bodies are drawn in the dedicated pass below — skip
            // the mesh + wireframe paths entirely.
            if body.primitiveKind == .point { continue }

            var uniforms = makeUniforms()
            var bodyUniforms = BodyUniforms(body: body, objectIndex: 0, isSelected: 0)

            let hasMesh = buffers.vertexBuffer != nil && buffers.indexBuffer != nil && buffers.indexCount > 0
            let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0

            // Shaded
            if displayMode.showsSurfaces, hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer {
                mainEncoder.setRenderPipelineState(shadedPipeline)
                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(&bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.setFragmentTexture(matcapTexture, index: 0)
                if shadowEnabled, let shadowTex = shadowMapManager.texture {
                    mainEncoder.setFragmentTexture(shadowTex, index: 1)
                }
                mainEncoder.drawIndexedPrimitives(type: .triangle, indexCount: buffers.indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            }

            // Wireframe
            let shouldDrawEdges = hasEdges && (displayMode.showsEdges || !hasMesh)
            if shouldDrawEdges, let edgeVB = buffers.edgeVertexBuffer {
                var edgeBodyUniforms = bodyUniforms
                if !hasMesh { edgeBodyUniforms.metallic = -1.0 }
                mainEncoder.setRenderPipelineState(wireframePipeline)
                mainEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(&edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
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
                      buffers.pointVertexCount > 0 else { continue }

                if !didBindPipeline {
                    mainEncoder.setRenderPipelineState(pointPipeline)
                    mainEncoder.setDepthStencilState(depthState)
                    didBindPipeline = true
                }

                var uniforms = makeUniforms()
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
                mainEncoder.setVertexBytes(&params, length: MemoryLayout<PointParamsSwift>.size, index: 3)

                mainEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
            }
        }

        mainEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Readback: blit resolve texture to shared buffer
        let bytesPerRow = w * 4
        let bufferSize = bytesPerRow * h
        guard let readbackBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return nil }

        guard let blitCB = commandQueue.makeCommandBuffer(),
              let blit = blitCB.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: readbackBuffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bufferSize)
        blit.endEncoding()
        blitCB.commit()
        blitCB.waitUntilCompleted()

        // Build CGImage from BGRA8 buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let context = CGContext(
            data: readbackBuffer.contents(),
            width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

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

    /// Renders and writes PNG to disk. Returns file size in bytes.
    @discardableResult
    public func renderToPNG(bodies: [ViewportBody], url: URL, options: OffscreenRenderOptions = .init()) throws -> Int {
        guard let image = render(bodies: bodies, options: options) else {
            throw OffscreenRenderError.renderFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
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
        guard width != cachedWidth || height != cachedHeight || sampleCount != cachedSampleCount else { return }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.textureType = .type2DMultisample
        colorDesc.sampleCount = sampleCount
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .private
        msaaColorTexture = device.makeTexture(descriptor: colorDesc)

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDesc.textureType = .type2DMultisample
        depthDesc.sampleCount = sampleCount
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        msaaDepthTexture = device.makeTexture(descriptor: depthDesc)

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
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

        var vertexBuffer: MTLBuffer?
        var indexBuffer: MTLBuffer?
        var indexCount = 0
        var vertexCount = 0

        if !body.vertexData.isEmpty, !body.indices.isEmpty {
            vertexBuffer = device.makeBuffer(bytes: body.vertexData, length: body.vertexData.count * MemoryLayout<Float>.size, options: .storageModeShared)
            indexBuffer = device.makeBuffer(bytes: body.indices, length: body.indices.count * MemoryLayout<UInt32>.size, options: .storageModeShared)
            indexCount = body.indices.count
            vertexCount = body.vertexData.count / 6
        }

        var edgeVertices: [Float] = []
        for polyline in body.edges {
            guard polyline.count >= 2 else { continue }
            for i in 0..<(polyline.count - 1) {
                let a = polyline[i], b = polyline[i + 1]
                edgeVertices.append(contentsOf: [a.x, a.y, a.z, 0, 0, 0])
                edgeVertices.append(contentsOf: [b.x, b.y, b.z, 0, 0, 0])
            }
        }

        let edgeVB: MTLBuffer? = edgeVertices.isEmpty ? nil :
            device.makeBuffer(bytes: edgeVertices, length: edgeVertices.count * MemoryLayout<Float>.size, options: .storageModeShared)
        let edgeVertexCount = edgeVertices.count / 6

        // Point-cloud buffers (issue #28). Built only when `body.vertices`
        // is non-empty. The colour buffer is only built when its length
        // matches the vertex count — mismatched arrays silently fall back
        // to the body colour rather than reading out of bounds.
        let pointPositionVB: MTLBuffer?
        let pointVertexCount: Int
        if !body.vertices.isEmpty {
            pointPositionVB = body.vertices.withUnsafeBufferPointer { buf in
                device.makeBuffer(
                    bytes: buf.baseAddress!,
                    length: buf.count * MemoryLayout<SIMD3<Float>>.stride,
                    options: .storageModeShared
                )
            }
            pointVertexCount = body.vertices.count
        } else {
            pointPositionVB = nil
            pointVertexCount = 0
        }

        let pointColorVB: MTLBuffer?
        if !body.vertexColors.isEmpty, body.vertexColors.count == body.vertices.count {
            pointColorVB = body.vertexColors.withUnsafeBufferPointer { buf in
                device.makeBuffer(
                    bytes: buf.baseAddress!,
                    length: buf.count * MemoryLayout<SIMD4<Float>>.stride,
                    options: .storageModeShared
                )
            }
        } else {
            pointColorVB = nil
        }

        guard vertexBuffer != nil || edgeVB != nil || pointPositionVB != nil else { return }

        bodyBufferCache[body.id] = BodyBuffersOffscreen(
            vertexBuffer: vertexBuffer,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            edgeVertexBuffer: edgeVB,
            edgeVertexCount: edgeVertexCount,
            vertexCount: vertexCount,
            pointPositionBuffer: pointPositionVB,
            pointVertexCount: pointVertexCount,
            pointColorBuffer: pointColorVB
        )
        bodyGeneration[body.id] = currentGen
    }

    private func computeLightViewProjection(lightDir: SIMD3<Float>, bodies: [ViewportBody]) -> simd_float4x4 {
        var sceneMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var sceneMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var hasGeometry = false

        for body in bodies where body.isVisible {
            if let bb = body.boundingBox {
                sceneMin = simd_min(sceneMin, bb.min)
                sceneMax = simd_max(sceneMax, bb.max)
                hasGeometry = true
            }
        }

        if !hasGeometry {
            sceneMin = SIMD3<Float>(-5, -5, -5)
            sceneMax = SIMD3<Float>(5, 5, 5)
        }

        let center = (sceneMin + sceneMax) * 0.5
        let extents = sceneMax - sceneMin
        let radius = simd_length(extents) * 0.5

        let dir = simd_normalize(lightDir)
        let lightPos = center - dir * (radius * 2.0)

        let tentativeUp = SIMD3<Float>(0, 1, 0)
        let up: SIMD3<Float> = abs(simd_dot(dir, tentativeUp)) > 0.99 ? SIMD3<Float>(0, 0, 1) : tentativeUp

        let lightView = simd_float4x4.lookAt(eye: lightPos, target: center, up: up)
        let orthoSize = radius * 1.5
        let lightProj = simd_float4x4.orthographic(left: -orthoSize, right: orthoSize, bottom: -orthoSize, top: orthoSize, near: 0.01, far: radius * 4.0)

        return lightProj * lightView
    }

    private func computeGridSpacing(cameraState: CameraState) -> Float {
        let distance = cameraState.distance
        let fovRadians = cameraState.fieldOfView * .pi / 180.0
        let visibleWidth = 2.0 * distance * tan(fovRadians / 2.0)
        let idealSpacing = visibleWidth / 15.0
        let baseSpacing: Float = 1.0
        let subdivisions: Float = 5.0
        guard baseSpacing > 0, idealSpacing > 0 else { return 1.0 }
        let level = (log(idealSpacing / baseSpacing) / log(subdivisions)).rounded()
        return baseSpacing * pow(subdivisions, level)
    }
}

// MARK: - Private Types

private struct BodyBuffersOffscreen {
    let vertexBuffer: MTLBuffer?
    let indexBuffer: MTLBuffer?
    let indexCount: Int
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int
    let vertexCount: Int
    /// Tight position buffer (stride 12) for the visible point-cloud pass.
    /// Built from `body.vertices` only when non-empty.
    let pointPositionBuffer: MTLBuffer?
    let pointVertexCount: Int
    /// Per-point colour buffer (stride 16). Nil when `body.vertexColors` is
    /// empty or its length doesn't match `body.vertices` — the pass falls
    /// back to `body.color` in that case.
    let pointColorBuffer: MTLBuffer?
}
