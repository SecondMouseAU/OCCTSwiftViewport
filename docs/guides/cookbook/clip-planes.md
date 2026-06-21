---
title: Clip Planes & Sections
parent: Cookbook
nav_order: 9
---

# Clip Planes & Sections

A `ClipPlane` removes geometry on the negative side of a plane equation. The
Metal shaders evaluate the equation `dot(normal, worldPosition) + distance < 0`
per fragment and call `discard_fragment()` when it is true — so anything on the
**negative side of the normal** is cut away.

Up to **4** clip planes may be active simultaneously. Planes beyond that limit
are silently ignored; the renderer collects only the first 4 enabled entries
from `ViewportController.clipPlanes`.

---

## The `ClipPlane` type

```swift
// ClipPlane is a value type (struct, Sendable, Equatable)
public struct ClipPlane {
    public var normal:    SIMD3<Float>   // unit outward-facing normal
    public var distance:  Float          // signed distance from origin
    public var isEnabled: Bool           // toggle without removing from the array

    public init(
        normal:    SIMD3<Float> = SIMD3(0, 1, 0),
        distance:  Float        = 0,
        isEnabled: Bool         = true
    )

    public var asFloat4: SIMD4<Float>   // (nx, ny, nz, distance) — shader packing
}
```

The initializer normalizes `normal` for you, so you can pass an un-normalized
vector safely.

### Predefined presets

Three static presets are provided for the most common axis-aligned sections:

| Preset | Normal | Clips |
|---|---|---|
| `ClipPlane.groundPlane` | `(0, 1, 0)` | everything below Y = 0 |
| `ClipPlane.xPlane` | `(1, 0, 0)` | everything at negative X |
| `ClipPlane.zPlane` | `(0, 0, 1)` | everything at negative Z |

---

## Adding planes to the scene

`ViewportController.clipPlanes` is a `@Published [ClipPlane]`. Assign or
mutate it from the main actor; the renderer picks up the change automatically
on the next frame.

```swift
// Horizontal section: show only geometry above Y = 1.5
controller.clipPlanes = [
    ClipPlane(normal: SIMD3(0, 1, 0), distance: -1.5)
]
```

**Distance sign convention:** To cut at world Y = h, set `distance = -h`.
The plane equation is `dot(N, P) + d = 0`, so for normal `(0,1,0)`:
`y + d = 0` → `d = -h`.

To remove a section, clear the array:

```swift
controller.clipPlanes = []
```

---

## Enabling and disabling planes without removing them

Set `isEnabled` to `false` to temporarily suspend a plane while keeping it in
the array for later re-use.

```swift
// Start with the plane off
var section = ClipPlane(normal: SIMD3(0, 1, 0), distance: -1.0, isEnabled: false)
controller.clipPlanes = [section]

// Turn it on later (must reassign to trigger @Published)
section.isEnabled = true
controller.clipPlanes = [section]
```

---

## Horizontal section through a model

The most common use case: a horizontal cut that exposes the interior of a solid.

```swift
import OCCTSwiftViewport
import SwiftUI

struct SectionView: View {
    @StateObject private var controller = ViewportController()

    // Height of the cut plane in world units
    @State private var cutHeight: Float = 0.0

    var body: some View {
        VStack {
            MetalViewportView(controller: controller, bodies: .constant([yourBody]))
                .ignoresSafeArea()

            // Scrubber to move the cut plane interactively
            Slider(value: $cutHeight, in: -5.0...5.0)
                .padding()
                .onChange(of: cutHeight) { _, newValue in
                    controller.clipPlanes = [
                        ClipPlane(normal: SIMD3(0, 1, 0), distance: -newValue)
                    ]
                }
        }
        .onAppear {
            // Initial cut at Y = 0
            controller.clipPlanes = [
                ClipPlane(normal: SIMD3(0, 1, 0), distance: 0)
            ]
        }
    }
}
```

---

## Animating the plane offset

Use a `Timer` or SwiftUI animation to sweep the cut plane through the model:

```swift
import OCCTSwiftViewport
import SwiftUI
import Combine

struct AnimatedSectionView: View {
    @StateObject private var controller = ViewportController()

    @State private var timer: AnyCancellable?
    @State private var cutHeight: Float = -5.0

    var body: some View {
        MetalViewportView(controller: controller, bodies: .constant([yourBody]))
            .ignoresSafeArea()
            .onAppear {
                controller.clipPlanes = [
                    ClipPlane(normal: SIMD3(0, 1, 0), distance: -cutHeight)
                ]
                timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                    .autoconnect()
                    .sink { _ in
                        cutHeight += 0.05
                        if cutHeight > 5.0 { cutHeight = -5.0 }
                        controller.clipPlanes = [
                            ClipPlane(normal: SIMD3(0, 1, 0), distance: -cutHeight)
                        ]
                    }
            }
            .onDisappear {
                timer?.cancel()
            }
    }
}
```

---

## Using multiple planes

Up to 4 planes can be active at once. Combine them to create quarter-section
or box-crop views:

```swift
// Quarter section: expose the front-right quadrant (positive X and positive Z)
controller.clipPlanes = [
    ClipPlane(normal: SIMD3( 1, 0, 0), distance:  0),   // hide negative-X
    ClipPlane(normal: SIMD3( 0, 0, 1), distance:  0),   // hide negative-Z
]

// Box crop: only show geometry inside a slab -1 ≤ Y ≤ 1
controller.clipPlanes = [
    ClipPlane(normal: SIMD3(0,  1, 0), distance: -1),   // bottom face of slab
    ClipPlane(normal: SIMD3(0, -1, 0), distance: -1),   // top face of slab (flipped normal)
]
```

Planes beyond index 3 (i.e. a 5th or later entry) are not sent to the GPU
and have no effect.

---

## Arbitrary cutting angles

Any unit normal works. To cut at 45° through the XY plane:

```swift
let diagonal = SIMD3<Float>(1, 1, 0)   // will be normalized by the initializer
controller.clipPlanes = [
    ClipPlane(normal: diagonal, distance: 0)
]
```

---

## How it works in the shader

Every shaded, wireframe, and point fragment shader evaluates:

```metal
for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
    float4 plane = uniforms.clipPlanes[cp];           // (nx, ny, nz, distance)
    if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0)
        discard_fragment();
}
```

Clipping is done in **world space** after the model transform has been applied,
so per-body transforms and clip planes interact correctly — a rotated or
translated body is clipped at the same world-space boundary as everything else.

The renderer sends only enabled planes, packing them into a fixed-size 4-tuple
in the `Uniforms` struct. `clipPlaneCount` tells the shader how many entries to
read; unused slots are zeroed.

---

## Tips

- **Performance:** Each additional active plane adds one dot-product per
  fragment per pass (shaded, wireframe, pick). With 4 planes this is negligible
  on Apple GPU hardware.
- **Cap faces:** Clip planes cut geometry but do not generate cap faces. If you
  need filled caps on the cut cross-section, composite a filled polygon
  `ViewportBody` aligned with the cut plane on top of the scene.
- **Toggling without array mutation:** Prefer `isEnabled = false` over removing
  an element when you intend to restore the same plane later. Array mutations
  on a `@Published` property trigger a full re-upload of the uniform block;
  both approaches have the same cost, but `isEnabled` avoids bookkeeping errors.
