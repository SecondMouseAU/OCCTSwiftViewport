---
title: API Reference
nav_order: 3
has_children: true
---

# OCCTSwiftViewport API Reference

A **detailed, per-type function reference** for the OCCTSwiftViewport Swift API. One page per domain,
every public type and member documented: signature, behaviour, parameters, return, and a runnable
example. This complements the [Cookbook](../guides/cookbook/) (task-oriented walkthroughs); this is
the *exhaustive* surface.

The library also aliases ~56 public types under underscore-prefixed typealiases (`_CameraState`,
`_ViewportBody`, …) in the umbrella `OCCTSwiftViewport.swift`. Every aliased type is already
`public` in that same module, so after `import OCCTSwiftViewport` the bare type name is what you
normally write; the `_TypeName` form is an index of the public surface and an escape hatch for
disambiguating against a same-named type in another imported module. These pages document the
underlying types.

## Page layout

Each page groups related types by domain. Every page:

```markdown
---
title: <Domain>
parent: API Reference
---

# <Domain>

<1–3 sentences: what this domain covers and the key entry points.>

## Topics
- [<Type A>](#type-a) · [<Type B>](#type-b) · …

---

## <Type>          ← one ## per public type
<what it represents and how you obtain one.>

### `member(label:)`   ← ### per public member
<one-line summary, signature, parameters, example.>
```

## Pages

| Page | Types |
|------|-------|
| [Camera](Camera.md) | `CameraController`, `CameraState`, `PivotStrategy`, `DynamicPivotConfiguration`, `RotationStyle`, `StandardView` |
| [Viewport Body & Geometry](ViewportBody.md) | `ViewportBody`, `ViewportBody.directMesh(…)` / `usesDirectMesh`, `ViewportArc`, `ArcSampling`, `BodyPrimitiveKind`, primitive factories |
| [Configuration](Configuration.md) | `ViewportConfiguration`, `RenderingQuality`, `RenderLayer`, `PickingConfiguration`, `ClipPlane` |
| [Display & Lighting](Display-Lighting.md) | `DisplayMode`, `LightingConfiguration`, `LightSettings` |
| [Materials](Materials.md) | `PBRMaterial`, `MaterialLibrary`, `NamedMaterial`, `HDRLoader` |
| [Picking & Selection](Picking.md) | `PickResult`, `PrimitiveKind`, `PickLayer`, `PickResultFilter`, `SceneRaycast`, `RaycastHit`, `Ray`, `ProjectionUtility` |
| [Rendering](Rendering.md) | `ViewportRenderer`, `OffscreenRenderer`, `OffscreenRenderOptions`, `OffscreenRenderError`, `OrthoBounds` |
| [ViewCube](ViewCube.md) | `NavigationCube`, `NavigationCubeView`, `ViewCubeView`, `ViewCubeRegion`, `ViewCubeFace`, `ViewCubePosition` |
| [Measurements](Measurements.md) | `ViewportMeasurement`, `MeasurementMode`, `DistanceMeasurement`, `AngleMeasurement`, `RadiusMeasurement` |
| [HUD](HUD.md) | `OrientationGnomon`, `ScaleBarView`, `ScaleBarMetrics` |
| [Input](Input.md) | `ViewportInputEvent`, `ViewportModifierKeys`, `GestureConfiguration`, `GestureAction` |
| [Math](Math.md) | `BoundingBox`, `Frustum`, `Ray` |
| [SwiftUI Views](Views.md) | `MetalViewportView`, `ViewportController` |
