// ViewportRenderer.swift
// ViewportKit
//
// MTKViewDelegate that drives Metal rendering for the viewport.

@preconcurrency import MetalKit
import SwiftUI
import simd

// MARK: - Uniform Types (Swift-side, must match Shaders.metal)

struct LightDataSwift {
    var directionAndIntensity: SIMD4<Float>  // xyz = direction, w = intensity
    var colorAndEnabled: SIMD4<Float>  // rgb = color, a = enabled flag
    var typeAndParams: SIMD4<Float>  // x = type (0=directional, 1=point), y = radius, z/w = unused
    var positionAndPad: SIMD4<Float>  // xyz = world position (point lights), w = unused
}

struct Uniforms {
    var viewProjectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var cameraPosition: SIMD4<Float>  // xyz + nearPlane in w
    var light0: LightDataSwift
    var light1: LightDataSwift
    var light2: LightDataSwift
    var ambientSkyColor: SIMD4<Float>  // rgb + specularPower in w
    var ambientGroundColor: SIMD4<Float>  // rgb + specularIntensity in w
    var materialParams: SIMD4<Float>  // fresnelPower, fresnelIntensity, matcapBlend, farPlane
    var lightViewProjectionMatrix: simd_float4x4  // for shadow mapping
    var shadowParams: SIMD4<Float>  // x = bias, y = intensity, z = enabled (1/0), w = edgeIntensity
    var shadowParams2: SIMD4<Float> = .zero  // x = lightSize, y = searchRadius, z/w = unused (PCSS)
    var iblParams: SIMD4<Float> = .zero  // x = intensity, y = rotationY (radians),
    // z = backgroundExposure, w = hasEnvMap
    var clipPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero
    )
    var clipPlaneCount: UInt32 = 0
    var unlit: UInt32 = 0  // 1 = unlit/flat-colour (skip lighting + tone map)
    var _clipPad: SIMD2<Float> = .zero
}

// Per-body shader uniforms.
//
// IMPORTANT — Swift↔Metal sync:
// The matching `struct BodyUniforms` lives in Renderer/Shaders.metal.
// Field order, types, and 16-byte alignment must stay identical.
// Total stride is 64 bytes (4 × float4-equivalent slots).
struct BodyUniforms {
    var color: SIMD4<Float>  // offset  0  (16) — base colour rgb, opacity in a
    var objectIndex: UInt32 = 0  // offset 16
    var roughness: Float = 0.5  // offset 20
    var metallic: Float = 0.0  // offset 24
    var isSelected: UInt32 = 0  // offset 28  (1 = selected, 2 = hovered)
    var clearcoat: Float = 0  // offset 32
    var clearcoatRoughness: Float = 0.03  // offset 36
    var ior: Float = 1.5  // offset 40
    var _pad0: Float = 0  // offset 44
    // offset 48 — xyz = emissive linear RGB, w = strength
    var emissiveAndStrength: SIMD4<Float> = .zero
}

extension BodyUniforms {
    /// Builds per-body uniforms from the body's effective material.
    init(body: ViewportBody, objectIndex: UInt32 = 0, isSelected: UInt32 = 0) {
        let m = body.effectiveMaterial
        self.color = SIMD4<Float>(m.baseColor.x, m.baseColor.y, m.baseColor.z, m.opacity)
        self.objectIndex = objectIndex
        self.roughness = m.roughness
        self.metallic = m.metallic
        self.isSelected = isSelected
        self.clearcoat = m.clearcoat
        self.clearcoatRoughness = m.clearcoatRoughness
        self.ior = m.ior
        self.emissiveAndStrength = SIMD4<Float>(
            m.emissive.x, m.emissive.y, m.emissive.z, m.emissiveStrength)
    }
}

// IMPORTANT — Swift↔Metal sync (see Renderer/Shaders.metal `struct PointParams`).
// Field order, types, and 16-byte alignment must stay identical. Total stride = 32 bytes.
struct PointParamsSwift {
    var baseColor: SIMD4<Float>  // offset  0 — fallback colour when vertexColors empty
    var worldRadius: Float  // offset 16
    var pxPerWorldFactor: Float  // offset 20 — viewportHeight * projection[1][1] / 2
    var useVertexColors: UInt32  // offset 24
    var _pad: UInt32 = 0  // offset 28
}

struct GridUniforms {
    var viewProjectionMatrix: simd_float4x4
    var gridOrigin: SIMD3<Float>
    var spacing: Float
    var halfCount: Int32
    var dotSize: Float
    var dotColor: SIMD4<Float>
}

struct AxisUniforms {
    var viewProjectionMatrix: simd_float4x4
}

struct SelectionOutlineParamsSwift {
    var viewProjectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var outlineColor: SIMD3<Float>
    var outlineScale: Float
}

struct ShadowUniformsSwift {
    var lightViewProjectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
}

struct SSAOParamsSwift {
    var texelSize: SIMD2<Float>
    var radius: Float
    var intensity: Float
    var nearPlane: Float
    var farPlane: Float
    var silhouetteThickness: Float
    var silhouetteIntensity: Float
    var exposure: Float
    var whitePoint: Float
    var dofAperture: Float
    var dofFocalDistance: Float
    var dofMaxBlurRadius: Float
    var dofEnabled: Float
}

// IMPORTANT — Swift↔Metal sync (see Renderer/Shaders.metal `struct TAAParams`).
struct TAAParamsSwift {
    var blendFactor: Float
    var disableClamp: Float = 0  // 1.0 = skip neighborhood AABB clamp (use for static scenes)
    var jitterOffset: SIMD2<Float>
    var texelSize: SIMD2<Float>
}

// IMPORTANT — Swift↔Metal sync (see Renderer/Shaders.metal `struct SkyboxUniforms`).
struct SkyboxUniformsSwift {
    var inverseViewProjection: simd_float4x4
    var params: SIMD4<Float>  // x = rotationY, y = backgroundExposure, z = mipLevel, w = unused
}

// MARK: - Cached Body Buffers

private struct BodyBuffers {
    let vertexBuffer: MTLBuffer?
    /// De-interleaved normal buffer (stride 12) for the direct-mesh path (Option A).
    ///
    /// When non-nil, `vertexBuffer` holds positions only (stride 12) and the body draws via
    /// `directMeshPipeline` in the opaque shaded pass; the shadow / pick / depth passes skip it.
    var normalBuffer: MTLBuffer? = nil
    let indexBuffer: MTLBuffer?
    let indexCount: Int
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int
    /// Number of line segments (edge primitives), equal to `edgeVertexCount / 2`.
    ///
    /// Used to gate edge picking, since the line primitive count must equal
    /// `body.edgeIndices.count` for the index map to be usable.
    let edgePrimitiveCount: Int
    /// Vertex buffer for point-sprite picking, built from `body.vertices`.
    ///
    /// Same stride as the mesh vertex buffer (position + zeroed normal) so it
    /// can reuse the standard pick vertex descriptor.
    let pointVertexBuffer: MTLBuffer?
    let pointVertexCount: Int
    /// Position-only buffer for the visible point-cloud pass (stride 12).
    ///
    /// The visible-point shader reads this with `[[vertex_id]]` instead of
    /// going through a vertex descriptor.
    let pointPositionBuffer: MTLBuffer?
    /// Per-point colour buffer (stride 16).
    ///
    /// Nil when the body has no `vertexColors` set — the pass falls back to the body colour.
    let pointColorBuffer: MTLBuffer?
    let vertexCount: Int
    // Tessellation (nil when tessellation disabled or edge-only body)
    let tessellation: TessellationBuffers?
    // Mesh shader meshlets (nil when mesh shaders disabled or edge-only body)
    let meshlets: MeshletBuffers?
    /// Per-triangle highlight style buffer.
    ///
    /// Nil when `body.triangleStyles` is empty. RGBA per triangle, indexed by
    /// `[[primitive_id]]` in the highlight fragment shader.
    let triangleStyleBuffer: MTLBuffer?
    /// The body's local-space AABB, computed once when buffers are built.
    ///
    /// Cached here so per-frame frustum culling (issue #42) doesn't rescan vertices.
    let localBoundingBox: BoundingBox?
}

// MARK: - Frame Render Targets

/// The attachment set one frame is encoded into.
///
/// `draw(in:)` fills this from the live `MTKView` drawable and `renderHeadless(...)` fills it from
/// renderer-owned off-screen textures built to the same specification, so both drive the identical
/// encode path. See `docs/reference/Rendering.md`.
struct FrameRenderTargets {
    /// Main colour pass descriptor, with attachments, load/store actions and clear values set.
    let mainPassDescriptor: MTLRenderPassDescriptor

    /// Texture the frame's final composite lands in — the drawable's texture on the live path.
    let finalColorTexture: MTLTexture

    /// Target size in pixels.
    let size: CGSize

    /// Drawable presented when the frame's command buffer commits; `nil` off-screen.
    let presentable: (any MTLDrawable)?
}

// MARK: - ViewportRenderer

@MainActor
public final class ViewportRenderer: NSObject, MTKViewDelegate, Sendable {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    // MSAA pipelines (sampleCount matches view — 4 or 1)
    private let shadedPipeline: MTLRenderPipelineState
    /// Direct-mesh shaded pipeline (Option A).
    ///
    /// Same shaders as `shadedPipeline`, but its vertex descriptor reads position from buffer 0
    /// and normal from buffer 2 (de-interleaved), so bodies built via
    /// `ViewportBody.directMesh(...)` render without a CPU interleave.
    private let directMeshPipeline: MTLRenderPipelineState
    private let wireframePipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let axisPipeline: MTLRenderPipelineState
    // 1x pick-only pipelines (pick texture is always sampleCount=1)
    private let pickShadedPipeline: MTLRenderPipelineState
    /// Direct-mesh face-pick pipeline (Option A).
    ///
    /// `pick_vertex` with the two-buffer descriptor (position@0 / normal@2) so direct-mesh bodies
    /// are stamped into the R32Uint pick texture. The pick vertex shader reads only position; the
    /// normal binding satisfies attribute 1.
    private let pickShadedDirectPipeline: MTLRenderPipelineState
    /// Line-primitive pick pipeline for edge picking.
    ///
    /// Same vertex shader as `pick_vertex`; the fragment emits kind=1 in the pick encoding.
    private let pickLinePipeline: MTLRenderPipelineState?
    private let pickArcPipeline: MTLRenderPipelineState?
    /// Point-sprite pick pipeline for vertex picking.
    ///
    /// The vertex shader writes `[[point_size]]` so individual points have a clickable
    /// footprint; the fragment emits kind=2.
    private let pickPointPipeline: MTLRenderPipelineState?
    /// MSAA point-sprite pipeline for visible point-cloud bodies.
    ///
    /// Renders a `.point` body's `vertices` as disc-masked point sprites with a world-space
    /// radius projected to screen pixels.
    private let visiblePointPipeline: MTLRenderPipelineState?
    /// `.lessEqual` depth state used by the edge + vertex pick sub-passes so
    /// edges/points coplanar with a face win the pick over the face.
    private let pickEdgeOrPointDepthState: MTLDepthStencilState
    // Depth-only pipeline for SSAO depth pass
    private let depthOnlyPipeline: MTLRenderPipelineState
    /// Direct-mesh depth-only pipeline (Option A).
    ///
    /// `depth_only_vertex` with the two-buffer descriptor (position@0 / normal@2) so direct-mesh
    /// bodies are written into the SSAO / silhouette depth prepass too. The depth shader reads
    /// only position; the normal binding just satisfies the descriptor's attribute 1.
    private let depthOnlyDirectPipeline: MTLRenderPipelineState
    // Shadow mapping
    private let shadowPipeline: MTLRenderPipelineState
    /// Direct-mesh shadow pipeline (Option A).
    ///
    /// `shadow_vertex` with the two-buffer descriptor (position@0 / normal@2) so direct-mesh
    /// bodies cast shadows too. The shadow shader reads only position; the normal binding just
    /// satisfies the descriptor's attribute 1.
    private let shadowDirectPipeline: MTLRenderPipelineState
    private let shadowMapManager: ShadowMapManager
    // Selection outline
    private let outlinePipeline: MTLRenderPipelineState

    // Per-triangle highlight overlay (issue #25).
    // Drawn with the same vertex pipeline as shaded — so identical positions —
    // but composites per-triangle style color over the existing fragment.
    private let highlightPipeline: MTLRenderPipelineState
    private let stencilWriteState: MTLDepthStencilState
    private let stencilTestState: MTLDepthStencilState
    private let depthState: MTLDepthStencilState
    /// Always-pass, no-write depth state for overlay-layer bodies such as manipulator widgets.
    ///
    /// Drawn after the selection outline so they remain visible even when occluded by user
    /// geometry.
    private let overlayDepthState: MTLDepthStencilState

    // .lessEqual + write disabled — for the per-triangle highlight pass.
    // Identical-position highlight triangles win ties with the shaded pass
    // without depth-fighting; depth write off so later passes aren't disturbed.
    private let highlightDepthState: MTLDepthStencilState
    private let transparentSurfaceDepthState: MTLDepthStencilState
    private let matcapTexture: MTLTexture
    private let msaaSampleCount: Int
    // Skybox (HDR background draw — IBL cubemap as fullscreen background)
    private let skyboxPipeline: MTLRenderPipelineState?
    private let skyboxDepthState: MTLDepthStencilState?

    // Hardware tessellation (PN triangles)
    private let tessellationManager: TessellationManager?
    private let tessellatedShadedPipeline: MTLRenderPipelineState?
    private let tessellatedShadowPipeline: MTLRenderPipelineState?
    private let tessellatedDepthOnlyPipeline: MTLRenderPipelineState?
    private let tessellatedPickPipeline: MTLRenderPipelineState?
    private let tessellationEnabled: Bool

