---
title: Camera & Navigation
parent: Cookbook
nav_order: 3
---

# Camera & Navigation

The camera system is split across three types:

- **`CameraState`** — immutable value type (`Hashable, Codable, Sendable`) capturing the full camera pose.
- **`CameraController`** — `@MainActor` class that mutates state in response to gestures and drives animations.
- **`ViewportController`** — the top-level observable hub; exposes the controller as `cameraController` and mirrors its `@Published cameraState` for observation.

---

## CameraState at a glance

```swift
public struct CameraState: Hashable, Codable, Sendable {
    public var rotation: simd_quatf        // normalised quaternion
    public var distance: Float             // from pivot, default 10
    public var pivot: SIMD3<Float>         // orbit centre in world space
    public var fieldOfView: Float          // degrees, perspective only, default 45
    public var orthographicScale: Float    // world-height of viewport, ortho only, default 10
    public var isOrthographic: Bool        // default false
    public var panOffset: SIMD2<Float>     // camera-relative fine offset

    // Derived, read-only
    public var position: SIMD3<Float>      // world-space eye position
    public var viewDirection: SIMD3<Float> // normalised, toward pivot
    public var upVector: SIMD3<Float>
    public var rightVector: SIMD3<Float>
    public var viewMatrix: simd_float4x4
}
```

`CameraState` is a plain value — capture it, persist it with `Codable`, diff it, or hand it to `animateTo(_:duration:)`.

```swift
// Snapshot and restore
let bookmark = viewport.cameraState
// … later …
viewport.animateTo(bookmark, duration: 0.4)
```

---

## Projection matrix

```swift
let proj = cameraState.projectionMatrix(
    aspectRatio: Float(viewSize.width / viewSize.height),
    near: 0.01,
    far: 1000.0
)
```

The matrix is perspective or orthographic depending on `isOrthographic`. Both use Metal NDC (z in [0, 1]).

---

## Fitting the camera to geometry

`fit(to:aspectRatio:padding:)` returns a **new** `CameraState` with the pivot moved to the bounding-box centre and the distance (perspective) or `orthographicScale` (orthographic) adjusted so the bounding sphere fills the view. `padding` is a multiplier: `1.1` gives 10 % breathing room.

```swift
// Fit to an explicit bounding box
if let bb = body.boundingBox {
    let fitted = viewport.cameraState.fit(
        to: bb,
        aspectRatio: Float(viewSize.width / viewSize.height),
        padding: 1.1
    )
    viewport.animateTo(fitted, duration: 0.4)
}
```

```swift
// Convenience overload: fits to all visible bodies
let bodies: [ViewportBody] = …
if let fitted = viewport.cameraState.fit(
    to: bodies,
    aspectRatio: Float(viewSize.width / viewSize.height)
) {
    viewport.animateTo(fitted, duration: 0.4)
}
```

The overload skips invisible bodies and returns `nil` when no body has geometry.

---

## Standard and isometric views

`StandardView` enumerates ten axis-aligned orientations. The six orthographic cases (`top`, `bottom`, `front`, `back`, `right`, `left`) set `isOrthographic: true`; the four isometric corners remain perspective.

```swift
public enum StandardView: String, CaseIterable, Sendable {
    // Orthographic (isOrthographic = true)
    case top, bottom, front, back, right, left
    // Perspective isometric corners
    case isometricFrontRight, isometricFrontLeft
    case isometricBackRight,  isometricBackLeft
}
```

### Navigating via the controller

```swift
// Animated (default 0.3 s)
viewport.goToStandardView(.top)
viewport.goToStandardView(.isometricFrontRight, duration: 0.5)
```

### Building a view-picker toolbar

```swift
Menu("Views") {
    Button("Top")       { viewport.goToStandardView(.top) }
    Button("Front")     { viewport.goToStandardView(.front) }
    Button("Right")     { viewport.goToStandardView(.right) }
    Button("Isometric") { viewport.goToStandardView(.isometricFrontRight) }
}
```

### Keyboard shortcuts

`StandardView` carries single-character shortcuts:

| View | Key |
|---|---|
| Top | `t` |
| Front | `f` |
| Right | `r` |
| Left | `l` |
| Isometric (front-right) | `i` |

These are automatically handled by `ViewportController.handleKeyPress(_:)`.

### Building a CameraState directly from a StandardView

```swift
let state = StandardView.front.cameraState(
    pivot: SIMD3<Float>(0, 0, 0),
    distance: 20,
    fieldOfView: 45,
    orthographicScale: 10
)
viewport.animateTo(state, duration: 0.3)
```

---

## Animated transitions (SLERP + ease-out)

All animated moves go through `CameraController.animateTo(_:duration:)`, which:

1. Captures `animationStart` and `animationTarget`.
2. Runs a 60 FPS `Timer`.
3. Applies an ease-out curve (`t = 1 - (1 - progress)³`) at each tick.
4. SLERPs `rotation` via `simd_slerp`; linearly interpolates `distance`, `pivot`, `fieldOfView`, `orthographicScale`, and `panOffset`.
5. Snaps `isOrthographic` at the midpoint.

```swift
// Direct state animation through the controller
viewport.animateTo(mySavedState, duration: 0.4)

// Instant snap (duration = 0)
viewport.animateTo(mySavedState, duration: 0)

// Cancel mid-flight
viewport.cameraController.cancelAnimation()
```

