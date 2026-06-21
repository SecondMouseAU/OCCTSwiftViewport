---
title: HUD Overlays
parent: Cookbook
nav_order: 12
---

# HUD Overlays

OCCTSwiftViewport ships two screen-space heads-up overlays that are pinned to viewport corners and never affected by pan or zoom:

| Overlay | Type | Purpose |
|---|---|---|
| `OrientationGnomon` | RGB axis legend | Shows current camera orientation as X/Y/Z lines |
| `ScaleBarView` | World-unit ruler | Shows how many world units span ~100 screen points |

Both are SwiftUI views that take a `ViewportController` and react to `cameraState` changes automatically.

---

## Enabling the built-in overlays

The simplest path is to let `MetalViewportView` manage both overlays. Set the flags in `ViewportConfiguration` at construction time:

```swift
let config = ViewportConfiguration(
    showOrientationGnomon: true,
    showScaleBar: true,
    scaleBarUnitLabel: "mm"   // "" = no unit suffix
)
let controller = ViewportController(configuration: config)
```

`MetalViewportView` renders the gnomon at **top-leading, 64 × 64 pt** and the scale bar at **bottom-leading** whenever the respective flag is `true`. No further code is needed.

Toggle either overlay at runtime through the published properties:

```swift
controller.showOrientationGnomon = true
controller.showScaleBar = false
```

The `scaleBarUnitLabel` comes from `controller.configuration.scaleBarUnitLabel` and is baked in at renderer construction; to change it at runtime, place `ScaleBarView` yourself (see below).

---

## Orientation gnomon

`OrientationGnomon` draws three lines from a centre point toward the screen-space projections of the world +X (red), +Y (green), and +Z (blue) axes. Axes closer to the viewer draw on top. It is a pure orientation aid — it never reflects camera distance or pan.

### Placing it yourself

```swift
MetalViewportView(controller: controller, bodies: $bodies)
    .overlay(alignment: .topLeading) {
        OrientationGnomon(controller: controller)
            .frame(width: 64, height: 64)
            .padding(12)
            .allowsHitTesting(false)
    }
```

`OrientationGnomon` only needs a `ViewportController`; it reads `controller.cameraState.rotation` on every update.

### How projection works

Internally, `OrientationGnomon.projectedAxes(rotation:)` is a `nonisolated static` function you can call directly — useful for unit tests or custom HUD implementations:

```swift
let axes = OrientationGnomon.projectedAxes(rotation: controller.cameraState.rotation)
// axes is [ProjectedAxis] sorted back-to-front
// Each axis has: label ("X"/"Y"/"Z"), direction (CGSize, screen-space),
// color (.red/.green/.blue), depth (Float)
```

---

## Scale bar

`ScaleBarView` renders a horizontal bar with end ticks and a label above it (e.g. `"50 mm"`). The represented world length snaps to a clean 1 / 2 / 5 × 10ⁿ value. For perspective cameras the reading is exact at the pivot (focus) depth; for orthographic cameras it is exact everywhere.

### Placing it yourself

`ScaleBarView` needs the viewport height in points so it can convert the camera scale. Use a `GeometryReader` to supply it:

```swift
GeometryReader { geo in
    MetalViewportView(controller: controller, bodies: $bodies)
        .overlay(alignment: .bottomLeading) {
            ScaleBarView(
                controller: controller,
                viewportHeightPoints: geo.size.height,
                unitLabel: "mm",
                targetPoints: 100        // desired bar length in points (default)
            )
            .padding(12)
            .allowsHitTesting(false)
        }
}
```

`targetPoints` is the *desired* on-screen bar length; the actual rendered length snaps to the nearest nice value and may differ slightly.

---

## ScaleBarMetrics — the underlying value type

`ScaleBarMetrics` is a pure, `Sendable` value type that does the scale arithmetic. Use it directly when you want to drive a custom HUD element:

```swift
let wpp = controller.cameraState.worldUnitsPerPoint(
    viewportHeightPoints: Float(viewportHeight)
)
if let metrics = ScaleBarMetrics(
    worldUnitsPerPoint: wpp,
    targetPoints: 100,
    unitLabel: "mm"
) {
    // metrics.worldLength  — Float, the snapped world length (e.g. 50.0)
    // metrics.pointLength  — CGFloat, actual bar length in screen points
    // metrics.label        — String, formatted label (e.g. "50 mm")
}
```

`ScaleBarMetrics.init` returns `nil` for degenerate inputs (zero or non-finite scale), so the `if let` guard is the correct pattern.

### Nice-number rounding

The snapping follows the 1 / 2 / 5 × 10ⁿ rule:

```swift
ScaleBarMetrics.niceNumber(3.7)   // → 5.0
ScaleBarMetrics.niceNumber(14.0)  // → 10.0
ScaleBarMetrics.niceNumber(0.006) // → 0.005
```

---

## CameraState.worldUnitsPerPoint

This is the bridge between the camera and both HUD elements:

```swift
// Signature (on CameraState)
public func worldUnitsPerPoint(viewportHeightPoints: Float) -> Float
```

- **Orthographic:** returns `orthographicScale / viewportHeightPoints` — depth-independent.
- **Perspective:** evaluates at `distance` (the pivot depth) using the vertical FOV.
- Returns `0` for a degenerate viewport (`viewportHeightPoints ≤ 0` or non-finite).

```swift
let wpp = controller.cameraState.worldUnitsPerPoint(
    viewportHeightPoints: Float(viewportHeight)
)
// wpp == 0 → camera not yet set up; skip HUD rendering
if wpp > 0 {
    // safe to build ScaleBarMetrics or annotate the scale elsewhere
}
```

---

## Complete example — both overlays together

```swift
struct MyViewport: View {
    @StateObject private var controller = ViewportController(
        configuration: ViewportConfiguration(
            showOrientationGnomon: false,  // we'll place them manually
            showScaleBar: false
        )
    )
    @State private var bodies: [ViewportBody] = [.box()]

    var body: some View {
        GeometryReader { geo in
            MetalViewportView(controller: controller, bodies: $bodies)
                .overlay(alignment: .topLeading) {
                    OrientationGnomon(controller: controller)
                        .frame(width: 64, height: 64)
                        .padding(12)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    ScaleBarView(
                        controller: controller,
                        viewportHeightPoints: geo.size.height,
                        unitLabel: "mm"
                    )
                    .padding(12)
                    .allowsHitTesting(false)
                }
        }
    }
}
```

> **Tip:** call `.allowsHitTesting(false)` on HUD overlays so taps and drags pass through to the viewport underneath.

---

## Summary

| Task | API |
|---|---|
| Enable gnomon via config | `ViewportConfiguration(showOrientationGnomon: true)` |
| Enable scale bar via config | `ViewportConfiguration(showScaleBar: true, scaleBarUnitLabel: "mm")` |
| Toggle at runtime | `controller.showOrientationGnomon`, `controller.showScaleBar` |
| Place gnomon manually | `OrientationGnomon(controller:)` in any SwiftUI overlay |
| Place scale bar manually | `ScaleBarView(controller:viewportHeightPoints:unitLabel:targetPoints:)` |
| Raw scale value | `CameraState.worldUnitsPerPoint(viewportHeightPoints:)` |
| Custom HUD arithmetic | `ScaleBarMetrics(worldUnitsPerPoint:targetPoints:unitLabel:)` |
