// ViewportConfiguration.swift
// ViewportKit
//
// Master configuration for viewport behavior and appearance.

import Foundation
import simd

// MARK: - Edge Line Style

/// Dash pattern kind for edge lines.
public enum EdgeLineDashKind: UInt32, Sendable, Hashable {
    case solid
    case dashed
    case dotted
    case dashDot
}

/// Dash pattern for edge lines.
public struct EdgeLineDashPattern: Sendable, Hashable {
    /// Pattern kind.
    public var kind: EdgeLineDashKind
    /// Dash length in world units.
    public var dashLength: Float
    /// Gap length in world units.
    public var gapLength: Float
    /// Dot length in world units.
    public var dotLength: Float
    /// Phase offset in world units.
    public var phase: Float

    public init(
        dashLength: Float = 0,
        gapLength: Float = 0,
        dotLength: Float = 2,
        phase: Float = 0
    ) {
        self.kind = dashLength > 0 ? .dashed : .solid
        self.dashLength = dashLength
        self.gapLength = gapLength
        self.dotLength = dotLength
        self.phase = phase
    }

    public init(
        kind: EdgeLineDashKind,
        dashLength: Float,
        gapLength: Float,
        dotLength: Float = 2,
        phase: Float = 0
    ) {
        self.kind = kind
        self.dashLength = dashLength
        self.gapLength = gapLength
        self.dotLength = dotLength
        self.phase = phase
    }

    /// Solid line (no dash).
    public static let solid = EdgeLineDashPattern()

    /// Standard dashed line.
    public static let dashed = EdgeLineDashPattern(
        kind: .dashed, dashLength: 10, gapLength: 5)

    /// Dotted line, rendered as very short square-ended dashes (`dashLength`/`gapLength`);
    /// round dots are not supported and `dotLength` is unused for this kind.
    public static let dotted = EdgeLineDashPattern(
        kind: .dotted, dashLength: 2, gapLength: 3, dotLength: 2)

    /// Dash-dot line.
    public static let dashDot = EdgeLineDashPattern(
        kind: .dashDot, dashLength: 8, gapLength: 3, dotLength: 2)
}

/// Configuration for edge/wireframe line rendering.
public struct EdgeLineConfiguration: Sendable {
    /// Line width in pixels (1.0 = default thin line).
    public var width: Float
    /// Dash pattern for edges.
    public var dashPattern: EdgeLineDashPattern
    /// Whether to use quad-expanded lines (true) or native Metal lines (false).
    /// Quad expansion enables variable width and dash patterns.

    public var useQuadExpansion: Bool

    public init(
        width: Float = 1.0,
        dashPattern: EdgeLineDashPattern = .solid,
        useQuadExpansion: Bool = true
    ) {
        self.width = width
        self.dashPattern = dashPattern
        self.useQuadExpansion = useQuadExpansion
    }

    /// Default thin solid lines.
    public static let `default` = EdgeLineConfiguration()

    /// Bold lines for selection highlighting.
    public static let bold = EdgeLineConfiguration(width: 3.0)

    /// Dashed lines for construction/hidden geometry.
    public static let dashed = EdgeLineConfiguration(dashPattern: .dashed)
}

// MARK: - Selection Outline Style

/// Colour and width of the outline ring drawn around a selected or hovered body.
public struct SelectionOutlineStyle: Sendable, Hashable {
    /// Outline colour in linear RGB.
    public var color: SIMD3<Float>

    /// Outline width in drawable pixels, constant at any zoom and model scale; 0 hides it.
    public var width: Float

    public init(color: SIMD3<Float>, width: Float = 3.0) {
        self.color = color
        self.width = width
    }

    /// Default outline for selected bodies: bright blue, 3 px.
    public static let selection = SelectionOutlineStyle(color: SIMD3<Float>(0.1, 0.5, 1.0))

    /// Default outline for the hovered body: light blue, 3 px.
    public static let hover = SelectionOutlineStyle(color: SIMD3<Float>(0.4, 0.7, 1.0))
}

// MARK: - Grid Style