Observe `viewport.isAnimating` (a `@Published Bool`) to gate UI interactions during the transition.

---

## Orbit, pan, and zoom

These calls go through `ViewportController`'s gesture-forwarding API, which in turn drives `CameraController`.

```swift
// Orbit (drag translation in points)
viewport.handleOrbit(translation: gesture.translation)

// Release with inertia — auto-snaps to a nearby axis view if velocity < 200 pt/s
viewport.endOrbit(velocity: gesture.velocity)

// Pan
viewport.handlePan(translation: gesture.translation)
viewport.endPan(velocity: gesture.velocity)    // pan inertia

// Zoom (magnification factor: >1 = in, <1 = out)
viewport.handleZoom(magnification: CGFloat(gesture.magnification))

// Pinch-to-zoom keeping the gesture centre stationary (NDC −1…+1)
viewport.handleZoom(
    magnification: CGFloat(gesture.magnification),
    centerNormalized: pinchCenterNDC,
    aspectRatio: Float(viewSize.width / viewSize.height)
)

// Scroll-wheel zoom (positive delta = zoom in)
viewport.handleScrollZoom(delta: scrollDelta)

// Scroll-wheel zoom toward cursor (NDC)
viewport.handleScrollZoom(
    delta: scrollDelta,
    cursorNormalized: cursorNDC,
    aspectRatio: Float(viewSize.width / viewSize.height)
)

// Roll (radians)
viewport.handleRoll(angle: rotationGesture.rotation)
```

### Sensitivity knobs on CameraController

```swift
let cam = viewport.cameraController
cam.orbitSensitivity      = 0.005   // radians per point
cam.panSensitivity        = 0.002   // world-units per point, scaled by distance
cam.zoomSensitivity       = 1.0     // pinch factor multiplier
cam.scrollZoomSensitivity = 0.1     // exponential scale for scroll delta
cam.minPanSpeed           = 0.001   // floor preventing imperceptible pan when close
cam.minDistance           = 0.1
cam.maxDistance           = 10_000
cam.enableInertia         = true
cam.dampingFactor         = 0.1     // 0 = no damping, 1 = instant stop
```

---

## Rotation styles

`RotationStyle` controls how drag gestures rotate the camera.

```swift
public enum RotationStyle: String, CaseIterable, Sendable {
    case arcball      // Ken Shoemake free-rotation; unrestricted axes
    case turntable    // Z-up locked; horizontal = yaw, vertical = tilt
    case firstPerson  // Yaw + pitch; camera-centric walk-through
}
```

Two named presets:

```swift
RotationStyle.cadDefault       // == .turntable
RotationStyle.modelingDefault  // == .arcball
```

Set the style on the camera controller at any time:

```swift
viewport.cameraController.rotationStyle = .arcball
```

Or configure it at init via `ViewportConfiguration`:

```swift
let config = ViewportConfiguration.cad  // ships with .turntable
// customise:
var custom = ViewportConfiguration.cad
// (rotationStyle lives on the configuration; set it before constructing the controller)
```

### Choosing a style

| Style | When to use |
|---|---|
| `.turntable` | CAD, architecture — "up is always up". Default. |
| `.arcball` | Freeform 3D modeling, inspecting objects from any angle. |
| `.firstPerson` | Walk-through, VR-style navigation. |

---

## Dynamic pivot (auto orbit centre)

`PivotStrategy` adjusts the orbit centre automatically as the user zooms:

- **Zoomed out** (`distance / sceneDiagonalLength > zoomThreshold + halfBand`): orbit around the scene centre.
- **Zoomed in** (below threshold): orbit around the raycast hit point at the screen centre.
- **Blend zone**: smoothstep between the two over `blendBand × zoomThreshold`.

The strategy is configured via `DynamicPivotConfiguration`:

```swift
public struct DynamicPivotConfiguration: Sendable {
    public var isEnabled: Bool          // default true
    public var animationDuration: Float // pivot transition time, default 0.15 s
    public var zoomThreshold: Float     // distance/diagonal ratio, default 0.5
    public var blendBand: Float         // fraction of threshold for blend zone, default 0.3

    public static let `default` = DynamicPivotConfiguration()
}
```

Configure via `ViewportConfiguration.dynamicPivotConfiguration`. The controller schedules updates automatically with a 50 ms coalesce delay after each orbit/zoom event — no manual calls needed.

To focus on a specific world point programmatically (bypassing the strategy):

```swift
// Animate pivot to a pick result's world position
viewport.focusOn(point: pickResult.worldPosition, distance: 5.0, animated: true)
```

---

## Projection toggle

```swift
// Toggle perspective ↔ orthographic (animated)
viewport.toggleProjection()

// Or set directly and animate
var state = viewport.cameraState
state.isOrthographic = true
viewport.animateTo(state, duration: 0.3)
```

---

## Persisting camera state

`CameraState` is `Codable`, making save/restore straightforward:

```swift
// Save
if let data = try? JSONEncoder().encode(viewport.cameraState) {
    UserDefaults.standard.set(data, forKey: "savedCamera")
}

// Restore
if let data = UserDefaults.standard.data(forKey: "savedCamera"),
   let saved = try? JSONDecoder().decode(CameraState.self, from: data) {
    viewport.animateTo(saved, duration: 0.4)
}
```
