---
title: Viewport Body & Geometry
parent: API Reference
---

# Viewport Body & Geometry

These types are the complete input interface for the Metal rendering pipeline. `ViewportBody` is the geometry-source-agnostic container passed to `ViewportController`; `ViewportArc` describes analytic circular/arc edges that the renderer re-samples adaptively each frame; `PBRMaterial` carries physically based material parameters; the supporting enums (`BodyPrimitiveKind`, `RenderLayer`, `PickLayer`) and the `TriangleStyle` struct control how a body is drawn and picked; and `ArcSampling` provides the pure utility that the renderer uses to decide how many line segments to allocate per arc.

All types are `Sendable` and value types (structs or enums), safe to pass across actor boundaries.

## Topics

- [ViewportBody](#viewportbody) · [Vertex data layout](#vertex-data-layout) · [Primitive factories](#primitive-factories)
- [ViewportArc](#viewportarc) · [ArcSampling](#arcsampling)
- [PBRMaterial](#pbrmaterial)
- [TriangleStyle](#trianglestyle)
- [BodyPrimitiveKind](#bodyprimitivekind) · [RenderLayer](#renderlayer) · [PickLayer](#picklayer)

---

## ViewportBody

```swift
public struct ViewportBody: Identifiable, Sendable
```

A renderable body for the Metal viewport. Holds interleaved vertex/normal data, triangle indices, optional polyline edges, analytic arcs, point-cloud vertices, per-triangle highlight styles, a PBR material, and rendering/picking metadata. The renderer reads all of these; the consumer creates and mutates `ViewportBody` values and hands them to `ViewportController`.

Every call to `init` increments a global generation counter. The renderer compares `generation` between frames to know whether GPU buffers must be re-uploaded, avoiding expensive vertex-data diffing.

### Vertex data layout

`vertexData` is a flat `[Float]` of interleaved position + normal, stride **6 floats (24 bytes)**:

```
index  0  1  2  3  4  5   6  7  8  9  10 11 ...
       px py pz nx ny nz | px py pz nx ny nz | …
```

Accessing vertex `i`: `base = i * 6`; position = `vertexData[base..<base+3]`; normal = `vertexData[base+3..<base+6]`.

### `init`

```swift
public init(
    id: String,
    vertexData: [Float],
    indices: [UInt32],
    edges: [[SIMD3<Float>]],
    arcs: [ViewportArc] = [],
    faceIndices: [Int32] = [],
    edgeIndices: [Int32] = [],
    vertices: [SIMD3<Float>] = [],
    vertexIndices: [Int32] = [],
    vertexColors: [SIMD4<Float>] = [],
    triangleStyles: [TriangleStyle] = [],
    color: SIMD4<Float>,
    roughness: Float = 0.5,
    metallic: Float = 0.0,
    material: PBRMaterial? = nil,
    pointRadius: Float = 0.05,
    primitiveKind: BodyPrimitiveKind = .mesh,
    isVisible: Bool = true,
    isPickable: Bool = true,
    renderLayer: RenderLayer = .geometry,
    pickLayer: PickLayer = .userGeometry,
    transform: simd_float4x4 = matrix_identity_float4x4
)
```

Creates a body and assigns it the next unique `generation` value. The two required non-defaulted parameters are `id`, `color`, and the three geometry arrays (`vertexData`, `indices`, `edges`).

| Parameter | Description |
|---|---|
| `id` | Stable string identifier; used as the dictionary key in `ViewportController`. |
| `vertexData` | Interleaved `[px, py, pz, nx, ny, nz, …]`, stride 6. See [vertex data layout](#vertex-data-layout). |
| `indices` | Triangle index list. `indices.count` must be divisible by 3. |
| `edges` | Polylines for wireframe rendering. Each inner array is one connected polyline. |
| `arcs` | Analytic circular/arc edges in body-local space. Renderer re-samples adaptively per frame. Default `[]`. |
| `faceIndices` | Per-triangle B-Rep face index, parallel to triangle count (`indices.count / 3`). Used for face pick mapping. Default `[]`. |
| `edgeIndices` | Per-segment source-edge index, parallel to the flattened edge segment list across all `edges` polylines. Enables edge-pick mapping. Default `[]` — body is not edge-pickable. |
| `vertices` | Point list for vertex-pick sprites. Default `[]` — body is not vertex-pickable. |
| `vertexIndices` | Per-point source-vertex index, parallel to `vertices`. Default `[]` — pick reports the raw vertex array index. |
| `vertexColors` | Per-point RGBA colors, parallel to `vertices`. Only consumed by the `.point` point-cloud pass. Default `[]`. |
| `triangleStyles` | Per-triangle highlight overrides, parallel to triangle count. Default `[]` (no highlight pass). |
| `color` | Base RGBA color. Used as `effectiveMaterial.baseColor + opacity` when `material` is `nil`. |
| `roughness` | PBR roughness 0–1. Default `0.5`. Ignored when `material` is set. |
| `metallic` | PBR metallic factor 0–1. Default `0.0`. Ignored when `material` is set. |
| `material` | Full `PBRMaterial`. When set, overrides `color`/`roughness`/`metallic`. Default `nil`. |
| `pointRadius` | World-space point-sprite radius for `.point` bodies. Projected and clamped to `[1, 64]` px. Default `0.05`. |
| `primitiveKind` | `.mesh` (default), `.point`, or `.wire`. See [`BodyPrimitiveKind`](#bodyprimitivekind). |
| `isVisible` | `false` skips the body entirely. Default `true`. |
| `isPickable` | `false` excludes the body from the GPU pick buffer while still drawing it. Default `true`. |
| `renderLayer` | `.geometry` (normal depth test) or `.overlay` (always-on-top). Default `.geometry`. |
| `pickLayer` | `.userGeometry` routes hits to `ViewportController.pickResult`; `.widget` routes to `widgetPickResult`. Default `.userGeometry`. |
| `transform` | Per-body model matrix applied on top of the scene model matrix in the vertex shader. Default `matrix_identity_float4x4`. |

**Example — shaded mesh from tessellated BREP data:**

```swift
// triangles and edgePolylines come from OCCTSwift tessellation
let body = ViewportBody(
    id: "bracket",
    vertexData: triangles.interleavedVertexNormals,   // [Float], stride 6
    indices: triangles.indices,
    edges: edgePolylines,
    faceIndices: triangles.faceIndices,
    color: SIMD4<Float>(0.72, 0.74, 0.76, 1.0),
    roughness: 0.4,
    metallic: 0.8
)
viewportController.bodies["bracket"] = body
```

---

### Properties

#### `id: String`

Unique identifier for this body. Used as the dictionary key in `ViewportController.bodies`.

#### `generation: UInt64`

Monotonically increasing tag assigned at init time. The renderer compares this between frames; a changed value triggers a full GPU buffer re-upload. Read-only (`let`).

#### `vertexData: [Float]`

Interleaved position + normal, stride 6. See [vertex data layout](#vertex-data-layout).

#### `indices: [UInt32]`

Triangle index buffer. `indices.count / 3` equals the triangle count.

#### `edges: [[SIMD3<Float>]]`

Polylines for wireframe rendering. Each sub-array is one continuous polyline — for a closed loop, repeat the first point at the end.

#### `arcs: [ViewportArc]`

Analytic arc/circle feature edges in body-local space. Renderer samples these to line segments adaptively per frame using `ArcSampling.segmentCount`. Empty by default.

#### `faceIndices: [Int32]`

Per-triangle source face index, parallel to `indices.count / 3`. Maps GPU face picks back to B-Rep face IDs for sub-body selection. Empty if not applicable.

#### `edgeIndices: [Int32]`

Per-segment source-edge index, parallel to the flattened segments across all `edges` polylines. Empty if not applicable — in which case the body is not edge-pickable.

#### `vertices: [SIMD3<Float>]`

Point list rendered as pick sprites for vertex picking. Empty if not applicable — body is not vertex-pickable.

#### `vertexIndices: [Int32]`

Per-point source-vertex index, parallel to `vertices`. Empty defaults to identity mapping.

#### `vertexColors: [SIMD4<Float>]`

Per-point RGBA colors, parallel to `vertices`. Only used by the `.point` point-cloud render pass. Empty means all points use `color`.

#### `pointRadius: Float`

World-space radius for point sprites. Projected through the MVP matrix and clamped to `[1, 64]` px by the shader (Apple Metal `[[point_size]]` limit). Default `0.05`.

#### `primitiveKind: BodyPrimitiveKind`

Selects the render pass: `.mesh` (shaded + wireframe), `.point` (point-cloud sprites), or `.wire` (edge-only). See [`BodyPrimitiveKind`](#bodyprimitivekind).

#### `triangleStyles: [TriangleStyle]`

Per-triangle highlight overrides. When non-empty, `count` must equal `indices.count / 3`. Entries with `color.w == 0` are skipped. The renderer composites non-zero-alpha styles over the shaded pass with `.lessEqual` depth, preventing silhouette flicker. Mutating this field triggers a GPU style-buffer re-upload without disturbing vertex/index/edge buffers.

#### `color: SIMD4<Float>`

Base RGBA color. Used by `effectiveMaterial` when `material` is `nil`. The alpha channel drives `opacity`.

#### `roughness: Float`

PBR perceptual roughness 0 (mirror) – 1 (fully rough). Default `0.5`. Ignored when `material` is set.

#### `metallic: Float`

PBR metallic factor 0 (dielectric) – 1 (metal). Default `0.0`. Ignored when `material` is set.

#### `material: PBRMaterial?`

Full PBR material. When set, overrides `color`, `roughness`, and `metallic`. Use `effectiveMaterial` to read the resolved value regardless of which source is active.

#### `isVisible: Bool`

When `false`, the body is completely skipped by the renderer (not drawn, not picked).

#### `isPickable: Bool`

When `false`, the body is drawn normally but excluded from the GPU pick buffer. Useful for datum planes, ground planes, and always-on-top reference geometry that should not steal picks from real geometry behind them.

#### `renderLayer: RenderLayer`

`.geometry` — normal depth test (default). `.overlay` — body is drawn after the selection outline pass with an always-pass depth state, visible even when occluded. Used by manipulator widgets.

#### `pickLayer: PickLayer`

`.userGeometry` — hit results flow into `ViewportController.pickResult` (default). `.widget` — hit results flow into `ViewportController.widgetPickResult`, keeping manipulator picks out of the user selection stream.

#### `transform: simd_float4x4`

Per-body model matrix. Applied in the vertex shader on top of the scene model matrix. Lets the renderer reposition a body (e.g., during a manipulator drag) without re-uploading vertex data. Default `matrix_identity_float4x4`.

---

### Computed properties

#### `var boundingBox: BoundingBox?`

```swift
public var boundingBox: BoundingBox? { get }
```

Returns the axis-aligned bounding box of all vertex positions in `vertexData` (stride 6, positions at offsets 0-2). Falls back to `vertices` when `vertexData` is empty, so `.point` bodies report a usable extent for shadow framing, pick culling, and `CameraState.fit(to:)`. Returns `nil` if both sources are empty.

#### `var effectiveMaterial: PBRMaterial`

```swift
public var effectiveMaterial: PBRMaterial { get }
```

Returns `material` if set; otherwise synthesizes a `PBRMaterial` from the legacy `color`/`roughness`/`metallic` fields. The renderer always reads this rather than either source directly.

**Example:**

```swift
var body = ViewportBody.box(id: "b", color: SIMD4<Float>(0.8, 0.8, 0.8, 1))
// Color-only body — effectiveMaterial synthesizes from color/roughness/metallic.
print(body.effectiveMaterial.roughness)   // 0.5

// Switch to a named PBR preset:
body.material = .steel
print(body.effectiveMaterial.metallic)    // 1.0
```

---

### `worldHitPoint(ray:triangleIndex:)`

```swift
public func worldHitPoint(ray: Ray, triangleIndex: Int) -> SIMD3<Float>?
```

Returns the world-space point where `ray` intersects the triangle at `triangleIndex`, accounting for this body's `transform`.

Looks up the three vertex positions from `indices`/`vertexData` (stride 6), transforms each into world space via `transform`, and intersects with the ray using Möller-Trumbore. Returns `nil` if `triangleIndex` is out of range or the ray misses the (transformed) triangle.

`triangleIndex` matches `PickResult.triangleIndex` for a `.face` pick result — pass the two together to find where the user tapped on a surface.

| Parameter | Description |
|---|---|
| `ray` | World-space ray (typically from `Ray.fromCamera` via `ProjectionUtility`). |
| `triangleIndex` | Zero-based triangle index; matches `PickResult.triangleIndex`. |

**Example — tap-to-measure world point:**

```swift
// result from ViewportController.pickResult, ray from tap NDC coords
if result.kind == .face,
   let point = body.worldHitPoint(ray: tapRay, triangleIndex: result.triangleIndex) {
    viewportController.addMeasurementPoint(point)
}
```

---

## Primitive factories

Convenience static methods on `ViewportBody` that generate common CAD primitives with interleaved vertex/normal data, triangle indices, closed polyline edges, and `faceIndices`. All are defined in `Primitives.swift`.

---

### `box(id:width:height:depth:color:)`

```swift
public static func box(
    id: String,
    width: Float = 1,
    height: Float = 1,
    depth: Float = 1,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
) -> ViewportBody
```

Creates a flat-shaded box centered at the origin. Six faces, four vertices each (24 vertices total, unique per face for flat normals). Twelve polyline edges (four per axis-aligned loop plus four connecting edges). `faceIndices` maps each triangle pair to its face (0 = front +Z, 1 = back −Z, 2 = right +X, 3 = left −X, 4 = top +Y, 5 = bottom −Y).

**Example:**

```swift
let crate = ViewportBody.box(id: "crate", width: 2, height: 1, depth: 1.5,
                              color: SIMD4<Float>(0.6, 0.4, 0.2, 1))
```

---

### `cylinder(id:radius:height:segments:color:)`

```swift
public static func cylinder(
    id: String,
    radius: Float = 0.5,
    height: Float = 1,
    segments: Int = 64,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
) -> ViewportBody
```

Creates a cylinder aligned along the Y axis, centered at the origin. Side, top cap, and bottom cap are separate geometry regions with their own normals. Polyline edges: top ring, bottom ring, and up to eight evenly-spaced vertical lines. `faceIndices`: face 0 = side, face 1 = top cap, face 2 = bottom cap.

**Example:**

```swift
let pin = ViewportBody.cylinder(id: "pin", radius: 0.05, height: 0.8)
```

---

### `sphere(id:radius:segments:rings:color:)`

```swift
public static func sphere(
    id: String,
    radius: Float = 0.5,
    segments: Int = 48,
    rings: Int = 32,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
) -> ViewportBody
```

Creates a UV sphere centered at the origin. Smooth per-vertex normals. Polyline edges: one equatorial ring plus four meridians (at 0°, 90°, 180°, 270°). All triangles belong to `faceIndices` face 0 (single continuous surface).

**Example:**

```swift
let ball = ViewportBody.sphere(id: "ball", radius: 0.25, segments: 64, rings: 48)
```

---

## ViewportArc

```swift
public struct ViewportArc: Sendable, Hashable
```

An analytic circular arc in body-local space. Unlike polyline `edges` (pre-sampled), `ViewportArc` is re-tessellated by the renderer adaptively to the arc's projected screen size each frame, so circular features stay smooth at any zoom level without the consumer choosing a segment count.

A point at angle θ on the arc is computed as:
```
center + radius * (cos(θ) · xAxis + sin(θ) · yAxis)
```

**Picking:** arcs are pickable. A hit reports `PickResult.kind == .edge` with `triangleIndex` equal to the arc's index in `ViewportBody.arcs`. A body that mixes both `edges` and `arcs` cannot distinguish them from `kind` alone — prefer one representation per body.

### Properties

#### `var center: SIMD3<Float>`
Arc center in body-local space.

#### `var radius: Float`
Arc radius.

#### `var xAxis: SIMD3<Float>`
Unit in-plane axis at angle 0. Must be orthogonal to `yAxis`.

#### `var yAxis: SIMD3<Float>`
Unit in-plane axis at angle π/2. The arc lies in the plane spanned by `xAxis` and `yAxis`; their cross product is the arc's normal.

#### `var startAngle: Float`
Start angle in radians. Default `0`.

#### `var endAngle: Float`
End angle in radians. `endAngle > startAngle` sweeps counter-clockwise in the `xAxis`→`yAxis` plane. Default `2 * .pi` (full circle).

#### `var sweep: Float`
The total swept angle: `abs(endAngle - startAngle)`. Read-only computed.

---

### `init(center:radius:xAxis:yAxis:startAngle:endAngle:)`

```swift
public init(
    center: SIMD3<Float>,
    radius: Float,
    xAxis: SIMD3<Float>,
    yAxis: SIMD3<Float>,
    startAngle: Float = 0,
    endAngle: Float = 2 * .pi
)
```

**Example — arc on a cylindrical hole edge:**

```swift
// A 60° arc on a horizontal circle at y = 0.5, radius 0.3
let arc = ViewportArc(
    center: SIMD3<Float>(0, 0.5, 0),
    radius: 0.3,
    xAxis: SIMD3<Float>(1, 0, 0),
    yAxis: SIMD3<Float>(0, 0, 1),
    startAngle: 0,
    endAngle: .pi / 3
)
body.arcs.append(arc)
```

---

### `circle(center:radius:xAxis:yAxis:)`

```swift
public static func circle(
    center: SIMD3<Float>,
    radius: Float,
    xAxis: SIMD3<Float>,
    yAxis: SIMD3<Float>
) -> ViewportArc
```

Convenience factory for a full circle (`startAngle = 0`, `endAngle = 2π`). `xAxis` and `yAxis` must be unit-length and orthogonal; their cross product is the circle's normal.

**Example — circular edge on a bore:**

```swift
// XY-plane circle at the top face of a cylinder, z = 1.0
let topEdge = ViewportArc.circle(
    center: SIMD3<Float>(0, 0, 1),
    radius: 0.5,
    xAxis: SIMD3<Float>(1, 0, 0),
    yAxis: SIMD3<Float>(0, 1, 0)
)
body.arcs = [topEdge]
```

---

### `point(at:)`

```swift
public func point(at t: Float) -> SIMD3<Float>
```

Returns the body-local position at parameter `t ∈ [0, 1]`, mapping linearly from `startAngle` to `endAngle`.

**Example:**

```swift
let mid = arc.point(at: 0.5)   // midpoint of the arc
```

---

## ArcSampling

```swift
public enum ArcSampling
```

Namespace for the adaptive segment-count algorithm used by the renderer when tessellating `ViewportArc` values to line segments. Exposed publicly so host apps or custom renderers can use the same heuristic.

---

### `segmentCount(arc:mvp:viewportSize:targetPixels:minSegments:maxSegments:)`

```swift
public static func segmentCount(
    arc: ViewportArc,
    mvp: simd_float4x4,
    viewportSize: SIMD2<Float>,
    targetPixels: Float = 6,
    minSegments: Int = 6,
    maxSegments: Int = 512
) -> Int
```

Returns the number of line segments to use when rendering `arc`, chosen so that each segment is roughly `targetPixels` pixels long on screen. The algorithm:

1. Coarsely samples 8 evenly-spaced arc points, projects through `mvp`, and sums the on-screen pixel-length.
2. Divides by `targetPixels` to get a pixel-driven segment count.
3. Applies an angular floor of 1 segment per ~12° (`Float.pi / 15`) so small on-screen circles remain round.
4. Clamps to `[minSegments, maxSegments]`.
5. Falls back to `max(minSegments, maxSegments / 4)` if any sample projects behind the camera (`w ≤ 0`).

| Parameter | Default | Description |
|---|---|---|
| `arc` | — | The arc to measure. |
| `mvp` | — | Model-view-projection matrix for the current frame. |
| `viewportSize` | — | Viewport dimensions in pixels, as `SIMD2<Float>`. |
| `targetPixels` | `6` | Desired pixel length per segment. |
| `minSegments` | `6` | Lower clamp. |
| `maxSegments` | `512` | Upper clamp. |

**Example — custom renderer:**

```swift
let n = ArcSampling.segmentCount(
    arc: arc,
    mvp: uniforms.modelViewProjectionMatrix,
    viewportSize: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
)
// Emit n+1 vertices from arc.point(at:) calls
for i in 0...n {
    let p = arc.point(at: Float(i) / Float(n))
    // ... add to line buffer
}
```

---

## PBRMaterial

```swift
public struct PBRMaterial: Sendable, Codable, Hashable
```

Physically based material parameters following the glTF 2.0 metallic-roughness model, extended with a clearcoat layer (KHR_materials_clearcoat), IOR-driven F0 (KHR_materials_ior), and HDR emissive strength (KHR_materials_emissive_strength). When `clearcoat == 0` the material reduces to standard glTF 2.0 metallic-roughness.

Assign to `ViewportBody.material` to override the legacy `color`/`roughness`/`metallic` fields.

### `init`

```swift
public init(
    baseColor: SIMD3<Float> = SIMD3<Float>(0.8, 0.8, 0.8),
    metallic: Float = 0,
    roughness: Float = 0.5,
    ior: Float = 1.5,
    clearcoat: Float = 0,
    clearcoatRoughness: Float = 0.03,
    emissive: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
    emissiveStrength: Float = 1,
    opacity: Float = 1
)
```

### Properties

#### `var baseColor: SIMD3<Float>`
Linear RGB albedo for dielectrics; F0 tint for metals.

#### `var metallic: Float`
0 = dielectric, 1 = metal. Intermediate values are not physically meaningful but useful for blending.

#### `var roughness: Float`
Perceptual roughness 0 (mirror) – 1 (fully rough). Squared internally for GGX microfacet distribution.

#### `var ior: Float`
Index of refraction for dielectrics. Default `1.5` (plastic, glass). Drives F0 = `((ior-1)/(ior+1))²` for non-metals. Ignored when `metallic >= 1`.

#### `var clearcoat: Float`
Clearcoat layer strength. 0 = no coat, 1 = full polyurethane-like coat. Enables a second specular lobe.

#### `var clearcoatRoughness: Float`
Roughness of the clearcoat layer, independent of base roughness. Default `0.03` (sharp coat).

#### `var emissive: SIMD3<Float>`
Linear RGB emissive color. Multiplied by `emissiveStrength` before tonemapping.

#### `var emissiveStrength: Float`
Emissive intensity multiplier. Values > 1 produce true HDR bloom-ready emission.

#### `var opacity: Float`
Surface opacity. 1 = opaque. Values < 1 alpha-blend the body against the background; not a transmission model.

### Presets

```swift
public static let presets: [String: PBRMaterial]
```

Built-in materials for the common engineering visualization palette, keyed by stable lowercase identifiers. Available as convenience static properties:

| Property | Key | Notes |
|---|---|---|
| `PBRMaterial.steel` | `"steel"` | Metallic, roughness 0.35 |
| `PBRMaterial.brushedAluminum` | `"brushedAluminum"` | Metallic, roughness 0.55 |
| `PBRMaterial.brass` | `"brass"` | Metallic, roughness 0.30 |
| `PBRMaterial.copper` | `"copper"` | Metallic, roughness 0.30 |
| `PBRMaterial.chromedSteel` | `"chromedSteel"` | Metallic, roughness 0.05 |
| `PBRMaterial.gold` | `"gold"` | Metallic, roughness 0.20 |
| `PBRMaterial.titanium` | `"titanium"` | Metallic, roughness 0.45 |
| `PBRMaterial.plasticGlossy` | `"plasticGlossy"` | Dielectric, ior 1.5, roughness 0.25 |
| `PBRMaterial.plasticMatte` | `"plasticMatte"` | Dielectric, ior 1.5, roughness 0.85 |
| `PBRMaterial.paintedAutomotive` | `"paintedAutomotive"` | Dielectric + clearcoat 1.0 |
| `PBRMaterial.rubber` | `"rubber"` | Dielectric, roughness 0.95 |
| `PBRMaterial.glass` | `"glass"` | Dielectric, opacity 0.3 |

**Example:**

```swift
var body = ViewportBody.box(id: "housing", color: .zero /* overridden */)
body.material = .paintedAutomotive
```

**Custom material example:**

```swift
let anodizedBlue = PBRMaterial(
    baseColor: SIMD3<Float>(0.1, 0.2, 0.6),
    metallic: 0.9,
    roughness: 0.3,
    ior: 1.5
)
body.material = anodizedBlue
```

---

## TriangleStyle

```swift
public struct TriangleStyle: Hashable, Sendable
```

Per-triangle highlight color. Alpha 0 means no highlight (renderer skips); alpha > 0 composites the color over the base shading at that triangle using a `.lessEqual` depth pass, preventing silhouette flicker on coplanar geometry.

Populate `ViewportBody.triangleStyles` (parallel to triangle count) to highlight specific triangles — for example, the triangles of a selected B-Rep face.

### `init(color:)`

```swift
public init(color: SIMD4<Float> = .zero)
```

### Properties

#### `var color: SIMD4<Float>`
RGBA highlight color. Alpha 0 = no highlight; alpha > 0 composites over base shading.

#### `static let none: TriangleStyle`
Pre-built no-highlight style (`color = .zero`). Use to clear individual entries without allocating.

**Example — highlight triangles belonging to a selected face:**

```swift
guard var body = viewportController.bodies["bracket"] else { return }
let triangleCount = body.indices.count / 3
var styles = Array(repeating: TriangleStyle.none, count: triangleCount)
// faceIndices maps triangle → face ID; highlight face 3
for i in 0..<triangleCount where body.faceIndices[i] == 3 {
    styles[i] = TriangleStyle(color: SIMD4<Float>(0.2, 0.6, 1.0, 0.5))
}
body.triangleStyles = styles
viewportController.bodies["bracket"] = body
```

---

## BodyPrimitiveKind

```swift
public enum BodyPrimitiveKind: Sendable, Hashable
```

Selects which renderer pass draws the body.

| Case | Behavior |
|---|---|
| `.mesh` | Default. Shaded triangles from `vertexData`/`indices` + wireframe edges from `edges`/`arcs`. |
| `.point` | Point-cloud sprites from `vertices`. Ignores `vertexData`/`indices`/`edges`. `vertexColors` and `pointRadius` apply. |
| `.wire` | Edge-only intent. Currently rendered identically to `.mesh` with empty `vertexData` — use an empty `indices` array and populate `edges`/`arcs`. |

**Example — point cloud:**

```swift
let pts: [SIMD3<Float>] = scanPoints
let body = ViewportBody(
    id: "scan",
    vertexData: [],
    indices: [],
    edges: [],
    vertices: pts,
    color: SIMD4<Float>(0.9, 0.7, 0.2, 1),
    pointRadius: 0.02,
    primitiveKind: .point
)
```

---

## RenderLayer

```swift
public enum RenderLayer: Hashable, Sendable
```

Controls when the body is drawn relative to depth testing.

| Case | Behavior |
|---|---|
| `.geometry` | Normal depth test. Default for all bodies. |
| `.overlay` | Drawn after the selection outline pass with an always-pass depth state. The body is visible even when fully occluded by other geometry. Used by manipulator widgets and similar always-on-top affordances. |

---

## PickLayer

```swift
public enum PickLayer: Hashable, Sendable
```

Determines which pick result stream receives hits on this body.

| Case | Destination |
|---|---|
| `.userGeometry` | `ViewportController.pickResult` — the main user-selection stream. Default. |
| `.widget` | `ViewportController.widgetPickResult` — a separate stream for manipulator/widget hits, so OCCTSwiftAIS or custom gizmos can handle their own picks without polluting the user selection stream. |
