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
- [ViewportBody.heightfield](#viewportbodyheightfield) · [PickResult.heightfield](#pickresultheightfield) · [heightfieldMeshCellPixels](#heightfieldmeshcellpixels) · [heightfieldLatticePixels](#heightfieldlatticepixels) · [ViewportController.refinePick](#viewportcontrollerrefinepick)
- [How it is drawn](#how-it-is-drawn) · [The wireframe lattice](#the-wireframe-lattice) · [Trade-offs](#trade-offs) · [Limits](#limits-and-failure) · [What is supported](#what-is-supported) · [Cost](#cost)

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
| `defaultLatticePixels` | 16 |
| `latticePixelsRange` | `1...256` |

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

In `.wireframe` the surface is not drawn, so it is not picked either: the **lattice lines** are
(see [the wireframe lattice](#the-wireframe-lattice)). A pixel on a line returns the same `.face`
pick with the cell under it; a pixel between lines returns `nil`, as a mesh in `.wireframe` picks
at its edges and not its faces. `PickResult.heightfield` is set, and `refinePick` still makes the
cell exact.

In `.shadedWithEdges` the lattice is drawn over the surface, but it is not stamped on its own: the
surface already is, and writes the same cell under a line as the line's own stamp would. A pixel on
a line and a pixel between lines both give the surface pick, the `.face` with the cell under it and
`PickResult.heightfield` set. (A mesh's edges are picked as `.edge`s there; a heightfield has no edge
primitive for a line to report.)

With `PickingConfiguration.followsDisplayMode` off (`OffscreenRenderOptions.pickFollowsDisplayMode`
offscreen) the surface is picked in every display mode, `.wireframe` included, between the lines as
well as on them: a heightfield carries a surface, and the lattice lines are part of it. The lattice
pick is then not written. Nothing is drawn differently.

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
- **On an iPad the default is expensive.** On an iPad Pro (M2) rendering 2732 x 2048 with 4x MSAA,
  4 px costs about 20 ms, which misses 60 fps. 6 px costs about 5.8 ms, and 4 px with MSAA 1 about
  5.9 ms. 2 px is a 132 ms cliff there. The default is the same on every platform (4); set
  `heightfieldMeshCellPixels` (or the MSAA sample count) for the device. 5 px has not been measured.

An older GPU will have its cliff elsewhere; the M4 numbers are in [Cost](#cost), and the iPad
numbers are in [Cost on an iPad](#cost-on-an-ipad).

## heightfieldLatticePixels

```swift
ViewportConfiguration.heightfieldLatticePixels: Float   // default 16
OffscreenRenderOptions.heightfieldLatticePixels: Float  // default 16; init(matching:) copies it
```

How far apart the lines of the [lattice](#the-wireframe-lattice) (`.wireframe`, and `.shadedWithEdges`
over the surface) are on screen, in drawable pixels. Each tile's lines are the smallest power-of-two number of cells apart that spans at
least this many pixels, so the pitch of a line is between this value and twice it. **Documented range
`1...256`** (clamped when drawn). A value at or below the mesh cell
([`heightfieldMeshCellPixels`](#heightfieldmeshcellpixels), 4 px) draws one line per mesh cell, the
true wireframe of what the GPU draws; at the default 4 px mesh cell that is a dense hatch (about 2 to 4
pixels apart), which fades out where lines come closer than 3 pixels. It has no effect in any display
mode but those two.

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

## The wireframe lattice

`.wireframe` draws a heightfield as a **lattice**: lines of constant grid position on the displaced
surface, in the body's own colour, as an edge-only body's edges are. Nothing else of the surface is
drawn. `.shadedWithEdges` draws the same lattice over the shaded surface (see
[Over the surface](#over-the-surface-shadedwithedges) below). (The heading keeps its name, and its
anchor, from when `.wireframe` was the only mode that drew it.)

- **Same surface.** The lattice is drawn through the tile planner and `hfDisplace` the shaded passes
  use (the lattice vertex function calls it), so its lines lie on the surface that is drawn at each
  tile's level of detail, not on a polyline sampled from the heights: a line that crosses a one-cell
  step climbs the step, and a section plane, `transform`, `isVisible` and tile culling apply exactly as
  for the shaded surface. The live renderer and `OffscreenRenderer` share the implementation. An
  overlay-layer field still draws its surface in `.wireframe`, as in every mode.
- **Spacing in pixels.** Each tile's lines are `2^k` cells apart, `k` chosen on the CPU from the
  tile's on-screen cell size (see [`heightfieldLatticePixels`](#heightfieldlatticepixels), default
  16 px), never finer than the tile's mesh cell, so no line cuts across triangles. Zooming steps the
  pitch by factors of two. Where one tile's pitch is twice its neighbour's, every second line of the
  finer tile ends at the border; lines at every multiple of the coarser pitch continue across it.
- **Line style.** Width and dash follow `edgeLineConfiguration` (`useQuadExpansion = false` gives a
  one-pixel solid line); the colour is the body's own, `ViewportBody.color`, or the base colour of its
  `material` when it has one (`effectiveMaterial`, as for an edge-only body): choose one that
  contrasts with the background. A dash runs along each line, measured in the field's XY plane in body-local units from
  the field's origin, so it continues across tiles. Lines are anti-aliased by their own coverage and
  fade out where, on a surface seen at a grazing angle, they come closer than 3 pixels. As for an
  edge-only body, `edgeIntensity` and the depth fade do not apply.
- **See-through.** Lines behind a ridge are drawn, as a mesh's edges are in `.wireframe`: the surface
  writes no depth. Lines are tested against opaque geometry drawn before them but write no depth.
- **Picking.** In `.wireframe` the lines are picked, not the gaps (unless
  `PickingConfiguration.followsDisplayMode` is `false`, which picks the whole surface); see
  [`PickResult.heightfield`](#pickresultheightfield).
- **Lines at multiples of the pitch.** Lines stand at the field's cell 0 and every pitch after it, so the
  far border (the last row and column) has a line only where it falls on one.
- **Lines on a tile border.** From a pitch of 64 cells a tile's lines fall on its borders, and each of
  the two tiles that meet at a border draws its half of the line. A border is a multiple of 64 cells, so
  tiles of the same pitch, or whose coarser pitch divides the border, draw it from both sides. Where
  a neighbour's finer pitch reaches a border that this tile's coarser pitch does not, the tile draws its
  half of that line too (the tile plan says which borders, in `HeightfieldTile.lattice`), so such a
  line is as wide as any other. This arises only where neighbouring tiles differ in pitch, as they do
  under a perspective camera, and the coarser pitch is 128 cells or more. The line along the field's own
  edge, at cell 0, is the exception: one tile draws it and the surface ends at it, so it is half as wide.
- **Cost.** The lattice rasterises the same triangles as the shaded surface and keeps the fragments on a
  line, so the vertex and raster cost is the surface's, with none of its lighting. On an M4 in a release
  build (2000 x 2000 cells, 1668 x 1194, 4x MSAA, 4 px mesh cell) it measured 0.7 to 2.5 ms against 2.5 to
  4.5 ms for the shaded surface in the same sessions, and about a fifth to a third of the shaded frame
  when the two were drawn alternately, frame by frame. Those figures are noisy (the GPU's clock state
  and other load moved them threefold between runs), so read them as "no dearer than the surface", not
  as a precise number. The lattice pitch did not change it measurably, and
  [`heightfieldMeshCellPixels`](#heightfieldmeshcellpixels) moves it as it moves the surface. M4 numbers
  only; nothing has been measured on an iPad or iPhone. The benchmark is
  `HeightfieldPerformanceTests/latticeCost` (see [Cost](#cost)).

### Over the surface (`.shadedWithEdges`)

`.shadedWithEdges` draws the shaded surface as `.shaded` does, then the same lattice over it, as a
mesh's edges are drawn over its faces (#263). It is the `.wireframe` lattice pass (the same draw loop,
tile plan, `hfDisplace` and line coverage; only its vertex and fragment entry points are its own), so
the spacing (`heightfieldLatticePixels`), width and dash (`edgeLineConfiguration`), section planes,
`transform`, tile culling and the full-width lines on tile borders (the same border bits in the tile
plan) are the same; what differs is:

- **Hidden lines are hidden.** The lines are depth tested against the surface just drawn, so the surface
  hides the lines behind a ridge (the one thing `.wireframe` deliberately does not do), and a nearer body
  hides them like any other geometry. They write no depth, so the lines of one field never knock each other
  out. A translucent field (`opacity < 1`) draws its lines in the opaque pass and its surface over them,
  as a translucent mesh does with its edges.
- **No z-fighting.** The lattice and the surface are two draws of the same triangles through two vertex
  functions, so their depth agrees only to rounding in a perspective projection, and with no allowance a
  quarter of the line pixels were lost to the depth test (78 percent of them kept at 1x MSAA on a
  perspective top-down view, 92 at 4x; an orthographic projection agrees exactly). The vertex function
  therefore pulls each vertex toward the viewer along its view ray by 3 pixels' worth of world distance at
  its depth, the pull a mesh's edges get (`edgeBiasedClipPosition`), which keeps 99 percent. The pull is in
  screen pixels, so it does not depend on the near and far planes. A hidden line within 3 pixels of depth
  of the surface in front of it still shows: at a grazing angle, over a surface rougher than a cell, that
  is a few lines, as for a mesh's edges.
- **Colour.** The body's own colour would vanish into the surface, so the lines take the contrast colour a
  mesh's edges get in this mode (dark on a pale body, light on a dark one), the depth fade, and
  `edgeIntensity` (0 hides them).
- **Picking.** Not stamped separately: the surface is, and gives the same cell under a line. A pixel on a
  line and a pixel between lines both return the surface pick (`.face`, the cell,
  `PickResult.heightfield`). See [`PickResult.heightfield`](#pickresultheightfield).
- **Cost.** One more raster of the field's triangles with the lattice's cheap fragment, drawn on top of the
  surface: about **a quarter of a shaded frame**. On an M4 in a release build (2000 x 2000 cells,
  1668 x 1194, 4 px mesh cell, lattice 16 px), `.shadedWithEdges` against `.shaded` drawn alternately
  frame by frame, five runs, the paired difference (lattice frame minus the shaded frame beside it) had a
  median of 1.5 ms at 1x MSAA (1.50 to 1.53 across the runs; shaded 5.5 ms), 1.2 ms at an 8 px mesh cell
  and 4x MSAA (1.15 to 1.18 in four runs, 0.5 in one), and 1.4 to 2.5 ms at the default 4x MSAA and 4 px
  (median of the five runs 2.45); one line per mesh cell (lattice 1 px) cost 2.0 to 2.8 ms (median 2.77).
  The 4x MSAA frames were bimodal, 4 ms or 11 ms for the shaded surface, because the GPU's clock state
  moved within and between runs, and the lattice's cost moved in proportion (about 1.0 ms in the fast state,
  2.5 ms in the slow one: 23 to 28 percent of the shaded frame in each, 24 percent at 8 px). Other work
  was running on the Mac, so read it as "about a quarter of the frame", not as a precise number. M4
  numbers only; **nothing has been measured on an iPad or iPhone**. The benchmark is
  `HeightfieldPerformanceTests/latticeCost` (see [Cost](#cost)).

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
| Shaded, flat, unlit, x-ray | Drawn. A heightfield has no edge geometry, so `.xray`'s edges add nothing (the lattice is drawn only in `.wireframe` and `.shadedWithEdges`). |
| `.shadedWithEdges` | The shaded surface with the **lattice drawn over it**, in the contrast colour a mesh's edges get, with the lines behind a ridge hidden by the surface. The surface is picked as in `.shaded`. See [Over the surface](#over-the-surface-shadedwithedges). |
| `.wireframe` | A **lattice** on the displaced surface, see-through, in the body's colour with the edge configuration's width and dash; the surface itself is not drawn. The lines are picked (the cell under the pixel), the gaps are not, unless `PickingConfiguration.followsDisplayMode` is off, which picks the whole surface. See [the wireframe lattice](#the-wireframe-lattice). |
| Translucency (`opacity < 1`, `.xray`) | Drawn in the sorted transparent pass with no depth writes, depth-sorted with translucent meshes by world-bounds centre. A single sheet needs no cull order. |
| Shadows | Casts shadows. The shadow plan is separate from the camera's: it keeps tiles outside the view whose shadow can fall into it, and culls the rest. |
| SSAO, silhouettes | The field writes the depth prepass (not when translucent, as for meshes). |
| Section planes | Clipped per fragment, and tiles wholly behind a plane are culled. |
| Selection | Tint, and the screen-space outline (selection mask and stencil mark), live and offscreen. |
| Tap-to-measure | `handleMeasurementPick` takes the point from the field: the tap's ray walked over the full-resolution heights through the body's transform, as `refinePick` does, so the point is on the true surface, not the coarser drawn one. A ray that passes beside the field adds no point. `ViewportBody.worldHitPoint(ray:triangleIndex:)` is for meshes and returns `nil` for a field. |
| Overlay layer (`renderLayer == .overlay`) | Drawn after the outline with always-pass depth, in every display mode, with no shadows or outline, like a widget. Picked over geometry. |
| TAA | The jittered projection reaches the tile plan and every draw. An edit restarts accumulation (like an animated body), so a field being edited does not ghost under a still camera. |
| Per-triangle highlight, vertex colours, tessellation, mesh shaders, normal smoothing | Not applicable: the per-cell attribute ramp is the colour channel, and the surface is not a mesh. |
| Offscreen | Everything above, plus picking. |

## Cost

All measured on an M4 (10-core GPU), release build, 2000 x 2000 cells, 1668 x 1194, MSAA 4, camera
orbiting. **These are M4 numbers; they do not carry over to an iPad or an iPhone** (see
[Cost on an iPad](#cost-on-an-ipad) and [Cost on an iPhone](#cost-on-an-iphone)). An older A-series
GPU's micro-triangle and MSAA behaviour is the main risk. A debug build is 2 to 4 times slower on the
GPU and says nothing about release (the GPU is idle-clocked between frames that are far apart; see
the Rendering page).

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

### Cost on an iPad

Measured on an iPad Pro 12.9-inch (6th generation, M2), release build, 2000 x 2000 cells, rendered
offscreen at 2732 x 2048 (2.8 times the pixels of the M4 runs above, so the two tables are not
comparable one to one). Three runs; plain rows agreed to within 1%. The iPad was on battery, and the
default row rose by 8 to 10% after three minutes of continuous rendering.

| Scenario | GPU ms |
|----------|--------|
| Shaded, 4 px target, MSAA 4 (the default) | 18.4 cold, about 20 warm |
| Shaded, 4 px target, MSAA 1 | 5.9 |
| Shaded, 6 px target, MSAA 4 | 5.8 |
| Shaded, 2 px target, MSAA 4 | 132 |
| Shaded + shadow map + SSAO + silhouettes, 4 px, MSAA 4 | 35 to 41 |
| Shaded + shadow map + SSAO + silhouettes, 6 px, MSAA 4 | 13 to 18 |
| Update only: 200 sliding edits | +0.9 |
| Update only: 200 disjoint edits (15.6 MB per frame) | +2.2 |
| A pick through the pick pass | +1.2 |

`Heightfield.raycast` takes under 5 microseconds. `precision: .float16` cuts the upload from 15.6 MB
to 9.3 MB but does not change GPU time (20.3 ms against 20.4 ms). The field's roughness matters: a
field roughened with noise of plus or minus 30 units cost 28.5 ms against 20.3 ms for the smooth one
on a frame with no edits, so measure with your own data. 5 px has not been measured.

### Cost on an iPhone

Measured on an iPhone 15 Pro (A17 Pro, 6-core GPU, iOS 27.2.1), release build, 2000 x 2000 cells,
rendered offscreen at the phone's native 2556 x 1179 (3.0 million pixels, against the iPad's 5.6
million). Unplugged, Low Power Mode off, thermal state nominal at the start of each run and fair at
the end. Two runs. The figures are the same measure as the iPad table: the interval between frames
finishing, with frames queued back to back.

**The phone's speed depends on its clock state.** The first rows of a run agreed between the two runs
to within about 5%. The same default scene measured again later in a run, after a minute or more of
heavy rendering, read 1.5 to 3 times slower (the 10th-percentile frame moved with the median, so this
is the GPU's clock and not noise). Read the first column as the best case and the second as what a
phone that has been busy gives.

| Scenario | GPU ms, early in a run | Later in the same run |
|----------|------------------------|-----------------------|
| Shaded, 4 px target, MSAA 4 (the default) | 4.3 | 6 to 13 |
| Shaded, 4 px target, MSAA 1 | 2.3 to 2.4 | not measured |
| Shaded, 6 px target, MSAA 4 | 2.6 to 2.7 | not measured |
| Shaded, 8 px target, MSAA 4 | 2.2 to 2.3 | not measured |
| Shaded, 3 px target, MSAA 4 | 8.6 to 8.7 | not measured |
| Shaded, 2 px target, MSAA 4 | 46 | not measured |
| Shaded + shadow map + SSAO + silhouettes, 4 px, MSAA 4 | 11.0 to 11.6 | about 22 |
| Shaded + shadow map + SSAO + silhouettes, 6 px, MSAA 4 | 7.8 to 8.2 | not measured |
| Shaded + shadow map + SSAO + silhouettes, 4 px, MSAA 1 | 7.8 to 8.1 | not measured |
| Update only: 200 sliding edits | +0.55 to +0.56 | not measured |
| Update only: 200 disjoint edits (15.6 MB per frame) | +2.4 to +11.7, see below | not measured |
| A pick through the pick pass | within noise (-0.4 to +0.6) | not measured |

What this gives: at the default the surface alone holds a 60 fps budget (16.6 ms) in both states, and
a 120 Hz budget (8.3 ms) early in a run and not reliably once warm. With shadows, SSAO and silhouettes
on, the default misses 60 fps once the phone is warm; 6 px is about 8 ms early in a run. 3 px or finer
is the cliff.

The 200 disjoint edits case read +11.7 ms in one run and +2.4 ms in the other, because the table it
sits in runs in a different clock state each time; neither figure is reliable.
`precision: .float16` against `.float32` showed no clear difference with no edits and about 8% less
frame time with 200 disjoint edits in both runs (upload 9.3 MB against 15.6 MB).
`Heightfield.raycast` took 0 to 3.8 microseconds median and 13.6 microseconds at worst.

On the default scene the iPhone read about four times faster than the iPad table above (4.3 ms
against 18.4 ms) with 1.9 times fewer pixels, although the iPad's M2 GPU is the larger one on paper.
That is unexplained and the iPad is being re-measured, so treat the iPad figures as provisional until
it is. Not measured: the lattice (see [The wireframe lattice](#the-wireframe-lattice), and
[over the surface](#over-the-surface-shadedwithedges)) on a phone, a
5 px target, a sustained run longer than about 90 seconds, and a second iPhone.
