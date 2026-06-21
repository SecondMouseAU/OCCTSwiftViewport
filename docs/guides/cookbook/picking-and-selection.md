---
title: Picking & Selection
parent: Cookbook
nav_order: 6
---

# Picking & Selection

OCCTSwiftViewport resolves a tap or click through two complementary paths: a **GPU pick pass** that reads a single R32Uint texel to identify which body and primitive was hit, and a **CPU raycast** (`SceneRaycast`) that computes a precise world-space intersection point. Both paths are controlled from `ViewportController`.

---

## Enabling the GPU pick pass

Picking is off by default. Turn it on when you create your `ViewportConfiguration`:

```swift
var config = ViewportConfiguration.cad
config.pickingConfiguration = PickingConfiguration(isEnabled: true)

let controller = ViewportController(configuration: config)
```

The renderer allocates a second R32Uint color attachment only when picking is enabled, keeping the default render path lean.

---

## Reading a pick result

After a tap, the renderer reads the pick texture and populates `ViewportController.pickResult` (a `@Published` property). Subscribe with Combine or read it directly in SwiftUI:

```swift
// SwiftUI — react inside .onChange
MetalViewportView(controller: controller, bodies: bodies)
    .onChange(of: controller.pickResult) { _, result in
        guard let result else {
            // tap landed on background
            return
        }
        print("hit body:", result.bodyID)
        print("kind:", result.kind)          // .face / .edge / .vertex
        print("primitive index:", result.triangleIndex)
    }
```

`PickResult` fields:

| Property | Type | Meaning |
|---|---|---|
| `bodyID` | `String` | The `id` string of the picked `ViewportBody` |
| `bodyIndex` | `Int` | Zero-based draw-order index |
| `kind` | `PrimitiveKind` | `.face`, `.edge`, or `.vertex` |
| `triangleIndex` | `Int` | Primitive index within the body (triangle for face picks, segment for edge picks, point for vertex picks) |
| `pickLayer` | `PickLayer` | `.userGeometry` or `.widget` |
| `rawValue` | `UInt32` | Raw R32Uint value (bits 0–15: objectIndex; 16–29: primitiveID; 30–31: kind) |

`pickResult` carries `.userGeometry` picks. Widget-layer picks (manipulator handles, etc.) land separately in `widgetPickResult` and are never mixed into the selection stream.

### Callback alternative

If you prefer a callback over Combine, assign `onPick`:

```swift
controller.onPick = { result in
    if let result {
        highlightBody(id: result.bodyID)
    }
}
```

---

## Body-level selection

`ViewportController` maintains `selectedBodyIDs: Set<String>`, which the renderer uses to draw a highlight outline around selected bodies. Select programmatically or mirror a pick result:

```swift
// Single select
controller.selectBody("bracket", toggle: false)

// Multi-select (toggle mode)
controller.selectBody("bracket", toggle: true)

// Mirror GPU pick → body selection
controller.onPick = { result in
    guard let result else { return }
    controller.selectBody(result.bodyID, toggle: false)
}

// Clear
controller.deselectAll()
// or
controller.clearSelection()   // also clears pickResult
```

---

## SelectionFilter chains

A `SelectionFilter` is a composable predicate that runs on a decoded `PickResult` after the GPU pass. A result that fails the filter is treated as a miss — since the GPU resolves exactly one primitive per pixel, there is no fallback candidate.

Assign one to `ViewportController.selectionFilter`:

```swift
// Faces only
controller.selectionFilter = .faces

// Edges or vertices
controller.selectionFilter = .edges.or(.vertices)

// Faces, excluding a construction body
controller.selectionFilter = .faces.and(.excludingBodyIDs(["ground_plane"]))

// Custom predicate
controller.selectionFilter = SelectionFilter { result in
    result.kind == .face && result.bodyID.hasPrefix("solid_")
}

// Remove the filter (accept everything)
controller.selectionFilter = nil
```

Built-in factory filters:

| Filter | Accepts |
|---|---|
| `.all` | Everything |
| `.nothing` | Nothing |
| `.faces` | `.face` primitives |
| `.edges` | `.edge` primitives |
| `.vertices` | `.vertex` primitives |
| `.kind(_:)` | Exact `PrimitiveKind` |
| `.kinds(_:)` | Set of `PrimitiveKind` |
| `.bodyIDs(_:)` | Allow-listed body IDs |
| `.excludingBodyIDs(_:)` | Deny-listed body IDs |
| `.bodyIndices(_:)` | Allow-listed draw-order indices |
| `.layer(_:)` | Specific `PickLayer` |

Compose with `.and(_:)`, `.or(_:)`, `.negated`, `SelectionFilter.all(of:)`, and `SelectionFilter.any(of:)`.

---

## Excluding bodies from picks with `isPickable`

Set `ViewportBody.isPickable = false` to keep a body visible but invisible to the GPU pick pass. This is the right way to handle datum planes, grid meshes, or any decorative geometry that should never steal a tap from real parts:

```swift
let groundPlane = ViewportBody(
    id: "ground",
    vertexData: planeVerts,
    indices: planeIndices,
    isPickable: false       // drawn, but excluded from pick texture
)
```

The body's `objectIndex` still advances in the draw order so other indices remain stable. You do not need a `SelectionFilter` as well — `isPickable: false` is cheaper because it skips the pick sub-passes entirely.

