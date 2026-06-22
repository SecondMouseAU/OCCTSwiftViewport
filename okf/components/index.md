---
type: component
title: Components index
resource: https://github.com/SecondMouseAU/OCCTSwiftViewport
tags: [index]
description: Public modules / API surfaces exposed by OCCTSwiftViewport.
timestamp: 2026-06-22
---

# Components

The published library product/target is `OCCTSwiftViewport`. Its key public types (from the README):

- **`MetalViewportView`** — SwiftUI entry point wrapping an `MTKView` (UIView/NSView representable)
  with gesture handling.
- **`ViewportController`** — `@MainActor` `ObservableObject` central state hub: display mode,
  standard views, focus, clip planes, measurements, picking.
- **`ViewportBody`** — geometry container (interleaved vertex data + triangle indices + edge
  polylines + RGBA color + optional `faceIndices`). The geometry-source-agnostic input type.
- **`CameraState`** / **`CameraController`** — immutable camera value and input/animation handling
  (arcball, turntable, first-person; inertia; SLERP).
- **`ViewportConfiguration`** / **`GestureConfiguration`** / **`LightingConfiguration`** — display,
  gesture (`.default` / `.blender` / `.fusion360`), and lighting (`.threePoint` / `.studio` /
  `.architectural` / `.flat`) presets, plus `.performance` and `.cadHighQuality` presets.
- **`ClipPlane`** — section cut planes. **`PickResult`** — GPU pick hit info.
- **`SceneRaycast`** / **`ProjectionUtility`** — CPU ray intersection and screen ↔ world conversion.
- **`ViewCubeView`** — standalone orientation widget (26 clickable regions).
- **`NormalSmoothing`** — crease-aware per-vertex normal smoothing helper.
