# Spike: dynamic heightfield surface (issue #139)

**Status: COMPLETE (phases 1-4 landed, gates passed).** Branch `spike/heightfield-139`, cut from `origin/main` at `0751a58`
(v1.3.1). Research prototype, not a PR. Commits are `spike: phase N ...`.

Question: can the viewport draw a 2000 x 2000-cell height grid, updated in place by rectangle,
displaced in the vertex stage, in both renderers, without per-update mesh rebuilds, and what does it
cost to wire into every pass? API stays generic: no domain vocabulary in names, docs or tests.

## Design as built

- **Public shape** (`Types/Heightfield.swift`): `Heightfield` is a `final class` handle
  (`@unchecked Sendable` over an `OSAllocatedUnfairLock`). It owns CPU mirrors of heights (`[Float]`),
  attributes (`[UInt8]`) and optional per-cell ids (`[UInt32]`), a monotonically increasing `version`,
  a bounded change log of `(version, region)` and running min/max height. `replace(region:heights:
  attributes:ids:)` mutates in place. It is attached to `ViewportBody` as a defaulted optional
  `heightfield: Heightfield?` (not a new `BodyPrimitiveKind` case, which would break exhaustive
  switches). Precision (`.float32` default, `.float16`) and a 256-entry ramp plus
  `rampColorSpace` (default sRGB) live on the handle.
- **GPU state** (`Renderer/HeightfieldRenderer.swift`): `HeightfieldGPU` is per (renderer, body id).
  One `r32Float`/`r16Float` texture with 7 mip levels: level 0 is the height grid, levels 1-6 the min
  pyramid (stride 2^L). Padded to `(drawTiles + 1) * 64` so every level has an exact size. One `r8Uint`
  attribute texture. A 256 x float4 ramp buffer.
- **Tiles and levels**: 64 x 64-cell tiles drawn instanced. The CPU picks each tile's level from the
  projected cell width (`level = floor(log2(targetPixels / cellPixels))`, target 2 px), culls against the
  frustum, groups tiles by level and issues ONE `drawIndexedPrimitives(instanceCount:)` per level present
  (<= 7 per pass). Index buffers (uint16) are per level and shared. Vertices come from `[[vertex_id]]`
  and `[[instance_id]]`; there is no vertex buffer.
- **Displacement**: ONE MSL function `hfDisplace` (Shaders.metal) reads heights with integer
  `texture.read(coord, level)` (no filtering). Every pass's vertex function calls it.
- **Seams**: edge vertices snap to the coarser neighbour. Each tile instance carries the level shared
  with each of its 4 edge neighbours (max of the two) and with each of its 4 corners (max of the four
  tiles meeting there). A finer tile's edge vertex that is not a coarse vertex interpolates linearly
  between the coarse tile's two edge vertices; coincident vertices read the shared level. Both tiles
  compute the same value from the same inputs, so the edge is watertight. Skirts were not needed.
- **Fragment**: normal from central differences on the full-resolution level 0 (nearest cell, one-sided
  at the border); attribute from the `r8Uint` texture; attribute 0 shades as the body material (vertex
  colour mode 0), anything else replaces the albedo with the ramp colour (mode 2, +4 when the ramp is
  linear). Lighting reuses the mesh path: `shaded_fragment` was split into an `inline
  shadedFragmentBody` plus a thin entry point (a 2-hunk diff in Shaders.metal), and
  `heightfield_fragment` builds a `ShadedVertexOut` and calls the same body.
- **Cell semantic**: cell `(i, j)` owns `origin + (i, j) * cellSize` to one cell further; the surface
  passes through the cell CENTRES (one vertex per cell). The drawn mesh therefore spans half a cell inside
  the nominal rectangle on every side.

## Phase 1: render core (offscreen shaded pass)

**Gate: PASSED.**

### Pyramid
The pyramid is hierarchical: level L texel k = min of level L-1 texels 2k-1, 2k, 2k+1 on each axis
(clamped). Windows therefore reach `s - 1` cells either side of the vertex (s = 2^L) and nest, which
gives a provable property: the interpolated coarse surface never rises above the true one. Tested:
GPU levels equal a CPU reference bit for bit on a 213 x 131 random field (an awkward size, so the
padding and clamping paths run), and every coarse texel is <= the fine cell at its centre.

