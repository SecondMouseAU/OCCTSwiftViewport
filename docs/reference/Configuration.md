---
title: Configuration
parent: API Reference
---

# Configuration

These types control viewport appearance, rendering fidelity, and picking. `ViewportConfiguration` is the single struct passed to `MetalViewportView` (or mutated on `ViewportController.configuration`) that governs everything from camera limits and grid style to anti-aliasing and tessellation quality. `ClipPlane` defines section cuts. `PickingConfiguration` gates the GPU pick-ID buffer. `EdgeLineConfiguration` sets edge line width and dash pattern. The supporting enums — `RenderingQuality`, `RenderLayer`, `AxisStyle`, `GridStyle`, and `ViewCubePosition` — are referenced by fields inside `ViewportConfiguration`.

[`GestureConfiguration`](Input.md#gestureconfiguration) and [`DynamicPivotConfiguration`](Camera.md#dynamicpivotconfiguration) are documented on the Input and Camera pages respectively — `ViewportConfiguration` embeds them by value.

## Topics

- [ViewportConfiguration](#viewportconfiguration) · [RenderingQuality](#renderingquality) · [RenderLayer](#renderlayer) · [EdgeLineConfiguration](#edgelineconfiguration) · [EdgeLineDashPattern](#edgelinedashpattern) · [EdgeLineDashKind](#edgelinedashkind) · [AxisStyle](#axisstyle) · [GridStyle](#gridstyle) · [ViewCubePosition](#viewcubeposition) · [PickingConfiguration](#pickingconfiguration) · [ClipPlane](#clipplane)

---

## ViewportConfiguration

`ViewportConfiguration` is the master configuration value type for a viewport instance. It is `Sendable` and can be constructed with any subset of its parameters overridden; every field has a default. Pass it to `MetalViewportView(configuration:)` or set `ViewportController.configuration` at runtime to apply changes.

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
public var defaultFieldOfView: Float  // default: 45
```

Vertical field of view in degrees for the initial perspective projection.

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
public var axisLength: Float  // default: 2.0
```

Length of the coordinate axis cylinders in world units.

---

#### `axisRadius`

```swift
public var axisRadius: Float  // default: 0.02
```

Radius of the axis cylinders (or base radius when `axisStyle == .constantScreenWidth`).

---

#### `axisStyle`

```swift
public var axisStyle: AxisStyle  // default: .cylinder
```

Whether axis cylinders scale with camera distance to maintain constant on-screen width. See [`AxisStyle`](#axisstyle).

---

#### `showGrid`

```swift
public var showGrid: Bool  // default: true
```

Whether the ground grid is rendered.

---

#### `gridStyle`

```swift
public var gridStyle: GridStyle  // default: .plane
```

Solid plane or adaptive dot grid. See [`GridStyle`](#gridstyle).

---

#### `gridSize`

```swift
public var gridSize: Float  // default: 100.0
```

Half-extent of the grid plane in world units (`.plane` style only).

---

#### `gridBaseSpacing`

```swift
public var gridBaseSpacing: Float  // default: 1.0
```

Fundamental grid spacing in world units (`.dots` style). The renderer snaps to multiples of this value as the camera zooms.

---

#### `gridSubdivisions`

```swift
public var gridSubdivisions: Int  // default: 10
```

Number of subdivisions between major grid levels (`.dots` style).

---

#### `backgroundColor`

```swift
public var backgroundColor: SIMD4<Float>  // default: SIMD4<Float>(0.95, 0.95, 0.95, 1.0)
```

Viewport background color as linear RGBA with premultiplied-alpha conventions. The default is a near-white light grey.

---

### Anti-aliasing

#### `msaaSampleCount`

```swift
public var msaaSampleCount: Int  // default: 4
```

Metal MSAA sample count for the main color/depth attachments. Must be `1` (no MSAA) or `4` (4× MSAA). Use `1` in the `.performance` preset to reclaim fillrate on mobile.

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

Whether a screen-space edge-darkening silhouette pass is applied after geometry rendering.

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

When `true`, crease-aware normal smoothing is applied to each body's mesh when its GPU buffers are first built. Flat-shaded meshes (per-face normals from some tessellators) cannot be rounded by Phong tessellation alone; this averages normals across shared vertices while preserving hard edges. Computed once per body and cached. Enabled by the `.cadHighQuality` preset.

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

Focus distance in world units from the camera. `0` activates autofocus, centering focus on the selection or scene center.

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

Maximum hardware tessellation factor per edge (1–64). Only used when `renderingQuality == .enhanced` or `.maximum`. The `.cadHighQuality` preset raises this to 48.

---

#### `adaptiveTessellation`

```swift
public var adaptiveTessellation: Bool  // default: true
```

When `true`, the tessellation level adapts per edge to the projected screen-space length and surface curvature, concentrating triangles where the mesh is coarse relative to the viewport. Requires `renderingQuality != .standard`.

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
| `.overlay` | Drawn after the selection-outline pass using an always-pass depth state, so the body is visible even when behind other geometry. Use for manipulator widgets and similar always-on-top affordances. |

Set on `ViewportBody.renderLayer`. See [`ViewportBody`](ViewportBody.md) for the full body API.

**Example:**

```swift
var gizmo = ViewportBody(/* … */)
gizmo.renderLayer = .overlay  // always visible, never occluded
```

---

## EdgeLineConfiguration

```swift
public struct EdgeLineConfiguration: Sendable
```

Controls how body edges are drawn: polyline `edges`, analytic `arcs` (sampled each frame, with the dash pattern running continuously round the arc) and the edges of `RenderLayer.overlay` bodies. With `useQuadExpansion` on (the default), each edge segment is expanded into a screen-aligned quad, which is what makes widths other than 1 px and dash patterns possible. Width is constant in screen space regardless of camera distance. Both `ViewportRenderer` (via `ViewportConfiguration.edgeLineConfiguration`) and `OffscreenRenderer` (via `OffscreenRenderOptions.edgeLineConfiguration`) honour it. `OffscreenRenderer` does not draw `arcs`.

Quad edges are shaded like native ones: `ViewportController.edgeIntensity` (or `OffscreenRenderOptions.edgeIntensity`) dims and depth-fades them, and they are depth-biased toward the viewer so an edge lying on a face is not lost to it. The bias grows with the line width: each edge vertex is pulled toward the viewer by twice (half the width + 1 px), measured as world distance per pixel at its depth, so a wide edge keeps its full width on faces tilted up to about 63° from the view plane. Only a face less than that distance in front of an edge can let it show through.

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

Rendering style for the world-space coordinate axes.

| Case | Behaviour |
|---|---|
| `.cylinder` | Axis cylinders have a fixed world-space radius (`axisRadius`). They appear thinner on screen as the camera zooms out. Default. |
| `.constantScreenWidth` | Cylinder radius auto-scales with camera distance so the axes maintain a constant on-screen width. Useful when axes must remain readable across a wide zoom range. |

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
| `.plane` | Solid infinite grid plane. `gridSize` controls how many world units the plane extends. Default. |
| `.dots` | Instanced adaptive dot grid. The renderer snaps the dot spacing to powers of `gridSubdivisions × gridBaseSpacing` so the grid always shows a readable density regardless of zoom level. |

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

Every pass that draws scene geometry honours the planes: shaded surfaces, edges, arcs, highlights, point clouds, the selection outline, the SSAO/silhouette depth prepass and the GPU pick pass, so clipped geometry is neither visible nor pickable. The shadow map, CPU `SceneRaycast` and `OffscreenRenderer` do not apply clip planes.

The plane equation is:

```
dot(normal, P) + distance = 0
```

Points on the normal side (positive half-space) are kept; points on the opposite side are clipped.

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

Y-up plane at the origin — discards all geometry below Y = 0.

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
