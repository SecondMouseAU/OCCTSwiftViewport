---
title: Offscreen Rendering
parent: Cookbook
nav_order: 10
---

# Offscreen Rendering

`OffscreenRenderer` renders `[ViewportBody]` to a `CGImage` or PNG file without
an `MTKView` or a window. It uses the same Metal pipelines as the interactive
viewport — the same Blinn-Phong shading, the same shadow map, the same
transparent-surface sort — so headless output is visually identical to what a
user sees on screen.

Typical uses: documentation figures, thumbnail generation, CI regression images,
export workflows, and integration tests that check rendering without a display.

{: .note }
`OffscreenRenderer` is `@MainActor`. On macOS it can be driven from a plain
`@main` Swift executable. In a test target annotate the test method
`@MainActor` or call from a `Task { @MainActor in … }`.

---

## Quick start

```swift
import OCCTSwiftViewport

// 1. Create the renderer (failable — returns nil if no Metal device).
guard let renderer = await MainActor.run(body: { OffscreenRenderer() }) else {
    fatalError("No Metal device")
}

// 2. Geometry.
let body = ViewportBody.box(size: SIMD3<Float>(2, 1, 3), color: SIMD4<Float>(0.4, 0.6, 0.9, 1))

// 3. Frame the camera to fit the geometry.
let aspectRatio: Float = 1024.0 / 768.0
let camera = CameraState.isometric.fit(to: [body], aspectRatio: aspectRatio) ?? CameraState.isometric

// 4. Render.
let options = OffscreenRenderOptions(
    width: 1024,
    height: 768,
    cameraState: camera
)
if let image = renderer.render(bodies: [body], options: options) {
    // use CGImage …
}
```

---

