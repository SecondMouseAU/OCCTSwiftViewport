---
title: ViewCube
parent: API Reference
---

# ViewCube

The ViewCube system provides a corner-mounted orientation widget for Metal viewports. It lets users see the current camera orientation at a glance and snap to any of 26 standard views by tapping a face, edge, or corner. `NavigationCubeView` is the primary interactive widget; `ViewCubeView` is the legacy orientation-only gizmo kept for compatibility.

## Topics

- [NavigationCube](#navigationcube) · [NavigationCubeView](#navigationcubeview) · [ViewCubeRegion](#viewcuberegion) · [ViewCubeFace](#viewcubeface) · [ViewCubePosition](#viewcubeposition) · [ViewCubeView](#viewcubeview)

---

## NavigationCube

A SwiftUI-free, unit-testable model that drives geometry projection and hit-testing for the interactive navigation cube. It tracks a camera rotation and resolves taps to one of the 26 `ViewCubeRegion`s.

**Axis convention:** +X = right, −X = left, +Y = back, −Y = front, +Z = top, −Z = bottom. A world point projects to screen as `(rotated.x, −rotated.y)` where `rotated = rotation.inverse.act(point)`.

```swift
public struct NavigationCube
```

### `init(rotation:size:padding:)`

```swift
public init(rotation: simd_quatf, size: CGFloat, padding: CGFloat = 6)
```

Creates a `NavigationCube` tracking `rotation`, rendered into a square widget of `size` points with `padding` points of inset from the widget edge.

```swift
let cube = NavigationCube(
    rotation: controller.cameraState.rotation,
    size: 96
)
```

### `rotation`

```swift
public var rotation: simd_quatf
```

The current camera rotation the cube tracks. Update this each frame to keep the widget in sync.

### `size`

```swift
public var size: CGFloat
```

Widget side length in points.

### `padding`

```swift
public var padding: CGFloat
```

Inset from the widget edge in points. Default is `6`.

### `scale`

```swift
public var scale: CGFloat { get }
```

Derived pixels-per-cube-unit value. The rotated cube's silhouette reaches approximately √3 units; `scale` is computed so a face (±1) fits comfortably inside `size − padding`, with corners allowed to approach the edges.

```swift
// (size * 0.5 - padding) / 1.45
```

### `project(_:)`

```swift
public func project(_ p: SIMD3<Float>) -> CGPoint
```

Projects a cube-local point in `[−1, 1]³` to widget coordinates using the current `rotation`. The y-axis is flipped (screen y is down).

### `visibleFaces()`

```swift
public func visibleFaces() -> [NavigationCube.VisibleFace]
```

Returns the faces currently pointing toward the camera, sorted back-to-front (draw in order to get correct painter's-algorithm overlap). Only faces whose outward normal opposes the look direction are included.

### `region(at:)`

```swift
public func region(at point: CGPoint) -> ViewCubeRegion?
```

Resolves a tap in widget coordinates to a `ViewCubeRegion`, or `nil` if the tap misses the cube silhouette. Internally casts a ray through the cube, finds the frontmost surface point, and classifies it using the 3×3-per-face grid (outer third of each tangent axis activates the adjacent face).

```swift
if let tapped = cube.region(at: tapLocation) {
    controller.goToRegion(tapped)
}
```

---

### `NavigationCube.VisibleFace`

A face that is currently pointing toward the camera, with its projected geometry ready for drawing.

```swift
public struct NavigationCube.VisibleFace
```

| Property | Type | Description |
|---|---|---|
| `region` | `ViewCubeRegion` | Which of the 6 face regions this is |
| `corners` | `[CGPoint]` | 4 projected corners, in drawing order |
| `center` | `CGPoint` | Projected center of the face (for label placement) |
| `depth` | `Float` | Toward-camera depth of the face centre (used for back-to-front sorting) |

```swift
let canvas = Canvas { ctx, _ in
    for face in cube.visibleFaces() {
        var path = Path()
        path.move(to: face.corners[0])
        for c in face.corners.dropFirst() { path.addLine(to: c) }
        path.closeSubpath()
        ctx.fill(path, with: .color(.gray))
        ctx.draw(Text(face.region.displayName).font(.caption), at: face.center)
    }
}
```

---

## NavigationCubeView

A Fusion 360 / Shapr3D-style interactive navigation cube rendered via SwiftUI `Canvas`. Tapping a face, edge, or corner snaps the camera to the matching `ViewCubeRegion`; dragging the cube orbits the camera (grab-and-spin). This is the recommended widget for new code.

```swift
public struct NavigationCubeView: View
```

Geometry and hit-testing are handled by `NavigationCube`; the view observes `ViewportController` for camera state changes. On macOS, hovering highlights the region under the cursor using `onContinuousHover`.

**Orbit direction:** The cube acts as a camera proxy, so dragging it rotates the camera *around* the model — the opposite sign to viewport grab-the-model drag.

### `init(controller:)`

```swift
public init(controller: ViewportController)
```

Creates a `NavigationCubeView` tied to `controller`. The view calls `controller.handleOrbit` and `controller.endOrbit` for drag orbiting, and `controller.goToRegion(_:)` for tap snaps.

```swift
// Place in the top-trailing corner of the viewport
ZStack(alignment: .topTrailing) {
    MetalViewportView(controller: controller, bodies: $bodies)
    NavigationCubeView(controller: controller)
        .frame(width: 96, height: 96)
        .padding(12)
}
```

The view is square (`aspectRatio(1, contentMode: .fit)`) and scales its label font relative to the widget side length.

---

## ViewCubeRegion

An enum representing one of the 26 clickable regions of the cube: 6 faces, 12 edges, and 8 corners.

```swift
public enum ViewCubeRegion: String, CaseIterable, Sendable
```

### Face cases (6)

```swift
case top
case bottom
case front
case back
case left
case right
```

### Edge cases (12)

```swift
case topFront
case topBack
case topLeft
case topRight
case bottomFront
case bottomBack
case bottomLeft
case bottomRight
case frontLeft
case frontRight
case backLeft
case backRight
```

### Corner cases (8)

```swift
case topFrontLeft
case topFrontRight
case topBackLeft
case topBackRight
case bottomFrontLeft
case bottomFrontRight
case bottomBackLeft
case bottomBackRight
```

---

### `isFace`

```swift
public var isFace: Bool { get }
```

`true` for the 6 face cases (`.top`, `.bottom`, `.front`, `.back`, `.left`, `.right`).

### `isEdge`

```swift
public var isEdge: Bool { get }
```

`true` for the 12 edge cases.

### `isCorner`

```swift
public var isCorner: Bool { get }
```

`true` for the 8 corner cases.

### `displayName`

```swift
public var displayName: String { get }
```

A human-readable, hyphen-separated name for the region. Face names are single words (`"Top"`, `"Front"`, …); edge names are two components (`"Top-Front"`, `"Back-Left"`, …); corner names are three components (`"Top-Front-Right"`, …).

```swift
let label = region.displayName  // e.g. "Top-Front-Right"
```

### `standardView`

```swift
public var standardView: StandardView? { get }
```

Returns the `StandardView` that corresponds to this region, or `nil` for edges and corners (which have no single standard orthographic view). Face-to-view mapping:

| Region | StandardView |
|---|---|
| `.top` | `.top` |
| `.bottom` | `.bottom` |
| `.front` | `.front` |
| `.back` | `.back` |
| `.left` | `.left` |
| `.right` | `.right` |

```swift
if let sv = region.standardView {
    controller.goToStandardView(sv, duration: 0.3)
}
```

### `cameraState(pivot:distance:)`

```swift
public func cameraState(
    pivot: SIMD3<Float> = .zero,
    distance: Float = 10.0
) -> CameraState
```

Returns a `CameraState` positioned for this region. Face regions use the corresponding `StandardView` rotation. Edge regions use SLERP at t = 0.5 between their two adjacent face rotations. Top-corner regions use the four `StandardView.isometric*` rotations; bottom-corner regions are derived by tilting ~35.26° below the horizon from each quadrant direction.

```swift
// Manually position the camera to look at the top-front-right isometric corner
let state = ViewCubeRegion.topFrontRight.cameraState(
    pivot: sceneBounds.center,
    distance: 25.0
)
controller.setCameraState(state, animated: true)
```

---

## ViewCubeFace

An identifier for one of the 6 cube faces. Used by `ViewCubeView` (the legacy gizmo) when mapping taps to `StandardView` transitions.

```swift
public enum ViewCubeFace: String, CaseIterable, Sendable {
    case top, bottom, front, back, right, left
}
```

For interactive hit testing across all 26 regions, prefer `ViewCubeRegion`. `ViewCubeFace` exists as a separate type because `ViewCubeView` predates the `NavigationCube` hit-classification system.

---

## ViewCubePosition

The corner of the viewport overlay in which the ViewCube widget appears. Set via `ViewportConfiguration.viewCubePosition` (default `.bottomTrailing`).

```swift
public enum ViewCubePosition: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}
```

`MetalViewportView` reads this property and places the `NavigationCubeView` in the matching corner automatically — no manual layout is required.

```swift
var config = ViewportConfiguration()
config.viewCubePosition = .topTrailing
let controller = ViewportController(configuration: config)
```

---

## ViewCubeView

The legacy orientation-only ViewCube gizmo. Renders a simplified 2D projection of the cube faces with a compass ring showing the north (Y-axis) direction. Tapping a face triggers `goToStandardView(_:duration:)` with a 0.3 s animation. Retained for source compatibility; `NavigationCubeView` is preferred for new code.

```swift
public struct ViewCubeView: View
```

### `init(controller:)`

```swift
public init(controller: ViewportController)
```

Creates a `ViewCubeView` tied to `controller`. The view must be sized externally; it fills its frame proportionally.

```swift
// Legacy usage
ViewCubeView(controller: controller)
    .frame(width: 80, height: 80)
    .padding()
```

The compass ring renders a circle plus a floating `"N"` label that tracks the projected Y-axis direction as the camera orbits. Face tiles are colored: top/bottom in blue-tinted gray, front/back and left/right in neutral gray, all brightened by the face's toward-camera dot product.