/// Rendering style for the ground grid.
///
/// The grid lies in the XY plane at z = 0 (the world is Z-up). Both styles use the adaptive
/// spacing from `gridBaseSpacing` / `gridSubdivisions`, centre on the camera pivot and stop at
/// the `gridSize` square around the origin.
public enum GridStyle: Sendable {
    /// Ground plane: grid lines over a faint translucent fill, with every
    /// `gridSubdivisions`-th line drawn stronger (default).
    case plane
    /// Adaptive dot grid that snaps spacing levels based on zoom.
    case dots
}

// MARK: - Axis Style

/// Rendering style for coordinate axes.
///
/// Either way each axis is an unlit cylinder `axisLength` long from the origin (X red, Y green,
/// Z blue) over a 1 px centre line, so it never vanishes when the radius falls below a pixel.
public enum AxisStyle: Sendable {
    /// Fixed world-space radius, `axisRadius` (default).
    case cylinder
    /// Radius scales with the view's visible height at the pivot, so the axes keep the screen
    /// width `axisRadius` gives from the default camera (distance 10, 45° FOV) at any zoom.
    case constantScreenWidth
}

// MARK: - Rendering Quality

/// Rendering quality level controlling tessellation and shading fidelity.
public enum RenderingQuality: Sendable {
    /// Finer CPU tessellation + crease-aware normal smoothing.
    case standard
    /// Standard + GPU hardware tessellation with PN triangles (Apple3+).
    case enhanced
    /// Enhanced + mesh shaders with per-meshlet culling (Apple9+ / M3+, falls back to enhanced).
    case maximum
}

/// How the uniform tessellation factor is chosen when `adaptiveTessellation` is `false`.
public enum UniformTessellationFactor: Sendable, Equatable {
    /// Scale the factor to system load, between `minimum` and `tessellationMaxFactor`.
    ///
    /// The live renderer lowers the factor when the smoothed GPU frame time nears the frame
    /// budget (`1 / preferredFramesPerSecond`), under thermal pressure, or in Low Power Mode,
    /// and raises it again when there is headroom, with hysteresis so it does not oscillate.
    case loadAdaptive(minimum: Int = 4)
    /// Always tessellate at this factor (clamped to `1...tessellationMaxFactor`).
    case fixed(Int)
}

/// Master configuration for a viewport.
///
/// ViewportConfiguration aggregates all settings for camera behavior,
/// gesture handling, display modes, and lighting.
public struct ViewportConfiguration: Sendable {

    // MARK: - Camera Settings

    /// Initial camera state when viewport loads.
    public var initialCameraState: CameraState

    /// Rotation style (arcball or turntable).
    public var rotationStyle: RotationStyle

    /// Minimum distance from pivot.
    public var minDistance: Float

    /// Maximum distance from pivot.
    public var maxDistance: Float

    /// Vertical field of view of the initial perspective camera in degrees, or `nil` (the
    /// default) to keep `initialCameraState.fieldOfView`.
    ///
    /// When set, it overrides `initialCameraState.fieldOfView` when a `ViewportController` is
    /// created (see `effectiveInitialCameraState`). Either way the resulting FOV is the one
    /// `ViewportController.reset(animated:)` returns to. `nil` by default so that assigning
    /// `initialCameraState` after creating the configuration keeps that camera's own FOV.
    public var defaultFieldOfView: Float?

    /// `initialCameraState` with `defaultFieldOfView` applied when it is set: the camera a new
    /// `ViewportController` starts from.
    public var effectiveInitialCameraState: CameraState {
        var state = initialCameraState
        if let defaultFieldOfView { state.fieldOfView = defaultFieldOfView }
        return state
    }

    // MARK: - Gesture Settings

    /// Gesture configuration.
    public var gestureConfiguration: GestureConfiguration

    // MARK: - Display Settings

    /// Display mode for geometry.
    public var displayMode: DisplayMode

    /// Lighting configuration.
    public var lightingConfiguration: LightingConfiguration

    /// Whether to show the ViewCube.
    public var showViewCube: Bool

    /// ViewCube position.
    public var viewCubePosition: ViewCubePosition

    /// Whether to show the screen-space orientation gnomon (HUD corner axes).
    public var showOrientationGnomon: Bool

