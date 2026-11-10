---
title: Heightfield Surfaces
parent: Cookbook
nav_order: 13
---

# Heightfield Surfaces

A `Heightfield` is a grid of cell heights drawn as a displaced surface and edited **in place by
rectangle**, so a surface of millions of cells can change many times a frame. Use it when a surface
is a height function over a plane and changes over time (terrain, a stock block being cut away, a
simulation grid) and rebuilding a mesh per change would be far too slow. For ordinary geometry use
a [`ViewportBody` mesh](loading-geometry.md).

Each cell has a **height**, an 8-bit **attribute** that picks a colour from a 256-entry ramp
(0 means "untouched": shaded as the body's own material), and an optional 32-bit **id** that a pick
returns, so you can map a click back to whatever last changed the cell. The exhaustive surface is the
[Heightfield reference](../../reference/Heightfield.md).

---

## Build a field and put it on screen

```swift
import OCCTSwiftViewport

// 2000 x 2000 cells, each 0.5 units wide, starting flat at height 20. `ids` are returned by picks.
let field = try Heightfield(
    width: 2000, height: 2000, cellSize: SIMD2(0.5, 0.5), initialHeight: 20, tracksIDs: true)

let stock = ViewportBody(
    id: "stock", vertexData: [], indices: [], edges: [],
    color: SIMD4(0.72, 0.74, 0.78, 1), material: PBRMaterial.steel,
    heightfield: field)

// bodies: [stock] on a MetalViewportView, as for any other body.
```

The initializer throws a `HeightfieldError` for a side under 2 or over `Heightfield.maximumDimension`
(16,321 cells), for a cell size that is not finite and positive, and for arrays of the wrong length,
so a field that cannot be drawn never gets built:

```swift
do {
    _ = try Heightfield(width: 20_000, height: 20_000)
} catch HeightfieldError.sizeExceedsMaximum(let w, let h, let maximum) {
    print("\(w) x \(h) is over the \(maximum)-cell limit")
}
```

From existing heights, row-major with row 0 first:

```swift
let terrain = try Heightfield(
    width: 512, height: 512, origin: SIMD2(-256, -256), heights: heights,
    attributes: classes)   // `classes[i]` is 0 for untouched, 1...255 to colour
```

A heightfield body draws only the field: its mesh arrays are ignored. `color`, `material` (including
opacity), `transform`, `isVisible` and `renderLayer` apply as for a mesh. The mesh cell target
(`heightfieldMeshCellPixels`, 4 px by default) trades sharpness for GPU time; leave it alone unless
you have measured.

---

## Update a region every frame

`replace(region:heights:attributes:ids:)` changes cells in place. Nothing in SwiftUI has to change:
each renderer sees the field's new `version` and uploads only the 64 x 64-cell tiles that changed.

```swift
let region = HeightfieldRegion(x: 600, y: 480, width: 130, height: 120)

func cut(toolDepth: Float, eventID: UInt32) {
    // New heights for just those 130 x 120 cells, row-major.
    var heights = [Float](repeating: toolDepth, count: region.cellCount)
    heights[0] = toolDepth - 0.1
    field.replace(
        region: region,
        heights: heights,
        attributes: [UInt8](repeating: 1, count: region.cellCount),   // "cut" colour
        ids: [UInt32](repeating: eventID, count: region.cellCount))   // which event touched them
}
```

Calling it hundreds of times in a frame is fine: the cost on the GPU scales with the **tiles touched**,
not the number of edits (200 overlapping 130 x 120 edits upload 12 tiles, 0.2 MB). On the CPU, each
call copies its rows into a mirror under a lock; budget a few microseconds per 130 x 120 region in a
release build, and call from any thread.

Pass `nil` (the default) for `attributes` or `ids` to leave that channel as it was:

```swift
field.replace(region: region, heights: lowered)   // heights only
```

If a pass lowers the surface, call `recomputeHeightRange()` now and then. The field's height range is
a running one that grows with edits and never shrinks by itself, which only loosens its bounds
(a slightly larger camera fit), never the picture:

```swift
field.recomputeHeightRange()   // O(cells): between passes, not per edit
```

A renderer that did not draw for a while, or a second one added later, converges on its own; you
never tell the viewport the field changed. With on-demand drawing (not `MTKView`'s continuous loop)
you do need to ask for a redraw yourself.

---

## Colour by attribute

Attribute `n` shows ramp entry `n`. Entry 0 is never used: attribute 0 is the untouched surface and
shades as the body's material.

```swift
// A depth ramp: attributes 1...255 run from pale to deep blue.
var ramp = [SIMD4<Float>](repeating: SIMD4(1, 1, 1, 1), count: Heightfield.rampSize)
for i in 1..<Heightfield.rampSize {
    let t = Float(i) / 255
    ramp[i] = SIMD4(0.85 * (1 - t), 0.9 * (1 - t) + 0.2 * t, 1 - 0.4 * t, 1)
}
field.ramp = ramp
field.rampColorSpace = .sRGB     // display values (default); .linear for linear light
```

Changing the ramp replaces a 4 KB buffer and re-uploads no heights, so you can animate it. Shading,
shadows, tone mapping and selection tint apply on top of the ramp colour.

---

## Pick a cell, exactly

A tap on a heightfield gives the cell, its height, attribute and id, in `PickResult.heightfield`:

```swift
controller.onPick = { result in
    guard let hit = result?.heightfield else { return }
    print("cell \(hit.cell), height \(hit.height), colour \(hit.attribute)")
    if let id = hit.id { print("last changed by event \(id)") }   // needs tracksIDs
}
```

The GPU pick sees the surface **as drawn**, whose coarse levels of detail are lowered to their cell
minimum; at an oblique angle, beside a tall step, it can land cells from the true one. So
`MetalViewportView` refines every tap for you: it re-casts the tap's own ray over the full-resolution
heights (`Heightfield.raycast`, microseconds) and hands `onPick` the exact cell at every level. If you
take a pick yourself, refine it with the ray's NDC:

```swift
renderer.performPick(at: pixel) { result in
    Task { @MainActor in
        let exact = controller.refinePick(result, ndc: ndc, bodies: bodies)
        // exact?.heightfield is the cell the ray enters
    }
}
```

The same ray march is available directly, in the field's local space, for your own queries:

```swift
if let hit = field.raycast(origin: localOrigin, direction: localDirection) {
    print("hits cell \(hit.cell) at distance \(hit.distance)")
}
```

A region pick (`controller.performRegionPick`) has no single ray, so it reports the cell of the drawn
surface under each pixel. Headless, `OffscreenRenderer.performPick` and `performRegionPick` return the
same `PickResult.heightfield`.

---

## See through it, select it, put it on top

```swift
var glass = stock
glass.color.w = 0.4                  // translucent: sorted with other translucent bodies
controller.displayMode = .xray       // or make every surface translucent

controller.selectedBodyIDs = ["stock"]   // tint, and the screen-space outline ring

var gauge = stock
gauge.renderLayer = .overlay         // drawn over everything, like a widget; no outline or shadow
```

`.wireframe` draws nothing for a heightfield (it has no edge geometry); use `.shaded`.

---

## Things to know

- **Limits.** At most 16,321 cells a side, and memory is real: about 25 MB for 2000 x 2000 with
  float32 heights, over 1 GB at the maximum side. `precision: .float16` halves the height memory and
  upload (11 bits of mantissa; it falls back to float32 on Intel Macs).
- **If the GPU cannot hold a field** the renderer logs once (`os.Logger`, subsystem
  `OCCTSwiftViewport`, category `Heightfield`) and does not draw it.
- **Cost.** On an M4 in a release build a 2000 x 2000 field costs about 2.6 ms of GPU at the default
  target; 2 px is a 9x cliff. Nothing has been measured on an iPad or iPhone yet; measure in a
  **release** build, since a debug build's GPU timings are not representative.
- **Offscreen.** `OffscreenRenderer` draws, shadows, outlines and picks a heightfield exactly as the
  live viewport does; `OffscreenRenderOptions.heightfieldMeshCellPixels` carries the target.
