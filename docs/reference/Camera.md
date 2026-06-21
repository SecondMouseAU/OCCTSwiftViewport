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

### `init(rotation:distance:pivot:fieldOfView:orthographicScale:isOrthographic:panOffset:)`

```swift
public init(
    rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)),
    distance: Float = 10.0,
    pivot: SIMD3<Float> = .zero,
    fieldOfView: Float = 45.0,
    orthographicScale: Float = 10.0,
    isOrthographic: Bool = false,
    panOffset: SIMD2<Float> = .zero
)
```

Designated initialiser. `rotation` is normalised on entry. All parameters are optional — the defaults produce a perspective view looking along +Y from 10 world units with a 45° vertical FoV.

---

### `var rotation: simd_quatf`

View rotation as a normalized quaternion mapping camera space into world space (look direction = `rotation.act(0, 0, -1)`).

---

### `var distance: Float`

Distance from the pivot point along the view direction. Must be positive. Use `CameraController.minDistance` / `maxDistance` to enforce limits during interaction.

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

### `var panOffset: SIMD2<Float>`

Camera-relative pan offset for fine-tuning the view centre without moving the pivot. Usually managed by `CameraController.pan(deltaX:deltaY:)` rather than set directly.

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

Returns scene-adaptive near/far clip distances. When `sceneBounds` is `nil` (empty scene) returns `(0.01, 10_000)`. Otherwise computes distances from the camera to the near and far surfaces of the scene's bounding sphere, clamping the `far/near` ratio to ≤ 1e4 to preserve depth-buffer precision regardless of model scale.

```swift
let (near, far) = state.clipPlanes(sceneBounds: sceneBB)
let proj = state.projectionMatrix(aspectRatio: aspect, near: near, far: far)
```

---

### `func fit(to:aspectRatio:padding:) -> CameraState`

```swift
public func fit(to bounds: BoundingBox, aspectRatio: Float, padding: Float = 1.1) -> CameraState
```

Returns a copy of the state whose pivot and distance (or `orthographicScale`) are adjusted so that the bounding sphere of `bounds` fills the view from the current viewing direction. `padding` is multiplicative: `1.0` = tight fit, `1.1` = 10 % breathing room (default).

---

### `func fit(to:aspectRatio:padding:) -> CameraState?`

```swift
public func fit(to bodies: [ViewportBody], aspectRatio: Float, padding: Float = 1.1) -> CameraState?
```

Convenience overload. Unions the bounding boxes of all visible bodies and calls the `BoundingBox` overload. Returns `nil` when no visible body has geometry.

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

Returns a state interpolated between `self` (t = 0) and `target` (t = 1). Uses SLERP for rotation and linear interpolation for all scalar/vector fields. `isOrthographic` switches at t = 0.5. Used internally by `CameraController` animations.

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

`CameraController` is a `@MainActor` `ObservableObject` that owns a `CameraState` and handles interactive orbit, pan, zoom, roll, focus, and animated transitions. It drives a 60 Hz timer for inertia decay and state-interpolation animations.

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

### `@Published var isAnimating: Bool` *(read-only)*

`true` while a `animateTo` or inertia animation is running.

---

### Configuration properties

| Property | Type | Default | Purpose |
|---|---|---|---|
| `rotationStyle` | `RotationStyle` | `.turntable` | Drag rotation model |
| `orbitSensitivity` | `Float` | `0.005` | Radians per point of drag |
| `panSensitivity` | `Float` | `0.002` | World units per point (scaled by distance) |
| `zoomSensitivity` | `Float` | `1.0` | Pinch zoom multiplier |
| `scrollZoomSensitivity` | `Float` | `0.1` | Scroll wheel exponent factor |
| `minPanSpeed` | `Float` | `0.001` | Floor on pan speed when very close to pivot |
| `minDistance` | `Float` | `0.1` | Minimum pivot distance |
| `maxDistance` | `Float` | `10000` | Maximum pivot distance |
| `minPhi` | `Float` | `0.01` | Min vertical angle (turntable, radians from vertical) |
| `maxPhi` | `Float` | `π − 0.01` | Max vertical angle (turntable) |
| `dampingFactor` | `Float` | `0.1` | Inertia decay per frame (0 = coast forever) |
| `enableInertia` | `Bool` | `true` | Whether inertia is applied after gestures end |

---

### `func orbit(deltaX:deltaY:)`

```swift
public func orbit(deltaX: Float, deltaY: Float)
```

Rotates the camera by the given drag delta in points, dispatching to the algorithm selected by `rotationStyle` (arcball, turntable, or first-person).

---

### `func pan(deltaX:deltaY:)`

```swift
public func pan(deltaX: Float, deltaY: Float)
```

Shifts the pivot in the camera's local XY plane. Speed scales with `distance * panSensitivity`, floored at `minPanSpeed`.

---

### `func zoom(factor:)`

```swift
public func zoom(factor: Float)
```

Multiplies distance by `1 / factor` (factor > 1 zooms in). Clamps to `[minDistance, maxDistance]`. Also scales `orthographicScale` in orthographic mode.

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

