---
title: Getting Started
parent: Cookbook
nav_order: 1
---

# Getting Started

<script type="module" src="https://cdn.jsdelivr.net/npm/@google/model-viewer/dist/model-viewer.min.js"></script>

<model-viewer src="../../models/rounded-block.glb" camera-controls auto-rotate environment-image="neutral" exposure="1.1" shadow-intensity="1" style="width:340px;height:300px;background:#eef1f5;border-radius:6px"></model-viewer>

*The viewport rendering a solid (interactive).*


This page takes you from a blank SwiftUI project to a Metal 3D viewport with an
interactive primitive on screen. It covers the minimum viable setup and points you
toward the other cookbook pages for depth.

---

## Add the package

In `Package.swift` (or via Xcode's package manager UI):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/gsdali/OCCTSwiftViewport.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
        ]
    ),
]
```

If you also need to load STEP/STL files or work with OCCTSwift geometry, depend on
`OCCTSwiftTools` instead — it provides `CADFileLoader` and converter utilities on top
of the viewport.

**Requirements:** iOS 18+ / macOS 15+ / visionOS 1+, Swift 6, Xcode 16.

---

## Drop a viewport into a SwiftUI view

Two objects do almost all the work:

| Type | Role |
|------|------|
| `ViewportController` | `@MainActor ObservableObject` — camera, display mode, selection, HUD |
| `MetalViewportView` | SwiftUI view wrapping MTKView — gestures, overlay, render loop |

`MetalViewportView` takes a `ViewportController` and a `Binding<[ViewportBody]>`.
`ViewportBody` is the geometry-source-agnostic input type: interleaved vertex/normal
data + triangle indices + optional edge polylines.

```swift
import SwiftUI
import OCCTSwiftViewport

struct ContentView: View {
    // ViewportController holds all mutable viewport state.
    // The .cad preset enables turntable rotation, the ViewCube, axes, and grid.
    @StateObject private var controller = ViewportController(configuration: .cad)

    // Bodies live in @State so SwiftUI owns the binding lifetime.
    @State private var bodies: [ViewportBody] = [
        .box(id: "box1",
             width: 2, height: 1, depth: 1,
             color: SIMD4<Float>(0.5, 0.7, 1.0, 1.0)),
    ]

    var body: some View {
        MetalViewportView(controller: controller, bodies: $bodies)
            .ignoresSafeArea()
    }
}
```

Run it — you get a shaded blue box with orbit, pan, pinch-to-zoom, and a ViewCube
in the corner. On macOS, drag to orbit, ⌥-drag to pan, and scroll to zoom.

---

## Built-in primitives

Three static factories on `ViewportBody` generate ready-to-render geometry with
correct normals and edge polylines:

```swift
import OCCTSwiftViewport

// Box — flat-shaded faces, 12 edge polylines
let box = ViewportBody.box(
    id: "myBox",
    width: 2.0,
    height: 1.0,
    depth: 0.5,
    color: SIMD4<Float>(0.8, 0.6, 0.3, 1.0)
)

// Cylinder — along the Y axis
let cyl = ViewportBody.cylinder(
    id: "myCyl",
    radius: 0.5,
    height: 2.0,
    segments: 64,                              // radial facets
    color: SIMD4<Float>(0.4, 0.8, 0.4, 1.0)
)

// UV sphere
let sphere = ViewportBody.sphere(
    id: "mySphere",
    radius: 1.0,
    segments: 48,                              // longitudinal
    rings: 32,                                 // latitudinal
    color: SIMD4<Float>(0.9, 0.3, 0.3, 1.0)
)
```

All defaults are already set, so `.box(id: "b")` gives a 1×1×1 grey box if you just
need something on screen fast.

---

## ViewportController at a glance

`ViewportController` is the central hub. Everything the viewport can do is accessible
through it:

```swift
import OCCTSwiftViewport

// -- Configuration presets --
// .cad            turntable + ViewCube + axes + grid  (default for CAD tools)
// .modelViewer    arcball, no HUD                     (product viewers)
// .architectural  turntable, architectural lighting, longer camera distance
// .performance    shadows/SSAO/MSAA off — best for large many-body scenes
// .cadHighQuality PN-triangle tessellation on — smooth silhouettes
let controller = ViewportController(configuration: .cad)

