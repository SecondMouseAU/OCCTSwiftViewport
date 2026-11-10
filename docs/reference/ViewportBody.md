---
title: Viewport Body & Geometry
parent: API Reference
---

# Viewport Body & Geometry

These types are the complete input interface for the Metal rendering pipeline. `ViewportBody` is the geometry-source-agnostic container passed to `ViewportController`; `ViewportArc` describes analytic circular/arc edges that the renderer re-samples adaptively each frame; `PBRMaterial` carries physically based material parameters; the supporting enums (`BodyPrimitiveKind`, `RenderLayer`, `PickLayer`) and the `TriangleStyle` struct control how a body is drawn and picked; and `ArcSampling` provides the pure utility that the renderer uses to decide how many line segments to allocate per arc.

All types are `Sendable` and value types (structs or enums), safe to pass across actor boundaries.

## Topics

- [ViewportBody](#viewportbody) · [boundsKey and in-place content](#boundskey-and-in-place-content) · [Vertex data layout](#vertex-data-layout) · [Primitive factories](#primitive-factories) · [PrimitiveUpAxis](#primitiveupaxis)
- [ViewportArc](#viewportarc) · [ArcSampling](#arcsampling)
- [PBRMaterial](#pbrmaterial)
- [TriangleStyle](#trianglestyle) · [AuthoredColorSpace](#authoredcolorspace)
- [BodyPrimitiveKind](#bodyprimitivekind) · [VertexColorMode](#vertexcolormode) · [RenderLayer](#renderlayer) · [PickLayer](#picklayer)

---

## ViewportBody

```swift
public struct ViewportBody: Identifiable, Sendable
```

A renderable body for the Metal viewport. Holds interleaved vertex/normal data, triangle indices, optional polyline edges, analytic arcs, point-cloud vertices, per-triangle highlight styles, a PBR material, and rendering/picking metadata. The renderer reads all of these; the consumer creates and mutates `ViewportBody` values and hands them to `ViewportController`.

Every call to `init`, and every assignment or in-place mutation of a geometry field, takes the next value of a global generation counter. The renderer compares `generation` between frames to know whether GPU buffers must be re-uploaded, avoiding expensive vertex-data diffing.

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
    vertexColorMode: VertexColorMode = .ignored,
    vertexColorSpace: AuthoredColorSpace = .sRGB,
    triangleStyles: [TriangleStyle] = [],
    edgeColors: [SIMD4<Float>] = [],
    edgeDrawRange: Range<Int>? = nil,
    edgeColorSpace: AuthoredColorSpace = .sRGB,
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
    transform: simd_float4x4 = matrix_identity_float4x4,
    meshPositions: [Float] = [],
    meshNormals: [Float] = []
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
| `vertexColors` | Per-vertex RGBA colour, as sRGB (display) values unless `vertexColorSpace` says linear. For `.point` bodies: one per point, parallel to `vertices`. For mesh bodies: one per mesh vertex, applied per `vertexColorMode`. Default `[]`. See [per-vertex colours](#per-vertex-colours-on-mesh-bodies). |
| `vertexColorMode` | How a mesh body's `vertexColors` combine with its base colour: `.ignored` (default, the body colour alone), `.multiply` or `.replace`. See [`VertexColorMode`](#vertexcolormode). |
| `vertexColorSpace` | The colour space `vertexColors` are authored in, for mesh and point-cloud bodies: `.sRGB` (default, display values drawn as given) or `.linear` (linear light, encoded for display when drawn). See [`AuthoredColorSpace`](#authoredcolorspace). |
| `triangleStyles` | Per-triangle highlight overrides, parallel to triangle count. Default `[]` (no highlight pass). |
| `edgeColors` | Per-segment edge colours, RGBA in the space `edgeColorSpace` names (sRGB by default), parallel to the flattened `edges` segments (`edgeSegmentCount`). A cheap update: does not change `generation`. Default `[]` (every segment in the body's usual edge colour). |
| `edgeDrawRange` | The flattened `edges` segments that are drawn and picked. A cheap update: does not change `generation`. Default `nil` (all). |
| `edgeColorSpace` | How `edgeColors` are interpreted: [`AuthoredColorSpace`](#authoredcolorspace) `.sRGB` (display values drawn as given) or `.linear` (converted for display). A cheap update: does not change `generation`. Default `.sRGB`. |
| `color` | Base RGBA colour, as sRGB (display) values. Used as `effectiveMaterial.baseColor + opacity` when `material` is `nil`. |
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
| `meshPositions` | De-interleaved positions `[px, py, pz, …]` for the direct-mesh path. Default `[]`. See [`directMesh`](#directmesh-direct-mesh-path). |
| `meshNormals` | De-interleaved normals `[nx, ny, nz, …]`, parallel to `meshPositions`. Default `[]`. |

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
bodies.append(body)   // `bodies` is the app's @State [ViewportBody], passed to MetalViewportView
```

---

### `directMesh` (direct-mesh path)

```swift
public static func directMesh(
    id: String,
    positions: [Float],
    normals: [Float],
    indices: [UInt32],
    color: SIMD4<Float>,
    faceIndices: [Int32] = [],
    edges: [[SIMD3<Float>]] = [],
    vertexColors: [SIMD4<Float>] = [],
    vertexColorMode: VertexColorMode = .ignored,
    vertexColorSpace: AuthoredColorSpace = .sRGB,
    material: PBRMaterial? = nil,
    transform: simd_float4x4 = matrix_identity_float4x4
) -> ViewportBody
```

Builds a body from **de-interleaved** position and normal arrays, which the renderer uploads as two separate GPU buffers (position @ buffer 0, normal @ buffer 2, stride 12 each) instead of one interleaved stride-6 buffer.

Use this when your geometry source **already hands you flat, contiguous position and normal arrays** — as OCCT's `Poly_Triangulation` does. It skips the CPU interleave/repack and the extra copy that `init(vertexData:)` requires, which is a load-time and peak-memory win on large meshes.

| Parameter | Description |
|---|---|
| `positions` | Flat `[px, py, pz, …]`. Length must be a multiple of 3. |
| `normals` | Flat `[nx, ny, nz, …]`, **same length** as `positions` (one normal per position). |
| `indices` | Triangle index list, indexing *vertices* (not floats). |
| `faceIndices` | Per-triangle B-Rep face index, for face pick mapping. Default `[]`. |
| `edges` | Wireframe polylines, as on `init`. Default `[]`. |
| `vertexColors` | One RGBA colour per vertex, parallel to `positions`, in `vertexColorSpace` (sRGB by default). Default `[]`. See [per-vertex colours](#per-vertex-colours-on-mesh-bodies). |
| `vertexColorMode` | How `vertexColors` combine with `color`. Default `.ignored`. |
| `vertexColorSpace` | The colour space of `vertexColors`. Default `.sRGB`. |

```swift
// positions/normals come straight from the kernel — no interleaving
let body = ViewportBody.directMesh(
    id: "bracket",
    positions: mesh.vertexData,      // [Float] — flat xyz
    normals: mesh.normalData,        // [Float] — flat xyz, parallel
    indices: mesh.indices,
    color: SIMD4<Float>(0.72, 0.74, 0.76, 1.0),
    faceIndices: mesh.faceIndices
)
```

#### Behaviour and trade-offs

- **Opt-in.** Nothing changes unless you call `directMesh(...)`. Bodies built with `init(vertexData:)` keep the interleaved path and all existing behaviour.
- **`NormalSmoothing` is skipped.** A direct body renders the normals you supply, verbatim. This is the point: OCCT's analytic per-vertex normals are already correct, and re-deriving them is wasted work. It also means `ViewportConfiguration.autoSmoothNormals` does **not** apply to direct bodies — if your source normals are flat/faceted, either smooth them yourself or use the interleaved path.
- **`vertexData` is left empty**; `vertices` is populated with the reshaped positions (for vertex picking). `boundingBox`, `CameraState.fit(to:)` and CPU raycasting (`SceneRaycast`) read `meshPositions` directly, so a direct body built through `init(meshPositions:meshNormals:)` without `vertices` works too.
- **Tessellation and mesh shaders are skipped** for direct bodies (`renderingQuality = .enhanced` has no effect on them).
- **Pick caveat:** because `vertices` holds *mesh* vertices, a direct body does not carry separate B-Rep corner-vertex or per-segment edge pick indices. Face display, GPU pick, CPU raycast, and edge *display* all work.

All render passes support direct bodies: shaded (opaque + transparent), shadow casting, the SSAO/silhouette depth prepass, the selection/hover outline, the per-triangle `triangleStyles` highlight, and the overlay layer in both `ViewportRenderer` and `OffscreenRenderer`, plus the GPU pick pass in `ViewportRenderer`.

#### `usesDirectMesh: Bool`

`true` when `meshPositions` is non-empty and `meshNormals` matches its length — i.e. the renderer will take the direct path for this body. Computed, read-only.

---

### Properties

#### `id: String`

Unique identifier for this body. Keys the renderer's per-body buffer cache, selection (`selectedBodyIDs`), and pick results (`PickResult.bodyID`); keep it stable across updates.

#### `generation: UInt64`

Monotonically increasing tag. `init` assigns one, and so does every assignment or in-place mutation of a geometry field: `vertexData`, `indices`, `edges`, `arcs`, `faceIndices`, `edgeIndices`, `vertices`, `vertexIndices`, `vertexColors`, `meshPositions`, `meshNormals`. Both renderers (and `PivotStrategy`'s bounding-box cache) compare it with the value they cached for the body's `id`; a changed value triggers a full GPU buffer re-upload. So mutating geometry on an existing body and handing it back is enough:

```swift
var body = bodies[0]
body.vertexData = deformed   // new generation
bodies[0] = body             // next frame re-uploads this body's buffers
```

Appearance and placement fields (`color`, `material`, `transform`, `isVisible`, `triangleStyles`, `edgeColors`, `edgeDrawRange`, `edgeColorSpace`, ...) leave it unchanged, since they are read every frame or re-upload only their own small buffer. Copies share a generation until one of them is mutated. Read-only (`public private(set)`); the counter is thread-safe, so bodies can be built and mutated off the main actor.

**Invariant for caches.** Any change that affects a body's *bounds* must change `generation`, or the body must expose a different `boundsKey` (see [below](#boundskey-and-in-place-content)). Caches of per-body bounds (`PivotStrategy`, the controller's overlay bounds, the renderers' local-bounds lookup) key on `boundsKey`, never on `generation` directly.

#### `heightfield: Heightfield?`

A [`Heightfield`](Heightfield.md) this body draws instead of a mesh; `nil` by default (also an `init` parameter). The field is a shared handle edited in place, so editing it does **not** change `generation`; assigning a different handle does. A heightfield body draws and is bounded by the field alone: `vertexData`, `edges`, `arcs`, `vertices` and the other mesh arrays are ignored.

#### `vertexData: [Float]`

Interleaved position + normal, stride 6. See [vertex data layout](#vertex-data-layout).

#### `indices: [UInt32]`

Triangle index buffer. `indices.count / 3` equals the triangle count.

#### `edges: [[SIMD3<Float>]]`

Polylines for wireframe rendering. Each sub-array is one continuous polyline — for a closed loop, repeat the first point at the end.

#### `arcs: [ViewportArc]`

Analytic arc/circle feature edges in body-local space. Renderer samples these to line segments adaptively per frame using `ArcSampling.segmentCount`. Empty by default.

#### `faceIndices: [Int32]`

Per-triangle source face index, parallel to `indices.count / 3`. Maps GPU face picks back to B-Rep face IDs for sub-body selection. Empty if not applicable. Rendering never needs it: `.enhanced` tessellation and `.maximum` mesh shading apply to bodies without it too (#161).

#### `edgeSegmentCount: Int`

Number of line segments in `edges` once flattened: a polyline of `n` points has `n - 1`, and one with fewer than two points has none. This is the length `edgeIndices` and `edgeColors` need and the bound of `edgeDrawRange`.

#### `edgeIndices: [Int32]`

Per-segment source-edge index, parallel to the flattened segments across all `edges` polylines. Empty if not applicable, in which case the body is not edge-pickable. Overlay-layer bodies are the exception: their drawn edges are always pickable (#170).

#### `edgeColors: [SIMD4<Float>]`

Per-segment edge colour, parallel to the flattened segments of `edges`: segment `k` of polyline `p` is entry `(segments in polylines before p) + k`, the same order as `edgeIndices`. Needs exactly `edgeSegmentCount` entries. Empty (the default), or any other count, is ignored and every segment keeps the body's usual edge colour (the body `color` for an edge-only body, the contrast-adaptive edge colour for a meshed one), the rule `vertexColors` follows for points.

- **Colour space.** Chosen by [`edgeColorSpace`](#edgecolorspace-authoredcolorspace), **sRGB (display) by default**: drawn as given, like `color`, `vertexColors` and `TriangleStyle.color`, so mid-grey `(0.5, 0.5, 0.5)` reads 128 in the output. Edges and the other passes that only draw an authored colour never decode and re-encode it (see [Colour pipeline](Display-Lighting.md#colour-pipeline)). Set `edgeColorSpace = .linear` for linear-light data.
- **Where it applies.** The `edges` polylines of geometry and overlay bodies, in both edge paths (quad-expanded and native 1 px lines) and in the live and offscreen renderers. Arcs (`arcs`) keep the body colour.
- **On a meshed body** the segment colour replaces the contrast-adaptive edge colour; the depth fade and `edgeIntensity` still scale it, and the colour's alpha scales it further. So `edgeIntensity == 0` hides every edge, and alpha 0 hides that segment's drawing. A fully transparent segment stays pickable: hide segments you do not want picked with `edgeDrawRange`.
- **On an edge-only body** the colour, alpha included, is the fragment colour, so alpha blends over what is behind it.
- **Cost.** Assigning it (or mutating it in place) leaves `generation` unchanged and re-uploads only its own buffer on the next frame, 16 bytes per segment: about 192 KB for a 12,000-segment path. The edge vertex buffers are not touched. `OffscreenRenderer` builds the buffer per render.

```swift
// `bodies` is the array bound to MetalViewportView; `palette` maps a move kind to a colour.
// Recolour a path by move kind without rebuilding it.
bodies[pathIndex].edgeColors = moves.map { palette[$0.kind] }
```

#### `edgeColorSpace: AuthoredColorSpace`

How `edgeColors` are interpreted. `.sRGB` (the default) draws them as given; `.linear` encodes them to sRGB when drawn, so mid-grey `(0.5, 0.5, 0.5)` reads about 188 instead of 128. Only the colour channels are converted: alpha is coverage and is never encoded. The conversion runs in the fragment shader on every edge pass (quad-expanded and native, geometry and overlay, live and offscreen), so changing it leaves `generation` alone and uploads nothing, not even the colour buffer. It has no effect on picking, and none while `edgeColors` is empty or mismatched.

#### `edgeDrawRange: Range<Int>?`

The slice of flattened `edges` segments that is drawn and picked, in the same numbering as `edgeColors` and `edgeIndices`; `nil` (the default) shows them all. The range is clamped to `0..<edgeSegmentCount`, so a playhead may run past the end or start below zero, and an empty or out-of-range range draws and picks nothing.

- **Cheap.** Assigning it leaves `generation` unchanged and uploads nothing; the renderers read it every frame and draw that slice of the existing edge buffer, so it can change 60 times a second. Dash patterns keep their phase, as the arc length is baked into the segments.
- **Picking.** Segments outside the range are not written to the pick buffer, so they cannot be picked; segments inside it report their absolute index.
- **Not affected.** `arcs`, and `boundingBox` (so revealing a path does not move the camera fit or the clip planes).

```swift
// Reveal the first `playhead` segments of the path.
bodies[pathIndex].edgeDrawRange = 0..<playhead
```

#### `vertices: [SIMD3<Float>]`

Point list rendered as pick sprites for vertex picking. Empty if not applicable — body is not vertex-pickable.

#### `vertexIndices: [Int32]`

Per-point source-vertex index, parallel to `vertices`. Empty defaults to identity mapping.

#### `vertexColors: [SIMD4<Float>]`

Per-vertex RGBA colour, as **sRGB (display) values** like `color` unless [`vertexColorSpace`](#vertexcolorspace-authoredcolorspace) is `.linear`. Two readers:

- **`.point` bodies:** one colour per point, parallel to `vertices`, always used when the count matches.
- **Mesh bodies:** one colour per *mesh* vertex (`vertexData.count / 6` for an interleaved body, `meshPositions.count / 3` for a direct-mesh one), interpolated across each triangle and applied per [`vertexColorMode`](#vertexcolormode). See [per-vertex colours](#per-vertex-colours-on-mesh-bodies).

Empty, or any count that does not match, means every point or vertex uses `color`. Assigning it takes a fresh `generation`, so the renderers re-upload the body.

#### `vertexColorSpace: AuthoredColorSpace`

The colour space `vertexColors` are authored in, for mesh bodies on every path and for point clouds alike. `.sRGB` (the default) takes them as display values, like `color`, so every existing render is unchanged. `.linear` takes them as linear light. See [`AuthoredColorSpace`](#authoredcolorspace). Read per frame, so changing it leaves `generation` unchanged. It does not affect `color`, which is always an sRGB value.

#### `vertexColorMode: VertexColorMode`

How a mesh body's `vertexColors` combine with its base colour in the shaded pass. Defaults to `.ignored`, so setting `vertexColors` alone changes nothing about how a mesh draws. No effect on `.point` bodies. Read per frame, so changing it leaves `generation` unchanged (the colours upload the first time a body needs them). See [`VertexColorMode`](#vertexcolormode).

#### `pointRadius: Float`

World-space radius for point sprites. Projected through the MVP matrix and clamped to `[1, 64]` px by the shader (Apple Metal `[[point_size]]` limit). Default `0.05`.

#### `primitiveKind: BodyPrimitiveKind`

Selects the render pass: `.mesh` (shaded + wireframe), `.point` (point-cloud sprites), or `.wire` (edge-only). See [`BodyPrimitiveKind`](#bodyprimitivekind).

#### `triangleStyles: [TriangleStyle]`

Per-triangle highlight overrides. When non-empty, `count` must equal `indices.count / 3`; an array of any other length is ignored (the body draws with no highlights) and debug builds log the mismatch. Entries with `color.w == 0` are skipped. The renderer composites non-zero-alpha styles straight after the surface they style, with `.lessEqual` depth, preventing silhouette flicker. On a translucent body (opacity below 1, or any body in `.xray`) they are drawn inside the sorted translucent pass, the far-facing half before the camera-facing half, so a highlight is seen through the surfaces in front of it rather than painted over them (#171). Over a mesh-shader surface (`.maximum` quality) the highlight is drawn through the plain vertex pipeline with a depth bias of a few depth units toward the viewer, so it keeps winning its `.lessEqual` tie with the meshlet surface even if the two stages round the position differently in the last bit (#213). Reassigning this field on an existing body (same `generation`) triggers a GPU style-buffer re-upload on the next frame without disturbing vertex/index/edge buffers.

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

`.geometry` — normal depth test (default). `.overlay` — body is drawn after the selection outline pass with an always-pass depth state, visible even when occluded, and casts no shadows. Overlay `.point` bodies (markers) are drawn the same way. Overlay bodies get no selection or hover outline. Used by manipulator widgets. Both `ViewportRenderer` and `OffscreenRenderer` honour it.

#### `pickLayer: PickLayer`

`.userGeometry` — hit results flow into `ViewportController.pickResult` (default). `.widget` — hit results flow into `ViewportController.widgetPickResult`, keeping manipulator picks out of the user selection stream.

#### `transform: simd_float4x4`

Per-body model matrix. Applied in the vertex shader on top of the scene model matrix. Lets the renderer reposition a body (e.g., during a manipulator drag) without re-uploading vertex data. Default `matrix_identity_float4x4`.

Positions go through the matrix; normals go through the inverse transpose of its upper 3×3 (the shaders' `Uniforms.normalMatrix`, kept in step with `transform`), so a body with a non-uniform scale or a shear is lit exactly like the same geometry with the transform baked into its vertices, on the shaded, direct-mesh, tessellated and mesh-shader paths alike (issue #213). Transforming a normal by the matrix itself tilts it off the surface under such a transform. A mirroring transform keeps its normals pointing out of the surface.

---

### boundsKey and in-place content

`ViewportBody` is a value type, so a change to any of its arrays makes a new `generation`. A body that draws shared content edited in place (today a [`Heightfield`](Heightfield.md)) can change without the value changing, so caches of its bounds compare an internal `boundsKey` instead: the `generation` plus the version of that content. The key is internal; the rule it enforces is the invariant on [`generation`](#generation-uint64). GPU-buffer caches built from the value-type arrays (`bodyGeneration` in both renderers, the offscreen point-pick buffers) may still key on `generation` alone, since those arrays cannot change in place.

---

### Computed properties

#### `var boundingBox: BoundingBox?`

```swift
public var boundingBox: BoundingBox? { get }
```

Returns the axis-aligned bounding box of everything the body draws: the mesh positions in `vertexData` (stride 6, positions at offsets 0-2), or `vertices` when `vertexData` is empty (point clouds and direct-mesh bodies), plus every point of every `edges` polyline and the full circle of every `arcs` entry (conservative for a partial arc). Used for near/far clip-plane fitting, frustum culling, shadow framing, pick culling and `CameraState.fit(to:)`. Returns `nil` if the body has no points at all.

Edges have counted since issue #135. Before that, an edge lying in front of its mesh could be cut off by the near plane, and an edge-only body had no bounds, so it was never culled and was ignored by fit-to-view.

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

Looks up the three vertex positions from `indices`/`vertexData` (stride 6), or from `vertices` on a direct-mesh body (whose `vertexData` is empty), transforms each into world space via `transform`, and intersects with the ray using Möller-Trumbore. Returns `nil` if `triangleIndex` is out of range or the ray misses the (transformed) triangle.

`triangleIndex` matches `PickResult.triangleIndex` for a `.face` pick result — pass the two together to find where the user tapped on a surface. That index is always exact, whatever the body's triangle count.

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

### `resolveWrappedTriangleIndex(_:ray:)` *(deprecated)*

```swift
@available(*, deprecated)
public func resolveWrappedTriangleIndex(_ wrappedIndex: Int, ray: Ray) -> Int?
```

Resolves a *wrapped* face-pick triangle index to the exact triangle under `ray`. Before issue #160 the GPU pick format carried 14 bits of primitive index, so on a body with more than 16,384 triangles a face pick reported the true index modulo 16,384 and set `PickResult.isPrimitiveIndexAmbiguous`. The pick target is now RG32Uint and `PickResult.triangleIndex` is always exact, so there is nothing to resolve and nothing in the library calls this any more.

It stays for callers that still hold a wrapped index. It tests each congruent candidate (`wrappedIndex`, `wrappedIndex + 16_384`, …) against `ray` in world space and returns the one hit nearest the ray origin. It costs one ray-triangle test per 16,384 triangles, and returns `nil` when `wrappedIndex` is outside `0..<16_384` or the ray hits no candidate.

---

## Primitive factories

Convenience static methods on `ViewportBody` that generate common CAD primitives with interleaved vertex/normal data, triangle indices, closed polyline edges, and `faceIndices`. All are defined in `Primitives.swift`. Triangles wind counter-clockwise seen from outside, the same convention as OCCT meshes.

**Orientation.** The viewport's world is Z-up, but the factories default to Y-up (`up: .y`) for source compatibility with code written before the `up:` parameter existed. Pass `up: .z` to build a primitive that stands on the Z-up grid; see [`PrimitiveUpAxis`](#primitiveupaxis).

```swift
// Upright in the Z-up world: the cylinder's axis is +Z, the box is 0.5 tall along Z.
let post = ViewportBody.cylinder(id: "post", radius: 0.1, height: 2, up: .z)
let slab = ViewportBody.box(id: "slab", width: 2, height: 0.5, depth: 1, up: .z)
```

---

### `box(id:width:height:depth:color:up:)`

```swift
public static func box(
    id: String,
    width: Float = 1,
    height: Float = 1,
    depth: Float = 1,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0),
    up: PrimitiveUpAxis = .y
) -> ViewportBody
```

Creates a flat-shaded box centered at the origin. `height` runs along `up`: with the default `.y`, `width`/`height`/`depth` are the X/Y/Z extents; with `.z` they are the X/Z/Y extents. Six faces, four vertices each (24 vertices total, unique per face for flat normals). Twelve polyline edges (four per axis-aligned loop plus four connecting edges). `faceIndices` maps each triangle pair to its face: 0 = front, 1 = back, 2 = right +X, 3 = left −X, 4 = top, 5 = bottom. With `up: .y` front/back are ±Z and top/bottom ±Y; with `up: .z` front is −Y (toward a viewer at the front standard view), back +Y, top +Z and bottom −Z.

**Example:**

```swift
let crate = ViewportBody.box(id: "crate", width: 2, height: 1, depth: 1.5,
                              color: SIMD4<Float>(0.6, 0.4, 0.2, 1), up: .z)
```

---

### `cylinder(id:radius:height:segments:color:up:)`

```swift
public static func cylinder(
    id: String,
    radius: Float = 0.5,
    height: Float = 1,
    segments: Int = 64,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0),
    up: PrimitiveUpAxis = .y
) -> ViewportBody
```

Creates a cylinder centered at the origin whose axis runs along `up` (Y by default; pass `.z` for an upright cylinder in the Z-up world). Side, top cap, and bottom cap are separate geometry regions with their own normals. Polyline edges: top ring, bottom ring, and a vertical line every `segments / 8` segments (eight lines when `segments` is a multiple of 8). `faceIndices`: face 0 = side, face 1 = top cap (+`up`), face 2 = bottom cap (−`up`).

**Example:**

```swift
let pin = ViewportBody.cylinder(id: "pin", radius: 0.05, height: 0.8, up: .z)
```

---

### `sphere(id:radius:segments:rings:color:up:)`

```swift
public static func sphere(
    id: String,
    radius: Float = 0.5,
    segments: Int = 48,
    rings: Int = 32,
    color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0),
    up: PrimitiveUpAxis = .y
) -> ViewportBody
```

Creates a UV sphere centered at the origin whose poles lie on `up`. Smooth per-vertex normals. Polyline edges: one equatorial ring (perpendicular to `up`) plus four meridians (at 0°, 90°, 180°, 270°). All triangles belong to `faceIndices` face 0 (single continuous surface).

**Example:**

```swift
let ball = ViewportBody.sphere(id: "ball", radius: 0.25, segments: 64, rings: 48, up: .z)
```

---

### PrimitiveUpAxis

```swift
public enum PrimitiveUpAxis: Sendable, Hashable, CaseIterable {
    case x, y, z
}
```

The axis a primitive factory treats as up (its height, cylinder or pole axis). Each factory builds Y-up geometry and then applies a proper rotation (determinant +1, so triangle winding, outward normals, `faceIndices` and edge order are all preserved) that carries +Y onto the chosen axis.

| `up` | +Y maps to | Box `width` / `height` / `depth` run along |
|------|-----------|--------------------------------------------|
| `.y` (default) | +Y (unchanged) | X / Y / Z |
| `.z` | +Z | X / Z / Y |
| `.x` | +X | Y / X / Z |

`.y` is the default only for source compatibility. In the viewport's Z-up world (turntable orbit, standard views, lighting hemisphere, grid) `.z` is usually what you want.

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
// A 60° arc on a horizontal circle (Z-up world) at z = 0.5, radius 0.3
let arc = ViewportArc(
    center: SIMD3<Float>(0, 0, 0.5),
    radius: 0.3,
    xAxis: SIMD3<Float>(1, 0, 0),
    yAxis: SIMD3<Float>(0, 1, 0),
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
sRGB (display) albedo for dielectrics, decoded to linear for lighting; F0 tint for metals.

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
guard let index = bodies.firstIndex(where: { $0.id == "bracket" }) else { return }
var body = bodies[index]
let triangleCount = body.indices.count / 3
var styles = Array(repeating: TriangleStyle.none, count: triangleCount)
// faceIndices maps triangle → face ID; highlight face 3
for i in 0..<triangleCount where body.faceIndices[i] == 3 {
    styles[i] = TriangleStyle(color: SIMD4<Float>(0.2, 0.6, 1.0, 0.5))
}
body.triangleStyles = styles
bodies[index] = body   // `bodies` is the app's @State [ViewportBody]
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

## VertexColorMode

```swift
public enum VertexColorMode: UInt32, Sendable, Hashable, CaseIterable
```

How a mesh body's [`vertexColors`](#vertexcolors-simd4float) combine with its base colour (`color`, or `material.baseColor`) in the shaded pass. Set it on [`ViewportBody.vertexColorMode`](#vertexcolormode-vertexcolormode).

| Case | Behaviour |
|---|---|
| `.ignored` | Default. The surface uses the body colour alone, whether or not `vertexColors` is populated. Every existing render is unchanged. |
| `.multiply` | The base colour times the interpolated vertex colour, per channel. A white body shows the vertex colours as authored; a coloured body tints them. |
| `.replace` | The interpolated vertex colour replaces the base colour as the albedo. |

`.point` bodies always use their `vertexColors` and ignore this setting.

### Per-vertex colours on mesh bodies

```swift
// A scalar field (say, distance from a plane) as a colour ramp over the mesh vertices.
var body = ViewportBody.directMesh(
    id: "part", positions: mesh.vertexData, normals: mesh.normalData, indices: mesh.indices,
    color: SIMD4<Float>(1, 1, 1, 1))
body.vertexColors = field.map { t in SIMD4<Float>(t, 0, 1 - t, 1) }   // one per vertex
body.vertexColorMode = .replace
```

- **Colour space.** Set by [`vertexColorSpace`](#vertexcolorspace-authoredcolorspace), `.sRGB` by default: display values, exactly like `color`, `PBRMaterial.baseColor` and the point-cloud colours (the library's authored colours are display values, and lit surfaces decode to linear for lighting; see [Colour pipeline](Display-Lighting.md#colour-pipeline)). The colour is interpolated across the triangle as stored (sRGB), combined with the body colour (`.multiply` or `.replace`), then decoded for lighting, so a ramp looks like the same ramp drawn in any image tool, and `.unlit` shows the combined colour as is. With `.linear` the colours are linear light: they interpolate in linear light, `.multiply` combines them with the decoded body colour in linear light, lit surfaces use the result as linear albedo (no sRGB decode), and `.unlit` encodes it for display. Values outside `0...1` are clamped either way.
- **Where it applies.** The shaded pass on every mesh path: interleaved, [`directMesh`](#directmesh-direct-mesh-path), PN tessellation (`renderingQuality = .enhanced`, each patch blends its triangle's three corner colours with the patch's barycentric weights) and mesh shaders (`.maximum` on Apple9; other GPUs draw `.maximum` through tessellation, which supports it too). Also the translucent and x-ray passes, `.unlit` and `.flat` display modes, matcap, overlay-layer bodies, and `OffscreenRenderer` as well as `ViewportRenderer`. Lighting, `roughness`, `metallic`, clearcoat, emission, shadows and the selection tint still come from the material, and `triangleStyles` highlights still composite over the result.
- **What ignores it.** The shadow, depth-prepass, selection-mask and pick passes draw no colour. Edges, arcs and the selection outline keep their own colours.
- **Alpha is not read.** Only the RGB channels are used. Opacity still comes from `color.w` / `material.opacity` (and x-ray), because a body's opaque-versus-translucent pass is chosen per body, not per vertex.
- **Fallback.** An empty `vertexColors`, or one whose count does not match the mesh's vertex count, falls back to the body colour (nothing is read out of bounds). A mismatch is silent.
- **Cost.** One RGBA `Float` per vertex (16 bytes), uploaded in a buffer parallel to the vertices (the interleaved 6-float layout is unchanged), only for a body whose `vertexColorMode` is not `.ignored`. Assigning `vertexColors` takes a fresh `generation`, so the whole body re-uploads (vertex, index, tessellation patches and meshlets as well as the colours). To animate a field every frame, expect that cost on large meshes.

---

## AuthoredColorSpace

```swift
public enum AuthoredColorSpace: Sendable, Hashable, CaseIterable
```

How a body's authored per-element colours (`vertexColors`, `edgeColors`) are interpreted. Set on [`ViewportBody.vertexColorSpace`](#vertexcolorspace-authoredcolorspace) and `ViewportBody.edgeColorSpace`.

| Case | Meaning |
|---|---|
| `.sRGB` | Display (sRGB-encoded) values, drawn as given. The default. |
| `.linear` | Linear-light values; converted to display encoding when drawn. |

`ViewportBody.vertexColorSpace` takes one for `vertexColors`, `ViewportBody.edgeColorSpace` for `edgeColors`. Authored colours in the viewport are sRGB unless stated otherwise (see [Colour pipeline](Display-Lighting.md#colour-pipeline)). Also exported as `_AuthoredColorSpace` from the module.

For `vertexColors` the space applies to mesh bodies (all paths, both renderers) and to `.point` bodies:

- **Mesh, lit:** `.linear` skips the sRGB decode, so the colour is the linear albedo directly. 0.5 linear is much brighter than 0.5 sRGB (which decodes to about 0.21).
- **Mesh, `.unlit`, and point clouds:** `.linear` colours are encoded to sRGB for display (0.5 linear shows as about 0.735, a stored value of 188). Pure 0 and 1 channels look the same in both spaces.
- **Interpolation** happens in the stated space: a red-green-blue triangle in `.linear` has a lighter centre (a third of each channel is about 156 once encoded) than the same colours as `.sRGB` (85).
- **Fallbacks are unaffected.** Without usable `vertexColors`, or with `vertexColorMode == .ignored`, the body draws with `color` (always an sRGB value) exactly as before, whatever the space.

---

## RenderLayer

```swift
public enum RenderLayer: Hashable, Sendable
```

Controls when the body is drawn relative to depth testing.

| Case | Behavior |
|---|---|
| `.geometry` | Normal depth test. Default for all bodies. |
| `.overlay` | Drawn after the selection outline pass with an always-pass depth state. The body is visible even when fully occluded by other geometry, and gets no selection or hover outline. Used by manipulator widgets and similar always-on-top affordances. |

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