Zoom-at-cursor / pinch-at-fingers. Adjusts the pivot so the world point under `cursorNormalized` stays stationary during the zoom. Works in both perspective and orthographic modes. `nil` cursor = plain centre zoom.

---

### `func roll(deltaAngle:)`

```swift
public func roll(deltaAngle: Float)
```

Rolls the camera around its forward axis by `deltaAngle` radians. In turntable mode the roll is stored separately so it survives subsequent orbit moves; in arcball/first-person modes it is baked directly into the rotation quaternion.

---

### `func animateTo(_:duration:)` (CameraState)

```swift
public func animateTo(_ target: CameraState, duration: Float = 0.3)
```

Animates smoothly to `target` using SLERP for rotation and an ease-out (1 − (1 − t)³) curve over `duration` seconds. Passing `duration: 0` snaps immediately.

---

### `func animateTo(_:duration:)` (StandardView)

```swift
public func animateTo(_ view: StandardView, duration: Float = 0.3)
```

Convenience overload that preserves the current `pivot`, `distance`, `fieldOfView`, and `orthographicScale` while snapping to the standard view's orientation and projection type.

---

### `func cancelAnimation()`

```swift
public func cancelAnimation()
```

Stops any running animation immediately, leaving `cameraState` at its current interpolated position.

---

### `func focusOn(point:distance:animated:)`

```swift
public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true)
```

Moves the pivot to `point`. Optionally sets a new `distance` (clamped to `[minDistance, maxDistance]`). Animated by default (0.3 s).

---

### `func reset(animated:)`

```swift
public func reset(animated: Bool = true)
```

Resets to the default `CameraState()` (Z-up, distance 10, perspective 45°). Animated by default (0.5 s). Also clears any accumulated roll.

---

### `func adjustPivot(to:duration:)`

```swift
public func adjustPivot(to newPivot: SIMD3<Float>, duration: Float = 0.15)
```

Silently shifts the orbit pivot if the new position differs by more than 0.001 world units and no animation is already running. Used by `PivotStrategy` to auto-adjust the orbit center.

---

### `func setAngularVelocity(_:)`

```swift
public func setAngularVelocity(_ velocity: SIMD2<Float>)
```

Seeds inertia with an angular velocity (radians per second, X = horizontal, Y = vertical). No-op when `enableInertia` is `false`. Call at gesture end to enable coasting.

---

### `func setPanVelocity(_:)`

```swift
public func setPanVelocity(_ velocity: SIMD2<Float>)
```

Seeds pan inertia. Same semantics as `setAngularVelocity`.

---

## PivotStrategy

`PivotStrategy` is a `@MainActor` helper that chooses an appropriate orbit center each time the user begins an orbit gesture. When the camera is zoomed out it returns the scene center; when zoomed in close it raycasts through the view center and returns the hit point; in between it blends smoothly via a smoothstep curve.

`ViewportController` owns a `PivotStrategy` and drives it automatically. You only need to interact with it directly for custom viewport integrations.

---

### `init()`

```swift
public init()
```

---

### `func computePivot(cameraState:bodies:aspectRatio:config:) -> SIMD3<Float>?`

```swift
public func computePivot(
    cameraState: CameraState,
    bodies: [ViewportBody],
    aspectRatio: Float,
    config: DynamicPivotConfiguration
) -> SIMD3<Float>?
```

Returns the recommended pivot, or `nil` when `config.isEnabled` is `false` or no scene geometry exists. The caller (typically `ViewportController`) should feed the result to `CameraController.adjustPivot(to:duration:)`.

---

### `func invalidateCache()`

```swift
public func invalidateCache()
```

Forces the bounding-box cache to be rebuilt on the next `computePivot` call. Call when bodies are added or removed from the scene.

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

- **`isEnabled`** — set to `false` to use a fixed pivot at all times.
- **`animationDuration`** — how long the pivot glide animation takes (seconds).
- **`zoomThreshold`** — `cameraDistance / sceneDiagonalLength` ratio that separates "zoomed out" (scene center) from "zoomed in" (raycast hit). Default `0.5`.
- **`blendBand`** — fraction of `zoomThreshold` used as the width of the smoothstep blend zone between the two pivot strategies. Default `0.3`.

---

### `var isEnabled: Bool`

Disables dynamic pivot when `false`; `PivotStrategy.computePivot` returns `nil`.

---

### `var animationDuration: Float`

Duration of the pivot-glide animation in seconds.

---

### `var zoomThreshold: Float`

Zoom-ratio crossover point (camera distance / scene diagonal).

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

Unrestricted 3D rotation using Ken Shoemake's virtual-sphere algorithm. Drag on the sphere surface rotates around axes perpendicular to the drag direction; drag outside the sphere rolls around the view axis. Best for freeform 3D modelling.

#### `case turntable`

Z-axis–locked rotation ("pottery wheel"). Horizontal drag rotates around world Z; vertical drag tilts the camera up and down. Best for CAD, architecture, and any domain where "up is up".

#### `case firstPerson`

Camera-centric yaw/pitch. Horizontal drag yaws around world Z; vertical drag pitches around the camera right vector. Best for walk-through and VR-style navigation.

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