### Cracks
Test `noCracks`: 2000 x 2000 cells with cell-scale roughness, camera BELOW the sheet looking up at an
oblique angle so a gap shows the background colour instead of more surface (looking from above, a gap
mostly reveals more of the sheet and the test is blind: the first version of this test could not fail).
Plan used levels 1, 2 and 3 (70, 559, 147 tiles). The level-of-detail render is compared with a forced
level-0 render of the same camera; a pixel the reference covers with a margin of 8 px must not be
background.
- Seam snapping on: 0 holes.
- Negative control (snapping disabled in the shader): 391 holes more than 6 px inside the silhouette,
  up to 22 px away. Holes within 5 px of the silhouette (about 460 px in both runs) are the coarse
  levels' min heights lowering the silhouette, not cracks, hence the margin.

### Acceptance 4: step position
Measured on a 45-degree orthographic side view where the lowest pixel of each column is the height
profile; step of 100 cells at X = 1000, 0.31 cells per pixel.

| stride | step error (cells) |
|---|---|
| 1 | 0.002 |
| 2 | 1.5 |
| 4 | 2.5 |
| 8 | 4.5 |
| 16 | 16.5 |

At a zoomed-out view (2400 world units over 512 px, 4.7 cells per pixel) the natural level is 3
(stride 8) and the step is 4.7 cells = **1.0 px** from the truth.
The error is always toward the high side (min lowers the low side outward) and is bounded by 1.5 mesh
cells. A strict reading of "within one cell" (one TEXTURE cell at a zoomed-out view) is not
achievable by a mesh of stride s and is below one pixel anyway; "within one MESH cell" holds for
strides <= 8 and is 1.03 cells at stride 16. **Decision for the owner**: a window of `s/2` (built
directly from level 0, about 3x the pyramid reads, still cheap) holds the step to < 1 mesh cell at
every level, but a one-cell pit that falls between two vertices keeps only 1 - d/s of its depth (62 %
at worst for s = 8). The hierarchical window keeps every pit at full depth (measured 49.9 of 50 at
stride 8, 48.6 at stride 1, pixel-quantised). Chosen: hierarchical, because it is conservative by
construction, and a thin removed slot vanishing at a zoom level is the worse failure.
Shading is unaffected: normals and the attribute are read at full resolution, so the shaded edge and
the colour boundary are exact (within one texel) at any level.

### Dead ends and surprises
- The first crack test passed with snapping DISABLED (see above). A control experiment is part of the
  method now.
- `OffscreenRenderer.render` allocated nothing for heightfields before this work; a body with empty
  `vertexData` has no `bodyBufferCache` entry, so every draw loop that guards on it skips the
  heightfield body silently. A dedicated pass after the body loop is the cheap integration.

## Phase 2: update path

**Gate: PASSED** (correctness and cost); performance numbers below are from an M4, not an iPad.

### How it works
- `replace` copies the rows into the CPU mirror under the lock, widens the running min/max and appends
  `(version, clippedRegion)` to the change log (4096-entry ring that trims in half-blocks; a ramp change
  bumps `version` but logs nothing).
- Each `HeightfieldGPU` remembers the version it last drew. `field.changes(since:)` returns `.none`,
  `.regions([...])` or `.full` (never drawn, or the log no longer reaches back). Two renderers, or the
  same renderer after skipping frames, therefore always converge; the handle holds no per-renderer state.
- **Dirty coalescing is per tile, not by rectangle union**: a flag per 64 x 64 tile over all logged regions,
  so 200 overlapping edits upload each touched tile once.
- **Hazard-free upload**: dirty tile runs (consecutive dirty tiles in a tile row become one block) are
  memcpy'd from the mirror into a `FrameBufferPool` shared buffer (float16 converts on the way) and
  blitted into the `.private` height and attribute textures at the head of the frame's command buffer; the
  staging buffer returns to the pool in the command buffer's completion handler. The CPU never writes a
  texture or a buffer the GPU may be reading, whatever the frames in flight. The ramp is replaced by a new
  4 KB buffer rather than rewritten.
