---
title: Input
parent: API Reference
---

# Input

These types form the platform-neutral input pipeline for OCCTSwiftViewport. Native gesture recognisers (UIKit on iOS, AppKit on macOS) or spatial-input handlers (visionOS) translate their events into `ViewportInputEvent` values and call `ViewportController.dispatch(_:)`. `ViewportModifierKeys` bridges platform modifier-flag types into a portable `OptionSet`. `GestureConfiguration` controls both sensitivity and the mapping from modifier states to camera actions; `GestureAction` is the set of named actions those mappings can produce.

## Topics

- [ViewportInputEvent](#viewportinputevent) · [ViewportModifierKeys](#viewportmodifierkeys) · [GestureConfiguration](#gestureconfiguration) · [GestureAction](#gestureaction)

---

## ViewportInputEvent

```swift
public enum ViewportInputEvent: Sendable, Equatable
```

A platform-neutral viewport input event. Deltas and velocities are raw values in points / points-per-second; interpretation (which `GestureAction` applies, sign conventions, zoom curve) is applied centrally by `ViewportController.dispatch(_:)`, not by the platform translation layer.

This is the seam that lets non-AppKit/UIKit sources — visionOS, Catalyst, scripting, tests — drive the camera through one entry point.

---

### `.dragChanged(delta:modifiers:)`

```swift
case dragChanged(delta: SIMD2<Float>, modifiers: ViewportModifierKeys)
```

Primary pointer drag changed. On macOS this is a mouse drag; on iOS a single-finger drag. `modifiers` reflects the keyboard state at the time of the event and is empty on iOS. `ViewportController.dispatch(_:)` resolves the applicable `GestureAction` via `GestureConfiguration.dragAction(for:)`.

```swift
controller.dispatch(.dragChanged(delta: SIMD2(4, -2), modifiers: [.shift]))
```

---

### `.dragEnded(velocity:modifiers:)`

```swift
case dragEnded(velocity: SIMD2<Float>, modifiers: ViewportModifierKeys)
```

Primary pointer drag ended. `velocity` is the release velocity in points per second and is used to seed inertia when `GestureConfiguration.enableInertia` is `true`.

---

### `.twoFingerPanChanged(translation:)`

```swift
case twoFingerPanChanged(translation: SIMD2<Float>)
```

Two-finger pan (iOS) changed. `translation` is the accumulated translation of the gesture in points since it began, matching the coordinate convention of `UIPanGestureRecognizer.translation(in:)`.

---

### `.twoFingerPanEnded(velocity:)`

```swift
case twoFingerPanEnded(velocity: SIMD2<Float>)
```

Two-finger pan ended. `velocity` seeds pan inertia.

---

### `.pinchChanged(scale:)`

```swift
case pinchChanged(scale: Float)
```

Pinch changed. `scale` is an incremental scale ratio relative to the previous event — `1.0` means no change. Zoom is applied toward the view centre.

---

### `.pinchAtChanged(scale:centerNDC:aspectRatio:)`

```swift
case pinchAtChanged(scale: Float, centerNDC: SIMD2<Float>, aspectRatio: Float)
```

Pinch changed with a known gesture centre in normalized-device coordinates (NDC, −1…+1 on each axis). Zoom is applied toward `centerNDC` rather than the view centre, matching the behaviour of mainstream CAD and map applications. `aspectRatio` is `viewWidth / viewHeight` and is required to convert the NDC position into world space correctly.

```swift
// Zoom toward the mid-point between two fingers
let center = SIMD2<Float>(0.1, -0.2) // NDC
controller.dispatch(.pinchAtChanged(scale: 1.05, centerNDC: center, aspectRatio: aspectRatio))
```

---

### `.pinchEnded`

```swift
case pinchEnded
```

Pinch gesture ended. No payload; the router uses this for gesture-state cleanup.

---

### `.rotateChanged(radians:)`

```swift
case rotateChanged(radians: Float)
```

Two-finger rotation changed. `radians` is the incremental angle since the last event (positive = counter-clockwise on screen).

---

### `.rotateEnded`

```swift
case rotateEnded
```

Two-finger rotation gesture ended.

---

### `.scroll(delta:cursorNDC:aspectRatio:)`

```swift
case scroll(delta: Float, cursorNDC: SIMD2<Float>, aspectRatio: Float)
```

Scroll-wheel input (macOS). `delta` is a single-axis scroll amount; positive values zoom in. Zoom is applied toward `cursorNDC` so that the point under the cursor stays fixed, matching the behaviour of `.pinchAtChanged`. `aspectRatio` serves the same purpose as in that case.

---

### `.tap(ndc:count:)`

```swift
case tap(ndc: SIMD2<Float>, count: Int)
```

A tap or click at `ndc` (normalized-device coordinates). When `count >= 2` the router calls `reset(animated: true)` to return the camera to its default view. Single taps are delivered to any `onInputEvent` observer but do not trigger a built-in camera action (object picking runs through a separate renderer-bound path).

---

## ViewportModifierKeys

```swift
public struct ViewportModifierKeys: OptionSet, Sendable, Hashable
```

Platform-neutral keyboard-modifier state used to interpret viewport drag input. Analogous to OCCT's `Aspect_VKeyFlags`. Bridge from a platform type with the `init(_:)` overloads, then resolve an action with `GestureConfiguration.dragAction(for:)`.

---

### `rawValue`

```swift
public let rawValue: Int
```

---

### Static members

```swift
public static let shift:   ViewportModifierKeys  // Shift key
public static let control: ViewportModifierKeys  // Control key
public static let option:  ViewportModifierKeys  // Option / Alt key
public static let command: ViewportModifierKeys  // Command / Meta key
```

---

### `init(rawValue:)`

```swift
public init(rawValue: Int)
```

Memberwise initialiser required by `OptionSet`. Prefer the platform bridge overloads or the named static members.

---

### `init(_ flags: NSEvent.ModifierFlags)` — macOS

```swift
// Available on macOS only (canImport(AppKit))
public init(_ flags: NSEvent.ModifierFlags)
```

Bridges AppKit modifier flags into the portable representation. Maps `.shift`, `.control`, `.option`, and `.command`.

```swift
// In an NSViewController subclass
override func mouseDragged(with event: NSEvent) {
    let mods = ViewportModifierKeys(event.modifierFlags)
    controller.dispatch(.dragChanged(delta: SIMD2(Float(event.deltaX), Float(event.deltaY)),
                                     modifiers: mods))
}
```

---

### `init(_ flags: UIKeyModifierFlags)` — iOS

```swift
// Available on iOS only (canImport(UIKit))
public init(_ flags: UIKeyModifierFlags)
```

Bridges UIKit key-modifier flags into the portable representation. Maps `.shift` → `.shift`, `.control` → `.control`, `.alternate` → `.option`, `.command` → `.command`.

---

## GestureConfiguration

```swift
public struct GestureConfiguration: Sendable
```

Configuration for gesture handling in the viewport. Controls sensitivity, orbit-inversion flags, inertia behaviour, and the mapping from input gestures / modifier keys to `GestureAction` values. Assigned to `ViewportConfiguration.gestureConfiguration`.

---

### Presets

#### `.default`

```swift
public static let `default` = GestureConfiguration()
```

Shapr3D-style defaults: single-finger / bare-mouse drag orbits; shift-drag pans; option-drag zooms; command-drag selects; two-finger pan pans; pinch zooms; double-tap/click resets.

#### `.blender`

```swift
public static let blender = GestureConfiguration(
    mouseDrag: .select,
    shiftDrag: .pan,
    optionDrag: .orbit,
    commandDrag: .zoom
)
```

Blender-style mapping: bare mouse drag selects; option-drag orbits; shift-drag pans; command-drag zooms. All other fields use `.default` values.

#### `.fusion360`

```swift
public static let fusion360 = GestureConfiguration(
    mouseDrag: .select,
    shiftDrag: .orbit,
    optionDrag: .pan,
    commandDrag: .zoom
)
```

Fusion 360-style mapping: bare mouse drag selects; shift-drag orbits; option-drag pans; command-drag zooms.

#### `.visionOS`

```swift
public static let visionOS = GestureConfiguration(
    dampingFactor: 0.15
)
```

Starting point for visionOS spatial (indirect pinch + look) input in a window or volume. Keeps the touch-style mapping (single pinch-drag orbits; two-handed pinch/twist for zoom/roll) and raises inertia damping slightly so momentum settles more predictably with indirect input. Tune sensitivities on Vision Pro hardware.

---

### Sensitivity fields

| Property | Type | Default | Description |
|---|---|---|---|
| `orbitSensitivity` | `Float` | `0.005` | Orbit turn rate in radians per drag point. |
| `panSensitivity` | `Float` | `0.005` | Pan speed multiplier. |
| `zoomSensitivity` | `Float` | `1.0` | Pinch/drag-zoom multiplier. |
| `scrollZoomSensitivity` | `Float` | `0.25` | Scroll-wheel zoom multiplier. |
| `minPanSpeed` | `Float` | `0.001` | Minimum pan speed floor; prevents stalling when zoomed very close. |

---

### Orbit-inversion flags

```swift
public var invertOrbitHorizontal: Bool  // default false
public var invertOrbitVertical: Bool    // default false
```

When `false` (default) a left-drag rotates the scene counter-clockwise — the camera orbits right around the model. Set `invertOrbitHorizontal = true` for "grab the model and drag it" (object follows the pointer). The same logic applies vertically for `invertOrbitVertical`.

---

### Inertia

```swift
public var enableInertia: Bool    // default true
public var dampingFactor: Float   // default 0.1
```

`enableInertia` enables post-gesture momentum. `dampingFactor` controls how quickly momentum decays: `0` means no damping (perpetual spin); `1` means instant stop. The `.visionOS` preset uses `0.15`.

---

### iOS gesture mapping

```swift
public var singleFingerDrag: GestureAction  // default .orbit
public var twoFingerDrag:    GestureAction  // default .pan
public var pinchGesture:     GestureAction  // default .zoom
public var doubleTap:        GestureAction  // default .focusOnPoint
```

---

### macOS gesture mapping

```swift
public var mouseDrag:     GestureAction  // default .orbit
public var shiftDrag:     GestureAction  // default .pan
public var optionDrag:    GestureAction  // default .zoom
public var commandDrag:   GestureAction  // default .select
public var scrollWheel:   GestureAction  // default .zoom
public var trackpadPinch: GestureAction  // default .zoom
public var doubleClick:   GestureAction  // default .focusOnPoint
```

---

### `init(...)`

```swift
public init(
    orbitSensitivity:     Float         = 0.005,
    panSensitivity:       Float         = 0.005,
    zoomSensitivity:      Float         = 1.0,
    scrollZoomSensitivity: Float        = 0.25,
    minPanSpeed:          Float         = 0.001,
    invertOrbitHorizontal: Bool         = false,
    invertOrbitVertical:   Bool         = false,
    enableInertia:        Bool          = true,
    dampingFactor:        Float         = 0.1,
    singleFingerDrag:     GestureAction = .orbit,
    twoFingerDrag:        GestureAction = .pan,
    pinchGesture:         GestureAction = .zoom,
    doubleTap:            GestureAction = .focusOnPoint,
    mouseDrag:            GestureAction = .orbit,
    shiftDrag:            GestureAction = .pan,
    optionDrag:           GestureAction = .zoom,
    commandDrag:          GestureAction = .select,
    scrollWheel:          GestureAction = .zoom,
    trackpadPinch:        GestureAction = .zoom,
    doubleClick:          GestureAction = .focusOnPoint
)
```

Creates a gesture configuration. All parameters are optional; every field has a sensible default so you can pass only the fields you want to change.

```swift
// Orbit-invert for users who prefer "grab-and-drag" feel
var config = ViewportConfiguration()
config.gestureConfiguration = GestureConfiguration(invertOrbitHorizontal: true)
```

---

### `dragAction(for:)`

```swift
public func dragAction(for modifiers: ViewportModifierKeys) -> GestureAction
```

Resolves the `GestureAction` for a pointer drag given the active modifier keys. Priority (highest to lowest): `.command` → `.shift` → `.option` → unmodified. This is the portable interpretation seam: platform code bridges its native modifier flags into `ViewportModifierKeys` and calls this method; `ViewportInputRouter` calls it internally from `dispatch(_:)`.

```swift
let action = config.gestureConfiguration.dragAction(for: ViewportModifierKeys([.shift]))
// action == .pan  (with .default preset)
```

---

## GestureAction

```swift
public enum GestureAction: String, CaseIterable, Sendable
```

The set of named actions that a gesture or modifier-key combination can trigger.

| Case | Description |
|---|---|
| `.orbit` | Orbit (rotate) the camera around the pivot point. |
| `.pan` | Pan the camera parallel to the view plane. |
| `.zoom` | Zoom in or out. |
| `.select` | Select objects under the pointer (handled outside the camera router). |
| `.focusOnPoint` | Focus the camera on the point under the cursor. |
| `.resetView` | Reset the camera to its default view. |
| `.none` | No action — the gesture is ignored. |

`GestureAction` conforms to `CaseIterable`, so you can enumerate all cases to populate a preference UI.

```swift
// Build a picker for the "mouse drag" action
Picker("Mouse drag", selection: $config.mouseDrag) {
    ForEach(GestureAction.allCases, id: \.self) { action in
        Text(action.rawValue).tag(action)
    }
}
```
