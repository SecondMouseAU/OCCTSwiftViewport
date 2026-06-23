---
title: Loading Geometry
parent: Cookbook
nav_order: 7
---

# Loading Geometry

<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>

<model-viewer src="../../models/drilled-block.glb" camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1" style="width:340px;height:300px;background:#eef1f5;border-radius:6px"></model-viewer>

*A loaded model displayed as a ViewportBody.*


`ViewportBody` is the geometry-source-agnostic container that feeds every rendering pass in the Metal viewport. It carries interleaved vertex data, triangle indices, edge polylines, analytic arcs, and a collection of per-body properties — color, material, transform, visibility, and pickability. The viewport has no dependency on OpenCASCADE; bridging from B-Rep to `ViewportBody` is the responsibility of the consuming app (typically via OCCTSwiftTools).

Bodies are passed to the view through a `Binding<[ViewportBody]>`:

```swift
struct ContentView: View {
    @StateObject private var controller = ViewportController()
    @State private var bodies: [ViewportBody] = []

    var body: some View {
        MetalViewportView(controller: controller, bodies: $bodies)
            .onAppear { bodies = [.box(id: "b1", color: SIMD4<Float>(0.6, 0.8, 1.0, 1.0))] }
    }
}
```

Appending, replacing, or removing elements from `bodies` is all that is needed to update the scene.

---

## The vertex buffer layout

`ViewportBody.vertexData` is a flat `[Float]` array with **stride 6** — six floats per vertex, in this exact order:

| Offset | Field |
|--------|-------|
| 0 | position X |
| 1 | position Y |
| 2 | position Z |
| 3 | normal X |
| 4 | normal Y |
| 5 | normal Z |

Each stride block is 24 bytes. The renderer reads positions and normals directly from this buffer with no repacking step.

`indices` is a `[UInt32]` triangle list parallel to this vertex buffer: every three consecutive values form one triangle.

### Building a body by hand

```swift
// A single triangle in the XY plane, normal pointing +Z.
let vertexData: [Float] = [
    //  px,   py,   pz,   nx,   ny,   nz
     0.0,  1.0,  0.0,  0.0,  0.0,  1.0,
    -1.0, -1.0,  0.0,  0.0,  0.0,  1.0,
     1.0, -1.0,  0.0,  0.0,  0.0,  1.0,
]
let indices: [UInt32] = [0, 1, 2]

// Wireframe outline — one polyline per logical edge.
let edges: [[SIMD3<Float>]] = [
    [SIMD3(0, 1, 0), SIMD3(-1, -1, 0), SIMD3(1, -1, 0), SIMD3(0, 1, 0)]
]

let triangle = ViewportBody(
    id: "triangle",
    vertexData: vertexData,
    indices: indices,
    edges: edges,
    color: SIMD4<Float>(0.4, 0.7, 1.0, 1.0)
)
```

All `ViewportBody.init` parameters after `edges` have defaults, so passing only the three required arrays is valid.

---

## Primitive factories

Three convenience factories are available for quick prototyping:

```swift
// Axis-aligned box (default 1×1×1, grey).
let box = ViewportBody.box(
    id: "box",
    width: 2.0,
    height: 0.5,
    depth: 1.0,
    color: SIMD4<Float>(0.8, 0.5, 0.2, 1.0)
)

// Cylinder along the Y axis (default radius 0.5, height 1, 64 segments).
let cyl = ViewportBody.cylinder(
    id: "cyl",
    radius: 0.3,
    height: 2.0,
    segments: 64,
    color: SIMD4<Float>(0.6, 0.6, 0.9, 1.0)
)

// UV sphere (default radius 0.5, 48 segments, 32 rings).
let sphere = ViewportBody.sphere(
    id: "sphere",
    radius: 1.0,
    segments: 48,
    rings: 32,
    color: SIMD4<Float>(0.9, 0.3, 0.3, 1.0)
)
```

All three factories populate `faceIndices` so sub-body face selection works out of the box.

---

## Analytic arc edges

Pre-sampled polylines in `edges` facet circles at a fixed density. For round features that must stay smooth at any zoom level, use `arcs` instead. The renderer samples each `ViewportArc` to line segments **adaptively per frame** based on its projected size.

```swift
// A full horizontal circle of radius 1 in the XZ plane.
let circle = ViewportArc.circle(
    center: SIMD3<Float>(0, 0, 0),
    radius: 1.0,
    xAxis: SIMD3<Float>(1, 0, 0),
    yAxis: SIMD3<Float>(0, 0, 1)
)

// A 90° arc (quarter circle).
let arc = ViewportArc(
    center: SIMD3<Float>(0, 0, 0),
    radius: 0.5,
    xAxis: SIMD3<Float>(1, 0, 0),
    yAxis: SIMD3<Float>(0, 0, 1),
    startAngle: 0,
    endAngle: .pi / 2
)

let roundBody = ViewportBody(
    id: "round",
    vertexData: [],   // mesh data omitted for illustration
    indices: [],
    edges: [],
    arcs: [circle, arc],
    color: SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
)
```

A body may mix `edges` and `arcs`, but note that a tap on either reports `PickResult.kind == .edge` — prefer one representation per body when you need to distinguish pick results.

---

## `faceIndices` for sub-body face selection

When `faceIndices` is populated it must be **parallel to the triangle count** (`indices.count / 3`). Each element maps the corresponding triangle back to an integer face ID (e.g., a B-Rep face index). The GPU pick texture encodes `objectIndex | (triangleIndex << 16)`; the controller uses `faceIndices[triangleIndex]` to resolve which logical face was tapped.

