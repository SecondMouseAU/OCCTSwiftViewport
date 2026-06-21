---
title: Measurements
parent: Cookbook
nav_order: 8
---

# Measurements

OCCTSwiftViewport includes a tap-to-measure system (added in v1.1.20, issue #68) that lets users tap geometry to accumulate world-space surface points and commit annotated measurements. Committed measurements are drawn by the built-in `MeasurementOverlay` — no extra rendering setup required.

---

## Measurement modes

`MeasurementMode` has four cases:

| Case | Points required | Committed as |
|------|----------------|--------------|
| `.none` | — | (tool inactive) |
| `.distance` | 2 (start, end) | `ViewportMeasurement.distance` |
| `.angle` | 3 (armA, vertex, armB) | `ViewportMeasurement.angle` |
| `.radius` | 2 (center, edge point) | `ViewportMeasurement.radius` |

The point count for a mode is available statically:

```swift
let needed = ViewportController.pointCount(for: .angle) // 3
```

`.none` returns 0.

---

## Activating a mode

Set `controller.measurementMode` to activate the tool:

```swift
// Start measuring distances
controller.measurementMode = .distance

// Switch to angle measurement (clears any in-progress points automatically)
controller.measurementMode = .angle

// Deactivate — normal tap-to-select resumes
controller.measurementMode = .none
```

Changing the mode while a measurement is in progress clears `pendingMeasurementPoints` immediately. No half-built measurement is committed.

---

## How taps accumulate into measurements

While `measurementMode != .none`, each tap on a **face** (`.face` pick) is converted to a world-space surface point via Möller–Trumbore intersection and fed into `addMeasurementPoint(_:)`. `MetalViewportView` handles this routing automatically — taps call `handleMeasurementPick(result:ndc:bodies:aspectRatio:)` instead of the normal selection path so the selection stream is not disturbed.

The internal flow per tap:

1. GPU pick returns a `PickResult` with `kind == .face` and a `triangleIndex`.
2. `ViewportController.handleMeasurementPick` reconstructs the world-space hit point using `ViewportBody.worldHitPoint(ray:triangleIndex:)`, which respects the body's `transform`.
3. The point is appended to `pendingMeasurementPoints`.
4. Once enough points are gathered for the active mode, a `ViewportMeasurement` is appended to `controller.measurements` and `pendingMeasurementPoints` is cleared for the next measurement.

Edge and vertex picks, and taps that miss geometry, are silently ignored.

---

## Wiring the overlay

`MetalViewportView` renders the `MeasurementOverlay` automatically — you do not need to add it yourself. Just place `MetalViewportView` and set the mode:

```swift
import SwiftUI
import OCCTSwiftViewport

struct ContentView: View {
    @StateObject private var controller = ViewportController()
    @State private var bodies: [ViewportBody] = []

    var body: some View {
        MetalViewportView(controller: controller, bodies: $bodies)
            .overlay(alignment: .topTrailing) {
                MeasureToolbar(controller: controller)
            }
    }
}

// Simple toolbar that switches measurement modes
@MainActor
struct MeasureToolbar: View {
    @ObservedObject var controller: ViewportController

    var body: some View {
        HStack {
            Button("Distance") { controller.measurementMode = .distance }
            Button("Angle")    { controller.measurementMode = .angle }
            Button("Radius")   { controller.measurementMode = .radius }
            Button("Clear")    { controller.clearMeasurements() }
            if controller.measurementMode != .none {
                Button("Cancel") { controller.cancelPendingMeasurement() }
            }
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
    }
}
```

---

## In-progress feedback (rubber-band)

`pendingMeasurementPoints` is `@Published` and exposes the points tapped so far. You can observe it to draw a rubber-band indicator or a "tap N more" prompt:

```swift
@ObservedObject var controller: ViewportController

var body: some View {
    let pending = controller.pendingMeasurementPoints.count
    let needed  = ViewportController.pointCount(for: controller.measurementMode)
    let remaining = needed - pending

    if controller.measurementMode != .none, remaining > 0 {
        Text("Tap \(remaining) more point\(remaining == 1 ? "" : "s")")
            .font(.caption)
            .padding(6)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}
```

The `MeasurementOverlay` included in `MetalViewportView` draws committed measurements only. Rubber-band rendering for in-progress points is left to the host app.

---

## Driving a distance measurement programmatically

You can feed points directly without waiting for taps — useful for tests or automation:

```swift
@MainActor
func addDistanceMeasurement(
    controller: ViewportController,
    from start: SIMD3<Float>,
    to end: SIMD3<Float>
) {
    controller.measurementMode = .distance
    controller.addMeasurementPoint(start)
    controller.addMeasurementPoint(end)
    // Two points satisfy .distance — measurement is committed and
    // pendingMeasurementPoints is cleared automatically.
}
```

After the call `controller.measurements` contains the new `.distance` entry.

---

## Cancelling and clearing

| Method | Effect |
|--------|--------|
| `cancelPendingMeasurement()` | Discards in-progress points; mode stays active |
| `clearMeasurements()` | Removes all committed measurements **and** in-progress points |
| `controller.measurementMode = .none` | Deactivates the tool; clears in-progress points; committed measurements stay |

---

## Measurement value types

All three concrete types are value types (`Sendable`, `Identifiable`).

### `DistanceMeasurement`

```swift
public struct DistanceMeasurement: Identifiable, Sendable {
    public let id: String
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    public var label: String?      // nil = computed distance string

    public var distance: Float     // simd_length(end - start)
    public var midpoint: SIMD3<Float>

    public init(
        id: String = UUID().uuidString,
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        label: String? = nil
    )
}
```

### `AngleMeasurement`

```swift
public struct AngleMeasurement: Identifiable, Sendable {
    public let id: String
    public var pointA: SIMD3<Float>   // first arm endpoint
    public var vertex: SIMD3<Float>   // angle apex
    public var pointB: SIMD3<Float>   // second arm endpoint
    public var label: String?

    public var degrees: Float         // computed via ProjectionUtility.angle

    public init(
        id: String = UUID().uuidString,
        pointA: SIMD3<Float>,
        vertex: SIMD3<Float>,
        pointB: SIMD3<Float>,
        label: String? = nil
    )
}
```

### `RadiusMeasurement`

```swift
public struct RadiusMeasurement: Identifiable, Sendable {
    public let id: String
    public var center: SIMD3<Float>
    public var edgePoint: SIMD3<Float>
    public var showDiameter: Bool      // default false; overlay shows ⌀ prefix when true
    public var label: String?

    public var radius: Float           // simd_length(edgePoint - center)
    public var diameter: Float         // radius * 2

    public init(
        id: String = UUID().uuidString,
        center: SIMD3<Float>,
        edgePoint: SIMD3<Float>,
        showDiameter: Bool = false,
        label: String? = nil
    )
}
```

---

## Reading committed measurements

`controller.measurements` is `[ViewportMeasurement]`. Iterate it to export values:

```swift
for measurement in controller.measurements {
    switch measurement {
    case .distance(let m):
        print("Distance: \(m.distance) (from \(m.start) to \(m.end))")
    case .angle(let m):
        print("Angle: \(m.degrees)° at vertex \(m.vertex)")
    case .radius(let m):
        let value = m.showDiameter ? m.diameter : m.radius
        let prefix = m.showDiameter ? "⌀" : "R"
        print("\(prefix)\(value) centered at \(m.center)")
    }
}
```

---

## Overlay rendering details

`MeasurementOverlay` uses `Canvas` and is hit-testing–disabled so it never intercepts gestures. It projects world-space points to screen coordinates per frame using the current view–projection matrix. Labels appear in a dark capsule above the measurement midpoint:

- **Distance:** white/blue leader line between the two points; label at midpoint.
- **Angle:** white/orange V-shaped arms + arc indicator; label at arc midpoint.
- **Radius:** white/green line from center to edge point; cross-hair at center; label at midpoint. Displays `⌀` prefix when `showDiameter` is `true`.

The overlay re-renders whenever `controller.measurements` changes (it is driven by `@Published`).

---

## Notes and limitations

- Only **face** picks accumulate measurement points. Tapping an edge, vertex, or empty space is ignored.
- Tap-to-measure and selection are mutually exclusive at the interaction layer: while `measurementMode != .none`, taps route to `handleMeasurementPick` and do not update `controller.pickResult` or `selectedBodyIDs`.
- Bodies with `isPickable = false` are excluded from the GPU pick buffer and cannot yield measurement points.
- Rubber-band rendering for the in-progress segment is not drawn by the built-in overlay; expose `pendingMeasurementPoints` to your own canvas layer if you need it.
