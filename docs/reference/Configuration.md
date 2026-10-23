---
title: Configuration
parent: API Reference
---

# Configuration

These types control viewport appearance, rendering fidelity, and picking. `ViewportConfiguration` is the single struct passed to `ViewportController(configuration:)` that governs everything from camera limits and grid style to anti-aliasing and tessellation quality. `ClipPlane` defines section cuts. `PickingConfiguration` gates the GPU pick-ID buffer. `EdgeLineConfiguration` sets edge line width and dash pattern. The supporting enums — `RenderingQuality`, `UniformTessellationFactor`, `RenderLayer`, `AxisStyle`, `GridStyle`, and `ViewCubePosition` — are referenced by fields inside `ViewportConfiguration`.

[`GestureConfiguration`](Input.md#gestureconfiguration) and [`DynamicPivotConfiguration`](Camera.md#dynamicpivotconfiguration) are documented on the Input and Camera pages respectively — `ViewportConfiguration` embeds them by value.

## Topics

- [ViewportConfiguration](#viewportconfiguration) · [RenderingQuality](#renderingquality) · [UniformTessellationFactor](#uniformtessellationfactor-1) · [RenderLayer](#renderlayer) · [SelectionOutlineStyle](#selectionoutlinestyle) · [EdgeLineConfiguration](#edgelineconfiguration) · [EdgeLineDashPattern](#edgelinedashpattern) · [EdgeLineDashKind](#edgelinedashkind) · [AxisStyle](#axisstyle) · [GridStyle](#gridstyle) · [ViewCubePosition](#viewcubeposition) · [PickingConfiguration](#pickingconfiguration) · [ClipPlane](#clipplane)

---

## ViewportConfiguration

`ViewportConfiguration` is the master configuration value type for a viewport instance. It is `Sendable` and can be constructed with any subset of its parameters overridden; every field has a default. Pass it to `ViewportController(configuration:)`, then hand that controller to `MetalViewportView(controller:bodies:)`:

```swift
var config = ViewportConfiguration.cad
config.gridStyle = .dots
let controller = ViewportController(configuration: config)
// MetalViewportView(controller: controller, bodies: $bodies)
```

`ViewportController.configuration` is a `let`: the configuration is fixed for the controller's lifetime. The settings that can change live are mirrored as `@Published` properties on the controller (`displayMode`, `showAxes`, `showGrid`, `lightingConfiguration`, `enableTAA`, the depth-of-field values and so on); to change anything else, build a new controller.

---

### Camera fields

#### `initialCameraState`

```swift
public var initialCameraState: CameraState  // default: .isometric
```

The camera state loaded when the viewport first appears. Changing this after the viewport is created has no effect unless the host resets the camera explicitly.

---

#### `rotationStyle`

```swift
public var rotationStyle: RotationStyle  // default: .turntable
```

Controls how drag gestures orbit the camera. See [`RotationStyle`](Camera.md#rotationstyle) on the Camera page.

---

#### `minDistance`

```swift
public var minDistance: Float  // default: 0.1
```

Minimum camera-to-pivot distance in world units. Prevents the camera from passing through the orbit center when the user zooms in.

---

#### `maxDistance`

```swift
public var maxDistance: Float  // default: 10000
```

Maximum camera-to-pivot distance in world units. Caps the zoom-out range.

---

#### `defaultFieldOfView`

```swift
public var defaultFieldOfView: Float?  // default: nil (keep initialCameraState.fieldOfView)
```

Vertical field of view in degrees for the initial perspective camera. When set, `ViewportController` applies it over `initialCameraState.fieldOfView` when it is created (`effectiveInitialCameraState` returns the result). `nil` keeps the initial camera's own FOV, including a camera you assign to `initialCameraState` after creating the configuration. Either way, `reset(animated:)` returns to that FOV.

---

#### `gestureConfiguration`

```swift
public var gestureConfiguration: GestureConfiguration  // default: .default
```

Platform-specific gesture mapping. See [`GestureConfiguration`](Input.md#gestureconfiguration).

---

### Display fields

#### `displayMode`

```swift
public var displayMode: DisplayMode  // default: .shaded
```

Geometry display mode (shaded, wireframe, hidden-line, etc.). See [`DisplayMode`](Display-Lighting.md#displaymode).

---

#### `xrayOpacity`

```swift
public var xrayOpacity: Float  // default: DisplayMode.defaultXRayOpacity (0.4)
```

Opacity ceiling for surfaces in `.xray` mode, clamped to `0...1` on set (and in the initializer) by `DisplayMode.clampedXRayOpacity(_:)`. Seeds `ViewportController.xrayOpacity`, which is what the renderer reads; change that one to tune it live.

---

#### `lightingConfiguration`

```swift
public var lightingConfiguration: LightingConfiguration  // default: .threePoint
```

Lighting preset and per-light properties. See [`LightingConfiguration`](Display-Lighting.md#lightingconfiguration).

---

#### `showViewCube`

```swift
public var showViewCube: Bool  // default: true
```

Whether the 3D navigation cube overlay is visible.

---

#### `viewCubePosition`

```swift
public var viewCubePosition: ViewCubePosition  // default: .bottomTrailing
```

Corner of the viewport where the navigation cube is placed. See [`ViewCubePosition`](#viewcubeposition).

---

#### `showOrientationGnomon`

```swift
public var showOrientationGnomon: Bool  // default: false
```

Whether the screen-space orientation gnomon (corner RGB axis triad HUD) is shown.

---

#### `showScaleBar`

```swift
public var showScaleBar: Bool  // default: false
```

Whether the screen-space scale bar HUD is shown.

---

#### `scaleBarUnitLabel`

```swift
public var scaleBarUnitLabel: String  // default: ""
```

Unit suffix appended to the scale bar readout (e.g. `"mm"`). Pass an empty string for a bare number.

---

#### `showAxes`

```swift
public var showAxes: Bool  // default: false
```

Whether the world-space coordinate axes are rendered.

---

#### `axisLength`

```swift
public var axisLength: Float?  // default: nil (sized to the scene)
```

Length of each coordinate axis in world units, measured from the origin along +X (red), +Y (green) and +Z (blue). `nil` sizes the axes to the scene every frame: `max(1.5 × reach, 0.5 × diagonal)` of the visible geometry-layer bodies' world bounds, where `reach` is the bounds' largest absolute coordinate. The axes start at the origin, so this makes them poke out of a model that contains it at any scale, and keeps them a visible size beside a model that sits away from it. An empty scene gets 2 units. A value you set always wins. `OffscreenRenderer` resolves `nil` the same way from the bodies it renders.

---

#### `axisRadius`

```swift
public var axisRadius: Float?  // default: nil (automatic)
```

World-space radius of the axis cylinders for `.cylinder`; for `.constantScreenWidth`, the radius they have at the default camera's zoom (distance 10, 45° FOV), scaled with the zoom from there. `nil` picks it automatically: for `.cylinder`, 1 % of the axis length (0.02 at 2 units), so axes sized to a large scene stay proportionate instead of shrinking to a hairline; for `.constantScreenWidth`, 0.02. A value you set always wins. A 1 px centre line is always drawn as well, so an axis never disappears when its radius falls below a pixel.

---

#### `axisStyle`

```swift
public var axisStyle: AxisStyle  // default: .cylinder
```

Fixed world-space radius or constant on-screen width. See [`AxisStyle`](#axisstyle).

---

#### `showGrid`

```swift
public var showGrid: Bool  // default: true
```

Whether the ground grid is rendered. The grid lies in the XY plane at z = 0, matching the Z-up world (turntable orbit, standard views).

---

#### `gridStyle`

```swift
public var gridStyle: GridStyle  // default: .plane
```

Ground plane with grid lines, or adaptive dot grid. See [`GridStyle`](#gridstyle).

---

#### `gridSize`

```swift
public var gridSize: Float  // default: 100.0
```

Side length, in world units, of the square grid centred on the world origin (it spans `±gridSize / 2` on X and Y). Applies to both styles: no line or dot is drawn outside the square. `0`, a negative value or `.infinity` leaves the grid unbounded. Either way the grid only covers a window around the camera pivot (about ±50 spacings for `.plane`, ±15 for `.dots`) at the current spacing level.

---

#### `gridBaseSpacing`

```swift
public var gridBaseSpacing: Float  // default: 1.0
```

Fundamental grid spacing in world units (both styles). The renderer snaps to this value times a power of `gridSubdivisions` as the camera zooms.

---

#### `gridSubdivisions`

```swift
public var gridSubdivisions: Int  // default: 10
```

Factor between grid spacing levels (both styles). In the `.plane` style every `gridSubdivisions`-th line is drawn with more contrast, marking where the next-coarser level's lines fall.

---

#### `backgroundColor`

```swift
public var backgroundColor: SIMD4<Float>  // default: SIMD4<Float>(0.95, 0.95, 0.95, 1.0)
```

Viewport background color in the light appearance, as linear RGBA with premultiplied-alpha conventions. The default is a near-white light grey. In the dark appearance `darkModeBackgroundColor` replaces it, unless that is `nil`.

---

#### `darkModeBackgroundColor`

```swift
public var darkModeBackgroundColor: SIMD4<Float>?  // default: ViewportConfiguration.defaultDarkModeBackgroundColor
```

Background colour used in the dark appearance. Following dark mode is on by default, with `defaultDarkModeBackgroundColor`, a near-black grey `(0.12, 0.12, 0.12, 1)`.

- **Follow dark mode with your own colour:** set this to it.
- **Opt out:** set it to `nil`, and `backgroundColor` applies in both appearances.
- **Force an appearance:** `MetalViewportView` follows the SwiftUI colour scheme of its environment, so `.preferredColorScheme(.light)` or `.environment(\.colorScheme, .dark)` on the view (or an ancestor) pins it.

`resolvedBackgroundColor(isDark:)` returns the colour in effect for an appearance. Headless renders follow the system appearance by default too, through `OffscreenRenderOptions.appearance` (pin `.light`/`.dark` for reproducible output); see [Rendering](Rendering.md#offscreenrenderoptions).

Up to v1.2.3 the dark colour was hard-coded and replaced even a custom `backgroundColor`; it is now this configurable field.

---

### Anti-aliasing

#### `msaaSampleCount`

```swift
public var msaaSampleCount: Int  // default: 4
```

Requested Metal MSAA sample count for the main color/depth attachments: `1` for no MSAA, `4` (the default) for 4× MSAA. The renderer clamps the request to a count the device supports — values below `2` mean no MSAA, otherwise the largest of 8, 4 and 2 that does not exceed the request and that `MTLDevice.supportsTextureSampleCount(_:)` accepts, falling back to `1` — so an unsupported value degrades instead of failing renderer creation. `OffscreenRenderOptions.msaaSampleCount` uses the same mapping. Use `1` in the `.performance` preset to reclaim fillrate on mobile.

---

#### `preferredFramesPerSecond`

```swift
public var preferredFramesPerSecond: Int  // default: 120
```

Frame rate the viewport asks for. `MTKView` picks the supported display rate closest to it, so the default runs at 120 Hz on ProMotion displays and 60 Hz on 60 Hz ones. The camera's animation and inertia timer runs at the same rate. Set `60` to cap the rate and save power. It is not an `init` parameter; set it on the value before creating the `ViewportController`. On iPhone, rates above 60 also need `CADisableMinimumFrameDurationOnPhone` set to `YES` in the app's Info.plist.

```swift
var config = ViewportConfiguration.cad
config.preferredFramesPerSecond = 60
let controller = ViewportController(configuration: config)
```

Earlier releases hard-coded 60 FPS for both the view and the camera timer.

---

#### `enableTAA`

```swift
public var enableTAA: Bool  // default: false
```

Whether temporal anti-aliasing is composited over the rendered frame.

---

#### `taaBlendFactor`

```swift
public var taaBlendFactor: Float  // default: 0.9
```

History blend weight for TAA. `0.0` = no history (effectively disables TAA), `1.0` = full history (maximum smoothing, but ghosting on fast camera moves). Meaningful only when `enableTAA == true`.

---

### Silhouettes

#### `enableSilhouettes`

```swift
public var enableSilhouettes: Bool  // default: true
```

Whether a screen-space edge-darkening silhouette pass is applied after geometry rendering. The pass (and SSAO) reads a depth prepass of opaque geometry-layer bodies only: translucent bodies, `RenderLayer.overlay` bodies (manipulators, gizmos) and point clouds get no silhouette or ambient occlusion.

---

#### `silhouetteThickness`

```swift
public var silhouetteThickness: Float  // default: 1.0
```

Edge thickness multiplier. `1.0` = normal, `2.0` = twice as thick.

---

#### `silhouetteIntensity`

```swift
public var silhouetteIntensity: Float  // default: 0.7
```

Darkness of detected edges. `0.0` = invisible (silhouette pass does nothing), `1.0` = fully darkened.

---

### Selection outline

#### `selectionOutline`

```swift
public var selectionOutline: SelectionOutlineStyle  // default: .selection
```

Colour and width of the outline ring drawn around bodies in `ViewportController.selectedBodyIDs`. The width is in drawable pixels, so the ring looks the same on a millimetre-scale part and a building. Set `width` to `0` to hide it. Not an `init` parameter; assign it on the value. See [`SelectionOutlineStyle`](#selectionoutlinestyle).

```swift
var config = ViewportConfiguration.cad
config.selectionOutline = SelectionOutlineStyle(color: SIMD3(1.0, 0.6, 0.1), width: 4)
```

---

#### `hoverOutline`

```swift
public var hoverOutline: SelectionOutlineStyle  // default: .hover
```

Outline for `ViewportController.hoveredBodyID` when that body is not also selected. Not an `init` parameter.

---

### Edge lines

#### `edgeLineConfiguration`

```swift
public var edgeLineConfiguration: EdgeLineConfiguration  // default: .default
```

Width and dash pattern for body edge polylines (wireframe, shaded-with-edges and x-ray modes). See [`EdgeLineConfiguration`](#edgelineconfiguration).

**Example — thick dashed edges:**

```swift
var config = ViewportConfiguration.cad
config.edgeLineConfiguration = EdgeLineConfiguration(width: 2.5, dashPattern: .dashed)
```

---

### Frustum culling

#### `enableFrustumCulling`

```swift
public var enableFrustumCulling: Bool  // default: true
```

When `true`, bodies whose world-space bounding box falls entirely outside the camera frustum are skipped during draw encoding. Bodies with no `boundingBox` are never culled. The shadow map pass is exempt (off-screen casters can shadow visible geometry).

**Example — disable for debugging:**

```swift
var config = ViewportConfiguration.cad
config.enableFrustumCulling = false
```

---

### Normal smoothing

#### `autoSmoothNormals`

```swift
public var autoSmoothNormals: Bool  // default: false
```

When `true`, crease-aware normal smoothing is applied to each body's mesh when its GPU buffers are first built. Flat-shaded meshes (per-face normals from some tessellators) cannot be rounded by Phong tessellation alone; this averages normals across shared vertices while preserving hard edges. Computed once per body and cached; the smoothed data feeds the standard, tessellated (`.enhanced`) and mesh-shader (`.maximum`) paths alike, since all three read the same vertex buffer. Direct-mesh bodies are not smoothed (their producer supplies the normals). Enabled by the `.cadHighQuality` preset.

---

#### `normalSmoothingCreaseAngle`

```swift
public var normalSmoothingCreaseAngle: Float  // default: 0.524  (~30°, in radians)
```

Crease angle threshold for `autoSmoothNormals`. Adjacent face normals that differ by more than this angle are treated as a hard edge and kept sharp. Only meaningful when `autoSmoothNormals == true`.

---

### Picking

#### `pickingConfiguration`

```swift
public var pickingConfiguration: PickingConfiguration  // default: .init()
```

Governs whether the GPU pick-ID texture is allocated and written. See [`PickingConfiguration`](#pickingconfiguration).

---

### Depth of field

#### `enableDepthOfField`

```swift
public var enableDepthOfField: Bool  // default: false
```

Whether a post-process depth-of-field blur is applied.

---

#### `dofAperture`

```swift
public var dofAperture: Float  // default: 2.8
```

Simulated f-number. Smaller values produce a shallower (stronger) blur.

---

#### `dofFocalDistance`

```swift
public var dofFocalDistance: Float  // default: 0
```

Focus distance in world units from the camera. `0` activates autofocus on the scene centre: the mean of the visible geometry-layer bodies' world-space bounding-box centres (each body's `transform` applied).

---

#### `dofMaxBlurRadius`

```swift
public var dofMaxBlurRadius: Float  // default: 8.0
```

Maximum circle-of-confusion radius in pixels. Clamps the blur on very out-of-focus regions.

---

### Rendering quality

#### `renderingQuality`

```swift
public var renderingQuality: RenderingQuality  // default: .standard
```

Controls tessellation tier and mesh-shader usage. See [`RenderingQuality`](#renderingquality).

---

#### `tessellationMaxFactor`

```swift
public var tessellationMaxFactor: Int  // default: 32
```

Maximum hardware tessellation factor per edge. Only used when `renderingQuality == .enhanced` or `.maximum`. The `.cadHighQuality` preset raises this to 48.

Metal caps the factor at 64, and the fractional-even partitioning the tessellated pipelines use needs an even value. An out-of-range or odd value used to make pipeline creation fail, silently disabling tessellation; the renderer now clamps it to `2...64` and rounds an odd value up to the next even one. The pipelines are built with the value in effect when the renderer is created, so raising it later is capped to that value.

---

#### `adaptiveTessellation`

```swift
public var adaptiveTessellation: Bool  // default: true
```

When `true`, the tessellation level adapts per edge to the projected screen-space length (target about 4 px per tessellated edge) and surface curvature, concentrating triangles where the mesh is coarse relative to the viewport, capped at `tessellationMaxFactor`. Projection uses each body's `transform`, so moved and scaled bodies get the right factors.

When `false`, every patch is tessellated uniformly, whatever its size on screen, at the factor [`uniformTessellationFactor`](#uniformtessellationfactor) chooses. A uniform factor `f` costs roughly `f²` triangles per input triangle. Requires `renderingQuality != .standard`.

---

#### `uniformTessellationFactor`

```swift
public var uniformTessellationFactor: UniformTessellationFactor  // default: .loadAdaptive()
```

The factor used when `adaptiveTessellation == false`. See [`UniformTessellationFactor`](#uniformtessellationfactor-1).

---

### Dynamic pivot

#### `dynamicPivotConfiguration`

```swift
public var dynamicPivotConfiguration: DynamicPivotConfiguration  // default: .default
```

Configuration for the automatic orbit-pivot heuristic that shifts the orbit center from the scene centroid to the surface under the cursor as the user zooms in. See [`DynamicPivotConfiguration`](Camera.md#dynamicpivotconfiguration).

---

### `init(...)`

```swift
public init(
    initialCameraState: CameraState = .isometric,
    rotationStyle: RotationStyle = .turntable,
    minDistance: Float = 0.1,
    maxDistance: Float = 10000,
    defaultFieldOfView: Float? = nil,  // nil → keep initialCameraState.fieldOfView
    gestureConfiguration: GestureConfiguration = .default,
    displayMode: DisplayMode = .shaded,
    xrayOpacity: Float = DisplayMode.defaultXRayOpacity,
    lightingConfiguration: LightingConfiguration = .threePoint,
    showViewCube: Bool = true,
    viewCubePosition: ViewCubePosition = .bottomTrailing,
    showAxes: Bool = false,
    axisLength: Float? = nil,  // nil → sized to the scene
    axisRadius: Float? = nil,  // nil → automatic
    axisStyle: AxisStyle = .cylinder,
    showGrid: Bool = true,
    gridStyle: GridStyle = .plane,
    gridSize: Float = 100.0,
    gridBaseSpacing: Float = 1.0,
    gridSubdivisions: Int = 10,
    backgroundColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.95, 0.95, 1.0),
    darkModeBackgroundColor: SIMD4<Float>? = ViewportConfiguration.defaultDarkModeBackgroundColor,
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
)
```

All parameters are optional; omit any to accept its default. Construct a preset and then mutate individual fields for targeted changes.

**Example — start from `.cad`, enable scale bar and millimetre label:**

```swift
var config = ViewportConfiguration.cad
config.showScaleBar = true
config.scaleBarUnitLabel = "mm"
```

---

### Presets

#### `.cad`

```swift
public static let cad: ViewportConfiguration
```

Turntable orbit, ViewCube on, axes on, grid on. All other fields at defaults.

---

#### `.modelViewer`

```swift
public static let modelViewer: ViewportConfiguration
```

Arcball orbit, ViewCube off, axes off, grid off. Suited to 3D model inspection without engineering overlays.

---

#### `.architectural`

```swift
public static let architectural: ViewportConfiguration
```

Turntable orbit, shaded mode, `.architectural` lighting preset, ViewCube on, grid on, camera pre-positioned at an isometric-front-right view at distance 50.

---

#### `.performance`

```swift
public static let performance: ViewportConfiguration
```

Turntable orbit, shadows disabled, SSAO disabled, MSAA disabled (`msaaSampleCount = 1`), silhouettes disabled, `renderingQuality = .standard`. Use on dense many-body scenes (thousands of bodies / hundreds of thousands of triangles) on iPhone or iPad where per-frame whole-scene passes dominate render time.

**Example:**

```swift
MetalViewportView(
    bodies: heavyScene,
    configuration: .performance
)
```

---

#### `.cadHighQuality`

```swift
public static let cadHighQuality: ViewportConfiguration
```

Turntable orbit, ViewCube on, axes on, grid on, `autoSmoothNormals = true`, `renderingQuality = .enhanced`, `tessellationMaxFactor = 48`, `adaptiveTessellation = true`. Enables GPU PN-triangle Phong tessellation so cylinder and fillet silhouettes stay smooth at any zoom. Requires an Apple3+ GPU; falls back to un-tessellated rendering on older hardware.

---

## RenderingQuality

```swift
public enum RenderingQuality: Sendable {
    case standard
    case enhanced
    case maximum
}
```

Controls the tessellation tier used by `ViewportRenderer`.

| Case | Description |
|---|---|
| `.standard` | Finer CPU-side tessellation combined with crease-aware normal smoothing. No GPU hardware tessellation. Runs on all supported hardware. |
| `.enhanced` | Everything in `.standard`, plus GPU hardware tessellation using PN triangles (Phong tessellation). Requires an Apple3+ GPU; silently falls back to `.standard` on earlier hardware. |
| `.maximum` | Everything in `.enhanced`, plus mesh shaders with per-meshlet culling. Requires Apple9+ / M3+; falls back to `.enhanced` when unavailable. |

**Example — upgrade quality on a known capable device:**

```swift
if config.renderingQuality == .standard {
    config.renderingQuality = .enhanced
    config.tessellationMaxFactor = 32
    config.adaptiveTessellation = true
}
```

---

## UniformTessellationFactor

```swift
public enum UniformTessellationFactor: Sendable, Equatable {
    case loadAdaptive(minimum: Int = 4)
    case fixed(Int)
}
```

How the uniform tessellation factor is chosen when `adaptiveTessellation == false`.

| Case | Description |
|---|---|
| `.loadAdaptive(minimum:)` | Default. The live renderer scales the factor between `minimum` and `tessellationMaxFactor` to fit system load. It starts at the maximum. When the smoothed GPU frame time (measured from each frame's command buffer) rises above 85% of the frame budget (`1 / preferredFramesPerSecond`, or 1/60), it lowers the factor by 20%. Below 55% it raises the factor by 2. Between the two it holds, and after any change it holds for 30 frames, so the factor never oscillates frame to frame. Thermal state caps the ceiling: `.fair` to 75% of the maximum, `.serious` to 50%, `.critical` to `minimum`. Low Power Mode halves it. A lowered cap applies at once. |
| `.fixed(_:)` | Always tessellate at this factor, clamped to `1...tessellationMaxFactor`. |

Off-screen renders (`renderHeadless(...)`) never adapt to load: `.loadAdaptive` uses `tessellationMaxFactor` there, so the output is deterministic.

```swift
var config = ViewportConfiguration.cadHighQuality
config.adaptiveTessellation = false
config.uniformTessellationFactor = .loadAdaptive(minimum: 8)  // or .fixed(12) to pin it
```

---

## RenderLayer

```swift
public enum RenderLayer: Hashable, Sendable {
    case geometry
    case overlay
}
```

Controls when in the render order a `ViewportBody` is drawn.

| Case | Behaviour |
|---|---|
| `.geometry` | Drawn in the normal geometry pass with standard depth testing. |
| `.overlay` | Drawn after the selection-outline pass using an always-pass depth state, so the body is visible even when behind other geometry. Overlay bodies get no selection or hover outline (and no per-triangle highlight). Use for manipulator widgets and similar always-on-top affordances. |

Set on `ViewportBody.renderLayer`. See [`ViewportBody`](ViewportBody.md) for the full body API.

**Example:**

```swift
var gizmo = ViewportBody(/* … */)
gizmo.renderLayer = .overlay  // always visible, never occluded
```

---

## SelectionOutlineStyle

```swift
public struct SelectionOutlineStyle: Sendable, Hashable
```

Colour and width of the outline ring the live renderer draws around a selected or hovered body. Used by `ViewportConfiguration.selectionOutline` and `.hoverOutline`. The ring is drawn by pushing the body's vertices outward along their screen-space normals by `width` pixels, outside the body's stencil footprint, so it stays the same thickness at any zoom and model scale.

| Property | Type | Default | Description |
|---|---|---|---|
| `color` | `SIMD3<Float>` | — | Outline colour, linear RGB. |
| `width` | `Float` | `3.0` | Outline width in drawable pixels. `0` hides the outline. |

| Preset | Colour | Width |
|---|---|---|
| `.selection` | `(0.1, 0.5, 1.0)` bright blue | 3 px |
| `.hover` | `(0.4, 0.7, 1.0)` light blue | 3 px |

The faint blue tint the shaded pass mixes into selected (15 %) and hovered (8 %) bodies is separate and fixed.

---

## EdgeLineConfiguration

```swift
public struct EdgeLineConfiguration: Sendable
```

Controls how body edges are drawn: polyline `edges`, analytic `arcs` (sampled each frame, with the dash pattern running continuously round the arc) and the edges of `RenderLayer.overlay` bodies. With `useQuadExpansion` on (the default), each edge segment is expanded into a screen-aligned quad, which is what makes widths other than 1 px and dash patterns possible. Width is constant in screen space regardless of camera distance. Both `ViewportRenderer` (via `ViewportConfiguration.edgeLineConfiguration`) and `OffscreenRenderer` (via `OffscreenRenderOptions.edgeLineConfiguration`) honour it. `OffscreenRenderer` does not draw `arcs`.

Quad edges are shaded like native ones: `ViewportController.edgeIntensity` (or `OffscreenRenderOptions.edgeIntensity`) dims and depth-fades them (the fade is linear in view distance from the near to the far clip plane), and they are depth-biased toward the viewer so an edge lying on a face is not lost to it. The bias grows with the line width: each edge vertex is pulled toward the viewer by twice (half the width + 1 px), measured as world distance per pixel at its depth, so a wide edge keeps its full width on faces tilted up to about 63° from the view plane. Only a face less than that distance in front of an edge can let it show through.

Native edges (`useQuadExpansion` off) are biased the same way, by a fixed 0.6% of the NDC height (about 3 px at 1000 px tall) in world units at each vertex's depth, because the shader has no viewport size. Neither path uses a constant NDC depth offset, whose world-space size depends on the near/far range: under a wide range it let hidden back edges show through faces (issue #157). Neither bias can push an edge past the near plane.

With `PickingConfiguration.isEnabled`, edge and arc picks cover the same width as the drawn edge (at least 1 pt), so a wide edge is clickable across its whole width. Dash gaps are pickable too. See [Picking](Picking.md#pick-footprints).

| Property | Type | Default | Notes |
|---|---|---|---|
| `width` | `Float` | `1.0` | Line width in pixels. |
| `dashPattern` | `EdgeLineDashPattern` | `.solid` | See [`EdgeLineDashPattern`](#edgelinedashpattern). |
| `useQuadExpansion` | `Bool` | `true` | `false` falls back to native 1 px Metal lines; `width` and `dashPattern` are then ignored. |

```swift
public init(
    width: Float = 1.0,
    dashPattern: EdgeLineDashPattern = .solid,
    useQuadExpansion: Bool = true
)
```

| Preset | Value |
|---|---|
| `.default` | 1 px solid |
| `.bold` | 3 px solid |
| `.dashed` | 1 px, `EdgeLineDashPattern.dashed` |

Edge-only bodies (wires, sketches, sampled curves) take the body colour directly rather than the contrast-adaptive edge colour, and are dashed like any other edge. Dash patterns need `useQuadExpansion`: with it off, every edge draws as a solid 1 px line.

---

## EdgeLineDashPattern

```swift
public struct EdgeLineDashPattern: Sendable, Hashable
```

A dash pattern measured along each edge polyline in **world units** (the cumulative arc length of the polyline, starting at its first point). Because lengths are in world units, the dashes scale on screen with zoom.

| Property | Type | Notes |
|---|---|---|
| `kind` | `EdgeLineDashKind` | Pattern kind. |
| `dashLength` | `Float` | Length of each dash. |
| `gapLength` | `Float` | Length of each gap. |
| `dotLength` | `Float` | Length of the dot in `.dashDot`. Unused by other kinds. |
| `phase` | `Float` | Offset added to the arc length before the pattern is applied. |

```swift
// kind is inferred: .dashed when dashLength > 0, otherwise .solid
public init(dashLength: Float = 0, gapLength: Float = 0, dotLength: Float = 2, phase: Float = 0)

public init(kind: EdgeLineDashKind, dashLength: Float, gapLength: Float, dotLength: Float = 2, phase: Float = 0)
```

| Preset | Kind | dash / gap / dot |
|---|---|---|
| `.solid` | `.solid` | — |
| `.dashed` | `.dashed` | 10 / 5 / — |
| `.dotted` | `.dotted` | 2 / 3 / — (very short square-ended dashes; round dots are not supported) |
| `.dashDot` | `.dashDot` | 8 / 3 / 2 |

Pick lengths relative to your model's scale: the presets suit models a few hundred units across.

**Example — dashes sized for a 50 mm part:**

```swift
let pattern = EdgeLineDashPattern(kind: .dashed, dashLength: 2, gapLength: 1)
config.edgeLineConfiguration = EdgeLineConfiguration(width: 1.5, dashPattern: pattern)
```

---

## EdgeLineDashKind

```swift
public enum EdgeLineDashKind: UInt32, Sendable, Hashable {
    case solid
    case dashed
    case dotted
    case dashDot
}
```

The pattern kind of an [`EdgeLineDashPattern`](#edgelinedashpattern). `.dotted` is drawn with the same dash/gap logic as `.dashed`; `.dashDot` alternates dash, gap, dot, gap.

---

## AxisStyle

```swift
public enum AxisStyle: Sendable {
    case cylinder
    case constantScreenWidth
}
```

Rendering style for the world-space coordinate axes. Each axis is an unlit cylinder `axisLength` long from the origin (X red, Y green, Z blue) over a 1 px centre line.

| Case | Behaviour |
|---|---|
| `.cylinder` | Axis cylinders have a fixed world-space radius (`axisRadius`; automatically 1 % of the axis length). They appear thinner on screen as the camera zooms out, down to the 1 px centre line. Default. |
| `.constantScreenWidth` | The radius scales with the view's visible height at the pivot (camera distance and FOV in perspective, `orthographicScale` in orthographic), so the axes keep the on-screen width `axisRadius` gives at the default camera (distance 10, 45° FOV). The width is exact at the pivot's depth; nearer and farther parts of an axis still follow perspective. |

---

## GridStyle

```swift
public enum GridStyle: Sendable {
    case plane
    case dots
}
```

Rendering style for the ground grid.

| Case | Behaviour |
|---|---|
| `.plane` | Ground plane: a faint translucent fill (depth-tested but not depth-writing, so it only tints what lies behind it) under 1 px grid lines, every `gridSubdivisions`-th line with more contrast. Default. |
| `.dots` | Instanced adaptive dot grid. |

Both styles lie in the XY plane at z = 0 (drawn 0.01 below it so faces resting on the ground win the depth test), use spacing `gridBaseSpacing × gridSubdivisionsⁿ` chosen for the current zoom, centre on the camera pivot, and stop at the `gridSize` square around the origin. Line and dot colours are derived from the background the frame clears to (mixed toward black over a light background, toward white over a dark one), so the grid keeps the same modest contrast in light and dark appearance. Up to v1.2.3 the dot grid was drawn in the XZ plane, standing vertical in the Z-up world, and the `.plane` style, `gridStyle` and `gridSize` were ignored.

---

## ViewCubePosition

```swift
public enum ViewCubePosition: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}
```

Corner of the viewport that hosts the navigation cube overlay. Assigned to `ViewportConfiguration.viewCubePosition` (default `.bottomTrailing`).

**Example — move cube to top-right:**

```swift
var config = ViewportConfiguration.cad
config.viewCubePosition = .topTrailing
```

---

## PickingConfiguration

`PickingConfiguration` controls whether the GPU-accelerated pick-ID texture is allocated and written each frame. When disabled, the second color attachment is not used and no GPU picking results are produced; `ViewportController.pickResult` will never fire.

---

### `isEnabled`

```swift
public var isEnabled: Bool  // default: false
```

When `false`, the pick texture is not allocated and no pick-ID pass is rendered. Set to `true` to enable tap/click picking via `ViewportController.pickResult` or `ViewportController.widgetPickResult`.

---

### `pickRadius`

```swift
public var pickRadius: Int  // default: 0
```

Pick tolerance in pixels for a point pick. At `0` the pick reads the single pixel under the cursor. Above `0` it reads the `(2 * pickRadius + 1)²` square around it and returns the best hit: a vertex beats an edge, an edge beats a face, and among hits of the same kind the one nearest the cursor wins. Background pixels are ignored, so a click just beside a thin edge still lands on it.

Values are clamped to `0...32`, both in the initializer and when the pick runs, to bound GPU readback size. 2–4 px suits CAD interaction. Region picks (`performRegionPick`) are unaffected.

---

### `init(isEnabled:pickRadius:)`

```swift
public init(isEnabled: Bool = false, pickRadius: Int = 0)
```

Creates a picking configuration.

**Example — enable picking with a 3 px tolerance for edges and vertices:**

```swift
var config = ViewportConfiguration.cad
config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: 3)
```

---

## ClipPlane

`ClipPlane` defines a half-space clipping plane for section views. It is a `Sendable`, `Equatable` value type. Fragments where `dot(normal, point) + distance < 0` are discarded by the Metal shader. Pass clip planes to `ViewportController.clipPlanes` to activate them.

Every pass that draws scene geometry honours the planes: shaded surfaces, edges, arcs, highlights, point clouds, the selection outline, the SSAO/silhouette depth prepass, the shadow map and the GPU pick pass, so clipped geometry is neither visible nor pickable and casts no shadow. Under MSAA the clip test uses a centroid-sampled world position, so partly covered pixels at a cut do not keep samples of the removed part. CPU `SceneRaycast` skips clipped hits when given the planes (`clipPlanes:`), which the dynamic pivot does. `OffscreenRenderer` does not apply clip planes.

**Limit:** the renderer applies at most `ClipPlane.maxActivePlanes` (4) enabled planes at once, taken in array order. Enabled planes past the fourth are not applied, and debug builds log a warning when `ViewportController.clipPlanes` is set with more. Disabled planes don't count.

The plane equation is:

```
dot(normal, P) + distance = 0
```

Points on the normal side (positive half-space) are kept; points on the opposite side are clipped.

---

### `maxActivePlanes`

```swift
public static let maxActivePlanes: Int  // 4
```

Maximum number of enabled clip planes the renderer applies at once. The shader uniform holds four planes.

---

### `normal`

```swift
public var normal: SIMD3<Float>
```

Outward-facing unit normal of the clip plane. The initializer normalizes the input automatically. Fragments are discarded when they fall on the opposite side from the normal.

---

### `distance`

```swift
public var distance: Float
```

Signed distance from the world origin along the normal. Positive values shift the clipping boundary away from the origin in the normal direction; negative values shift it toward the origin.

**Example — clip at Y = 5 (keep Y > 5):**

```swift
// dot((0,1,0), P) + (-5) = 0  →  plane at Y=5
let plane = ClipPlane(normal: SIMD3(0, 1, 0), distance: -5)
```

---

### `isEnabled`

```swift
public var isEnabled: Bool
```

Whether this plane is active. A disabled plane in the `clipPlanes` array is ignored by the renderer without requiring removal from the array.

---

### `init(normal:distance:isEnabled:)`

```swift
public init(
    normal: SIMD3<Float> = SIMD3(0, 1, 0),
    distance: Float = 0,
    isEnabled: Bool = true
)
```

Creates a clip plane. The `normal` is normalized at init time.

- `normal`: Outward-facing normal (default: Y-up, clips below the ground plane).
- `distance`: Signed distance from origin along the normal (default: `0`).
- `isEnabled`: Whether the plane is active immediately (default: `true`).

**Example — section cut at X = 2 (keep X > 2):**

```swift
let plane = ClipPlane(normal: SIMD3(1, 0, 0), distance: -2)
```

---

### `asFloat4`

```swift
public var asFloat4: SIMD4<Float> { get }
```

The plane equation packed as `(normal.x, normal.y, normal.z, distance)` for direct upload to a Metal uniform buffer.

**Example:**

```swift
uniforms.clipPlane = plane.asFloat4
```

---

### Presets

#### `.groundPlane`

```swift
public static let groundPlane: ClipPlane
```

Ground plane of the Z-up world: discards all geometry below Z = 0 (the same plane as `.zPlane`). Up to v1.2.3 this cut at Y = 0; use `.yPlane` for that.

#### `.yPlane`

```swift
public static let yPlane: ClipPlane
```

Y plane at the origin — discards geometry on the negative-Y side.

#### `.xPlane`

```swift
public static let xPlane: ClipPlane
```

X-right plane at the origin — discards geometry on the negative-X side.

#### `.zPlane`

```swift
public static let zPlane: ClipPlane
```

Z-forward plane at the origin — discards geometry on the negative-Z side.

**Example — combine two planes for a quadrant section view:**

```swift
controller.clipPlanes = [
    ClipPlane(normal: SIMD3(1, 0, 0), distance: 0),   // keep X ≥ 0
    ClipPlane(normal: SIMD3(0, 0, 1), distance: 0),   // keep Z ≥ 0
]
```