- Pyramid rebuild: one compute dispatch per level 1-6 over the dirty tiles plus a one-texel halo (a cell
  reaches one texel further at every level). Verified exact against a full rebuild after edits across tile
  edges, at the borders and at the far corner.

### Correctness evidence (all headless, `OffscreenRenderer`)
- Acceptance 2, correctness half: 400 x 400 field, replace a 130 x 120 region, fixed top-down orthographic
  camera, 1024 px: **0 differing pixels outside the region (+ one cell of halo, projected with
  `ProjectionUtility`), 95,921 inside**.
- 200 edits of 130 x 120 in one frame, disjoint and sliding-overlapping: the result is pixel-identical to a
  fresh field + fresh renderer holding the final contents.
- Two renderers on one handle, one skipping five edits: identical images, no extra full upload. After
  more than the log holds (8,200 edits) the lagging renderer does exactly one full upload and still
  matches a fresh render.
- Upload counter (`uploadedBytes`, in the style of `arcBufferPool.allocatedCount`): first draw 32 x 32 =
  1,024 tiles; one 130 x 120 region = 9 tiles = 184,320 bytes; 200 sliding regions = 12 tiles = 245,760
  bytes; 200 disjoint regions = 797 tiles = 16.3 MB (the field is 20 MB). Upload scales with dirty tile
  area, bounded by the field, never by the edit count.
- A ramp change uploads no height or attribute bytes.

### Performance (M4, 10-core GPU, release build, 2000 x 2000, camera orbiting)
`VIEWPORT_SPIKE_PERF=1 swift test -c release -Xswiftc -enable-testing --filter HeightfieldPerformanceTests`.
Never run the bench in a debug build: Swift `-Onone` made `replace` x200 take 390 ms and the plan 5-7 ms,
and the shaders also ran 2-4x slower; none of that is representative.

| scenario (1668 x 1194, MSAA 4) | GPU ms (median) | CPU encode ms |
|---|---|---|
| static, mesh cells <= 4 px (default) | 2.6 - 4.3 | 0.13 (plan 0.12) |
| static, mesh cells <= 2 px | 24 | 0.2 |
| static, mesh cells <= 8 px | 1.2 | 0.1 |
| the same surface as an ordinary 2M-triangle `directMesh` body | 45 | n/a |
| update alone, 200 sliding 130 x 120 edits (12 tiles, 0.2 MB) | 0.12 | 0.05 |
| update alone, 200 disjoint 130 x 120 edits (797 tiles, 15.6 MB) | 1.33 | 0.8 |
| `replace` x200 (3.1M cells copied into the mirror), CPU | 2.6 - 4.2 | |

Frame budget on this machine at the default: about 4.3 ms of GPU for the draw plus at most 1.4 ms for the
worst-case update = under 6 ms, which is **2.9x headroom under 16.6 ms** (just short of the 3x target) and 3.8x
for the typical sliding load. The GPU wait-per-frame bench also showed 8 - 11 ms frames with edits in some runs: the GPU
downclocks between frames that are separated by CPU work, so the update-only number is the reliable one.

Findings from the numbers:
1. **The mesh-cell target is the performance knob, and 2 px is a cliff**: stride-2 tiles are 1.7M
   micro-triangles (1-2 px each) and MSAA 4 + a lit fragment makes that 24 ms (9x the 4 px cost; MSAA 1 is
   3.6 ms). 4 px is the default. Costs: at 4 px the step lands up to 1.5 mesh cells (6 px) off, measured
   3.6 px; shading stays exact. The same surface as an ordinary mesh at the same triangle count is 45 ms.
2. **`replace` itself is the CPU limiter**: 21 us per 130 x 120 call (3.1M cells in 2.6 ms) on the caller's
   thread; fine for 200 per frame on one core but worth vectorising (it widens min/max per cell).
