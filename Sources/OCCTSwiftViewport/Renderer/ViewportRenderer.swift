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
    var ambientSkyColor: SIMD4<Float>  // rgb, w unused
    var ambientGroundColor: SIMD4<Float>  // rgb, w unused
    // rgb = ambient scale (ambientColor × ambientIntensity, 1 = .threePoint), w = specular scale
    var lightingScales: SIMD4<Float>
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
    var unlit: UInt32 = 0  // 1 = unlit/flat-colour (skip lighting + tone map), 2 = faceted
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
        // `objectIndex` is the body's draw-order ordinal and is read only by the pick shaders.
        // Past the 16-bit object field it becomes the sentinel, so the body reads back as a miss
        // instead of bleeding into the primitive bits (issue #136, H4).
        self.objectIndex = PickResult.pickObjectIndex(forOrdinal: objectIndex)
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

// Swift↔Metal sync: Renderer/Shaders.metal `struct GridUniforms` (same field order; `rows`
// fills the 4 bytes of padding before the 16-byte-aligned `dotColor`, so the size stays 112).
struct GridUniforms {
    var viewProjectionMatrix: simd_float4x4
    /// World position of the window's minimum-index dot.
    var gridOrigin: SIMD3<Float>
    var spacing: Float
    /// Dots along X.
    var columns: Int32
    var dotSize: Float
    /// Dots along Y.
    var rows: Int32
    var dotColor: SIMD4<Float>
}

struct AxisUniforms {
    var viewProjectionMatrix: simd_float4x4
}

// IMPORTANT — Swift↔Metal sync (see Renderer/Shaders.metal `struct SelectionOutlineParams`).
// Field order, types, and 16-byte alignment must stay identical. Total stride = 160 bytes.
struct SelectionOutlineParamsSwift {
    var viewProjectionMatrix: simd_float4x4  // offset   0
    var modelMatrix: simd_float4x4  // offset  64
    var outlineColor: SIMD3<Float>  // offset 128 (16 bytes, like Metal float3)
    var outlineWidth: Float  // offset 144 — drawable pixels
    var viewportSize: SIMD2<Float>  // offset 152 — drawable pixels
}

// IMPORTANT — Swift↔Metal sync (see Renderer/Shaders.metal `struct EdgeUniforms`).
// Field order, types, and 16-byte alignment must stay identical.
struct EdgeUniforms {
    var viewProjectionMatrix: simd_float4x4
    var modelMatrix: simd_float4x4
    var viewMatrix: simd_float4x4
    var cameraPosition: SIMD4<Float>  // xyz + nearPlane in w
    var materialParams: SIMD4<Float>  // fresnelPower, fresnelIntensity, matcapBlend, farPlane
    var dashPatternParams: SIMD4<Float>  // dashLength, gapLength, dotLength, phase
    var edgeParams: SIMD4<Float>  // x = width (px), y = edgeIntensity, z/w = unused
    var clipPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
        .zero, .zero, .zero, .zero
    )
    var clipPlaneCount: UInt32 = 0
    var dashPatternType: UInt32 = 0
    var viewportSize: SIMD2<Float> = .zero
    var _pad: SIMD2<Float> = .zero
}

extension EdgeUniforms {
    /// Quad-edge uniforms for one draw, taken from that draw's scene `Uniforms`.
    ///
    /// The edge intensity comes from `uniforms.shadowParams.w`, where both renderers already put
    /// it for the native wireframe path, so the two edge paths fade and dim identically.
    ///
    /// - Parameters:
    ///   - uniforms: The draw's scene uniforms (matrices, camera, clip planes, edge intensity).
    ///   - configuration: Width and dash pattern.
    ///   - viewportSize: Render target size in pixels.
    ///   - width: Overrides `configuration.width`, e.g. for a wider pick footprint.
    init(
        uniforms: Uniforms,
        configuration: EdgeLineConfiguration,
        viewportSize: SIMD2<Float>,
        width: Float? = nil
    ) {
        let dash = configuration.dashPattern
        self.init(
            viewProjectionMatrix: uniforms.viewProjectionMatrix,
            modelMatrix: uniforms.modelMatrix,
            viewMatrix: uniforms.viewMatrix,
            cameraPosition: uniforms.cameraPosition,
            materialParams: uniforms.materialParams,
            dashPatternParams: SIMD4<Float>(
                dash.dashLength, dash.gapLength, dash.dotLength, dash.phase),
            edgeParams: SIMD4<Float>(width ?? configuration.width, uniforms.shadowParams.w, 0, 0),
            clipPlanes: uniforms.clipPlanes,
            clipPlaneCount: uniforms.clipPlaneCount,
            dashPatternType: dash.kind.rawValue,
            viewportSize: simd_max(viewportSize, SIMD2<Float>(1, 1))
        )
    }
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
    /// Quad-expanded edge vertex buffer (9 floats per vertex: endpoint, arc length,
    /// corner offset, and segment direction; 6 vertices per segment including strip breaks).
    ///
    /// Used by the quad-edge pipeline for variable width and dash patterns.
    let quadEdgeVertexBuffer: MTLBuffer?
    let quadEdgeVertexCount: Int
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
    var triangleStyleBuffer: MTLBuffer?
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

    /// Time available per frame, in seconds, on the live path; `nil` off-screen.
    ///
    /// Drives the uniform-tessellation load governor; off-screen frames leave it `nil` so they
    /// tessellate at the configured factor and stay deterministic.
    var frameBudget: Double?
}

// MARK: - ViewportRenderer

@MainActor
public final class ViewportRenderer: NSObject, MTKViewDelegate, Sendable {

    // MARK: - Properties

    /// One sampled arc of this frame: its vertex range in the frame's arc line buffer
    /// (`start`/`count`) and in its quad-strip buffer (`quadStart`/`quadCount`).
    private typealias FrameArcDraw = (
        body: ViewportBody, objectIndex: UInt32, arcIndex: Int, start: Int, count: Int,
        quadStart: Int, quadCount: Int
    )

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
    /// Quad-expanded wireframe pipeline (variable width + dash patterns).
    private let quadEdgePipeline: MTLRenderPipelineState?
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
    /// `pick_line_vertex` carries `wireframe_vertex`'s depth bias, so a native edge wins the pick
    /// over the face it lies on (issue #182); the fragment emits kind=1 in the pick encoding.
    /// `pickArcPipeline` uses the same vertex shader.
    private let pickLinePipeline: MTLRenderPipelineState?
    private let pickArcPipeline: MTLRenderPipelineState?
    /// Quad-expanded edge + arc pick pipeline, so the pick footprint matches the visible width.
    private let pickQuadEdgePipeline: MTLRenderPipelineState?
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
    /// Direct-mesh selection outline pipeline.
    ///
    /// `selection_outline_vertex` with the two-buffer descriptor (position@0 / normal@2). The
    /// outline expands along the normal, so the normal binding is read, not just satisfied.
    private let outlineDirectPipeline: MTLRenderPipelineState
    /// Colourless stencil masks marking each selected or hovered body's whole silhouette.
    ///
    /// The selection outline draws only where they left the stencil unmarked, which is the ring
    /// around the body. Drawn with `selectionMaskState`.
    private let stencilMaskPipeline: MTLRenderPipelineState
    private let stencilMaskDirectPipeline: MTLRenderPipelineState

    // Per-triangle highlight overlay (issue #25).
    // Drawn with the same vertex pipeline as shaded — so identical positions —
    // but composites per-triangle style color over the existing fragment.
    private let highlightPipeline: MTLRenderPipelineState
    /// Direct-mesh per-triangle highlight pipeline (two-buffer descriptor, position@0 /
    /// normal@2), so `triangleStyles` overlay `ViewportBody.directMesh(...)` bodies correctly.
    private let highlightDirectPipeline: MTLRenderPipelineState
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
    /// Always-pass depth, no depth write, stencil set to the reference: marks a selected body's
    /// whole silhouette for the outline pass, including where nearer geometry covers it (#177).
    private let selectionMaskState: MTLDepthStencilState
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
    // Internal (not private) so headless tests can tell whether the tessellated pick path ran.
    let tessellatedPickPipeline: MTLRenderPipelineState?
    let tessellationEnabled: Bool
    /// The `maxTessellationFactor` the tessellated pipelines were built with (clamped, even).
    ///
    /// Per-frame factors are capped to this, since a later `tessellationMaxFactor` raise cannot
    /// exceed what the pipelines were created for.
    private let pipelineMaxTessFactor: Int
    /// Load governor for the uniform tessellation factor (live frames only).
    private var tessLoadGovernor = TessellationLoadGovernor()
    /// Latest GPU frame time, fed to `tessLoadGovernor`.
    private let gpuFrameTimes = GPUFrameTimeRecorder()
    /// The uniform tessellation factor the last frame used (`nil` when adaptive or untessellated).
    private(set) var lastUniformTessellationFactor: Float?

    // Mesh shaders (Apple9+ / M3+ / A17+)
    private let meshShaderShadedPipeline: MTLRenderPipelineState?
    private let meshShaderShadowPipeline: MTLRenderPipelineState?
    private let meshShaderDepthOnlyPipeline: MTLRenderPipelineState?
    // Internal (not private) so headless tests can tell whether the mesh-shader pick path ran.
    let meshShaderPickPipeline: MTLRenderPipelineState?
    let meshShadersEnabled: Bool

    /// Off-screen attachment set backing `renderHeadless(...)`; `nil` until the first such call.
    ///
    /// Kept out of every live-path code path, so headless mode cannot perturb on-screen rendering.
    var headlessTargets: HeadlessRenderTargets?

    /// Near/far planes the last encoded frame used.
    ///
    /// Internal so tests can check that a body's first frame is fitted (#157).
    private(set) var lastFrameClipPlanes: (near: Float, far: Float)?

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
    /// `ViewportBody.triangleStylesGeneration` each cached `triangleStyleBuffer` was built from.
    private var bodyStyleGeneration: [String: UInt64] = [:]

    /// Axis cylinders and the cached `.plane` grid-line buffer.
    private let gridAxisBuffers: GridAxisBuffers

    // MARK: - Picking