```swift
// Two quads forming two logical faces (face 0 and face 1).
// indices: [0,1,2, 0,2,3, 4,5,6, 4,6,7]  → 4 triangles
let faceIndices: [Int32] = [0, 0, 1, 1]  // triangles 0–1 → face 0; 2–3 → face 1
```

Leave `faceIndices` empty when face-level selection is not needed.

---

## Per-body transform, color, and material

Each body carries its own model transform applied on top of the scene model matrix in the vertex shader. You can animate a body's position without re-uploading vertex data:

```swift
var body = ViewportBody.box(id: "moving", color: SIMD4<Float>(1, 1, 0, 1))

// Translate 3 units along X.
body.transform = simd_float4x4(
    SIMD4<Float>(1, 0, 0, 0),
    SIMD4<Float>(0, 1, 0, 0),
    SIMD4<Float>(0, 0, 1, 0),
    SIMD4<Float>(3, 0, 0, 1)   // column-major: translation in last column
)
```

For simple shading, set `color` (RGBA), `roughness` (0 = mirror, 1 = rough, default 0.5), and `metallic` (0 = dielectric, 1 = metal, default 0.0):

```swift
body.color = SIMD4<Float>(0.9, 0.6, 0.1, 1.0)  // gold-ish
body.roughness = 0.2
body.metallic = 0.9
```

For full PBR control — clearcoat, IOR, emission — assign a `PBRMaterial`, which overrides the three shorthand fields:

```swift
body.material = PBRMaterial(
    baseColor: SIMD3<Float>(0.05, 0.05, 0.05),
    metallic: 1.0,
    roughness: 0.05,
    clearcoat: 1.0,
    clearcoatRoughness: 0.03
)
```

Surface transparency is driven by `color.w` (or `PBRMaterial.opacity`). Bodies with opacity < 1 are sorted back-to-front and rendered in a separate translucent pass.

---

## Point-cloud bodies

Set `primitiveKind` to `.point` to skip the triangle/edge passes and render `vertices` as point sprites instead. `vertexData` and `indices` are ignored in this mode.

```swift
let points: [SIMD3<Float>] = [
    SIMD3<Float>(0, 0, 0),
    SIMD3<Float>(1, 0, 0),
    SIMD3<Float>(0, 1, 0),
]

// Optional per-point colors (parallel to vertices).
let colors: [SIMD4<Float>] = [
    SIMD4<Float>(1, 0, 0, 1),
    SIMD4<Float>(0, 1, 0, 1),
    SIMD4<Float>(0, 0, 1, 1),
]

let cloud = ViewportBody(
    id: "cloud",
    vertexData: [],
    indices: [],
    edges: [],
    vertices: points,
    vertexColors: colors,
    color: SIMD4<Float>(1, 1, 1, 1),   // fallback when vertexColors is empty
    pointRadius: 0.03,                  // world-space radius; clamped 1–64 px on screen
    primitiveKind: .point
)
```

`boundingBox` falls back to the `vertices` array when `vertexData` is empty, so `CameraState.fit(to:)` and frustum culling work correctly for point clouds.

---

## Visibility and pickability

Two independent switches control how a body participates in rendering and picking:

| Property | Default | Effect when `false` |
|----------|---------|---------------------|
| `isVisible` | `true` | Body is not drawn at all |
| `isPickable` | `true` | Body is excluded from the pick buffer (still drawn) |

Setting `isPickable = false` is useful for datum planes or reference overlays that should never steal a pick from the geometry behind them.

```swift
var ground = ViewportBody.box(id: "ground", width: 20, height: 0.01, depth: 20,
                              color: SIMD4<Float>(0.5, 0.5, 0.5, 0.3))
ground.isPickable = false
ground.material = PBRMaterial(baseColor: SIMD3(0.5, 0.5, 0.5), opacity: 0.3)
```

---

## Bridging from OCCTSwift geometry

The viewport has no OpenCASCADE dependency. Tessellation is handled by **OCCTSwiftTools** (`import OCCTSwiftTools`), which lives in a separate package:

```swift
import OCCTSwiftTools

// shape: an OCCTSwift Shape (solid, face, compound, etc.)
// deflection: chord-height tolerance for triangulation (smaller = finer)
if let (body, metadata) = try? CADFileLoader.shapeToBodyAndMetadata(
    shape,
    id: "part",
    deflection: 0.01,
    color: SIMD4<Float>(0.7, 0.8, 0.9, 1.0)
) {
    bodies.append(body)
    // metadata contains face/edge maps for selection round-tripping
}
```

`shapeToBodyAndMetadata` tessellates the B-Rep, interleaves position+normal into `vertexData`, builds edge polylines for silhouette and feature edges, and populates `faceIndices` so every triangle traces back to its source B-Rep face. The consuming app stores the returned metadata to resolve `PickResult.triangleIndex` → B-Rep face → downstream selection operations.

---

## Generation counter and cache invalidation

Each `ViewportBody.init` call atomically increments a static counter and stamps the new body's `generation` property with a unique `UInt64`. The renderer compares generations to detect geometry changes and decide whether to re-upload vertex, index, or edge buffers to the GPU. This means:

- Mutating a property on an *existing* body (e.g., changing `color` or `transform`) does **not** re-upload vertex buffers — only the uniform is updated.
- Replacing a body with a new `ViewportBody(...)` (new `generation`) forces a full buffer re-upload.
- Bulk-replacing all bodies triggers re-uploads for every body whose `generation` changed.

For live editing workflows where you change color frequently but geometry rarely, update `color` in place rather than constructing a new body.
