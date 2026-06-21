---
title: Picking & Selection
parent: API Reference
---

# Picking & Selection

OCCTSwiftViewport provides two complementary picking paths. The **GPU pick path** resolves a single primitive per pixel from a dedicated R32Uint pick-ID texture rendered each frame; it is fast and automatic, delivering a `PickResult` to `ViewportController.pickResult`. The **CPU raycast path** (`SceneRaycast`) performs broadphase AABB culling followed by Möller–Trumbore triangle intersection; it is distance-aware and useful when you need the world-space hit point independently of the GPU readback.

`SelectionFilter` sits on top of the GPU path as a composable predicate that accepts or rejects a decoded `PickResult` before it reaches your code. `Ray` and `ProjectionUtility` are shared utilities used by both paths and by measurement code.

## Topics

- [PrimitiveKind](#primitivekind) · [PickLayer](#picklayer) · [PickResult](#pickresult) · [SelectionFilter](#selectionfilter) · [RaycastHit](#raycasthit) · [SceneRaycast](#sceneraycast) · [Ray](#ray) · [ProjectionUtility](#projectionutility)

---

## PrimitiveKind

```swift
public enum PrimitiveKind: UInt8, Sendable, Hashable
```

The sub-shape kind that a GPU pick resolves to. Encoded into bits 30–31 of the R32Uint pick-texture value so that a single texture readback disambiguates the kind without a second pass.

| Case | Raw value | Meaning |
|------|-----------|---------|
| `.face` | `0` | A mesh triangle (face pick) |
| `.edge` | `1` | A wireframe line segment, or an analytic arc segment |
| `.vertex` | `2` | A point-cloud point or vertex sprite |

**Note:** A body that contains both `edges` and `arcs` reports `.edge` for both; callers must inspect `triangleIndex` to determine whether it indexes into `edges` or `arcs`.

---

## PickLayer

```swift
public enum PickLayer: Hashable, Sendable
```

Defined in `Types/ViewportBody.swift`. Determines which published pick stream a body's pick results are delivered to.

| Case | Delivered to |
|------|-------------|
| `.userGeometry` | `ViewportController.pickResult` |
| `.widget` | `ViewportController.widgetPickResult` |

Set per body via `ViewportBody.pickLayer`. The widget layer is intended for manipulator widgets (e.g. OCCTSwiftAIS gizmos) whose picks should not enter the user selection stream. A `SelectionFilter` assigned to `ViewportController.selectionFilter` only gates the `.userGeometry` stream; widget-layer picks bypass it entirely.

---

## PickResult

```swift
public struct PickResult: Sendable, Equatable
```

The decoded result of a single GPU pick operation. Produced by `ViewportController` after each gesture and published on `pickResult` (user geometry) or `widgetPickResult` (widget layer).

### Bit layout

The raw R32Uint value from the pick texture encodes three fields:

```
bits  0–15 : objectIndex  (16 bits — draw-order body index)
bits 16–29 : primitiveID  (14 bits — triangle/segment/point index within body)
bits 30–31 : kind         ( 2 bits — 0=face, 1=edge, 2=vertex)
```

### Properties

#### `static let sentinel: UInt32`

The sentinel value (`0xFFFF_FFFF`) written to pixels that have no geometry or hit a non-pickable body. `init?(rawValue:indexMap:layerMap:)` returns `nil` for this value.

#### `let bodyID: String`

The `id` string of the picked `ViewportBody`.

#### `let bodyIndex: Int`

Zero-based index of the body in draw order. Corresponds to `objectIndex` in the bit layout.

#### `let triangleIndex: Int`

The primitive index within the body, interpreted by `kind`:
- `.face` — triangle index into the body's index buffer (`indices[triangleIndex * 3]…`)
- `.edge` — line-segment index into `edges` (or `arcs`)
- `.vertex` — point index into `vertices`

The name is preserved for historical compatibility; it is semantically a *primitive* index.

#### `let kind: PrimitiveKind`

The sub-shape kind of the picked primitive.

#### `let rawValue: UInt32`

The raw value read from the GPU pick buffer.

#### `let pickLayer: PickLayer`

The pick layer the body belongs to, as recorded in the layer map at the time of the pick.

### Initializer

```swift
public init?(
    rawValue: UInt32,
    indexMap: [Int: String],
    layerMap: [String: PickLayer] = [:]
) 
```

Decodes a raw pick-buffer value. Returns `nil` when `rawValue` equals `sentinel`, when the `objectIndex` is absent from `indexMap`, or when the encoded kind bits do not match a valid `PrimitiveKind` case. Bodies absent from `layerMap` default to `.userGeometry`.

**Example — subscribing to face picks:**

```swift
import Combine

var cancellable: AnyCancellable?

func observeFacePicks(controller: ViewportController) {
    cancellable = controller.$pickResult
        .compactMap { $0 }
        .filter { $0.kind == .face }
        .sink { result in
            print("Hit face \(result.triangleIndex) on body '\(result.bodyID)'")
        }
}
```

---

## SelectionFilter

```swift
public struct SelectionFilter: Sendable
```

A composable predicate over `PickResult`. Assign to `ViewportController.selectionFilter` to constrain what the user-geometry pick stream surfaces. A rejected pick is treated as a miss.

Widget-layer picks bypass this filter; they are handled separately via `widgetPickResult`.

### Custom initializer

```swift
public init(_ predicate: @escaping @Sendable (PickResult) -> Bool)
```

Wraps an arbitrary predicate. Prefer the built-in factories for common cases.

### Evaluation

#### `func matches(_ result: PickResult) -> Bool`

Returns `true` if `result` passes the filter.

#### `func callAsFunction(_ result: PickResult) -> Bool`

Allows calling a filter as a function: `filter(result)`.

### Built-in filters

#### `static let all: SelectionFilter`

Accepts every result (the default when no filter is set).

#### `static let nothing: SelectionFilter`

Rejects every result.

#### `static let faces: SelectionFilter`

Accepts `.face` picks only. Equivalent to `.kind(.face)`.

#### `static let edges: SelectionFilter`

Accepts `.edge` picks only. Equivalent to `.kind(.edge)`.

#### `static let vertices: SelectionFilter`

Accepts `.vertex` picks only. Equivalent to `.kind(.vertex)`.

#### `static func kind(_ kind: PrimitiveKind) -> SelectionFilter`

Accepts results whose `kind` matches the given value.

#### `static func kinds(_ kinds: Set<PrimitiveKind>) -> SelectionFilter`

Accepts results whose `kind` is contained in the set.

#### `static func layer(_ layer: PickLayer) -> SelectionFilter`

Accepts results belonging to the given pick layer.

#### `static func bodyIDs(_ ids: Set<String>) -> SelectionFilter`

Accepts results whose `bodyID` is in the allow-list.

```swift
controller.selectionFilter = .bodyIDs(["part-A", "part-B"])
```

#### `static func excludingBodyIDs(_ ids: Set<String>) -> SelectionFilter`

Rejects results whose `bodyID` is in the deny-list.

```swift
// Exclude a construction grid from picks
controller.selectionFilter = .excludingBodyIDs(["construction-grid"])
```

#### `static func bodyIndices(_ indices: Set<Int>) -> SelectionFilter`

Accepts results whose draw-order `bodyIndex` is in the given set.

### Composition

#### `func and(_ other: SelectionFilter) -> SelectionFilter`

Logical AND — both filters must accept.

#### `func or(_ other: SelectionFilter) -> SelectionFilter`

Logical OR — either filter must accept.

#### `var negated: SelectionFilter`

Logical NOT — inverts acceptance.

#### `static func all(of filters: [SelectionFilter]) -> SelectionFilter`

AND-combines a collection of filters. An empty collection accepts everything.

#### `static func any(of filters: [SelectionFilter]) -> SelectionFilter`

OR-combines a collection of filters. An empty collection rejects everything.

**Example — compound filter:**

```swift
// Accept edges and vertices, but never on the "datum-plane" body
controller.selectionFilter = .edges
    .or(.vertices)
    .and(.excludingBodyIDs(["datum-plane"]))
```

**Example — custom predicate:**

```swift
// Accept only faces whose primitive index is even
controller.selectionFilter = SelectionFilter { result in
    result.kind == .face && result.triangleIndex.isMultiple(of: 2)
}
```

---

## RaycastHit

```swift
public struct RaycastHit: Sendable
```

The result of a successful CPU raycast. Returned by `SceneRaycast.cast(ray:bodies:boundingBoxCache:)`.

### Properties

#### `let bodyID: String`

The `id` of the `ViewportBody` that was hit.

#### `let point: SIMD3<Float>`

World-space position of the intersection point, computed as `ray.origin + ray.direction * distance`.

#### `let distance: Float`

Signed distance along the ray from `ray.origin` to the hit point. Always positive (behind-camera hits are excluded).

---

## SceneRaycast

```swift
public enum SceneRaycast
```

CPU-side raycasting against an array of `ViewportBody` instances. Uses a two-phase strategy:

1. **Broadphase** — ray–AABB intersection (slab method) for each visible body; bodies whose AABBs are missed or farther than the current best hit are skipped.
2. **Narrowphase** — Möller–Trumbore triangle intersection on each surviving body, testing every triangle in the index buffer.

The result is the nearest hit across all bodies.

### `static func cast(...) -> RaycastHit?`

```swift
public static func cast(
    ray: Ray,
    bodies: [ViewportBody],
    boundingBoxCache: [String: BoundingBox]
) -> RaycastHit?
```

Casts `ray` against all visible bodies, returning the nearest `RaycastHit` or `nil` on a complete miss. Non-visible bodies (`body.isVisible == false`) and bodies absent from `boundingBoxCache` are skipped.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `ray` | `Ray` | The world-space ray to cast |
| `bodies` | `[ViewportBody]` | Scene bodies to test |
| `boundingBoxCache` | `[String: BoundingBox]` | Pre-computed bounding boxes keyed by body ID; typically sourced from `ViewportController` |

**Example — cast a ray through a screen tap:**

```swift
@MainActor
func handleTap(
    at screenPoint: CGPoint,
    controller: ViewportController,
    bodies: [ViewportBody],
    viewportSize: CGSize
) {
    let ndc = SIMD2<Float>(
        Float(screenPoint.x / viewportSize.width)  * 2 - 1,
        1 - Float(screenPoint.y / viewportSize.height) * 2
    )
    let aspectRatio = Float(viewportSize.width / viewportSize.height)
    let ray = Ray.fromCamera(
        ndc: ndc,
        cameraState: controller.cameraController.cameraState,
        aspectRatio: aspectRatio
    )
    if let hit = SceneRaycast.cast(
        ray: ray,
        bodies: bodies,
        boundingBoxCache: controller.boundingBoxCache
    ) {
        print("Hit '\(hit.bodyID)' at \(hit.point), distance \(hit.distance)")
    }
}
```

---

## Ray

```swift
public struct Ray: Sendable
```

A world-space ray with an origin and a normalized direction. Used by both the CPU raycast path and measurement hit-point computation.

### Stored properties

#### `var origin: SIMD3<Float>`

Ray origin in world space.

#### `var direction: SIMD3<Float>`

Normalized ray direction. The initializer calls `simd_normalize` on the supplied value.

### Initializer

```swift
public init(origin: SIMD3<Float>, direction: SIMD3<Float>)
```

`direction` is normalized on construction; you do not need to pre-normalize.

### Camera ray construction

#### `static func fromCamera(ndc:cameraState:aspectRatio:) -> Ray`

```swift
public static func fromCamera(
    ndc: SIMD2<Float>,
    cameraState: CameraState,
    aspectRatio: Float
) -> Ray
```

Constructs a world-space ray passing through a point expressed in normalized device coordinates. NDC convention: `(-1, -1)` = bottom-left, `(1, 1)` = top-right, `(0, 0)` = center.

Handles both perspective and orthographic projections:
- **Perspective** — origin at `cameraState.position`; direction computed from field-of-view, aspect ratio, and NDC offset.
- **Orthographic** — origin offset from `cameraState.position` by the NDC-scaled half-extents; direction parallel to `viewDirection`.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ndc` | `SIMD2<Float>` | Normalized device coordinates in `[-1, 1]` (x right, y up) |
| `cameraState` | `CameraState` | Current camera state |
| `aspectRatio` | `Float` | Viewport width / height |

#### `static func throughViewCenter(cameraState:aspectRatio:) -> Ray`

```swift
public static func throughViewCenter(
    cameraState: CameraState,
    aspectRatio: Float
) -> Ray
```

Convenience — equivalent to `fromCamera(ndc: .zero, ...)`. Returns a ray through the exact view-space centre.

### Intersection tests

#### `func intersects(_ box: BoundingBox) -> Float?`

```swift
public func intersects(_ box: BoundingBox) -> Float?
```

Ray–AABB intersection using the slab method. Returns the distance to the entry point, or `nil` on a miss. Returns `0` when the ray origin is inside the box. Used internally by `SceneRaycast` for broadphase culling.

#### `func intersectsTriangle(v0:v1:v2:) -> Float?`

```swift
public func intersectsTriangle(
    v0: SIMD3<Float>,
    v1: SIMD3<Float>,
    v2: SIMD3<Float>
) -> Float?
```

Ray–triangle intersection using the Möller–Trumbore algorithm. Returns the distance `t` along the ray to the intersection point, or `nil` on a miss (parallel, behind the ray, or outside the triangle). An `epsilon` of `1e-6` guards against degenerate triangles and back-face grazing.

**Example — manual triangle test:**

```swift
let ray = Ray(
    origin: SIMD3<Float>(0, 0, 5),
    direction: SIMD3<Float>(0, 0, -1)
)
let v0 = SIMD3<Float>(-1, -1, 0)
let v1 = SIMD3<Float>( 1, -1, 0)
let v2 = SIMD3<Float>( 0,  1, 0)

if let t = ray.intersectsTriangle(v0: v0, v1: v1, v2: v2) {
    let hitPoint = ray.origin + ray.direction * t  // (0, -0.333, 0) approx
    print("Hit at distance \(t)")
}
```

---

## ProjectionUtility

```swift
public enum ProjectionUtility
```

Stateless utility for converting between world space, NDC, and screen-space coordinates, and for computing common geometric measurements. All methods are `static`.

### `static func worldToScreen(point:vpMatrix:viewportSize:) -> CGPoint?`

```swift
public static func worldToScreen(
    point: SIMD3<Float>,
    vpMatrix: simd_float4x4,
    viewportSize: CGSize
) -> CGPoint?
```

Projects a world-space point to a screen-space `CGPoint`. Returns `nil` if the point is behind the camera (`clip.w ≤ 0.001`). The returned point uses a top-left origin with Y increasing downward (UIKit / AppKit window convention).

| Parameter | Type | Description |
|-----------|------|-------------|
| `point` | `SIMD3<Float>` | World-space position to project |
| `vpMatrix` | `simd_float4x4` | Combined view-projection matrix |
| `viewportSize` | `CGSize` | Viewport dimensions in points |

**Example:**

```swift
if let screenPt = ProjectionUtility.worldToScreen(
    point: hitPoint,
    vpMatrix: controller.viewProjectionMatrix,
    viewportSize: viewportSize
) {
    // Place a SwiftUI annotation overlay at screenPt
}
```

### `static func worldToNDC(point:vpMatrix:) -> SIMD3<Float>?`

```swift
public static func worldToNDC(
    point: SIMD3<Float>,
    vpMatrix: simd_float4x4
) -> SIMD3<Float>?
```

Projects a world-space point to normalized device coordinates `(x, y ∈ [-1, 1], z for depth)`. Returns `nil` when the point is behind the camera. Useful when you need NDC before the final screen-space mapping (e.g. to pass back into `Ray.fromCamera`).

### `static func distance(_:_:) -> Float`

```swift
public static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float
```

Euclidean distance between two world-space points. Wraps `simd_length(b - a)`.

### `static func angle(_:vertex:_:) -> Float`

```swift
public static func angle(
    _ a: SIMD3<Float>,
    vertex b: SIMD3<Float>,
    _ c: SIMD3<Float>
) -> Float
```

Angle in degrees at vertex `b` formed by the rays `b→a` and `b→c`. Returns a value in `[0°, 180°]`. Used by the tap-to-measure system when three points are accumulated for an angle measurement.

**Example:**

```swift
let angle = ProjectionUtility.angle(
    pointA,
    vertex: cornerPoint,
    pointC
)
print("\(angle)°")
```

### `static func midpoint(_:_:) -> SIMD3<Float>`

```swift
public static func midpoint(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float>
```

Returns `(a + b) * 0.5`. Used by the measurement overlay to place dimension labels at the midpoint of a measured segment.