3. The update's GPU work is negligible; its CPU cost is dominated by the mirror-to-staging memcpy (0.8 ms for
   16 MB). Merging dirty tiles into row runs cut the blit commands from 2 per tile to 2 per run; the
   disjoint case's update GPU time is 1.3 ms.

### Dead ends and surprises
- First perf numbers were useless: debug build, test-side data generation counted as `replace`, and the
  2 px default. All three would have produced a wrong "no-go".
- Blitting one command per tile (1,600 per frame in the disjoint case) was replaced by runs; not measured
  before/after separately, since the total is small either way.

## Phase 3: picking

**Gate: PASSED** for acceptance 3 (cell, height, attribute, id through the live renderer's real pick
pass); accuracy at coarse levels is a **finding** (below), with a CPU refinement that fixes it.

### What was built
- `heightfield_pick_vertex` (the same `hfDisplace`) and `heightfield_pick_fragment`, which stamps
  `packPickID(object, cellIndex, kind 0)` where `cellIndex = y * width + x` of the pixel's position on the
  drawn surface, computed from the interpolated grid position, so it is exact laterally at any level.
  No new `PrimitiveKind`: the result is an ordinary `.face` pick whose `triangleIndex` is the cell index
  (the third kind value stays free; adding an enum case would break exhaustive switches, as feared).
  The pick pipeline lives in `HeightfieldRenderCache` and is 1 sample, `rg32Uint`, `depth32Float` like the
  other pick pipelines.
- **PickResult extension**: one additive optional field, `PickResult.heightfield: HeightfieldHit?`
  (`cell`, `cellIndex`, `height`, `attribute`, `id`). The decoder resolves it from a `[bodyID: Heightfield]`
  snapshot captured with the index map each frame, reading the CPU mirror at decode time, so the three
  decode paths (exact, neighbourhood, region) all carry it, behind a defaulted parameter (no signature
  breaks). The values are as of the pick, not as of the frame that was drawn.
- The live `ViewportRenderer` got the heightfield cache, the update/plan step at the head of the frame
  (`prepare`), the shaded draw and the pick draw. That is about 70 lines in `ViewportRenderer.swift`
  and made `renderHeadlessBGRA` + `performPick` the test vehicle, as asked.
- `Heightfield.raycast(origin:direction:)`: Amanatides-Woo walk of the quads the ray crosses, skipping a
  quad the ray passes clear of, testing the two triangles the GPU draws. Hooked into
  `SceneRaycast.cast` (a 6-line branch before `TrianglePositions`), so `PivotStrategy` and
  focus-on-point work on a heightfield.
- Bounds: `ViewportBody.boundingBox` has a heightfield branch (surface footprint x running height range).

### Evidence
- Exact pick, 300 x 200 field with distinct height/attribute/id in every cell, top-down: 56 pixels across the
  field, every one returned the analytically expected cell, its height and attribute equal the mirror's, and
  the id equals `x * 1000 + y`; `triangleIndex == cellIndex`, kind face.
- A mesh body above the field wins its pixels and carries no heightfield payload; off-field pixels miss; the
  field's `bodyIndex` is its draw-order index. A pick after `replace` (no new frame) sees the new height,
  attribute and id. A region pick returns every distinct cell under the rectangle (between 300 and 500 distinct cells for a rectangle about 20 x 20 cells).
- `Heightfield.raycast` equals a brute-force every-quad intersection on 600 random rays (from above,
  grazing, from below, a non-unit cell size and a non-zero origin): same hit/miss, same distance to 1e-3.
  Cost: 75 us for a near-grazing ray across 2000 cells in a DEBUG build.
- `SceneRaycast.cast` hits a scaled and translated heightfield body and honours clip planes.

### Pick accuracy at coarse levels (the honest part)
The GPU pick hits the DRAWN (coarse, min-lowered) surface, so the cell is where the view ray meets that
surface, not the true one. The error in cells is about `(true - coarse height) * tan(angle off vertical)`.
Measured at 57 degrees off vertical, 1000 x 1000 cells, 90+ picks per cell (distance in cells between the
GPU-picked cell and the exact `raycast` cell):

