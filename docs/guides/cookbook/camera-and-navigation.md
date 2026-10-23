---
title: Camera & Navigation
parent: Cookbook
nav_order: 3
---

# Camera & Navigation

The camera system is split across three types:

- **`CameraState`**: immutable value type (`Hashable, Codable, Sendable`) capturing the full camera pose.
- **`CameraController`**: `@MainActor` class that mutates state in response to gestures and drives animations.
- **`ViewportController`**: the top-level observable hub; exposes the controller as `cameraController` and mirrors its `@Published cameraState` for observation.

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
    // panOffset is deprecated: it was never applied to the view (pan moves pivot).

    // Derived, read-only
    public var position: SIMD3<Float>      // world-space eye position
    public var viewDirection: SIMD3<Float> // normalised, toward pivot
    public var upVector: SIMD3<Float>
    public var rightVector: SIMD3<Float>
    public var viewMatrix: simd_float4x4
}
```

`CameraState` is a plain value: capture it, persist it with `Codable`, diff it, or hand it to `animateTo(_:duration:)`.

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

Fixed planes like these waste depth precision on CAD scenes. Fit them to the scene instead, as the built-in renderers do on every frame:

```swift
let (near, far) = cameraState.clipPlanes(sceneBounds: sceneBoundingBox)
let proj = cameraState.projectionMatrix(
    aspectRatio: Float(viewSize.width / viewSize.height), near: near, far: far)
```

`near` sits 1% in front of the nearest corner of the scene's bounding box, measured as depth along the view direction, so neither a face square-on to the camera at the front of the box (a top view of a plate, a flat sketch) nor the near corner of an obliquely viewed scene is clipped by it.

The near plane can't go behind the eye, so an eye inside the scene still cuts it. In orthographic that never has to happen: the picture is `orthographicScale` tall wherever the eye is along the view axis, so orthographic zoom changes only the scale, and `MetalViewportView` keeps the eye in front of the scene (`CameraController.sceneBoundsProvider`): its bodies, the overlay bodies and the axes. `OffscreenRenderer` places the eye of the camera it is given the same way before it draws (issue #215). For a camera you use some other way, place the eye first:

```swift
let camera = cameraState.placingOrthographicEye(inFrontOf: sceneBoundingBox)
```

---

## Fitting the camera to geometry

`fit(to:aspectRatio:padding:)` returns a **new** `CameraState` with the pivot moved to the bounding-box centre and the distance (perspective) or `orthographicScale` (orthographic) adjusted so the bounding sphere fills the view. `padding` is a multiplier: `1.1` gives 10 % breathing room. The `[ViewportBody]` overload uses each visible body's world-space bounds (its `transform` applied) and leaves out `.overlay` widgets unless nothing else is visible.

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

Forward key presses to `ViewportController.handleKeyPress(_:modifiers:)` to run them. A press with ⌘, ⌃ or ⌥ held is ignored, so app shortcuts such as ⌘F still reach the app.

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
2. Runs a `Timer` at `CameraController.preferredFramesPerSecond` (default 120, set from `ViewportConfiguration.preferredFramesPerSecond`). Progress is time-based, so the rate affects smoothness only.
3. Applies an ease-out curve (`t = 1 - (1 - progress)³`) at each tick.
4. SLERPs `rotation` via `simd_slerp`; linearly interpolates `distance`, `pivot`, `fieldOfView`, and `orthographicScale` (and the deprecated, unused `panOffset`).
5. Snaps `isOrthographic` at the midpoint. When the projections differ, the start's unused value (`orthographicScale` in perspective, `distance` in orthographic) is first matched to the height it shows, so the snap doesn't jump the view in size.

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
// Orbit (drag translation in points, y down). handleOrbit is the raw call: it always turns
// the model with the drag. MetalViewportView's own drags also apply
// GestureConfiguration.dragRotation (default .rotateObject); to honour that in a custom
// gesture, multiply by configuration.gestureConfiguration.orbitDragSigns first, or
// dispatch .dragChanged / .dragEnded events instead.
viewport.handleOrbit(translation: gesture.translation)

// Release with inertia (velocity in pt/s; momentum starts at
// GestureConfiguration.momentumScale of it). Auto-snaps to a nearby axis view's orientation
// (keeping the projection) if velocity < 200 pt/s. Also ends the drag, so the next
// handleOrbit begins a new one.
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
cam.panSensitivity        = 1       // pan speed × the pointer's; 1 = 1:1
cam.viewportHeight        = 600     // view height in points; MetalViewportView sets it
cam.zoomSensitivity       = 1.0     // exponent on pinch / drag-zoom magnification
cam.scrollZoomSensitivity = 0.25    // exponential scale for scroll delta
cam.minPanSpeed           = 0       // optional floor, world units per point
cam.minDistance           = 0.1
cam.maxDistance           = 10_000  // also bounds orthographicScale (orthographicScaleRange)
cam.sceneBoundsProvider   = { sceneBounds }  // ortho eye stays in front of the scene; for your own view
                                             // (MetalViewportView sets it on appear, replacing yours)
cam.enableInertia         = true
cam.dampingFactor         = 0.1     // velocity lost per 1/60 s: 0 = no damping, 1 = instant stop
```