    /// Whether to show the screen-space scale bar (HUD).
    public var showScaleBar: Bool

    /// Unit suffix appended to the scale bar's number, e.g. `"mm"`.
    ///
    /// Empty (the default) shows the number on its own. Purely a label: it does not convert
    /// or scale the value, which is always in the scene's own world units.
    public var scaleBarUnitLabel: String

    /// Whether to show coordinate axes.
    public var showAxes: Bool

    /// Axis length in world units, measured from the origin, or `nil` (the default) to size the
    /// axes to the scene.
    ///
    /// Automatic length is `max(1.5 × reach, 0.5 × diagonal)` of the visible geometry's world
    /// bounds, `reach` being its largest absolute coordinate, so the axes poke out of the model
    /// at any scale; an empty scene gets 2 units. A value set here always wins.
    public var axisLength: Float?

    /// Axis cylinder radius in world units (`.cylinder`), or the radius at the default camera's
    /// zoom (`.constantScreenWidth`).
    public var axisRadius: Float

    /// Rendering style for coordinate axes.
    public var axisStyle: AxisStyle

    /// Whether to show ground grid.
    public var showGrid: Bool

    /// Rendering style for the ground grid.
    public var gridStyle: GridStyle

    /// Side length of the square grid, in world units, centred on the world origin.
    ///
    /// Bounds both styles: no line or dot is drawn outside the square. Zero, negative or
    /// `.infinity` leaves the grid unbounded (it still only covers a window around the pivot).
    public var gridSize: Float

    /// Fundamental grid unit in world units (both grid styles).
    public var gridBaseSpacing: Float

    /// Subdivision factor between spacing levels (both grid styles).
    public var gridSubdivisions: Int

    /// Background color in light appearance (platform-agnostic).
    ///
    /// In dark appearance `MetalViewportView` uses `darkModeBackgroundColor` instead, unless that
    /// is `nil`.
    public var backgroundColor: SIMD4<Float>

    /// Background colour used while the appearance is dark, or `nil` to opt out of following
    /// dark mode.
    ///
    /// `MetalViewportView` follows the SwiftUI colour scheme of its environment: system dark mode,
    /// or whatever the app forces with `.preferredColorScheme(_:)` /
    /// `.environment(\.colorScheme, _)`. Defaults to `defaultDarkModeBackgroundColor`; set your
    /// own colour, or `nil` to keep `backgroundColor` in both appearances. `OffscreenRenderOptions`
    /// carries the same field.
    public var darkModeBackgroundColor: SIMD4<Float>?

    /// The default dark-appearance background, a near-black grey `(0.12, 0.12, 0.12, 1)`.
    public static let defaultDarkModeBackgroundColor = SIMD4<Float>(0.12, 0.12, 0.12, 1.0)

    /// The background colour for the given colour scheme: `darkModeBackgroundColor` when `isDark`
    /// and it is set, otherwise `backgroundColor`.
    public func resolvedBackgroundColor(isDark: Bool) -> SIMD4<Float> {
        if isDark, let dark = darkModeBackgroundColor { return dark }
        return backgroundColor
    }

    // MARK: - Anti-Aliasing

    /// Requested MSAA sample count: 1 for no anti-aliasing, 4 (the default) for 4x.
    ///
    /// The renderer clamps the request to a count the device supports: values below 2 mean no
    /// MSAA, otherwise the largest of 8, 4 and 2 that does not exceed the request and that
    /// `MTLDevice.supportsTextureSampleCount(_:)` accepts, falling back to 1. The same mapping
    /// applies to `OffscreenRenderOptions.msaaSampleCount`.
    public var msaaSampleCount: Int

    // MARK: - Frame Rate

    /// Frame rate the viewport asks for, in frames per second (default 120).
    ///
    /// `MTKView` picks the supported display rate closest to this, so the default runs at 120 Hz
    /// on ProMotion displays and at 60 Hz on 60 Hz ones. Set 60 to cap the frame rate and save
    /// power. The camera's animation and inertia timer runs at the same rate. On iPhone, rates
    /// above 60 also need `CADisableMinimumFrameDurationOnPhone` set to `YES` in the app's
    /// Info.plist.
    public var preferredFramesPerSecond: Int = 120