| terrain | level 0 | level 1 | level 2 | level 3 | level 4 | natural (4 px) |
|---|---|---|---|---|---|---|
| smooth hills, median / p90 / max | 0 / 0 / 1 | 1 / 1 / 2 | 1.4 / 3 / 5 | 4 / 7 / 11 | 7 / 16 / 30 | 1 / 3 / 8 |
| plateaus with 30-unit steps | 0 / 0 / 0 | 0 / 2 / 8 | 2 / 17 / 68 | 6 / 58 / 77 | 22 / 89 / 143 | 2 / 9 / 68 |
| cell-scale roughness (+-10) | 0 / 0 / 4 | 18 / 30 / 42 | 22 / 36 / 74 | 25 / 40 / 82 | 29 / 47 / 94 | 21 / 36 / 74 |

So: exact at level 0; a cell or two on smooth ground at the natural level; **tens of cells beside a tall step
or on very rough ground at an oblique angle**, because min-lowering moves the drawn surface by the step
height there. **Recommendation: use the GPU pick for body and approximate cell, then refine with
`Heightfield.raycast` along the same view ray** (microseconds), which is exact at every level; a top-down
pick is already exact at every level. The refinement is not wired into `performPick` (it needs the
ray, which the pick pass does not have); doing so is a small follow-up in the controller.