    // Mesh shaders (Apple9+ / M3+ / A17+)
    private let meshShaderShadedPipeline: MTLRenderPipelineState?
    private let meshShaderShadowPipeline: MTLRenderPipelineState?
    private let meshShaderDepthOnlyPipeline: MTLRenderPipelineState?
    private let meshShaderPickPipeline: MTLRenderPipelineState?
    private let meshShadersEnabled: Bool

    /// Off-screen attachment set backing `renderHeadless(...)`; `nil` until the first such call.
    ///
    /// Kept out of every live-path code path, so headless mode cannot perturb on-screen rendering.
    var headlessTargets: HeadlessRenderTargets?

    /// Depth texture for the 1x pick pass (separate from the MSAA depth).
    private var pickDepthTexture: MTLTexture?
    private var pickDepthWidth: Int = 0
    private var pickDepthHeight: Int = 0

    // SSAO post-process
    private let ssaoPipeline: MTLRenderPipelineState?
    /// 1x resolved color texture for SSAO input (MSAA resolves into this).
    private var resolvedColorTexture: MTLTexture?
    /// 1x resolved depth texture for SSAO depth sampling.
    private var resolvedDepthTexture: MTLTexture?
    private var resolvedWidth: Int = 0
    private var resolvedHeight: Int = 0

    // TAA
    private let taaPipeline: MTLRenderPipelineState?
    private var taaHistoryTexture: MTLTexture?
    private var taaOutputTexture: MTLTexture?
    private var taaFrameIndex: UInt32 = 0
    private var lastCameraState: CameraState?

    // Environment map IBL
    private var environmentMapManager: EnvironmentMapManager?

    private weak var controller: ViewportController?
    private var bodiesBinding: Binding<[ViewportBody]>

    /// Cached MTLBuffers keyed by body ID.
    private var bodyBufferCache: [String: BodyBuffers] = [:]
    /// Generation counter per body ID (detects geometry changes).
    private var bodyGeneration: [String: UInt64] = [:]

    /// Axis vertex buffer (6 vertices: 3 line segments with position+color).
    private let axisVertexBuffer: MTLBuffer

    // MARK: - Picking

    /// Manages the R32Uint pick ID texture (second color attachment).
    private let pickTextureManager: PickTextureManager
    /// Shared-mode buffer for single-pixel readback of pick ID.
    private let pickReadbackBuffer: MTLBuffer
    /// Shared-mode buffer for region readback of pick IDs (issue #90).
    ///
    /// Grown on demand to fit the largest rectangle requested so far; reused below that.
    private var regionReadbackBuffer: MTLBuffer?
    private var regionReadbackCapacity: Int = 0
    /// Maps objectIndex → bodyID, rebuilt each frame.
    private var currentIndexMap: [Int: String] = [:]
    /// Maps bodyID → PickLayer, rebuilt each frame.
    ///
    /// Routes GPU pick results to either `ViewportController.pickResult` or `widgetPickResult`.
    private var currentLayerMap: [String: PickLayer] = [:]

    /// Reused buffer for per-frame adaptively-sampled analytic arc edges (issue #48).
    ///
    /// Grown on demand; written CPU-side each frame.
    private var arcLineBuffer: MTLBuffer?

    /// Most recent drawable size in pixels, updated each frame.
    ///
    /// Lets the view layer derive the point→pixel scale without `UIScreen`/`NSScreen` (works on
    /// iOS / macOS / visionOS alike).
    public private(set) var lastDrawableSize: CGSize = .zero

    /// One-shot guard for the DEBUG "bodies have no tessellation data" warning, so the
    /// per-frame check can't log on every frame.
    private var didLogMissingTessellationData = false

    // MARK: - Initialization

    public init?(controller: ViewportController, bodies: Binding<[ViewportBody]>) {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.controller = controller
        self.bodiesBinding = bodies

        let sampleCount = controller.configuration.msaaSampleCount
        self.msaaSampleCount = sampleCount

        // Load shader library.
        // Xcode compiles .metal → default.metallib inside the resource bundle.
        // Plain SPM copies the .metal source, so fall back to runtime compilation.
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

        let depthFormat: MTLPixelFormat = .depth32Float_stencil8

        // --- MSAA pipelines (color-only, no pick texture) ---

        guard
            let shadedPipeline = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.shadedPipeline = shadedPipeline

        guard
            let directMeshPipeline = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc)
        else {
            return nil
        }
        self.directMeshPipeline = directMeshPipeline

        guard
            let wireframePipeline = RendererSharedSetup.makeWireframePipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.wireframePipeline = wireframePipeline

        guard
            let gridPipeline = RendererSharedSetup.makeGridPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else {
            return nil
        }
        self.gridPipeline = gridPipeline

        guard
            let axisPipeline = RendererSharedSetup.makeAxisPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else {
            return nil
        }
        self.axisPipeline = axisPipeline