---

## CPU raycast with `SceneRaycast`

The GPU pick pass identifies *which* body and primitive was hit but carries no world-space position. Use `SceneRaycast` when you need the actual hit point in 3D (for measurements, snapping, or distance-aware filtering).

### Constructing a ray from a tap

Convert a screen-space tap location to NDC, then use `Ray.fromCamera`:

```swift
// screenPoint: CGPoint in the viewport's coordinate system (origin top-left)
// viewportSize: CGSize of the MetalViewportView
func makeRay(from screenPoint: CGPoint,
             viewportSize: CGSize,
             controller: ViewportController) -> Ray {
    let aspectRatio = Float(viewportSize.width / viewportSize.height)

    // NDC: x in [-1, 1] right, y in [-1, 1] up
    let ndcX = Float(screenPoint.x / viewportSize.width)  * 2.0 - 1.0
    let ndcY = 1.0 - Float(screenPoint.y / viewportSize.height) * 2.0
    let ndc = SIMD2<Float>(ndcX, ndcY)

    return Ray.fromCamera(
        ndc: ndc,
        cameraState: controller.cameraState,
        aspectRatio: aspectRatio
    )
}
```

`Ray.fromCamera` handles both perspective and orthographic projections automatically.

### Casting the ray

Pass the ray, your body array, and a bounding-box cache. `SceneRaycast.cast` runs AABB broadphase (slab method) then Möller–Trumbore narrowphase on survivors, returning the nearest hit:

```swift
func castRay(_ ray: Ray,
             bodies: [ViewportBody],
             controller: ViewportController) -> RaycastHit? {
    // Build a simple AABB cache from each body's bounding box
    var bbCache: [String: BoundingBox] = [:]
    for body in bodies {
        bbCache[body.id] = body.boundingBox
    }

    return SceneRaycast.cast(
        ray: ray,
        bodies: bodies,
        boundingBoxCache: bbCache
    )
}
```

`RaycastHit` gives you `bodyID: String`, `point: SIMD3<Float>` (world-space), and `distance: Float` from the ray origin.

### Full tap-to-world-point example

```swift
func onTap(at screenPoint: CGPoint,
           viewportSize: CGSize,
           controller: ViewportController,
           bodies: [ViewportBody]) {
    let aspectRatio = Float(viewportSize.width / viewportSize.height)
    let ndcX = Float(screenPoint.x / viewportSize.width)  * 2.0 - 1.0
    let ndcY = 1.0 - Float(screenPoint.y / viewportSize.height) * 2.0
    let ray = Ray.fromCamera(
        ndc: SIMD2<Float>(ndcX, ndcY),
        cameraState: controller.cameraState,
        aspectRatio: aspectRatio
    )

    var bbCache: [String: BoundingBox] = [:]
    for body in bodies { bbCache[body.id] = body.boundingBox }

    if let hit = SceneRaycast.cast(ray: ray, bodies: bodies, boundingBoxCache: bbCache) {
        print("hit \(hit.bodyID) at \(hit.point), distance \(hit.distance)")
    }
}
```

### Direct ray construction

You can also build a `Ray` directly for programmatic use (e.g. automated testing):

```swift
let ray = Ray(
    origin: SIMD3<Float>(0, 10, 0),
    direction: SIMD3<Float>(0, -1, 0)   // normalized automatically
)
```

---

## Projecting world points back to screen

Use `ProjectionUtility` to go the other direction — world position to screen coordinates, for annotation placement or custom overlays:

```swift
let vpMatrix = controller.cameraState.viewProjectionMatrix(aspectRatio: aspectRatio)

if let screenPt = ProjectionUtility.worldToScreen(
    point: hit.point,
    vpMatrix: vpMatrix,
    viewportSize: viewportSize
) {
    // screenPt is a CGPoint with origin at top-left, Y-down
    drawAnnotation(at: screenPt)
}
```

`worldToScreen` returns `nil` when the point is behind the camera. `worldToNDC` gives the same result in NDC space when you need to stay in normalized coordinates.

---

## Two-stream pick routing

Bodies tagged with `pickLayer: .widget` bypass the `selectionFilter` and land in `widgetPickResult` instead of `pickResult`. This lets manipulator widgets (e.g. from OCCTSwiftAIS) have their own pick stream without colliding with user geometry selection:

```swift
let handle = ViewportBody(
    id: "translate_x",
    vertexData: arrowVerts,
    indices: arrowIndices,
    pickLayer: .widget   // routed to controller.widgetPickResult
)
```

---

## faceIndices — mapping triangles to BREP faces

When your geometry comes from a B-Rep tessellation, supply `faceIndices` to map each triangle back to its source face ID. This lets you identify which BREP face was tapped from a `.face` `PickResult`:

```swift
let body = ViewportBody(
    id: "solid",
    vertexData: meshVerts,
    indices: meshIndices,
    faceIndices: perTriangleFaceIDs   // [Int32], one entry per triangle
)

// In the pick handler:
controller.onPick = { result in
    guard let result, result.kind == .face else { return }
    let faceID = body.faceIndices[result.triangleIndex]
    print("tapped BREP face", faceID)
}
```

`faceIndices` is optional (defaults to `[]`). When empty, `triangleIndex` is still valid as a raw triangle index within the body's `indices` buffer.
