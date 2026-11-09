# Spike: dynamic heightfield surface (issue #139)

**Status: IN PROGRESS.** Branch `spike/heightfield-139`, cut from `origin/main` at `0751a58`
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

## Open questions / for the on-device session
(Filled in as the phases land.)
