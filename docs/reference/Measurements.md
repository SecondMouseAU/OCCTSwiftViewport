---
title: Measurements
parent: API Reference
---

# Measurements

These five types provide annotation data structures for distance, angle, and radius measurements displayed as viewport overlays. Measurements are value types suitable for encoding/decoding; clients accumulate them into a `ViewportController` and render them via the `MeasurementOverlay` SwiftUI view.

## Topics

- [ViewportMeasurement](#viewportmeasurement) · [MeasurementMode](#measurementmode) · [DistanceMeasurement](#distancemeasurement) · [AngleMeasurement](#anglemeasurement) · [RadiusMeasurement](#radiusmeasurement)

---

## ViewportMeasurement

`ViewportMeasurement` is an enum that wraps the three concrete measurement types. It conforms to `Identifiable` and `Sendable`, enabling safe integration with SwiftUI state and Combine pipelines.

### Cases

#### `case distance(DistanceMeasurement)`

A point-to-point distance measurement.

```swift
public enum ViewportMeasurement: Identifiable, Sendable {
    case distance(DistanceMeasurement)
}
```

---

#### `case angle(AngleMeasurement)`

An angle measurement between three points.

```swift
public enum ViewportMeasurement: Identifiable, Sendable {
    case angle(AngleMeasurement)
}
```

---

#### `case radius(RadiusMeasurement)`

A radius or diameter measurement.

```swift
public enum ViewportMeasurement: Identifiable, Sendable {
    case radius(RadiusMeasurement)
}
```

---

### `id`

Unique identifier derived from the wrapped measurement.

```swift
public var id: String { get }
```

Extracts and returns the `id` field from the wrapped value (e.g., `DistanceMeasurement.id`). Enables use in SwiftUI lists and ForEach loops.

- **Returns:** The `String` ID of the wrapped measurement.
- **Example:**
  ```swift
  let meas: ViewportMeasurement = .distance(DistanceMeasurement(start: .zero, end: SIMD3(10, 0, 0)))
  print(meas.id)  // UUID-based identifier
  ```

---

## DistanceMeasurement

`DistanceMeasurement` records the start and end points of a point-to-point distance measurement. It conforms to `Identifiable` and `Sendable`.

### `init(id:start:end:label:)`

Creates a distance measurement between two world-space points.

```swift
public init(id: String = UUID().uuidString, start: SIMD3<Float>, end: SIMD3<Float>, label: String? = nil)
```

- **Parameters:**
  - `id` — unique identifier (default: UUID string).
  - `start` — first point in world coordinates.
  - `end` — second point in world coordinates.
  - `label` — optional text override; if `nil`, the computed distance is used.
- **Example:**
  ```swift
  let m = DistanceMeasurement(start: SIMD3(0, 0, 0), end: SIMD3(10, 0, 0))
  print(m.distance)  // 10.0
  ```

---

### Properties

#### `id`

Unique identifier for this measurement.

```swift
public let id: String
```

- **Example:**
  ```swift
  let m = DistanceMeasurement(id: "dist-1", start: .zero, end: SIMD3(5, 0, 0))
  ```

---

#### `start`

Start point in world coordinates.

```swift
public var start: SIMD3<Float>
```

- **Example:**
  ```swift
  let m = DistanceMeasurement(start: SIMD3(1, 2, 3), end: SIMD3(4, 5, 6))
  ```

---

#### `end`

End point in world coordinates.

```swift
public var end: SIMD3<Float>
```

- **Example:**
  ```swift
  var m = DistanceMeasurement(start: .zero, end: SIMD3(10, 0, 0))
  m.end = SIMD3(5, 0, 0)
  ```

---

#### `label`

Optional label override for custom text display.

```swift
public var label: String?
```

If `nil`, the overlay displays the computed `distance` value formatted as a string.

- **Example:**
  ```swift
  var m = DistanceMeasurement(start: .zero, end: SIMD3(50, 0, 0))
  m.label = "Gap: 50 mm"
  ```

---

### `distance`

The computed Euclidean distance between `start` and `end`.

```swift
public var distance: Float { get }
```

Computed as `simd_length(end - start)`. Always non-negative.

- **Returns:** Distance in world units.
- **Example:**
  ```swift
  let m = DistanceMeasurement(start: .zero, end: SIMD3(3, 4, 0))
  print(m.distance)  // 5.0
  ```

---

### `midpoint`

The midpoint for label placement.

```swift
public var midpoint: SIMD3<Float> { get }
```

Computed as `(start + end) * 0.5`. Useful for positioning the measurement label in the viewport.

- **Returns:** World-space midpoint.
- **Example:**
  ```swift
  let m = DistanceMeasurement(start: SIMD3(0, 0, 0), end: SIMD3(10, 0, 0))
  print(m.midpoint)  // (5, 0, 0)
  ```

---

## AngleMeasurement

`AngleMeasurement` records three points that form an angle, with the vertex at the middle point. It conforms to `Identifiable` and `Sendable`.

### `init(id:pointA:vertex:pointB:label:)`

Creates an angle measurement.

```swift
public init(id: String = UUID().uuidString, pointA: SIMD3<Float>, vertex: SIMD3<Float>, pointB: SIMD3<Float>, label: String? = nil)
```

- **Parameters:**
  - `id` — unique identifier (default: UUID string).
  - `pointA` — first arm endpoint.
  - `vertex` — the angle vertex (corner point).
  - `pointB` — second arm endpoint.
  - `label` — optional text override; if `nil`, the computed degrees are used.
- **Example:**
  ```swift
  let m = AngleMeasurement(
      pointA: SIMD3(1, 0, 0),
      vertex: SIMD3(0, 0, 0),
      pointB: SIMD3(0, 1, 0)
  )
  print(m.degrees)  // 90.0
  ```

---

### Properties

#### `id`

Unique identifier for this measurement.

```swift
public let id: String
```

---

#### `pointA`

First arm endpoint.

```swift
public var pointA: SIMD3<Float>
```

---

#### `vertex`

Vertex point (where the angle is measured).

```swift
public var vertex: SIMD3<Float>
```

---

#### `pointB`

Second arm endpoint.

```swift
public var pointB: SIMD3<Float>
```

---

#### `label`

Optional label override for custom text display.

```swift
public var label: String?
```

If `nil`, the overlay displays the computed `degrees` value.

- **Example:**
  ```swift
  var m = AngleMeasurement(pointA: SIMD3(1, 0, 0), vertex: .zero, pointB: SIMD3(0, 1, 0))
  m.label = "45°"
  ```

---

### `degrees`

The computed angle in degrees.

```swift
public var degrees: Float { get }
```

Computed using `ProjectionUtility.angle(_:vertex:_)`, which calculates the angle formed by rays from the vertex to the two endpoints. Returns a value in the range `[0, 180]`.

- **Returns:** Angle in degrees.
- **Example:**
  ```swift
  let m = AngleMeasurement(
      pointA: SIMD3(1, 0, 0),
      vertex: .zero,
      pointB: SIMD3(0, 1, 0)
  )
  print(m.degrees)  // ~90.0
  ```

---

## RadiusMeasurement

`RadiusMeasurement` records the center and an edge point of a circular arc or circle, optionally displaying as diameter. It conforms to `Identifiable` and `Sendable`.

### `init(id:center:edgePoint:showDiameter:label:)`

Creates a radius or diameter measurement.

```swift
public init(id: String = UUID().uuidString, center: SIMD3<Float>, edgePoint: SIMD3<Float>, showDiameter: Bool = false, label: String? = nil)
```

- **Parameters:**
  - `id` — unique identifier (default: UUID string).
  - `center` — center point of the circle/arc.
  - `edgePoint` — a point on the circle/arc edge.
  - `showDiameter` — if `true`, display diameter (2× radius); if `false`, display radius (default: `false`).
  - `label` — optional text override; if `nil`, the computed radius or diameter is used.
- **Example:**
  ```swift
  let m = RadiusMeasurement(center: .zero, edgePoint: SIMD3(5, 0, 0))
  print(m.radius)     // 5.0
  print(m.diameter)   // 10.0
  ```

---

### Properties

#### `id`

Unique identifier for this measurement.

```swift
public let id: String
```

---

#### `center`

Center point of the circle/arc.

```swift
public var center: SIMD3<Float>
```

---

#### `edgePoint`

A point on the circle/arc edge.

```swift
public var edgePoint: SIMD3<Float>
```

---

#### `showDiameter`

Whether to display as diameter (`true`) or radius (`false`).

```swift
public var showDiameter: Bool
```

- **Example:**
  ```swift
  var m = RadiusMeasurement(center: .zero, edgePoint: SIMD3(10, 0, 0))
  m.showDiameter = true  // display as "Diameter: 20"
  ```

---

#### `label`

Optional label override for custom text display.

```swift
public var label: String?
```

If `nil`, the overlay displays either the computed `radius` or `diameter` (controlled by `showDiameter`).

- **Example:**
  ```swift
  var m = RadiusMeasurement(center: .zero, edgePoint: SIMD3(25, 0, 0))
  m.label = "R25"
  ```

---

### `radius`

The computed radius (distance from center to edgePoint).

```swift
public var radius: Float { get }
```

Computed as `simd_length(edgePoint - center)`.

- **Returns:** Radius in world units.
- **Example:**
  ```swift
  let m = RadiusMeasurement(center: .zero, edgePoint: SIMD3(3, 4, 0))
  print(m.radius)  // 5.0
  ```

---

### `diameter`

The computed diameter (2× radius).

```swift
public var diameter: Float { get }
```

Computed as `radius * 2.0`.

- **Returns:** Diameter in world units.
- **Example:**
  ```swift
  let m = RadiusMeasurement(center: .zero, edgePoint: SIMD3(5, 0, 0))
  print(m.diameter)  // 10.0
  ```

---

## MeasurementMode

`MeasurementMode` is an enum that controls which measurement tool is active. It conforms to `Sendable` and `Equatable`, enabling state management in `ViewportController`.

### Cases

#### `case none`

No measurement tool active; measurements cannot be added.

```swift
public enum MeasurementMode: Sendable, Equatable {
    case none
}
```

---

#### `case distance`

Measuring point-to-point distance (accumulates 2 points).

```swift
public enum MeasurementMode: Sendable, Equatable {
    case distance
}
```

---

#### `case angle`

Measuring angle between three points (accumulates 3 points: pointA, vertex, pointB).

```swift
public enum MeasurementMode: Sendable, Equatable {
    case angle
}
```

---

#### `case radius`

Measuring radius or diameter (accumulates 2 points: center, edgePoint).

```swift
public enum MeasurementMode: Sendable, Equatable {
    case radius
}
```

---

### Usage Example

```swift
@MainActor
class ViewportController: ObservableObject {
    @Published var measurementMode: MeasurementMode = .none
    
    func addMeasurementPoint(_ point: SIMD3<Float>) {
        switch measurementMode {
        case .none:
            break
        case .distance:
            // accumulate point; create DistanceMeasurement when 2 points collected
            break
        case .angle:
            // accumulate point; create AngleMeasurement when 3 points collected
            break
        case .radius:
            // accumulate point; create RadiusMeasurement when 2 points collected
            break
        }
    }
}
```

---
