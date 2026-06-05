// ViewportConfiguration.swift
// ViewportKit
//
// Master configuration for viewport behavior and appearance.

import Foundation
import simd

// MARK: - Axis Style

/// Rendering style for coordinate axes.
public enum AxisStyle: Sendable {
    /// Fixed world-space radius (default).
    case cylinder
    /// Radius auto-scales with camera distance to maintain constant screen width.
    case constantScreenWidth
}

// MARK: - Grid Style

/// Rendering style for the ground grid.
public enum GridStyle: Sendable {
    /// Solid plane (default).
    case plane
    /// Adaptive dot grid that snaps spacing levels based on zoom.
    case dots
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

    /// Default field of view in degrees.
    public var defaultFieldOfView: Float

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

    /// Optional unit suffix shown on the scale bar (e.g. `"mm"`). Empty = number only.
    public var scaleBarUnitLabel: String

    /// Whether to show coordinate axes.
    public var showAxes: Bool

    /// Axis length in world units.
    public var axisLength: Float

    /// Axis radius (or base radius for screen-space style).
    public var axisRadius: Float

    /// Rendering style for coordinate axes.
    public var axisStyle: AxisStyle

    /// Whether to show ground grid.
    public var showGrid: Bool

    /// Rendering style for the ground grid.
    public var gridStyle: GridStyle

    /// Grid plane size in world units (for `.plane` style).
    public var gridSize: Float

    /// Fundamental grid unit in world units (for `.dots` style).
    public var gridBaseSpacing: Float

    /// Subdivision factor between spacing levels (for `.dots` style).
    public var gridSubdivisions: Int

    /// Background color (platform-agnostic).
    public var backgroundColor: SIMD4<Float>

    // MARK: - Anti-Aliasing

    /// MSAA sample count (1 = no MSAA, 4 = 4x MSAA). Must be 1 or 4.
    public var msaaSampleCount: Int

    // MARK: - Edge Silhouettes

    /// Whether screen-space edge silhouettes are enabled.
    public var enableSilhouettes: Bool

    /// Silhouette edge thickness (1.0 = normal, 2.0 = thick).
    public var silhouetteThickness: Float

    /// Silhouette edge darkness (0 = invisible, 1 = fully dark).
    public var silhouetteIntensity: Float

    // MARK: - Picking

    /// Configuration for GPU-accelerated picking.
    public var pickingConfiguration: PickingConfiguration

    // MARK: - Depth of Field

    /// Whether post-process depth of field is enabled.
    public var enableDepthOfField: Bool

    /// DoF aperture (smaller = shallower depth of field).
    public var dofAperture: Float

    /// DoF focal distance (0 = autofocus on selection or scene center).
    public var dofFocalDistance: Float

    /// Maximum blur radius in pixels for DoF.
    public var dofMaxBlurRadius: Float

    // MARK: - Rendering Quality

    /// Rendering quality level (tessellation, normal smoothing, mesh shaders).
    public var renderingQuality: RenderingQuality

    /// Maximum tessellation factor for hardware tessellation (1-64, default 16).
    public var tessellationMaxFactor: Int

    /// Whether tessellation adapts to screen-space edge length.
    public var adaptiveTessellation: Bool

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
        defaultFieldOfView: Float = 45,
        gestureConfiguration: GestureConfiguration = .default,
        displayMode: DisplayMode = .shaded,
        lightingConfiguration: LightingConfiguration = .threePoint,
        showViewCube: Bool = true,
        viewCubePosition: ViewCubePosition = .bottomTrailing,
        showAxes: Bool = false,
        axisLength: Float = 2.0,
        axisRadius: Float = 0.02,
        axisStyle: AxisStyle = .cylinder,
        showGrid: Bool = true,
        gridStyle: GridStyle = .plane,
        gridSize: Float = 100.0,
        gridBaseSpacing: Float = 1.0,
        gridSubdivisions: Int = 10,
        backgroundColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.95, 0.95, 1.0),
        msaaSampleCount: Int = 4,
        enableSilhouettes: Bool = true,
        silhouetteThickness: Float = 1.0,
        silhouetteIntensity: Float = 0.7,
        pickingConfiguration: PickingConfiguration = .init(),
        enableDepthOfField: Bool = false,
        dofAperture: Float = 2.8,
        dofFocalDistance: Float = 0,
        dofMaxBlurRadius: Float = 8.0,
        renderingQuality: RenderingQuality = .standard,
        tessellationMaxFactor: Int = 32,
        adaptiveTessellation: Bool = true,
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
        self.msaaSampleCount = msaaSampleCount
        self.enableSilhouettes = enableSilhouettes
        self.silhouetteThickness = silhouetteThickness
        self.silhouetteIntensity = silhouetteIntensity
        self.pickingConfiguration = pickingConfiguration
        self.enableDepthOfField = enableDepthOfField
        self.dofAperture = dofAperture
        self.dofFocalDistance = dofFocalDistance
        self.dofMaxBlurRadius = dofMaxBlurRadius
        self.renderingQuality = renderingQuality
        self.tessellationMaxFactor = tessellationMaxFactor
        self.adaptiveTessellation = adaptiveTessellation
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
}

// MARK: - ViewCube Position

/// Position of the ViewCube overlay.
public enum ViewCubePosition: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}
