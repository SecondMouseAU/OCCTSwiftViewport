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
| `.shaded` | Lit surface shading (Blinn-Phong + hemisphere ambient + Fresnel rim). No edge overlay. |
| `.shadedWithEdges` | Shaded surfaces with a contrast-adaptive wireframe overlay. Default for `OffscreenRenderOptions`. |
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

Full configuration for a single offscreen render pass. All fields have defaults; the no-argument init is valid.

### Stored properties

| Property | Type | Default | Notes |
|----------|------|---------|-------|
| `width` | `Int` | `1024` | Output image width in pixels. |
| `height` | `Int` | `768` | Output image height in pixels. |
| `cameraState` | `CameraState` | `CameraState()` | Camera pose, projection, and FOV. |
| `displayMode` | `DisplayMode` | `.shadedWithEdges` | Visual representation style. |
| `lightingConfiguration` | `LightingConfiguration` | `.threePoint` | Key/fill/back lights, shadows, IBL. |
| `backgroundColor` | `SIMD4<Float>` | `(0.95, 0.95, 0.95, 1.0)` | RGBA background colour, linear space. |
| `showGrid` | `Bool` | `false` | Draw the adaptive dot grid. |
| `showAxes` | `Bool` | `false` | Draw RGB world-space axis lines. |
| `msaaSampleCount` | `Int` | `4` | MSAA sample count (1 = disabled). |
| `explicitOrthoBounds` | `OrthoBounds?` | `nil` | Override projection with exact world-unit bounds. See `OrthoBounds`. |
| `pixelPan` | `SIMD2<Float>?` | `nil` | Screen-space nudge in pixels. `+x` = right, `+y` = down. Lightweight alternative to adjusting the camera for small registration corrections. |
| `measurements` | `[ViewportMeasurement]` | `[]` | Measurement annotations composited over the Metal pass via Core Graphics. World-space anchors must already be resolved on the input values. |

### Initializer

```swift
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
)
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

Headless Metal renderer that produces a `CGImage` from an array of `ViewportBody` values without requiring `MTKView` or a window. Uses MSAA 4× by default, an MSAA resolve pass, and a CPU-side blit readback. Translucent bodies (opacity < 1) are deferred to a back-to-front sorted pass. Point-cloud bodies (`primitiveKind == .point`) are drawn via a dedicated point-sprite pipeline.

The renderer caches GPU buffers per body ID and regenerates them only when a body's `generation` counter changes.

> **Platform note:** `OffscreenRenderer` does not perform a GPU pick pass. Per-body `isPickable` flags and stencil-based selection outlines are not available in the headless path.

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

Returns `nil` if Metal device/queue creation fails or any required pipeline state cannot be compiled. Normally called by `MetalViewportView` — you do not need to create `ViewportRenderer` directly.

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