        // Skybox pipeline (MSAA, no vertex buffer — fullscreen triangle from vertex_id)
        self.skyboxPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "skybox", library: library,
            vertexFunction: "skybox_vertex", fragmentFunction: "skybox_fragment",
            colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
            stencilPixelFormat: depthFormat, sampleCount: sampleCount)

        // Skybox depth state: depth test always, no depth write.
        // Drawn first; subsequent geometry overwrites via normal depth test.
        self.skyboxDepthState = RendererSharedSetup.makeDepthStencilState(
            device: device, compareFunction: .always, isDepthWriteEnabled: false)

        // --- 1x pick-only pipeline (R32Uint, no MSAA) ---

        guard
            let pickShadedPipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "pick_shaded", library: library,
                vertexFunction: "pick_vertex", fragmentFunction: "pick_fragment",
                colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
                vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.pickShadedPipeline = pickShadedPipeline

        // Direct-mesh face-pick pipeline (Option A): same pick shaders, two-buffer descriptor.
        guard
            let pickShadedDirectPipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "pick_shaded_direct", library: library,
                vertexFunction: "pick_vertex", fragmentFunction: "pick_fragment",
                colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
                vertexDescriptor: directVertexDesc)
        else {
            return nil
        }
        self.pickShadedDirectPipeline = pickShadedDirectPipeline

        // 1x line pick pipeline (edge picking) — reuses pick_vertex; fragment emits kind=1.
        self.pickLinePipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_line", library: library,
            vertexFunction: "pick_vertex", fragmentFunction: "pick_line_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDesc)

        // 1x arc pick pipeline (issue #48) — reuses pick_vertex; fragment emits
        // kind=1 with the per-draw arc index.
        self.pickArcPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_arc", library: library,
            vertexFunction: "pick_vertex", fragmentFunction: "pick_arc_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDesc)

        // 1x point pick pipeline (vertex picking) — pick_point_vertex outputs
        // point_size for clickable footprint; fragment emits kind=2.
        self.pickPointPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_point", library: library,
            vertexFunction: "pick_point_vertex", fragmentFunction: "pick_point_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDesc)

        self.visiblePointPipeline = RendererSharedSetup.makeVisiblePointPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, label: "visible_point")

        // Depth-only pipeline (for SSAO depth pass — no color attachments)
        guard
            let depthOnlyPipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "depth_only", library: library,
                vertexFunction: "depth_only_vertex", fragmentFunction: "depth_only_fragment",
                depthPixelFormat: .depth32Float, vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.depthOnlyPipeline = depthOnlyPipeline

        // Direct-mesh depth-only pipeline (Option A): same depth shaders, two-buffer descriptor.
        guard
            let depthOnlyDirectPipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "depth_only_direct", library: library,
                vertexFunction: "depth_only_vertex", fragmentFunction: "depth_only_fragment",
                depthPixelFormat: .depth32Float, vertexDescriptor: directVertexDesc)
        else {
            return nil
        }
        self.depthOnlyDirectPipeline = depthOnlyDirectPipeline

        // Shadow map pipeline (depth-only from light perspective)
        guard
            let shadowPipeline = RendererSharedSetup.makeShadowPipelineState(
                device: device, library: library, vertexDescriptor: vertexDesc,
                label: "shadow_map")
        else {
            return nil
        }
        self.shadowPipeline = shadowPipeline

        // Direct-mesh shadow pipeline (Option A): same shadow shaders, two-buffer descriptor.
        guard
            let shadowDirectPipeline = RendererSharedSetup.makeShadowPipelineState(
                device: device, library: library, vertexDescriptor: directVertexDesc,
                label: "shadow_map_direct")
        else {
            return nil
        }
        self.shadowDirectPipeline = shadowDirectPipeline
        self.shadowMapManager = ShadowMapManager(device: device)

        // Selection outline pipeline (MSAA, renders expanded geometry where stencil != 1)
        guard
            let outlinePipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "selection_outline", library: library,
                vertexFunction: "selection_outline_vertex",
                fragmentFunction: "selection_outline_fragment",
                colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
                stencilPixelFormat: depthFormat, sampleCount: sampleCount,
                blending: .sourceAlphaColorOnly, vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.outlinePipeline = outlinePipeline

        // Highlight pipeline (per-triangle style buffer; alpha-composite over base shading)
        guard
            let highlightPipeline = RendererSharedSetup.makePipelineState(
                device: device, label: "triangle_highlight", library: library,
                vertexFunction: "highlight_vertex", fragmentFunction: "highlight_fragment",
                colorPixelFormat: .bgra8Unorm, depthPixelFormat: depthFormat,
                stencilPixelFormat: depthFormat, sampleCount: sampleCount,
                blending: .sourceAlpha, vertexDescriptor: vertexDesc)
        else {
            return nil
        }
        self.highlightPipeline = highlightPipeline

        // --- Hardware tessellation pipelines (PN triangles) ---
        let quality = controller.configuration.renderingQuality
        let wantsTessellation = quality == .enhanced || quality == .maximum

        if wantsTessellation,
            let tessMgr = TessellationManager(device: device, library: library)
        {
            self.tessellationManager = tessMgr
            let maxTessFactor = controller.configuration.tessellationMaxFactor

            // Helper to configure tessellation on a pipeline descriptor
            func configureTessellation(_ desc: MTLRenderPipelineDescriptor) {
                desc.maxTessellationFactor = maxTessFactor
                desc.tessellationFactorStepFunction = .perPatch
                desc.tessellationPartitionMode = .fractionalEven
                desc.tessellationFactorFormat = .half
                desc.tessellationOutputWindingOrder = .counterClockwise
                desc.vertexDescriptor = nil  // No vertex descriptor for tessellation
            }

            // Tessellated shaded pipeline
            let tsDesc = MTLRenderPipelineDescriptor()
            tsDesc.label = "tessellated_shaded"
            tsDesc.vertexFunction = library.makeFunction(name: "tessellated_vertex")
            tsDesc.fragmentFunction = library.makeFunction(name: "shaded_fragment")
            tsDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            tsDesc.colorAttachments[1].pixelFormat = .invalid
            // Per-body surface transparency (issue #53).
            tsDesc.colorAttachments[0].isBlendingEnabled = true
            tsDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            tsDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            tsDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            tsDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            tsDesc.depthAttachmentPixelFormat = depthFormat
            tsDesc.stencilAttachmentPixelFormat = depthFormat
            tsDesc.rasterSampleCount = sampleCount
            configureTessellation(tsDesc)

            var diagErrors: [String] = []
            // Check if shader functions were found
            if tsDesc.vertexFunction == nil {
                diagErrors.append("tessellated_vertex function NOT FOUND")
            }

            do {
                self.tessellatedShadedPipeline = try device.makeRenderPipelineState(
                    descriptor: tsDesc)
            } catch {
                self.tessellatedShadedPipeline = nil
                diagErrors.append("shaded: \(error.localizedDescription)")
            }

            // Tessellated shadow pipeline
            let tshDesc = MTLRenderPipelineDescriptor()
            tshDesc.label = "tessellated_shadow"
            tshDesc.vertexFunction = library.makeFunction(name: "tessellated_shadow_vertex")
            tshDesc.fragmentFunction = library.makeFunction(name: "depth_only_fragment")
            tshDesc.depthAttachmentPixelFormat = .depth32Float
            tshDesc.rasterSampleCount = 1
            configureTessellation(tshDesc)
            do {
                self.tessellatedShadowPipeline = try device.makeRenderPipelineState(
                    descriptor: tshDesc)
            } catch {
                self.tessellatedShadowPipeline = nil
                diagErrors.append("shadow: \(error.localizedDescription)")
            }

            // Tessellated depth-only pipeline (SSAO)
            let tdDesc = MTLRenderPipelineDescriptor()
            tdDesc.label = "tessellated_depth_only"
            tdDesc.vertexFunction = library.makeFunction(name: "tessellated_depth_vertex")
            tdDesc.fragmentFunction = library.makeFunction(name: "depth_only_fragment")
            tdDesc.depthAttachmentPixelFormat = .depth32Float
            tdDesc.rasterSampleCount = 1
            configureTessellation(tdDesc)
            do {
                self.tessellatedDepthOnlyPipeline = try device.makeRenderPipelineState(
                    descriptor: tdDesc)
            } catch {
                self.tessellatedDepthOnlyPipeline = nil
                diagErrors.append("depth: \(error.localizedDescription)")
            }

            // Tessellated pick pipeline
            let tpDesc = MTLRenderPipelineDescriptor()
            tpDesc.label = "tessellated_pick"
            tpDesc.vertexFunction = library.makeFunction(name: "tessellated_pick_vertex")
            tpDesc.fragmentFunction = library.makeFunction(name: "tessellated_pick_fragment")
            tpDesc.colorAttachments[0].pixelFormat = .r32Uint
            tpDesc.depthAttachmentPixelFormat = .depth32Float
            tpDesc.rasterSampleCount = 1
            configureTessellation(tpDesc)
            do {
                self.tessellatedPickPipeline = try device.makeRenderPipelineState(
                    descriptor: tpDesc)
            } catch {
                self.tessellatedPickPipeline = nil
                diagErrors.append("pick: \(error.localizedDescription)")
            }

            self.tessellationEnabled = tessellatedShadedPipeline != nil

            #if DEBUG
                let diagMsg: String
                if diagErrors.isEmpty {
                    diagMsg = """
                        OK: shaded=\(tessellatedShadedPipeline != nil) \
                        shadow=\(tessellatedShadowPipeline != nil) \
                        depth=\(tessellatedDepthOnlyPipeline != nil) \
                        pick=\(tessellatedPickPipeline != nil)
                        """
                } else {
                    diagMsg = "ERRORS:\n" + diagErrors.joined(separator: "\n")
                }
                NSLog("[ViewportRenderer] Tessellation: %@", diagMsg)
            #endif
        } else {
            self.tessellationManager = nil
            self.tessellatedShadedPipeline = nil
            self.tessellatedShadowPipeline = nil
            self.tessellatedDepthOnlyPipeline = nil
            self.tessellatedPickPipeline = nil
            self.tessellationEnabled = false
            #if DEBUG
                NSLog("[ViewportRenderer] Tessellation disabled")
            #endif
        }

        // --- Mesh shader pipelines (Apple9+ / M3+ / A17+) ---
        let supportsMeshShaders = device.supportsFamily(.apple9)
        let wantsMeshShaders = quality == .maximum && supportsMeshShaders

        if wantsMeshShaders,
            let objectFunc = library.makeFunction(name: "meshlet_object"),
            let meshFunc = library.makeFunction(name: "meshlet_mesh"),
            let shadowMeshFunc = library.makeFunction(name: "meshlet_shadow_mesh"),
            let depthMeshFunc = library.makeFunction(name: "meshlet_depth_mesh"),
            let pickMeshFunc = library.makeFunction(name: "meshlet_pick_mesh")
        {

            // Helper to create mesh render pipeline
            func makeMeshPipeline(
                meshFn: MTLFunction,
                fragmentFn: MTLFunction?,
                colorFormat: MTLPixelFormat,
                depthFmt: MTLPixelFormat,
                stencilFmt: MTLPixelFormat = .invalid,
                samples: Int = 1,
                blend: Bool = false,
                label: String
            ) -> MTLRenderPipelineState? {
                let desc = MTLMeshRenderPipelineDescriptor()
                desc.label = label
                desc.objectFunction = objectFunc
                desc.meshFunction = meshFn
                desc.fragmentFunction = fragmentFn
                if colorFormat != .invalid {
                    desc.colorAttachments[0].pixelFormat = colorFormat
                    if blend {
                        // Per-body surface transparency (issue #53).
                        desc.colorAttachments[0].isBlendingEnabled = true
                        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    }
                }
                desc.depthAttachmentPixelFormat = depthFmt
                if stencilFmt != .invalid {
                    desc.stencilAttachmentPixelFormat = stencilFmt
                }
                desc.rasterSampleCount = samples
                desc.maxTotalThreadsPerObjectThreadgroup = 1
                desc.maxTotalThreadsPerMeshThreadgroup = 64
                return try? device.makeRenderPipelineState(descriptor: desc, options: []).0
            }

            let shadedFrag = library.makeFunction(name: "shaded_fragment")!
            let depthFrag = library.makeFunction(name: "depth_only_fragment")
            let pickFrag = library.makeFunction(name: "pick_fragment")

            self.meshShaderShadedPipeline = makeMeshPipeline(
                meshFn: meshFunc, fragmentFn: shadedFrag,
                colorFormat: .bgra8Unorm, depthFmt: depthFormat, stencilFmt: depthFormat,
                samples: sampleCount, blend: true, label: "mesh_shaded"
            )
            self.meshShaderShadowPipeline = makeMeshPipeline(
                meshFn: shadowMeshFunc, fragmentFn: depthFrag,
                colorFormat: .invalid, depthFmt: .depth32Float,
                label: "mesh_shadow"
            )
            self.meshShaderDepthOnlyPipeline = makeMeshPipeline(
                meshFn: depthMeshFunc, fragmentFn: depthFrag,
                colorFormat: .invalid, depthFmt: .depth32Float,
                label: "mesh_depth_only"
            )
            self.meshShaderPickPipeline = makeMeshPipeline(
                meshFn: pickMeshFunc, fragmentFn: pickFrag,
                colorFormat: .r32Uint, depthFmt: .depth32Float,
                label: "mesh_pick"
            )
            self.meshShadersEnabled = meshShaderShadedPipeline != nil
            #if DEBUG
                NSLog(
                    "[ViewportRenderer] Mesh shaders: %@",
                    meshShaderShadedPipeline != nil ? "enabled" : "FAILED")
            #endif
        } else {
            self.meshShaderShadedPipeline = nil
            self.meshShaderShadowPipeline = nil
            self.meshShaderDepthOnlyPipeline = nil
            self.meshShaderPickPipeline = nil
            self.meshShadersEnabled = false
            #if DEBUG
                NSLog("[ViewportRenderer] Mesh shaders: skipped (supports=%d)", supportsMeshShaders)
            #endif
        }

        // SSAO post-process pipeline (1x, renders to drawable).
        // Output goes directly to the MSAA resolve target (drawable), so sampleCount = 1,
        // and the fullscreen pass needs no depth attachment.
        self.ssaoPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "ssao_postprocess", library: library,
            vertexFunction: "fullscreen_vertex", fragmentFunction: "ssao_fragment",
            colorPixelFormat: .bgra8Unorm, depthPixelFormat: .invalid)

        // TAA resolve pipeline (1x fullscreen pass)
        self.taaPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "taa_resolve", library: library,
            vertexFunction: "fullscreen_vertex", fragmentFunction: "taa_resolve_fragment",
            colorPixelFormat: .bgra8Unorm, depthPixelFormat: .invalid)

        // Depth stencil state
        guard
            let depthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .less, isDepthWriteEnabled: true)
        else {
            return nil
        }
        self.depthState = depthState

        // Stencil write state: write reference value to stencil for selected bodies
        let stencilWriteDesc = MTLDepthStencilDescriptor()
        stencilWriteDesc.depthCompareFunction = .less
        stencilWriteDesc.isDepthWriteEnabled = true
        let writeStencil = MTLStencilDescriptor()
        writeStencil.stencilCompareFunction = .always
        writeStencil.depthStencilPassOperation = .replace
        writeStencil.stencilFailureOperation = .keep
        writeStencil.depthFailureOperation = .keep
        stencilWriteDesc.frontFaceStencil = writeStencil
        stencilWriteDesc.backFaceStencil = writeStencil

        guard let stencilWriteState = device.makeDepthStencilState(descriptor: stencilWriteDesc)
        else {
            return nil
        }
        self.stencilWriteState = stencilWriteState

        // Stencil test state: only draw where stencil != reference (the outline ring)
        let stencilTestDesc = MTLDepthStencilDescriptor()
        stencilTestDesc.depthCompareFunction = .always
        stencilTestDesc.isDepthWriteEnabled = false
        let testStencil = MTLStencilDescriptor()
        testStencil.stencilCompareFunction = .notEqual
        testStencil.stencilFailureOperation = .keep
        testStencil.depthStencilPassOperation = .keep
        testStencil.depthFailureOperation = .keep
        stencilTestDesc.frontFaceStencil = testStencil
        stencilTestDesc.backFaceStencil = testStencil

        guard let stencilTestState = device.makeDepthStencilState(descriptor: stencilTestDesc)
        else {
            return nil
        }
        self.stencilTestState = stencilTestState

        // Overlay depth state: always pass, no depth or stencil writes. Used for
        // RenderLayer.overlay bodies so they render on top of all geometry.
        guard
            let overlayDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .always, isDepthWriteEnabled: false)
        else {
            return nil
        }
        self.overlayDepthState = overlayDepthState

        // .lessEqual + write enabled — edges and points that lie on a face win
        // ties (face writes first with .less, edge/point overwrites at equal depth).
        guard
            let pickEdgeOrPointDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .lessEqual, isDepthWriteEnabled: true)
        else {
            return nil
        }
        self.pickEdgeOrPointDepthState = pickEdgeOrPointDepthState

        // .lessEqual + write disabled — for the highlight pass. Same geometry as
        // the shaded pass at the same positions; we want them to win the depth
        // tie without writing depth so subsequent passes aren't disturbed.
        guard
            let highlightDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .lessEqual, isDepthWriteEnabled: false)
        else {
            return nil
        }
        self.highlightDepthState = highlightDepthState

        // .less + write disabled — for the transparent surface pass (issue #53).
        // Transparent bodies test against the opaque depth buffer (so they hide
        // behind opaque geometry) but don't write depth, so back-to-front sorted
        // translucent surfaces composite without occluding each other in depth.
        guard
            let transparentSurfaceDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .less, isDepthWriteEnabled: false)
        else {
            return nil
        }
        self.transparentSurfaceDepthState = transparentSurfaceDepthState

        // Build axis vertex buffer (6 vertices for 3 lines)
        guard let axisVB = RendererSharedSetup.makeAxisVertexBuffer(device: device) else {
            return nil
        }
        self.axisVertexBuffer = axisVB

        // Generate procedural matcap texture (256x256 RGBA8)
        guard let matcap = RendererSharedSetup.makeMatcapTexture(device: device) else {
            return nil
        }
        self.matcapTexture = matcap

        // Picking: texture manager + 4-byte shared readback buffer
        self.pickTextureManager = PickTextureManager(device: device)
        guard
            let readback = device.makeBuffer(
                length: MemoryLayout<UInt32>.size, options: .storageModeShared)
        else {
            return nil
        }
        self.pickReadbackBuffer = readback

        // Environment map manager (IBL)
        self.environmentMapManager = EnvironmentMapManager(device: device, library: library)

        super.init()

        // Lets the controller forward performRegionPick(pixelRect:completion:) (issue #90)
        // to this renderer without the controller extending its lifetime — see
        // ViewportController.attachedRenderer.
        controller.attachedRenderer = self
    }

    // MARK: - Public

    /// The Metal device, exposed for MTKView configuration.
    public var metalDevice: MTLDevice { device }

    /// The renderer's command queue, shared with the off-screen readback path.
    var renderCommandQueue: MTLCommandQueue { commandQueue }

    /// MSAA sample count every colour pipeline in this renderer was built for.
    ///
    /// Off-screen targets must match it, or the main pass fails validation.
    var pipelineSampleCount: Int { msaaSampleCount }

    /// Loads an equirectangular HDR image as the environment map for IBL.
    ///
    /// Legacy path; expects raw bytes with `Int32 width | Int32 height | RGBA32Float pixels`.
    public func loadEnvironmentMap(data: Data) {
        environmentMapManager?.loadEquirectangular(data: data, commandQueue: commandQueue)
    }

    /// Loads an HDR environment map from a file URL (Radiance `.hdr`).
    ///
    /// Throws on parse failure; on success, generates the prefiltered/irradiance/cube maps.
    public func loadEnvironmentMap(url: URL) throws {
        try environmentMapManager?.loadHDR(url: url, commandQueue: commandQueue)
    }

    /// Loads pre-decoded equirectangular RGBA32Float pixels into the IBL pipeline.
    public func loadEnvironmentMap(width: Int, height: Int, pixels: [Float]) {
        environmentMapManager?.loadEquirectangular(
            width: width, height: height, pixels: pixels, commandQueue: commandQueue)
    }

    /// Clears the current environment map.
    public func clearEnvironmentMap() {
        environmentMapManager?.clear()
    }

    /// Invalidates cached buffers so they are rebuilt on next draw.
    public func invalidateBuffers() {
        bodyBufferCache.removeAll()
        bodyGeneration.removeAll()
    }

    // MARK: - MTKViewDelegate

    nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled in draw via drawable size
    }

    nonisolated public func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            drawOnMainActor(in: view)
        }
    }

    // MARK: - Draw

    /// Ensures 1x resolved color + depth textures for SSAO input.
    private func ensureResolvedTextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != resolvedWidth || height != resolvedHeight else { return }

        // 1x color texture that receives the MSAA resolve output
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        resolvedColorTexture = device.makeTexture(descriptor: colorDesc)

        // 1x depth texture for SSAO depth sampling
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        depthDesc.usage = [.renderTarget, .shaderRead]
        depthDesc.storageMode = .private
        resolvedDepthTexture = device.makeTexture(descriptor: depthDesc)

        resolvedWidth = width
        resolvedHeight = height
    }

    /// Ensures TAA history + output textures exist at the given size.
    private func ensureTAATextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if let existing = taaHistoryTexture, existing.width == width, existing.height == height {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private

        taaHistoryTexture = device.makeTexture(descriptor: desc)
        taaOutputTexture = device.makeTexture(descriptor: desc)
        taaFrameIndex = 0
    }

    /// Halton sequence value for sub-pixel jitter.
    private func halton(index: UInt32, base: UInt32) -> Float {
        var f: Float = 1.0
        var r: Float = 0.0
        var i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r
    }

    /// Ensures the 1x depth texture for the pick pass matches the given size.
    private func ensurePickDepthTexture(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != pickDepthWidth || height != pickDepthHeight else { return }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        desc.sampleCount = 1

        pickDepthTexture = device.makeTexture(descriptor: desc)
        pickDepthWidth = width
        pickDepthHeight = height
    }

    private func drawOnMainActor(in view: MTKView) {
        guard controller != nil else { return }
        guard let drawable = view.currentDrawable,
            let renderPassDescriptor = view.currentRenderPassDescriptor
        else { return }

        encodeFrame(
            into: FrameRenderTargets(
                mainPassDescriptor: renderPassDescriptor,
                finalColorTexture: drawable.texture,
                size: view.drawableSize,
                presentable: drawable
            ))
    }

    /// Encodes one complete frame — every pass `draw(in:)` runs — into `targets`.
    ///
    /// The live path and the off-screen path (`renderHeadless(...)`) both go through here, so the
    /// two can never drift apart in the way a parallel headless implementation would.
    func encodeFrame(into targets: FrameRenderTargets) {
        guard let controller = controller else { return }
        let renderPassDescriptor = targets.mainPassDescriptor

        let cameraState = controller.cameraState
        let drawableSize = targets.size
        lastDrawableSize = drawableSize
        let aspectRatio = Float(drawableSize.width / drawableSize.height)

        let viewMatrix = cameraState.viewMatrix

        // Scene-adaptive clip planes (issue #57): fit near/far to the visible
        // geometry so hyperbolic depth precision isn't crushed by a fixed
        // 0.01/10000 range. Uses the cached per-body AABBs (from the previous
        // frame on the first frame — bounds change slowly, so that's fine).
        var sceneBounds: BoundingBox? = nil
        for body in bodiesBinding.wrappedValue where body.isVisible && body.renderLayer == .geometry
        {
            guard let localBox = bodyBufferCache[body.id]?.localBoundingBox else { continue }
            let worldBox = localBox.transformed(by: body.transform)
            sceneBounds = sceneBounds.map { $0.union(worldBox) } ?? worldBox
        }
        let clip = cameraState.clipPlanes(sceneBounds: sceneBounds)

        var projMatrix = cameraState.projectionMatrix(
            aspectRatio: aspectRatio, near: clip.near, far: clip.far)

        // TAA / progressive accumulation: apply Halton(2,3) sub-pixel jitter to the
        // projection matrix so each frame rasterizes at a different sub-pixel offset.
        // Without this, the existing TAA resolve only softens — it doesn't supersample.
        // We must compute the jitter here (pre-draw) to use the same value in the
        // TAA resolve pass below.
        let taaWillRun = controller.enableTAA && taaPipeline != nil
        let jitterPx: SIMD2<Float>
        if taaWillRun {
            let jx = halton(index: taaFrameIndex + 1, base: 2) - 0.5
            let jy = halton(index: taaFrameIndex + 1, base: 3) - 0.5
            jitterPx = SIMD2<Float>(jx, jy)
            // Convert pixel offset to NDC and bake into the projection matrix's column 2.
            // For both perspective and orthographic, this shifts the rasterized image
            // by (jx, jy) pixels post-projection.
            let w = Float(drawableSize.width)
            let h = Float(drawableSize.height)
            projMatrix.columns.2[0] += 2.0 * jx / w
            projMatrix.columns.2[1] += 2.0 * jy / h
        } else {
            jitterPx = .zero
        }

        let viewProjection = projMatrix * viewMatrix

        let lighting = controller.lightingConfiguration

        let nearPlane: Float = clip.near
        let farPlane: Float = clip.far

        // Debug toggles
        let useTessellation = tessellationEnabled && !controller.debugDisableTessellation
        let useMeshShaders = meshShadersEnabled && !controller.debugDisableTessellation

        // Shadow mapping: compute light VP matrix from key light direction
        let shadowEnabled = lighting.shadowsEnabled
        let lightVP: simd_float4x4
        if shadowEnabled {
            // Local (untransformed) bounds, which is what this pass has always fitted the light
            // frustum to — see `RendererSharedSetup.sceneBounds(of:applyingTransforms:)`.
            lightVP = RendererSharedSetup.lightViewProjection(
                lightDirection: lighting.keyLight.direction,
                sceneBounds: RendererSharedSetup.sceneBounds(
                    of: bodiesBinding.wrappedValue, applyingTransforms: false)
            )
        } else {
            lightVP = matrix_identity_float4x4
        }
        let edgeIntensity = controller.edgeIntensity
        let shadowParams = SIMD4<Float>(
            lighting.shadowBias,
            lighting.shadowIntensity,
            shadowEnabled ? 1.0 : 0.0,
            edgeIntensity
        )

        // Collect active clip planes (up to 4)
        let activeClipPlanes = Array(controller.clipPlanes.filter { $0.isEnabled }.prefix(4))
        let clipPlaneVecs: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = {
            var planes: [SIMD4<Float>] = activeClipPlanes.map { $0.asFloat4 }
            while planes.count < 4 { planes.append(.zero) }
            return (planes[0], planes[1], planes[2], planes[3])
        }()
        let clipPlaneCount = UInt32(activeClipPlanes.count)

        let shadowParams2 = SIMD4<Float>(
            lighting.shadowLightSize,
            lighting.shadowSearchRadius,
            controller.debugDisableCurvature ? 1.0 : 0.0,
            0
        )

        let hasEnvMap: Float = (environmentMapManager?.hasEnvironmentMap ?? false) ? 1.0 : 0.0
        let iblParams = SIMD4<Float>(
            lighting.environmentIntensity,
            lighting.environmentRotationY,
            lighting.backgroundExposure,
            hasEnvMap
        )

        func makeUniforms() -> Uniforms {
            Uniforms(
                viewProjection: viewProjection,
                viewMatrix: viewMatrix,
                cameraPosition: cameraState.position,
                nearPlane: nearPlane,
                farPlane: farPlane,
                lighting: lighting,
                lightViewProjection: lightVP,
                shadowParams: shadowParams,
                shadowParams2: shadowParams2,
                iblParams: iblParams,
                clipPlanes: clipPlaneVecs,
                clipPlaneCount: clipPlaneCount,
                unlit: controller.displayMode == .unlit
            )
        }

        let bodies = bodiesBinding.wrappedValue
        let displayMode = controller.displayMode

        // Build index map for picking: objectIndex → bodyID
        var indexMap: [Int: String] = [:]
        var layerMap: [String: PickLayer] = [:]
        var objectIndex: UInt32 = 0

        // Ensure buffers for all visible bodies, and resolve each body's buffers +
        // stable pick index ONCE per frame (issue #42 part 3). The main draw pass
        // iterates this list instead of re-filtering `bodies` and re-hashing the
        // String-keyed `bodyBufferCache[body.id]` every pass.
        var frameVisibleBodies: [(body: ViewportBody, buffers: BodyBuffers, objectIndex: UInt32)] =
            []
        frameVisibleBodies.reserveCapacity(bodies.count)
        for body in bodies where body.isVisible {
            ensureBuffers(for: body)
            indexMap[Int(objectIndex)] = body.id
            layerMap[body.id] = body.pickLayer
            if let bufs = bodyBufferCache[body.id] {
                frameVisibleBodies.append((body, bufs, objectIndex))
            }
            objectIndex += 1
        }
        currentIndexMap = indexMap
        currentLayerMap = layerMap

        // Per-body frustum culling (issue #42): off-screen bodies are skipped
        // inline in the main pass below, using the cached local AABB — no per-frame
        // Set / extra String hashing. The shadow pass is intentionally not
        // camera-culled (off-screen casters can shadow visible geometry); bodies
        // with no bounds are never culled.
        let cullFrustum: Frustum? =
            controller.configuration.enableFrustumCulling
            ? Frustum(viewProjection: viewProjection)
            : nil

        let silhouettesEnabled = controller.configuration.enableSilhouettes
        // Unlit mode bypasses the SSAO/tone-map composite pass entirely so diagnostic
        // colours are never desaturated by ACES tone mapping (issue #77).
        let ssaoEnabled =
            (lighting.enableSSAO || silhouettesEnabled) && ssaoPipeline != nil
            && displayMode.showsSurfaces && displayMode != .unlit
        let taaEnabled = controller.enableTAA && taaPipeline != nil
        let w = Int(drawableSize.width)
        let h = Int(drawableSize.height)

        if ssaoEnabled || taaEnabled {
            ensureResolvedTextures(width: w, height: h)
        }
        if taaEnabled {
            ensureTAATextures(width: w, height: h)
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // =========================================================
        // Pre-pass: Update tessellation factors (per-frame, camera-dependent)
        // =========================================================
        if useTessellation, let tessMgr = tessellationManager {
            var tessBufferList: [(TessellationBuffers, simd_float4x4)] = []
            var tessBodyCount = 0
            var nonTessBodyCount = 0
            for body in bodies where body.isVisible {
                if let buffers = bodyBufferCache[body.id] {
                    if let tess = buffers.tessellation {
                        tessBufferList.append((tess, matrix_identity_float4x4))
                        tessBodyCount += 1
                    } else if buffers.indexCount > 0 {
                        nonTessBodyCount += 1
                    }
                }
            }
            // One-time diagnostic log, guarded so it can't repeat every frame.
            #if DEBUG
                if tessBufferList.isEmpty, nonTessBodyCount > 0, !didLogMissingTessellationData {
                    didLogMissingTessellationData = true
                    NSLog(
                        "[ViewportRenderer] WARNING: %d bodies have no tessellation data",
                        nonTessBodyCount)
                }
            #endif
            if !tessBufferList.isEmpty,
                let computeEncoder = commandBuffer.makeComputeCommandEncoder()
            {
                let config = controller.configuration
                tessMgr.updateTessFactors(
                    tessBuffers: tessBufferList,
                    viewProjectionMatrix: viewProjection,
                    viewportSize: SIMD2<Float>(Float(w), Float(h)),
                    targetEdgePixels: config.adaptiveTessellation ? 4.0 : 1.0,
                    maxFactor: Float(config.tessellationMaxFactor),
                    encoder: computeEncoder
                )
                computeEncoder.endEncoding()
            }
        }

        // =========================================================
        // Pass 0: Shadow map (if enabled)
        // =========================================================
        if shadowEnabled {
            let mapSize = lighting.shadowMapSize
            shadowMapManager.ensureSize(mapSize)

            if let shadowTex = shadowMapManager.texture {
                let shadowPass = MTLRenderPassDescriptor()
                shadowPass.depthAttachment.texture = shadowTex
                shadowPass.depthAttachment.loadAction = .clear
                shadowPass.depthAttachment.storeAction = .store
                shadowPass.depthAttachment.clearDepth = 1.0

                if let shadowEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: shadowPass)
                {
                    shadowEncoder.setDepthStencilState(depthState)
                    shadowEncoder.setCullMode(.front)  // Reduce shadow acne with front-face culling
                    shadowEncoder.setDepthBias(0.01, slopeScale: 1.5, clamp: 0.02)

                    for body in bodies where body.isVisible {
                        guard let buffers = bodyBufferCache[body.id] else { continue }
                        // Overlay bodies don't cast shadows — they are UI affordances.
                        if body.renderLayer == .overlay { continue }
                        // Direct-mesh bodies cast shadows via shadowDirectPipeline (handled in the
                        // standard draw branch below), so they are NOT excluded here.
                        let hasMesh =
                            buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                            && buffers.indexCount > 0

                        if hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer {
                            var shadowUniforms = ShadowUniformsSwift(
                                lightViewProjectionMatrix: lightVP,
                                modelMatrix: body.transform
                            )

                            if useMeshShaders, let ml = buffers.meshlets,
                                let msPipeline = meshShaderShadowPipeline
                            {
                                shadowEncoder.setRenderPipelineState(msPipeline)
                                shadowEncoder.setObjectBuffer(
                                    ml.descriptorBuffer, offset: 0, index: 0)
                                shadowEncoder.setObjectBytes(
                                    &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size,
                                    index: 1)
                                shadowEncoder.setMeshBuffer(
                                    ml.descriptorBuffer, offset: 0, index: 0)
                                shadowEncoder.setMeshBuffer(vb, offset: 0, index: 1)
                                shadowEncoder.setMeshBuffer(
                                    ml.vertexIndexBuffer, offset: 0, index: 2)
                                shadowEncoder.setMeshBuffer(
                                    ml.triangleIndexBuffer, offset: 0, index: 3)
                                shadowEncoder.setMeshBytes(
                                    &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size,
                                    index: 4)
                                shadowEncoder.drawMeshThreadgroups(
                                    MTLSize(width: ml.meshletCount, height: 1, depth: 1),
                                    threadsPerObjectThreadgroup: MTLSize(
                                        width: 1, height: 1, depth: 1),
                                    threadsPerMeshThreadgroup: MTLSize(
                                        width: 64, height: 1, depth: 1)
                                )
                            } else if useTessellation, let tess = buffers.tessellation,
                                let tessPipeline = tessellatedShadowPipeline
                            {
                                shadowEncoder.setRenderPipelineState(tessPipeline)
                                shadowEncoder.setTessellationFactorBuffer(
                                    tess.tessFactorBuffer, offset: 0, instanceStride: 0)
                                shadowEncoder.setVertexBuffer(
                                    tess.patchDataBuffer, offset: 0, index: 0)
                                shadowEncoder.setVertexBytes(
                                    &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size,
                                    index: 1)
                                shadowEncoder.drawPatches(
                                    numberOfPatchControlPoints: 3,
                                    patchStart: 0,
                                    patchCount: tess.patchCount,
                                    patchIndexBuffer: nil,
                                    patchIndexBufferOffset: 0,
                                    instanceCount: 1,
                                    baseInstance: 0
                                )
                            } else {
                                if let nb = buffers.normalBuffer {
                                    // Direct-mesh body (Option A): position@0 + normal@2.
                                    shadowEncoder.setRenderPipelineState(shadowDirectPipeline)
                                    shadowEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                    shadowEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                                } else {
                                    shadowEncoder.setRenderPipelineState(shadowPipeline)
                                    shadowEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                }
                                shadowEncoder.setVertexBytes(
                                    &shadowUniforms, length: MemoryLayout<ShadowUniformsSwift>.size,
                                    index: 1)
                                shadowEncoder.drawIndexedPrimitives(
                                    type: .triangle,
                                    indexCount: buffers.indexCount,
                                    indexType: .uint32,
                                    indexBuffer: ib,
                                    indexBufferOffset: 0
                                )
                            }
                        }
                    }
                    shadowEncoder.endEncoding()
                }
            }
        }

        // =========================================================
        // Pass 1: Main MSAA render (color-only, no pick texture)
        // =========================================================
        renderPassDescriptor.colorAttachments[1].texture = nil

        // When SSAO or TAA is enabled, redirect MSAA resolve to our intermediate texture
        if ssaoEnabled || taaEnabled, let resolvedColor = resolvedColorTexture {
            if msaaSampleCount > 1 {
                renderPassDescriptor.colorAttachments[0].resolveTexture = resolvedColor
            } else {
                // No MSAA: render directly to resolved color texture
                renderPassDescriptor.colorAttachments[0].texture = resolvedColor
            }
        }

        guard
            let mainEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor)
        else { return }
        mainEncoder.setDepthStencilState(depthState)

        // 0. Draw skybox background (HDR cubemap), if enabled.
        if lighting.drawBackground,
            let envMgr = environmentMapManager,
            let cubeMap = envMgr.cubeMap,
            let skyPipeline = skyboxPipeline,
            let skyDepth = skyboxDepthState
        {
            mainEncoder.setRenderPipelineState(skyPipeline)
            mainEncoder.setDepthStencilState(skyDepth)
            var skyUniforms = SkyboxUniformsSwift(
                inverseViewProjection: simd_inverse(viewProjection),
                params: SIMD4<Float>(
                    lighting.environmentRotationY,
                    lighting.backgroundExposure,
                    0,  // mip level — sharp background
                    0
                )
            )
            mainEncoder.setVertexBytes(
                &skyUniforms, length: MemoryLayout<SkyboxUniformsSwift>.size, index: 0)
            mainEncoder.setFragmentBytes(
                &skyUniforms, length: MemoryLayout<SkyboxUniformsSwift>.size, index: 0)
            mainEncoder.setFragmentTexture(cubeMap, index: 0)
            mainEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            mainEncoder.setDepthStencilState(depthState)
        }

        // 1. Draw grid
        if controller.showGrid {
            let config = controller.configuration
            RendererSharedSetup.encodeGrid(
                encoder: mainEncoder,
                pipeline: gridPipeline,
                viewProjection: viewProjection,
                cameraState: cameraState,
                baseSpacing: config.gridBaseSpacing,
                subdivisions: config.gridSubdivisions
            )
        }

        // 2. Draw axes
        if controller.showAxes {
            RendererSharedSetup.encodeAxes(
                encoder: mainEncoder,
                pipeline: axisPipeline,
                vertexBuffer: axisVertexBuffer,
                viewProjection: viewProjection
            )
        }

        // 3. Draw bodies
        let selectedIDs = controller.selectedBodyIDs
        let hoveredID = controller.hoveredBodyID

        // Transparent surfaces (issue #53) are deferred to a sorted back-to-front
        // pass after the opaque bodies, so they composite correctly.
        var transparentDraws: [(body: ViewportBody, buffers: BodyBuffers, objectIndex: UInt32)] = []

        for (body, buffers, bodyObjectIndex) in frameVisibleBodies {
            // Frustum-cull off-screen geometry inline using the cached local AABB.
            // Pick IDs stay stable: bodyObjectIndex was assigned over all visible
            // bodies, independent of culling.
            if let cullFrustum, body.renderLayer == .geometry,
                let localBox = buffers.localBoundingBox,
                !cullFrustum.intersects(localBox.transformed(by: body.transform))
            {
                continue
            }
            // Overlay bodies are drawn after the selection outline, in their own pass.
            if body.renderLayer == .overlay { continue }
            // Point-cloud bodies are drawn in the dedicated visible-point pass
            // below — skip the mesh + wireframe paths so a `.point` body that
            // happens to also carry stray vertexData/edges doesn't double-draw.
            if body.primitiveKind == .point { continue }
            // Translucent geometry bodies are deferred to the sorted transparent
            // pass below (a body with edges only — no mesh — is unaffected).
            if body.renderLayer == .geometry,
                body.effectiveMaterial.opacity < 1.0,
                buffers.vertexBuffer != nil, buffers.indexCount > 0
            {
                transparentDraws.append((body, buffers, bodyObjectIndex))
                continue
            }

            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform

            let selState: UInt32 =
                selectedIDs.contains(body.id) ? 1 : (hoveredID == body.id ? 2 : 0)
            var bodyUniforms = BodyUniforms(
                body: body, objectIndex: bodyObjectIndex, isSelected: selState)

            // Main opaque pass — direct-mesh bodies ARE rendered here (encodeShadedSurface picks
            // the directMeshPipeline when normalBuffer is set). The shadow / pick / depth / overlay
            // passes above & below now route direct bodies through their own *Direct pipelines
            // (two-buffer descriptor: position@0 / normal@2) rather than skipping them.
            let hasMesh =
                buffers.vertexBuffer != nil && buffers.indexBuffer != nil && buffers.indexCount > 0
            let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0

            // Shaded pass (mesh bodies only)
            if displayMode.showsSurfaces, hasMesh {
                // Write stencil=1 for selected bodies
                if selState > 0 {
                    mainEncoder.setDepthStencilState(stencilWriteState)
                    mainEncoder.setStencilReferenceValue(1)
                } else {
                    mainEncoder.setDepthStencilState(depthState)
                }

                // Set shared fragment state (same for tessellated and non-tessellated)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.setFragmentTexture(matcapTexture, index: 0)
                if shadowEnabled, let shadowTex = shadowMapManager.texture {
                    mainEncoder.setFragmentTexture(shadowTex, index: 1)
                }
                if let envMgr = environmentMapManager, envMgr.hasEnvironmentMap {
                    if let spec = envMgr.prefilteredSpecularMap {
                        mainEncoder.setFragmentTexture(spec, index: 2)
                    }
                    if let diff = envMgr.irradianceMap {
                        mainEncoder.setFragmentTexture(diff, index: 3)
                    }
                    if let brdf = envMgr.brdfLUT { mainEncoder.setFragmentTexture(brdf, index: 4) }
                }

                encodeShadedSurface(
                    mainEncoder, buffers: buffers, uniforms: &uniforms,
                    useMeshShaders: useMeshShaders, useTessellation: useTessellation)
            }

            // Wireframe/edge pass
            let shouldDrawEdges = hasEdges && (displayMode.showsEdges || !hasMesh)
            if shouldDrawEdges, let edgeVB = buffers.edgeVertexBuffer {
                // For edge-only bodies, signal the shader to use the body color directly
                // instead of contrast-adaptive edge color (metallic = -1 sentinel)
                var edgeBodyUniforms = bodyUniforms
                if !hasMesh {
                    edgeBodyUniforms.metallic = -1.0
                }
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

        // 3.3 Transparent surface pass (issue #53): draw the deferred translucent
        // bodies back-to-front with depth-test on / write off, so they composite
        // over the opaque set (and over each other in sorted order).
        if displayMode.showsSurfaces, !transparentDraws.isEmpty {
            let camPos = cameraState.position
            func centerDistanceSq(
                _ d: (body: ViewportBody, buffers: BodyBuffers, objectIndex: UInt32)
            ) -> Float {
                let localCenter = d.buffers.localBoundingBox?.center ?? SIMD3<Float>(0, 0, 0)
                let c = d.body.transform * SIMD4<Float>(localCenter, 1)
                return simd_length_squared(SIMD3<Float>(c.x, c.y, c.z) - camPos)
            }
            let sorted = transparentDraws.sorted { centerDistanceSq($0) > centerDistanceSq($1) }

            mainEncoder.setDepthStencilState(transparentSurfaceDepthState)
            mainEncoder.setFragmentTexture(matcapTexture, index: 0)
            if shadowEnabled, let shadowTex = shadowMapManager.texture {
                mainEncoder.setFragmentTexture(shadowTex, index: 1)
            }
            if let envMgr = environmentMapManager, envMgr.hasEnvironmentMap {
                if let spec = envMgr.prefilteredSpecularMap {
                    mainEncoder.setFragmentTexture(spec, index: 2)
                }
                if let diff = envMgr.irradianceMap {
                    mainEncoder.setFragmentTexture(diff, index: 3)
                }
                if let brdf = envMgr.brdfLUT { mainEncoder.setFragmentTexture(brdf, index: 4) }
            }
            for d in sorted {
                var uniforms = makeUniforms()
                uniforms.modelMatrix = d.body.transform
                var bodyUniforms = BodyUniforms(
                    body: d.body, objectIndex: d.objectIndex, isSelected: 0)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                encodeShadedSurface(
                    mainEncoder, buffers: d.buffers, uniforms: &uniforms,
                    useMeshShaders: useMeshShaders, useTessellation: useTessellation)
            }
        }

        // 3.35 Analytic arc edge pass (issue #48).
        // Adaptively samples each visible body's `arcs` to line segments by their
        // projected size, so circular feature edges stay smooth at any zoom
        // independent of mesh density. Per-arc segment ranges are recorded in
        // `frameArcDraws` and the data lives in `arcLineBuffer`, so the pick pass
        // below re-draws the same segments to the pick texture without re-sampling.
        var frameArcDraws:
            [(body: ViewportBody, objectIndex: UInt32, arcIndex: Int, start: Int, count: Int)] = []
        let arcBodies = frameVisibleBodies.filter { !$0.body.arcs.isEmpty }
        if !arcBodies.isEmpty {
            let vpSize = SIMD2<Float>(Float(w), Float(h))
            var arcVerts: [Float] = []
            for entry in arcBodies {
                // Match the edge-pass visibility rule: show feature edges when the
                // display mode draws edges, or when the body is edge-only.
                let bodyHasMesh = entry.buffers.indexCount > 0
                guard displayMode.showsEdges || !bodyHasMesh else { continue }

                let mvp = viewProjection * entry.body.transform
                for (arcIndex, arc) in entry.body.arcs.enumerated() {
                    let segs = ArcSampling.segmentCount(arc: arc, mvp: mvp, viewportSize: vpSize)
                    let startVert = arcVerts.count / 6
                    var prev = arc.point(at: 0)
                    for s in 1...segs {
                        let cur = arc.point(at: Float(s) / Float(segs))
                        arcVerts.append(contentsOf: [
                            prev.x, prev.y, prev.z, 0, 0, 0,
                            cur.x, cur.y, cur.z, 0, 0, 0,
                        ])
                        prev = cur
                    }
                    let count = arcVerts.count / 6 - startVert
                    if count > 0 {
                        frameArcDraws.append(
                            (entry.body, entry.objectIndex, arcIndex, startVert, count))
                    }
                }
            }

            if !arcVerts.isEmpty,
                let arcBuf = ensureArcBuffer(byteCount: arcVerts.count * MemoryLayout<Float>.size)
            {
                arcVerts.withUnsafeBytes { raw in
                    arcBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
                mainEncoder.setRenderPipelineState(wireframePipeline)
                mainEncoder.setVertexBuffer(arcBuf, offset: 0, index: 0)
                for d in frameArcDraws {
                    let bodyHasMesh = (bodyBufferCache[d.body.id]?.indexCount ?? 0) > 0
                    var uniforms = makeUniforms()
                    uniforms.modelMatrix = d.body.transform
                    var arcBodyUniforms = BodyUniforms(
                        body: d.body, objectIndex: d.objectIndex, isSelected: 0)
                    if !bodyHasMesh { arcBodyUniforms.metallic = -1.0 }  // use body colour directly
                    mainEncoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &arcBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    mainEncoder.drawPrimitives(
                        type: .line, vertexStart: d.start, vertexCount: d.count)
                }
            }
        }

        // 3.4 Point-cloud pass (issue #28).
        // Walks bodies whose primitiveKind is .point and draws their
        // `vertices` as MTL point primitives with a world-space radius
        // projected to a clamped [[point_size]]. Premultiplied-alpha
        // blending lets per-point colours composite over earlier geometry.
        let hasPointBodies = bodies.contains { body in
            body.isVisible
                && body.renderLayer == .geometry
                && body.primitiveKind == .point
                && (bodyBufferCache[body.id]?.pointPositionBuffer != nil)
        }
        if hasPointBodies, let pointPipeline = visiblePointPipeline {
            // pxPerWorldFactor = viewportHeight * projection[1][1] / 2
            // — see Shaders.metal `visible_point_vertex` for derivation.
            let pxPerWorldFactor = Float(drawableSize.height) * projMatrix.columns.1.y * 0.5
            mainEncoder.setRenderPipelineState(pointPipeline)
            mainEncoder.setDepthStencilState(depthState)
            for body in bodies
            where body.isVisible && body.renderLayer == .geometry && body.primitiveKind == .point {
                guard let buffers = bodyBufferCache[body.id],
                    let positionBuf = buffers.pointPositionBuffer,
                    buffers.pointVertexCount > 0
                else { continue }

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
                    // Bind the position buffer as a benign placeholder so the
                    // shader's `vertexColors` argument is non-null on devices
                    // that validate buffer bindings.
                    mainEncoder.setVertexBuffer(positionBuf, offset: 0, index: 1)
                }
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                mainEncoder.setVertexBytes(
                    &params, length: MemoryLayout<PointParamsSwift>.size, index: 3)

                mainEncoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
            }
        }

        // 3.5 Per-triangle highlight pass (issue #25).
        // For every visible body that has a triangleStyleBuffer, draw with the
        // highlight pipeline. The shader discards triangles with alpha == 0,
        // so this is cheap on bodies with sparse highlight maps.
        // .lessEqual + depth-write-off keeps depth state untouched for outline.
        let hasHighlightBodies = bodies.contains { body in
            body.isVisible
                && body.renderLayer == .geometry
                && bodyBufferCache[body.id]?.triangleStyleBuffer != nil
        }
        if hasHighlightBodies, displayMode.showsSurfaces {
            mainEncoder.setRenderPipelineState(highlightPipeline)
            mainEncoder.setDepthStencilState(highlightDepthState)
            for body in bodies where body.isVisible && body.renderLayer == .geometry {
                guard let buffers = bodyBufferCache[body.id],
                    let vb = buffers.vertexBuffer,
                    let ib = buffers.indexBuffer,
                    let styleBuf = buffers.triangleStyleBuffer,
                    buffers.indexCount > 0
                else { continue }

                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform

                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBuffer(styleBuf, offset: 0, index: 2)
                mainEncoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: buffers.indexCount,
                    indexType: .uint32,
                    indexBuffer: ib,
                    indexBufferOffset: 0
                )
            }
            // Restore the default depth state for the outline pass that follows.
            mainEncoder.setDepthStencilState(stencilTestState)
        }

        // 4. Selection outline pass (stencil test: draw only where stencil != 1)
        let allSelectedIDs = selectedIDs.union(hoveredID.map { [$0] } ?? [])
        if !allSelectedIDs.isEmpty {
            mainEncoder.setRenderPipelineState(outlinePipeline)
            mainEncoder.setDepthStencilState(stencilTestState)
            mainEncoder.setStencilReferenceValue(1)

            for body in bodies where body.isVisible && allSelectedIDs.contains(body.id) {
                guard let buffers = bodyBufferCache[body.id],
                    let vb = buffers.vertexBuffer,
                    let ib = buffers.indexBuffer,
                    buffers.indexCount > 0
                else { continue }

                let isHover = (hoveredID == body.id && !selectedIDs.contains(body.id))
                let outlineColor: SIMD3<Float> =
                    isHover
                    ? SIMD3<Float>(0.4, 0.7, 1.0)  // light blue for hover
                    : SIMD3<Float>(0.1, 0.5, 1.0)  // bright blue for selection

                var outlineParams = SelectionOutlineParamsSwift(
                    viewProjectionMatrix: viewProjection,
                    modelMatrix: body.transform,
                    outlineColor: outlineColor,
                    outlineScale: 0.015
                )

                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                mainEncoder.setVertexBytes(
                    &outlineParams, length: MemoryLayout<SelectionOutlineParamsSwift>.size, index: 1
                )
                mainEncoder.setFragmentBytes(
                    &outlineParams, length: MemoryLayout<SelectionOutlineParamsSwift>.size, index: 1
                )
                mainEncoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: buffers.indexCount,
                    indexType: .uint32,
                    indexBuffer: ib,
                    indexBufferOffset: 0
                )
            }
        }

        // 5. Overlay pass — RenderLayer.overlay bodies, drawn after the selection
        // outline with always-pass depth so they remain visible through any geometry.
        // Uses the standard shaded + wireframe pipelines (no tessellation / mesh
        // shader paths, since manipulator widgets are simple meshes).
        let hasOverlayBodies = bodies.contains { $0.isVisible && $0.renderLayer == .overlay }
        if hasOverlayBodies {
            mainEncoder.setDepthStencilState(overlayDepthState)
            objectIndex = 0
            for body in bodies where body.isVisible {
                let bodyObjectIndex = objectIndex
                objectIndex += 1
                guard body.renderLayer == .overlay,
                    let buffers = bodyBufferCache[body.id]
                else { continue }

                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                var bodyUniforms = BodyUniforms(
                    body: body, objectIndex: bodyObjectIndex, isSelected: 0)

                // Direct-mesh overlay bodies draw via directMeshPipeline (handled below), so
                // they are NOT excluded here.
                let hasMesh =
                    buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                    && buffers.indexCount > 0
                let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0

                if displayMode.showsSurfaces, hasMesh,
                    let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer
                {
                    if let nb = buffers.normalBuffer {
                        // Direct-mesh body (Option A): position@0 + normal@2, shared shaded shaders.
                        mainEncoder.setRenderPipelineState(directMeshPipeline)
                        mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                        mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                    } else {
                        mainEncoder.setRenderPipelineState(shadedPipeline)
                        mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                    }
                    mainEncoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    mainEncoder.setFragmentTexture(matcapTexture, index: 0)
                    mainEncoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: buffers.indexCount,
                        indexType: .uint32,
                        indexBuffer: ib,
                        indexBufferOffset: 0
                    )
                }

                let shouldDrawEdges = hasEdges && (displayMode.showsEdges || !hasMesh)
                if shouldDrawEdges, let edgeVB = buffers.edgeVertexBuffer {
                    var edgeBodyUniforms = bodyUniforms
                    if !hasMesh {
                        edgeBodyUniforms.metallic = -1.0
                    }
                    mainEncoder.setRenderPipelineState(wireframePipeline)
                    mainEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                    mainEncoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    mainEncoder.drawPrimitives(
                        type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
                }
            }
        }

        mainEncoder.endEncoding()

        // =========================================================
        // Pass 2: 1x Pick pass (R32Uint, no MSAA)
        // =========================================================
        let pickingEnabled = controller.configuration.pickingConfiguration.isEnabled
        if pickingEnabled {
            let w = Int(drawableSize.width)
            let h = Int(drawableSize.height)
            pickTextureManager.ensureSize(width: w, height: h)
            ensurePickDepthTexture(width: w, height: h)

            if let pickTex = pickTextureManager.texture, let pickDepth = pickDepthTexture {
                let pickPass = MTLRenderPassDescriptor()
                pickPass.colorAttachments[0].texture = pickTex
                pickPass.colorAttachments[0].loadAction = .clear
                pickPass.colorAttachments[0].storeAction = .store
                pickPass.colorAttachments[0].clearColor = MTLClearColor(
                    red: Double(0xFFFF_FFFF),
                    green: 0, blue: 0, alpha: 0
                )
                pickPass.depthAttachment.texture = pickDepth
                pickPass.depthAttachment.loadAction = .clear
                pickPass.depthAttachment.storeAction = .dontCare
                pickPass.depthAttachment.clearDepth = 1.0

                if let pickEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pickPass) {
                    pickEncoder.setDepthStencilState(depthState)

                    objectIndex = 0
                    for body in bodies where body.isVisible {
                        let bodyObjectIndex = objectIndex
                        objectIndex += 1
                        // Non-pickable bodies (issue #63) are skipped, but objectIndex
                        // still advances so the remaining bodies keep their pick IDs.
                        if !body.isPickable { continue }
                        guard let buffers = bodyBufferCache[body.id] else {
                            continue
                        }
                        // Overlay bodies are picked in the second pick loop (always-pass depth).
                        if body.renderLayer == .overlay { continue }

                        // Direct-mesh bodies are stamped via pickShadedDirectPipeline (the standard
                        // branch below), so they are NOT excluded here.
                        let hasMesh =
                            buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                            && buffers.indexCount > 0

                        if hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer {
                            var uniforms = makeUniforms()
                            uniforms.modelMatrix = body.transform
                            var bodyUniforms = BodyUniforms(
                                body: body, objectIndex: bodyObjectIndex)

                            if useMeshShaders, let ml = buffers.meshlets,
                                let msPipeline = meshShaderPickPipeline
                            {
                                pickEncoder.setRenderPipelineState(msPipeline)
                                pickEncoder.setObjectBuffer(
                                    ml.descriptorBuffer, offset: 0, index: 0)
                                pickEncoder.setObjectBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setMeshBuffer(ml.descriptorBuffer, offset: 0, index: 0)
                                pickEncoder.setMeshBuffer(vb, offset: 0, index: 1)
                                pickEncoder.setMeshBuffer(ml.vertexIndexBuffer, offset: 0, index: 2)
                                pickEncoder.setMeshBuffer(
                                    ml.triangleIndexBuffer, offset: 0, index: 3)
                                pickEncoder.setMeshBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 4)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawMeshThreadgroups(
                                    MTLSize(width: ml.meshletCount, height: 1, depth: 1),
                                    threadsPerObjectThreadgroup: MTLSize(
                                        width: 1, height: 1, depth: 1),
                                    threadsPerMeshThreadgroup: MTLSize(
                                        width: 64, height: 1, depth: 1)
                                )
                            } else if useTessellation, let tess = buffers.tessellation,
                                let tessPipeline = tessellatedPickPipeline
                            {
                                pickEncoder.setRenderPipelineState(tessPipeline)
                                pickEncoder.setTessellationFactorBuffer(
                                    tess.tessFactorBuffer, offset: 0, instanceStride: 0)
                                pickEncoder.setVertexBuffer(
                                    tess.patchDataBuffer, offset: 0, index: 0)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawPatches(
                                    numberOfPatchControlPoints: 3,
                                    patchStart: 0,
                                    patchCount: tess.patchCount,
                                    patchIndexBuffer: nil,
                                    patchIndexBufferOffset: 0,
                                    instanceCount: 1,
                                    baseInstance: 0
                                )
                            } else if let nb = buffers.normalBuffer {
                                // Direct-mesh body (Option A): position@0 + normal@2.
                                pickEncoder.setRenderPipelineState(pickShadedDirectPipeline)
                                pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                pickEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawIndexedPrimitives(
                                    type: .triangle,
                                    indexCount: buffers.indexCount,
                                    indexType: .uint32,
                                    indexBuffer: ib,
                                    indexBufferOffset: 0
                                )
                            } else {
                                pickEncoder.setRenderPipelineState(pickShadedPipeline)
                                pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawIndexedPrimitives(
                                    type: .triangle,
                                    indexCount: buffers.indexCount,
                                    indexType: .uint32,
                                    indexBuffer: ib,
                                    indexBufferOffset: 0
                                )
                            }
                        }
                    }

                    // Edge pick pass: render line primitives for any body with
                    // `edgeIndices` set. Uses `.lessEqual` so edges co-planar with
                    // a face overwrite the face's pick ID. The fragment encodes
                    // kind=1, primitiveID = line-segment index.
                    if let pickLinePipeline {
                        let hasEdgePickable = bodies.contains {
                            $0.isVisible && !$0.edgeIndices.isEmpty
                        }
                        if hasEdgePickable {
                            pickEncoder.setDepthStencilState(pickEdgeOrPointDepthState)
                            pickEncoder.setRenderPipelineState(pickLinePipeline)
                            objectIndex = 0
                            for body in bodies where body.isVisible {
                                let bodyObjectIndex = objectIndex
                                objectIndex += 1
                                if !body.isPickable { continue }  // issue #63
                                guard !body.edgeIndices.isEmpty,
                                    let buffers = bodyBufferCache[body.id],
                                    let edgeVB = buffers.edgeVertexBuffer,
                                    buffers.edgePrimitiveCount > 0
                                else { continue }

                                var uniforms = makeUniforms()
                                uniforms.modelMatrix = body.transform
                                var bodyUniforms = BodyUniforms(
                                    body: body, objectIndex: bodyObjectIndex)

                                pickEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawPrimitives(
                                    type: .line,
                                    vertexStart: 0,
                                    vertexCount: buffers.edgeVertexCount
                                )
                            }
                        }
                    }

                    // Arc pick pass (issue #48): re-draw this frame's adaptively
                    // sampled arc segments (from `arcLineBuffer`, ranges in
                    // `frameArcDraws`) to the pick texture. Each arc is drawn
                    // separately so the fragment can stamp the ARC index (kind=1).
                    if let pickArcPipeline, !frameArcDraws.isEmpty, let arcBuf = arcLineBuffer {
                        pickEncoder.setDepthStencilState(pickEdgeOrPointDepthState)
                        pickEncoder.setRenderPipelineState(pickArcPipeline)
                        pickEncoder.setVertexBuffer(arcBuf, offset: 0, index: 0)
                        for d in frameArcDraws {
                            if !d.body.isPickable { continue }  // issue #63
                            var uniforms = makeUniforms()
                            uniforms.modelMatrix = d.body.transform
                            var bodyUniforms = BodyUniforms(
                                body: d.body, objectIndex: d.objectIndex)
                            var arcPrimID = UInt32(truncatingIfNeeded: d.arcIndex)
                            pickEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.setFragmentBytes(
                                &arcPrimID, length: MemoryLayout<UInt32>.size, index: 3)
                            pickEncoder.drawPrimitives(
                                type: .line, vertexStart: d.start, vertexCount: d.count)
                        }
                    }

                    // Vertex pick pass: render point sprites for any body with
                    // `vertices` set. Same `.lessEqual` policy as edges so vertices
                    // sitting on edges win the tie.
                    if let pickPointPipeline {
                        let hasVertexPickable = bodies.contains {
                            $0.isVisible && !$0.vertices.isEmpty
                        }
                        if hasVertexPickable {
                            pickEncoder.setDepthStencilState(pickEdgeOrPointDepthState)
                            pickEncoder.setRenderPipelineState(pickPointPipeline)
                            objectIndex = 0
                            for body in bodies where body.isVisible {
                                let bodyObjectIndex = objectIndex
                                objectIndex += 1
                                if !body.isPickable { continue }  // issue #63
                                guard !body.vertices.isEmpty,
                                    let buffers = bodyBufferCache[body.id],
                                    let pointVB = buffers.pointVertexBuffer,
                                    buffers.pointVertexCount > 0
                                else { continue }

                                var uniforms = makeUniforms()
                                uniforms.modelMatrix = body.transform
                                var bodyUniforms = BodyUniforms(
                                    body: body, objectIndex: bodyObjectIndex)

                                pickEncoder.setVertexBuffer(pointVB, offset: 0, index: 0)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                pickEncoder.drawPrimitives(
                                    type: .point,
                                    vertexStart: 0,
                                    vertexCount: buffers.pointVertexCount
                                )
                            }
                        }
                    }

                    // Overlay pick pass: draw RenderLayer.overlay bodies with
                    // always-pass depth so they win the pick over occluding geometry.
                    let hasOverlayBodies = bodies.contains {
                        $0.isVisible && $0.renderLayer == .overlay
                    }
                    if hasOverlayBodies {
                        pickEncoder.setDepthStencilState(overlayDepthState)
                        objectIndex = 0
                        for body in bodies where body.isVisible {
                            let bodyObjectIndex = objectIndex
                            objectIndex += 1
                            if !body.isPickable { continue }  // issue #63
                            guard body.renderLayer == .overlay,
                                let buffers = bodyBufferCache[body.id],
                                let vb = buffers.vertexBuffer,
                                let ib = buffers.indexBuffer,
                                buffers.indexCount > 0
                            else { continue }

                            var uniforms = makeUniforms()
                            uniforms.modelMatrix = body.transform
                            var bodyUniforms = BodyUniforms(
                                body: body, objectIndex: bodyObjectIndex)

                            if let nb = buffers.normalBuffer {
                                // Direct-mesh overlay body (Option A): position@0 + normal@2.
                                pickEncoder.setRenderPipelineState(pickShadedDirectPipeline)
                                pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                pickEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                            } else {
                                pickEncoder.setRenderPipelineState(pickShadedPipeline)
                                pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                            }
                            pickEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: buffers.indexCount,
                                indexType: .uint32,
                                indexBuffer: ib,
                                indexBufferOffset: 0
                            )
                        }
                    }

                    pickEncoder.endEncoding()
                }
            }
        }

        // =========================================================
        // Pass 2.5: TAA resolve (if enabled)
        // =========================================================
        if taaEnabled, let taaPipeline = taaPipeline,
            let resolvedColor = resolvedColorTexture,
            let taaOutput = taaOutputTexture,
            let taaHistory = taaHistoryTexture
        {

            // Reset accumulation when the scene changes (camera move or animation).
            let cameraChanged = (lastCameraState == nil || lastCameraState! != cameraState)
            let isAnimating = controller.isAnimating
            if cameraChanged || isAnimating {
                taaFrameIndex = 0
            }

            let progressive = controller.enableProgressiveAccumulation && !isAnimating
            // Progressive mode: history weight = N/(N+1), unbounded N up to 256, no clamp.
            // Standard TAA mode: history weight = taaBlendFactor (0.9), 16-frame jitter cycle.
            let blendFactor: Float
            if progressive {
                blendFactor =
                    taaFrameIndex == 0 ? 0 : Float(taaFrameIndex) / Float(taaFrameIndex + 1)
            } else {
                blendFactor = taaFrameIndex > 0 ? controller.taaBlendFactor : 0
            }
            let disableClamp: Float = progressive ? 1 : 0

            let taaPass = MTLRenderPassDescriptor()
            taaPass.colorAttachments[0].texture = taaOutput
            taaPass.colorAttachments[0].loadAction = .dontCare
            taaPass.colorAttachments[0].storeAction = .store

            if let taaEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: taaPass) {
                taaEncoder.setRenderPipelineState(taaPipeline)

                // In progressive mode, sample history at the same UV as current — each frame's
                // sub-pixel-jittered rasterization contributes to averaged supersampling.
                // In standard TAA, the unjitter step compensates so current and history align.
                let resolveJitter: SIMD2<Float> = progressive ? .zero : jitterPx
                var taaParams = TAAParamsSwift(
                    blendFactor: blendFactor,
                    disableClamp: disableClamp,
                    jitterOffset: resolveJitter,
                    texelSize: SIMD2<Float>(1.0 / Float(w), 1.0 / Float(h))
                )
                taaEncoder.setFragmentTexture(resolvedColor, index: 0)
                taaEncoder.setFragmentTexture(taaHistory, index: 1)
                taaEncoder.setFragmentBytes(
                    &taaParams, length: MemoryLayout<TAAParamsSwift>.size, index: 0)
                taaEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                taaEncoder.endEncoding()
            }

            // Swap history: blit taaOutput → taaHistory for next frame
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(from: taaOutput, to: taaHistory)
                blitEncoder.endEncoding()
            }

            lastCameraState = cameraState
            // Standard TAA cycles a 16-sample Halton sequence; progressive accumulates up to 256.
            let frameCap: UInt32 = progressive ? 256 : 16
            taaFrameIndex = min(taaFrameIndex + 1, frameCap)
        }

        // Determine which color texture to feed into SSAO
        let ssaoInputColor: MTLTexture? = {
            if taaEnabled, let taaOutput = taaOutputTexture {
                return taaOutput
            }
            return resolvedColorTexture
        }()

        // =========================================================
        // Pass 3: SSAO post-process (if enabled)
        // =========================================================
        if ssaoEnabled, let ssaoPipeline = ssaoPipeline,
            let resolvedColor = ssaoInputColor,
            let resolvedDepth = resolvedDepthTexture
        {

            // First: render a 1x depth-only pass for SSAO sampling
            let depthOnlyPass = MTLRenderPassDescriptor()
            depthOnlyPass.depthAttachment.texture = resolvedDepth
            depthOnlyPass.depthAttachment.loadAction = .clear
            depthOnlyPass.depthAttachment.storeAction = .store
            depthOnlyPass.depthAttachment.clearDepth = 1.0

            if let depthEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthOnlyPass)
            {
                depthEncoder.setDepthStencilState(depthState)

                objectIndex = 0
                for body in bodies where body.isVisible {
                    guard let buffers = bodyBufferCache[body.id] else {
                        objectIndex += 1
                        continue
                    }
                    // Direct-mesh bodies are written via depthOnlyDirectPipeline (handled in the
                    // standard branch below), so they are NOT excluded here.
                    let hasMesh =
                        buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                        && buffers.indexCount > 0
                    if hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer {
                        var uniforms = makeUniforms()

                        if useMeshShaders, let ml = buffers.meshlets,
                            let msPipeline = meshShaderDepthOnlyPipeline
                        {
                            depthEncoder.setRenderPipelineState(msPipeline)
                            depthEncoder.setObjectBuffer(ml.descriptorBuffer, offset: 0, index: 0)
                            depthEncoder.setObjectBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            depthEncoder.setMeshBuffer(ml.descriptorBuffer, offset: 0, index: 0)
                            depthEncoder.setMeshBuffer(vb, offset: 0, index: 1)
                            depthEncoder.setMeshBuffer(ml.vertexIndexBuffer, offset: 0, index: 2)
                            depthEncoder.setMeshBuffer(ml.triangleIndexBuffer, offset: 0, index: 3)
                            depthEncoder.setMeshBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 4)
                            depthEncoder.drawMeshThreadgroups(
                                MTLSize(width: ml.meshletCount, height: 1, depth: 1),
                                threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerMeshThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
                            )
                        } else if useTessellation, let tess = buffers.tessellation,
                            let tessPipeline = tessellatedDepthOnlyPipeline
                        {
                            depthEncoder.setRenderPipelineState(tessPipeline)
                            depthEncoder.setTessellationFactorBuffer(
                                tess.tessFactorBuffer, offset: 0, instanceStride: 0)
                            depthEncoder.setVertexBuffer(tess.patchDataBuffer, offset: 0, index: 0)
                            depthEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            depthEncoder.drawPatches(
                                numberOfPatchControlPoints: 3,
                                patchStart: 0,
                                patchCount: tess.patchCount,
                                patchIndexBuffer: nil,
                                patchIndexBufferOffset: 0,
                                instanceCount: 1,
                                baseInstance: 0
                            )
                        } else if let nb = buffers.normalBuffer {
                            // Direct-mesh body (Option A): position@0 + normal@2.
                            depthEncoder.setRenderPipelineState(depthOnlyDirectPipeline)
                            depthEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                            depthEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                            depthEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            depthEncoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: buffers.indexCount,
                                indexType: .uint32,
                                indexBuffer: ib,
                                indexBufferOffset: 0
                            )
                        } else {
                            depthEncoder.setRenderPipelineState(depthOnlyPipeline)
                            depthEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                            depthEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            depthEncoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: buffers.indexCount,
                                indexType: .uint32,
                                indexBuffer: ib,
                                indexBufferOffset: 0
                            )
                        }
                    }
                    objectIndex += 1
                }
                depthEncoder.endEncoding()
            }

            // SSAO composite pass: read resolved color + depth, output to drawable
            let ssaoPass = MTLRenderPassDescriptor()
            ssaoPass.colorAttachments[0].texture = targets.finalColorTexture
            ssaoPass.colorAttachments[0].loadAction = .dontCare
            ssaoPass.colorAttachments[0].storeAction = .store

            if let ssaoEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: ssaoPass) {
                ssaoEncoder.setRenderPipelineState(ssaoPipeline)

                let silhouetteConfig = controller.configuration
                let dofEnabled = controller.enableDepthOfField
                var dofFocalDist = controller.dofFocalDistance
                if dofEnabled && dofFocalDist == 0 {
                    // Auto-focus: use distance to scene center
                    var sceneCenter = SIMD3<Float>.zero
                    var count: Float = 0
                    for body in bodies where body.isVisible {
                        if let bb = body.boundingBox {
                            sceneCenter += (bb.min + bb.max) * 0.5
                            count += 1
                        }
                    }
                    if count > 0 {
                        sceneCenter /= count
                        dofFocalDist = simd_distance(cameraState.position, sceneCenter)
                    } else {
                        dofFocalDist = cameraState.distance
                    }
                }
                var ssaoParams = SSAOParamsSwift(
                    texelSize: SIMD2<Float>(1.0 / Float(w), 1.0 / Float(h)),
                    radius: lighting.ssaoRadius,
                    intensity: lighting.ssaoIntensity,
                    nearPlane: nearPlane,
                    farPlane: farPlane,
                    silhouetteThickness: silhouetteConfig.enableSilhouettes
                        ? silhouetteConfig.silhouetteThickness : 0.0,
                    silhouetteIntensity: silhouetteConfig.enableSilhouettes
                        ? silhouetteConfig.silhouetteIntensity : 0.0,
                    exposure: lighting.exposure,
                    whitePoint: lighting.whitePoint,
                    dofAperture: controller.dofAperture,
                    dofFocalDistance: dofFocalDist,
                    dofMaxBlurRadius: controller.dofMaxBlurRadius,
                    dofEnabled: dofEnabled ? 1.0 : 0.0
                )
                ssaoEncoder.setFragmentTexture(resolvedDepth, index: 0)
                ssaoEncoder.setFragmentTexture(resolvedColor, index: 1)
                ssaoEncoder.setFragmentBytes(
                    &ssaoParams, length: MemoryLayout<SSAOParamsSwift>.size, index: 0)
                ssaoEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                ssaoEncoder.endEncoding()
            }
        }

        // Prune cache entries for bodies no longer in the scene.
        let activeIDs = Set(bodies.map(\.id))
        for id in bodyBufferCache.keys where !activeIDs.contains(id) {
            bodyBufferCache.removeValue(forKey: id)
            bodyGeneration.removeValue(forKey: id)
        }

        if let presentable = targets.presentable {
            commandBuffer.present(presentable)
        }
        commandBuffer.commit()
    }

    // MARK: - Shaded surface draw

    /// Encodes a body's shaded surface via the mesh-shader, tessellated, or standard path.
    ///
    /// The caller sets uniforms / fragment bytes / textures / depth state first. Shared by the
    /// opaque main loop and the transparent pass (#53).
    private func encodeShadedSurface(
        _ encoder: MTLRenderCommandEncoder,
        buffers: BodyBuffers,
        uniforms: inout Uniforms,
        useMeshShaders: Bool,
        useTessellation: Bool
    ) {
        guard let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer, buffers.indexCount > 0
        else { return }

        if let nb = buffers.normalBuffer {
            // Direct-mesh path (Option A): de-interleaved position@0 + normal@2, no interleave.
            encoder.setRenderPipelineState(directMeshPipeline)
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            encoder.setVertexBuffer(nb, offset: 0, index: 2)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: buffers.indexCount,
                indexType: .uint32,
                indexBuffer: ib,
                indexBufferOffset: 0
            )
        } else if useMeshShaders, let ml = buffers.meshlets,
            let msPipeline = meshShaderShadedPipeline
        {
            encoder.setRenderPipelineState(msPipeline)
            encoder.setObjectBuffer(ml.descriptorBuffer, offset: 0, index: 0)
            encoder.setObjectBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.setMeshBuffer(ml.descriptorBuffer, offset: 0, index: 0)
            encoder.setMeshBuffer(vb, offset: 0, index: 1)
            encoder.setMeshBuffer(ml.vertexIndexBuffer, offset: 0, index: 2)
            encoder.setMeshBuffer(ml.triangleIndexBuffer, offset: 0, index: 3)
            encoder.setMeshBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 4)
            encoder.drawMeshThreadgroups(
                MTLSize(width: ml.meshletCount, height: 1, depth: 1),
                threadsPerObjectThreadgroup: MTLSize(width: 1, height: 1, depth: 1),
                threadsPerMeshThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
            )
        } else if useTessellation, let tess = buffers.tessellation,
            let tessPipeline = tessellatedShadedPipeline
        {
            encoder.setRenderPipelineState(tessPipeline)
            encoder.setTessellationFactorBuffer(tess.tessFactorBuffer, offset: 0, instanceStride: 0)
            encoder.setVertexBuffer(tess.patchDataBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawPatches(
                numberOfPatchControlPoints: 3,
                patchStart: 0,
                patchCount: tess.patchCount,
                patchIndexBuffer: nil,
                patchIndexBufferOffset: 0,
                instanceCount: 1,
                baseInstance: 0
            )
        } else {
            encoder.setRenderPipelineState(shadedPipeline)
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: buffers.indexCount,
                indexType: .uint32,
                indexBuffer: ib,
                indexBufferOffset: 0
            )
        }
    }

    // MARK: - Buffer Management

    /// Returns the reused arc-line buffer, growing it if needed.
    private func ensureArcBuffer(byteCount: Int) -> MTLBuffer? {
        if let b = arcLineBuffer, b.length >= byteCount { return b }
        arcLineBuffer = device.makeBuffer(length: max(byteCount, 4096), options: .storageModeShared)
        return arcLineBuffer
    }

    private func ensureBuffers(for body: ViewportBody) {
        let currentGen = body.generation
        if let cachedGen = bodyGeneration[body.id], cachedGen == currentGen {
            return  // buffer still valid
        }

        // Build vertex + index buffers (nil for edge-only bodies). Interleaved bodies optionally
        // get crease-aware normal smoothing first (issue #48) so meshes with flat / per-face
        // normals can be rounded by Phong tessellation: done once here (generation-gated), and
        // the tessellation patch builder reads from this vertex buffer, so smoothed normals flow
        // into the PN-triangle control points automatically. Direct-mesh bodies skip smoothing
        // (the producer supplies normals) and skip the tessellation / mesh-shader paths, which
        // consume the interleaved buffer + faceIndices.
        var smoothedVertexData: [Float]?
        if !body.usesDirectMesh, !body.vertexData.isEmpty, !body.indices.isEmpty,
            controller?.configuration.autoSmoothNormals == true
        {
            var meshVertexData = body.vertexData
            NormalSmoothing.smoothNormals(
                vertexData: &meshVertexData,
                indices: body.indices,
                creaseAngle: controller?.configuration.normalSmoothingCreaseAngle ?? 0.524
            )
            smoothedVertexData = meshVertexData
        }

        let mesh = RendererSharedBuffers.makeMeshBuffers(
            device: device, body: body, interleavedVertexData: smoothedVertexData)
        let vertexBuffer = mesh.vertexBuffer
        let normalBuffer = mesh.normalBuffer
        let indexBuffer = mesh.indexBuffer
        let indexCount = mesh.indexCount
        let vertexCount = mesh.vertexCount

        // Build edge vertex buffer (convert polylines to line segment pairs)
        let edgeVertices = RendererSharedBuffers.edgeLineVertices(from: body.edges)
        let edgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: edgeVertices)
        let edgeVertexCount = edgeVertices.count / 6
        let edgePrimitiveCount = edgeVertexCount / 2

        // Build point vertex buffer for vertex picking. Each entry in body.vertices
        // becomes one point sprite; uses the same position+normal stride as the
        // mesh vertex buffer so the standard pick vertex descriptor applies.
        let pointVB: MTLBuffer?
        let pointVertexCount: Int
        if !body.vertices.isEmpty {
            var pointData: [Float] = []
            pointData.reserveCapacity(body.vertices.count * 6)
            for v in body.vertices {
                pointData.append(contentsOf: [v.x, v.y, v.z, 0, 0, 0])
            }
            pointVB = device.makeBuffer(
                bytes: pointData,
                length: pointData.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            pointVertexCount = body.vertices.count
        } else {
            pointVB = nil
            pointVertexCount = 0
        }

        // Tight position-only buffer for the visible point-cloud pass. Separate from `pointVB`
        // because the visible pass uses [[vertex_id]] indexing with no vertex descriptor — a
        // stride of 12 keeps memory bandwidth proportional to the point count rather than 2× for
        // the unused normal slots. The colour buffer is dropped when its length doesn't match.
        let pointPositionVB = RendererSharedBuffers.makePointPositionBuffer(
            device: device, vertices: body.vertices)
        let pointColorVB = RendererSharedBuffers.makePointColorBuffer(
            device: device, vertexColors: body.vertexColors, vertexCount: body.vertices.count)

        // Skip bodies with no renderable data at all. Arc-only bodies have none of
        // the baked buffers (arcs are sampled per-frame), so admit them too (#48).
        guard vertexBuffer != nil || edgeVB != nil || pointPositionVB != nil || !body.arcs.isEmpty
        else { return }

        // Build tessellation patch data if tessellation is enabled. Skipped for direct-mesh bodies:
        // the patch builder consumes an interleaved stride-6 buffer + faceIndices, neither of which
        // a direct body has (it brings its own normals; no PN refinement needed).
        var tessBuffers: TessellationBuffers?
        if tessellationEnabled, !body.usesDirectMesh,
            let tessMgr = tessellationManager,
            let vb = vertexBuffer, let ib = indexBuffer,
            indexCount > 0
        {
            let triangleCount = indexCount / 3
            tessBuffers = tessMgr.buildPatches(
                vertexBuffer: vb,
                indexBuffer: ib,
                faceIndices: body.faceIndices,
                triangleCount: triangleCount,
                commandQueue: commandQueue
            )
            // One-shot diagnostic for the first body
            #if DEBUG
                if !tessMgr.didLogDiagnostic {
                    tessMgr.didLogDiagnostic = true
                    let msg = """
                        ensureBuffers: body=\(body.id) tris=\(triangleCount) \
                        faceIdx=\(body.faceIndices.count) tessResult=\(tessBuffers != nil) \
                        tessEnabled=\(tessellationEnabled) vb=\(vb.length) ib=\(ib.length)
                        """
                    NSLog("[ViewportRenderer] %@", msg)
                }
            #endif
        }

        // Build meshlets if mesh shaders are enabled
        var meshletBufs: MeshletBuffers?
        if meshShadersEnabled, !body.vertexData.isEmpty, !body.indices.isEmpty {
            meshletBufs = MeshletBuilder.build(
                vertexData: body.vertexData,
                indices: body.indices,
                faceIndices: body.faceIndices,
                device: device
            )
        }

        // Per-triangle highlight style buffer. Built only when the body has any
        // triangleStyles set; nil otherwise. Uploaded as raw SIMD4<Float> array
        // so the fragment shader can index by [[primitive_id]] directly.
        let triStyleBuf: MTLBuffer?
        let triangleCount = indexCount / 3
        if !body.triangleStyles.isEmpty, triangleCount > 0,
            body.triangleStyles.count == triangleCount
        {
            // Pack into a contiguous SIMD4<Float> array.
            var packed = body.triangleStyles.map { $0.color }
            triStyleBuf = device.makeBuffer(
                bytes: &packed,
                length: packed.count * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModeShared
            )
        } else {
            triStyleBuf = nil
        }

        bodyBufferCache[body.id] = BodyBuffers(
            vertexBuffer: vertexBuffer,
            normalBuffer: normalBuffer,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            edgeVertexBuffer: edgeVB,
            edgeVertexCount: edgeVertexCount,
            edgePrimitiveCount: edgePrimitiveCount,
            pointVertexBuffer: pointVB,
            pointVertexCount: pointVertexCount,
            pointPositionBuffer: pointPositionVB,
            pointColorBuffer: pointColorVB,
            vertexCount: vertexCount,
            tessellation: tessBuffers,
            meshlets: meshletBufs,
            triangleStyleBuffer: triStyleBuf,
            localBoundingBox: body.boundingBox
        )
        bodyGeneration[body.id] = currentGen
    }

    // MARK: - Picking

    /// Reads a single pixel from the pick ID buffer and decodes the result.
    ///
    /// - Parameters:
    ///   - pixel: The pixel coordinate (in drawable pixels) to sample.
    ///   - completion: Called with the decoded `PickResult`, or `nil` for background/no hit.
    public func performPick(
        at pixel: SIMD2<Int>, completion: @escaping @Sendable (PickResult?) -> Void
    ) {
        guard let pickTexture = pickTextureManager.texture else {
            completion(nil)
            return
        }

        // Clamp to texture bounds
        let x = max(0, min(pixel.x, pickTextureManager.width - 1))
        let y = max(0, min(pixel.y, pickTextureManager.height - 1))

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            completion(nil)
            return
        }

        // Blit 1x1 region from private pick texture to shared readback buffer
        blitEncoder.copy(
            from: pickTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: pickReadbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: MemoryLayout<UInt32>.size,
            destinationBytesPerImage: MemoryLayout<UInt32>.size
        )
        blitEncoder.endEncoding()

        let indexMap = currentIndexMap
        let layerMap = currentLayerMap
        let readbackBuffer = pickReadbackBuffer

        commandBuffer.addCompletedHandler { _ in
            let rawValue = readbackBuffer.contents().load(as: UInt32.self)
            let result = PickResult(rawValue: rawValue, indexMap: indexMap, layerMap: layerMap)
            Task { @MainActor in
                completion(result)
            }
        }

        commandBuffer.commit()
    }

    /// Returns (creating or growing if needed) a shared-mode buffer of at least
    /// `minimumBytes`, reused across calls to avoid reallocating on every region pick.
    private func ensureRegionReadbackBuffer(minimumBytes: Int) -> MTLBuffer? {
        if let buffer = regionReadbackBuffer, regionReadbackCapacity >= minimumBytes {
            return buffer
        }
        guard let buffer = device.makeBuffer(length: minimumBytes, options: .storageModeShared)
        else {
            return nil
        }
        regionReadbackBuffer = buffer
        regionReadbackCapacity = minimumBytes
        return buffer
    }

    /// Reads a screen-space rectangle from the pick ID buffer in a single GPU round trip and
    /// returns the de-duplicated set of primitives it touches (issue #90).
    ///
    /// Unlike `performPick(at:)`, which blits a single pixel, this blits the whole rectangle in
    /// one command-buffer submission — one GPU round trip regardless of the rectangle's pixel
    /// count, instead of one `performPick` call per pixel. Results are occlusion-aware and
    /// pixel-accurate (including face interiors), unlike a CPU vertex-projection approximation.
    ///
    /// - Parameters:
    ///   - rect: The rectangle to sample, in drawable **pixel** coordinates — the same space as
    ///     `performPick(at:)`'s `pixel` parameter, not view points (see `MetalViewportView`'s
    ///     point→pixel conversion). Clamped to the pick texture's bounds; a rect that doesn't
    ///     intersect it completes with an empty array.
    ///   - completion: Called once with every distinct primitive under the rectangle, in scan
    ///     order of first appearance. Background pixels are excluded, so a rect entirely over
    ///     empty space completes with `[]`. Apply a `SelectionFilter` to the result the same way
    ///     you would a single `performPick` result.
    public func performRegionPick(
        rect: CGRect, completion: @escaping @Sendable ([PickResult]) -> Void
    ) {
        guard let pickTexture = pickTextureManager.texture else {
            completion([])
            return
        }

        guard
            let region = Self.clampRegionPickRect(
                rect, textureWidth: pickTextureManager.width,
                textureHeight: pickTextureManager.height
            )
        else {
            completion([])
            return
        }
        let (x, y, w, h) = region

        // Metal blit copies from a texture into a buffer expect each row on an aligned
        // stride, not necessarily a tightly-packed `width * bytesPerPixel` — pad every row
        // rather than risk decoding garbage past row 0 on real hardware.
        let bytesPerRow = Self.alignedBytesPerRow(forWidth: w)
        let byteCount = bytesPerRow * h

        guard let readbackBuffer = ensureRegionReadbackBuffer(minimumBytes: byteCount),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            completion([])
            return
        }

        // Blit the whole rectangle from the private pick texture to the shared readback
        // buffer in one copy — the batched alternative to N per-pixel blits.
        blitEncoder.copy(
            from: pickTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: w, height: h, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blitEncoder.endEncoding()

        let indexMap = currentIndexMap
        let layerMap = currentLayerMap

        commandBuffer.addCompletedHandler { _ in
            // De-stride: read exactly the w*4 live bytes from each padded row, skipping the
            // alignment padding, into one flat row-major array for decodeRegionPickResults.
            let base = readbackBuffer.contents()
            var rawValues: [UInt32] = []
            rawValues.reserveCapacity(w * h)
            for row in 0..<h {
                let rowValues = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                rawValues.append(contentsOf: UnsafeBufferPointer(start: rowValues, count: w))
            }
            let results = Self.decodeRegionPickResults(
                rawValues, indexMap: indexMap, layerMap: layerMap)
            Task { @MainActor in
                completion(results)
            }
        }

        commandBuffer.commit()
    }

    /// Rounds `width * bytesPerPixel` up to a 256-byte-aligned row stride — the safe
    /// conservative choice for a texture→buffer blit's `destinationBytesPerRow` (Metal's true
    /// minimum per-format alignment can be smaller, but never larger, for a plain 4-byte
    /// uncompressed format like the R32Uint pick texture).
    nonisolated static func alignedBytesPerRow(
        forWidth width: Int, bytesPerPixel: Int = MemoryLayout<UInt32>.size
    ) -> Int {
        let alignment = 256
        let unaligned = width * bytesPerPixel
        let remainder = unaligned % alignment
        return remainder == 0 ? unaligned : unaligned + (alignment - remainder)
    }

    /// Clamps `rect` to the pick texture's bounds and returns the origin/size to blit.
    ///
    /// `rect` is in drawable pixel coordinates and is rounded outward so a fractional rect isn't
    /// under-sampled. Returns `nil` if the rect doesn't intersect the texture at all, or the
    /// texture has zero size (e.g. no frame has drawn yet).
    nonisolated static func clampRegionPickRect(
        _ rect: CGRect, textureWidth: Int, textureHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        let clipped = rect.intersection(
            CGRect(x: 0, y: 0, width: textureWidth, height: textureHeight))
        guard !clipped.isNull else { return nil }

        let x = max(0, Int(clipped.origin.x.rounded(.down)))
        let y = max(0, Int(clipped.origin.y.rounded(.down)))
        let w = min(textureWidth - x, max(1, Int(clipped.width.rounded(.up))))
        let h = min(textureHeight - y, max(1, Int(clipped.height.rounded(.up))))
        guard w > 0, h > 0 else { return nil }
        return (x, y, w, h)
    }

    /// Decodes raw R32Uint pick values into the de-duplicated primitives they represent.
    ///
    /// Input is a flat, row-major array as read back by `performRegionPick`; output keeps each
    /// primitive's first appearance, and background (sentinel) pixels are dropped. Pulled out of
    /// the GPU readback path as a pure function so the dedup/decode logic is unit-testable
    /// without a live draw (the pick texture itself is only populated by an actual frame).
    nonisolated static func decodeRegionPickResults(
        _ rawValues: [UInt32],
        indexMap: [Int: String],
        layerMap: [String: PickLayer]
    ) -> [PickResult] {
        var seen = Set<UInt32>()
        var results: [PickResult] = []
        for rawValue in rawValues {
            guard rawValue != PickResult.sentinel, !seen.contains(rawValue) else { continue }
            seen.insert(rawValue)
            if let result = PickResult(rawValue: rawValue, indexMap: indexMap, layerMap: layerMap) {
                results.append(result)
            }
        }
        return results
    }
}
