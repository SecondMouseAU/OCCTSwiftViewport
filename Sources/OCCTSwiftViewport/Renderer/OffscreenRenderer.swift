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

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

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

/// Which appearance (light or dark) a headless render uses to pick its background.
///
/// Offscreen defaults follow onscreen: `.system` (the default) uses the system appearance at
/// render time, as `MetalViewportView` follows its colour scheme. That makes the image depend on
/// the host's Light/Dark setting, so pin `.light` or `.dark` wherever output must be
/// reproducible: tests, CI, reference images and documentation figures.
public enum RenderAppearance: Sendable, Hashable {
    /// Light appearance: `backgroundColor`.
    case light
    /// Dark appearance: `darkModeBackgroundColor`, or `backgroundColor` when that is `nil`.
    case dark
    /// The appearance in effect at render time.
    ///
    /// On macOS, when the process has an `NSApplication`, this is `NSApp.effectiveAppearance`, so
    /// an app that forces its own appearance with `NSApp.appearance` renders in it. A plain
    /// headless process with no application falls back to the user's Light/Dark setting. On iOS
    /// and visionOS it is `UITraitCollection.current`, which is usually unspecified outside a
    /// view's trait update, so a headless render there comes out light. Render inside the view's
    /// `traitCollection.performAsCurrent { ... }` to follow its style, or pin `.light` / `.dark`
    /// (#202). The library does not ask `UIApplication` itself, which app extensions can't use.
    case system

    /// Whether this appearance renders dark right now.
    @MainActor
    public var isDark: Bool {
        switch self {
        case .light: return false
        case .dark: return true
        case .system: return Self.systemIsDark
        }
    }