## `OffscreenRenderOptions` — all fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `width` | `Int` | `1024` | Output pixel width |
| `height` | `Int` | `768` | Output pixel height |
| `cameraState` | `CameraState` | `CameraState()` | Camera position and projection |
| `displayMode` | `DisplayMode` | `.shadedWithEdges` | See [Display modes](#display-modes) |
| `lightingConfiguration` | `LightingConfiguration` | `.threePoint` | Key/fill/back + ambient |
| `backgroundColor` | `SIMD4<Float>` | `(0.95, 0.95, 0.95, 1)` | RGBA, linear |
| `showGrid` | `Bool` | `false` | Adaptive dot grid |
| `showAxes` | `Bool` | `false` | RGB world-space axes |
| `msaaSampleCount` | `Int` | `4` | MSAA samples (1, 2, or 4) |
| `explicitOrthoBounds` | `OrthoBounds?` | `nil` | See [Pixel-registered ortho](#pixel-registered-ortho-renders) |
| `pixelPan` | `SIMD2<Float>?` | `nil` | Screen-space nudge (+x right, +y down) |
| `measurements` | `[ViewportMeasurement]` | `[]` | See [Measurement overlays](#measurement-overlays) |

All fields have defaults so you can construct with only the overrides you need:

```swift
var options = OffscreenRenderOptions()   // 1024×768, shadedWithEdges, threePoint
options.backgroundColor = SIMD4<Float>(1, 1, 1, 1)   // white background
options.showGrid = true
```

---

## Framing the camera with `CameraState.fit`

`CameraState.fit(to:aspectRatio:padding:)` returns a copy of the receiver with
`pivot`, `distance` (perspective), or `orthographicScale` (orthographic) set to
enclose a `BoundingBox`. The `padding` parameter is a multiplicative margin:
`1.0` is a tight fit, `1.1` (the default) adds 10 % breathing room.

```swift
// Fit to an explicit bounding box.
let bounds = BoundingBox(min: SIMD3(-5, 0, -5), max: SIMD3(5, 10, 5))
let camera = CameraState.isometric.fit(to: bounds, aspectRatio: 4.0 / 3.0, padding: 1.15)
```

The convenience overload that accepts `[ViewportBody]` unions the bounding boxes
of all visible bodies and returns `nil` when no body has geometry:

```swift
if let camera = CameraState.front.fit(to: bodies, aspectRatio: Float(width) / Float(height)) {
    options.cameraState = camera
}
```

Standard presets — `CameraState.isometric`, `.top`, `.front`, `.right` — are
good starting points. Build a completely custom viewpoint with `CameraState.lookAt`:

```swift
let camera = CameraState.lookAt(
    target: SIMD3<Float>(0, 0, 0),
    from:   SIMD3<Float>(10, 8, 12)
)
```

---

## Rendering to `CGImage` and to a PNG file

### `render(bodies:options:) -> CGImage?`

Executes the Metal command buffer synchronously on the calling thread and
returns a `CGImage` backed by a shared-memory blit. Returns `nil` only if
the device is lost or texture allocation fails.

```swift
if let image = renderer.render(bodies: bodies, options: options) {
    // Write with ImageIO, pass to NSImageView / UIImageView, diff in tests …
}
```

### `renderToPNG(bodies:url:options:) throws -> Int`

Calls `render`, encodes the result as PNG via `ImageIO`, writes it to `url`,
and returns the file size in bytes. Throws `OffscreenRenderError`:

| Error | Meaning |
|---|---|
| `.renderFailed` | Metal render returned nil |
| `.fileCreationFailed` | Could not create `CGImageDestination` at the URL |
| `.writeFailed` | `CGImageDestinationFinalize` failed (disk full, permissions, …) |

```swift
let url = URL(fileURLWithPath: "/tmp/part-thumbnail.png")
do {
    let bytes = try renderer.renderToPNG(bodies: bodies, url: url, options: options)
    print("wrote \(bytes) bytes")
} catch OffscreenRenderError.renderFailed {
    // handle …
}
```

`@discardableResult` — the return value can be ignored when only the file
matters.

---

## Display modes

`OffscreenRenderOptions.displayMode` accepts any `DisplayMode` case.

| Case | Surfaces | Edges | Lighting |
|---|---|---|---|
| `.wireframe` | no | yes | — |
| `.shaded` | yes | no | yes |
| `.shadedWithEdges` (default) | yes | yes | yes |
| `.flat` | yes | no | yes (flat normals) |
| `.unlit` | yes | no | **no** |
| `.xray` | yes (transparent) | yes | yes |

### `.unlit` — faithful diagnostic colour renders

`.unlit` draws each body at its constant `color` with no lighting, no ambient
hemisphere, no shadows, no Fresnel rim, and no tone mapping. Every body appears
exactly as its `SIMD4<Float>` colour with no shading variation across the surface.

Use it when colours carry semantic meaning — topology colouring, deviation maps,
result visualisations — and lighting-induced brightness variation would obscure
the data.

```swift
let redBody   = ViewportBody.box(size: .one, color: SIMD4<Float>(1, 0, 0, 1))
let greenBody = ViewportBody.box(size: .one, color: SIMD4<Float>(0, 1, 0, 1))
// place bodies at different positions via body.transform …

let options = OffscreenRenderOptions(
    displayMode: .unlit,
    backgroundColor: SIMD4<Float>(0.12, 0.12, 0.12, 1)
)
```

---

## Lighting and background

`lightingConfiguration` accepts any `LightingConfiguration` value. The built-in
presets cover most documentation needs:

```swift
options.lightingConfiguration = .studio         // soft, balanced
options.lightingConfiguration = .architectural  // high-contrast
options.lightingConfiguration = .flat           // ambient-only, no shadows
options.lightingConfiguration = .threePoint     // default: key + fill + back
```

`backgroundColor` is a linear-space RGBA `SIMD4<Float>`. Common values:

```swift
options.backgroundColor = SIMD4<Float>(1, 1, 1, 1)       // white
options.backgroundColor = SIMD4<Float>(0, 0, 0, 1)       // black
options.backgroundColor = SIMD4<Float>(0.18, 0.18, 0.18, 1)  // mid-grey
```

---

## MSAA

`msaaSampleCount` accepts `1`, `2`, or `4` (the default). On Apple Silicon
4× MSAA resolves in the same pass at negligible extra cost. Set to `1` when
doing pixel-exact SSIM comparisons or when writing tests that check raw pixel
values.

```swift
options.msaaSampleCount = 1   // pixel-exact; no multi-sample blur
```

---

## Pixel-registered ortho renders

When the output must align with an external drawing or reference image —
for example SSIM-diffing against a CAD drawing view — set
`explicitOrthoBounds` to pin the world-space region exactly rather than
inferring it from `CameraState.orthographicScale` or the scene AABB:

```swift
let bounds = OrthoBounds(left: -50, right: 50, bottom: -37.5, top: 37.5)
var options = OffscreenRenderOptions(
    width: 2000, height: 1500,
    cameraState: CameraState.top,
    displayMode: .shadedWithEdges
)
options.explicitOrthoBounds = bounds
```

For sub-pixel registration nudges after the projection is set, use `pixelPan`.
Positive x pans the image right; positive y pans it down (screen-space
convention):

```swift
options.pixelPan = SIMD2<Float>(0.5, -1.2)  // nudge half a pixel right, 1.2 up
```

`pixelPan` is a lightweight alternative to recomputing `explicitOrthoBounds`
when the calibration offset is already known in pixel space.

---

## Measurement overlays

Populate `options.measurements` with `ViewportMeasurement` values to burn
dimension annotations into the output image. `MeasurementCompositor` composites
them over the Metal render using Core Graphics and Core Text, matching the visual
style of the interactive `MeasurementOverlay` SwiftUI canvas exactly (same line
weights, label font, halo, colours).

The three measurement kinds and their required world-space data:

| Kind | Type | Required properties |
|---|---|---|
| Distance | `DistanceMeasurement` | `start`, `end`, `midpoint`, `distance` |
| Angle | `AngleMeasurement` | `vertex`, `pointA`, `pointB`, `degrees` |
| Radius | `RadiusMeasurement` | `center`, `edgePoint`, `radius` |

World-space anchor points must be resolved before passing to
`OffscreenRenderOptions`. The headless path performs no geometry or topology
lookups.

```swift
let dist = DistanceMeasurement(
    start:    SIMD3<Float>(0, 0, 0),
    end:      SIMD3<Float>(10, 0, 0),
    midpoint: SIMD3<Float>(5, 0, 0),
    distance: 10.0
)
options.measurements = [.distance(dist)]
```

Labels default to auto-formatted values (`"10.00"`, `"45.0°"`, `"R5.00"`).
Override with the `label` property on any measurement type:

```swift
var dist = DistanceMeasurement(…)
dist.label = "100 mm"
```

---

## How the cookbook figures are made

The figures in `Examples/DocFigures/` are produced with exactly this API —
each figure is a small Swift script that constructs bodies, sets
`OffscreenRenderOptions`, and calls `renderToPNG`. Running the scripts
regenerates all figures deterministically from source geometry, with no manual
screenshot step.

---

## Thread safety

`OffscreenRenderer` is `@MainActor`. It is safe to hold a single instance and
call `render` or `renderToPNG` multiple times; the renderer caches GPU buffers
per `body.id` and only rebuilds them when `body.generation` changes.

Concurrent renders from multiple `OffscreenRenderer` instances are safe — each
instance owns its Metal command queue, buffer cache, and textures independently.
