---
title: Camera
parent: API Reference
---

# Camera

Six types make up the camera system: `CameraState` holds the immutable snapshot of a view; `CameraController` drives interactive orbit/pan/zoom and animated transitions; `PivotStrategy` auto-selects the orbit center; `DynamicPivotConfiguration` tunes that heuristic; `RotationStyle` chooses the drag model; and `StandardView` enumerates the axis-aligned preset angles (and their `ViewCubeFace` companions).

## Topics

- [CameraState](#camerastate) · [CameraController](#cameracontroller) · [PivotStrategy](#pivotstrategy) · [DynamicPivotConfiguration](#dynamicpivotconfiguration) · [RotationStyle](#rotationstyle) · [StandardView](#standardview) · [ViewCubeFace](#viewcubeface)

---

## CameraState

`CameraState` is an immutable value type (`struct`) that fully describes a viewport orientation. Because it is `Hashable`, `Codable`, and `Sendable` it can be stored in settings, sent across actor boundaries, and diffed cheaply.

Obtain one from `CameraController.cameraState`, a `StandardView`, one of the static presets, or construct it directly.

```swift
// Save and restore a view
let bookmark = controller.cameraState
// … user navigates …
controller.animateTo(bookmark, duration: 0.4)
```

---

### `init(rotation:distance:pivot:fieldOfView:orthographicScale:isOrthographic:)`

```swift
public init(
    rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
    distance: Float = 10.0,
    pivot: SIMD3<Float> = .zero,
    fieldOfView: Float = 45.0,
    orthographicScale: Float = 10.0,
    isOrthographic: Bool = false
)
```

Designated initialiser. `rotation` is normalised on entry. All parameters are optional; the defaults produce a perspective view looking along +Y from 10 world units with a 45° vertical FoV.

The overload that also takes `panOffset:` (now without a default) is deprecated along with [`panOffset`](#var-panoffset-simd2float-deprecated); calls that omit it use the initialiser above.

---

### `var rotation: simd_quatf`

View rotation as a normalized quaternion mapping camera space into world space (look direction = `rotation.act(0, 0, -1)`).

---

### `var distance: Float`

Distance from the pivot point along the view direction. Must be positive. Use `CameraController.minDistance` / `maxDistance` to enforce limits during interaction.

In perspective it sets how large the view is. In orthographic `orthographicScale` does that, and `distance` only places the eye along the line of sight, which moves the clip planes but not the picture. Orthographic zoom leaves it alone, and `placingOrthographicEye(inFrontOf:)` raises it to keep the eye in front of the scene (issue #211).

---

### `var pivot: SIMD3<Float>`

Orbit center in world coordinates. All orbit gestures rotate the camera around this point.

---

### `var fieldOfView: Float`

Vertical field of view in degrees, used only when `isOrthographic == false`. Default `45.0`.

---

### `var orthographicScale: Float`

Vertical world-unit extent of the orthographic frustum, used only when `isOrthographic == true`. Default `10.0`.

---

### `var isOrthographic: Bool`

`true` for an orthographic projection, `false` (default) for perspective.

---

### `var panOffset: SIMD2<Float>` *(deprecated)*

Deprecated (issue #204): it was never applied to the view. It is still stored, compared, interpolated and encoded (`panOffsetX`/`panOffsetY`), so saved states keep round-tripping and existing code still compiles, with a deprecation warning. Nothing reads it: `viewMatrix` and `projectionMatrix` ignore it, and `CameraController.pan(deltaX:deltaY:)` moves the pivot instead, so setting it does not move the view. To pan programmatically, move `pivot` across the view:

```swift
var state = controller.cameraState
state.pivot += state.rightVector * dx + state.upVector * dy
controller.animateTo(state, duration: 0)
```

---

### `var position: SIMD3<Float>` *(computed)*

Camera eye position in world coordinates, derived as `pivot + rotation.act(0, 0, 1) * distance`.

---

### `var viewDirection: SIMD3<Float>` *(computed)*

Normalized look direction pointing toward the pivot: `rotation.act(0, 0, -1)`.

---

### `var upVector: SIMD3<Float>` *(computed)*

Camera up vector in world space: `rotation.act(0, 1, 0)`.

---

### `var rightVector: SIMD3<Float>` *(computed)*

Camera right vector in world space: `rotation.act(1, 0, 0)`.

---

### `var viewMatrix: simd_float4x4` *(computed)*

World-to-camera (view) matrix ready for a Metal `Uniforms` struct.

---

### `func projectionMatrix(aspectRatio:near:far:) -> simd_float4x4`

```swift
public func projectionMatrix(
    aspectRatio: Float,
    near: Float = 0.01,
    far: Float = 1000.0
) -> simd_float4x4
```

Returns a perspective or orthographic projection matrix in Metal NDC (z in [0, 1]). When `isOrthographic` is true the frustum is derived from `orthographicScale`; when false from `fieldOfView`. Prefer `clipPlanes(sceneBounds:)` over the fixed `near`/`far` defaults for CAD scenes.

---

### `func clipPlanes(sceneBounds:) -> (near: Float, far: Float)`

```swift
public func clipPlanes(sceneBounds: BoundingBox?) -> (near: Float, far: Float)
```

Returns scene-adaptive near/far clip distances. When `sceneBounds` is `nil` (empty scene) returns `(0.01, 10_000)`. Otherwise `far` reaches past the back of the scene's bounding sphere, while `near` sits just in front of the bounding **box**: the box's smallest view-space depth (the depth of its nearest corner along `viewDirection`) pulled back by `nearPlaneMargin` (1%), clamping the `far/near` ratio to ≤ 1e4 to preserve depth-buffer precision regardless of model scale.

Measuring `near` against the box rather than the sphere matters for non-cubic scenes. A camera that is clear of the geometry but inside its circumscribed sphere used to collapse `near` to the `far * 1e-4` floor, throwing away roughly four orders of magnitude of depth precision and producing section-view artifacts (issue #116). `near` still falls back to that floor when part of the box is at or behind the camera plane (the camera is inside the geometry, or beside it), where the box's smallest depth is `0` or less.

Depth, not straight-line distance, is what the near plane cuts at. Earlier releases set `near` from the Euclidean camera-to-box distance, which only equals the depth straight ahead: a box viewed obliquely, with its nearest corner off the view axis, is nearer in depth than in distance, so its front was clipped.

The 1% margin keeps geometry on the box's camera-facing face (the top face in a top view, a flat panel, an edge-only sketch, which since #135 defines the box itself) at a small positive depth. With `near` exactly on the box, that geometry sat at NDC z = 0 and rounding could clip it away (issue #156). The margin raises the `far/near` ratio by about 1%, a negligible share of depth precision.

`ViewportRenderer` fits these planes on every frame, including a body's first one: it uses the body's cached bounds when they are current and computes them from the body otherwise, so a frame never falls back to the wide `(0.01, 10_000)` range just because a body is new (issue #157). `OffscreenRenderer` computes them from the bodies on every render.

```swift
let (near, far) = state.clipPlanes(sceneBounds: sceneBB)
let proj = state.projectionMatrix(aspectRatio: aspect, near: near, far: far)
```

---

### `func placingOrthographicEye(inFrontOf:) -> CameraState`

```swift
public func placingOrthographicEye(inFrontOf bounds: BoundingBox?) -> CameraState
```

Returns an orthographic copy whose eye sits in front of `bounds`. An orthographic picture does not depend on where the eye is along the view axis, but the near plane cannot go behind the eye, so an eye inside the model cut away everything between it and the front of the model. This raises `distance`, keeping the pivot, rotation and `orthographicScale`, until the nearest corner of `bounds` is one scene radius (half the box's diagonal) in front of the eye. The picture is unchanged; `clipPlanes(sceneBounds:)` then takes in the whole scene. A perspective camera, `nil` bounds, or an eye already that far in front come back unchanged, and the eye is only ever moved back (issue #211).

`CameraController` applies it after every camera change when it has a `sceneBoundsProvider`, which `MetalViewportView` sets, and `fit(to:aspectRatio:padding:)` applies it in orthographic. `OffscreenRenderer` applies it to the camera it renders, with the bounds of its bodies, overlay bodies and axes (also with `explicitOrthoBounds` on a perspective camera), so a headless orthographic render is not near-clipped (issue #215). Call it yourself on a camera you use some other way:

```swift
let camera = state.placingOrthographicEye(inFrontOf: sceneBounds)
```

---

### `func fit(to:aspectRatio:padding:) -> CameraState`

```swift
public func fit(to bounds: BoundingBox, aspectRatio: Float, padding: Float = 1.1) -> CameraState
```

Returns a copy of the state whose pivot and distance (or `orthographicScale`) are adjusted so that the bounding sphere of `bounds` fills the view from the current viewing direction. `padding` is multiplicative: `1.0` = tight fit, `1.1` = 10 % breathing room (default). In orthographic it also moves the eye back, if need be, to sit in front of `bounds` (see `placingOrthographicEye(inFrontOf:)`), so a short `distance` doesn't near-clip the front of what it frames.

---

### `func fit(to:aspectRatio:padding:) -> CameraState?`

```swift
public func fit(to bodies: [ViewportBody], aspectRatio: Float, padding: Float = 1.1) -> CameraState?
```

Convenience overload. Unions the world-space bounding boxes of the visible bodies, each moved by its `transform`, and calls the `BoundingBox` overload. `.overlay`-layer bodies (gizmos, manipulators) are left out, as in the renderer's scene bounds, unless no visible geometry-layer body has any. Returns `nil` when no visible body has geometry. Before issue #208 the boxes were taken in body-local space and overlays counted, so a moved body or an off-model widget gave the wrong fit.

```swift
if let fitted = controller.cameraState.fit(to: bodies, aspectRatio: aspect) {
    controller.animateTo(fitted, duration: 0.4)
}
```

---

### `static func lookAt(target:from:up:) -> CameraState`

```swift
public static func lookAt(
    target: SIMD3<Float>,
    from position: SIMD3<Float>,
    up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)
) -> CameraState
```

Constructs a state that positions the camera at `position` looking toward `target`.

---

### `func interpolated(to:t:) -> CameraState`

```swift
public func interpolated(to target: CameraState, t: Float) -> CameraState
```

Returns a state interpolated between `self` (t = 0) and `target` (t = 1). Uses SLERP for rotation and linear interpolation for all scalar/vector fields. `isOrthographic` switches at t = 0.5. When the two differ in projection, the start's unused value (`orthographicScale` in perspective, `distance` in orthographic) is first set to the one that shows the same height at the pivot, so the switch at t = 0.5 no longer jumps the view in size. Used internally by `CameraController` animations.

---

### Static presets

```swift
public static let isometric: CameraState   // front-right-top isometric corner
public static let top: CameraState         // plan view, looking down −Z
public static let front: CameraState       // front elevation, looking along +Y
public static let right: CameraState       // right side, looking along −X
```

Convenience constants backed by the corresponding `StandardView` case.

---

### `Codable` conformance

`CameraState` encodes/decodes via explicit flattened keys (`rotationX/Y/Z/W`, `pivotX/Y/Z`, `panOffsetX/Y`, etc.). The format is stable across releases.

---

## CameraController

`CameraController` is a `@MainActor` `ObservableObject` that owns a `CameraState` and handles interactive orbit, pan, zoom, roll, focus, and animated transitions. It drives a timer for inertia decay and state-interpolation animations, running at `preferredFramesPerSecond` (default 120; `ViewportController` sets it from `ViewportConfiguration.preferredFramesPerSecond`). Inertia and animation are time-based, so the tick rate changes only smoothness, not speed.

Obtain it from `ViewportController.cameraController`, or create a standalone instance for headless use.

```swift
let controller = CameraController(standardView: .isometricFrontRight, distance: 50)
controller.rotationStyle = .arcball
controller.animateTo(.top, duration: 0.3)
```

---

### `init(initialState:)`

```swift
public init(initialState: CameraState = CameraState())
```

Creates a controller with an explicit initial state. Extracts spherical coordinates from `initialState.rotation` to seed the turntable orbit state.

---

### `convenience init(standardView:distance:)`

```swift
public convenience init(standardView: StandardView, distance: Float = 10)
```

Creates a controller positioned at a named standard view.

---

### `@Published var cameraState: CameraState` *(read-only)*

The current camera state. Subscribe via Combine or use SwiftUI's `@ObservedObject` / `@StateObject` to react to changes.

---

### `var sceneBoundsProvider: (@MainActor () -> BoundingBox?)?`

Returns the world-space bounds of the scene, which an orthographic eye is kept in front of. With a provider set, each change to `cameraState` in orthographic moves the eye back along the line of sight, if need be, until it is in front of these bounds (see `CameraState.placingOrthographicEye(inFrontOf:)`); the picture does not change, only `distance`. An eye already in front is not moved, so the dynamic pivot sliding along the line of sight never moves it. `MetalViewportView` sets one that reads its bodies when it appears, replacing any set before: the visible geometry bodies, every visible overlay body (each counted only up to four diagonals past the model and axes, the same cap the orthographic clip fit now uses) and the axes when they show, so a widget or the axes nearer the camera than the model are not near-clipped (issue #215). None of these depends on the pivot, so the dynamic pivot still never moves the eye. The grid is not included: the part drawn follows the pivot. It also re-places the eye when the scene's bounds change under a still camera; `nil` (the default) leaves the eye of `cameraState` where `distance` puts it (issue #211); `ViewportRenderer` still draws an orthographic frame from an eye placed in front of the scene (issue #215). Each change is published once, already placed.

While the eye stays put and the pivot moves (the dynamic pivot), an orthographic `distance` is kept above `minDistance` but not capped at `maxDistance`: the placed eye may sit further back than that in front of a large scene, and the cap stopped the pivot short of the surface it was sliding to.

---

### `func placeOrthographicEyeInFrontOfScene()`

```swift
public func placeOrthographicEyeInFrontOfScene()
```

Moves an orthographic eye in front of the `sceneBoundsProvider`'s bounds now, without any other camera change, for when the scene changed rather than the camera (a model loaded or moved). Does nothing in perspective, without a provider, or when the eye is already in front.

---

### `@Published var isAnimating: Bool` *(read-only)*

`true` while a `animateTo` or inertia animation is running.

---

### Configuration properties

| Property | Type | Default | Purpose |
|---|---|---|---|
| `rotationStyle` | `RotationStyle` | `.turntable` | Drag rotation model. Changing it ends any orbit drag and re-reads the turntable angles from the current rotation |
| `orbitSensitivity` | `Float` | `0.005` | Radians per point of drag |
| `panSensitivity` | `Float` | `1` | Pan speed as a multiple of the pointer's; `1` is 1:1 (see [`pan`](#func-pandeltaxdeltay)) |
| `viewportHeight` | `Float` | `800` | Height of the view in points, which pan uses to stay 1:1. `MetalViewportView` keeps it current |
| `zoomSensitivity` | `Float` | `1.0` | Exponent applied to pinch / drag-zoom magnification by `pinchZoom` |
| `scrollZoomSensitivity` | `Float` | `0.25` | Scroll wheel exponent factor |
| `minPanSpeed` | `Float` | `0` | Floor on pan speed, in world units per point. `0` keeps pan 1:1 at any distance |
| `minDistance` | `Float` | `0.1` | Minimum pivot distance |
| `maxDistance` | `Float` | `10000` | Maximum pivot distance |
| `orthographicScaleRange` | `ClosedRange<Float>` | read-only | The range zoom keeps `orthographicScale` in: the heights the field of view spans at `minDistance` and `maxDistance` |
| `minPhi` | `Float` | `0.01` | **Deprecated, ignored.** Turntable tilt is unclamped by design |
| `maxPhi` | `Float` | `π − 0.01` | **Deprecated, ignored.** See `minPhi` |
| `dampingFactor` | `Float` | `0.1` | Inertia velocity lost per 1/60 s, scaled by elapsed time (0 = coast forever) |
| `enableInertia` | `Bool` | `true` | Whether inertia is applied after gestures end |
| `preferredFramesPerSecond` | `Int` | `120` | Rate of the animation / inertia timer |
| `homeCameraState` | `CameraState` | the initial state | State that `reset(animated:)` returns to |
| `zoomTowardShiftsPivot` | `Bool` | `true` | Whether `zoomToward` shifts the pivot toward the cursor |

The sensitivity, inertia and damping defaults are read from `GestureConfiguration.default`, so a standalone controller feels the same as one that `ViewportController` configured. Previously a standalone controller used `panSensitivity` 0.002 and `scrollZoomSensitivity` 0.1, while `ViewportController` always overwrote them with 0.005 and 0.25.

The turntable tilt is deliberately unclamped: the camera can tilt over the pole for a full 360° vertical orbit. `minPhi` and `maxPhi` were documented as clamps but never read, and are now deprecated. Past the pole the camera is upside down, and a turn about world Z looks reversed from there, so each drag decides at its start which way a horizontal drag turns (see [`beginOrbitDrag(at:signs:)`](#func-beginorbitdragatsigns)). A drag that begins upside down still carries the model with the pointer; a drag that crosses the pole keeps the direction it began with rather than flipping partway, as in Blender.

---

### `func orbit(deltaX:deltaY:)`

```swift
public func orbit(deltaX: Float, deltaY: Float)
```

Rotates the camera by the given drag delta in points (y down), dispatching to the algorithm selected by `rotationStyle` (arcball, turntable, or first-person).

In every style the model turns with the delta: a positive `deltaX` carries the model's near side right on screen, and a negative `deltaY` (an upward drag) carries it up. `ViewportController` multiplies drag deltas by `GestureConfiguration.orbitDragSigns` before calling this, which is how `DragRotationConvention.orbitCamera` and the invert flags reverse it. Arcball turns about an axis in screen space, so a horizontal drag from any view turns the model about the screen's vertical axis; before this was fixed, it turned about a world axis, and from the front view a horizontal drag rolled the picture instead.

Successive calls are one drag until `endOrbitDrag()`. If `beginOrbitDrag(at:signs:)` was not called, the first call begins a drag at the centre of the view with every sign `1`. Code that drives the camera with `orbit` directly should call `endOrbitDrag()` (or `ViewportController.endOrbit(velocity:)`) when its gesture ends, so the next gesture begins a new drag.

---

### `func beginOrbitDrag(at:signs:)`

```swift
public func beginOrbitDrag(at pointer: SIMD2<Float> = .zero, signs: SIMD3<Float> = SIMD3(1, 1, 1))
```

Begins an orbit drag and stops any orbit momentum still coasting. `pointer` is where the drag starts, in points from the centre of the view (y down). `signs` is the drag direction as (horizontal, vertical, roll), each `1` or `-1`; `ViewportController` passes `GestureConfiguration.orbitDragSigns` and `orbitRollSign`.

A drag fixes two things at its start:

- **Turntable and first-person:** whether the camera is upside down. If its up vector points below the horizon, a horizontal drag turns the other way for the whole drag, so the model still follows the pointer. Deciding once avoids a jump when a drag crosses the top view. Before this, a turntable tilted over the pole turned against the pointer on every later drag.
- **Arcball:** where the pointer is on the virtual sphere. See [`case arcball`](#case-arcball).

The deltas passed to `orbit(deltaX:deltaY:)` already carry the horizontal and vertical signs. The arcball uses `signs` to recover where the pointer really is, and the roll sign to set which way a drag outside the sphere rolls.

---

### `func endOrbitDrag()`

```swift
public func endOrbitDrag()
```

Ends the orbit drag in progress. Momentum set by `setAngularVelocity(_:)` keeps coasting the way the drag was turning (past the pole, the momentum keeps the drag's direction too). The drag is forgotten once the momentum dies out or the next drag begins.

---

### `var isOrbitDragActive: Bool` *(read-only)*

`true` between `beginOrbitDrag(at:signs:)` (or the first `orbit` call) and `endOrbitDrag()`.

---

### `func stopInertia()`

```swift
public func stopInertia()
```

Stops orbit and pan momentum and forgets any orbit drag. When a new drag or two-finger gesture begins, `ViewportController` does this and also cancels any animation to a target view (a standard view, a reset, or the snap after a slow release), so touching the view stops a coasting model instead of adding the new drag to its momentum. Previously an animation still running replayed its path on every tick, so a drag or pan made during it was overwritten and then thrown away. The dynamic pivot's pivot-only animation keeps running, since it moves the pivot alongside the gesture.

---

### `func pan(deltaX:deltaY:)`

```swift
public func pan(deltaX: Float, deltaY: Float)
```

Shifts the pivot in the camera's local XY plane. At the default `panSensitivity` of `1` the pan is 1:1: the world point under the pointer when the drag starts is still under it when the drag ends. In perspective that holds for points at the pivot's depth; in orthographic it holds for every point. One point of drag moves the pivot by the height the view shows (`orthographicScale`, or the height the field of view spans at `distance`) divided by `viewportHeight`, times `panSensitivity`, floored at `minPanSpeed` world units. Pan momentum uses the same scale.

**Behaviour change (issue #200).** Pan used to move `distance × panSensitivity` world units per point with a default of `0.005`, about five times as far as the finger in an 800 pt tall view, and it ignored the field of view and, in orthographic, the scale: once the distance reached its limit an orthographic pan no longer matched the zoom. `panSensitivity` is now a multiplier of the 1:1 speed with a default of `1`, and `minPanSpeed` defaults to `0`, since 1:1 already tracks the pointer however close the camera is (the old `0.001` floor broke 1:1 inside a distance of about 1). An app that set `panSensitivity` to `0.005` itself pans 200 times slower than 1:1 and should use `1`, or another multiplier.

---

### `func zoom(factor:)`

```swift
public func zoom(factor: Float)
```

In perspective, multiplies distance by `1 / factor` (factor > 1 zooms in), clamped to `[minDistance, maxDistance]`. In orthographic, multiplies `orthographicScale` by `1 / factor` instead, clamped to `orthographicScaleRange`, so an orthographic view zooms as far in and out as a perspective one. The scale used to be unbounded and could shrink toward zero or grow without limit. This is the raw primitive: it does not apply `zoomSensitivity`.

**Behaviour change (issue #211).** An orthographic zoom no longer changes `distance`. It used to divide it too, which walked the eye toward the pivot without changing the picture; zoomed in, the eye ended up inside the model and the near plane cut its front half away.

---

### `func pinchZoom(magnification:cursorNormalized:aspectRatio:)`

```swift
public func pinchZoom(
    magnification: Float,
    cursorNormalized: SIMD2<Float>? = nil,
    aspectRatio: Float = 1.0
)
```

Zooms by a pinch or drag-zoom magnification raised to `zoomSensitivity`, then passes through to `zoomToward`. Non-positive magnifications are ignored. `ViewportController.handleZoom` and the input router's pinch and drag-zoom paths go through this method.

---

### `func scrollZoom(delta:cursorNormalized:aspectRatio:)`

```swift
public func scrollZoom(
    delta: Float,
    cursorNormalized: SIMD2<Float>? = nil,
    aspectRatio: Float = 1.0
)
```

Applies a scroll-wheel delta using an exponential mapping (`factor = exp(delta * scrollZoomSensitivity)`) so in/out scrolls cancel symmetrically. Passes through to `zoomToward`. `cursorNormalized` is in NDC (−1…+1); pass `nil` for center zoom.

---

### `func zoomToward(factor:cursorNormalized:aspectRatio:)`

```swift
public func zoomToward(factor: Float, cursorNormalized: SIMD2<Float>?, aspectRatio: Float = 1.0)
```

Zoom-at-cursor / pinch-at-fingers. Adjusts the pivot so the world point under `cursorNormalized` stays stationary during the zoom. Works in both perspective and orthographic modes. `nil` cursor = plain centre zoom. The pivot moves by the zoom actually applied, so once the distance reaches `minDistance` or `maxDistance` the view stops; previously it kept sliding toward the cursor.

The pivot shift is gated on `zoomTowardShiftsPivot`. When that is `false` the zoom still changes distance (or orthographic scale) and the pivot holds still, so zoom-at-cursor no longer drifts the orbit centre for apps that have turned dynamic pivoting off. `ViewportController` keeps the flag in step with `ViewportConfiguration.dynamicPivotConfiguration.isEnabled` (issue #117).

---

### `func roll(deltaAngle:)`

```swift
public func roll(deltaAngle: Float)
```

Rolls the camera around its forward axis by `deltaAngle` radians. The line of sight does not move, so a roll needs no dynamic pivot update: `MetalViewportView` schedules none when a rotate gesture ends, by design, since the update would find the pivot the camera already has (issue #211). A positive angle turns the picture clockwise on screen, matching the `.rotateChanged` event (positive is a clockwise twist), in every rotation style; previously arcball and first-person rolled the other way from turntable. In turntable mode the roll is stored separately so it survives subsequent orbit moves; in arcball/first-person modes it is baked directly into the rotation quaternion.

---

### `func animateTo(_:duration:)` (CameraState)

```swift
public func animateTo(_ target: CameraState, duration: Float = 0.3)
```

Animates smoothly to `target` using SLERP for rotation and an ease-out (1 − (1 − t)³) curve over `duration` seconds. Passing `duration: 0` snaps immediately and cancels any animation in progress (previously a running animation overwrote the snap on its next tick). Stops orbit and pan momentum, which would otherwise fight the animation, and ends any orbit drag.

---

### `func animateTo(_:duration:)` (StandardView)

```swift
public func animateTo(_ view: StandardView, duration: Float = 0.3)
```

Convenience overload that preserves the current `pivot`, `distance`, `fieldOfView`, and `orthographicScale` while snapping to the standard view's orientation and projection type. When the view is in the other projection (the axis views are orthographic, the isometric ones perspective), it keeps the height shown at the pivot instead: going orthographic, `orthographicScale` becomes `2 · distance · tan(fieldOfView / 2)`; going perspective, `distance` becomes `orthographicScale / (2 · tan(fieldOfView / 2))`, within `[minDistance, maxDistance]`. Previously the other projection's last value was kept, the default scale of 10 the first time, so pressing a face view jumped the view in size.

---

### `func cancelAnimation()`

```swift
public func cancelAnimation()
```

Stops any running animation immediately, leaving `cameraState` at its current interpolated position. Momentum keeps coasting; previously cancelling also stopped the shared timer, which froze any momentum until the next gesture.

---

### `func focusOn(point:distance:animated:)`

```swift
public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true)
```

Moves the pivot to `point`. Optionally sets a new `distance` (clamped to `[minDistance, maxDistance]`). In orthographic, `distance` zooms instead: `orthographicScale` becomes the height a perspective camera that far from the point would show, `2 · distance · tan(fieldOfView / 2)`, within `orthographicScaleRange`, and the eye's distance is kept. It used to set the eye's distance, which an orthographic view does not show, so the call did not zoom (issue #211). Animated by default (0.3 s). Animated or not, it stops orbit and pan momentum and cancels any animation in progress. Previously `animated: false` left momentum coasting, which carried the camera off the point straight away.

---

### `func reset(animated:)`

```swift
public func reset(animated: Bool = true)
```

Resets to `homeCameraState`, which defaults to the controller's initial state; for a `ViewportController` that is `ViewportConfiguration.initialCameraState`. Animated by default (0.5 s). Also clears any accumulated roll and, animated or not, stops any momentum. Previously this always went to `CameraState()`, whatever the configuration said.

---

### `func adjustPivot(to:duration:)`

```swift
public func adjustPivot(to newPivot: SIMD3<Float>, duration: Float = 0.15)
```

Silently shifts the orbit pivot if the new position differs by more than 0.001 world units and no animation is already running. Only the pivot is animated, so orbit and pan momentum keep coasting while it moves. Previously the animation replayed the rotation it started from on every tick and, when it finished, threw away whatever the momentum had turned in the meantime, so the model jumped back. `ViewportController` skips the dynamic pivot in `.firstPerson`, where moving the pivot would move the camera.

The camera keeps its place along the line of sight: `distance` changes by the pivot's change in depth (clamped to `[minDistance, maxDistance]`). A pivot that moves along the view axis, such as the dynamic pivot's view-centre raycast hit, leaves the view exactly as it was. Previously the distance was kept, so the camera slid toward or away from the model after each gesture when zoomed in, a visible zoom jump (issue #200). Only a move across the view still moves the camera, sideways, as it must for the pivot to stay at the centre of the view. The dynamic pivot never makes such a move: `ViewportController` slides the pivot along the current line of sight to the depth `PivotStrategy` picked, recomputing it from the camera's position on every tick, so the view never moves, even while momentum turns or pans it (issue #204).

---

### `func setAngularVelocity(_:)`

```swift
public func setAngularVelocity(_ velocity: SIMD2<Float>)
```

Seeds inertia with an angular velocity, in drag points per 1/60 s (X = horizontal, Y = vertical); each tick orbits by `velocity × elapsed × 60` points. No-op when `enableInertia` is `false`. Call at gesture end to enable coasting, before `endOrbitDrag()`. To convert a release velocity in points per second, divide by 60; `ViewportController.endOrbit(velocity:)` does that and scales by `GestureConfiguration.momentumScale`.

---

### `func setPanVelocity(_:)`

```swift
public func setPanVelocity(_ velocity: SIMD2<Float>)
```

Seeds pan inertia. Same semantics as `setAngularVelocity`.

---

## PivotStrategy

`PivotStrategy` is a `@MainActor` helper that chooses an appropriate orbit center each time the user begins an orbit gesture. Every pivot it returns is on the line of sight through the view centre, so moving the pivot there never moves the view. When the camera is zoomed out it returns the point on the line of sight at the depth of the scene centre (the centre of the world-space union of the visible `.geometry`-layer bodies' bounds, each moved by its current `transform`, so moving a body by transform alone moves the pivot too; hidden and `.overlay` bodies are left out). It used to return the scene centre itself, which after a pan was off to the side, so releasing the pan slid the view back to the model (issue #204). When zoomed in close it raycasts through the view center and returns the hit point; in between it blends smoothly via a smoothstep curve.

`ViewportController` owns a `PivotStrategy` and drives it automatically. You only need to interact with it directly for custom viewport integrations.

---

### `init()`

```swift
public init()
```

---

### `func computePivot(cameraState:bodies:aspectRatio:config:clipPlanes:) -> SIMD3<Float>?`

```swift
public func computePivot(
    cameraState: CameraState,
    bodies: [ViewportBody],
    aspectRatio: Float,
    config: DynamicPivotConfiguration,
    clipPlanes: [ClipPlane] = []
) -> SIMD3<Float>?
```

Returns the recommended pivot, or `nil` when `config.isEnabled` is `false`, no scene geometry exists, the scene centre is behind the camera, or (closer in than the zoomed-out band) the view-centre raycast misses. The view-centre raycast skips geometry removed by `clipPlanes`, so a sectioned model pivots on what is drawn; `ViewportController` passes its own `clipPlanes`. `ViewportController` slides its pivot along the line of sight to the result's depth. A custom integration can pass the result to `CameraController.adjustPivot(to:duration:)`, which for a point on the line of sight also leaves the view unchanged.

---

### `func invalidateCache()`

```swift
public func invalidateCache()
```

Forces the bounding-box cache to be rebuilt on the next `computePivot` call. Rarely needed: the cache is keyed on each body's `generation`, which changes whenever its geometry is replaced or mutated, and entries for bodies no longer passed in are pruned.

---

## DynamicPivotConfiguration

`DynamicPivotConfiguration` is a `Sendable` value type that controls how aggressively `PivotStrategy` adjusts the orbit center.

---

### `init(isEnabled:animationDuration:zoomThreshold:blendBand:)`

```swift
public init(
    isEnabled: Bool = true,
    animationDuration: Float = 0.15,
    zoomThreshold: Float = 0.5,
    blendBand: Float = 0.3
)
```

- **`isEnabled`**: set to `false` to use a fixed pivot at all times.
- **`animationDuration`**: how long the pivot glide animation takes (seconds).
- **`zoomThreshold`**: `cameraDistance / sceneDiagonalLength` ratio that separates "zoomed out" (the scene centre's depth on the line of sight) from "zoomed in" (raycast hit). Default `0.5`. In orthographic the camera distance is `orthographicScale / (2 · tan(fieldOfView / 2))`, the distance at which perspective shows the same height, since orthographic zoom changes the scale and the pivot slide changes `distance` without changing the view. Before issue #208 `distance` was used in both, so an orthographic zoom could stay on the wrong side of the threshold.
- **`blendBand`**: fraction of `zoomThreshold` used as the width of the smoothstep blend zone between the two pivot strategies. Default `0.3`.

---

### `var isEnabled: Bool`

Disables dynamic pivot when `false`; `PivotStrategy.computePivot` returns `nil`.

---

### `var animationDuration: Float`

Duration of the pivot-glide animation in seconds.

---

### `var zoomThreshold: Float`

Zoom-ratio crossover point (camera distance / scene diagonal; in orthographic, the distance at which perspective shows `orthographicScale`).

---

### `var blendBand: Float`

Blend band width as a fraction of `zoomThreshold`.

---

### `static let default: DynamicPivotConfiguration`

Canonical default: enabled, 0.15 s animation, threshold 0.5, blend band 0.3.

---

## RotationStyle

`RotationStyle` selects the mathematical model used by `CameraController.orbit(deltaX:deltaY:)`.

```swift
public enum RotationStyle: String, CaseIterable, Sendable
```

---

### Cases

#### `case arcball`

Unrestricted 3D rotation using Ken Shoemake's arcball. The pointer is placed on a virtual sphere centred on the view, and the rotation is measured from where the drag began to where the pointer is now. Inside the sphere a drag tumbles the model about an axis perpendicular to the drag. Outside it the pointer is held to the sphere's rim, so moving around the centre rolls the view about the line of sight. Because the rotation depends only on the two pointer positions, a pointer that returns to where it began leaves the model as it found it. Best for freeform 3D modelling.

The sphere's radius is `2 / orbitSensitivity` points (400 pt at the default 0.005), so a short drag near the centre turns the model `orbitSensitivity` radians per point, as in the other styles. A drag from the centre to the rim turns it 180°. `MetalViewportView` tells the viewport where each drag starts (`ViewportController.setDragOrigin(offsetFromCenter:)`), so a drag that starts near the edge of the view and moves around the centre rolls it. A two-finger drag bound to `.orbit` starts at the touches' centroid (`ViewportController.setTwoFingerDragOrigin(offsetFromCenter:)`), so it can roll the view too; it used to start at the centre and could only tumble. A navigation cube drag starts at its offset from the cube's centre, which is well inside the sphere, so it tumbles. A drag with no known start, such as a direct `orbit` call, starts at the centre.

The direction follows `GestureConfiguration.dragRotation`: with `.rotateObject` the model turns and rolls with the pointer, as if the pointer held the sphere; `.orbitCamera` reverses both. The invert flags reverse only the horizontal or vertical turn, not the roll.

Before this, each drag step was projected from the sphere's centre with a 300 pt radius, so a step would have needed about 850 pt to leave the sphere and the arcball never rolled.

#### `case turntable`

Z-axis–locked rotation ("pottery wheel"). Horizontal drag rotates around world Z; vertical drag tilts the camera up and down, without a limit, so it can tilt over the pole. A drag that begins upside down reverses the horizontal turn so the model still follows the pointer. Best for CAD, architecture, and any domain where "up is up".

#### `case firstPerson`

Look-around: the camera turns in place. Horizontal drag yaws around world Z; vertical drag pitches around the camera's right vector. The camera position stays where it is and the pivot moves with the view, kept `distance` in front of the camera, so zoom still dollies toward what is in the middle of the view. Before this, the camera position was derived from a fixed pivot, so first-person turned about the pivot like the other styles and could not look around in place.

How it interacts with `GestureConfiguration.dragRotation`:

- `.rotateObject` (default) drags the scene with the pointer, as in a touch panorama viewer: drag right and the view turns left, so what is in front of the camera moves right with the finger.
- `.orbitCamera` is desktop mouse-look: drag right, look right.

The invert flags flip one axis on top of either. As with turntable, a drag that begins with the camera upside down reverses the horizontal turn, so the scene still follows the convention. In `.firstPerson`, `ViewportController` does not move the pivot to the geometry under the view centre after a drag (the dynamic pivot), and a gentle release does not snap to a nearby standard view, since both would move the camera.

---

### `var description: String`

Human-readable one-line description of the rotation behaviour.

---

### `var hasConstraints: Bool`

`false` for `.arcball`; `true` for `.turntable` and `.firstPerson`.

---

### Static shorthands

```swift
public static let cadDefault: RotationStyle      // .turntable
public static let modelingDefault: RotationStyle // .arcball
```

---

## StandardView

`StandardView` enumerates the ten axis-aligned camera presets used by CAD tools: six orthographic face views and four isometric corners.

```swift
public enum StandardView: String, CaseIterable, Sendable
```

---

### Orthographic cases

| Case | Direction |
|---|---|
| `.top` | Looking down −Z (plan view) |
| `.bottom` | Looking up +Z |
| `.front` | Looking along +Y (front elevation) |
| `.back` | Looking along −Y |
| `.right` | Looking along −X |
| `.left` | Looking along +X |

---

### Isometric cases

| Case | Corner |
|---|---|
| `.isometricFrontRight` | Front-right-top (standard isometric) |
| `.isometricFrontLeft` | Front-left-top |
| `.isometricBackRight` | Back-right-top |
| `.isometricBackLeft` | Back-left-top |

Isometric views use true equal-angle isometric tilt (arctan(1/√2) ≈ 35.26° above horizon) and perspective projection.

---

### `var displayName: String`

Human-readable label, e.g. `"Top"`, `"Isometric"`.

---

### `var keyboardShortcut: Character?`

Single-character shortcut assigned by convention: `t` (top), `f` (front), `r` (right), `l` (left), `i` (isometricFrontRight). All other cases return `nil`.

---

### `var isOrthographic: Bool`

`true` for the six face views; `false` for the four isometric views.

---

### `var rotation: simd_quatf`

Rotation quaternion for this standard view in the Z-up world convention. The look direction is `rotation.act(0, 0, -1)` and the up vector is `rotation.act(0, 1, 0)`.

---

### `func cameraState(pivot:distance:fieldOfView:orthographicScale:) -> CameraState`

```swift
public func cameraState(
    pivot: SIMD3<Float> = .zero,
    distance: Float = 10.0,
    fieldOfView: Float = 45.0,
    orthographicScale: Float = 10.0
) -> CameraState
```

Creates a `CameraState` positioned for this view. Automatically sets `isOrthographic` from `self.isOrthographic`.

```swift
// Fit isometric to a loaded model
let iso = StandardView.isometricFrontRight
    .cameraState(pivot: bounds.center, distance: bounds.diagonalLength * 2)
controller.animateTo(iso, duration: 0.4)
```

---

### `static func fromViewCubeFace(_:) -> StandardView`

```swift
public static func fromViewCubeFace(_ face: ViewCubeFace) -> StandardView
```

Maps a `ViewCubeFace` tap to the corresponding `StandardView`.

---

## ViewCubeFace

Six-case enum identifying the clickable face regions of the navigation cube.

```swift
public enum ViewCubeFace: String, CaseIterable, Sendable {
    case top, bottom, front, back, right, left
}
```

Pass to `StandardView.fromViewCubeFace(_:)` to obtain the matching camera preset, or to `ViewportController.goToRegion(_:duration:)` via the `ViewCubeRegion` / `NavigationCube` pipeline.