### Bounds invalidation (found by a failing test)
`PivotStrategy` caches each body's box keyed by `body.generation`. A heightfield edit leaves the
generation alone, so after an edit raised the surface the cached box kept the old top and a ray that should
hit the raised block missed (a control run without the fix fails the test). Fixed with a `boundsKey`
(`generation` mixed with the field's `boundsVersion`, which `replace` bumps only when the running
min/max grow). Sites that read `body.boundingBox` directly (the renderers' per-frame scene bounds, the
live renderer's `cachedLocalBounds` which has no buffer entry for a heightfield body) are always current;
`ViewportController.overlayBoundsCache` is keyed by generation too but is overlay-only. Any future cache
keyed by `generation` must use `boundsKey`. The running range never shrinks, so bounds can be loose;
`recomputeHeightRange()` is the O(cells) reset.

## Phase 4: integration cost

**Gate: PASSED.** Shadow and SSAO / silhouette depth are wired in BOTH renderers; the live shaded pass was
cheap (it came with phase 3's `prepare` call).

### Depth equality across vertex functions (unknown 1)
`depthEqualAcrossPasses`: one 500 x 500 field with a rotating, non-uniformly scaled, translated body
transform and a perspective camera, drawn through the real shaded (`heightfield_vertex` +
`heightfield_fragment`), shadow (`heightfield_shadow_vertex`, the light matrix set to the camera's) and
depth-only (`heightfield_depth_vertex`) pipelines into three depth textures, then read back. **All 65,536
pixels are bit-identical (worst difference 0.0) for the natural levels (several in use, seams included),
forced level 0 and forced level 3.** About 14,000 pixels are covered, and a second test proves the
comparison can fail (level 0 against level 4 differ in more than 500 pixels). The reason it holds: every
pass calls the one MSL function `hfDisplace`, and the plan (levels, instances, seam levels) is computed once
per frame and shared.

Also checked: shadow casting (a 40-high block throws a shadow over 3,738 pixels, identical count in the live
and the offscreen renderer), silhouettes see the field's depth (1,040 pixels, identical in both), section
planes cut it (the footprint halves), live and offscreen shaded output are pixel-identical (0 differing
pixels, shadows on), float16 heights render identically to float32 for exactly representable values at half
the height upload.

### Cost of the extra passes (M4, release, 2000 x 2000, 1668 x 1194, MSAA 4, 4 px target)
| passes | GPU ms |
|---|---|
| shaded only | 2.6 |
| shaded + shadow map + SSAO + silhouettes | 5.2 |

Draw count: one instanced draw per level present per pass. The test camera has 2 levels in use, so 2 draws per
pass, 8 across shaded + shadow + depth + pick (a mesh body is 1 per pass, 4); the worst case is 7 levels x 4
passes = 28 draws. CPU encode of the whole `render` call, plan included, is 0.13 ms in release; the plan
(levels for 1,014 tiles, neighbour levels, frustum cull, instance buffer) is 0.12 ms. A tile costs 16 bytes
of instance data; 1,014 tiles is 16 KB per frame.

### Remaining integration sites (unknown 5)
Done in the spike: shaded opaque (both), shadow (both), SSAO / silhouette depth prepass (both), pick (live;
the offscreen renderer has no pick pass at all), section planes (every fragment stage), bounds
(`boundingBox`, which feeds scene bounds, clip-plane fitting, shadow framing, grid and axes sizing, camera
fit), `SceneRaycast`, `PivotStrategy` cache, per-body frustum culling (the tile cull replaces it).

| site | renderers | what is needed | estimate |
|---|---|---|---|
| Translucent surface (`opacity < 1`, `.xray`) | live transparent pass, offscreen transparent pass | Today an alpha < 1 field draws in the opaque pass, blended but writing depth. Defer to the sorted pass with the no-write depth state (no cull order needed for a sheet), depth-sort by world bounds, skip the depth prepass (`writesSSAODepth` already does), decide pick | 1 day |
| Selection mask + stencil mark + outline (#209) | both (`selectionMaskDraws`, `stencilMask` loops) | Tint already works (`isSelected`). The outline needs the mask pass (`heightfield_depth_vertex` + `selection_mask_fragment`) and a stencil-only pipeline for the mark, plus a loop in each place | 1 day |
| Wire / edges display mode, `edgeDrawRange`, `edgeColors` | both | A heightfield has no edge geometry. `.wireframe` currently draws nothing for it. A lattice would need per-level line index buffers and a `heightfield_wire_vertex` pipeline | 1-2 days, only if wanted |
| Clip-plane tile culling | both | Correct already (fragment discard); culling whole tiles against the planes is perf only | 0.5 day |
| Shadow tile culling | both | The shadow pass reuses the camera's tile list, so an off-screen tile casts no shadow. Needs a second plan against the light frustum (0.12 ms) | 0.5 day |
| Overlay layer (`renderLayer == .overlay`) | both | Not drawn. Draw in the overlay pass with always-pass depth, or document as unsupported | 0.5 day |
| Per-triangle highlight (`triangleStyles`) | both | N/A by construction: the per-cell attribute ramp is the equivalent. `highlight` pipelines skip heightfield bodies | 0 |
| Vertex colours (`vertexColorMode`) | both | N/A: the ramp replaces them | 0 |
| Tessellation, mesh shaders (`renderingQuality`), normal smoothing | both | N/A: a heightfield bypasses them | 0 |
| TAA | live | The jittered projection reaches the plan and every draw, so it works. A surface that is being edited ghosts in the history like any animated body (not tested) | 0.5 day to check |
| Offscreen pick | offscreen | There is no pick pass in `OffscreenRenderer` for any body. A shared one would serve all body kinds | inherited gap |
| Refine a pick with `raycast` | live | `performPick` has no ray; the refinement belongs in the controller where the camera is known | 0.5 day |
| Public configuration | both | Level-of-detail target (pixels), maybe tile size; currently internal vars | 0.5 day |
| Limits and failure paths | both | Fields wider than the device's 16,384-texel limit (the padded texture) fail `HeightfieldGPU.init`, which today silently draws nothing; a throwing or logging path is needed. Intel Macs have no `Float16`, so `.float16` falls back to float32 there | 0.5 day |
| Docs, cookbook, CHANGELOG bullets, DocFigures | n/a | per `docs-current.md` | 1-2 days |

Roughly **6-9 working days** to finish, none of it risky; the renderer-side structure is the same
`prepare` call, plan and per-level draw helper in every case.

## Answers to the five unknowns

1. **Displacement consistency and seams**: one shared MSL function, verified bit-identical across shaded,
   shadow and depth, and a crack-free proof with a negative control. Seams: snap the finer edge to the coarser
   neighbour, with corner levels as the max of four tiles; no skirts. Cost: 8 neighbour levels packed in the
   per-tile instance (4 bytes).
2. **Hazard-free upload**: dirty-tile runs staged through a `FrameBufferPool` buffer, blitted at the head of the
   command buffer into private textures, returned in the completion handler. 12 dirty tiles: 0.12 ms GPU,
   0.05 ms CPU; 797 tiles (15.6 MB): 1.3 ms GPU, 0.8 ms CPU. Latency: an edit made before a frame is in that
   frame (same command buffer), one frame of CPU-to-screen.
3. **Pick payload**: cell index in the existing G channel (kind face), no new enum case; height, attribute and
   id from the CPU mirror through an additive `PickResult.heightfield`. CPU raycast: a grid walk, 75 us for a
   grazing 2,000-cell ray in a debug build (exact, matches brute force). Bounds invalidation: the running
   range, plus `boundsKey` for caches keyed by `generation` (found by a failing test).
4. **Draw count x passes and CPU encode**: see above; 2-7 draws per pass, 0.13 ms.
5. **Remaining integration breadth**: the table above.

## Go / no-go

**GO**, to build it for real, with these conditions:
- Default to a **4 px mesh-cell target** (2 px is a 9x cost cliff) and expose it.
- Treat **min-lowered coarse levels as a known visual/pick trade-off** and give the owner the
  `s - 1` versus `s / 2` window decision (steps within 1.5 versus 1 mesh cells, pits keep full depth versus
  part of it). Refine picks with `Heightfield.raycast`.
- Budget the 6-9 days above, and the iPad measurement before promising 60 fps there.

Main risk: **the iPad GPU's micro-triangle and MSAA behaviour**. On an M4 the same 2M-triangle surface as a
plain mesh costs 45 ms and the heightfield at 4 px costs 2.6 ms, but the cliff between 2 px (24 ms) and 4 px
(2.6 ms) shows how sensitive it is to triangle size, and an older A-series GPU will have its cliff elsewhere.
Second risk: `replace` on the caller's thread (4-7 ms for 200 x 130 x 120 in release).

## For the on-device session (DirectMeshVerify rig)
Build a field of 2000 x 2000 with the `HeightfieldScene` terrain and measure, on the iPad, in a RELEASE build:
1. GPU frame time (`gpuEndTime - gpuStartTime`) for the orbiting camera at the native resolution, MSAA 4 and 1,
   mesh-cell target 2, 3, 4, 6, 8 px: find the cliff.
2. The same with shadows + SSAO + silhouettes on.
3. 200 `replace` calls of 130 x 120 per frame, sliding and disjoint: `replace` CPU ms, `uploadedBytes`, update
   GPU ms (`HeightfieldGPU.timedUpdate`), and whether the frame holds 16.6 ms.
4. `.float16` versus `.float32`: frame time and upload.
5. Sustained 60 fps over several minutes (thermal), memory (a 2000 x 2000 field is 16 MB + 5 MB pyramid + 4 MB
   attributes, plus the pick texture), and a GPU frame capture of the vertex-stage texture fetches.
6. Whether `texture.read(coord, level)` on a mipmapped `r16Float` texture written by a compute kernel behaves on
   A-series as on the M4 (it was only run on the M4).
Run the bench with `VIEWPORT_SPIKE_PERF=1 swift test -c release -Xswiftc -enable-testing --filter
HeightfieldPerformanceTests` on the Mac; the iPad needs the rig.

## Adjacent findings (not fixed)
- `OffscreenRenderer` has no pick pass for any body type; headless picks need `ViewportRenderer`.
- Caches keyed by `ViewportBody.generation` (`PivotStrategy`, `ViewportController.overlayBoundsCache`) assume
  geometry only changes with the generation. That holds for mesh bodies and broke for an in-place mutable
  handle; a general `boundsKey`-style hook would stop the pattern recurring.
- In a debug `swift test` run the GPU times were 2-4x worse than in a release run (observed on the same
  scenes; plausibly an unoptimised metallib, not confirmed), so any GPU timing from a debug test run is
  misleading, and nothing warns about it.
- `ViewportBody` has no way to say "this field changed" to SwiftUI diffing; here that is intentional (the
  MTKView redraws every frame), but a consumer using on-demand drawing would need a redraw call.
