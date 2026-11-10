---
title: Heightfield
parent: API Reference
---

# Heightfield

A **dynamic heightfield surface**: a grid of cell heights with a per-cell attribute and optional id,
drawn as a displaced surface and edited in place by rectangle, at interactive rates, on grids of
millions of cells. The primitive is generic: a height grid, an 8-bit attribute that picks a colour
from a 256-entry ramp, and an integer id per cell that a pick returns.

Entry points: build a [`Heightfield`](#heightfield-1), attach it with
[`ViewportBody.heightfield`](#viewportbodyheightfield), change it with
[`replace(region:heights:attributes:ids:)`](#replaceregionheightsattributesids), and read a pick
from [`PickResult.heightfield`](#pickresultheightfield).

## Topics
- [Heightfield](#heightfield-1) · [HeightfieldRegion](#heightfieldregion) · [HeightfieldHit](#heightfieldhit) · [HeightfieldPrecision](#heightfieldprecision) · [HeightfieldError](#heightfielderror)
- [ViewportBody.heightfield](#viewportbodyheightfield) · [PickResult.heightfield](#pickresultheightfield) · [heightfieldMeshCellPixels](#heightfieldmeshcellpixels) · [ViewportController.refinePick](#viewportcontrollerrefinepick)
- [How it is drawn](#how-it-is-drawn) · [Trade-offs](#trade-offs) · [Limits](#limits-and-failure) · [What is supported](#what-is-supported) · [Cost](#cost)

---

## Heightfield

`public final class Heightfield: @unchecked Sendable`

A handle, not a value. The body that references it never changes when the field does: each renderer
remembers the version of the field it last drew and uploads only the 64 x 64-cell tiles edited
since. The same handle can be drawn by any number of renderers (a live viewport and an offscreen
renderer, say) and each converges on its own.

Heights are body-local Z. Cell `(i, j)` occupies `origin + (i, j) * cellSize` to one cell further.
The surface passes through the cell **centres** (one vertex per cell), so the drawn mesh spans half
a cell inside that rectangle on every side. `localBounds` is the full rectangle, so it is half a
cell loose.

### `init(width:height:origin:cellSize:initialHeight:precision:tracksIDs:) throws`

```swift
init(
    width: Int, height: Int, origin: SIMD2<Float> = .zero, cellSize: SIMD2<Float> = SIMD2(1, 1),
    initialHeight: Float = 0, precision: HeightfieldPrecision = .float32, tracksIDs: Bool = false
) throws
```

Every cell at `initialHeight`, attribute 0, id 0. Throws a [`HeightfieldError`](#heightfielderror)
before allocating anything when a side is under 2 or over
[`maximumDimension`](#static-let-maximumdimension), or the cell size is not finite and positive.

```swift
let field = try Heightfield(width: 2000, height: 2000, cellSize: SIMD2(0.5, 0.5), initialHeight: 20)
```

### `init(width:height:origin:cellSize:heights:attributes:ids:precision:tracksIDs:) throws`

Row-major arrays, row 0 first. `attributes` and `ids` default to 0; passing `ids` implies
`tracksIDs`. Throws `HeightfieldError.countMismatch` for an array that does not hold
`width * height` values, and the same size and cell-size errors as above.

### Static values

| Name | Value |
|------|-------|
| `rampSize` | 256 |
| `maximumDimension` | 16,321 |
| `defaultMeshCellPixels` | 4 |
| `meshCellPixelsRange` | `1...32` |

#### `static let maximumDimension`

The most cells a side can have. The GPU height texture is padded to whole 64-cell tiles plus one,
and a Metal texture is at most 16,384 texels wide, which allows 16,321 cells (16,320 quads). A
larger field throws at creation, never at draw time. Memory is the other limit; see
[Limits](#limits-and-failure).

### Properties

| Property | Meaning |
|----------|---------|
| `width`, `height` | Cells along X and Y. |
| `origin`, `cellSize` | Body-local XY of the corner of cell (0, 0), and the size of one cell. |
| `precision` | GPU storage precision of the heights. The CPU mirror is always 32-bit. |
| `tracksIDs` | Whether the field keeps an id per cell. |
| `version` | Incremented by every `replace` and ramp change. |
| `heightRange` | The lowest and highest height held; see [the running range](#heightrange-and-recomputeheightrange). |
| `boundsVersion` | Bumped whenever `heightRange` changes. |
| `localBounds` | Footprint by `heightRange`, in body space. |
| `ramp` | The 256-entry colour ramp (`SIMD4<Float>`), in `rampColorSpace`. Entry 0 is never used. |
| `rampColorSpace` | `.sRGB` (default) or `.linear`. |

Changing `ramp` or `rampColorSpace` replaces a 4 KB buffer and uploads no height data.

### `replace(region:heights:attributes:ids:)`

```swift
func replace(
    region: HeightfieldRegion, heights: [Float], attributes: [UInt8]? = nil, ids: [UInt32]? = nil)
```

Replaces a rectangle of cells in place. `heights` is row-major with `region.width` values per row;
`attributes` and `ids` are the same shape, and `nil` leaves that channel as it was (`ids` is ignored
unless `tracksIDs`). A region that reaches past the field is clipped. A count that does not match
the region is a programmer error and traps.

The call copies the rows into the CPU mirror and logs the rectangle. The GPU upload happens at the
next draw, **per tile**, however many edits piled up: 200 overlapping edits of one region upload each
touched tile once. A renderer that skipped frames, or fell more than 4,096 edits behind, uploads
what it needs (or, past the log, the whole field once) and still matches.

```swift
field.replace(
    region: HeightfieldRegion(x: 600, y: 480, width: 130, height: 120),
    heights: newHeights,                                   // 130 * 120 values
    attributes: [UInt8](repeating: 3, count: 130 * 120),   // colour them from the ramp
    ids: [UInt32](repeating: eventID, count: 130 * 120))
```

`replace` runs on the caller's thread under a lock and is safe from any thread. On an M4 in a release
build, a 130 x 120 region takes about 21 microseconds; 200 of them (3.1 million cells) take 2.6 to
4.2 ms, which is the practical CPU limit of the update path.

### `heightRange` and `recomputeHeightRange()`

`heightRange` is a **running** range: it grows with every edit and never shrinks on its own. After an
edit that lowers the surface it can exceed the true extremes, so `localBounds` (the camera fit, the
clip-plane fit, tile culling, the ray march's early-out) is slightly conservative. It never changes
the picture or a pick. Tracking exact extremes under region edits would cost a rescan of every
touched tile on each `replace`, which is the update path's limiter.

Call `recomputeHeightRange()` when the slack matters (after a bulk lowering, or between playback
passes). It is O(cells), makes the range exact, and bumps `boundsVersion` only if the range changed.
Caches of the body's bounds (`PivotStrategy`, the overlay bounds, the renderers) key on that version,
so they re-measure.

### `sample(x:y:)`

```swift
func sample(x: Int, y: Int) -> (height: Float, attribute: UInt8, id: UInt32?)?
```

The cell's current contents from the CPU mirror, or `nil` outside the field.

### `cell(atLocal:)`

```swift
func cell(atLocal point: SIMD2<Float>) -> SIMD2<Int>?
```

The cell containing a body-local XY point, or `nil` outside the field.

### `raycast(origin:direction:maxDistance:)`

```swift
func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = .infinity)
    -> (distance: Float, cell: SIMD2<Int>)?
```

The first hit of a **body-local** ray on the full-resolution surface. It walks the quads the ray's XY
projection crosses (Amanatides and Woo), skips a quad whose corner heights the ray passes clear of,
and tests the two triangles the renderer draws per quad. It is exact at any level of detail, one
step per quad crossed (about 75 microseconds for a grazing ray across 2,000 cells in a debug build),
and it matches a brute-force test of every quad. `direction` need not be unit length; the distance
is in its units. `SceneRaycast` uses it for a heightfield body, so the dynamic pivot and
focus-on-point work on one.

---

## HeightfieldRegion

`public struct HeightfieldRegion: Sendable, Hashable`

`x`, `y` (the first cell) and `width`, `height` (the extent), all `Int`; `cellCount` and `isEmpty`.

## HeightfieldHit

`public struct HeightfieldHit: Sendable, Hashable`

The cell a pick landed on and what it held when the pick was decoded: `cell` (`SIMD2<Int>`),
`cellIndex` (`y * width + x`, also `PickResult.triangleIndex`), `height`, `attribute` and `id`
(`UInt32?`, `nil` unless the field tracks ids).

## HeightfieldPrecision

`public enum HeightfieldPrecision: Sendable, Hashable`: `.float32` (the default, an `r32Float`
texture) or `.float16` (`r16Float`: half the height memory and upload, 11 bits of mantissa). Where
the platform cannot write half floats (Intel Macs, which have no `Float16` in Swift) `.float16`
falls back to `.float32`; `HeightfieldGPU.storageFormat(for:supportsHalf:)` is that decision.

## HeightfieldError

`public enum HeightfieldError: Error, Sendable, Hashable, CustomStringConvertible`

| Case | When |
|------|------|
| `sizeTooSmall(width:height:)` | A side under 2 cells: a surface needs at least one quad. |
| `sizeExceedsMaximum(width:height:maximum:)` | A side over `Heightfield.maximumDimension`. |
| `countMismatch(name:expected:actual:)` | `heights`, `attributes` or `ids` not `width * height` long. |
| `invalidCellSize(_:)` | A cell size that is not finite and positive on both axes. |

---

## ViewportBody.heightfield

```swift
var heightfield: Heightfield? { get set }
```

Also an `init` parameter (`heightfield:`), `nil` by default. A body with a heightfield **draws and is
bounded by the field alone**: its `vertexData`, `edges`, `arcs` and the like are ignored. `color`,
`material` (so opacity), `transform`, `isVisible`, `isPickable`, `renderLayer` and `pickLayer` apply
as for a mesh. Assigning a different handle takes a fresh `generation`; editing the field does not
(it changes `boundsKey`, which every bounds cache keys on, so a cached bounding box never goes stale).

```swift
let body = ViewportBody(
    id: "stock", vertexData: [], indices: [], edges: [],
    color: SIMD4(0.7, 0.72, 0.75, 1), heightfield: field)
```

## PickResult.heightfield

```swift
let heightfield: HeightfieldHit?
```

For a pick of a heightfield body, the cell with its height, attribute and id; `nil` for every other
pick. The result is an ordinary `.face` pick: `triangleIndex` is the cell index. Height, attribute
and id are read from the CPU mirror when the pick is **decoded**, so they are the values at the pick,
not at the frame that was drawn. Offscreen picks (`OffscreenRenderer.performPick`,
`renderPickMap`) carry it too.

The GPU pick hits the surface **as drawn**, which at a coarse level of detail is the min-lowered
surface, so an oblique pick can land cells from the true one (measured: a median of 1 cell at the
natural level on smooth ground, and tens of cells beside a 30-unit step at 57 degrees off vertical;
a top-down pick is exact at every level). [`refinePick`](#viewportcontrollerrefinepick) makes it
exact.

## heightfieldMeshCellPixels

```swift
ViewportConfiguration.heightfieldMeshCellPixels: Float   // default 4
OffscreenRenderOptions.heightfieldMeshCellPixels: Float  // default 4; init(matching:) copies it
```

The widest a mesh cell may appear on screen. Each tile is drawn at the coarsest level of detail whose
cell is no wider than this. **Documented range `1...32`** (clamped when drawn); the sensible range is
3 to 8.

- **4 (the default)** is the balanced setting: about 2.6 ms of GPU time for a 2000 x 2000 field on an
  M4 at 1668 x 1194 with 4x MSAA.
- **2 is a cost cliff**: about nine times the 4 px cost (24 ms against 2.6 ms), because tiles become
  1.7 million triangles of one to two pixels each, which MSAA 4 and a lit fragment make expensive.
  MSAA 1 at 2 px is 3.6 ms. Pay it only where a cell-exact silhouette matters.
- 8 costs about 1.2 ms.

An older GPU will have its cliff elsewhere; these numbers are from an M4 (see [Cost](#cost)).

## ViewportController.refinePick

```swift
func refinePick(_ result: PickResult?, ndc: SIMD2<Float>, bodies: [ViewportBody]) -> PickResult?
```

Re-casts the camera ray through `ndc` against the picked field's full-resolution heights with
`Heightfield.raycast` (microseconds) and returns the result with `heightfield` and `triangleIndex`
set to the cell the ray really enters. A result that is not a heightfield pick, or whose ray misses
the field (a pick a few pixels off its silhouette), comes back unchanged.

`MetalViewportView` applies it to every tap before `handlePick(result:ndc:)`, so
`controller.pickResult?.heightfield` and `onPick` are exact at every level of detail. Call it
yourself for a pick you take with `ViewportRenderer.performPick` and route elsewhere. A **region
pick** has no single ray: it reports the cell of the drawn surface under each pixel.

---

## How it is drawn

- **Tiles.** The field is 64 x 64-cell tiles, drawn instanced, one indexed draw per level of detail
  present (at most 7) per pass. There is no vertex buffer: positions come from `[[vertex_id]]` and
  the tile's `[[instance_id]]`.
- **Displacement.** One shader function (`hfDisplace`) reads the height texture with integer fetches,
  and every pass's vertex function calls it, so the shaded, shadow, depth and pick passes agree to the
  bit (tested: 65,536 of 65,536 depth values identical, seams and forced levels included).
- **Level of detail.** The CPU picks each tile's level from its projected cell width and the
  [mesh cell target](#heightfieldmeshcellpixels): stride 1, 2, 4 ... 64 cells. The height texture is
  mipmapped and level L holds a **min pyramid** (built by a compute kernel, only over the tiles an edit
  touched): texel `k` is the minimum height of the cells it covers, so pits, slots and steps survive at
  a distance.
- **No cracks.** An edge vertex of a finer tile that is not a vertex of the coarser neighbour
  interpolates between the coarser tile's edge vertices, and a tile corner takes the coarsest level of
  the four tiles meeting there; both tiles compute the same value. A test renders a 2000 x 2000 field at three levels from below the
  sheet, where a gap shows the background, and finds no hole (a one-off control with the snapping
  disabled in the shader found 391).
- **Shading.** Normals come from central differences on the full-resolution heights (so shading and
  the colour boundary are exact within one texel at any level). Attribute 0 shades with the body's
  material; any other value replaces the albedo with the ramp entry. Lighting, shadows, IBL, tone
  mapping and section planes are the mesh path's, through a shared fragment body.
- **Updates.** Edits are logged. Each renderer, once per frame, coalesces the log into dirty tiles,
  copies those runs from the CPU mirror into a pooled staging buffer and blits them into the private
  textures at the head of the frame's command buffer. The CPU never writes a texture the GPU may be
  reading, whatever the frames in flight, and an edit made before a frame is in that frame.

## Trade-offs

**The pyramid window is hierarchical (`s - 1`).** Level L texel `k` is the minimum of level L-1
texels `2k-1`, `2k`, `2k+1` on each axis, so the window reaches `s - 1` cells either side of a vertex
(`s = 2^L`) and nests. The interpolated coarse surface therefore **never rises above the true one**,
and a one-cell pit keeps its full depth at every level (49.9 of 50 units at stride 8). The price is
that a step edge can sit up to **1.5 mesh cells** off its true position (measured: 1.0 px at the
natural zoom, 3.6 px at the 4 px target; shading stays exact).

The alternative is a window of `s/2` built straight from level 0 (about three times the pyramid
reads, still cheap): it holds a step to under one mesh cell, but a thin pit that falls between two
vertices keeps only `1 - d/s` of its depth (62% at worst for `s = 8`, up to 38% lost). A thin removed
slot vanishing at a zoom level was judged the worse failure, so the hierarchical window is the one
built. Because the error is always toward the high side (the minimum lowers the low side outward), a
surface drawn from a coarse level is conservative, never an over-estimate.

**Picks and the min-lowered surface.** See [`PickResult.heightfield`](#pickresultheightfield) and
[`refinePick`](#viewportcontrollerrefinepick).

## Limits and failure

- A side is at most `Heightfield.maximumDimension` (16,321) cells. This is enforced at creation (a
  throwing `init`), so a field that cannot be drawn is never built.
- Memory per cell, for a 2000 x 2000 field: the CPU mirror holds 4 bytes of height, 1 byte of
  attribute and 4 bytes of id (if tracked), 20 MB at 2000 x 2000 without ids; the GPU holds the height
  texture (4 bytes, or 2 with `.float16`, per padded texel) plus about a third more for the pyramid
  and 1 byte of attribute: about 25 MB. A 16,321-cell side is over 1 GB of each; size the field to
  the device.
- The per-frame CPU plan (level of detail, culling, seams) is linear in the tile count: about
  0.12 ms for the 1,014 tiles of a 2000 x 2000 field in a release build on an M4. A field near the
  maximum side has 65,000 tiles; extrapolating, its plan would take several milliseconds a frame.
  That is **not measured**, and a field that large is outside what the spike validated.
- If the GPU still cannot allocate a field (the device's texture limit is lower than 16,384, or memory
  is exhausted), the renderer logs once through `os.Logger` (subsystem `OCCTSwiftViewport`, category
  `Heightfield`, error level) and does not draw that field. It does not retry every frame, and it
  never half-draws.
- `.float16` falls back to `.float32` where the platform has no half floats.

## What is supported

| Feature | Behaviour |
|---------|-----------|
| Shaded, flat, unlit, x-ray, shaded with edges | Drawn. A heightfield has no edge geometry, so "with edges" adds nothing. |
| `.wireframe` | **Defined no-op**: nothing is drawn, nothing is picked, no crash. A lattice view is not provided; use `.shaded`. |
| Translucency (`opacity < 1`, `.xray`) | Drawn in the sorted transparent pass with no depth writes, depth-sorted with translucent meshes by world-bounds centre. A single sheet needs no cull order. |
| Shadows | Casts shadows. The shadow plan is separate from the camera's: it keeps tiles outside the view whose shadow can fall into it, and culls the rest. |
| SSAO, silhouettes | The field writes the depth prepass (not when translucent, as for meshes). |
| Section planes | Clipped per fragment, and tiles wholly behind a plane are culled. |
| Selection | Tint, and the screen-space outline (selection mask and stencil mark), live and offscreen. |
| Overlay layer (`renderLayer == .overlay`) | Drawn after the outline with always-pass depth, in every display mode, with no shadows or outline, like a widget. Picked over geometry. |
| TAA | The jittered projection reaches the tile plan and every draw. An edit restarts accumulation (like an animated body), so a field being edited does not ghost under a still camera. |
| Per-triangle highlight, vertex colours, tessellation, mesh shaders, normal smoothing | Not applicable: the per-cell attribute ramp is the colour channel, and the surface is not a mesh. |
| Offscreen | Everything above, plus picking. |

## Cost

All measured on an M4 (10-core GPU), release build, 2000 x 2000 cells, 1668 x 1194, MSAA 4, camera
orbiting. **Nothing has been measured on an iPad or iPhone**, and an older A-series GPU's
micro-triangle and MSAA behaviour is the main risk; treat these as a ceiling on what to expect, not a
promise. A debug build is 2 to 4 times slower on the GPU and says nothing about release (the GPU is
idle-clocked between frames that are far apart; see the Rendering page).

| Scenario | GPU ms |
|----------|--------|
| Shaded, 4 px target (default) | 2.6 to 4.3 |
| Shaded + shadow map + SSAO + silhouettes | 5.2 |
| The same surface as an ordinary 2M-triangle `directMesh` body | 45 |
| Update only: 200 sliding 130 x 120 edits (12 tiles, 0.2 MB) | 0.12 |
| Update only: 200 disjoint 130 x 120 edits (797 tiles, 15.6 MB) | 1.3 |

CPU encode of a whole frame, plan included, is about 0.13 ms; `replace` x 200 is 2.6 to 4.2 ms on the
caller's thread. The benchmark is `HeightfieldPerformanceTests`, off by default:
`VIEWPORT_HEIGHTFIELD_PERF=1 swift test -c release -Xswiftc -enable-testing --filter HeightfieldPerformanceTests`.
