---
title: Home
nav_order: 1
---

# OCCTSwiftViewport documentation

<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>

<model-viewer src="models/l-bracket.glb" camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1" style="width:340px;height:300px;background:#eef1f5;border-radius:6px"></model-viewer>

*A B-Rep solid rendered live in the viewport — drag to orbit, scroll to zoom.*


A reusable **Metal-based 3D viewport** for CAD applications on **iOS 18+ / macOS 15+ / visionOS** —
camera control, GPU picking, PBR lighting, measurement overlays, and a headless offscreen renderer.
It is the rendering companion to [OCCTSwift](https://github.com/gsdali/OCCTSwift): the two libraries
are **fully independent** — OCCTSwiftViewport knows nothing about OCCT or B-Rep topology; your app
bridges geometry into a `ViewportBody` and the viewport displays it.

```swift
import SwiftUI
import OCCTSwiftViewport

struct ContentView: View {
    @StateObject private var controller = ViewportController()

    // Bodies live in @State so SwiftUI owns the binding the view renders.
    @State private var bodies: [ViewportBody] = [
        .box(id: "box", width: 2, height: 2, depth: 2,
             color: SIMD4(0.4, 0.7, 0.95, 1)),
    ]

    var body: some View {
        MetalViewportView(controller: controller, bodies: $bodies)
    }
}
```

## Cookbook

Task-oriented, example-rich guides — each a short bit of prose plus runnable Swift, with a rendered
figure where it helps. The **[Cookbook index](guides/cookbook/)** lists all areas:

[Getting Started](guides/cookbook/getting-started.md) ·
[Display Modes](guides/cookbook/display-modes.md) ·
[Camera & Navigation](guides/cookbook/camera-and-navigation.md) ·
[ViewCube](guides/cookbook/viewcube.md) ·
[Lighting & Materials](guides/cookbook/lighting-and-materials.md) ·
[Picking & Selection](guides/cookbook/picking-and-selection.md) ·
[Loading Geometry](guides/cookbook/loading-geometry.md) ·
[Measurements](guides/cookbook/measurements.md) ·
[Clip Planes & Sections](guides/cookbook/clip-planes.md) ·
[Offscreen Rendering](guides/cookbook/offscreen-rendering.md) ·
[Gestures & Input](guides/cookbook/gestures-and-input.md) ·
[HUD Overlays](guides/cookbook/hud-overlays.md)

## Reference

- **[API Reference](reference/)** — the detailed, per-type function reference: every public type and
  member, signatures, parameters, and runnable examples, grouped by domain (camera, picking,
  rendering, materials, measurement, …).
- [Changelog](CHANGELOG.md) — release-by-release history.

## Architecture & concepts

- [Metal Architecture](metal-architecture.md) — the render pipeline, pick texture, shadow/IBL passes.
- The library is `@MainActor`-isolated for mutable state holders (`ViewportController`,
  `CameraController`, `ViewportRenderer`); value types and configs are `Sendable`. Swift 6 ready.

## Where it fits

```
Your App
  ├── OCCTSwift          (geometry kernel — B-Rep, STEP, booleans, …)
  ├── OCCTSwiftViewport  (Metal rendering, camera, picking — no OCCT dependency)
  ├── OCCTSwiftTools     (Shape → ViewportBody bridge, file I/O, export)
  └── displays geometry in the viewport
```

See the [ecosystem map](https://github.com/gsdali/OCCTSwift/blob/main/docs/ecosystem.md) for how this
package relates to the kernel, bridge, and sibling layers.

## Project

- Source & issues: [github.com/gsdali/OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport)
- Install via Swift Package Manager — pin `from: "1.0.0"` (SemVer-stable since v1.0.0).
- Requires iOS 18+ / macOS 15+, Swift 6.0+, Xcode 16+.
