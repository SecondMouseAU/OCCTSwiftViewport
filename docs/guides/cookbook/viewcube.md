---
title: ViewCube
parent: Cookbook
nav_order: 4
---

# ViewCube

The ViewCube is an interactive 3D navigation widget — familiar from Shapr3D and FreeCAD — that tracks the camera orientation and lets the user snap to any of 26 standard views with a single tap. Dragging the cube orbits the camera in real time.

## Two widgets — use the right one

| Widget | Type | Purpose |
|---|---|---|
| `NavigationCubeView` | Interactive cube | Tap → snap to view; drag → orbit. **Use this one.** |
| `ViewCubeView` | Orientation gizmo | Read-only orientation indicator with compass ring. Legacy; kept for compatibility. |

`NavigationCubeView` is the default overlay rendered by `MetalViewportView`. `ViewCubeView` is available for apps that only want a passive orientation indicator without interaction.

## Built-in overlay (zero setup)

`MetalViewportView` draws `NavigationCubeView` automatically when `showViewCube` is `true` — which is the default. No extra code is required:

```swift
let controller = ViewportController()
// controller.showViewCube is true by default

MetalViewportView(controller: controller, bodies: $bodies)
```

The overlay is 96 × 96 pt, placed 12 pt inside the corner specified by `configuration.viewCubePosition` (default `.bottomTrailing`).

## Configuring position

Pass a `ViewportConfiguration` with the desired `viewCubePosition`:

```swift
var config = ViewportConfiguration.default
config.viewCubePosition = .topTrailing   // move cube to top-right

let controller = ViewportController(configuration: config)
```

`ViewCubePosition` has four cases — `.topLeading`, `.topTrailing`, `.bottomLeading`, `.bottomTrailing` — each mapping to the matching SwiftUI `Alignment` corner.

## Hiding and showing at runtime

`ViewportController` publishes `showViewCube` directly, so you can toggle it without recreating the controller:

```swift
// Hide the cube
controller.showViewCube = false

// Show it again
controller.showViewCube = true
```

## The 26 ViewCubeRegions

A tap on the cube resolves to a `ViewCubeRegion` — an enum with 26 cases covering every clickable target:

| Category | Count | Examples |
|---|---|---|
| Faces | 6 | `.top`, `.bottom`, `.front`, `.back`, `.left`, `.right` |
| Edges | 12 | `.topFront`, `.frontLeft`, `.bottomRight`, … |
| Corners | 8 | `.topFrontLeft`, `.topBackRight`, `.bottomFrontRight`, … |

Each case exposes `.isFace`, `.isEdge`, `.isCorner`, and a human-readable `.displayName` (e.g. `"Top-Front-Left"`). Faces additionally provide `.standardView` — the matching `StandardView` case, or `nil` for edges and corners.

## Snapping the camera with goToRegion

`ViewportController.goToRegion(_:duration:)` animates to the region's camera orientation, preserving the current pivot, zoom distance and projection type:

```swift
// Snap to the top-front-right isometric corner
controller.goToRegion(.topFrontRight)

// Custom animation duration (default 0.3 s)
controller.goToRegion(.front, duration: 0.5)
```

The rotation is computed by `ViewCubeRegion.cameraState(pivot:distance:)`:

- **Faces** use the corresponding `StandardView` rotation directly (exact orthographic alignment).
- **Edges** SLERP halfway between the two adjacent face rotations.
- **Corners** use isometric-like rotations (top corners) or a tilt-from-below construction (bottom corners).

## How tap classification works

The pure model lives in `NavigationCube` (no SwiftUI dependency, fully unit-tested). The algorithm:

1. **Project** — the tap point is un-projected from widget coordinates into the unit-cube's rotated frame using the camera quaternion inverse.
2. **Ray-cast** — a ray is built from that screen point through the cube, intersected with `[-1, 1]³` via a slab test. The *frontmost* surface point is taken.
3. **Classify** — each tangent axis coordinate is compared against ±⅓. Any coordinate outside that band activates the corresponding face region (e.g. x > ⅓ → `.right`). One active face = face hit; two = edge hit; three = corner hit.

```swift
// Use NavigationCube directly for custom hit-testing
let cube = NavigationCube(
    rotation: controller.cameraState.rotation,
    size: 96
)

if let region = cube.region(at: tapPoint) {
    controller.goToRegion(region)
}
```

## Drag-to-orbit

Dragging the cube more than 4 pt triggers orbit mode. The delta is forwarded to `controller.handleOrbit(translation:)` — the same call the main viewport uses — so inertia and rotation style settings apply identically.

The sign is inverted relative to viewport drags: dragging the cube clockwise rotates the camera clockwise around the model (grab-the-camera, not grab-the-model).

## Embedding NavigationCubeView manually

If you build your own overlay layout instead of using `MetalViewportView`, embed `NavigationCubeView` directly:

```swift
ZStack {
    MetalViewportView(controller: controller, bodies: $bodies)
        .ignoresSafeArea()

    // Disable the built-in overlay first to avoid double-rendering
    // (showViewCube defaults to true).
    // controller.showViewCube = false  — set before MetalViewportView appears
    
    VStack {
        NavigationCubeView(controller: controller)
            .frame(width: 96, height: 96)
            .padding(16)
        Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
}
```

`NavigationCubeView(controller:)` is the only initialiser. The view observes `controller.cameraState.rotation` and redraws automatically on every camera update.

## Legacy: ViewCubeView

`ViewCubeView` is a passive orientation indicator with a compass ring. It has no tap or drag interaction — tapping a face calls `controller.goToStandardView(_:duration:)` internally but does not support edges or corners. Prefer `NavigationCubeView` for all new code.

```swift
// Legacy usage — orientation indicator only
ViewCubeView(controller: controller)
    .frame(width: 80, height: 80)
```

## Summary

| Task | API |
|---|---|
| Enable / disable built-in overlay | `controller.showViewCube = Bool` |
| Place overlay in a different corner | `ViewportConfiguration.viewCubePosition = ViewCubePosition` |
| Snap camera from code | `controller.goToRegion(_ region: ViewCubeRegion, duration: Float = 0.3)` |
| Custom hit-test | `NavigationCube(rotation:size:).region(at: CGPoint) -> ViewCubeRegion?` |
| Embed widget manually | `NavigationCubeView(controller: ViewportController)` |