    /// Manages the R32Uint pick ID texture (second color attachment).
    private let pickTextureManager: PickTextureManager
    /// Shared-mode readback buffers for exact and region picks (issue #90).
    ///
    /// Each pick takes a buffer no other in-flight pick holds and returns it once its completion
    /// handler has read it, so overlapping picks never read each other's pixels (issue #184).
    /// Beyond 1 MB the pool keeps only the most recently returned buffer, so a burst of large
    /// overlapping region picks does not leave several full-screen readbacks allocated. Internal
    /// so tests can check reuse.
    lazy var pickReadbackPool = FrameBufferPool(device: device, maxRetainedBytes: 1 << 20)
    /// Maps objectIndex → bodyID, rebuilt each frame.
    private var currentIndexMap: [Int: String] = [:]
    /// Maps bodyID → PickLayer, rebuilt each frame.
    ///
    /// Routes GPU pick results to either `ViewportController.pickResult` or `widgetPickResult`.
    private var currentLayerMap: [String: PickLayer] = [:]
    /// Maps bodyID → primitive kinds with more than `PickResult.maxPrimitivesPerKind` primitives,
    /// rebuilt each frame, so picks of those kinds are flagged `isPrimitiveIndexAmbiguous`.
    private var currentAmbiguousKinds: [String: Set<PrimitiveKind>] = [:]

    /// Buffers for the per-frame adaptively-sampled analytic arc edges (issue #48): line
    /// segments and, with quad expansion, their quad strips.
    ///
    /// Written CPU-side each frame. Each frame takes buffers no earlier frame still has in flight
    /// and returns them when its command buffer completes, so the CPU never overwrites arc data
    /// the GPU is still drawing or picking from. Internal so tests can check reuse.
    lazy var arcBufferPool = FrameBufferPool(device: device)

    /// Drawable pixels per point, updated each live frame from the view.
    ///
    /// Scales the vertex pick sprite and the minimum edge pick width so pick footprints keep their
    /// size in points on Retina displays. Headless renders keep `1`.
    var pickContentScale: Float = 1

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

        // Clamp the requested MSAA count to one the device supports (#136 L2), using the same
        // mapping as OffscreenRenderer (#134). An unsupported count would otherwise fail pipeline
        // creation, `init` would return nil and MetalViewportView would show its fallback colour.
        let sampleCount = OffscreenRenderer.supportedSampleCount(
            controller.configuration.msaaSampleCount
        ) { device.supportsTextureSampleCount($0) }
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

