---
title: Rendering
parent: API Reference
---

# Rendering

These types form the rendering layer of OCCTSwiftViewport. `ViewportRenderer` is the live Metal render loop that drives an `MTKView`; `OffscreenRenderer` is a headless variant that produces `CGImage` and PNG output without any window or view. Supporting types — `OffscreenRenderOptions`, `OffscreenRenderError`, `OrthoBounds`, and `DisplayMode` — configure both renderers.

## Topics

- [DisplayMode](#displaymode) · [OrthoBounds](#orthobounds) · [OffscreenRenderOptions](#offscreenrenderoptions) · [OffscreenRenderError](#offscreenrendererror) · [OffscreenRenderer](#offscreenrenderer) · [ViewportRenderer](#viewportrenderer)

---

## DisplayMode

```swift
public enum DisplayMode: String, CaseIterable, Sendable
```

Controls how geometry is drawn in the viewport or an offscreen render.

### Cases

| Case | Description |
|------|-------------|
| `.wireframe` | Edges only — no surface fill. |
| `.shaded` | Lit surface shading (Cook-Torrance GGX + hemisphere ambient + Fresnel rim). No edge overlay. |
| `.shadedWithEdges` | Shaded surfaces with a contrast-adaptive wireframe overlay. |
| `.flat` | Surface fill without smooth normal interpolation. |
| `.unlit` | Flat-colour shading — each body drawn in its constant `color` with no lighting, ambient, shadows, Fresnel, or tone-mapping. Faithful per-body colour for diagnostic renders (v1.1.21+). |
| `.xray` | Transparent surface with visible internal edges. |
| `.rendered` | Surfaces with full material/texture treatment. |

### Computed properties

```swift
public var displayName: String        // "Wireframe", "Shaded", "Shaded + Edges", "Flat", "Unlit", "X-Ray", "Rendered"
public var showsSurfaces: Bool        // false only for .wireframe
public var showsEdges: Bool           // true for .wireframe, .shadedWithEdges, .xray
public var usesSmoothShading: Bool    // false only for .flat
public var usesTransparency: Bool     // true only for .xray
public var keyboardShortcut: Character? // "w", "s", "e", "x" for the named modes; nil otherwise
```

---

## OrthoBounds

```swift
public struct OrthoBounds: Sendable, Hashable, Codable
```

Explicit orthographic projection bounds in world units. When supplied to `OffscreenRenderOptions.explicitOrthoBounds`, the renderer uses these exact bounds instead of fitting to scene extents or deriving from `CameraState.orthographicScale`. Required when the output must be pixel-registered against an external reference (for example, a drawing view for SSIM reprojection comparison).

### Stored properties

```swift
public var left:   Float
public var right:  Float
public var bottom: Float
public var top:    Float
```

### Initializer

```swift
public init(left: Float, right: Float, bottom: Float, top: Float)
```

**Example — render a 200 × 200 mm region centred at the origin:**

```swift
let bounds = OrthoBounds(left: -100, right: 100, bottom: -100, top: 100)
var opts = OffscreenRenderOptions(width: 1024, height: 1024)
opts.explicitOrthoBounds = bounds
```

---

## OffscreenRenderOptions

```swift
public struct OffscreenRenderOptions: Sendable
```

Full configuration for a single offscreen render pass. All fields have defaults; the no-argument init is valid. Every scene default is read from `ViewportController.defaultConfiguration` (`.cad`, what `ViewportController()` uses) and `ViewportController.defaultEdgeIntensity`, so a default offscreen render shows what a default live viewport shows. The defaults below are those values.

### Stored properties

| Property | Type | Default | Notes |
|----------|------|---------|-------|
| `width` | `Int` | `1024` | Output image width in pixels. |
| `height` | `Int` | `768` | Output image height in pixels. |
| `cameraState` | `CameraState` | `.isometric` | Camera pose, projection, and FOV. |
| `displayMode` | `DisplayMode` | `.shaded` | Visual representation style. |
| `xrayOpacity` | `Float` | `DisplayMode.defaultXRayOpacity` (0.2) | Surface opacity ceiling in `.xray`; mirrors `ViewportConfiguration.xrayOpacity`. Clamped to `0...1`. |
| `lightingConfiguration` | `LightingConfiguration` | `.threePoint` | Key/fill/back lights, shadows, SSAO (`enableSSAO`, on in `.threePoint`), and tone mapping (`exposure`, `whitePoint`, applied in linear space to every lit surface). Image-based lighting and the skybox (`drawBackground`) use the map named by `environmentMapURL` / `environmentMapData`; see [Parity with the live viewport](#parity-with-the-live-viewport). |
| `backgroundColor` | `SIMD4<Float>` | `(0.95, 0.95, 0.95, 1.0)` | RGBA background colour in the light appearance, sRGB (display) values. |
| `darkModeBackgroundColor` | `SIMD4<Float>?` | `ViewportConfiguration.defaultDarkModeBackgroundColor` | Background in the dark appearance; `nil` uses `backgroundColor` for both. Matches `ViewportConfiguration.darkModeBackgroundColor`. |
| `appearance` | `RenderAppearance` | `.system` | Which background the render uses: `.system` (the system appearance at render time, like the onscreen view), `.light` or `.dark`. Pin one for reproducible output. See below. |
| `showGrid` | `Bool` | `true` | Draw the ground grid (XY plane). |
| `showAxes` | `Bool` | `true` | Draw the RGB world-space axes. |
| `gridStyle` | `GridStyle` | `.plane` | Grid style; matches `ViewportConfiguration.gridStyle`. |
| `gridSize` | `Float` | `100` | Side of the square grid around the origin; matches `ViewportConfiguration.gridSize`. |
| `axisLength` | `Float?` | `nil` | Axis length; `nil` sizes the axes to the rendered bodies, as `ViewportConfiguration.axisLength` does. |
| `axisRadius` | `Float?` | `nil` | Axis radius; `nil` is automatic (1 % of the axis length for `.cylinder`), as `ViewportConfiguration.axisRadius`. |
| `axisStyle` | `AxisStyle` | `.cylinder` | Axis style; matches `ViewportConfiguration.axisStyle`. |
| `msaaSampleCount` | `Int` | `4` | MSAA sample count. `1` or less disables MSAA; otherwise the largest of 8, 4 and 2 that does not exceed it and that the device supports is used. Can change between renders on one `OffscreenRenderer`. |
| `gridBaseSpacing` | `Float` | `1.0` | Fundamental grid unit in world units, mirroring `ViewportConfiguration.gridBaseSpacing`. |
| `gridSubdivisions` | `Int` | `10` | Subdivision factor between adaptive grid spacing levels, mirroring `ViewportConfiguration.gridSubdivisions`. |
| `edgeLineConfiguration` | `EdgeLineConfiguration` | `.default` | Edge width and dash pattern, mirroring `ViewportConfiguration.edgeLineConfiguration`. See [`EdgeLineConfiguration`](Configuration.md#edgelineconfiguration). |
| `explicitOrthoBounds` | `OrthoBounds?` | `nil` | Override projection with exact world-unit bounds. See `OrthoBounds`. |
| `pixelPan` | `SIMD2<Float>?` | `nil` | Screen-space nudge in pixels. `+x` = right, `+y` = down. Lightweight alternative to adjusting the camera for small registration corrections. The near/far fit counts overlay bodies inside the panned (and `explicitOrthoBounds`) view, so an overlay either brings into view is not clipped (#209). |
| `measurements` | `[ViewportMeasurement]` | `[]` | Measurement annotations composited over the Metal pass via Core Graphics. World-space anchors must already be resolved on the input values. |
| `edgeIntensity` | `Float` | `1.0` | Edge intensity, mirroring `ViewportController.edgeIntensity`: `1` is fully opaque, lower values fade edges linearly with view distance between the near and far clip planes, `0` hides them. |
| `clipPlanes` | `[ClipPlane]` | `[]` | Section planes, mirroring `ViewportController.clipPlanes`. The first `ClipPlane.maxActivePlanes` (4) enabled planes clip every pass, the shadow map included. |
| `selectedBodyIDs` | `Set<String>` | `[]` | Bodies drawn selected (tint and outline ring), mirroring `ViewportController.selectedBodyIDs`. Meshed bodies get the ring in every display mode, translucent ones included; edge-only and point bodies get none. |
| `hoveredBodyID` | `String?` | `nil` | Body drawn hovered (lighter tint and outline), mirroring `ViewportController.hoveredBodyID`. |
| `selectionOutline` | `SelectionOutlineStyle` | `.selection` | Outline colour and pixel width for selected bodies, mirroring `ViewportConfiguration.selectionOutline`. |
| `hoverOutline` | `SelectionOutlineStyle` | `.hover` | Outline colour and pixel width for the hovered body, mirroring `ViewportConfiguration.hoverOutline`. |
| `autoSmoothNormals` | `Bool` | `false` | Crease-aware normal smoothing of interleaved meshes, mirroring `ViewportConfiguration.autoSmoothNormals` (on in `.cadHighQuality`). |
| `normalSmoothingCreaseAngle` | `Float` | `0.524` | Crease angle in radians for `autoSmoothNormals`. |
| `enableSilhouettes` | `Bool` | `true` | Screen-space depth silhouettes, mirroring `ViewportConfiguration.enableSilhouettes`. Shares one composite pass with SSAO (tone mapping happens in the surface shader, not here); the pass is skipped in `.wireframe` and `.unlit`. |
| `silhouetteThickness` | `Float` | `1.0` | Mirrors `ViewportConfiguration.silhouetteThickness`. |
| `silhouetteIntensity` | `Float` | `0.7` | Mirrors `ViewportConfiguration.silhouetteIntensity`. |
| `renderingQuality` | `RenderingQuality` | `.standard` | Surface path, mirroring `ViewportConfiguration.renderingQuality`: GPU PN-triangle tessellation at `.enhanced`; mesh shaders at `.maximum` on Apple9 GPUs (M3, A17 and later), falling back to tessellation elsewhere. Direct-mesh bodies, and bodies whose `faceIndices` don't cover every triangle, draw their mesh as given. |
| `tessellationMaxFactor` | `Int` | `32` | Mirrors `ViewportConfiguration.tessellationMaxFactor`; clamped to `2...64` and rounded up to even. |
| `adaptiveTessellation` | `Bool` | `true` | Mirrors `ViewportConfiguration.adaptiveTessellation`. Adaptive factors depend only on the camera, the output size and `tessellationMaxFactor`. |
| `uniformTessellationFactor` | `UniformTessellationFactor` | `.loadAdaptive()` | Factor when `adaptiveTessellation` is `false`. `.fixed(n)` uses `n`; `.loadAdaptive` has no load to follow offscreen and always uses `tessellationMaxFactor`, so the same options always give the same image. |

> **Behaviour change (issue #136):** the default options now run the SSAO / silhouette composite (as the live viewport's defaults do), so a lit render is ambient-occluded and silhouetted. Lit surfaces are ACES tone-mapped in linear space whether or not the composite runs. Set `enableSilhouettes = false` and `lightingConfiguration.enableSSAO = false` for the previous look.
>
> The scene-content defaults changed too, to match a default `ViewportController`: `displayMode` is now `.shaded` (was `.shadedWithEdges`), `showGrid` and `showAxes` are now `true` (were `false`), and `cameraState` is now `.isometric` (was `CameraState()`). Pass the old values explicitly to keep the previous framing and content.

### Initializer

```swift
public init(
    width: Int = 1024,
    height: Int = 768,
    // Scene defaults come from ViewportController.defaultConfiguration (.cad).
    cameraState: CameraState = .isometric,
    displayMode: DisplayMode = .shaded,
    xrayOpacity: Float = DisplayMode.defaultXRayOpacity,
    lightingConfiguration: LightingConfiguration = .threePoint,
    backgroundColor: SIMD4<Float> = SIMD4<Float>(0.95, 0.95, 0.95, 1.0),
    darkModeBackgroundColor: SIMD4<Float>? = ViewportConfiguration.defaultDarkModeBackgroundColor,
    appearance: RenderAppearance = .system,
    showGrid: Bool = true,
    showAxes: Bool = true,
    msaaSampleCount: Int = 4,
    gridBaseSpacing: Float = 1.0,
    gridSubdivisions: Int = 10,
    gridStyle: GridStyle = .plane,
    gridSize: Float = 100.0,
    axisLength: Float? = nil,
    axisRadius: Float? = nil,
    axisStyle: AxisStyle = .cylinder,
    edgeLineConfiguration: EdgeLineConfiguration = .default,
    explicitOrthoBounds: OrthoBounds? = nil,
    pixelPan: SIMD2<Float>? = nil,
    measurements: [ViewportMeasurement] = [],
    edgeIntensity: Float = 1.0,
    clipPlanes: [ClipPlane] = [],
    selectedBodyIDs: Set<String> = [],
    hoveredBodyID: String? = nil,
    selectionOutline: SelectionOutlineStyle = .selection,
    hoverOutline: SelectionOutlineStyle = .hover,
    autoSmoothNormals: Bool = false,
    normalSmoothingCreaseAngle: Float = 0.524,
    enableSilhouettes: Bool = true,
    silhouetteThickness: Float = 1.0,
    silhouetteIntensity: Float = 0.7,
    renderingQuality: RenderingQuality = .standard,
    tessellationMaxFactor: Int = 32,
    adaptiveTessellation: Bool = true,
    uniformTessellationFactor: UniformTessellationFactor = .loadAdaptive()
)

@MainActor
public init(matching controller: ViewportController, width: Int, height: Int)
```

`init(matching:width:height:)` copies everything the offscreen path honours from a live controller: camera, display mode, lighting, grid and axes, edge intensity, clip planes, selection and hover, and the relevant `ViewportConfiguration` fields (background colour, MSAA, grid spacing, edge lines, selection and hover outline styles, silhouettes, normal smoothing). Measurements are not copied.

**Example — thumbnail of what the viewport currently shows:**

```swift
let opts = OffscreenRenderOptions(matching: controller, width: 512, height: 384)
let image = renderer.render(bodies: bodies, options: opts)
```

### How a headless render picks its appearance

Offscreen defaults follow onscreen. `MetalViewportView` follows the SwiftUI colour scheme of its environment; a headless render has no view, so `appearance` decides:

| `RenderAppearance` | Background |
|---|---|
| `.system` (default) | As `.dark` when the appearance in effect at render time is dark, otherwise as `.light`. macOS: `NSApp.effectiveAppearance` when the process has an `NSApplication`, so an app that forces its own appearance with `NSApp.appearance` renders in it; a plain headless process with no application uses the user's Light/Dark setting. iOS/visionOS: `UITraitCollection.current`. That is usually unspecified outside a view's trait update, which makes a headless render light; call `render` inside your view's `traitCollection.performAsCurrent { … }` to follow its style, or pin `.light` / `.dark` (#202) |
| `.light` | `backgroundColor` |
| `.dark` | `darkModeBackgroundColor`, or `backgroundColor` when that is `nil` |

Because `.system` makes the image depend on the host's appearance, **pin `.light` or `.dark` wherever output must be reproducible**: tests, CI, golden/reference images and documentation figures. This package's own pixel tests and its `DocFigures` / `CookbookRender` harnesses pin `.light`. `resolvedBackgroundColor` returns the colour a render will use.

```swift
var options = OffscreenRenderOptions(width: 800, height: 600, appearance: .light)  // CI-stable
```

**Example — render a diagnostic unlit pass at 2 K:**

```swift
var opts = OffscreenRenderOptions(
    width: 2048,
    height: 2048,
    displayMode: .unlit,
    backgroundColor: SIMD4<Float>(0.1, 0.1, 0.1, 1.0),
    showAxes: true
)
```

---

## OffscreenRenderError

```swift
public enum OffscreenRenderError: Error, Sendable
```

Thrown by `OffscreenRenderer.renderToPNG(bodies:url:options:)`.

| Case | Meaning |
|------|---------|
| `.renderFailed` | The Metal render pass returned no image. |
| `.fileCreationFailed` | `CGImageDestinationCreateWithURL` could not open the destination URL. |
| `.writeFailed` | `CGImageDestinationFinalize` failed to write the PNG. |

---

## OffscreenRenderer

```swift
@MainActor
public final class OffscreenRenderer: Sendable
```

Headless Metal renderer that produces a `CGImage` from an array of `ViewportBody` values without requiring `MTKView` or a window. Uses MSAA 4× by default, an MSAA resolve pass, and a CPU-side blit readback. Translucent bodies (opacity < 1, or every body in `.xray`) have their surfaces deferred to a back-to-front sorted pass; their edges still draw. Point-cloud bodies (`primitiveKind == .point`) are drawn via a dedicated point-sprite pipeline.

The renderer caches GPU buffers per body ID and regenerates them only when a body's `generation` counter changes, which happens on `init` and on any geometry mutation.

> **Platform note:** `OffscreenRenderer` does not perform a GPU pick pass, so per-body `isPickable` flags have no effect in the headless path. Selection and hover are drawn (tint and outline ring) from `OffscreenRenderOptions.selectedBodyIDs` / `hoveredBodyID`.

### Parity with the live viewport

For the same bodies and settings, `OffscreenRenderer` produces the same image as a headless frame of `ViewportRenderer` (pinned per scene by `OffscreenParityTests`). `OffscreenRenderOptions(matching:width:height:)` copies those settings from a live `ViewportController`.

Reproduced offscreen: the shadow map, grid, axes, opaque and transparent surfaces (interleaved and direct-mesh), edges (native and quad-expanded), analytic arcs, point clouds, per-triangle highlights (`triangleStyles`), the selection/hover tint and outline, the overlay render layer (drawn last on top of all geometry, in every display mode, arcs included, neither casting nor receiving shadows), clip planes (first four enabled, shadow map included), `edgeIntensity`, crease-aware normal smoothing, the linear-space lighting and ACES tone mapping (`exposure`, `whitePoint`), the SSAO / silhouette composite, image-based lighting plus the HDR skybox (`drawBackground`) from the environment map named by `LightingConfiguration.environmentMapURL` / `environmentMapData`, and the `renderingQuality` surface paths: PN-triangle tessellation (`.enhanced`, `tessellationMaxFactor`, `adaptiveTessellation`, `uniformTessellationFactor`) and mesh shaders (`.maximum` on Apple9) in the shaded, shadow-map and SSAO depth passes. The per-triangle highlight, the selection stencil mask and the outline are drawn on the tessellated surface too, so a highlight is not hidden by the PN bulge and the ring sits outside the rounded silhouette (#202). These passes evaluate the same patch through different vertex functions and rely on them producing bit-identical positions, which Apple GPUs do in practice; Metal only guarantees it for `[[invariant]]` positions in a library compiled with `preserveInvariance`, which the build-time `default.metallib` cannot be. That guarantee is deferred (#209); PN patch edges whose end normals differ by more than `normalSmoothingCreaseAngle` stay flat. Overlay bodies draw the untessellated mesh, as live, and are left out of the per-frame tessellation factors.

Not reproduced offscreen:

| Live feature | Offscreen behaviour |
|---|---|
| An environment map loaded imperatively with `ViewportRenderer.loadEnvironmentMap(...)` | Lives on that renderer and is not seen offscreen. Name the map in `LightingConfiguration` instead. |
| The tessellation load governor (`uniformTessellationFactor = .loadAdaptive`) | Not run: offscreen tessellates uniformly at `tessellationMaxFactor`, so output is deterministic. A live view under load may be tessellating more coarsely. |
| TAA and progressive accumulation | Not run; MSAA (`msaaSampleCount`) is the only anti-aliasing. |
| Depth of field | Never applied by the composite pass. |
| Frustum culling | Not run; it only affects performance. |
| GPU picking | Not run. |
### Initializer

```swift
public init?()
```

Returns `nil` if the system provides no default Metal device or command queue, or if any required pipeline state fails to compile. In practice this succeeds on any device that supports Metal (iOS 18+, macOS 15+, visionOS 1+).

**Example:**

```swift
guard let renderer = await MainActor.run(body: { OffscreenRenderer() }) else {
    fatalError("Metal not available")
}
```

### Rendering

#### `render(bodies:options:)`

```swift
public func render(
    bodies: [ViewportBody],
    options: OffscreenRenderOptions = .init()
) -> CGImage?
```

Renders `bodies` synchronously and returns a `CGImage` in BGRA8 format, or `nil` on failure. Blocks the calling thread until the GPU command buffer and the blit readback both complete.

Invisible bodies (`isVisible == false`) are skipped. Scene-adaptive near/far clip planes are derived from the union of all visible geometry bounding boxes.

**Example:**

```swift
@MainActor
func snapshot(bodies: [ViewportBody], camera: CameraState) -> CGImage? {
    guard let renderer = OffscreenRenderer() else { return nil }
    let opts = OffscreenRenderOptions(
        width: 1920,
        height: 1080,
        cameraState: camera,
        displayMode: .shadedWithEdges
    )
    return renderer.render(bodies: bodies, options: opts)
}
```

#### `renderToPNG(bodies:url:options:)`

```swift
@discardableResult
public func renderToPNG(
    bodies: [ViewportBody],
    url: URL,
    options: OffscreenRenderOptions = .init()
) throws -> Int
```

Renders `bodies` and writes the result as a PNG to `url`. Returns the written file size in bytes. Throws `OffscreenRenderError` on failure.

**Example:**

```swift
@MainActor
func savePNG(bodies: [ViewportBody], to url: URL) throws {
    guard let renderer = OffscreenRenderer() else { return }
    let size = try renderer.renderToPNG(bodies: bodies, url: url)
    print("Wrote \(size) bytes to \(url.lastPathComponent)")
}
```

---

## ViewportRenderer

```swift
@MainActor
public final class ViewportRenderer: NSObject, MTKViewDelegate, Sendable
```

The live Metal render loop. Created by `MetalViewportView` and configured by a `ViewportController`. Implements `MTKViewDelegate` to drive the `MTKView` draw loop. Handles the full rendering pipeline including MSAA, shadow mapping, hardware tessellation (PN triangles on `.enhanced`/`.maximum` quality), mesh shaders (Apple9+ GPU families), SSAO post-processing, TAA, environment map IBL, the GPU pick texture, and per-body features such as transparency, triangle highlights, and render-layer separation.

Most behaviour is configured via `ViewportController` properties rather than directly on this type. The public surface is intentionally narrow.

### Initializer

```swift
public init?(controller: ViewportController, bodies: Binding<[ViewportBody]>)
```

Returns `nil` if Metal device/queue creation fails or any required pipeline state cannot be compiled. `configuration.msaaSampleCount` is first clamped to a count the device supports (the same mapping `OffscreenRenderer` uses), so an unsupported value no longer makes this fail; `MetalViewportView` configures its `MTKView` with the clamped count. Normally called by `MetalViewportView` — you do not need to create `ViewportRenderer` directly.

### Properties

#### `metalDevice`

```swift
public var metalDevice: MTLDevice { get }
```

The underlying `MTLDevice`. Exposed for `MTKView` configuration (for example setting `preferredFramesPerSecond`).

#### `lastDrawableSize`

```swift
public private(set) var lastDrawableSize: CGSize
```

The most recent drawable size in pixels, updated each frame. Use this to convert point coordinates to drawable pixels without accessing `UIScreen`/`NSScreen` (works on iOS, macOS, and visionOS).

#### `effectiveRenderingQuality`

```swift
public var effectiveRenderingQuality: RenderingQuality { get }
```

The [`RenderingQuality`](Configuration.md#renderingquality) the renderer actually draws with: `configuration.renderingQuality`, or lower when the device can't run it (`.maximum` without an Apple9 GPU runs `.enhanced`). Fixed when the renderer is created, which also logs the fallback once. `ViewportController.effectiveRenderingQuality` forwards it (`nil` before a renderer is attached).

### Environment map (IBL)

Three overloads load an equirectangular HDR environment map into the IBL pipeline. On success, the renderer generates prefiltered, irradiance, and cube-map textures and applies them to subsequent frames.

#### `loadEnvironmentMap(data:)`

```swift
public func loadEnvironmentMap(data: Data)
```

Legacy path. Expects raw bytes in the layout `Int32 width | Int32 height | RGBA32Float pixels`.

#### `loadEnvironmentMap(url:)`

```swift
public func loadEnvironmentMap(url: URL) throws
```

Loads a Radiance `.hdr` file. Throws on parse failure.

**Example:**

```swift
if let url = Bundle.main.url(forResource: "studio", withExtension: "hdr") {
    try renderer.loadEnvironmentMap(url: url)
}
```

#### `loadEnvironmentMap(width:height:pixels:)`

```swift
public func loadEnvironmentMap(width: Int, height: Int, pixels: [Float])
```

Loads pre-decoded equirectangular RGBA32Float pixel data.

#### `clearEnvironmentMap()`

```swift
public func clearEnvironmentMap()
```

Removes the current environment map and disables IBL on subsequent frames.

### Buffer management

#### `invalidateBuffers()`

```swift
public func invalidateBuffers()
```

Clears the GPU buffer cache so all body buffers are rebuilt on the next draw call. Call this if you have replaced all body geometry outside the normal generation-counter mechanism.

### GPU picking

#### `performPick(at:completion:)`

```swift
public func performPick(at pixel: SIMD2<Int>, completion: @escaping @Sendable (PickResult?) -> Void)
```

Asynchronously reads a single pixel from the R32Uint pick texture (populated during the previous frame's pick sub-pass) and calls `completion` on the main actor with the decoded `PickResult`, or `nil` for a background or no-hit pixel. The pixel coordinate is in drawable pixels (not points).

Pick IDs are encoded as `objectIndex | (primitiveID << 16)`. The renderer rebuilds the `objectIndex → bodyID` map each frame.

**Example:**

```swift
// In a tap handler, convert the tap point to drawable pixels first.
let scale = renderer.lastDrawableSize.width / viewSize.width
let drawablePx = SIMD2<Int>(Int(tapPt.x * scale), Int(tapPt.y * scale))
renderer.performPick(at: drawablePx) { result in
    if let result {
        print("Hit body \(result.bodyID), primitive \(result.primitiveID)")
    }
}
```

### MTKViewDelegate (protocol conformance)

These are protocol requirements; you will not normally call them directly.

```swift
nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
nonisolated public func draw(in view: MTKView)
```

### Off-screen frame rendering (internal)

`ViewportRenderer` can render a frame without a live `MTKView` drawable. This is **internal**, not public API: it exists so the live renderer's real per-frame output can be regression-tested, which was previously impossible (issue #103, follow-up to #101/#102).

```swift
// Internal to the module; reachable from tests via @testable import.
struct FrameRenderTargets {
    let mainPassDescriptor: MTLRenderPassDescriptor
    let finalColorTexture: MTLTexture
    let size: CGSize
    let presentable: (any MTLDrawable)?
}

func encodeFrame(into targets: FrameRenderTargets)

func renderHeadlessBGRA(
    width: Int, height: Int, backgroundColor: SIMD4<Float>, frameCount: Int = 1
) -> [UInt8]?

func renderHeadless(
    width: Int, height: Int, backgroundColor: SIMD4<Float>, frameCount: Int = 1
) -> CGImage?
```

`draw(in:)` and `renderHeadlessBGRA(...)` are both thin wrappers over the same `encodeFrame(into:)`, so the off-screen path runs **every** pass the live path runs — shadow map, skybox, grid, axes, opaque and transparent surfaces, analytic arcs, point clouds, per-triangle highlights, selection outline, overlay layer, the R32Uint pick pass, the TAA resolve, and the SSAO/silhouette composite. (Tone mapping is not a pass: the surface shader applies it, so both renderers get it.) `draw(in:)` supplies the drawable's texture and presents it; the off-screen path supplies renderer-owned textures (`HeadlessRenderTargets`) built to the same specification `MetalViewRepresentable` configures on the live view (BGRA8 colour, `depth32Float_stencil8` depth/stencil, matching MSAA sample count) and presents nothing.

This differs from `OffscreenRenderer` in kind, not just degree: `OffscreenRenderer` is a separate public pipeline that shares the live renderer's shaders and pipeline factories and reproduces most of its passes (see [Parity with the live viewport](#parity-with-the-live-viewport)), but has no TAA, depth of field or pick pass, whereas this path *is* the live renderer.

Notes:

- **TAA** accumulates across frames. Pass `frameCount > 1` to warm up the history texture before readback; a single frame has no history to blend.
- **State.** The call updates `lastDrawableSize` and the renderer's own caches, exactly as a live frame would. Use a dedicated renderer instance rather than one currently driving an on-screen view.
- **The pick texture is populated,** so `performPick(at:)` / `performRegionPick(rect:)` work headlessly.

`Tests/OCCTSwiftViewportTests/ViewportRendererHeadlessTests.swift` is the permanent harness built on this: a fixed battery of deterministic scenes, hashed per scene, with a `VIEWPORT_HEADLESS_DUMP_DIR` environment variable that dumps hashes plus raw BGRA buffers so two branches can be compared pixel-for-pixel.