    @MainActor
    private static var systemIsDark: Bool {
        #if os(macOS)
            // `NSApp` is nil until something creates the shared application (issue #186).
            let app: NSApplication? = NSApp
            return isDark(
                appAppearance: app?.effectiveAppearance,
                interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle"))
        #elseif canImport(UIKit)
            return UITraitCollection.current.userInterfaceStyle == .dark
        #else
            return false
        #endif
    }

    #if os(macOS)
        /// Whether `.system` renders dark, given the application's effective appearance (`nil`
        /// when the process has no `NSApplication`) and the `AppleInterfaceStyle` user default.
        ///
        /// The application's appearance wins: it already reflects the system setting unless the
        /// app overrides it. High-contrast variants match their light or dark base.
        @MainActor
        static func isDark(appAppearance: NSAppearance?, interfaceStyle: String?) -> Bool {
            if let appAppearance {
                return appAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            return interfaceStyle == "Dark"
        }
    #endif
}

/// Configuration for an offscreen render.
///
/// The fields mirror the live viewport's settings (`ViewportConfiguration` and the
/// `ViewportController` state), so the same bodies and settings render the same way in both. Use
/// `init(matching:width:height:)` to copy them from a live controller.
///
/// Image-based lighting and the HDR skybox (`drawBackground`) come from the environment map named
/// by `LightingConfiguration.environmentMapURL` / `environmentMapData`. A map loaded imperatively
/// with `ViewportRenderer.loadEnvironmentMap(...)` lives on that renderer and is not seen here.
///
/// `renderingQuality` selects the same surface path as live: PN-triangle tessellation at
/// `.enhanced` and `.maximum`, and mesh shaders at `.maximum` on Apple9 GPUs. Offscreen output
/// stays deterministic: a uniform factor never follows system load (see
/// `uniformTessellationFactor`).
///
/// What the offscreen path does **not** reproduce: TAA, depth of field, frustum culling, and the
/// GPU pick pass.
public struct OffscreenRenderOptions: Sendable {
    public var width: Int
    public var height: Int
    public var cameraState: CameraState
    public var displayMode: DisplayMode

    /// Opacity ceiling for surfaces in `.xray` mode, `0...1`.
    ///
    /// Defaults to `DisplayMode.defaultXRayOpacity`, the same default as
    /// `ViewportConfiguration.xrayOpacity`, so a headless render matches the live viewport.
    /// Clamped on set with `DisplayMode.clampedXRayOpacity(_:)`.
    public var xrayOpacity: Float = DisplayMode.defaultXRayOpacity {
        didSet {
            let clamped = DisplayMode.clampedXRayOpacity(xrayOpacity)
            if clamped != xrayOpacity { xrayOpacity = clamped }
        }
    }

    public var lightingConfiguration: LightingConfiguration
    /// Background colour in the light appearance.
    public var backgroundColor: SIMD4<Float>

    /// Background colour in the dark appearance, or `nil` to use `backgroundColor` for both,
    /// matching `ViewportConfiguration.darkModeBackgroundColor`.
    public var darkModeBackgroundColor: SIMD4<Float>?

    /// Appearance the render uses to pick its background.
    ///
    /// Defaults to `.system`, like the onscreen view. Pin `.light` or `.dark` for reproducible
    /// output; see `RenderAppearance`.
    public var appearance: RenderAppearance

    public var showGrid: Bool
    public var showAxes: Bool
    public var msaaSampleCount: Int

    /// Fundamental grid unit in world units, matching `ViewportConfiguration.gridBaseSpacing`.
    public var gridBaseSpacing: Float

    /// Subdivision factor between grid spacing levels, matching
    /// `ViewportConfiguration.gridSubdivisions`.
    public var gridSubdivisions: Int

    /// Grid rendering style, matching `ViewportConfiguration.gridStyle`.
    public var gridStyle: GridStyle

    /// Side length of the square grid centred on the world origin, matching
    /// `ViewportConfiguration.gridSize`.
    public var gridSize: Float

    /// Axis length in world units, or `nil` (the default) to size the axes to the rendered
    /// bodies, matching `ViewportConfiguration.axisLength`.
    public var axisLength: Float?

    /// Axis cylinder radius, or `nil` (the default) for automatic, matching
    /// `ViewportConfiguration.axisRadius`.
    public var axisRadius: Float?

    /// Axis rendering style, matching `ViewportConfiguration.axisStyle`.
    public var axisStyle: AxisStyle

    /// Edge line rendering configuration (width, dash pattern, quad expansion).
    public var edgeLineConfiguration: EdgeLineConfiguration

    /// Edge intensity, mirroring `ViewportController.edgeIntensity`.
    ///
    /// `0` hides the edges of meshed bodies, `1` (the default) is normal, and values toward `0`
    /// dim and depth-fade them. Applies to both the quad-expanded and the native edge paths.
    /// Edge-only bodies always draw in their body colour.
    public var edgeIntensity: Float

    /// Section planes, matching `ViewportController.clipPlanes`.
    ///
    /// The first four enabled planes are applied to surfaces, edges, arcs and highlights; any
    /// further ones are ignored, as in the live viewport.
    public var clipPlanes: [ClipPlane]

    /// Bodies drawn selected (tinted and ringed by the selection outline), matching
    /// `ViewportController.selectedBodyIDs`.
    public var selectedBodyIDs: Set<String>

    /// Body drawn hovered (lighter tint and outline), matching `ViewportController.hoveredBodyID`.
    ///
    /// Ignored when the body is also in `selectedBodyIDs`.
    public var hoveredBodyID: String?

    /// Outline colour and width for selected bodies, matching
    /// `ViewportConfiguration.selectionOutline`.
    public var selectionOutline: SelectionOutlineStyle

    /// Outline colour and width for the hovered body, matching `ViewportConfiguration.hoverOutline`.
    public var hoverOutline: SelectionOutlineStyle

    /// Whether interleaved bodies get crease-aware normal smoothing, matching
    /// `ViewportConfiguration.autoSmoothNormals`.
    public var autoSmoothNormals: Bool

    /// Crease angle in radians for `autoSmoothNormals`, matching
    /// `ViewportConfiguration.normalSmoothingCreaseAngle`.
    public var normalSmoothingCreaseAngle: Float

    /// Whether the screen-space depth silhouette pass runs, matching
    /// `ViewportConfiguration.enableSilhouettes`.
    ///
    /// Silhouettes share a full-screen composite pass with SSAO
    /// (`LightingConfiguration.enableSSAO`). That pass also applies ACES tone mapping with
    /// `LightingConfiguration.exposure` and `whitePoint`, exactly as the live viewport does, and
    /// is skipped in the `.wireframe` and `.unlit` display modes.
    public var enableSilhouettes: Bool

    /// Silhouette thickness, matching `ViewportConfiguration.silhouetteThickness`.
    public var silhouetteThickness: Float

    /// Silhouette darkness, matching `ViewportConfiguration.silhouetteIntensity`.
    public var silhouetteIntensity: Float

    /// Surface path, matching `ViewportConfiguration.renderingQuality`.
    ///
    /// `.enhanced` refines every interleaved mesh with GPU PN-triangle tessellation; `.maximum`
    /// draws through mesh shaders on Apple9 GPUs (M3, A17 and later) and falls back to
    /// tessellation elsewhere, as the live viewport does. Direct-mesh bodies, and bodies whose
    /// `faceIndices` don't cover every triangle, always draw their mesh as given.
    public var renderingQuality: RenderingQuality

    /// Maximum tessellation factor, matching `ViewportConfiguration.tessellationMaxFactor`.
    ///
    /// Clamped to `2...64` and rounded up to an even value, as live.
    public var tessellationMaxFactor: Int

    /// Whether tessellation adapts to projected edge length, matching
    /// `ViewportConfiguration.adaptiveTessellation`.
    ///
    /// Adaptive factors depend only on the camera, the output size and `tessellationMaxFactor`.
    public var adaptiveTessellation: Bool

    /// The factor used when `adaptiveTessellation` is `false`, matching
    /// `ViewportConfiguration.uniformTessellationFactor`.
    ///
    /// `.fixed(n)` tessellates at `n`. `.loadAdaptive` has no load to adapt to offscreen and
    /// always uses `tessellationMaxFactor`, so the same options always give the same image.
    public var uniformTessellationFactor: UniformTessellationFactor

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

    /// Creates render options.
    ///
    /// Every scene default is read from `ViewportController.defaultConfiguration` (and
    /// `ViewportController.defaultEdgeIntensity`), so a default offscreen render shows what a
    /// default `ViewportController` shows and the two cannot drift apart.
    public init(
        width: Int = 1024,
        height: Int = 768,
        cameraState: CameraState =
            ViewportController.defaultConfiguration.effectiveInitialCameraState,
        displayMode: DisplayMode = ViewportController.defaultConfiguration.displayMode,
        xrayOpacity: Float = ViewportController.defaultConfiguration.xrayOpacity,
        lightingConfiguration: LightingConfiguration =
            ViewportController.defaultConfiguration.lightingConfiguration,
        backgroundColor: SIMD4<Float> = ViewportController.defaultConfiguration.backgroundColor,
        darkModeBackgroundColor: SIMD4<Float>? =
            ViewportController.defaultConfiguration.darkModeBackgroundColor,
        appearance: RenderAppearance = .system,
        showGrid: Bool = ViewportController.defaultConfiguration.showGrid,
        showAxes: Bool = ViewportController.defaultConfiguration.showAxes,
        msaaSampleCount: Int = ViewportController.defaultConfiguration.msaaSampleCount,
        gridBaseSpacing: Float = ViewportController.defaultConfiguration.gridBaseSpacing,
        gridSubdivisions: Int = ViewportController.defaultConfiguration.gridSubdivisions,
        gridStyle: GridStyle = ViewportController.defaultConfiguration.gridStyle,
        gridSize: Float = ViewportController.defaultConfiguration.gridSize,
        axisLength: Float? = ViewportController.defaultConfiguration.axisLength,
        axisRadius: Float? = ViewportController.defaultConfiguration.axisRadius,
        axisStyle: AxisStyle = ViewportController.defaultConfiguration.axisStyle,
        edgeLineConfiguration: EdgeLineConfiguration =
            ViewportController.defaultConfiguration.edgeLineConfiguration,
        explicitOrthoBounds: OrthoBounds? = nil,
        pixelPan: SIMD2<Float>? = nil,
        measurements: [ViewportMeasurement] = [],
        edgeIntensity: Float = ViewportController.defaultEdgeIntensity,
        clipPlanes: [ClipPlane] = [],
        selectedBodyIDs: Set<String> = [],
        hoveredBodyID: String? = nil,
        selectionOutline: SelectionOutlineStyle =
            ViewportController.defaultConfiguration.selectionOutline,
        hoverOutline: SelectionOutlineStyle = ViewportController.defaultConfiguration.hoverOutline,
        autoSmoothNormals: Bool = ViewportController.defaultConfiguration.autoSmoothNormals,
        normalSmoothingCreaseAngle: Float =
            ViewportController.defaultConfiguration.normalSmoothingCreaseAngle,
        enableSilhouettes: Bool = ViewportController.defaultConfiguration.enableSilhouettes,
        silhouetteThickness: Float = ViewportController.defaultConfiguration.silhouetteThickness,
        silhouetteIntensity: Float = ViewportController.defaultConfiguration.silhouetteIntensity,
        renderingQuality: RenderingQuality =
            ViewportController.defaultConfiguration.renderingQuality,
        tessellationMaxFactor: Int = ViewportController.defaultConfiguration.tessellationMaxFactor,
        adaptiveTessellation: Bool = ViewportController.defaultConfiguration.adaptiveTessellation,
        uniformTessellationFactor: UniformTessellationFactor =
            ViewportController.defaultConfiguration.uniformTessellationFactor
    ) {
        self.width = width
        self.height = height
        self.cameraState = cameraState
        self.displayMode = displayMode
        self.xrayOpacity = DisplayMode.clampedXRayOpacity(xrayOpacity)
        self.lightingConfiguration = lightingConfiguration
        self.backgroundColor = backgroundColor
        self.darkModeBackgroundColor = darkModeBackgroundColor
        self.appearance = appearance
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.msaaSampleCount = msaaSampleCount
        self.gridBaseSpacing = gridBaseSpacing
        self.gridSubdivisions = gridSubdivisions
        self.gridStyle = gridStyle
        self.gridSize = gridSize
        self.axisLength = axisLength
        self.axisRadius = axisRadius
        self.axisStyle = axisStyle
        self.edgeLineConfiguration = edgeLineConfiguration
        self.explicitOrthoBounds = explicitOrthoBounds
        self.pixelPan = pixelPan
        self.measurements = measurements
        self.edgeIntensity = edgeIntensity
        self.clipPlanes = clipPlanes
        self.selectedBodyIDs = selectedBodyIDs
        self.hoveredBodyID = hoveredBodyID
        self.selectionOutline = selectionOutline
        self.hoverOutline = hoverOutline
        self.autoSmoothNormals = autoSmoothNormals
        self.normalSmoothingCreaseAngle = normalSmoothingCreaseAngle
        self.enableSilhouettes = enableSilhouettes
        self.silhouetteThickness = silhouetteThickness
        self.silhouetteIntensity = silhouetteIntensity
        self.renderingQuality = renderingQuality
        self.tessellationMaxFactor = tessellationMaxFactor
        self.adaptiveTessellation = adaptiveTessellation
        self.uniformTessellationFactor = uniformTessellationFactor
    }

    /// Options that reproduce what a controller's live viewport currently shows.
    ///
    /// Copies the camera, display mode, lighting, grid and axes, edge intensity, clip planes,
    /// selection and hover, and every `ViewportConfiguration` field the offscreen path honours.
    /// Measurements are not copied; pass resolved ones in `measurements` to draw them.
    ///
    /// With `debugDisableTessellation` on, which switches the live view's tessellation and mesh
    /// shaders off, the options use `.standard`.
    @MainActor
    public init(matching controller: ViewportController, width: Int, height: Int) {
        let config = controller.configuration
        self.init(
            width: width,
            height: height,
            cameraState: controller.cameraState,
            displayMode: controller.displayMode,
            xrayOpacity: controller.xrayOpacity,
            lightingConfiguration: controller.lightingConfiguration,
            backgroundColor: config.backgroundColor,
            darkModeBackgroundColor: config.darkModeBackgroundColor,
            appearance: .system,
            showGrid: controller.showGrid,
            showAxes: controller.showAxes,
            msaaSampleCount: config.msaaSampleCount,
            gridBaseSpacing: config.gridBaseSpacing,
            gridSubdivisions: config.gridSubdivisions,
            gridStyle: config.gridStyle,
            gridSize: config.gridSize,
            axisLength: config.axisLength,
            axisRadius: config.axisRadius,
            axisStyle: config.axisStyle,
            edgeLineConfiguration: config.edgeLineConfiguration,
            edgeIntensity: controller.edgeIntensity,
            clipPlanes: controller.clipPlanes,
            selectedBodyIDs: controller.selectedBodyIDs,
            hoveredBodyID: controller.hoveredBodyID,
            selectionOutline: config.selectionOutline,
            hoverOutline: config.hoverOutline,
            autoSmoothNormals: config.autoSmoothNormals,
            normalSmoothingCreaseAngle: config.normalSmoothingCreaseAngle,
            enableSilhouettes: config.enableSilhouettes,
            silhouetteThickness: config.silhouetteThickness,
            silhouetteIntensity: config.silhouetteIntensity,
            renderingQuality: config.renderingQuality,
            tessellationMaxFactor: config.tessellationMaxFactor,
            adaptiveTessellation: config.adaptiveTessellation,
            uniformTessellationFactor: config.uniformTessellationFactor
        )
        // `debugDisableTessellation` switches the live view's refinement off.
        if controller.debugDisableTessellation { renderingQuality = .standard }
    }

    /// The background colour for `appearance`: `darkModeBackgroundColor` when it renders dark and
    /// that is set, otherwise `backgroundColor`.
    @MainActor
    public var resolvedBackgroundColor: SIMD4<Float> {
        if appearance.isDark, let dark = darkModeBackgroundColor { return dark }
        return backgroundColor
    }
}

/// Error type for offscreen rendering failures.
public enum OffscreenRenderError: Error, Sendable {
    case renderFailed
    case fileCreationFailed
    case writeFailed
}

// MARK: - Sample-count-dependent pipelines

/// The `OffscreenRenderer` pipelines that must be built for the main pass's sample count.
///
/// The shadow pipelines render into the single-sample shadow map and are not here.
private struct SampledPipelines {
    let shadedPipeline: MTLRenderPipelineState

    /// Same shaders as `shadedPipeline`, but its vertex descriptor reads position from buffer 0 and
    /// normal from buffer 2 (de-interleaved), so bodies built via `ViewportBody.directMesh(...)`
    /// render without a CPU interleave.
    let directMeshPipeline: MTLRenderPipelineState
    let wireframePipeline: MTLRenderPipelineState
    /// Quad-expanded wireframe pipeline (variable width + dash patterns).
    let quadEdgePipeline: MTLRenderPipelineState?
    let gridPipeline: MTLRenderPipelineState
    let axisPipeline: MTLRenderPipelineState
    /// Visible point-cloud pipeline (issue #28).
    ///
    /// Optional only because pipeline construction could fail on a degenerate device.
    let visiblePointPipeline: MTLRenderPipelineState?

    /// Selection outline: the full-screen dilation of the selection mask (#209).
    let outlinePipeline: MTLRenderPipelineState?

    /// Per-triangle highlight pipelines (`ViewportBody.triangleStyles`) for interleaved and
    /// direct-mesh bodies.
    let highlightPipeline: MTLRenderPipelineState?
    let highlightDirectPipeline: MTLRenderPipelineState?

    /// HDR skybox background (`LightingConfiguration.drawBackground`).
    let skyboxPipeline: MTLRenderPipelineState?

    /// Stencil-only selection masks for interleaved and direct-mesh bodies.
    let stencilMaskPipeline: MTLRenderPipelineState?
    let stencilMaskDirectPipeline: MTLRenderPipelineState?

    init?(device: MTLDevice, library: MTLLibrary, sampleCount: Int) {
        let depthFormat: MTLPixelFormat = .depth32Float_stencil8
        let vertexDesc = RendererSharedSetup.interleavedVertexDescriptor()
        let directVertexDesc = RendererSharedSetup.directMeshVertexDescriptor()

        guard
            let shaded = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc),
            let directMesh = RendererSharedSetup.makeShadedPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: directVertexDesc),
            let wireframe = RendererSharedSetup.makeWireframePipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat, vertexDescriptor: vertexDesc),
            let grid = RendererSharedSetup.makeGridPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat),
            let axis = RendererSharedSetup.makeAxisPipelineState(
                device: device, library: library, sampleCount: sampleCount,
                depthFormat: depthFormat)
        else { return nil }

        shadedPipeline = shaded
        directMeshPipeline = directMesh
        wireframePipeline = wireframe
        gridPipeline = grid
        axisPipeline = axis
        quadEdgePipeline = RendererSharedSetup.makeQuadEdgePipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat,
            vertexDescriptor: RendererSharedSetup.quadEdgeVertexDescriptor())
        visiblePointPipeline = RendererSharedSetup.makeVisiblePointPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, label: "offscreen_visible_point")
        outlinePipeline = RendererSharedSetup.makeSelectionOutlinePipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, label: "offscreen_selection_outline")
        highlightPipeline = RendererSharedSetup.makeHighlightPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        highlightDirectPipeline = RendererSharedSetup.makeHighlightPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, vertexDescriptor: directVertexDesc)
        skyboxPipeline = RendererSharedSetup.makeSkyboxPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat)
        stencilMaskPipeline = RendererSharedSetup.makeStencilMaskPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, vertexDescriptor: vertexDesc)
        stencilMaskDirectPipeline = RendererSharedSetup.makeStencilMaskPipelineState(
            device: device, library: library, sampleCount: sampleCount,
            depthFormat: depthFormat, vertexDescriptor: directVertexDesc)
    }
}

