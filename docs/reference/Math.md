---
title: Math
parent: API Reference
---

# Math

Spatial primitives for 3D viewport operations: axis-aligned bounding boxes, view-frustum culling, and ray-casting. These types provide geometric utilities for scene bounds, frustum intersection tests, and per-body visibility culling (issue #42). Ray-casting support for picking is documented on the [Picking](Picking.md) reference page — see `Ray` for screen-to-world ray construction.

## Topics

- [BoundingBox](#boundingbox) · [Frustum](#frustum)

---

## BoundingBox

`BoundingBox` is an axis-aligned bounding box (AABB) value type defined by minimum and maximum corners. It supports union operations, diagonal measurement, and transformation by 4×4 matrices. When combined with `Frustum`, it enables per-body frustum culling to skip out-of-view geometry at render time.

---

### `BoundingBox.init(min:max:)`

Creates a bounding box from minimum and maximum corners.

```swift
public init(min: SIMD3<Float>, max: SIMD3<Float>)
```

- **Parameters:** `min` — lower corner; `max` — upper corner.
- **Example:**
  ```swift
  let box = BoundingBox(
      min: SIMD3(0, 0, 0),
      max: SIMD3(10, 10, 10)
  )
  ```

---

## Corners

### `min`

The minimum corner of the box.

```swift
public var min: SIMD3<Float>
```

- **Example:**
  ```swift
  print(box.min)  // e.g., SIMD3(0, 0, 0)
  ```

---

### `max`

The maximum corner of the box.

```swift
public var max: SIMD3<Float>
```

- **Example:**
  ```swift
  print(box.max)  // e.g., SIMD3(10, 10, 10)
  ```

---

## Derived Properties

### `center`

Center point of the box.

```swift
public var center: SIMD3<Float> { get }
```

Computed as `(min + max) * 0.5`.

- **Example:**
  ```swift
  let midpoint = box.center  // SIMD3(5, 5, 5)
  ```

---

### `size`

Size along each axis.

```swift
public var size: SIMD3<Float> { get }
```

Computed as `max - min`.

- **Example:**
  ```swift
  let dimensions = box.size  // SIMD3(10, 10, 10)
  ```

---

### `diagonalLength`

Length of the space diagonal.

```swift
public var diagonalLength: Float { get }
```

Computed as `simd_length(size)`.

- **Example:**
  ```swift
  let radius = box.diagonalLength * 0.5  // half-diagonal for sphere fit
  ```

---

## Operations

### `union(_:)`

Returns the smallest box enclosing both `self` and `other`.

```swift
public func union(_ other: BoundingBox) -> BoundingBox
```

Useful for combining scene bounds or merging multiple body AABBs.

- **Parameters:** `other` — the box to union with.
- **Returns:** A new `BoundingBox` with `min` = component-wise min and `max` = component-wise max.
- **Example:**
  ```swift
  let box1 = BoundingBox(min: SIMD3(0, 0, 0), max: SIMD3(5, 5, 5))
  let box2 = BoundingBox(min: SIMD3(3, 3, 3), max: SIMD3(8, 8, 8))
  let combined = box1.union(box2)
  // combined.min = (0, 0, 0), combined.max = (8, 8, 8)
  ```

---

### `transformed(by:)`

The world-space AABB enclosing this box after applying a 4×4 transformation.

```swift
public func transformed(by transform: simd_float4x4) -> BoundingBox
```

Transforms all eight corners and takes their extent. Returns `self` unchanged for an identity transform (the common case) without work.

- **Parameters:** `transform` — a column-major 4×4 transformation matrix (translation, rotation, scale).
- **Returns:** A new `BoundingBox` with transformed extent.
- **Example:**
  ```swift
  var tx = matrix_identity_float4x4
  tx.columns.3 = SIMD4(10, 0, 0, 1)  // translate by (10, 0, 0)
  let movedBox = box.transformed(by: tx)
  // movedBox.min ≈ SIMD3(10, 0, 0), movedBox.max ≈ SIMD3(20, 10, 10)
  ```

---

## Frustum

`Frustum` represents the six planes of a view-projection frustum, extracted from a view-projection matrix. Each plane is stored with its normal pointing **inward**; a point is inside the view when it satisfies all six half-space tests. Frustums are used for per-body visibility culling: if a body's AABB lies entirely outside any frustum plane, it can be skipped during rendering (issue #42).

Plane storage uses the Gribb–Hartmann method with Metal's `[0, 1]` clip-space depth convention (near plane = row 2, not row 3 + row 2 as in traditional OpenGL).

---

### `Frustum.init(viewProjection:)`

Extracts the six frustum planes from a view-projection matrix.

```swift
public init(viewProjection m: simd_float4x4)
```

Decomposes the matrix into six half-space planes (left, right, bottom, top, near, far) and normalizes each normal vector. The normals point **inward** so that a world point `p` is inside the plane when `dot(normal, p) + d >= 0`.

- **Parameters:** `m` — a column-major 4×4 view-projection matrix (typically `projectionMatrix * viewMatrix` from a camera).
- **Example:**
  ```swift
  let camera = Camera()
  camera.eye = SIMD3(0, -100, 50)
  camera.center = SIMD3(0, 0, 0)
  
  let viewProj = camera.projectionMatrix * camera.viewMatrix
  let frustum = Frustum(viewProjection: viewProj)
  ```

---

### `planes`

The six normalized frustum planes.

```swift
public let planes: [SIMD4<Float>]
```

Each element is `(a, b, c, d)` representing the half-space `ax + by + cz + d >= 0`. The planes are stored in order: left, right, bottom, top, near, far.

- **Example:**
  ```swift
  let frustum = Frustum(viewProjection: viewProj)
  for (i, plane) in frustum.planes.enumerated() {
      let normal = SIMD3<Float>(plane.x, plane.y, plane.z)
      print("Plane \(i) normal: \(normal), d: \(plane.w)")
  }
  ```

---

## Intersection Tests

### `intersects(_:)`

Tests whether an axis-aligned bounding box intersects the view frustum.

```swift
public func intersects(_ box: BoundingBox) -> Bool
```

Returns `false` only when `box` lies entirely outside at least one plane (i.e. it is safe to cull). Returns `true` for a box that straddles any plane (conservative: may include false positives, but never false negatives).

Uses the "p-vertex" technique: for each plane, selects the AABB corner furthest along the plane normal, tests it against the half-space, and returns `false` immediately if it's outside any plane.

- **Parameters:** `box` — the axis-aligned bounding box to test.
- **Returns:** `true` if the box intersects or is inside the frustum; `false` if entirely outside (safe to cull).
- **Example:**
  ```swift
  let viewProj = camera.projectionMatrix * camera.viewMatrix
  let frustum = Frustum(viewProjection: viewProj)
  
  for body in bodies {
      if frustum.intersects(body.boundingBox) {
          // Render the body
          renderBody(body)
      } else {
          // Skip this body — it's completely off-screen
      }
  }
  ```

---
