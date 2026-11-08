---
title: Picking & Selection
parent: API Reference
---

# Picking & Selection

OCCTSwiftViewport provides two complementary picking paths. The **GPU pick path** resolves a single primitive per pixel from a dedicated RG32Uint pick-ID texture rendered each frame; it is fast and automatic, delivering a `PickResult` to `ViewportController.pickResult`. The **CPU raycast path** (`SceneRaycast`) performs broadphase AABB culling followed by Möller–Trumbore triangle intersection; it is distance-aware and useful when you need the world-space hit point independently of the GPU readback.

`PickResultFilter` sits on top of the GPU path as a composable predicate that accepts or rejects a decoded `PickResult` before it reaches your code. `Ray` and `ProjectionUtility` are shared utilities used by both paths and by measurement code.

## Topics

- [PrimitiveKind](#primitivekind) · [PickLayer](#picklayer) · [PickResult](#pickresult) · [Display mode and pick content](#display-mode-and-pick-content) · [PickResultFilter](#pickresultfilter) · [RaycastHit](#raycasthit) · [SceneRaycast](#sceneraycast) · [Ray](#ray) · [ProjectionUtility](#projectionutility)

---

## PrimitiveKind

```swift
public enum PrimitiveKind: UInt8, Sendable, Hashable
```

The sub-shape kind that a GPU pick resolves to. Encoded into bits 30–31 of the G channel of the RG32Uint pick texture so that a single texture readback disambiguates the kind without a second pass.

| Case | Raw value | Meaning |
|------|-----------|---------|
| `.face` | `0` | A mesh triangle (face pick) |
| `.edge` | `1` | A wireframe line segment, or an analytic arc segment |
| `.vertex` | `2` | A point-cloud point or vertex sprite |

**Note:** A body that contains both `edges` and `arcs` reports `.edge` for both; callers must inspect `triangleIndex` to determine whether it indexes into `edges` or `arcs`.

### Pick footprints

How much of the pick texture each primitive covers, in drawable pixels:

| Primitive | Footprint |
|-----------|-----------|
| Face | The triangle's own pixels. |
| Edge, arc | With `EdgeLineConfiguration.useQuadExpansion` on (the default): a band as wide as the drawn edge, at least 1 pt (2 px on a 2× display). Dash gaps are pickable too. With it off: a 1 px line, like the drawn one. |
| Vertex | An 8 × 8 pt square (16 × 16 px on a 2× display), centred on the vertex. |

Only bodies with `edgeIndices` set are edge-pickable; arcs are always pickable. A body's `edgeDrawRange` limits this to the segments it shows: the others are not written to the pick buffer, and the segments inside it report their absolute index. `PickingConfiguration.pickRadius` adds to these footprints: it widens the square read around the cursor and does not change what is drawn into the pick texture.

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

Set per body via `ViewportBody.pickLayer`. The widget layer is intended for manipulator widgets (e.g. OCCTSwiftAIS gizmos) whose picks should not enter the user selection stream. A `PickResultFilter` assigned to `ViewportController.selectionFilter` only gates the `.userGeometry` stream; widget-layer picks bypass it entirely.

---

## PickResult

```swift
public struct PickResult: Sendable, Equatable
```

The decoded result of a single GPU pick operation. Produced by `ViewportController` after each gesture and published on `pickResult` (user geometry) or `widgetPickResult` (widget layer).

### Bit layout

The pick texture is **RG32Uint**: one texel per pixel, two 32-bit channels. The renderer clears it to `0xFFFF_FFFF` in both channels (no hit) and each pick fragment writes:

```
R (bits  0–31 of pickValue) : objectIndex  (32 bits: draw-order body index; 0xFFFF_FFFF = no object)
G (bits 32–63 of pickValue) : bits  0–29 primitiveID (30 bits: triangle/segment/point index within body)
                              bits 30–31 kind        ( 2 bits: 0=face, 1=edge, 2=vertex)
```

The CPU keeps the texel as one `UInt64`, `pickValue = G << 32 | R` (Metal lays the texel out R then G, so a little-endian `UInt64` load of it is exactly that). `PickResult.pickValue` is that value, and `init?(pickValue:indexMap:layerMap:)` decodes it.

For face picks the primitive ID is always the **input triangle index**, on every rendering quality: the standard pipeline uses `[[primitive_id]]`, the tessellated pipeline (`.enhanced`) uses the patch ID (one PN patch per input triangle), and the mesh-shader pipeline (`.maximum` on Apple9+ GPUs) passes the global triangle index as per-primitive data. Before v1.2.3 the tessellated path reported the B-Rep face index and the mesh-shader path a meshlet-local index (0–63).

### Limits

| Limit | Value |
|-------|-------|
| `maxPickableBodies` | 4,294,967,295 visible bodies per frame, counted in draw order (object index `0xFFFF_FFFF` is reserved for "no object"). |
| `maxPrimitivesPerKind` | 1,073,741,824 (2³⁰) triangles, edge segments (or arcs), or points per body. |

Both are far beyond what the renderer can hold, so `triangleIndex` is always the exact primitive index: map it through `faceIndices`, `edgeIndices` or `vertexIndices` directly, on any body, from a tap, a `performPick` call or a region pick.

**History.** Through v1.3.x the target was R32Uint (`objectIndex (16) | primitiveID (14) << 16 | kind (2) << 30`), which capped a frame at 65,536 pickable bodies and a body at 16,384 primitives per kind. A body past the primitive limit reported `index % 16_384` with `isPrimitiveIndexAmbiguous == true`, and only tapped faces were resolved (by a CPU ray test). Edge, vertex and region picks stayed ambiguous, and bodies past 65,535 could not be picked at all. Issue #160 removed all of that. `isPrimitiveIndexAmbiguous`, `resolveWrappedTriangleIndex(_:ray:)` and the 32-bit `rawValue` API remain as deprecated shims; see below.

### Cost

The pick target is twice as wide as it was:

| Drawable | R32Uint (before) | RG32Uint (now) |
|----------|------------------|----------------|
| 1920 × 1080 | 8.3 MB | 16.6 MB |
| 3840 × 2160 | 33.2 MB | 66.4 MB |

It is a `.private` texture rendered in its own 1× pass (no MSAA), next to a `depth32Float` attachment of the same size, so the pick pass's tile (imageblock) footprint is 8 bytes per pixel for its single color attachment (4 before), well inside the per-pixel render-target budget of every Apple GPU family. Writing it costs one extra 4-byte store per pixel of pick-pass overdraw, and a single-pixel pick reads back 8 bytes instead of 4. Region and neighborhood readbacks double the same way (rows are padded to 256 bytes, so a 64-pixel-wide row is 512 bytes, not 256). Picking is off by default, and none of this is allocated or drawn until `PickingConfiguration.isEnabled` is set. Measured on an Apple Silicon Mac at 2048 × 2048 with 40 spheres, the whole pick pass adds roughly 2–4 ms per frame, and the move from R32Uint to RG32Uint changed it by about 1 ms, within run-to-run noise.

### Properties

#### `static let noHit: UInt64`

The texel (`0xFFFF_FFFF_FFFF_FFFF`) the pick pass clears to: pixels with no geometry, non-pickable bodies, or a body whose object index is the reserved `0xFFFF_FFFF`. `init?(pickValue:indexMap:layerMap:)` returns `nil` for it, and for any texel whose R channel is `0xFFFF_FFFF`.

#### `static let sentinel: UInt32` *(deprecated)*

The pre-#160 R32Uint no-hit value, `0xFFFF_FFFF`. Use `noHit`.

#### `static let maxPickableBodies: Int`

`4_294_967_295`. Number of visible bodies, in draw order, that receive a pick ID each frame. See [Limits](#limits).

#### `static let maxPrimitivesPerKind: Int`

`1_073_741_824`. Number of distinct primitive indices per kind that the 30-bit primitive field can carry. See [Limits](#limits).

#### `let bodyID: String`

The `id` string of the picked `ViewportBody`.

#### `let bodyIndex: Int`

Zero-based index of the body in draw order. Corresponds to `objectIndex` (the R channel) in the bit layout.

#### `let triangleIndex: Int`

The primitive index within the body, interpreted by `kind`:
- `.face`: triangle index into the body's index buffer (`indices[triangleIndex * 3]…`)
- `.edge`: line-segment index into `edges` (or `arcs`)
- `.vertex`: point index into `vertices`

The name is preserved for historical compatibility; it is semantically a *primitive* index. It is always the exact index, however many primitives the body has.

#### `var isPrimitiveIndexAmbiguous: Bool` *(deprecated)*

Always `false` for a result decoded from the RG32Uint pick texture. Before #160 it flagged an index that had wrapped modulo 16,384. It can be `true` only for a result built by the deprecated `init(rawValue:...)` with an `ambiguousKinds` map.

#### `let kind: PrimitiveKind`

The sub-shape kind of the picked primitive.

#### `let pickValue: UInt64`

The raw texel read from the GPU pick texture: `G << 32 | R`. See [Bit layout](#bit-layout).

#### `var rawValue: UInt32` *(deprecated)*

What the pre-#160 R32Uint target would have held for this pick, packed as `objectIndex (16) | primitiveID (14) << 16 | kind (2) << 30`. Lossy past 65,535 bodies or 16,383 primitives, where it wraps. Use `pickValue`.

#### `let pickLayer: PickLayer`

The pick layer the body belongs to, as recorded in the layer map at the time of the pick.

### Initializers

```swift
public init?(
    pickValue: UInt64,
    indexMap: [Int: String],
    layerMap: [String: PickLayer] = [:]
)
```

Decodes a pick texel. Returns `nil` when the object index (R) is `0xFFFF_FFFF` (the `noHit` texel), when it is absent from `indexMap`, or when the encoded kind bits do not match a valid `PrimitiveKind` case. Bodies absent from `layerMap` default to `.userGeometry`.

```swift
@available(*, deprecated)
public init?(
    rawValue: UInt32,
    indexMap: [Int: String],
    layerMap: [String: PickLayer] = [:],
    ambiguousKinds: [String: Set<PrimitiveKind>] = [:]
)
```

Decodes a value in the pre-#160 R32Uint layout. The renderer no longer produces that layout, but the initializer keeps working for code that builds legacy values: the result carries the equivalent wide `pickValue`, and a pick of a kind listed for its body in `ambiguousKinds` still reports `isPrimitiveIndexAmbiguous == true`.

**Example: subscribing to face picks**

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

## Display mode and pick content

The GPU pick pass writes only what the current `DisplayMode` shows, so geometry the user can't see never wins a pick:

| Content | Written to the pick buffer when |
|---|---|
| Faces (`.face`) | `displayMode.showsSurfaces`: every mode except `.wireframe` |
| Edges (`.edge`, including analytic arcs) | `displayMode.drawsEdges(bodyHasMesh:)`: `.wireframe`, `.shadedWithEdges` and `.xray`, plus edge-only bodies in every mode |
| Vertices (`.vertex`) | always (vertex sprites are never drawn, so no mode hides them) |
| Overlay-layer bodies | as drawn: faces in every mode, edges and arcs by the rule above, vertices always, all over the geometry (#170) |

| Mode | Faces | Edges (bodies with a mesh) |
|---|:---:|:---:|
| `.wireframe` | — | ✓ |
| `.shaded`, `.flat`, `.unlit`, `.rendered` | ✓ | — |
| `.shadedWithEdges` | ✓ | ✓ |
| `.xray` | ✓ | ✓ |

`.xray` keeps surfaces pickable even though they are see-through: the nearest surface under the cursor wins, as in `.shaded`, and edges co-planar with it win the depth tie. Edges and faces behind that nearest surface stay unpickable, although they show through it.

A geometry-layer body's polyline `edges` are pickable only when it sets `edgeIndices` (its `arcs` always are; an overlay body's edges always are). In `.wireframe`, where faces are not pickable, a body with no `edgeIndices`, `arcs` or `vertices` therefore can't be picked at all. Set `edgeIndices` on bodies you want selectable in wireframe.

Before issue #136, faces were written in `.wireframe` and edges in `.shaded`, so a click could select an invisible face or edge.

---

## PickResultFilter

```swift
public struct PickResultFilter: Sendable
```

A composable predicate over `PickResult`. Assign to `ViewportController.selectionFilter` to constrain what the user-geometry pick stream surfaces. A rejected pick is treated as a miss.

Widget-layer picks bypass this filter; they are handled separately via `widgetPickResult`.

> **Renamed in #111.** This type was called `SelectionFilter` until v1.1.30. It filters a `PickResult`, not a resolved selection, and OCCTSwiftAIS has its own unrelated `SelectionFilter` protocol that runs *after* topology resolution and reasons about the actual face or edge; the two were never implementations of each other. `SelectionFilter` remains as a deprecated typealias, so existing code keeps compiling.

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

#### `static let all: PickResultFilter`

Accepts every result (the default when no filter is set).

#### `static let nothing: PickResultFilter`

Rejects every result.

#### `static let faces: PickResultFilter`

Accepts `.face` picks only. Equivalent to `.kind(.face)`.

#### `static let edges: PickResultFilter`

Accepts `.edge` picks only. Equivalent to `.kind(.edge)`.

#### `static let vertices: PickResultFilter`

Accepts `.vertex` picks only. Equivalent to `.kind(.vertex)`.

#### `static func kind(_ kind: PrimitiveKind) -> PickResultFilter`

Accepts results whose `kind` matches the given value.

#### `static func kinds(_ kinds: Set<PrimitiveKind>) -> PickResultFilter`

Accepts results whose `kind` is contained in the set.

#### `static func layer(_ layer: PickLayer) -> PickResultFilter`

Accepts results belonging to the given pick layer.

#### `static func bodyIDs(_ ids: Set<String>) -> PickResultFilter`

Accepts results whose `bodyID` is in the allow-list.

```swift
controller.selectionFilter = .bodyIDs(["part-A", "part-B"])
```

#### `static func excludingBodyIDs(_ ids: Set<String>) -> PickResultFilter`

Rejects results whose `bodyID` is in the deny-list.

```swift
// Exclude a construction grid from picks
controller.selectionFilter = .excludingBodyIDs(["construction-grid"])
```

#### `static func bodyIndices(_ indices: Set<Int>) -> PickResultFilter`

Accepts results whose draw-order `bodyIndex` is in the given set.

### Composition

#### `func and(_ other: PickResultFilter) -> PickResultFilter`

Logical AND, so both filters must accept.

#### `func or(_ other: PickResultFilter) -> PickResultFilter`

Logical OR, so either filter must accept.

#### `var negated: PickResultFilter`

Logical NOT, so acceptance is inverted.

#### `static func all(of filters: [PickResultFilter]) -> PickResultFilter`

AND-combines a collection of filters. An empty collection accepts everything.

#### `static func any(of filters: [PickResultFilter]) -> PickResultFilter`

OR-combines a collection of filters. An empty collection rejects everything.

**Example: compound filter**

```swift
// Accept edges and vertices, but never on the "datum-plane" body
controller.selectionFilter = .edges
    .or(.vertices)
    .and(.excludingBodyIDs(["datum-plane"]))
```

**Example: custom predicate**

```swift
// Accept only faces whose primitive index is even
controller.selectionFilter = PickResultFilter { result in
    result.kind == .face && result.triangleIndex.isMultiple(of: 2)
}
```

---

## RaycastHit

```swift
public struct RaycastHit: Sendable
```

The result of a successful CPU raycast. Returned by `SceneRaycast.cast(ray:bodies:boundingBoxCache:clipPlanes:includeWidgets:includeNonPickable:)` and `SceneRaycast.cast(ray:bodies:clipPlanes:includeWidgets:includeNonPickable:)`.

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

1. **Broadphase**: ray-AABB intersection (slab method) for each visible body; bodies whose AABBs are missed or farther than the current best hit are skipped.
2. **Narrowphase**: Möller-Trumbore triangle intersection on each surviving body, testing every triangle in the index buffer.

The result is the nearest hit across all bodies.

### `static func cast(ray:bodies:boundingBoxCache:clipPlanes:includeWidgets:includeNonPickable:) -> RaycastHit?`

```swift
public static func cast(
    ray: Ray,
    bodies: [ViewportBody],
    boundingBoxCache: [String: BoundingBox],
    clipPlanes: [ClipPlane] = [],
    includeWidgets: Bool = false,
    includeNonPickable: Bool = false
) -> RaycastHit?
```

Casts `ray` against all visible bodies, returning the nearest `RaycastHit` or `nil` on a complete miss. Non-visible bodies (`body.isVisible == false`) and bodies absent from `boundingBoxCache` are skipped.

**Widgets and non-pickable bodies.** By default the cast also skips widgets, meaning bodies on the `RenderLayer.overlay` render layer or the `PickLayer.widget` pick layer (gizmos, datum planes), and bodies with `isPickable == false`, which the GPU pick pass never reports. The dynamic pivot and double-tap/double-click focus-on-point use these defaults, so they never land on a widget. Focus-on-point shares the dynamic pivot's bounding-box cache, so it does not rescan geometry on each tap. Pass `includeWidgets: true` or `includeNonPickable: true` to test those bodies as well.

Each body is tested in its own local space: the ray is mapped through the inverse of `body.transform`, and `RaycastHit.point` / `distance` are returned in world space, so moved, rotated and scaled bodies are hit where they are drawn. Bodies with a non-invertible transform are skipped.

Triangles are read from the same positions the renderer draws: `meshPositions` for a direct-mesh body (`usesDirectMesh`), `vertexData` otherwise. Triangles with out-of-range indices, and a trailing partial triple, are skipped rather than trapping.

**Clip planes.** Pass the section planes in effect (typically `controller.clipPlanes`) and hits on geometry they remove are skipped, with the search continuing behind them. This matches the GPU pick pass: only the enabled planes the renderer applies count (the first `ClipPlane.maxActivePlanes`), and a world-space hit `p` is discarded when `dot(normal, p) + distance < 0` for any of them. The dynamic pivot passes `ViewportController.clipPlanes` automatically.

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `ray` | `Ray` | The world-space ray to cast |
| `bodies` | `[ViewportBody]` | Scene bodies to test |
| `boundingBoxCache` | `[String: BoundingBox]` | Pre-computed **local-space** bounding boxes keyed by body ID (`ViewportBody.boundingBox`, before `transform`). Build it yourself and keep it while the bodies' `generation` values are unchanged; `ViewportController` does not expose one. |
| `clipPlanes` | `[ClipPlane]` | Section planes to honour. Default `[]` |
| `includeWidgets` | `Bool` | Also test `.overlay` render-layer and `.widget` pick-layer bodies. Default `false` |
| `includeNonPickable` | `Bool` | Also test bodies with `isPickable == false`. Default `false` |

### `static func cast(ray:bodies:clipPlanes:includeWidgets:includeNonPickable:) -> RaycastHit?`

```swift
public static func cast(
    ray: Ray,
    bodies: [ViewportBody],
    clipPlanes: [ClipPlane] = [],
    includeWidgets: Bool = false,
    includeNonPickable: Bool = false
) -> RaycastHit?
```

Convenience for one-off casts: builds the bounding-box cache from `ViewportBody.boundingBox` for every body the cast will test (skipping the same hidden, widget and non-pickable bodies), then calls the overload above. It walks each body's geometry to do so, so code that casts repeatedly against the same bodies should keep its own cache.

**Example: cast a ray through a screen tap**

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
    // Local-space boxes keyed by body ID. Cache this across casts if the bodies don't change.
    let cache = Dictionary(
        uniqueKeysWithValues: bodies.compactMap { b in b.boundingBox.map { (b.id, $0) } })
    if let hit = SceneRaycast.cast(
        ray: ray,
        bodies: bodies,
        boundingBoxCache: cache,
        clipPlanes: controller.clipPlanes
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

#### `static func fromCamera(ndc:cameraState:aspectRatio:sceneBounds:) -> Ray`

```swift
public static func fromCamera(
    ndc: SIMD2<Float>,
    cameraState: CameraState,
    aspectRatio: Float,
    sceneBounds: BoundingBox? = nil
) -> Ray
```

Constructs a world-space ray passing through a point expressed in normalized device coordinates. NDC convention: `(-1, -1)` = bottom-left, `(1, 1)` = top-right, `(0, 0)` = center.

Handles both perspective and orthographic projections:
- **Perspective**: origin at `cameraState.position`; direction computed from field-of-view, aspect ratio, and NDC offset.
- **Orthographic**: origin offset from the eye by the NDC-scaled half-extents; direction parallel to `viewDirection`. With `sceneBounds`, the eye is the one `CameraState.placingOrthographicEye(inFrontOf:)` places in front of them, so the ray starts in front of the whole scene and geometry between the eye and the camera's side of the scene, or behind the eye, is not missed. Without, it starts at `cameraState.position` (issue #211).

The library's own rays (the dynamic pivot, focus-on-point, measurement picks and wrapped face-pick resolution) all pass the scene's or the picked body's bounds. A ray that starts in front of the scene finds what is drawn because `CameraController` keeps the orthographic eye in front of the scene too, when it has a `sceneBoundsProvider`; starting further back would pick geometry the near plane clips.

| Parameter | Type | Description |
|-----------|------|-------------|
| `ndc` | `SIMD2<Float>` | Normalized device coordinates in `[-1, 1]` (x right, y up) |
| `cameraState` | `CameraState` | Current camera state |
| `aspectRatio` | `Float` | Viewport width / height |
| `sceneBounds` | `BoundingBox?` | World-space bounds an orthographic ray starts in front of; `nil` (default) starts it at the eye. Ignored in perspective |

#### `static func throughViewCenter(cameraState:aspectRatio:sceneBounds:) -> Ray`

```swift
public static func throughViewCenter(
    cameraState: CameraState,
    aspectRatio: Float,
    sceneBounds: BoundingBox? = nil
) -> Ray
```

Convenience, equivalent to `fromCamera(ndc: .zero, ...)`. Returns a ray through the exact view-space centre.

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

**Example: manual triangle test**

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

Projects a world-space point to a screen-space `CGPoint`. Returns `nil` if the point is behind the camera, decided by view-space depth: under a perspective matrix that is `clip.w ≤ 0.001`; under an orthographic one, where `w` is always 1, it is NDC z < 0, nearer than the near plane, which is how the renderer clips it. Before issue #208 only `w` was checked, so a point behind an orthographic camera was still projected, mirrored onto the view, and the measurement overlay drew it. The returned point uses a top-left origin with Y increasing downward (UIKit / AppKit window convention).

| Parameter | Type | Description |
|-----------|------|-------------|
| `point` | `SIMD3<Float>` | World-space position to project |
| `vpMatrix` | `simd_float4x4` | Combined view-projection matrix |
| `viewportSize` | `CGSize` | Viewport dimensions in points |

**Example:**

```swift
let state = controller.cameraState
let vpMatrix = state.projectionMatrix(aspectRatio: aspect) * state.viewMatrix
if let screenPt = ProjectionUtility.worldToScreen(
    point: hitPoint,
    vpMatrix: vpMatrix,
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

Projects a world-space point to normalized device coordinates `(x, y ∈ [-1, 1], z for depth)`. Returns `nil` when the point is behind the camera, by the same view-space depth test as `worldToScreen`. Useful when you need NDC before the final screen-space mapping (e.g. to pass back into `Ray.fromCamera`).

The measurement overlay and the headless measurement compositor draw segments (a distance's leader, an angle's arms, a radius) through an internal companion that cuts a segment where it crosses that same test, rather than dropping it when one end is culled. Only the ends in view get their markers, and a culled label anchor falls back to the middle of the visible part. An angle whose vertex is culled draws the visible parts of its arms without the arc and label (issue #211).

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