// MARK: - OffscreenRenderer

/// Headless Metal renderer that renders [ViewportBody] to CGImage without MTKView.
@MainActor
public final class OffscreenRenderer: Sendable {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    /// Main-pass pipelines, built once per sample count.
    ///
    /// Their `rasterSampleCount` must match the pass's attachments. The default count (4) is built
    /// in `init` and any other on first use, so `OffscreenRenderOptions.msaaSampleCount` can change
    /// between renders (issue #134).
    private var pipelinesBySampleCount: [Int: SampledPipelines]
    private let shadowPipeline: MTLRenderPipelineState

    /// Direct-mesh shadow pipeline (Option A).
    ///
    /// `shadow_vertex` with the two-buffer descriptor (position@0 / normal@2) so direct-mesh bodies
    /// cast shadows in the headless path too.
    private let shadowDirectPipeline: MTLRenderPipelineState
    private let shadowMapManager: ShadowMapManager
    private let depthState: MTLDepthStencilState
    private let transparentDepthState: MTLDepthStencilState
    /// Draws the outline only where the stencil is unmarked.
    private let stencilTestState: MTLDepthStencilState
    /// Marks a selected body's whole silhouette in the stencil, ignoring depth (#177).
    private let stencilMarkState: MTLDepthStencilState
    /// `.lessEqual`, no depth write: highlight triangles win ties with the shaded surface.
    private let highlightDepthState: MTLDepthStencilState
    /// Always-pass, no depth write: overlay-layer bodies draw on top of all geometry.
    private let overlayDepthState: MTLDepthStencilState
    private let matcapTexture: MTLTexture
    /// Axis cylinders and the cached `.plane` grid-line buffer.
    private let gridAxisBuffers: GridAxisBuffers

    /// Image-based lighting from `LightingConfiguration.environmentMapURL`/`environmentMapData`,
    /// loaded on demand so headless renders light like the interactive viewport.
    private let environmentMapManager: EnvironmentMapManager

    // SSAO / silhouette post-process (single sample, so independent of the MSAA count).
    private let depthOnlyPipeline: MTLRenderPipelineState?
    private let depthOnlyDirectPipeline: MTLRenderPipelineState?
    private let ssaoCompositePipeline: MTLRenderPipelineState?
    /// Single-sample colour the main pass resolves into when the composite runs.
    private var postColorTexture: MTLTexture?
    /// Single-sample depth written by the SSAO / silhouette depth prepass.
    private var postDepthTexture: MTLTexture?

    // Cached textures (recreated if size changes)
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0
    private var cachedSampleCount: Int = 0
    private var msaaColorTexture: MTLTexture?
    private var msaaDepthTexture: MTLTexture?
    private var resolveTexture: MTLTexture?

    /// Selection-mask pipelines (single sample, so independent of the MSAA count; #209).
    private let selectionMaskPipelines: SelectionMaskPipelines?
    /// The render-sized selection mask the outline dilates (#209).
    private var selectionMaskTexture: MTLTexture?

    // Tessellation / mesh shaders (`OffscreenRenderOptions.renderingQuality`, #165), built on the
    // first render that asks for them so `.standard` renders pay nothing.
    private var tessellationManager: TessellationManager?
    /// Set once building `tessellationManager` failed, so it is not retried every render.
    private var tessellationManagerFailed = false
    private var refinedPipelinesByKey: [RefinedPipelines.Key: RefinedPipelines] = [:]

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

        guard let library = RendererSharedSetup.loadLibrary(device: device) else { return nil }
        self.library = library
        self.selectionMaskPipelines = RendererSharedSetup.makeSelectionMaskPipelines(
            device: device, library: library, label: "offscreen_selection_mask")

        let vertexDesc = RendererSharedSetup.interleavedVertexDescriptor()
        let directVertexDesc = RendererSharedSetup.directMeshVertexDescriptor()

        guard
            let defaultPipelines = SampledPipelines(
                device: device, library: library, sampleCount: Self.defaultSampleCount)
        else { return nil }
        self.pipelinesBySampleCount = [Self.defaultSampleCount: defaultPipelines]

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

