---
title: HUD
parent: API Reference
---

# HUD

Screen-space overlay helpers for orientation and scale visualization. The HUD (heads-up display) types stay pinned to viewport corners, ignore camera translation, and provide visual context without interfering with 3D interaction.

## Topics
- [OrientationGnomon](#orientationgnomon) · [ScaleBarView](#scalebarview) · [ScaleBarMetrics](#scalebarmetrics) · [CameraState.worldUnitsPerPoint](#camerastateworlunitesperpoint)

---

## OrientationGnomon

A small fixed-corner gnomon showing the orientation of the world X / Y / Z axes under the current camera rotation. Unlike the world-space axes drawn by the renderer, this overlay stays pinned to a viewport corner and only rotates — it is a pure orientation aid (HUD), never affected by zoom or pan.

### `init(controller:)`

```swift
public init(controller: ViewportController)
```

Creates an orientation gnomon overlay.

**Parameters:**
- `controller`: The `ViewportController` instance (observed to track camera rotation).

**Example:**
```swift
VStack {
    MetalViewportView(controller: controller)
    
    HStack {
        OrientationGnomon(controller: controller)
            .frame(width: 80, height: 80)
            .padding()
        Spacer()
    }
}
```

### `projectedAxes(rotation:)`

```swift
nonisolated static func projectedAxes(rotation: simd_quatf) -> [ProjectedAxis]
```

Projects the three positive world axes into gnomon screen space for a given camera rotation, sorted back-to-front so nearer axes draw on top.

Uses the same convention as `ViewCubeView`: transform into view space via the inverse rotation, map +X → right and +Y → up (screen y flipped).

**Parameters:**
- `rotation`: The camera's rotation quaternion.

**Returns:** Array of `ProjectedAxis` structs sorted by depth (back to front).

### `ProjectedAxis`

A world axis projected to gnomon screen space.

```swift
struct ProjectedAxis: Identifiable {
    let label: String
    let direction: CGSize      // Normalised screen direction (y points down)
    let color: Color
    let depth: Float           // View-space depth; larger draws on top
    var id: String { label }
}
```

---

## ScaleBarView

A fixed-corner scale bar reporting the world length of a ~100-point on-screen span at the camera's focus (pivot) depth. The represented length snaps to a nice 1 / 2 / 5 × 10ⁿ value via `ScaleBarMetrics`. For perspective cameras the reading is exact only at the pivot depth (scale varies with depth); for orthographic cameras it is exact everywhere.

### `init(controller:viewportHeightPoints:unitLabel:targetPoints:)`

```swift
public init(controller: ViewportController,
            viewportHeightPoints: CGFloat,
            unitLabel: String = "",
            targetPoints: CGFloat = 100)
```

Creates a scale bar overlay.

**Parameters:**
- `controller`: The `ViewportController` instance (observed to track camera scale).
- `viewportHeightPoints`: The viewport height in points (not pixels) — used to convert camera scale to points.
- `unitLabel`: Optional unit suffix shown after the number (library is unit-agnostic). Default: `""`.
- `targetPoints`: Target on-screen bar length in points; actual length snaps to a nice value. Default: `100`.

**Example:**
```swift
VStack {
    MetalViewportView(controller: controller)
    
    HStack {
        Spacer()
        ScaleBarView(
            controller: controller,
            viewportHeightPoints: 600,
            unitLabel: "mm",
            targetPoints: 100
        )
        .padding()
    }
}
```

---

## ScaleBarMetrics

Resolved geometry for a screen-space scale bar. Given a world-units-per-point scale and a target on-screen length, snaps the represented length to a "nice" 1 / 2 / 5 × 10ⁿ value and reports the matching bar length in points plus a formatted label.

### `init(worldUnitsPerPoint:targetPoints:unitLabel:)`

```swift
public init?(worldUnitsPerPoint: Float,
             targetPoints: CGFloat,
             unitLabel: String = "")
```

Builds metrics for a scale bar, or `nil` if the inputs are degenerate.

**Parameters:**
- `worldUnitsPerPoint`: World units per screen point (see `CameraState.worldUnitsPerPoint(viewportHeightPoints:)`).
- `targetPoints`: The desired bar length in points; the actual length is the nearest nice value to this.
- `unitLabel`: Optional unit suffix. Default: `""`.

**Returns:** `ScaleBarMetrics` instance, or `nil` if inputs are non-positive or non-finite.

**Example:**
```swift
let wpp: Float = 0.5  // 0.5 world units per screen point
let metrics = ScaleBarMetrics(
    worldUnitsPerPoint: wpp,
    targetPoints: 100,
    unitLabel: "mm"
)
if let metrics = metrics {
    print(metrics.label)      // e.g. "50 mm"
    print(metrics.worldLength) // e.g. 50.0
    print(metrics.pointLength) // e.g. 100.0
}
```

### `worldLength`

```swift
public let worldLength: Float
```

The (rounded) world length the bar represents. Always snaps to a nice 1 / 2 / 5 × 10ⁿ value.

### `pointLength`

```swift
public let pointLength: CGFloat
```

The bar length in screen points.

### `label`

```swift
public let label: String
```

Formatted label, e.g. `"10 mm"` (or just `"10"` when no unit is given).

### `niceNumber(_:)`

```swift
public static func niceNumber(_ x: Float) -> Float
```

Rounds a positive value to the nearest 1 / 2 / 5 × 10ⁿ.

**Parameters:**
- `x`: The value to round.

**Returns:** The rounded nice value, or `0` if `x` is non-positive or non-finite.

**Example:**
```swift
ScaleBarMetrics.niceNumber(47.3)  // Returns 50
ScaleBarMetrics.niceNumber(1.2)   // Returns 1
ScaleBarMetrics.niceNumber(7.8)   // Returns 10
```

---

## CameraState.worldUnitsPerPoint

### `worldUnitsPerPoint(viewportHeightPoints:)`

```swift
public func worldUnitsPerPoint(viewportHeightPoints: Float) -> Float
```

World units spanned by one screen point at the focus (pivot) depth.

For orthographic cameras the value is depth-independent (`orthographicScale` is the on-screen vertical extent). For perspective cameras it is evaluated at `distance` — the pivot depth — since perspective scale varies with depth and the pivot is the meaningful reference for a scale bar.

**Parameters:**
- `viewportHeightPoints`: The viewport height in points (not pixels).

**Returns:** World units per point, or `0` for a degenerate viewport.

**Example:**
```swift
let cameraState = controller.cameraState
let wpp = cameraState.worldUnitsPerPoint(viewportHeightPoints: 600)

// Use with ScaleBarMetrics
if let metrics = ScaleBarMetrics(
    worldUnitsPerPoint: wpp,
    targetPoints: 100,
    unitLabel: "mm"
) {
    print("Scale bar represents \(metrics.worldLength) mm")
}
```