// -- Display mode --
controller.displayMode = .shadedWithEdges   // .wireframe / .shaded / .shadedWithEdges
                                            // .flat / .unlit / .xray / .rendered

// -- HUD visibility --
controller.showViewCube = true
controller.showAxes = false
controller.showGrid = false
controller.showOrientationGnomon = true
controller.showScaleBar = true

// -- Camera: animate to a standard view --
controller.goToStandardView(.top)                   // .front .back .right .left .bottom
controller.goToStandardView(.isometricFrontRight)   // isometric diagonal views
controller.goToStandardView(.front, duration: 0.5)  // custom animation duration

// -- Camera: toggle perspective / orthographic --
controller.toggleProjection()

// -- Camera: reset --
controller.reset()

// -- Selection --
controller.selectBody("myBox")
controller.selectBody("myCyl", toggle: true)    // multi-select
controller.deselectAll()
controller.clearSelection()
```

`ViewportController.init(configuration:)` accepts any `ViewportConfiguration` —
you can also build a custom one if no preset fits (see the Configuration page).

---

## Putting multiple bodies on screen

`bodies` is a plain `[ViewportBody]` binding — update it with normal SwiftUI
state mutations:

```swift
struct MultiBodyDemo: View {
    @StateObject private var controller = ViewportController(configuration: .cad)
    @State private var bodies: [ViewportBody] = []

    var body: some View {
        VStack {
            MetalViewportView(controller: controller, bodies: $bodies)
                .ignoresSafeArea()

            HStack {
                Button("Add Box") {
                    let id = "box-\(bodies.count)"
                    let offset = Float(bodies.count) * 2.5
                    var body = ViewportBody.box(
                        id: id,
                        color: SIMD4<Float>(0.5, 0.7, 1.0, 1.0)
                    )
                    // Translate via the per-body transform — no re-upload needed.
                    body.transform = simd_float4x4(translation: SIMD3<Float>(offset, 0, 0))
                    bodies.append(body)
                }

                Button("Clear") {
                    bodies.removeAll()
                }
            }
            .padding()
        }
    }
}

// Helper: translation-only 4×4 matrix
extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
    }
}
```

`ViewportBody` has a `transform: simd_float4x4` property (default: identity) that
the renderer applies per-body in the vertex shader. Mutating `transform` moves a
body without re-uploading its vertex data.

---

## Reacting to selection

Tapping geometry sets `ViewportController.pickResult` and updates
`selectedBodyIDs`. Observe them in the usual SwiftUI ways:

```swift
struct SelectionDemo: View {
    @StateObject private var controller = ViewportController(configuration: .cad)
    @State private var bodies: [ViewportBody] = [
        .sphere(id: "s1", color: SIMD4<Float>(0.9, 0.3, 0.3, 1.0)),
        .box(id: "b1",    color: SIMD4<Float>(0.3, 0.6, 0.9, 1.0)),
    ]

    var body: some View {
        VStack {
            MetalViewportView(controller: controller, bodies: $bodies)
                .ignoresSafeArea()

            // Show the selected body ID under the viewport.
            if let id = controller.selectedBodyIDs.first {
                Text("Selected: \(id)")
                    .padding()
            }
        }
        // Or react programmatically via the onPick callback:
        .onAppear {
            controller.onPick = { result in
                guard let result else { return }
                print("Picked body \(result.bodyID), face \(result.triangleIndex)")
            }
        }
    }
}
```

`pickResult` is `@Published`, so a `.onChange(of: controller.pickResult)` modifier
or a Combine subscription works too.

---

## Next steps

- **Camera** — `CameraState`, `CameraController`, `focusOn`, `animateTo`, fit-to-scene
- **Custom geometry** — building a `ViewportBody` from your own vertex/index arrays
- **Display & lighting** — `LightingConfiguration` presets, shadows, environment maps
- **Picking & selection** — `PickResult`, `SelectionFilter`, face/edge/vertex IDs
- **Measurements** — tap-to-measure distance, angle, and radius overlays
- **Offscreen rendering** — `OffscreenRenderer` for headless snapshots and thumbnails