    // MARK: - Edge Silhouettes

    /// Whether screen-space edge silhouettes are enabled.
    public var enableSilhouettes: Bool

    /// Silhouette edge thickness (1.0 = normal, 2.0 = thick).
    public var silhouetteThickness: Float

    /// Silhouette edge darkness (0 = invisible, 1 = fully dark).
    public var silhouetteIntensity: Float

    // MARK: - Selection Outline

    /// Outline drawn around selected bodies.
    ///
    /// The width is in drawable pixels, so the ring looks the same on a millimetre-scale part
    /// and a building. Defaults to ``SelectionOutlineStyle/selection``.
    public var selectionOutline: SelectionOutlineStyle = .selection

    /// Outline drawn around the hovered body when it is not also selected.
    ///
    /// Defaults to ``SelectionOutlineStyle/hover``.
    public var hoverOutline: SelectionOutlineStyle = .hover

    // MARK: - Edge Lines

    /// Configuration for edge/wireframe line rendering (width, dash pattern, quad expansion).
    public var edgeLineConfiguration: EdgeLineConfiguration

    /// Whether to skip bodies whose world-space bounds fall wholly outside the view (issue #42).
    ///
    /// On by default, since off-screen bodies are not visible anyway and skipping them is the
    /// main lever on large scenes. Two carve-outs: bodies with no `boundingBox` are never
    /// culled, and the shadow pass ignores the camera frustum entirely, because an off-screen
    /// caster can still shadow visible geometry.
    public var enableFrustumCulling: Bool

    /// Whether each body's normals get crease-aware smoothing as its buffers are built (#48).
    ///
    /// Meshes that arrive with per-face (flat) normals cannot be rounded by Phong
    /// tessellation. Smoothing averages normals across shared vertices, keeping hard edges via
    /// `normalSmoothingCreaseAngle`, so `.enhanced` tessellation yields smooth silhouettes.
    /// Off by default, on in `.cadHighQuality`. Computed once per body and cached, not per
    /// frame.
    public var autoSmoothNormals: Bool

    /// Angle in radians above which `autoSmoothNormals` leaves an edge sharp.
    ///
    /// Edges whose adjacent faces differ by more than this keep their crease; anything flatter
    /// gets its normals averaged. Defaults to roughly 30°.
    public var normalSmoothingCreaseAngle: Float

    // MARK: - Picking

    /// Configuration for GPU-accelerated picking.
    public var pickingConfiguration: PickingConfiguration

    // MARK: - Depth of Field

    /// Whether post-process depth of field is enabled.
    public var enableDepthOfField: Bool

    /// DoF aperture (smaller = shallower depth of field).
    public var dofAperture: Float

    /// DoF focal distance (0 = autofocus on the world-space centre of the visible geometry).
    public var dofFocalDistance: Float

    /// Maximum blur radius in pixels for DoF.
    public var dofMaxBlurRadius: Float

    // MARK: - Rendering Quality

    /// Rendering quality level (tessellation, normal smoothing, mesh shaders).
    public var renderingQuality: RenderingQuality

    /// Maximum tessellation factor for hardware tessellation (default 32).
    ///
    /// The renderer clamps this to `2...64` and rounds odd values up to even, since Metal caps
    /// the factor at 64 and the fractional-even partitioning these pipelines use needs an even
    /// value. The tessellated pipelines are built with the value in effect when the renderer is
    /// created; a later increase is capped to that value.
    public var tessellationMaxFactor: Int

    /// Whether tessellation adapts to screen-space edge length (default `true`).
    ///
    /// `true` sizes each patch's factors from its projected edge length (target ~4 px per edge)
    /// and surface curvature, capped at `tessellationMaxFactor`. `false` tessellates every patch
    /// uniformly, regardless of size on screen, at the factor `uniformTessellationFactor`
    /// chooses. A uniform factor `f` costs roughly `f²` triangles per input triangle.
    public var adaptiveTessellation: Bool