        guard let stencilTestState = RendererSharedSetup.makeStencilTestState(device: device),
            let stencilMarkState = RendererSharedSetup.makeStencilMarkState(device: device),
            let highlightDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .lessEqual, isDepthWriteEnabled: false),
            let overlayDepthState = RendererSharedSetup.makeDepthStencilState(
                device: device, compareFunction: .always, isDepthWriteEnabled: false)
        else { return nil }
        self.stencilTestState = stencilTestState
        self.stencilMarkState = stencilMarkState
        self.highlightDepthState = highlightDepthState
        self.overlayDepthState = overlayDepthState

        self.depthOnlyPipeline = RendererSharedSetup.makeDepthOnlyPipelineState(
            device: device, library: library, vertexDescriptor: vertexDesc,
            label: "offscreen_depth_only")
        self.depthOnlyDirectPipeline = RendererSharedSetup.makeDepthOnlyPipelineState(
            device: device, library: library, vertexDescriptor: directVertexDesc,
            label: "offscreen_depth_only_direct")
        self.ssaoCompositePipeline = RendererSharedSetup.makeSSAOCompositePipelineState(
            device: device, library: library, label: "offscreen_ssao_composite")

        guard let gridAxisBuffers = GridAxisBuffers(device: device) else {
            return nil
        }
        self.gridAxisBuffers = gridAxisBuffers

        guard let matcap = RendererSharedSetup.makeMatcapTexture(device: device) else { return nil }
        self.matcapTexture = matcap
        self.environmentMapManager = EnvironmentMapManager(device: device, library: library)
    }

    // MARK: - Public API

    /// Renders bodies to a CGImage.
    public func render(bodies: [ViewportBody], options: OffscreenRenderOptions = .init())
        -> CGImage?
    {
        let w = options.width
        let h = options.height
        let sampleCount = Self.supportedSampleCount(options.msaaSampleCount, device: device)

        ensureTextures(width: w, height: h, sampleCount: sampleCount)
        guard let depthTexture = msaaDepthTexture,
            let resolve = resolveTexture,
            sampleCount == 1 || msaaColorTexture != nil,
            let pipelines = pipelines(forSampleCount: sampleCount)
        else { return nil }

        // Tessellated / mesh-shader surface pipelines for `renderingQuality`, as live (#165).
        let refined = refinedPipelines(for: options, sampleCount: sampleCount)
        let refinement =
            refined?.refinement(canTessellate: tessellationManager != nil) ?? .none

        // Ensure buffers for all bodies
        for body in bodies where body.isVisible {
            ensureBuffers(for: body, options: options, refinement: refinement)
        }
        pruneBufferCache(keeping: bodies)

        // Scene-adaptive clip planes (issue #57): fit near/far to the visible
        // geometry so depth precision isn't crushed by a fixed 0.01/10000 range.
        // The shadow frustum below reuses these model bounds, before the grid/axes widen them
        // for the clip fit (issue #183).
        let modelBounds = RendererSharedSetup.sceneBounds(of: bodies)
        let gridAxisSettings = GridAxisSettings(
            options: options, sceneBounds: modelBounds,
            background: options.resolvedBackgroundColor)

        // An orthographic eye in front of the bodies, overlays and axes, as `MetalViewportView`
        // keeps the live one (#215): an eye inside the scene would near-clip it.
        let cameraState = Self.renderCamera(options: options) {
            RendererSharedSetup.orthographicEyeBounds(
                modelBounds: modelBounds, bodies: bodies, settings: gridAxisSettings,
                showAxes: options.showAxes)
        }
        let viewMatrix = cameraState.viewMatrix
        let sceneBounds = GridAxisGeometry.clipBounds(
            sceneBounds: modelBounds,
            settings: gridAxisSettings,
            cameraState: options.cameraState,
            showGrid: options.showGrid,
            showAxes: options.showAxes
        )
        let clip = cameraState.clipPlanes(
            sceneBounds: RendererSharedSetup.clipFitBounds(
                sceneBounds, includingOverlaysOf: bodies,
                in: Self.wideViewFrustum(options: options, camera: cameraState),
                // Orthographic: cap overlays as the eye placement does, as live (#215).
                capBasis: Self.isOrthographic(options)
                    ? RendererSharedSetup.overlayCapBasis(
                        modelBounds: modelBounds, settings: gridAxisSettings,
                        showAxes: options.showAxes) : nil))
        let nearClip: Float = clip.near
        let farClip: Float = clip.far

        let projMatrix = Self.projectionMatrix(options: options, near: nearClip, far: farClip)
        let viewProjection = projMatrix * viewMatrix

        let lighting = options.lightingConfiguration

        // Shadow setup
        let shadowEnabled = lighting.shadowsEnabled
        let lightVP: simd_float4x4
        if shadowEnabled {
            lightVP = RendererSharedSetup.lightViewProjection(
                lightDirection: lighting.keyLight.direction, sceneBounds: modelBounds)
        } else {
            lightVP = matrix_identity_float4x4
        }
        let shadowParams = SIMD4<Float>(
            lighting.shadowBias, lighting.shadowIntensity, shadowEnabled ? 1.0 : 0.0,
            options.edgeIntensity)
        let shadowParams2 = SIMD4<Float>(
            lighting.shadowLightSize, lighting.shadowSearchRadius, 0, 0)
        let (clipPlaneVecs, clipPlaneCount) = RendererSharedSetup.packClipPlanes(
            options.clipPlanes)

        // Auto-load (or clear) the environment named by lighting.environmentMapURL/Data.
        environmentMapManager.sync(with: lighting, commandQueue: commandQueue)
        let iblParams = SIMD4<Float>(
            lighting.environmentIntensity,
            lighting.environmentRotationY,
            lighting.backgroundExposure,
            environmentMapManager.hasEnvironmentMap ? 1.0 : 0.0
        )

        func makeUniforms() -> Uniforms {
            Uniforms(
                viewProjection: viewProjection,
                viewMatrix: viewMatrix,
                // Parallel view vectors in orthographic, as live (#215).
                cameraPosition: RendererSharedSetup.shadingEyePosition(
                    of: cameraState, orthographic: Self.isOrthographic(options)),
                nearPlane: nearClip,
                farPlane: farClip,
                lighting: lighting,
                lightViewProjection: lightVP,
                shadowParams: shadowParams,
                shadowParams2: shadowParams2,
                iblParams: iblParams,
                clipPlanes: clipPlaneVecs,
                clipPlaneCount: clipPlaneCount,
                unlit: options.displayMode == .unlit,
                flatShading: !options.displayMode.usesSmoothShading
            )
        }

        // SSAO / silhouette composite, gated as the live renderer gates it. It reads the main
        // pass's colour from a single-sample intermediate and writes the final image to `resolve`.
        let displayMode = options.displayMode
        let compositeTargets: (color: MTLTexture, depth: MTLTexture)? =
            (lighting.enableSSAO || options.enableSilhouettes)
                && displayMode.showsSurfaces && displayMode != .unlit
                && ssaoCompositePipeline != nil && depthOnlyPipeline != nil
                && depthOnlyDirectPipeline != nil
            ? postProcessTargets(width: w, height: h) : nil

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Tessellation factors for this camera and output size (#165). Never load-governed, so
        // the same options always give the same image. Overlay bodies draw untessellated.
        if refinement.tessellation, let tessellationManager {
            let batch: [(TessellationBuffers, simd_float4x4)] = bodies.compactMap { body in
                guard body.isVisible, body.renderLayer == .geometry,
                    let tess = bodyBufferCache[body.id]?.tessellation
                else {
                    return nil
                }
                return (tess, body.transform)
            }
            if !batch.isEmpty, let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                let maxFactor = TessellationManager.clampedMaxFactor(options.tessellationMaxFactor)
                tessellationManager.updateTessFactors(
                    tessBuffers: batch,
                    viewProjectionMatrix: viewProjection,
                    viewportSize: SIMD2<Float>(Float(w), Float(h)),
                    adaptive: options.adaptiveTessellation,
                    maxFactor: RendererSharedBuffers.deterministicTessellationFactor(
                        requestedMaxFactor: options.tessellationMaxFactor,
                        pipelineMaxFactor: maxFactor,
                        adaptive: options.adaptiveTessellation,
                        policy: options.uniformTessellationFactor),
                    encoder: computeEncoder)
                computeEncoder.endEncoding()
            }
        }

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
                    // No culling (#209): a closed body's light-facing side is nearer the light
                    // and wins the depth test anyway, while an open sheet casts a shadow
                    // whichever way it faces. The old `.front` cull (with Metal's default
                    // clockwise front faces and counter-clockwise meshes) dropped the faces
                    // turned away from the light, so a sheet facing away cast none, and a
                    // mirroring transform, which reverses the winding, flipped which side drew.
                    enc.setCullMode(.none)
                    enc.setDepthBias(0.01, slopeScale: 1.5, clamp: 0.02)
                    // shadow_clip_fragment reads the section clip planes from the scene uniforms,
                    // so clipped-away geometry casts no shadow (#162).
                    var shadowClipUniforms = makeUniforms()
                    enc.setFragmentBytes(
                        &shadowClipUniforms, length: MemoryLayout<Uniforms>.size, index: 1)

                    // Overlay bodies are UI affordances and cast no shadows, as in the live pass.
                    for body in bodies where body.isVisible && body.renderLayer == .geometry {
                        guard let buffers = bodyBufferCache[body.id],
                            let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                            buffers.indexCount > 0
                        else { continue }
                        var shadowUniforms = ShadowUniformsSwift(
                            lightViewProjectionMatrix: lightVP, modelMatrix: body.transform)
                        if Self.encodeRefinedDraw(
                            encoder: enc, buffers: buffers, meshPipeline: refined?.meshShadow,
                            tessellatedPipeline: refined?.tessellatedShadow,
                            uniforms: &shadowUniforms)
                        {
                            continue
                        }
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

        /// 1 = selected, 2 = hovered, 0 = neither (the shader's `isSelected` encoding).
        func selectionState(of body: ViewportBody) -> UInt32 {
            if options.selectedBodyIDs.contains(body.id) { return 1 }
            return options.hoveredBodyID == body.id ? 2 : 0
        }

        /// The PN patches `encodeSurface` draws a body's surface from, or `nil` when it draws the
        /// plain mesh; the highlight, selection mask and outline follow it (#202).
        func drawnPatches(_ buffers: BodyBuffersOffscreen) -> TessellationBuffers? {
            guard buffers.normalBuffer == nil, refined?.tessellatedShaded != nil else { return nil }
            if buffers.meshlets != nil, refined?.meshShaded != nil { return nil }
            return buffers.tessellation
        }

        // Selection mask (#209): the selected and hovered geometry bodies rasterised, without a
        // depth test, into a single-sample mask the outline pass dilates in screen space.
        var selectionMaskDraws: [SelectionMaskDraw] = []
        for body in bodies
        where body.isVisible && body.renderLayer == .geometry && body.primitiveKind != .point
            && selectionState(of: body) > 0
        {
            guard let buffers = bodyBufferCache[body.id],
                let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                buffers.indexCount > 0
            else { continue }
            let patches = drawnPatches(buffers)
            selectionMaskDraws.append(
                SelectionMaskDraw(
                    code: selectionState(of: body), modelMatrix: body.transform,
                    vertexBuffer: vb, normalBuffer: buffers.normalBuffer, indexBuffer: ib,
                    indexCount: buffers.indexCount, patches: patches,
                    worldBounds: SelectionMaskDraw.worldBounds(
                        local: body.boundingBox, transform: body.transform,
                        tessellated: patches != nil)))
        }
        let outlineParams = RendererSharedSetup.selectionOutlineParams(
            selected: options.selectionOutline, hovered: options.hoverOutline)
        let outlineScissor = RendererSharedSetup.selectionOutlineScissor(
            bounds: selectionMaskDraws.map(\.worldBounds), viewProjection: viewProjection,
            size: SIMD2(w, h), margin: max(outlineParams.selected.w, outlineParams.hovered.w))
        var outlineMask: MTLTexture?
        if !selectionMaskDraws.isEmpty, outlineScissor != nil,
            var maskPipelines = selectionMaskPipelines,
            let mask = RendererSharedSetup.selectionMaskTexture(
                device: device, width: w, height: h, reusing: selectionMaskTexture)
        {
            selectionMaskTexture = mask
            maskPipelines.tessellated = refined?.tessellatedSelectionMask
            RendererSharedSetup.encodeSelectionMaskPass(
                commandBuffer: commandBuffer, mask: mask, draws: selectionMaskDraws,
                pipelines: maskPipelines, uniforms: makeUniforms())
            outlineMask = mask
        }

        // Main pass
        let bg = options.resolvedBackgroundColor
        let mainColorTarget = compositeTargets?.color ?? resolve
        let passDesc = MTLRenderPassDescriptor()
        if sampleCount > 1, let msaaColor = msaaColorTexture {
            passDesc.colorAttachments[0].texture = msaaColor
            passDesc.colorAttachments[0].resolveTexture = mainColorTarget
            passDesc.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            // No MSAA: draw straight into the single-sample target.
            passDesc.colorAttachments[0].texture = mainColorTarget
            passDesc.colorAttachments[0].storeAction = .store
        }
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w))
        passDesc.depthAttachment.texture = depthTexture
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .dontCare
        passDesc.depthAttachment.clearDepth = 1.0
        passDesc.stencilAttachment.texture = depthTexture
        passDesc.stencilAttachment.loadAction = .clear
        passDesc.stencilAttachment.storeAction = .dontCare

        guard let mainEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return nil
        }
        mainEncoder.setDepthStencilState(depthState)

        // IBL textures for shaded_fragment (slots 2–4), bound once for the whole pass.
        if environmentMapManager.hasEnvironmentMap {
            if let spec = environmentMapManager.prefilteredSpecularMap {
                mainEncoder.setFragmentTexture(spec, index: 2)
            }
            if let diff = environmentMapManager.irradianceMap {
                mainEncoder.setFragmentTexture(diff, index: 3)
            }
            if let brdf = environmentMapManager.brdfLUT {
                mainEncoder.setFragmentTexture(brdf, index: 4)
            }
        }

        // HDR skybox background, as the live viewport draws it when `drawBackground` is on.
        if lighting.drawBackground, let cubeMap = environmentMapManager.cubeMap,
            let skyboxPipeline = pipelines.skyboxPipeline
        {
            RendererSharedSetup.encodeSkybox(
                encoder: mainEncoder, pipeline: skyboxPipeline, depthState: overlayDepthState,
                viewProjection: viewProjection, lighting: lighting, cubeMap: cubeMap)
            mainEncoder.setDepthStencilState(depthState)
        }

        // Grid
        if options.showGrid {
            RendererSharedSetup.encodeGrid(
                encoder: mainEncoder,
                dotPipeline: pipelines.gridPipeline,
                linePipeline: pipelines.axisPipeline,
                fillDepthState: transparentDepthState,
                depthState: depthState,
                buffers: gridAxisBuffers,
                viewProjection: viewProjection,
                cameraState: options.cameraState,
                settings: gridAxisSettings
            )
        }

        // Axes
        if options.showAxes {
            RendererSharedSetup.encodeAxes(
                encoder: mainEncoder,
                pipeline: pipelines.axisPipeline,
                buffers: gridAxisBuffers,
                viewProjection: viewProjection,
                cameraState: options.cameraState,
                settings: gridAxisSettings
            )
        }

        let xrayOpacity = options.xrayOpacity

        /// Draws a body's shaded surface; the caller sets the depth-stencil state.
        ///
        /// With `refine`, interleaved bodies go through the mesh-shader or tessellated pipeline
        /// when `renderingQuality` built one, as in the live main and transparent passes. Overlay
        /// bodies pass `false`: live draws them with the plain pipeline.
        func encodeSurface(
            _ buffers: BodyBuffersOffscreen,
            uniforms: inout Uniforms,
            bodyUniforms: inout BodyUniforms,
            refine: Bool = true
        ) {
            guard let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                buffers.indexCount > 0
            else { return }
            mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.setFragmentBytes(
                &bodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            mainEncoder.setFragmentTexture(matcapTexture, index: 0)
            if shadowEnabled, let shadowTex = shadowMapManager.texture {
                mainEncoder.setFragmentTexture(shadowTex, index: 1)
            }
            if refine,
                Self.encodeRefinedDraw(
                    encoder: mainEncoder, buffers: buffers, meshPipeline: refined?.meshShaded,
                    tessellatedPipeline: refined?.tessellatedShaded, uniforms: &uniforms)
            {
                return
            }
            if let nb = buffers.normalBuffer {
                // Direct-mesh path (Option A): position@0 + normal@2, no interleave.
                mainEncoder.setRenderPipelineState(pipelines.directMeshPipeline)
                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
                mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
            } else {
                mainEncoder.setRenderPipelineState(pipelines.shadedPipeline)
                mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
            }
            mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.drawIndexedPrimitives(
                type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                indexBuffer: ib, indexBufferOffset: 0)
        }

        /// Draws a body's edge polylines when the display mode shows edges, or the body has no
        /// mesh, through the quad-expanded or native line pipeline.
        func encodeEdges(
            _ buffers: BodyBuffersOffscreen,
            hasMesh: Bool,
            uniforms: inout Uniforms,
            bodyUniforms: BodyUniforms
        ) {
            let hasEdges = buffers.edgeVertexBuffer != nil && buffers.edgeVertexCount > 0
            guard hasEdges, displayMode.showsEdges || !hasMesh,
                let edgeVB = buffers.edgeVertexBuffer
            else { return }
            var edgeBodyUniforms = bodyUniforms
            if !hasMesh { edgeBodyUniforms.metallic = -1.0 }

            let edgeConfig = options.edgeLineConfiguration
            var edgeUniforms = EdgeUniforms(
                uniforms: uniforms, configuration: edgeConfig,
                viewportSize: SIMD2<Float>(Float(w), Float(h)))

            if edgeConfig.useQuadExpansion,
                let quadPipeline = pipelines.quadEdgePipeline,
                let quadEdgeVB = buffers.quadEdgeVertexBuffer,
                buffers.quadEdgeVertexCount > 0
            {
                mainEncoder.setRenderPipelineState(quadPipeline)
                mainEncoder.setVertexBuffer(quadEdgeVB, offset: 0, index: 0)
                mainEncoder.setVertexBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &edgeBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
                mainEncoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: 0,
                    vertexCount: buffers.quadEdgeVertexCount)
            } else {
                // Native Metal line pipeline (backward compatible)
                mainEncoder.setRenderPipelineState(pipelines.wireframePipeline)
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

        /// Draws a `.point` body as disc-masked point sprites (issue #28). See Shaders.metal
        /// `visible_point_vertex` for the `pxPerWorldFactor` derivation.
        func encodePoints(_ body: ViewportBody, _ buffers: BodyBuffersOffscreen) {
            guard let pointPipeline = pipelines.visiblePointPipeline,
                let positionBuf = buffers.pointPositionBuffer,
                buffers.pointVertexCount > 0
            else { return }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            var params = PointParamsSwift(
                baseColor: body.color,
                worldRadius: body.pointRadius,
                pxPerWorldFactor: Float(h) * projMatrix.columns.1.y * 0.5,
                useVertexColors: buffers.pointColorBuffer != nil ? 1 : 0
            )
            mainEncoder.setRenderPipelineState(pointPipeline)
            mainEncoder.setVertexBuffer(positionBuf, offset: 0, index: 0)
            // Without per-point colours, bind the positions as a placeholder so the shader's
            // `vertexColors` argument is non-null (some validation layers care).
            mainEncoder.setVertexBuffer(
                buffers.pointColorBuffer ?? positionBuf, offset: 0, index: 1)
            mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 2)
            mainEncoder.setVertexBytes(
                &params, length: MemoryLayout<PointParamsSwift>.size, index: 3)
            mainEncoder.drawPrimitives(
                type: .point, vertexStart: 0, vertexCount: buffers.pointVertexCount)
        }

        /// Composites a body's `triangleStyles` over its shaded surface (issue #25), with
        /// `.lessEqual` and no depth writes so it wins the tie with the surface underneath. The
        /// style buffer is built per render rather than cached, so mutating `triangleStyles` on an
        /// existing body (which keeps its `generation`) is always picked up. Leaves
        /// `highlightDepthState` set.
        func encodeHighlight(
            _ body: ViewportBody, _ buffers: BodyBuffersOffscreen, uniforms: inout Uniforms
        ) {
            guard !body.triangleStyles.isEmpty,
                let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                buffers.indexCount > 0,
                let styleBuffer = RendererSharedBuffers.makeTriangleStyleBuffer(
                    device: device, body: body, triangleCount: buffers.indexCount / 3),
                let pipeline = buffers.normalBuffer != nil
                    ? pipelines.highlightDirectPipeline : pipelines.highlightPipeline
            else { return }
            mainEncoder.setDepthStencilState(highlightDepthState)
            if let patches = drawnPatches(buffers), let tessellated = refined?.tessellatedHighlight
            {
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBuffer(styleBuffer, offset: 0, index: 2)
                RendererSharedSetup.encodeTessellatedDraw(
                    encoder: mainEncoder, pipeline: tessellated, tessellation: patches,
                    uniforms: &uniforms)
                return
            }
            mainEncoder.setRenderPipelineState(pipeline)
            mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
            if let nb = buffers.normalBuffer {
                mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
            }
            mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.setFragmentBuffer(styleBuffer, offset: 0, index: 2)
            mainEncoder.drawIndexedPrimitives(
                type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                indexBuffer: ib, indexBufferOffset: 0)
        }

        // Bodies. Overlay-layer bodies are drawn last, on top (see the overlay pass below).
        // Translucent bodies (issue #53) are deferred to a sorted back-to-front pass.
        var transparentBodies: [(body: ViewportBody, buffers: BodyBuffersOffscreen)] = []
        for body in bodies where body.isVisible && body.renderLayer == .geometry {
            guard let buffers = bodyBufferCache[body.id] else { continue }
            // Point-cloud bodies are drawn in the dedicated pass below — skip
            // the mesh + wireframe paths entirely.
            if body.primitiveKind == .point { continue }

            let hasMesh =
                buffers.vertexBuffer != nil && buffers.indexBuffer != nil && buffers.indexCount > 0

            // Defer translucent mesh bodies to the transparent pass.
            // Only the surface is deferred: the body's edges still draw below, so a translucent
            // body keeps its edges (and `.xray`, which makes every surface translucent, has them).
            let defersSurface =
                body.renderLayer == .geometry && hasMesh
                && displayMode.surfaceOpacity(
                    forMaterialOpacity: body.effectiveMaterial.opacity, xrayOpacity: xrayOpacity)
                    < 1.0
            if defersSurface {
                transparentBodies.append((body, buffers))
            }

            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            let selState = selectionState(of: body)
            var bodyUniforms = BodyUniforms(body: body, objectIndex: 0, isSelected: selState)

            if displayMode.showsSurfaces, hasMesh, !defersSurface {
                mainEncoder.setDepthStencilState(depthState)
                encodeSurface(buffers, uniforms: &uniforms, bodyUniforms: &bodyUniforms)
                // Per-triangle highlights straight over the surface they style, so they composite
                // before the translucent pass rather than over it (#171).
                encodeHighlight(body, buffers, uniforms: &uniforms)
                mainEncoder.setDepthStencilState(depthState)
            }
            encodeEdges(buffers, hasMesh: hasMesh, uniforms: &uniforms, bodyUniforms: bodyUniforms)
        }

        // Transparent surface pass (issue #53): deferred translucent bodies,
        // back-to-front, depth test on / write off, composited over the opaque set.
        if displayMode.showsSurfaces, !transparentBodies.isEmpty {
            // Depth along the line of sight in orthographic, as live (#215); an
            // `explicitOrthoBounds` projection is orthographic whatever the camera says. Each
            // key is computed once: `boundingBox` scans the body's vertices.
            var sortCamera = cameraState
            sortCamera.isOrthographic = Self.isOrthographic(options)
            let sorted =
                transparentBodies
                .map { t in
                    let localCenter = t.body.boundingBox?.center ?? SIMD3<Float>(0, 0, 0)
                    let c = t.body.transform * SIMD4<Float>(localCenter, 1)
                    let depth = RendererSharedSetup.transparentSortDepth(
                        center: SIMD3<Float>(c.x, c.y, c.z), cameraState: sortCamera)
                    return (t: t, depth: depth)
                }
                .sorted { $0.depth > $1.depth }
                .map(\.t)

            for t in sorted {
                var uniforms = makeUniforms()
                uniforms.modelMatrix = t.body.transform
                let selState = selectionState(of: t.body)
                var bodyUniforms = BodyUniforms(body: t.body, objectIndex: 0, isSelected: selState)
                bodyUniforms.color.w = displayMode.surfaceOpacity(
                    forMaterialOpacity: bodyUniforms.color.w, xrayOpacity: xrayOpacity)
                // Far-facing triangles first, then camera-facing ones, each half followed by its
                // per-triangle highlights, as live (#171).
                for culled in ViewportRenderer.translucentCullOrder(for: t.body.transform) {
                    mainEncoder.setCullMode(culled)
                    mainEncoder.setDepthStencilState(transparentDepthState)
                    encodeSurface(t.buffers, uniforms: &uniforms, bodyUniforms: &bodyUniforms)
                    encodeHighlight(t.body, t.buffers, uniforms: &uniforms)
                }
            }
            mainEncoder.setCullMode(.none)
            mainEncoder.setDepthStencilState(transparentDepthState)
        }

        // Analytic arc edge pass (issue #48): each arc is sampled adaptively to its projected
        // size with the live renderer's `ArcSampling`. With quad expansion on, the samples are
        // expanded into quad strips so arcs take the configured width and dash pattern, as live;
        // otherwise they are native lines. Same visibility rule as the edge pass: shown when the
        // display mode draws edges, or when the body has no mesh. Buffers are built per render
        // and the render waits for the GPU, so no pooling is needed here.
        let edgeConfig = options.edgeLineConfiguration
        let useQuadArcs = edgeConfig.useQuadExpansion && pipelines.quadEdgePipeline != nil
        var arcVertices: [Float] = []
        var arcQuadVertices: [Float] = []
        var arcDraws:
            [(
                body: ViewportBody, hasMesh: Bool, start: Int, count: Int, quadStart: Int,
                quadCount: Int
            )] = []
        let arcViewport = SIMD2<Float>(Float(w), Float(h))
        for body in bodies where body.isVisible && !body.arcs.isEmpty {
            let hasMesh = (bodyBufferCache[body.id]?.indexCount ?? 0) > 0
            guard displayMode.showsEdges || !hasMesh else { continue }
            let mvp = viewProjection * body.transform
            let start = arcVertices.count / 6
            let quadStart = arcQuadVertices.count / 9
            for arc in body.arcs {
                let segments = ArcSampling.segmentCount(
                    arc: arc, mvp: mvp, viewportSize: arcViewport)
                let points = RendererSharedBuffers.sampledArcPolyline(arc, segmentCount: segments)
                for (previous, current) in zip(points, points.dropFirst()) {
                    arcVertices.append(contentsOf: [
                        previous.x, previous.y, previous.z, 0, 0, 0,
                        current.x, current.y, current.z, 0, 0, 0,
                    ])
                }
                if useQuadArcs {
                    arcQuadVertices += RendererSharedBuffers.quadEdgeLineVertices(from: [points])
                }
            }
            let count = arcVertices.count / 6 - start
            let quadCount = arcQuadVertices.count / 9 - quadStart
            if count > 0 { arcDraws.append((body, hasMesh, start, count, quadStart, quadCount)) }
        }
        let arcQuadBuffer =
            useQuadArcs
            ? RendererSharedBuffers.makeEdgeBuffer(device: device, edgeVertices: arcQuadVertices)
            : nil
        let arcBuffer = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: arcVertices)

        /// Draws one body's arcs; the caller sets the depth-stencil state.
        func encodeArcs(
            _ draw: (
                body: ViewportBody, hasMesh: Bool, start: Int, count: Int, quadStart: Int,
                quadCount: Int
            )
        ) {
            var uniforms = makeUniforms()
            uniforms.modelMatrix = draw.body.transform
            var arcBodyUniforms = BodyUniforms(body: draw.body, objectIndex: 0, isSelected: 0)
            if !draw.hasMesh { arcBodyUniforms.metallic = -1.0 }  // use body colour directly
            mainEncoder.setFragmentBytes(
                &arcBodyUniforms, length: MemoryLayout<BodyUniforms>.size, index: 2)
            if let arcQuadBuffer, let quadPipeline = pipelines.quadEdgePipeline {
                var edgeUniforms = EdgeUniforms(
                    uniforms: uniforms, configuration: edgeConfig, viewportSize: arcViewport)
                mainEncoder.setRenderPipelineState(quadPipeline)
                mainEncoder.setVertexBuffer(arcQuadBuffer, offset: 0, index: 0)
                mainEncoder.setVertexBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &edgeUniforms, length: MemoryLayout<EdgeUniforms>.size, index: 1)
                mainEncoder.drawPrimitives(
                    type: .triangleStrip, vertexStart: draw.quadStart, vertexCount: draw.quadCount)
            } else if let arcBuffer {
                mainEncoder.setRenderPipelineState(pipelines.wireframePipeline)
                mainEncoder.setVertexBuffer(arcBuffer, offset: 0, index: 0)
                mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.setFragmentBytes(
                    &uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                mainEncoder.drawPrimitives(
                    type: .line, vertexStart: draw.start, vertexCount: draw.count)
            }
        }

        // Overlay-layer arcs are drawn in the overlay pass, on top of everything (#170).
        mainEncoder.setDepthStencilState(depthState)
        for draw in arcDraws where draw.body.renderLayer == .geometry {
            encodeArcs(draw)
        }

        // Point-cloud pass (issue #28): geometry-layer `.point` bodies.
        mainEncoder.setDepthStencilState(depthState)
        for body in bodies
        where body.isVisible && body.renderLayer == .geometry && body.primitiveKind == .point {
            guard let buffers = bodyBufferCache[body.id] else { continue }
            encodePoints(body, buffers)
        }

        // Selection mask: stencil-mark each selected or hovered geometry body's whole silhouette,
        // without drawing colour or testing depth, so the outline below is the ring around it and
        // never paints over nearer geometry (#177). Covers translucent bodies and display modes
        // without surfaces alike. Per-triangle highlights were drawn with their surfaces (#171).
        var outlinedBodyIDs: Set<String> = []
        mainEncoder.setDepthStencilState(stencilMarkState)
        mainEncoder.setStencilReferenceValue(1)
        for body in bodies
        where body.isVisible && body.renderLayer == .geometry && body.primitiveKind != .point
            && selectionState(of: body) > 0
        {
            guard let buffers = bodyBufferCache[body.id],
                let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                buffers.indexCount > 0,
                let pipeline = buffers.normalBuffer != nil
                    ? pipelines.stencilMaskDirectPipeline : pipelines.stencilMaskPipeline
            else { continue }
            var uniforms = makeUniforms()
            uniforms.modelMatrix = body.transform
            outlinedBodyIDs.insert(body.id)
            mainEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            if let patches = drawnPatches(buffers),
                let tessellated = refined?.tessellatedStencilMask
            {
                RendererSharedSetup.encodeTessellatedDraw(
                    encoder: mainEncoder, pipeline: tessellated, tessellation: patches,
                    uniforms: &uniforms)
                continue
            }
            mainEncoder.setRenderPipelineState(pipeline)
            mainEncoder.setVertexBuffer(vb, offset: 0, index: 0)
            if let nb = buffers.normalBuffer {
                mainEncoder.setVertexBuffer(nb, offset: 0, index: 2)
            }
            mainEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            mainEncoder.drawIndexedPrimitives(
                type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                indexBuffer: ib, indexBufferOffset: 0)
        }

        // Selection outline pass: the selection mask dilated in screen space by each style's
        // width, drawn only where the stencil is unmarked, which leaves a ring around each
        // selected or hovered body (#209).
        if !outlinedBodyIDs.isEmpty, let mask = outlineMask, let scissor = outlineScissor,
            let outlinePipeline = pipelines.outlinePipeline
        {
            mainEncoder.setDepthStencilState(stencilTestState)
            mainEncoder.setStencilReferenceValue(1)
            RendererSharedSetup.encodeSelectionOutline(
                encoder: mainEncoder, pipeline: outlinePipeline, mask: mask,
                params: outlineParams, scissor: scissor, targetSize: SIMD2(w, h))
        }

        // Overlay pass: `RenderLayer.overlay` bodies (manipulator widgets, markers), drawn last
        // with always-pass depth and no depth writes so they stay visible through any geometry.
        // As live (#170): their surfaces draw in every display mode and receive no shadows, and
        // their edges and arcs follow the display mode's edge rule, on top too.
        for body in bodies where body.isVisible && body.renderLayer == .overlay {
            mainEncoder.setDepthStencilState(overlayDepthState)
            // An arc-only body has no cached buffers: its arcs live in this render's arc buffers.
            if let buffers = bodyBufferCache[body.id] {
                if body.primitiveKind == .point {
                    encodePoints(body, buffers)
                    continue
                }
                let hasMesh =
                    buffers.vertexBuffer != nil && buffers.indexBuffer != nil
                    && buffers.indexCount > 0
                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                uniforms.shadowParams.z = 0
                var bodyUniforms = BodyUniforms(body: body, objectIndex: 0, isSelected: 0)
                if hasMesh {
                    // Widgets draw their plain mesh, untessellated, as live.
                    encodeSurface(
                        buffers, uniforms: &uniforms, bodyUniforms: &bodyUniforms, refine: false)
                }
                encodeEdges(
                    buffers, hasMesh: hasMesh, uniforms: &uniforms, bodyUniforms: bodyUniforms)
            }
            for draw in arcDraws where draw.body.id == body.id {
                encodeArcs(draw)
            }
        }

        mainEncoder.endEncoding()

        if let compositeTargets {
            encodeSSAOComposite(
                commandBuffer: commandBuffer,
                bodies: bodies,
                targets: compositeTargets,
                output: resolve,
                options: options,
                nearPlane: nearClip,
                farPlane: farClip,
                refined: refined,
                makeUniforms: makeUniforms
            )
        }

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

    /// Single-sample colour + depth targets for the SSAO / silhouette composite, or `nil` if they
    /// can't be allocated (the render then goes ahead without the composite).
    private func postProcessTargets(width: Int, height: Int) -> (
        color: MTLTexture, depth: MTLTexture
    )? {
        if let color = postColorTexture, let depth = postDepthTexture,
            color.width == width, color.height == height
        {
            return (color, depth)
        }
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .private
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget, .shaderRead]
        depthDesc.storageMode = .private
        postColorTexture = device.makeTexture(descriptor: colorDesc)
        postDepthTexture = device.makeTexture(descriptor: depthDesc)
        guard let color = postColorTexture, let depth = postDepthTexture else {
            postColorTexture = nil
            postDepthTexture = nil
            return nil
        }
        return (color, depth)
    }

    /// Encodes the live renderer's SSAO / silhouette post-process: a single-sample depth prepass,
    /// then the `ssao_fragment` composite from `targets.color` into `output`.
    ///
    /// The composite shader also applies ACES tone mapping (`exposure`, `whitePoint`), as on the
    /// live path. Depth of field is never applied offscreen.
    private func encodeSSAOComposite(
        commandBuffer: MTLCommandBuffer,
        bodies: [ViewportBody],
        targets: (color: MTLTexture, depth: MTLTexture),
        output: MTLTexture,
        options: OffscreenRenderOptions,
        nearPlane: Float,
        farPlane: Float,
        refined: RefinedPipelines?,
        makeUniforms: () -> Uniforms
    ) {
        guard let compositePipeline = ssaoCompositePipeline,
            let depthPipeline = depthOnlyPipeline,
            let depthDirectPipeline = depthOnlyDirectPipeline
        else { return }

        // Depth prepass. Like the live renderer it writes only opaque geometry-layer meshes
        // (`ViewportRenderer.writesSSAODepth`), discarding fragments behind the section planes.
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = targets.depth
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = 1.0
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthPass) {
            encoder.setDepthStencilState(depthState)
            for body in bodies where body.isVisible && ViewportRenderer.writesSSAODepth(body) {
                guard let buffers = bodyBufferCache[body.id],
                    let vb = buffers.vertexBuffer, let ib = buffers.indexBuffer,
                    buffers.indexCount > 0
                else { continue }
                var uniforms = makeUniforms()
                uniforms.modelMatrix = body.transform
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                if Self.encodeRefinedDraw(
                    encoder: encoder, buffers: buffers, meshPipeline: refined?.meshDepthOnly,
                    tessellatedPipeline: refined?.tessellatedDepthOnly, uniforms: &uniforms)
                {
                    continue
                }
                if let nb = buffers.normalBuffer {
                    encoder.setRenderPipelineState(depthDirectPipeline)
                    encoder.setVertexBuffer(vb, offset: 0, index: 0)
                    encoder.setVertexBuffer(nb, offset: 0, index: 2)
                } else {
                    encoder.setRenderPipelineState(depthPipeline)
                    encoder.setVertexBuffer(vb, offset: 0, index: 0)
                }
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: buffers.indexCount, indexType: .uint32,
                    indexBuffer: ib, indexBufferOffset: 0)
            }
            encoder.endEncoding()
        }

        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = output
        compositePass.colorAttachments[0].loadAction = .dontCare
        compositePass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePass)
        else { return }
        let lighting = options.lightingConfiguration
        var params = SSAOParamsSwift(
            texelSize: SIMD2<Float>(
                1.0 / Float(max(options.width, 1)), 1.0 / Float(max(options.height, 1))),
            radius: lighting.ssaoRadius,
            intensity: lighting.enableSSAO ? lighting.ssaoIntensity : 0.0,
            nearPlane: nearPlane,
            farPlane: farPlane,
            silhouetteThickness: options.enableSilhouettes ? options.silhouetteThickness : 0.0,
            silhouetteIntensity: options.enableSilhouettes ? options.silhouetteIntensity : 0.0,
            exposure: lighting.exposure,
            whitePoint: lighting.whitePoint,
            dofAperture: 0,
            dofFocalDistance: 0,
            dofMaxBlurRadius: 0,
            dofEnabled: 0
        )
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(targets.depth, index: 0)
        encoder.setFragmentTexture(targets.color, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SSAOParamsSwift>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func ensureTextures(width: Int, height: Int, sampleCount: Int) {
        guard width != cachedWidth || height != cachedHeight || sampleCount != cachedSampleCount
        else { return }

        // With one sample there is no multisample color target: the pass draws straight into
        // `resolveTexture`, and depth is a plain 2D texture (Metal rejects a multisample texture
        // with a sample count of 1, issue #134).
        if sampleCount > 1 {
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            colorDesc.textureType = .type2DMultisample
            colorDesc.sampleCount = sampleCount
            colorDesc.usage = [.renderTarget]
            colorDesc.storageMode = .private
            msaaColorTexture = device.makeTexture(descriptor: colorDesc)
        } else {
            msaaColorTexture = nil
        }

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDesc.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        depthDesc.sampleCount = sampleCount
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private
        msaaDepthTexture = device.makeTexture(descriptor: depthDesc)

        let resolveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        resolveDesc.usage = [.renderTarget, .shaderRead]
        resolveDesc.storageMode = .private
        resolveTexture = device.makeTexture(descriptor: resolveDesc)

        // Only cache a complete set, so a failed allocation is retried on the next render.
        let complete =
            msaaDepthTexture != nil && resolveTexture != nil
            && (sampleCount == 1 || msaaColorTexture != nil)
        cachedWidth = complete ? width : 0
        cachedHeight = complete ? height : 0
        cachedSampleCount = complete ? sampleCount : 0
    }

    /// Sample count `init` builds pipelines for, and the `OffscreenRenderOptions` default.
    static let defaultSampleCount = 4

    /// Maps a requested MSAA sample count to one the device supports.
    ///
    /// Values below 2 mean no MSAA (1). Otherwise the largest of 8, 4 and 2 that does not exceed
    /// the request and that the device supports is used, falling back to 1.
    nonisolated static func supportedSampleCount(
        _ requested: Int, supports: (Int) -> Bool
    ) -> Int {
        guard requested > 1 else { return 1 }
        return [8, 4, 2].first { $0 <= requested && supports($0) } ?? 1
    }

    private static func supportedSampleCount(_ requested: Int, device: MTLDevice) -> Int {
        supportedSampleCount(requested) { device.supportsTextureSampleCount($0) }
    }

    /// Whether `render(bodies:options:)` projects orthographically: an orthographic camera, or
    /// any camera with `explicitOrthoBounds`.
    nonisolated static func isOrthographic(_ options: OffscreenRenderOptions) -> Bool {
        options.cameraState.isOrthographic || options.explicitOrthoBounds != nil
    }

    /// The camera `render(bodies:options:)` draws with: `options.cameraState`, with an
    /// orthographic eye moved back along the line of sight in front of `eyeBounds()` (see
    /// `CameraState.placingOrthographicEye(inFrontOf:)`), which is only called then.
    ///
    /// It used to render the camera as given, so an orthographic camera whose eye sat inside the
    /// scene, as one built with a small `distance` does, had its front near-clipped (#215).
    ///
    /// Moving the eye changes neither the projection nor the lit shading (see
    /// `RendererSharedSetup.shadingEyePosition`). It changes the clip planes, so whatever reads
    /// them changes too: the edge depth fade, and the composite pass (SSAO, silhouettes), which
    /// still decodes orthographic depth as perspective depth. An `explicitOrthoBounds`
    /// projection is orthographic whatever the camera's projection, so its eye is placed too;
    /// the grid and axes keep sizing themselves from `options.cameraState`, as that camera's
    /// `distance` sizes them.
    nonisolated static func renderCamera(
        options: OffscreenRenderOptions, eyeBounds: () -> BoundingBox?
    ) -> CameraState {
        var camera = options.cameraState
        guard isOrthographic(options) else { return camera }
        camera.isOrthographic = true
        camera = camera.placingOrthographicEye(inFrontOf: eyeBounds())
        camera.isOrthographic = options.cameraState.isOrthographic
        return camera
    }

    /// The projection `render(bodies:options:)` draws with: `explicitOrthoBounds` when set, else
    /// the camera's, then shifted by `pixelPan`.
    nonisolated static func projectionMatrix(
        options: OffscreenRenderOptions, near: Float, far: Float
    ) -> simd_float4x4 {
        let w = options.width
        let h = options.height
        let base: simd_float4x4
        if let bounds = options.explicitOrthoBounds {
            base = simd_float4x4.orthographic(
                left: bounds.left, right: bounds.right, bottom: bounds.bottom, top: bounds.top,
                near: near, far: far)
        } else {
            base = options.cameraState.projectionMatrix(
                aspectRatio: Float(w) / Float(max(h, 1)), near: near, far: far)
        }
        guard let pan = options.pixelPan, pan != .zero, w > 0, h > 0 else { return base }
        // Screen-space pixels → NDC translation. Screen y is down, NDC y is up.
        var panMatrix = matrix_identity_float4x4
        panMatrix.columns.3 = SIMD4<Float>(2 * pan.x / Float(w), -2 * pan.y / Float(h), 0, 1)
        return panMatrix * base
    }

    /// The rendered view's frustum with near and far planes far enough apart to hold any scene,
    /// for deciding which overlays lie in view before the clip planes are fitted.
    ///
    /// Built from `projectionMatrix(options:near:far:)`, so it follows `explicitOrthoBounds` and
    /// `pixelPan` like the image does (#209); the camera's own frustum missed an overlay they
    /// brought into view, and its depth then went unfitted and the near plane clipped it.
    ///
    /// `camera` is the camera drawn with, `renderCamera(options:eyeBounds:)`, when it differs
    /// from `options.cameraState`: the frustum's near plane is just in front of the eye, so an
    /// overlay between the given eye and the placed one fell outside it, and went unfitted
    /// (#215). `nil` reads `options.cameraState`.
    nonisolated static func wideViewFrustum(
        options: OffscreenRenderOptions, camera: CameraState? = nil
    ) -> Frustum {
        Frustum(
            viewProjection: projectionMatrix(options: options, near: 1e-3, far: 1e7)
                * (camera ?? options.cameraState).viewMatrix)
    }

    /// Returns the pipelines for `sampleCount`, building and caching them on first use.
    private func pipelines(forSampleCount sampleCount: Int) -> SampledPipelines? {
        if let cached = pipelinesBySampleCount[sampleCount] { return cached }
        guard
            let built = SampledPipelines(
                device: device, library: library, sampleCount: sampleCount)
        else { return nil }
        pipelinesBySampleCount[sampleCount] = built
        return built
    }

    /// The tessellated and mesh-shader pipelines `options.renderingQuality` asks for, built and
    /// cached on first use; `nil` at `.standard`.
    private func refinedPipelines(
        for options: OffscreenRenderOptions, sampleCount: Int
    ) -> RefinedPipelines? {
        guard RendererSharedSetup.wantsTessellation(options.renderingQuality) else { return nil }
        // Mesh shaders don't need the manager, so a failed manager only loses tessellation.
        if tessellationManager == nil, !tessellationManagerFailed {
            tessellationManager = TessellationManager(device: device, library: library)
            tessellationManagerFailed = tessellationManager == nil
        }
        let key = RefinedPipelines.Key(
            sampleCount: sampleCount,
            maxFactor: TessellationManager.clampedMaxFactor(options.tessellationMaxFactor),
            meshShaders: RendererSharedSetup.wantsMeshShaders(
                options.renderingQuality, device: device))
        if let cached = refinedPipelinesByKey[key] { return cached }
        let built = RefinedPipelines(device: device, library: library, key: key)
        refinedPipelinesByKey[key] = built
        return built
    }

    /// The refined surface paths the next render with `options` uses; exposed for tests.
    func surfacePaths(for options: OffscreenRenderOptions) -> (
        tessellation: Bool, meshShaders: Bool
    ) {
        let sampleCount = Self.supportedSampleCount(options.msaaSampleCount, device: device)
        let refinement = refinedPipelines(for: options, sampleCount: sampleCount)?.refinement(
            canTessellate: tessellationManager != nil)
        return (refinement?.tessellation ?? false, refinement?.meshShaders ?? false)
    }

    /// Whether the cached buffers for `bodyID` include tessellation patches / meshlets; exposed
    /// for tests.
    func refinementBuffers(forBodyID bodyID: String) -> (tessellation: Bool, meshlets: Bool) {
        let buffers = bodyBufferCache[bodyID]
        return (buffers?.tessellation != nil, buffers?.meshlets != nil)
    }

    /// Draws `buffers` through the mesh-shader pipeline when it has meshlets, else the
    /// tessellated pipeline when it has patches, mirroring the live renderer's precedence.
    ///
    /// - Returns: `false` when neither applies (direct-mesh bodies, `.standard`, or a body
    ///   without `faceIndices`); the caller then draws the plain mesh.
    private static func encodeRefinedDraw<U>(
        encoder: MTLRenderCommandEncoder,
        buffers: BodyBuffersOffscreen,
        meshPipeline: MTLRenderPipelineState?,
        tessellatedPipeline: MTLRenderPipelineState?,
        uniforms: inout U
    ) -> Bool {
        guard buffers.normalBuffer == nil, let vb = buffers.vertexBuffer else { return false }
        if let meshlets = buffers.meshlets, let meshPipeline {
            RendererSharedSetup.encodeMeshletDraw(
                encoder: encoder, pipeline: meshPipeline, meshlets: meshlets, vertexBuffer: vb,
                uniforms: &uniforms)
            return true
        }
        if let tessellation = buffers.tessellation, let tessellatedPipeline {
            RendererSharedSetup.encodeTessellatedDraw(
                encoder: encoder, pipeline: tessellatedPipeline, tessellation: tessellation,
                uniforms: &uniforms)
            return true
        }
        return false
    }

    /// Drops cached buffers for bodies no longer passed to `render`, matching the live renderer.
    private func pruneBufferCache(keeping bodies: [ViewportBody]) {
        let activeIDs = Set(bodies.map(\.id))
        for id in bodyGeneration.keys where !activeIDs.contains(id) {
            bodyBufferCache.removeValue(forKey: id)
            bodyGeneration.removeValue(forKey: id)
        }
    }

    /// Number of bodies with cached GPU buffers; exposed for tests.
    var cachedBodyCount: Int { bodyBufferCache.count }

    private func ensureBuffers(
        for body: ViewportBody, options: OffscreenRenderOptions, refinement: SurfaceRefinement
    ) {
        let currentGen = body.generation
        // Crease-smoothed normals (issue #48) depend on the options as well as the body, so the
        // cached mesh is reused only when it was built with the same smoothing.
        let smoothingApplies =
            options.autoSmoothNormals && !body.usesDirectMesh && !body.vertexData.isEmpty
            && !body.indices.isEmpty
        // The PN patches read the crease angle too (#202).
        let smoothingKey: Float? =
            smoothingApplies || refinement.tessellation ? options.normalSmoothingCreaseAngle : nil
        // Likewise the tessellation patches and meshlets depend on `renderingQuality`. A body with
        // no geometry has no entry and stays a cache hit until its generation changes.
        let cached = bodyBufferCache[body.id]
        if let cachedGen = bodyGeneration[body.id], cachedGen == currentGen,
            cached?.smoothingKey == smoothingKey,
            cached.map({ $0.refinement == refinement }) ?? true
        {
            return
        }

        let smoothed = RendererSharedBuffers.smoothedVertexData(
            for: body, autoSmoothNormals: options.autoSmoothNormals,
            creaseAngle: options.normalSmoothingCreaseAngle)
        let mesh = RendererSharedBuffers.makeMeshBuffers(
            device: device, body: body, interleavedVertexData: smoothed)

        let nativeEdgeVertices = RendererSharedBuffers.nativeEdgeLineVertices(from: body.edges)
        let nativeEdgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: nativeEdgeVertices)
        let nativeEdgeVertexCount = nativeEdgeVertices.count / 6

        let quadEdgeVertices = RendererSharedBuffers.quadEdgeLineVertices(from: body.edges)
        let quadEdgeVB = RendererSharedBuffers.makeEdgeBuffer(
            device: device, edgeVertices: quadEdgeVertices)
        let quadEdgeVertexCount = quadEdgeVertices.count / 9

        // Point-cloud buffers (issue #28), built only when `body.vertices` is non-empty.
        let pointPositionVB = RendererSharedBuffers.makePointPositionBuffer(
            device: device, vertices: body.vertices)
        let pointColorVB = RendererSharedBuffers.makePointColorBuffer(
            device: device, vertexColors: body.vertexColors, vertexCount: body.vertices.count)

        // Drop the previous generation's entry when the body no longer has any geometry, so a
        // body that keeps its `id` but clears its data stops drawing (#136 M10).
        guard mesh.vertexBuffer != nil || nativeEdgeVB != nil || pointPositionVB != nil else {
            bodyBufferCache.removeValue(forKey: body.id)
            bodyGeneration[body.id] = currentGen
            return
        }

        let refined = RendererSharedBuffers.makeRefinementBuffers(
            for: body, smoothedVertexData: smoothed, mesh: mesh,
            tessellationManager: refinement.tessellation ? tessellationManager : nil,
            buildMeshlets: refinement.meshShaders, creaseAngle: options.normalSmoothingCreaseAngle,
            device: device, commandQueue: commandQueue)

        bodyBufferCache[body.id] = BodyBuffersOffscreen(
            vertexBuffer: mesh.vertexBuffer,
            normalBuffer: mesh.normalBuffer,
            indexBuffer: mesh.indexBuffer,
            indexCount: mesh.indexCount,
            edgeVertexBuffer: nativeEdgeVB,
            edgeVertexCount: nativeEdgeVertexCount,
            quadEdgeVertexBuffer: quadEdgeVB,
            quadEdgeVertexCount: quadEdgeVertexCount,
            vertexCount: mesh.vertexCount,
            pointPositionBuffer: pointPositionVB,
            pointVertexCount: pointPositionVB != nil ? body.vertices.count : 0,
            pointColorBuffer: pointColorVB,
            smoothingKey: smoothingKey,
            tessellation: refined.tessellation,
            meshlets: refined.meshlets,
            refinement: refinement
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
    let quadEdgeVertexBuffer: MTLBuffer?
    let quadEdgeVertexCount: Int
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

    /// Crease angle the mesh normals were smoothed with, or `nil` when they are the body's own.
    let smoothingKey: Float?

    /// PN-triangle patches, when the render tessellates and the body can be (#165).
    let tessellation: TessellationBuffers?
    /// Meshlets, when the render uses mesh shaders and the body can (#165).
    let meshlets: MeshletBuffers?
    /// The refined paths `tessellation` and `meshlets` were built for.
    let refinement: SurfaceRefinement
}