        self.quadEdgePipeline = RendererSharedSetup.makeQuadEdgePipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat,
            vertexDescriptor: RendererSharedSetup.quadEdgeVertexDescriptor())

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
        self.skyboxPipeline = RendererSharedSetup.makeSkyboxPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, label: "skybox")

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

        // 1x line pick pipeline (edge picking) — pick_line_vertex applies wireframe_vertex's
        // depth bias (issue #182); fragment emits kind=1.
        self.pickLinePipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_line", library: library,
            vertexFunction: "pick_line_vertex", fragmentFunction: "pick_line_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDesc)

        // 1x arc pick pipeline (issue #48) — pick_line_vertex, biased like the drawn arc
        // (issue #182); fragment emits kind=1 with the per-draw arc index.
        self.pickArcPipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_arc", library: library,
            vertexFunction: "pick_line_vertex", fragmentFunction: "pick_arc_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: vertexDesc)

        // 1x quad edge pick pipeline — quad_edge_vertex expands segments to the visible edge
        // width; pick_quad_edge_fragment emits kind=1 with the segment (or arc) index.
        self.pickQuadEdgePipeline = RendererSharedSetup.makePipelineState(
            device: device, label: "pick_quad_edge", library: library,
            vertexFunction: "quad_edge_vertex", fragmentFunction: "pick_quad_edge_fragment",
            colorPixelFormat: .r32Uint, depthPixelFormat: .depth32Float,
            vertexDescriptor: RendererSharedSetup.quadEdgeVertexDescriptor())

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
            let depthOnlyPipeline = RendererSharedSetup.makeDepthOnlyPipelineState(
                device: device, library: library, vertexDescriptor: vertexDesc,
                label: "depth_only")
        else {
            return nil
        }
        self.depthOnlyPipeline = depthOnlyPipeline

        // Direct-mesh depth-only pipeline (Option A): same depth shaders, two-buffer descriptor.
        guard
            let depthOnlyDirectPipeline = RendererSharedSetup.makeDepthOnlyPipelineState(
                device: device, library: library, vertexDescriptor: directVertexDesc,
                label: "depth_only_direct")
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
            let outlinePipeline = RendererSharedSetup.makeSelectionOutlinePipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc,
                label: "selection_outline")
        else {
            return nil
        }
        self.outlinePipeline = outlinePipeline

        guard
            let outlineDirectPipeline = RendererSharedSetup.makeSelectionOutlinePipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc,
                label: "selection_outline_direct")
        else {
            return nil
        }
        self.outlineDirectPipeline = outlineDirectPipeline

        guard
            let stencilMaskPipeline = RendererSharedSetup.makeStencilMaskPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc,
                label: "selection_stencil_mask"),
            let stencilMaskDirectPipeline = RendererSharedSetup.makeStencilMaskPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc,
                label: "selection_stencil_mask_direct")
        else {
            return nil
        }
        self.stencilMaskPipeline = stencilMaskPipeline
        self.stencilMaskDirectPipeline = stencilMaskDirectPipeline

        // Highlight pipeline (per-triangle style buffer; alpha-composite over base shading)
        guard
            let highlightPipeline = RendererSharedSetup.makeHighlightPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc,
                label: "triangle_highlight")
        else {
            return nil
        }
        self.highlightPipeline = highlightPipeline

        guard
            let highlightDirectPipeline = RendererSharedSetup.makeHighlightPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc,
                label: "triangle_highlight_direct")
        else {
            return nil
        }
        self.highlightDirectPipeline = highlightDirectPipeline

        // --- Hardware tessellation pipelines (PN triangles) ---
        // Built through RendererSharedSetup, which OffscreenRenderer shares (#165).
        let quality = controller.configuration.renderingQuality

        if RendererSharedSetup.wantsTessellation(quality),
            let tessMgr = TessellationManager(device: device, library: library)
        {
            self.tessellationManager = tessMgr
            let maxTessFactor = TessellationManager.clampedMaxFactor(
                controller.configuration.tessellationMaxFactor)
            self.pipelineMaxTessFactor = maxTessFactor

            var diagErrors: [String] = []
            do {
                self.tessellatedShadedPipeline =
                    try RendererSharedSetup.makeTessellatedShadedPipelineState(
                        device: device, library: library, sampleCount: sampleCount,
                        depthFormat: depthFormat, maxFactor: maxTessFactor)
            } catch {
                self.tessellatedShadedPipeline = nil
                diagErrors.append("shaded: \(error.localizedDescription)")
            }
            do {
                self.tessellatedShadowPipeline =
                    try RendererSharedSetup.makeTessellatedShadowPipelineState(
                        device: device, library: library, maxFactor: maxTessFactor)
            } catch {
                self.tessellatedShadowPipeline = nil
                diagErrors.append("shadow: \(error.localizedDescription)")
            }
            do {
                self.tessellatedDepthOnlyPipeline =
                    try RendererSharedSetup.makeTessellatedDepthOnlyPipelineState(
                        device: device, library: library, maxFactor: maxTessFactor)
            } catch {
                self.tessellatedDepthOnlyPipeline = nil
                diagErrors.append("depth: \(error.localizedDescription)")
            }
            do {
                self.tessellatedPickPipeline =
                    try RendererSharedSetup.makeTessellatedPickPipelineState(
                        device: device, library: library, maxFactor: maxTessFactor)
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
            self.pipelineMaxTessFactor = 0
            #if DEBUG
                NSLog("[ViewportRenderer] Tessellation disabled")
            #endif
        }

        // --- Mesh shader pipelines (Apple9+ / M3+ / A17+) ---
        let supportsMeshShaders = device.supportsFamily(.apple9)
        // Mesh pipelines that failed to build, reported with the fallback below (#161).
        var meshPipelineErrors: [String] = []
        func meshPipeline(
            _ make: () throws -> MTLRenderPipelineState
        ) -> MTLRenderPipelineState? {
            do {
                return try make()
            } catch {
                meshPipelineErrors.append("\(error)")
                return nil
            }
        }
        if RendererSharedSetup.wantsMeshShaders(quality, device: device) {
            self.meshShaderShadedPipeline = meshPipeline {
                try RendererSharedSetup.makeMeshShaderShadedPipelineState(
                    device: device, library: library, sampleCount: sampleCount,
                    depthFormat: depthFormat)
            }
            // Both the shadow map (#162) and the SSAO/silhouette prepass honour section planes.
            self.meshShaderShadowPipeline = meshPipeline {
                try RendererSharedSetup.makeMeshShaderShadowPipelineState(
                    device: device, library: library)
            }
            self.meshShaderDepthOnlyPipeline = meshPipeline {
                try RendererSharedSetup.makeMeshShaderDepthOnlyPipelineState(
                    device: device, library: library)
            }
            self.meshShaderPickPipeline = meshPipeline {
                try RendererSharedSetup.makeMeshShaderPipelineState(
                    device: device, library: library, meshFunction: "meshlet_pick_mesh",
                    fragmentFunction: "meshlet_pick_fragment", colorPixelFormat: .r32Uint,
                    depthPixelFormat: .depth32Float, label: "mesh_pick")
            }
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
                NSLog(
                    "[ViewportRenderer] Mesh shaders: skipped (supports=%d)",
                    device.supportsFamily(.apple9))
            #endif
        }

        // An explicit, one-time report when the requested quality can't run (#161): it used to
        // drop silently to a lower path. `effectiveRenderingQuality` exposes the result.
        if let reason = Self.renderingQualityFallbackReason(
            requested: quality,
            tessellationEnabled: tessellationEnabled,
            meshShadersEnabled: meshShadersEnabled,
            supportsMeshShaders: supportsMeshShaders,
            pipelineErrors: meshPipelineErrors)
        {
            NSLog("[ViewportRenderer] %@", reason)
        }

        // SSAO post-process pipeline (1x, renders to drawable).
        // Output goes directly to the MSAA resolve target (drawable), so sampleCount = 1,
        // and the fullscreen pass needs no depth attachment.
        self.ssaoPipeline = RendererSharedSetup.makeSSAOCompositePipelineState(
            device: device, library: library, label: "ssao_postprocess")

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

        // Stencil test state: only draw where stencil != reference (the outline ring)
        guard let stencilTestState = RendererSharedSetup.makeStencilTestState(device: device)
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

        // Selection mask: the stencil reference over each selected body's whole silhouette, so
        // the outline pass is left with only the ring around it (#177).
        guard let selectionMaskState = RendererSharedSetup.makeStencilMarkState(device: device)
        else {
            return nil
        }
        self.selectionMaskState = selectionMaskState

        // Axis cylinders + grid-line cache.
        guard let gridAxisBuffers = GridAxisBuffers(device: device) else {
            return nil
        }
        self.gridAxisBuffers = gridAxisBuffers

        // Generate procedural matcap texture (256x256 RGBA8)
        guard let matcap = RendererSharedSetup.makeMatcapTexture(device: device) else {
            return nil
        }
        self.matcapTexture = matcap

        // Picking: texture manager (readback buffers come from `pickReadbackPool`)
        self.pickTextureManager = PickTextureManager(device: device)

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
        if view.bounds.width > 0 {
            pickContentScale = max(Float(view.drawableSize.width / view.bounds.width), 1)
        }

        let framesPerSecond = view.preferredFramesPerSecond > 0 ? view.preferredFramesPerSecond : 60
        encodeFrame(
            into: FrameRenderTargets(
                mainPassDescriptor: renderPassDescriptor,
                finalColorTexture: drawable.texture,
                size: view.drawableSize,
                presentable: drawable,
                frameBudget: 1.0 / Double(framesPerSecond)
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
        // 0.01/10000 range. Uses the cached per-body AABB when the cache is current for the
        // body's generation; otherwise (the body's first frame, or new geometry not yet
        // re-uploaded by `ensureBuffers` further down) computes it from the body, so the frame
        // that first shows a body is fitted too, not drawn with the wide fallback (#157).
        // The shadow frustum below reuses these model bounds, before the grid/axes widen them
        // for the clip fit (issue #183).
        let modelBounds = RendererSharedSetup.sceneBounds(of: bodiesBinding.wrappedValue) { body in
            let cached =
                self.bodyGeneration[body.id] == body.generation
                ? self.bodyBufferCache[body.id]?.localBoundingBox : nil
            return cached ?? body.boundingBox
        }
        let clearColor = renderPassDescriptor.colorAttachments[0].clearColor
        let gridAxisSettings = GridAxisSettings(
            configuration: controller.configuration,
            sceneBounds: modelBounds,
            background: SIMD4<Float>(
                Float(clearColor.red), Float(clearColor.green), Float(clearColor.blue),
                Float(clearColor.alpha))
        )
        let sceneBounds = GridAxisGeometry.clipBounds(
            sceneBounds: modelBounds,
            settings: gridAxisSettings,
            cameraState: cameraState,
            showGrid: controller.showGrid,
            showAxes: controller.showAxes
        )
        let clip = cameraState.clipPlanes(
            sceneBounds: RendererSharedSetup.clipBounds(
                sceneBounds, includingOverlaysOf: bodiesBinding.wrappedValue,
                in: RendererSharedSetup.wideViewFrustum(
                    cameraState: cameraState, aspectRatio: aspectRatio)
            ) { body in
                let cached =
                    self.bodyGeneration[body.id] == body.generation
                    ? self.bodyBufferCache[body.id]?.localBoundingBox : nil
                return cached ?? body.boundingBox
            })
        lastFrameClipPlanes = clip

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
            // The model bounds above: world space (issue #105), from the cached local boxes
            // rather than a per-frame vertex rescan, and without overlay bodies (issue #183).
            lightVP = RendererSharedSetup.lightViewProjection(
                lightDirection: lighting.keyLight.direction, sceneBounds: modelBounds)
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
        let (clipPlaneVecs, clipPlaneCount) = RendererSharedSetup.packClipPlanes(
            controller.clipPlanes)

        let shadowParams2 = SIMD4<Float>(
            lighting.shadowLightSize,
            lighting.shadowSearchRadius,
            controller.debugDisableCurvature ? 1.0 : 0.0,
            0
        )

        // Auto-load (or clear) the environment named by lighting.environmentMapURL/Data.
        environmentMapManager?.sync(with: lighting, commandQueue: commandQueue)
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
                unlit: controller.displayMode == .unlit,
                flatShading: !controller.displayMode.usesSmoothShading
            )
        }
        // Quad-expanded edges (body edges, arcs, overlay edges) and their pick footprints.
        let frameEdgeConfig = controller.configuration.edgeLineConfiguration
        let edgeViewportSize = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        let bodies = bodiesBinding.wrappedValue
        let displayMode = controller.displayMode
        let xrayOpacity = controller.xrayOpacity

        // Build index map for picking: objectIndex → bodyID
        var indexMap: [Int: String] = [:]
        var layerMap: [String: PickLayer] = [:]
        var ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
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
            // Bodies past the 16-bit object field get no pick ID (BodyUniforms writes the
            // sentinel for them), so they never enter the index map.
            if PickResult.pickObjectIndex(forOrdinal: objectIndex) != PickResult.sentinel {
                indexMap[Int(objectIndex)] = body.id
            }
            layerMap[body.id] = body.pickLayer
            if let bufs = bodyBufferCache[body.id] {
                frameVisibleBodies.append((body, bufs, objectIndex))
                let kinds = PickResult.ambiguousKinds(
                    triangleCount: bufs.indexCount / 3,
                    edgeSegmentCount: max(bufs.edgePrimitiveCount, body.arcs.count),
                    pointCount: bufs.pointVertexCount)
                if !kinds.isEmpty { ambiguousKinds[body.id] = kinds }
            }
            objectIndex += 1
        }
        currentIndexMap = indexMap
        currentLayerMap = layerMap
        currentAmbiguousKinds = ambiguousKinds

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
            let (tessBufferList, nonTessBodyCount) = tessellationFactorBatch(for: bodies)
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
                let maxFactor = RendererSharedBuffers.cappedMaxTessellationFactor(
                    requested: config.tessellationMaxFactor,
                    pipelineMaxFactor: pipelineMaxTessFactor)
                var factor = maxFactor
                if config.adaptiveTessellation {
                    lastUniformTessellationFactor = nil
                } else {
                    factor = uniformTessellationFactor(
                        config: config, maxFactor: maxFactor, frameBudget: targets.frameBudget,
                        commandBuffer: commandBuffer)
                    lastUniformTessellationFactor = factor
                }
                tessMgr.updateTessFactors(
                    tessBuffers: tessBufferList,
                    viewProjectionMatrix: viewProjection,
                    viewportSize: SIMD2<Float>(Float(w), Float(h)),
                    adaptive: config.adaptiveTessellation,
                    maxFactor: factor,
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
                    // shadow_clip_fragment reads the section clip planes from the scene uniforms,
                    // so clipped-away geometry casts no shadow (#162).
                    var shadowClipUniforms = makeUniforms()
                    shadowEncoder.setFragmentBytes(
                        &shadowClipUniforms, length: MemoryLayout<Uniforms>.size, index: 1)

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
                                RendererSharedSetup.encodeMeshletDraw(
                                    encoder: shadowEncoder, pipeline: msPipeline, meshlets: ml,
                                    vertexBuffer: vb, uniforms: &shadowUniforms)
                            } else if useTessellation, let tess = buffers.tessellation,
                                let tessPipeline = tessellatedShadowPipeline
                            {
                                RendererSharedSetup.encodeTessellatedDraw(
                                    encoder: shadowEncoder, pipeline: tessPipeline,
                                    tessellation: tess, uniforms: &shadowUniforms)
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
            RendererSharedSetup.encodeSkybox(
                encoder: mainEncoder, pipeline: skyPipeline, depthState: skyDepth,
                viewProjection: viewProjection, lighting: lighting, cubeMap: cubeMap)
            mainEncoder.setDepthStencilState(depthState)
        }

        // 1. Draw grid
        if controller.showGrid {
            RendererSharedSetup.encodeGrid(
                encoder: mainEncoder,
                dotPipeline: gridPipeline,
                linePipeline: axisPipeline,
                fillDepthState: transparentSurfaceDepthState,
                depthState: depthState,
                buffers: gridAxisBuffers,
                viewProjection: viewProjection,
                cameraState: cameraState,
                settings: gridAxisSettings
            )
        }

        // 2. Draw axes
        if controller.showAxes {
            RendererSharedSetup.encodeAxes(
                encoder: mainEncoder,
                pipeline: axisPipeline,
                buffers: gridAxisBuffers,
                viewProjection: viewProjection,
                cameraState: cameraState,
                settings: gridAxisSettings
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
            // Translucent geometry bodies' surfaces are deferred to the sorted transparent
            // pass below (a body with edges only — no mesh — is unaffected). Their edges still
            // draw here, so a translucent body keeps its edges, and `.xray` (which makes every
            // surface translucent) has them.
            let defersSurface =
                body.renderLayer == .geometry
                && buffers.vertexBuffer != nil && buffers.indexCount > 0
                && displayMode.surfaceOpacity(
                    forMaterialOpacity: body.effectiveMaterial.opacity, xrayOpacity: xrayOpacity)
                    < 1.0
            if defersSurface {
                transparentDraws.append((body, buffers, bodyObjectIndex))
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
            if displayMode.showsSurfaces, hasMesh, !defersSurface {
                mainEncoder.setDepthStencilState(depthState)

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

                // Per-triangle highlights (issue #25) straight over the surface they style, so
                // they composite before the translucent pass rather than over it (#171).
                if buffers.triangleStyleBuffer != nil {
                    mainEncoder.setDepthStencilState(highlightDepthState)
                    encodeTriangleHighlight(mainEncoder, buffers: buffers, uniforms: &uniforms)
                    mainEncoder.setDepthStencilState(depthState)
                }
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

                let edgeConfig = controller.configuration.edgeLineConfiguration
                let useQuadExpansion = edgeConfig.useQuadExpansion

                if useQuadExpansion,
                    let quadPipeline = quadEdgePipeline,
                    let quadEdgeVB = buffers.quadEdgeVertexBuffer
                {
                    // Quad-expanded pipeline: variable width + dash patterns
                    var edgeUniforms = EdgeUniforms(
                        uniforms: uniforms, configuration: edgeConfig,
                        viewportSize: edgeViewportSize)
                    mainEncoder.setRenderPipelineState(quadPipeline)
                    mainEncoder.setVertexBuffer(quadEdgeVB, offset: 0, index: 0)
                    mainEncoder.setVertexBytes(
                        &edgeUniforms,
                        length: MemoryLayout<EdgeUniforms>.size,
                        index: 1)
                    mainEncoder.setFragmentBytes(
                        &edgeUniforms,
                        length: MemoryLayout<EdgeUniforms>.size,
                        index: 1)
                    mainEncoder.setFragmentBytes(
                        &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    // The CPU buffer already contains the six-vertex triangle strip per segment.
                    mainEncoder.drawPrimitives(
                        type: .triangleStrip,
                        vertexStart: 0,
                        vertexCount: buffers.quadEdgeVertexCount)
                } else {
                    // Native Metal line pipeline (backward compatible)
                    mainEncoder.setRenderPipelineState(wireframePipeline)
                    mainEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                    mainEncoder.setVertexBytes(
                        &uniforms,
                        length: MemoryLayout<Uniforms>.size,
                        index: 1)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    mainEncoder.drawPrimitives(
                        type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
                }
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
                let selState: UInt32 =
                    selectedIDs.contains(d.body.id) ? 1 : (hoveredID == d.body.id ? 2 : 0)
                var bodyUniforms = BodyUniforms(
                    body: d.body, objectIndex: d.objectIndex, isSelected: selState)
                bodyUniforms.color.w = displayMode.surfaceOpacity(
                    forMaterialOpacity: bodyUniforms.color.w, xrayOpacity: xrayOpacity)
                // The far-facing triangles first, then the camera-facing ones, so the body's near
                // wall composites over its far wall. Each half carries its own per-triangle
                // highlights, drawn straight after it in the same order: a highlight on the far
                // wall is seen through the near wall, and one on a body behind is seen through
                // the bodies in front (#171). Every triangle is drawn in exactly one half, so a
                // mis-wound mesh only composites out of order; it never loses triangles.
                for culled in Self.translucentCullOrder {
                    mainEncoder.setCullMode(culled)
                    mainEncoder.setDepthStencilState(transparentSurfaceDepthState)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                    mainEncoder.setFragmentBytes(
                        &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    encodeShadedSurface(
                        mainEncoder, buffers: d.buffers, uniforms: &uniforms,
                        useMeshShaders: useMeshShaders, useTessellation: useTessellation)
                    if d.buffers.triangleStyleBuffer != nil {
                        mainEncoder.setDepthStencilState(highlightDepthState)
                        encodeTriangleHighlight(
                            mainEncoder, buffers: d.buffers, uniforms: &uniforms)
                    }
                }
            }
            mainEncoder.setCullMode(.none)
            mainEncoder.setDepthStencilState(transparentSurfaceDepthState)
        }

        // 3.35 Analytic arc edge pass (issue #48).
        // Adaptively samples each visible body's `arcs` to line segments by their
        // projected size, so circular feature edges stay smooth at any zoom
        // independent of mesh density. Per-arc segment ranges are recorded in
        // `frameArcDraws` and the data lives in `frameArcLineBuffer`, so the pick pass
        // below re-draws the same segments to the pick texture without re-sampling.
        // With quad expansion on, the same samples are also expanded into quad strips (from
        // `frameArcQuadBuffer`, ranges `quadStart`/`quadCount`) so arcs get the configured width and
        // dash pattern like polyline edges, and their pick footprint matches.
        var frameArcDraws: [FrameArcDraw] = []
        let arcBodies = frameVisibleBodies.filter { !$0.body.arcs.isEmpty }
        let useQuadArcs = frameEdgeConfig.useQuadExpansion && quadEdgePipeline != nil
        var frameArcQuadBuffer: MTLBuffer?
        var frameArcLineBuffer: MTLBuffer?

        /// Draws one of this frame's sampled arcs; the caller sets the depth-stencil state.
        func encodeArc(_ d: FrameArcDraw) {
            var uniforms = makeUniforms()
            uniforms.modelMatrix = d.body.transform
            var arcBodyUniforms = BodyUniforms(
                body: d.body, objectIndex: d.objectIndex, isSelected: 0)
            if (bodyBufferCache[d.body.id]?.indexCount ?? 0) == 0 {
                arcBodyUniforms.metallic = -1.0  // edge-only body: use its colour directly
            }
            mainEncoder.setFragmentBytes(
                &arcBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            if let quadBuf = frameArcQuadBuffer, let quadPipeline = quadEdgePipeline {
                var edgeUniforms = EdgeUniforms(
                    uniforms: uniforms, configuration: frameEdgeConfig,
                    viewportSize: edgeViewportSize)
                mainEncoder.setRenderPipelineState(quadPipeline)
                mainEncoder.setVertexBuffer(quadBuf, offset: 0, index: 0)
                mainEncoder.setVertexBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: d.quadStart, vertexCount: d.quadCount)
            } else if let arcBuf = frameArcLineBuffer {
                mainEncoder.setRenderPipelineState(wireframePipeline)
                mainEncoder.setVertexBuffer(arcBuf, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.drawPrimitives(type: .line, vertexStart: d.start, vertexCount: d.count)
            }
        }

        if !arcBodies.isEmpty {
            let vpSize = SIMD2<Float>(Float(w), Float(h))
            var arcVerts: [Float] = []
            var arcQuadVerts: [Float] = []
            for entry in arcBodies {
                // Match the edge-pass visibility rule: show feature edges when the
                // display mode draws edges, or when the body is edge-only.
                let bodyHasMesh = entry.buffers.indexCount > 0
                guard displayMode.showsEdges || !bodyHasMesh else { continue }

                let mvp = viewProjection * entry.body.transform
                for (arcIndex, arc) in entry.body.arcs.enumerated() {
                    let segs = ArcSampling.segmentCount(arc: arc, mvp: mvp, viewportSize: vpSize)
                    let startVert = arcVerts.count / 6
                    let points = RendererSharedBuffers.sampledArcPolyline(arc, segmentCount: segs)
                    for (prev, cur) in zip(points, points.dropFirst()) {
                        arcVerts.append(contentsOf: [
                            prev.x, prev.y, prev.z, 0, 0, 0,
                            cur.x, cur.y, cur.z, 0, 0, 0,
                        ])
                    }
                    let count = arcVerts.count / 6 - startVert
                    let quadStart = arcQuadVerts.count / 9
                    if useQuadArcs {
                        arcQuadVerts += RendererSharedBuffers.quadEdgeLineVertices(from: [points])
                    }
                    let quadCount = arcQuadVerts.count / 9 - quadStart
                    if count > 0 {
                        frameArcDraws.append(
                            (
                                entry.body, entry.objectIndex, arcIndex, startVert, count,
                                quadStart, quadCount
                            ))
                    }
                }
            }

            if !arcVerts.isEmpty,
                let arcBuf = arcBufferPool.acquire(
                    byteCount: arcVerts.count * MemoryLayout<Float>.size)
            {
                arcBufferPool.release(arcBuf, after: commandBuffer)
                frameArcLineBuffer = arcBuf
                arcVerts.withUnsafeBytes { raw in
                    arcBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
                if useQuadArcs, !arcQuadVerts.isEmpty,
                    let quadBuf = arcBufferPool.acquire(
                        byteCount: arcQuadVerts.count * MemoryLayout<Float>.size)
                {
                    arcBufferPool.release(quadBuf, after: commandBuffer)
                    arcQuadVerts.withUnsafeBytes { raw in
                        quadBuf.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                    }
                    frameArcQuadBuffer = quadBuf
                }
                // Overlay-layer arcs are drawn in the overlay pass, on top of everything (#170).
                mainEncoder.setDepthStencilState(depthState)
                for d in frameArcDraws where d.body.renderLayer == .geometry {
                    encodeArc(d)
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
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                mainEncoder.setVertexBytes(
                    &params, length: MemoryLayout<PointParamsSwift>.size, index: 3)

                mainEncoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
            }
        }

        // 3.9 Selection mask: stencil-mark each selected or hovered geometry body's whole
        // silhouette, without drawing colour or testing depth. Per-triangle highlights were drawn
        // with the surfaces they style, above (#171). The mask covers the parts of the body
        // hidden behind nearer geometry too, so the outline below is the ring around the body and
        // never paints over an occluder (#177); it covers bodies drawn translucent or without
        // surfaces (`.wireframe`) alike. Overlay bodies get no outline.
        var outlinedBodyIDs: Set<String> = []
        for (body, buffers, _) in frameVisibleBodies
        where body.renderLayer == .geometry && body.primitiveKind != .point
            && (selectedIDs.contains(body.id) || hoveredID == body.id)
        {
            guard let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                buffers.indexCount > 0
            else { continue }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            mainEncoder.setDepthStencilState(selectionMaskState)
            mainEncoder.setStencilReferenceValue(1)
            mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
            if let nb = buffers.normalBuffer {
                mainEncoder.setRenderPipelineState(stencilMaskDirectPipeline)
                mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
            } else {
                mainEncoder.setRenderPipelineState(stencilMaskPipeline)
            }
            mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.drawIndexedPrimitives(
                type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                indexBuffer: ib, indexBufferOffset: 0)
            outlinedBodyIDs.insert(body.id)
        }

        // 4. Selection outline pass (stencil test: draw only where stencil != 1). Only bodies
        // marked in the stencil above, all of them geometry-layer: overlay bodies are drawn later
        // with always-pass depth and never mark the stencil, so they get no outline.
        if !outlinedBodyIDs.isEmpty {
            mainEncoder.setDepthStencilState(stencilTestState)
            mainEncoder.setStencilReferenceValue(1)

            for body in bodies where body.isVisible && outlinedBodyIDs.contains(body.id) {
                guard let buffers = bodyBufferCache[body.id],
                    let vb = buffers.vertexBuffer,
                    let ib = buffers.indexBuffer,
                    buffers.indexCount > 0
                else { continue }

                let isHover = (hoveredID == body.id && !selectedIDs.contains(body.id))
                let style =
                    isHover
                    ? controller.configuration.hoverOutline
                    : controller.configuration.selectionOutline
                guard style.width > 0 else { continue }

                // Width is in drawable pixels; the vertex shader expands along the screen-space
                // normal, so the ring no longer scales with the body's size (#136 L4).
                var outlineParams = SelectionOutlineParamsSwift(
                    viewProjectionMatrix: viewProjection,
                    modelMatrix: body.transform,
                    outlineColor: style.color,
                    outlineWidth: style.width,
                    viewportSize: SIMD2<Float>(
                        Float(max(drawableSize.width, 1)), Float(max(drawableSize.height, 1)))
                )

                if let nb = buffers.normalBuffer {
                    // Direct-mesh body: position@0 + normal@2 (the outline expands along it).
                    mainEncoder.setRenderPipelineState(outlineDirectPipeline)
                    mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                } else {
                    mainEncoder.setRenderPipelineState(outlinePipeline)
                }
                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                mainEncoder.setVertexBytes(
                    &outlineParams, length: MemoryLayout<SelectionOutlineParamsSwift>.size, index: 1
                )
                mainEncoder.setFragmentBytes(
                    &outlineParams, length: MemoryLayout<SelectionOutlineParamsSwift>.size, index: 1
                )
                // Section clip planes (the outline fragment discards clipped fragments).
                var outlineUniforms = makeUniforms()
                mainEncoder.setFragmentBytes(
                    &outlineUniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                mainEncoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: buffers.indexCount,
                    indexType: .uint32,
                    indexBuffer: ib,
                    indexBufferOffset: 0
                )
            }
        }

        // 5. Overlay pass — RenderLayer.overlay bodies, drawn after the selection outline with
        // always-pass depth so they remain visible through any geometry. Uses the standard
        // shaded + wireframe pipelines (no tessellation / mesh shader paths, since manipulator
        // widgets are simple meshes). Widgets aren't model geometry (#170): their surfaces draw
        // in every display mode, `.wireframe` included, and receive no shadows (scene geometry
        // must not shadow a gizmo). Their edges and arcs follow the display mode's edge rule like
        // geometry edges, and are drawn on top too. The overlay pick pass stamps exactly this.
        let overlayDraws = frameVisibleBodies.filter { $0.body.renderLayer == .overlay }
        if !overlayDraws.isEmpty {
            mainEncoder.setDepthStencilState(overlayDepthState)
            // The image-based-lighting maps shaded_fragment samples. The geometry passes bind them
            // per draw, so with no geometry surface drawn this frame (`.wireframe`, a scene of
            // widgets only) they were never bound for the widgets.
            if let envMgr = environmentMapManager, envMgr.hasEnvironmentMap {
                if let spec = envMgr.prefilteredSpecularMap {
                    mainEncoder.setFragmentTexture(spec, index: 2)
                }
                if let diff = envMgr.irradianceMap {
                    mainEncoder.setFragmentTexture(diff, index: 3)
                }
                if let brdf = envMgr.brdfLUT { mainEncoder.setFragmentTexture(brdf, index: 4) }
            }
            for (body, buffers, bodyObjectIndex) in overlayDraws where body.primitiveKind != .point
            {
                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                uniforms.shadowParams.z = 0
                var bodyUniforms = BodyUniforms(
                    body: body, objectIndex: bodyObjectIndex, isSelected: 0)

                // Direct-mesh overlay bodies draw via directMeshPipeline (handled below), so
                // they are NOT excluded here.
                let hasMesh =
                    buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                    && buffers.indexCount > 0
                let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0

                if hasMesh, let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer {
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

                let shouldDrawEdges = hasEdges && displayMode.drawsEdges(bodyHasMesh: hasMesh)
                if shouldDrawEdges, let edgeVB = buffers.edgeVertexBuffer {
                    var edgeBodyUniforms = bodyUniforms
                    if !hasMesh {
                        edgeBodyUniforms.metallic = -1.0
                    }
                    mainEncoder.setFragmentBytes(
                        &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                    if frameEdgeConfig.useQuadExpansion, let quadPipeline = quadEdgePipeline,
                        let quadEdgeVB = buffers.quadEdgeVertexBuffer,
                        buffers.quadEdgeVertexCount > 0
                    {
                        // Same width / dash / intensity as geometry-layer edges.
                        var edgeUniforms = EdgeUniforms(
                            uniforms: uniforms, configuration: frameEdgeConfig,
                            viewportSize: edgeViewportSize)
                        mainEncoder.setRenderPipelineState(quadPipeline)
                        mainEncoder.setVertexBuffer(quadEdgeVB, offset: 0, index: 0)
                        mainEncoder.setVertexBytes(
                            &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                        mainEncoder.setFragmentBytes(
                            &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                        mainEncoder.drawPrimitives(
                            type: .triangleStrip, vertexStart: 0,
                            vertexCount: buffers.quadEdgeVertexCount)
                    } else {
                        mainEncoder.setRenderPipelineState(wireframePipeline)
                        mainEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                        mainEncoder.setVertexBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        mainEncoder.setFragmentBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        mainEncoder.drawPrimitives(
                            type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
                    }
                }

                // The body's arcs, sampled with the geometry arcs above but drawn here, on top.
                for d in frameArcDraws where d.body.id == body.id {
                    encodeArc(d)
                }
            }

            // Overlay point bodies (snap markers and the like): the geometry point pass above
            // only takes `.geometry` bodies, so without this they were never drawn at all.
            if let pointPipeline = visiblePointPipeline {
                let pxPerWorldFactor = Float(drawableSize.height) * projMatrix.columns.1.y * 0.5
                for (body, buffers, _) in overlayDraws where body.primitiveKind == .point {
                    guard let positionBuf = buffers.pointPositionBuffer,
                        buffers.pointVertexCount > 0
                    else { continue }
                    var uniforms = makeUniforms()
                    uniforms.modelMatrix = body.transform
                    var params = PointParamsSwift(
                        baseColor: body.color,
                        worldRadius: body.pointRadius,
                        pxPerWorldFactor: pxPerWorldFactor,
                        useVertexColors: buffers.pointColorBuffer != nil ? 1 : 0
                    )
                    mainEncoder.setRenderPipelineState(pointPipeline)
                    mainEncoder.setVertexBuffer(positionBuf, offset: 0, index: 0)
                    mainEncoder.setVertexBuffer(
                        buffers.pointColorBuffer ?? positionBuf, offset: 0, index: 1)
                    mainEncoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                    mainEncoder.setFragmentBytes(
                        &uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
                    mainEncoder.setVertexBytes(
                        &params, length: MemoryLayout<PointParamsSwift>.size, index: 3)
                    mainEncoder.drawPrimitives(
                        type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
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

                        // Faces are stamped only when the display mode draws them, so hidden
                        // surfaces (`.wireframe`) can't win a pick.
                        if displayMode.showsSurfaces, hasMesh, let vb = buffers.vertexBuffer,
                            let ib = buffers.indexBuffer
                        {
                            var uniforms = makeUniforms()
                            uniforms.modelMatrix = body.transform
                            var bodyUniforms = BodyUniforms(
                                body: body, objectIndex: bodyObjectIndex)

                            if useMeshShaders, let ml = buffers.meshlets,
                                let msPipeline = meshShaderPickPipeline
                            {
                                pickEncoder.setFragmentBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                RendererSharedSetup.encodeMeshletDraw(
                                    encoder: pickEncoder, pipeline: msPipeline, meshlets: ml,
                                    vertexBuffer: vb, uniforms: &uniforms)
                            } else if useTessellation, let tess = buffers.tessellation,
                                let tessPipeline = tessellatedPickPipeline
                            {
                                pickEncoder.setFragmentBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
                                    &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2
                                )
                                RendererSharedSetup.encodeTessellatedDraw(
                                    encoder: pickEncoder, pipeline: tessPipeline,
                                    tessellation: tess, uniforms: &uniforms)
                            } else if let nb = buffers.normalBuffer {
                                // Direct-mesh body (Option A): position@0 + normal@2.
                                pickEncoder.setRenderPipelineState(pickShadedDirectPipeline)
                                pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                                pickEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                                pickEncoder.setVertexBytes(
                                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                                pickEncoder.setFragmentBytes(
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

                    // Edge, arc and vertex stamps. Geometry bodies stamp them depth-tested
                    // (`.lessEqual`, so edges co-planar with a face and vertices on an edge win
                    // the tie); overlay bodies stamp them in the overlay pick pass below. With
                    // quad expansion on, edges and arcs are picked as quads as wide as the visible
                    // edge (at least 1 pt), not as 1 px lines. The fragments encode kind=1 with the
                    // line-segment (or arc) index, and kind=2 with the vertex index.
                    let quadPickPipeline =
                        frameEdgeConfig.useQuadExpansion ? pickQuadEdgePipeline : nil
                    let pickEdgeWidth = max(frameEdgeConfig.width, pickContentScale)

                    /// Stamps a body's edge polylines, as the visible edge pass draws them.
                    func stampEdges(
                        _ body: ViewportBody, _ buffers: BodyBuffers, objectIndex: UInt32
                    ) {
                        guard let edgeVB = buffers.edgeVertexBuffer, buffers.edgePrimitiveCount > 0
                        else { return }
                        var uniforms = makeUniforms()
                        uniforms.modelMatrix = body.transform
                        var bodyUniforms = BodyUniforms(body: body, objectIndex: objectIndex)
                        if let quadPickPipeline, let quadEdgeVB = buffers.quadEdgeVertexBuffer,
                            buffers.quadEdgeVertexCount > 0
                        {
                            var edgeUniforms = EdgeUniforms(
                                uniforms: uniforms, configuration: frameEdgeConfig,
                                viewportSize: edgeViewportSize, width: pickEdgeWidth)
                            var primSource = SIMD2<UInt32>(0, 0)  // segment = triangle / 6
                            pickEncoder.setRenderPipelineState(quadPickPipeline)
                            pickEncoder.setVertexBuffer(quadEdgeVB, offset: 0, index: 0)
                            pickEncoder.setVertexBytes(
                                &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.setFragmentBytes(
                                &primSource, length: MemoryLayout<SIMD2<UInt32>>.size, index: 3)
                            pickEncoder.drawPrimitives(
                                type: .triangleStrip, vertexStart: 0,
                                vertexCount: buffers.quadEdgeVertexCount)
                            return
                        }
                        guard let pickLinePipeline else { return }
                        pickEncoder.setRenderPipelineState(pickLinePipeline)
                        pickEncoder.setVertexBuffer(edgeVB, offset: 0, index: 0)
                        pickEncoder.setVertexBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        pickEncoder.setFragmentBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        pickEncoder.setFragmentBytes(
                            &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                        pickEncoder.drawPrimitives(
                            type: .line, vertexStart: 0, vertexCount: buffers.edgeVertexCount)
                    }

                    /// Re-draws one of this frame's sampled arcs (from `frameArcQuadBuffer` or
                    /// `frameArcLineBuffer`, ranges in `frameArcDraws`), stamping the ARC index.
                    func stampArc(_ d: FrameArcDraw) {
                        var uniforms = makeUniforms()
                        uniforms.modelMatrix = d.body.transform
                        var bodyUniforms = BodyUniforms(body: d.body, objectIndex: d.objectIndex)
                        let arcIndex = UInt32(truncatingIfNeeded: d.arcIndex)
                        if let quadPickPipeline, let quadBuf = frameArcQuadBuffer {
                            // Quad arcs: same footprint as the visible arc (the samples drawn above).
                            var edgeUniforms = EdgeUniforms(
                                uniforms: uniforms, configuration: frameEdgeConfig,
                                viewportSize: edgeViewportSize, width: pickEdgeWidth)
                            var primSource = SIMD2<UInt32>(arcIndex, 1)  // fixed arc index
                            pickEncoder.setRenderPipelineState(quadPickPipeline)
                            pickEncoder.setVertexBuffer(quadBuf, offset: 0, index: 0)
                            pickEncoder.setVertexBytes(
                                &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.setFragmentBytes(
                                &primSource, length: MemoryLayout<SIMD2<UInt32>>.size, index: 3)
                            pickEncoder.drawPrimitives(
                                type: .triangleStrip, vertexStart: d.quadStart,
                                vertexCount: d.quadCount)
                        } else if let pickArcPipeline, let arcBuf = frameArcLineBuffer {
                            var arcPrimID = arcIndex
                            pickEncoder.setRenderPipelineState(pickArcPipeline)
                            pickEncoder.setVertexBuffer(arcBuf, offset: 0, index: 0)
                            pickEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.setFragmentBytes(
                                &arcPrimID, length: MemoryLayout<UInt32>.size, index: 3)
                            pickEncoder.drawPrimitives(
                                type: .line, vertexStart: d.start, vertexCount: d.count)
                        }
                    }

                    /// Stamps a body's `vertices` as point sprites with an 8 pt footprint.
                    func stampVertices(
                        _ body: ViewportBody, _ buffers: BodyBuffers, objectIndex: UInt32
                    ) {
                        guard let pickPointPipeline, let pointVB = buffers.pointVertexBuffer,
                            buffers.pointVertexCount > 0
                        else { return }
                        var uniforms = makeUniforms()
                        uniforms.modelMatrix = body.transform
                        var bodyUniforms = BodyUniforms(body: body, objectIndex: objectIndex)
                        // 8 pt clickable footprint, in drawable pixels.
                        var pointSpriteSize = 8 * pickContentScale
                        pickEncoder.setRenderPipelineState(pickPointPipeline)
                        pickEncoder.setVertexBuffer(pointVB, offset: 0, index: 0)
                        pickEncoder.setVertexBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        pickEncoder.setVertexBytes(
                            &pointSpriteSize, length: MemoryLayout<Float>.size, index: 2)
                        pickEncoder.setFragmentBytes(
                            &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                        pickEncoder.setFragmentBytes(
                            &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                        pickEncoder.drawPrimitives(
                            type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
                    }

                    // Geometry-layer edges: bodies with `edgeIndices` set, when the display mode
                    // draws their edges (`.shaded` hides them, so they can't win a pick).
                    pickEncoder.setDepthStencilState(pickEdgeOrPointDepthState)
                    for (body, buffers, bodyObjectIndex) in frameVisibleBodies
                    where body.renderLayer == .geometry && body.isPickable
                        && !body.edgeIndices.isEmpty
                        && displayMode.drawsEdges(bodyHasMesh: buffers.indexCount > 0)
                    {
                        stampEdges(body, buffers, objectIndex: bodyObjectIndex)
                    }
                    // Geometry-layer arcs (issue #48), each drawn separately so the fragment
                    // stamps its arc index.
                    for d in frameArcDraws
                    where d.body.renderLayer == .geometry && d.body.isPickable {
                        stampArc(d)
                    }
                    // Geometry-layer vertices: bodies with `vertices` set.
                    for (body, buffers, bodyObjectIndex) in frameVisibleBodies
                    where body.renderLayer == .geometry && body.isPickable
                        && !body.vertices.isEmpty
                    {
                        stampVertices(body, buffers, objectIndex: bodyObjectIndex)
                    }

                    // Overlay pick pass (#170): RenderLayer.overlay bodies stamp everything the
                    // overlay pass draws (surfaces in every display mode, the edges and arcs the
                    // mode shows, and vertices) with always-pass depth, so a widget wins the pick
                    // over geometry in front of it, as it is drawn over it. Edges are stamped
                    // whether or not `edgeIndices` is set: a gizmo ring drawn as a polyline is
                    // grabbed by its edges. Within a body, edges and vertices are stamped after
                    // its faces so they win; a later overlay body wins over an earlier one, as it
                    // is drawn over it.
                    pickEncoder.setDepthStencilState(overlayDepthState)
                    for (body, buffers, bodyObjectIndex) in frameVisibleBodies
                    where body.renderLayer == .overlay && body.isPickable {
                        let hasMesh =
                            buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                            && buffers.indexCount > 0
                        if body.primitiveKind != .point, hasMesh, let vb = buffers.vertexBuffer,
                            let ib = buffers.indexBuffer
                        {
                            var uniforms = makeUniforms()
                            uniforms.modelMatrix = body.transform
                            var bodyUniforms = BodyUniforms(
                                body: body, objectIndex: bodyObjectIndex)
                            if let nb = buffers.normalBuffer {
                                // Direct-mesh overlay body (Option A): position@0 + normal@2.
                                pickEncoder.setRenderPipelineState(pickShadedDirectPipeline)
                                pickEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                            } else {
                                pickEncoder.setRenderPipelineState(pickShadedPipeline)
                            }
                            pickEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                            pickEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            pickEncoder.setFragmentBytes(
                                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                            pickEncoder.drawIndexedPrimitives(
                                type: .triangle, indexCount: buffers.indexCount,
                                indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
                        }
                        if body.primitiveKind != .point,
                            displayMode.drawsEdges(bodyHasMesh: hasMesh)
                        {
                            stampEdges(body, buffers, objectIndex: bodyObjectIndex)
                        }
                        for d in frameArcDraws where d.body.id == body.id {
                            stampArc(d)
                        }
                        stampVertices(body, buffers, objectIndex: bodyObjectIndex)
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
                    guard let buffers = bodyBufferCache[body.id],
                        Self.writesSSAODepth(body)
                    else {
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
                        // Issue #107: every other draw site in this file sets this explicitly;
                        // this one didn't, so every body depth-rendered at its local origin
                        // instead of its real position, corrupting the SSAO/silhouette pass's
                        // depth buffer for any transformed body.
                        uniforms.modelMatrix = body.transform

                        if useMeshShaders, let ml = buffers.meshlets,
                            let msPipeline = meshShaderDepthOnlyPipeline
                        {
                            depthEncoder.setFragmentBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            RendererSharedSetup.encodeMeshletDraw(
                                encoder: depthEncoder, pipeline: msPipeline, meshlets: ml,
                                vertexBuffer: vb, uniforms: &uniforms)
                        } else if useTessellation, let tess = buffers.tessellation,
                            let tessPipeline = tessellatedDepthOnlyPipeline
                        {
                            depthEncoder.setFragmentBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            RendererSharedSetup.encodeTessellatedDraw(
                                encoder: depthEncoder, pipeline: tessPipeline, tessellation: tess,
                                uniforms: &uniforms)
                        } else if let nb = buffers.normalBuffer {
                            // Direct-mesh body (Option A): position@0 + normal@2.
                            depthEncoder.setRenderPipelineState(depthOnlyDirectPipeline)
                            depthEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                            depthEncoder.setVertexBuffer(nb, offset: 0, index: 2)
                            depthEncoder.setVertexBytes(
                                &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                            depthEncoder.setFragmentBytes(
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
                            depthEncoder.setFragmentBytes(
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
                    // Auto-focus: use distance to the world-space scene center
                    dofFocalDist = Self.autoFocusDistance(
                        bodies: bodies, cameraPosition: cameraState.position,
                        fallback: cameraState.distance)
                }
                var ssaoParams = SSAOParamsSwift(
                    texelSize: SIMD2<Float>(1.0 / Float(w), 1.0 / Float(h)),
                    radius: lighting.ssaoRadius,
                    // The composite also runs for silhouettes alone; keep AO off unless enabled.
                    intensity: lighting.enableSSAO ? lighting.ssaoIntensity : 0.0,
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

        // Prune cache entries for bodies no longer in the scene. Walk `bodyGeneration`, a
        // superset of the buffer cache: an emptied body keeps a generation with no buffers.
        let activeIDs = Set(bodies.map(\.id))
        for id in bodyGeneration.keys where !activeIDs.contains(id) {
            bodyBufferCache.removeValue(forKey: id)
            bodyGeneration.removeValue(forKey: id)
            bodyStyleGeneration.removeValue(forKey: id)
        }

        if let presentable = targets.presentable {
            commandBuffer.present(presentable)
        }
        commandBuffer.commit()
    }

    // MARK: - Per-triangle styles

    /// The body's per-triangle style buffer (see `RendererSharedBuffers.makeTriangleStyleBuffer`).
    private func makeTriangleStyleBuffer(for body: ViewportBody, triangleCount: Int) -> MTLBuffer? {
        RendererSharedBuffers.makeTriangleStyleBuffer(
            device: device, body: body, triangleCount: triangleCount)
    }

    // MARK: - Depth-of-field autofocus

    /// Distance from `cameraPosition` to the mean of the visible geometry bodies' world-space
    /// bounding-box centres, or `fallback` when no such body has bounds.
    ///
    /// Bounds are transformed by each body's `transform` first, so a body positioned by its
    /// transform is focused where it is drawn rather than at its local origin (#136 M12).
    /// Overlay-layer bodies are ignored.
    nonisolated static func autoFocusDistance(
        bodies: [ViewportBody], cameraPosition: SIMD3<Float>, fallback: Float
    ) -> Float {
        var sceneCenter = SIMD3<Float>.zero
        var count: Float = 0
        for body in bodies where body.isVisible && body.renderLayer == .geometry {
            guard let bb = body.boundingBox?.transformed(by: body.transform) else { continue }
            sceneCenter += bb.center
            count += 1
        }
        guard count > 0 else { return fallback }
        return simd_distance(cameraPosition, sceneCenter / count)
    }

    // MARK: - SSAO depth prepass classification

    /// Whether `body` belongs in the SSAO / silhouette depth prepass.
    ///
    /// Mirrors how the main pass classifies bodies: overlay-layer bodies (manipulators, gizmos)
    /// draw in their own pass on top of everything, point clouds draw as sprites, and translucent
    /// bodies go through the sorted transparent pass without writing depth. None of them belongs
    /// in the depth the post-process reads, or they pick up silhouettes and ambient occlusion
    /// (#136 M11).
    nonisolated static func writesSSAODepth(_ body: ViewportBody) -> Bool {
        body.renderLayer == .geometry
            && body.primitiveKind != .point
            && body.effectiveMaterial.opacity >= 1.0
    }

    // MARK: - Rendering quality

    /// The ``RenderingQuality`` this renderer actually draws with.
    ///
    /// Equal to `ViewportConfiguration.renderingQuality` when the device supports it and its
    /// pipelines built. Lower when they didn't: `.maximum` needs mesh shaders (Apple9 GPU family:
    /// M3 / A17 Pro or later) and runs `.enhanced` without them, and `.enhanced` runs `.standard`
    /// if its tessellation pipelines fail to build. The fallback is also logged once, when the
    /// renderer is created. Fixed for the renderer's lifetime: the quality is read at creation.
    public var effectiveRenderingQuality: RenderingQuality {
        if meshShadersEnabled { return .maximum }
        return tessellationEnabled ? .enhanced : .standard
    }

    /// The one-line explanation logged when `requested` can't run, or `nil` when it runs as asked.
    nonisolated static func renderingQualityFallbackReason(
        requested: RenderingQuality,
        tessellationEnabled: Bool,
        meshShadersEnabled: Bool,
        supportsMeshShaders: Bool,
        pipelineErrors: [String]
    ) -> String? {
        let effective: RenderingQuality =
            meshShadersEnabled ? .maximum : (tessellationEnabled ? .enhanced : .standard)
        guard requested != effective, requested != .standard else { return nil }
        var why: [String] = []
        if requested == .maximum, !meshShadersEnabled {
            why.append(
                supportsMeshShaders
                    ? "mesh-shader pipelines failed to build"
                    : "this GPU has no mesh shaders (Apple9 family: M3 / A17 Pro or later)")
        }
        if !tessellationEnabled {
            why.append("tessellation pipelines failed to build")
        }
        why += pipelineErrors
        return "renderingQuality .\(requested) requested, drawing with .\(effective): "
            + why.joined(separator: "; ")
    }

    // MARK: - Shaded surface draw

    /// Cull modes the translucent pass draws each body with, in order: the far-facing triangles
    /// first, then the camera-facing ones, so a body's near wall composites over its far wall.
    ///
    /// Mesh triangles wind counter-clockwise seen from outside, which the default clockwise
    /// front-facing rule rasterises as back faces: `.back` culls the camera-facing side and
    /// leaves the far one. `OffscreenRenderer` uses the same order.
    nonisolated static let translucentCullOrder: [MTLCullMode] = [.back, .front]

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
            RendererSharedSetup.encodeMeshletDraw(
                encoder: encoder, pipeline: msPipeline, meshlets: ml, vertexBuffer: vb,
                uniforms: &uniforms)
        } else if useTessellation, let tess = buffers.tessellation,
            let tessPipeline = tessellatedShadedPipeline
        {
            RendererSharedSetup.encodeTessellatedDraw(
                encoder: encoder, pipeline: tessPipeline, tessellation: tess, uniforms: &uniforms)
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

    /// Composites a body's `triangleStyles` over its shaded surface (issue #25).
    ///
    /// The caller sets the depth-stencil state (`highlightDepthState`) and cull mode. Rebinds
    /// fragment buffers 1 (scene uniforms) and 2 (the style buffer).
    private func encodeTriangleHighlight(
        _ encoder: MTLRenderCommandEncoder,
        buffers: BodyBuffers,
        uniforms: inout Uniforms
    ) {
        guard let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
            let styleBuf = buffers.triangleStyleBuffer, buffers.indexCount > 0
        else { return }
        if let nb = buffers.normalBuffer {
            // Direct-mesh body: position@0 + normal@2.
            encoder.setRenderPipelineState(highlightDirectPipeline)
            encoder.setVertexBuffer(nb, offset: 0, index: 2)
        } else {
            encoder.setRenderPipelineState(highlightPipeline)
        }
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
        encoder.setFragmentBuffer(styleBuf, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
            indexBuffer: ib, indexBufferOffset: 0)
    }

    // MARK: - Buffer Management

    private func ensureBuffers(for body: ViewportBody) {
        let currentGen = body.generation
        if let cachedGen = bodyGeneration[body.id], cachedGen == currentGen {
            // Geometry still valid. `triangleStyles` can be reassigned on the same body without a
            // new generation, so re-upload just the style buffer when it changed.
            if bodyStyleGeneration[body.id] != body.triangleStylesGeneration,
                var cached = bodyBufferCache[body.id]
            {
                cached.triangleStyleBuffer = makeTriangleStyleBuffer(
                    for: body, triangleCount: cached.indexCount / 3)
                bodyBufferCache[body.id] = cached
            }
            bodyStyleGeneration[body.id] = body.triangleStylesGeneration
            return  // buffer still valid
        }

        // Build vertex + index buffers (nil for edge-only bodies). Interleaved bodies optionally
        // get crease-aware normal smoothing first (issue #48) so meshes with flat / per-face
        // normals can be rounded by Phong tessellation: done once here (generation-gated), and
        // the tessellation patch builder reads from this vertex buffer, so smoothed normals flow
        // into the PN-triangle control points automatically. Direct-mesh bodies skip smoothing
        // (the producer supplies normals) and skip the tessellation / mesh-shader paths, which
        // consume the interleaved buffer + faceIndices.
        let smoothedVertexData = RendererSharedBuffers.smoothedVertexData(
            for: body,
            autoSmoothNormals: controller?.configuration.autoSmoothNormals == true,
            creaseAngle: controller?.configuration.normalSmoothingCreaseAngle ?? 0.524
        )

        let mesh = RendererSharedBuffers.makeMeshBuffers(
            device: device, body: body, interleavedVertexData: smoothedVertexData)
        let vertexBuffer = mesh.vertexBuffer
        let normalBuffer = mesh.normalBuffer
        let indexBuffer = mesh.indexBuffer
        let indexCount = mesh.indexCount
        let vertexCount = mesh.vertexCount

        // Build edge vertex buffers
        // Native lines: 2 vertices per segment (start, end)
        let nativeEdgeVertices = RendererSharedBuffers.nativeEdgeLineVertices(from: body.edges)
        let nativeEdgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: nativeEdgeVertices)
        let nativeEdgeVertexCount = nativeEdgeVertices.count / 6
        let nativeEdgePrimitiveCount = nativeEdgeVertexCount / 2

        // Quad-expanded lines: six vertices per segment, each with a 9-float payload.
        let quadEdgeVertices = RendererSharedBuffers.quadEdgeLineVertices(from: body.edges)
        let quadEdgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: quadEdgeVertices)
        let quadEdgeVertexCount = quadEdgeVertices.count / 9

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
        // A body that kept its `id` but lost all its geometry must drop the entry cached
        // for its previous generation, or the old buffers keep drawing (#136 M10).
        guard
            vertexBuffer != nil
                || nativeEdgeVB != nil
                || pointPositionVB != nil
                || !body.arcs.isEmpty
        else {
            bodyBufferCache.removeValue(forKey: body.id)
            bodyGeneration[body.id] = currentGen
            return
        }

        // Tessellation patches and meshlets, shared with OffscreenRenderer (#165). Direct-mesh
        // bodies get neither: both builders consume an interleaved stride-6 buffer, and a direct
        // body brings its own normals. `faceIndices` plays no part (#161). Patches read the uploaded (possibly smoothed)
        // vertex buffer and meshlets the same smoothed data, so both see the smoothed normals.
        let refinement = RendererSharedBuffers.makeRefinementBuffers(
            for: body, smoothedVertexData: smoothedVertexData, mesh: mesh,
            tessellationManager: tessellationEnabled ? tessellationManager : nil,
            buildMeshlets: meshShadersEnabled, device: device, commandQueue: commandQueue)
        let tessBuffers = refinement.tessellation
        let meshletBufs = refinement.meshlets
        #if DEBUG
            // One-shot diagnostic for the first tessellated body.
            if let tessMgr = tessellationManager, tessellationEnabled, !body.usesDirectMesh,
                indexCount > 0, !tessMgr.didLogDiagnostic
            {
                tessMgr.didLogDiagnostic = true
                let msg = """
                    ensureBuffers: body=\(body.id) tris=\(indexCount / 3) \
                    tessResult=\(tessBuffers != nil)
                    """
                NSLog("[ViewportRenderer] %@", msg)
            }
        #endif

        // Per-triangle highlight style buffer. Built only when the body has any
        // triangleStyles set; nil otherwise.
        let triStyleBuf = makeTriangleStyleBuffer(for: body, triangleCount: indexCount / 3)

        bodyBufferCache[body.id] = BodyBuffers(
            vertexBuffer: vertexBuffer,
            normalBuffer: normalBuffer,
            indexBuffer: indexBuffer,
            indexCount: indexCount,
            edgeVertexBuffer: nativeEdgeVB,
            edgeVertexCount: nativeEdgeVertexCount,
            edgePrimitiveCount: nativeEdgePrimitiveCount,
            quadEdgeVertexBuffer: quadEdgeVB,
            quadEdgeVertexCount: quadEdgeVertexCount,
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
        bodyStyleGeneration[body.id] = body.triangleStylesGeneration
    }

    /// The interleaved vertex data meshlets are built from, or `nil` when the body gets none.
    ///
    /// Returns the auto-smoothed data when smoothing ran (so meshlet descriptors match the vertex
    /// buffer the mesh shader reads), otherwise `body.vertexData`. Direct-mesh bodies and bodies
    /// without triangles return `nil`: the meshlet path consumes an interleaved stride-6 buffer.
    nonisolated static func meshletSourceVertexData(
        for body: ViewportBody, smoothedVertexData: [Float]?
    ) -> [Float]? {
        guard !body.usesDirectMesh, !body.vertexData.isEmpty, !body.indices.isEmpty else {
            return nil
        }
        return smoothedVertexData ?? body.vertexData
    }

    /// Picks this frame's uniform tessellation factor (`adaptiveTessellation == false`).
    ///
    /// For `.loadAdaptive` on a live frame (`frameBudget != nil`), steps the load governor with
    /// the last measured GPU frame time, thermal state and Low Power Mode, and has this frame's
    /// command buffer record its own GPU time. Off-screen frames use the configured factor.
    private func uniformTessellationFactor(
        config: ViewportConfiguration, maxFactor: Float, frameBudget: Double?,
        commandBuffer: MTLCommandBuffer
    ) -> Float {
        var governed: Float?
        if case .loadAdaptive(let minimum) = config.uniformTessellationFactor,
            let frameBudget
        {
            let info = ProcessInfo.processInfo
            tessLoadGovernor = tessLoadGovernor.step(
                TessellationLoadSample(
                    gpuFrameTime: gpuFrameTimes.latestFrameTime,
                    frameBudget: frameBudget,
                    thermalState: info.thermalState,
                    isLowPowerModeEnabled: info.isLowPowerModeEnabled,
                    minFactor: Float(minimum),
                    maxFactor: maxFactor))
            governed = tessLoadGovernor.factor
            let recorder = gpuFrameTimes
            commandBuffer.addCompletedHandler { @Sendable buffer in
                recorder.record(gpuStartTime: buffer.gpuStartTime, gpuEndTime: buffer.gpuEndTime)
            }
        }
        return TessellationLoadGovernor.uniformFactor(
            policy: config.uniformTessellationFactor, maxFactor: maxFactor, governed: governed)
    }

    /// Collects the visible bodies' tessellation buffers with each body's model matrix, the
    /// input to the per-frame tessellation-factor kernel.
    ///
    /// Also counts visible bodies that have a mesh but no tessellation data (for diagnostics).
    func tessellationFactorBatch(
        for bodies: [ViewportBody]
    ) -> (batch: [(TessellationBuffers, simd_float4x4)], nonTessellatedCount: Int) {
        var batch: [(TessellationBuffers, simd_float4x4)] = []
        var nonTessellatedCount = 0
        for body in bodies where body.isVisible {
            guard let buffers = bodyBufferCache[body.id] else { continue }
            if let tess = buffers.tessellation {
                batch.append((tess, body.transform))
            } else if buffers.indexCount > 0 {
                nonTessellatedCount += 1
            }
        }
        return (batch, nonTessellatedCount)
    }

    // MARK: - Picking

    /// Reads a pixel (or neighborhood) from the pick ID buffer and decodes the result.
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

        // Get pick radius from configuration (0 = exact pixel, >0 = neighborhood)
        let pickRadius = controller?.configuration.pickingConfiguration.pickRadius ?? 0
        // `pickRadius` is a public mutable property, so enforce the documented 32px bound here
        // as well as in `PickingConfiguration.init`.
        let radius = min(max(0, pickRadius), 32)

        if radius == 0 {
            // Fast path: exact 1x1 pixel pick
            performExactPick(at: pixel, texture: pickTexture, completion: completion)
        } else {
            // Neighborhood pick: sample (2*radius+1)² region
            performNeighborhoodPick(
                at: pixel,
                radius: radius,
                texture: pickTexture,
                completion: completion)
        }
    }

    /// Exact 1x1 pixel pick (original implementation).
    private func performExactPick(
        at pixel: SIMD2<Int>,
        texture: MTLTexture,
        completion: @escaping @Sendable (PickResult?) -> Void
    ) {
        // Clamp to texture bounds
        let x = max(0, min(pixel.x, pickTextureManager.width - 1))
        let y = max(0, min(pixel.y, pickTextureManager.height - 1))

        let pool = pickReadbackPool
        guard let readbackBuffer = pool.acquire(byteCount: MemoryLayout<UInt32>.size) else {
            completion(nil)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            pool.release(readbackBuffer)
            completion(nil)
            return
        }

        // Blit 1x1 region from private pick texture to this pick's own readback buffer
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: MemoryLayout<UInt32>.size,
            destinationBytesPerImage: MemoryLayout<UInt32>.size
        )
        blitEncoder.endEncoding()

        let indexMap = currentIndexMap
        let layerMap = currentLayerMap
        let ambiguousKinds = currentAmbiguousKinds

        // `@Sendable` is load-bearing here, not decoration. Metal calls a completion handler on
        // its own `com.Metal.CompletionQueueDispatch` queue, never on the main thread. On an SDK
        // that does not annotate `MTLCommandBufferHandler` as Sendable, an unannotated closure
        // literal instead inherits this type's `@MainActor` isolation, and Swift 6 then asserts
        // that isolation when the handler is entered. The assertion fails on Metal's queue and
        // traps with SIGTRAP. Writing the closure `@Sendable` keeps it nonisolated on every SDK,
        // and makes the compiler check that the captures really are safe to hand to Metal.
        // See issue #110.
        commandBuffer.addCompletedHandler { @Sendable _ in
            let rawValue = readbackBuffer.contents().load(as: UInt32.self)
            pool.release(readbackBuffer)
            let result = PickResult(
                rawValue: rawValue, indexMap: indexMap, layerMap: layerMap,
                ambiguousKinds: ambiguousKinds)
            Task { @MainActor in
                completion(result)
            }
        }

        commandBuffer.commit()
    }

    /// Neighborhood pick: samples a square region around the target pixel.
    ///
    /// Returns the best non-background hit, preferring edges/vertices over faces.
    private func performNeighborhoodPick(
        at pixel: SIMD2<Int>,
        radius: Int,
        texture: MTLTexture,
        completion: @escaping @Sendable (PickResult?) -> Void
    ) {
        guard
            let region = Self.clampPickNeighborhood(
                around: pixel, radius: radius,
                textureWidth: pickTextureManager.width, textureHeight: pickTextureManager.height)
        else {
            completion(nil)
            return
        }
        let (startX, startY, actualWidth, actualHeight) = region

        let bytesPerRow = Self.alignedBytesPerRow(forWidth: actualWidth)
        let totalBytes = bytesPerRow * actualHeight

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder(),
            // Per-request buffer (tiny: at most 65x65 px), so an overlapping pick cannot overwrite
            // it before this completion handler reads it.
            let readbackBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared)
        else {
            completion(nil)
            return
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: startX, y: startY, z: 0),
            sourceSize: MTLSize(width: actualWidth, height: actualHeight, depth: 1),
            to: readbackBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blitEncoder.endEncoding()

        let indexMap = currentIndexMap
        let layerMap = currentLayerMap
        let ambiguousKinds = currentAmbiguousKinds
        let centerX = pixel.x - startX
        let centerY = pixel.y - startY

        commandBuffer.addCompletedHandler { @Sendable _ in
            // De-stride into one flat row-major array, as performRegionPick does.
            let base = readbackBuffer.contents()
            var rawValues: [UInt32] = []
            rawValues.reserveCapacity(actualWidth * actualHeight)
            for row in 0..<actualHeight {
                let rowValues = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                rawValues.append(
                    contentsOf: UnsafeBufferPointer(start: rowValues, count: actualWidth))
            }
            let bestResult = Self.bestNeighborhoodPickResult(
                rawValues, width: actualWidth, center: SIMD2(centerX, centerY),
                indexMap: indexMap, layerMap: layerMap, ambiguousKinds: ambiguousKinds)

            Task { @MainActor in
                completion(bestResult)
            }
        }

        commandBuffer.commit()
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
    ///     empty space completes with `[]`. Apply a `PickResultFilter` to the result the same way
    ///     you would a single `performPick` result.
    ///
    /// Each call reads back into a buffer of its own, so overlapping region picks (a new one
    /// issued before an earlier one completes) each get their own rectangle's results.
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

        // A buffer of this request's own (issue #184): a single shared buffer let an overlapping
        // region pick blit over this one's pixels before its completion handler read them.
        let pool = pickReadbackPool
        guard let readbackBuffer = pool.acquire(byteCount: byteCount) else {
            completion([])
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            pool.release(readbackBuffer)
            completion([])
            return
        }

        // Blit the whole rectangle from the private pick texture to the readback buffer in one
        // copy — the batched alternative to N per-pixel blits.
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
        let ambiguousKinds = currentAmbiguousKinds

        // `@Sendable` for the same reason as in `performPick(at:)` above: this handler runs on
        // Metal's completion queue, so it must not inherit `@MainActor` isolation. See issue #110.
        commandBuffer.addCompletedHandler { @Sendable _ in
            // De-stride: read exactly the w*4 live bytes from each padded row, skipping the
            // alignment padding, into one flat row-major array for decodeRegionPickResults.
            let base = readbackBuffer.contents()
            var rawValues: [UInt32] = []
            rawValues.reserveCapacity(w * h)
            for row in 0..<h {
                let rowValues = (base + row * bytesPerRow).assumingMemoryBound(to: UInt32.self)
                rawValues.append(contentsOf: UnsafeBufferPointer(start: rowValues, count: w))
            }
            pool.release(readbackBuffer)
            let results = Self.decodeRegionPickResults(
                rawValues, indexMap: indexMap, layerMap: layerMap, ambiguousKinds: ambiguousKinds)
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

    /// Clamps the `(2 * radius + 1)²` square around `pixel` to the pick texture's bounds.
    ///
    /// Returns the origin/size to blit, or `nil` when the square misses the texture entirely or
    /// the texture has zero size (no frame drawn yet).
    nonisolated static func clampPickNeighborhood(
        around pixel: SIMD2<Int>, radius: Int, textureWidth: Int, textureHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int)? {
        let startX = max(0, pixel.x - radius)
        let startY = max(0, pixel.y - radius)
        let endX = min(textureWidth - 1, pixel.x + radius)
        let endY = min(textureHeight - 1, pixel.y + radius)
        let width = endX - startX + 1
        let height = endY - startY + 1
        guard width > 0, height > 0 else { return nil }
        return (startX, startY, width, height)
    }

    /// Picks the best hit from a neighborhood of raw R32Uint pick values (issue #118).
    ///
    /// A vertex beats an edge, an edge beats a face; among hits of the same kind the one nearest
    /// `center` wins, and on an exact tie the first in row-major order is kept. Background and
    /// undecodable pixels are skipped. `rawValues` is flat and row-major, `width` values per row;
    /// `center` is the cursor's position within that region. Pulled out of the GPU readback path
    /// as a pure function, like `decodeRegionPickResults`, so it is testable without a live draw.
    nonisolated static func bestNeighborhoodPickResult(
        _ rawValues: [UInt32],
        width: Int,
        center: SIMD2<Int>,
        indexMap: [Int: String],
        layerMap: [String: PickLayer],
        ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
    ) -> PickResult? {
        guard width > 0 else { return nil }
        var bestResult: PickResult? = nil
        var bestPriority = -1
        var bestDistSq = Int.max

        for (index, rawValue) in rawValues.enumerated() {
            guard
                let result = PickResult(
                    rawValue: rawValue, indexMap: indexMap, layerMap: layerMap,
                    ambiguousKinds: ambiguousKinds)
            else {
                continue
            }

            let priority: Int
            switch result.kind {
            case .vertex: priority = 2
            case .edge: priority = 1
            case .face: priority = 0
            }

            let dx = index % width - center.x
            let dy = index / width - center.y
            let distSq = dx * dx + dy * dy
            let isCloser = priority == bestPriority && distSq < bestDistSq
            if priority > bestPriority || isCloser {
                bestPriority = priority
                bestDistSq = distSq
                bestResult = result
            }
        }
        return bestResult
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
        layerMap: [String: PickLayer],
        ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
    ) -> [PickResult] {
        var seen = Set<UInt32>()
        var results: [PickResult] = []
        for rawValue in rawValues {
            guard rawValue != PickResult.sentinel, !seen.contains(rawValue) else { continue }
            seen.insert(rawValue)
            if let result = PickResult(
                rawValue: rawValue, indexMap: indexMap, layerMap: layerMap,
                ambiguousKinds: ambiguousKinds)
            {
                results.append(result)
            }
        }
        return results
    }
}