    /// The factor used when `adaptiveTessellation` is `false` (default `.loadAdaptive()`).
    ///
    /// `.loadAdaptive(minimum:)` scales the factor between `minimum` and
    /// `tessellationMaxFactor` from the measured GPU frame time, the thermal state and Low
    /// Power Mode. `.fixed(_:)` pins it. Off-screen renders always use the configured factor
    /// (`tessellationMaxFactor` for `.loadAdaptive`), so their output stays deterministic.
    public var uniformTessellationFactor: UniformTessellationFactor

    // MARK: - Temporal Anti-Aliasing

    /// Whether temporal anti-aliasing is enabled.
    public var enableTAA: Bool

    /// TAA history blend factor (0 = no history, 1 = full history).
    public var taaBlendFactor: Float

    // MARK: - Dynamic Pivot

    /// Configuration for automatic orbit-pivot adjustment.
    public var dynamicPivotConfiguration: DynamicPivotConfiguration

    // MARK: - Initialization

    /// Creates a viewport configuration with default settings.
    public init(
        initialCameraState: CameraState = .isometric,
        rotationStyle: RotationStyle = .turntable,
        minDistance: Float = 0.1,
        maxDistance: Float = 10000,
        defaultFieldOfView: Float? = nil,
        gestureConfiguration: GestureConfiguration = .default,
        displayMode: DisplayMode = .shaded,
        lightingConfiguration: LightingConfiguration = .threePoint,
        showViewCube: Bool = true,
        viewCubePosition: ViewCubePosition = .bottomTrailing,
        showAxes: Bool = false,
        axisLength: Float? = nil,
        axisRadius: Float = 0.02,
        axisStyle: AxisStyle = .cylinder,
        showGrid: Bool = true,
        gridStyle: GridStyle = .plane,
        gridSize: Float = 100.0,
        gridBaseSpacing: Float = 1.0,
        gridSubdivisions: Int = 10,
        backgroundColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.95, 0.95, 1.0),
        darkModeBackgroundColor: SIMD4<Float>? = ViewportConfiguration
            .defaultDarkModeBackgroundColor,
        msaaSampleCount: Int = 4,
        enableSilhouettes: Bool = true,
        silhouetteThickness: Float = 1.0,
        silhouetteIntensity: Float = 0.7,
        edgeLineConfiguration: EdgeLineConfiguration = .default,
        enableFrustumCulling: Bool = true,
        autoSmoothNormals: Bool = false,
        normalSmoothingCreaseAngle: Float = 0.524,
        pickingConfiguration: PickingConfiguration = .init(),
        enableDepthOfField: Bool = false,
        dofAperture: Float = 2.8,
        dofFocalDistance: Float = 0,
        dofMaxBlurRadius: Float = 8.0,
        renderingQuality: RenderingQuality = .standard,
        tessellationMaxFactor: Int = 32,
        adaptiveTessellation: Bool = true,
        uniformTessellationFactor: UniformTessellationFactor = .loadAdaptive(),
        enableTAA: Bool = false,
        taaBlendFactor: Float = 0.9,
        dynamicPivotConfiguration: DynamicPivotConfiguration = .default,
        showOrientationGnomon: Bool = false,
        showScaleBar: Bool = false,
        scaleBarUnitLabel: String = ""
    ) {
        self.initialCameraState = initialCameraState
        self.rotationStyle = rotationStyle
        self.minDistance = minDistance
        self.maxDistance = maxDistance
        self.defaultFieldOfView = defaultFieldOfView
        self.gestureConfiguration = gestureConfiguration
        self.displayMode = displayMode
        self.lightingConfiguration = lightingConfiguration
        self.showViewCube = showViewCube
        self.viewCubePosition = viewCubePosition
        self.showAxes = showAxes
        self.axisLength = axisLength
        self.axisRadius = axisRadius
        self.axisStyle = axisStyle
        self.showGrid = showGrid
        self.gridStyle = gridStyle
        self.gridSize = gridSize
        self.gridBaseSpacing = gridBaseSpacing
        self.gridSubdivisions = gridSubdivisions
        self.backgroundColor = backgroundColor
        self.darkModeBackgroundColor = darkModeBackgroundColor
        self.msaaSampleCount = msaaSampleCount
        self.enableSilhouettes = enableSilhouettes
        self.silhouetteThickness = silhouetteThickness
        self.silhouetteIntensity = silhouetteIntensity
        self.edgeLineConfiguration = edgeLineConfiguration
        self.enableFrustumCulling = enableFrustumCulling
        self.autoSmoothNormals = autoSmoothNormals
        self.normalSmoothingCreaseAngle = normalSmoothingCreaseAngle
        self.pickingConfiguration = pickingConfiguration
        self.enableDepthOfField = enableDepthOfField
        self.dofAperture = dofAperture
        self.dofFocalDistance = dofFocalDistance
        self.dofMaxBlurRadius = dofMaxBlurRadius
        self.renderingQuality = renderingQuality
        self.tessellationMaxFactor = tessellationMaxFactor
        self.adaptiveTessellation = adaptiveTessellation
        self.uniformTessellationFactor = uniformTessellationFactor
        self.enableTAA = enableTAA
        self.taaBlendFactor = taaBlendFactor
        self.dynamicPivotConfiguration = dynamicPivotConfiguration
        self.showOrientationGnomon = showOrientationGnomon
        self.showScaleBar = showScaleBar
        self.scaleBarUnitLabel = scaleBarUnitLabel
    }

    // MARK: - Presets

    /// Configuration optimized for CAD applications.
    public static let cad = ViewportConfiguration(
        rotationStyle: .turntable,
        showViewCube: true,
        showAxes: true,
        showGrid: true
    )

    /// Configuration optimized for model viewing.
    public static let modelViewer = ViewportConfiguration(
        rotationStyle: .arcball,
        showViewCube: false,
        showAxes: false,
        showGrid: false
    )

    /// Configuration for architectural visualization.
    public static let architectural = ViewportConfiguration(
        initialCameraState: StandardView.isometricFrontRight.cameraState(distance: 50),
        rotationStyle: .turntable,
        displayMode: .shaded,
        lightingConfiguration: .architectural,
        showViewCube: true,
        showGrid: true
    )

    /// Configuration tuned for large / many-body scenes on mobile (issue #42).
    ///
    /// Disables the per-frame whole-scene passes that dominate cost on big models
    /// (directional shadow map, SSAO, MSAA, silhouettes), giving a discoverable
    /// fast path instead of hand-assembling the levers. Keep this for dense scenes
    /// (thousands of bodies / hundreds of thousands of triangles) on iPhone / iPad;
    /// see the README "Scaling" section for batching guidance and recommended body
    /// counts.
    public static let performance: ViewportConfiguration = {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = false
        return ViewportConfiguration(
            rotationStyle: .turntable,
            lightingConfiguration: lighting,
            showViewCube: true,
            showAxes: true,
            showGrid: true,
            msaaSampleCount: 1,
            enableSilhouettes: false,
            renderingQuality: .standard
        )
    }()

    /// CAD configuration tuned for smooth round geometry (issue #48).
    ///
    /// Enables the GPU's screen-space-adaptive PN-triangle (Phong) tessellation
    /// (`renderingQuality = .enhanced`), so curved surfaces (cylinder and cone
    /// silhouettes, filleted faces) stay smooth at any zoom without the consumer
    /// pre-tessellating finely. Tessellation refines by projected size and surface
    /// curvature each frame, so it doesn't waste triangles on small / distant parts.
    ///
    /// - Note: This is the smoothness counterpart to `.performance`. Tessellation
    ///   adds GPU work, so prefer `.performance` for very large many-body scenes
    ///   (see #42). Smooth silhouettes need reasonable per-vertex normals on the
    ///   input mesh; OCCT meshes provide these. Requires an Apple3+ GPU (falls back
    ///   to un-tessellated rendering otherwise).
    public static let cadHighQuality = ViewportConfiguration(
        rotationStyle: .turntable,
        showViewCube: true,
        showAxes: true,
        showGrid: true,
        autoSmoothNormals: true,
        renderingQuality: .enhanced,
        tessellationMaxFactor: 48,
        adaptiveTessellation: true
    )
}

// MARK: - ViewCube Position

/// Position of the ViewCube overlay.
public enum ViewCubePosition: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}