---

## Rotation styles

`RotationStyle` controls how drag gestures rotate the camera.

```swift
public enum RotationStyle: String, CaseIterable, Sendable {
    case arcball      // Ken Shoemake arcball; tumble inside the sphere, roll outside it
    case turntable    // Z-up locked; horizontal = yaw, vertical = tilt (over the pole too)
    case firstPerson  // Look-around: the camera turns in place, the pivot moves with it
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
| `.turntable` | CAD, architecture: "up is always up". Default. |
| `.arcball` | Freeform 3D modeling, inspecting objects from any angle. |
| `.firstPerson` | Walk-through, VR-style navigation. |

How each style feels under a drag:

- **Turntable.** Tilt is unlimited, so you can tilt over the pole and see the model upside down. Each drag decides at its start which way a horizontal drag turns, so the model keeps following the finger past the pole, and a drag that crosses the pole keeps its direction to the end, as in Blender.
- **Arcball.** The pointer moves over a virtual sphere centred on the view, with a radius of `2 / orbitSensitivity` points (400 pt by default). Drag across the middle to tumble the model. Start near the edge of the view and drag around the centre to roll it about the line of sight. The turn depends only on where the drag started and where the pointer is, so dragging back to the start undoes it.
- **First-person.** The camera turns in place to look around, and the pivot moves with the view. With the default `dragRotation = .rotateObject` the scene follows the finger, as in a touch panorama viewer. Set `.orbitCamera` for desktop mouse-look: drag right, look right. The dynamic pivot and the snap to standard views on a gentle release are off in this style, since both would move the camera.

```swift
var config = ViewportConfiguration()
config.rotationStyle = .firstPerson
config.gestureConfiguration.dragRotation = .orbitCamera  // mouse-look
let viewport = ViewportController(configuration: config)
```

---

## Dynamic pivot (auto orbit centre)

`PivotStrategy` adjusts the orbit centre automatically as the user zooms:

- **Zoomed out** (`distance / sceneDiagonalLength > zoomThreshold + halfBand`): orbit around the point on the line of sight at the scene centre's depth. In orthographic the distance is `orthographicScale / (2 · tan(fieldOfView / 2))`, where perspective would show the same height, so an orthographic zoom crosses the threshold as a perspective one does.
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

Configure via `ViewportConfiguration.dynamicPivotConfiguration`. The controller schedules updates automatically with a 50 ms coalesce delay after each orbit/zoom event; no manual calls needed. The update reads the bodies binding when it runs, so a body edited during the delay is raycast as it is then (issue #208).

A pivot change never moves the view. Every pivot the strategy returns is on the line of sight through the centre of the view, and the controller slides the pivot along it, changing only `distance`, so the camera's position and orientation stay exactly where the gesture left them, momentum or not. Before issue #200 the distance was kept, and the camera slid toward or away from the model after each gesture. Before issue #204 the zoomed-out pivot was the scene centre itself, off the line of sight whenever the user had panned, so releasing a pan slid the view back to centre the model.

To focus on a specific world point programmatically (bypassing the strategy):

```swift
// Animate pivot to a pick result's world position
viewport.focusOn(point: pickResult.worldPosition, distance: 5.0, animated: true)
```

`focusOn` stops any momentum, animated or not, so the camera stays on the point. Under an orthographic camera `distance` sets the zoom: the scale becomes the height a perspective camera 5 units away would show.

---

## Projection toggle

```swift
// Toggle perspective ↔ orthographic (animated), keeping the view's size at the pivot
viewport.toggleProjection()

// Or set directly and animate
var state = viewport.cameraState
state.isOrthographic = true
viewport.animateTo(state, duration: 0.3)
```

`toggleProjection()` and the standard views keep the height shown at the pivot: orthographic takes `orthographicScale = 2 · distance · tan(fieldOfView / 2)` and perspective takes the matching distance. Setting `isOrthographic` yourself, as in the second example, uses whatever `orthographicScale` the state holds.

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
