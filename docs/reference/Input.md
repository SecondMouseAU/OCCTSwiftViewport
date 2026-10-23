---
title: Input
parent: API Reference
---

# Input

These types form the platform-neutral input pipeline for OCCTSwiftViewport. Native gesture recognisers (UIKit on iOS, AppKit on macOS) or spatial-input handlers (visionOS) translate their events into `ViewportInputEvent` values and call `ViewportController.dispatch(_:)`. `ViewportModifierKeys` bridges platform modifier-flag types into a portable `OptionSet`. `GestureConfiguration` controls both sensitivity and the mapping from modifier states to camera actions; `GestureAction` is the set of named actions those mappings can produce.

## Topics

- [ViewportInputEvent](#viewportinputevent) · [ViewportModifierKeys](#viewportmodifierkeys) · [GestureConfiguration](#gestureconfiguration) · [DragRotationConvention](#dragrotationconvention) · [View reset](#view-reset) · [GestureAction](#gestureaction)

---

## ViewportInputEvent

```swift
public enum ViewportInputEvent: Sendable, Equatable
```

A platform-neutral viewport input event. Deltas and velocities are raw values in points / points-per-second; interpretation (which `GestureAction` applies, sign conventions, zoom curve) is applied centrally by `ViewportController.dispatch(_:)`, not by the platform translation layer.

This is the seam that lets non-AppKit/UIKit sources (visionOS, Catalyst, scripting, tests) drive the camera through one entry point.

---

### `.dragChanged(delta:modifiers:)`

```swift
case dragChanged(delta: SIMD2<Float>, modifiers: ViewportModifierKeys)
```

Primary pointer drag changed. On macOS this is a mouse drag; on iOS a single-finger drag. `modifiers` reflects the keyboard state at the time of the event and is empty on iOS. `ViewportController.dispatch(_:)` resolves the applicable `GestureAction` via `GestureConfiguration.dragAction(for:)`.

```swift
controller.dispatch(.dragChanged(delta: SIMD2(4, -2), modifiers: [.shift]))
```

The first `.dragChanged` after a `.dragEnded` begins a new drag: it stops any orbit or pan momentum still coasting, rather than adding the new drag to it, cancels any animation to a target view (which would otherwise overwrite the drag until it finished), and an orbit fixes its direction at that point (see `CameraController.beginOrbitDrag(at:signs:)`). The first `.twoFingerPanChanged` of a two-finger drag does the same.

#### `setDragOrigin(offsetFromCenter:)`

```swift
public func setDragOrigin(offsetFromCenter: SIMD2<Float>)   // on ViewportController
```

Optional: where the next drag starts, in points from the centre of the view (y down). The `.arcball` rotation style uses it to place the pointer on its virtual sphere, so that a drag that starts near the edge of the view and moves around the centre rolls the view. `MetalViewportView` calls it on mouse-down (macOS) and at the start of a one-finger drag (iOS / visionOS). Call it before the first `.dragChanged` when you dispatch drags from another source; without it the drag is taken to start at the centre.

```swift
controller.setDragOrigin(offsetFromCenter: SIMD2(Float(start.x - size.width / 2),
                                                 Float(start.y - size.height / 2)))
controller.dispatch(.dragChanged(delta: delta, modifiers: []))
```

---

### `.dragEnded(velocity:modifiers:)`

```swift
case dragEnded(velocity: SIMD2<Float>, modifiers: ViewportModifierKeys)
```

Primary pointer drag ended. `velocity` is the release velocity in points per second and is used to seed inertia when `GestureConfiguration.enableInertia` is `true`. The momentum starts at `GestureConfiguration.momentumScale` of it (see [Inertia](#inertia)).

---

### `.twoFingerPanChanged(translation:)`

```swift
case twoFingerPanChanged(translation: SIMD2<Float>)
```

Two-finger drag (iOS / visionOS) changed. `translation` is the incremental translation in points since the previous event (the recognizer's translation is reset after each event). The router applies it as `GestureConfiguration.twoFingerDrag`: `.pan` (default), `.orbit` or `.zoom`; any other action ignores the gesture. A pan is 1:1 with the fingers (see `CameraController.pan(deltaX:deltaY:)`).

#### `setTwoFingerDragOrigin(offsetFromCenter:)`

```swift
public func setTwoFingerDragOrigin(offsetFromCenter: SIMD2<Float>)   // on ViewportController
```

Optional: where the next two-finger drag starts, as the centroid of the two touches in points from the centre of the view (y down). It does for a two-finger drag what `setDragOrigin(offsetFromCenter:)` does for the primary drag: with `twoFingerDrag = .orbit` and the `.arcball` style, a drag that starts near the edge of the view and moves around the centre rolls the view. `MetalViewportView` calls it when the two-finger pan begins, with the centroid where the fingers went down. Without it the drag starts at the centre and can only tumble, which is how every two-finger arcball drag behaved before issue #200. It is a separate call rather than a field of the event so that `ViewportInputEvent` keeps its cases, and switches over it stay exhaustive.

---

### `.twoFingerPanEnded(velocity:)`

```swift
case twoFingerPanEnded(velocity: SIMD2<Float>)
```

Two-finger drag ended. `velocity` seeds pan or orbit inertia, matching `twoFingerDrag`.

---

### `.pinchChanged(scale:)`

```swift
case pinchChanged(scale: Float)
```

Pinch changed. `scale` is an incremental scale ratio relative to the previous event: `1.0` means no change. Zoom is applied toward the view centre, with the scale raised to `GestureConfiguration.zoomSensitivity`. The router zooms only while the platform's pinch mapping (`pinchGesture`, or `trackpadPinch` on macOS) is `.zoom`; any other action ignores the pinch.

---

### `.pinchAtChanged(scale:centerNDC:aspectRatio:)`

```swift
case pinchAtChanged(scale: Float, centerNDC: SIMD2<Float>, aspectRatio: Float)
```

Pinch changed with a known gesture centre in normalized-device coordinates (NDC, −1…+1 on each axis). Zoom is applied toward `centerNDC` rather than the view centre, matching the behaviour of mainstream CAD and map applications. `aspectRatio` is `viewWidth / viewHeight` and is required to convert the NDC position into world space correctly. `zoomSensitivity` and the `pinchGesture` / `trackpadPinch` mapping apply as for `.pinchChanged`.

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

Scroll-wheel input (macOS). `delta` is a single-axis scroll amount; positive values zoom in. Zoom is applied toward `cursorNDC` so that the point under the cursor stays fixed, matching the behaviour of `.pinchAtChanged`. `aspectRatio` serves the same purpose as in that case. The router zooms only while `GestureConfiguration.scrollWheel` is `.zoom`; any other action ignores scrolling.

---

### `.tap(ndc:count:)`

```swift
case tap(ndc: SIMD2<Float>, count: Int)
```

A tap or click at `ndc` (normalized-device coordinates). By default a double-tap (`count >= 2`) does nothing. When the app opts in, the router checks two things in order:

1. If `GestureConfiguration.resetViewTriggers` contains `.doubleTap`, or on macOS a `.doubleClick(modifiers:)` whose modifiers match those held, it calls `reset(animated: true)`, which animates back to `ViewportConfiguration.initialCameraState`.
2. Otherwise, for an unmodified double-tap, it runs `GestureConfiguration.doubleTap` (`doubleClick` on macOS). `.focusOnPoint` raycasts the scene under `ndc` and animates the orbit pivot onto the nearest surface hit, skipping geometry removed by `clipPlanes`; a miss does nothing. `.resetView` resets, as a shorthand for the matching trigger. Anything else, including the default `.none`, ignores the double-tap.

`MetalViewportView` dispatches the real tap location for double-taps on iOS / visionOS. On macOS it forwards the click count and the modifier keys held, so a double-click arrives as `count: 2`. A `.tap` event you dispatch yourself carries no modifiers, so it only matches `.doubleClick(modifiers: [])`. Single taps are delivered to any `onInputEvent` observer but do not trigger a built-in camera action (object picking runs through a separate renderer-bound path).

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

### `init(_ flags: NSEvent.ModifierFlags)`: macOS

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

### `init(_ flags: UIKeyModifierFlags)`: iOS

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

Configuration for gesture handling in the viewport. Controls sensitivity, drag direction (`dragRotation` plus the per-axis invert flags), inertia behaviour, and the mapping from input gestures / modifier keys to `GestureAction` values. Assigned to `ViewportConfiguration.gestureConfiguration`.

---

### Presets

#### `.default`

```swift
public static let `default` = GestureConfiguration()
```

Shapr3D-style defaults: single-finger / bare-mouse drag orbits; shift-drag pans; option-drag zooms; command-drag selects; two-finger pan pans; pinch and scroll zoom. Nothing resets the view and double-tap/click does nothing until the app opts in (see [View reset](#view-reset)).

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
| `panSensitivity` | `Float` | `1` | Pan speed as a multiple of the pointer's. `1` is 1:1: the point under the finger stays under it (at the pivot's depth in perspective). |
| `zoomSensitivity` | `Float` | `1.0` | Exponent applied to pinch and drag-zoom magnification: `2` zooms twice as fast (in log terms), `0.5` half as fast. |
| `scrollZoomSensitivity` | `Float` | `0.25` | Scroll-wheel zoom multiplier. |
| `minPanSpeed` | `Float` | `0` | Floor on pan speed, in world units per point. `0` keeps pan 1:1 at any distance. |

**Behaviour change (issue #200): pan is 1:1 by default.** `panSensitivity` used to be world units per point scaled by the camera distance, default `0.005`, which panned about five times as far as the finger in an 800 pt tall view and ignored the field of view and the orthographic scale. It is now a multiplier of the 1:1 speed with a default of `1`, and `minPanSpeed` defaults to `0` (it was `0.001`, which broke 1:1 inside a distance of about 1). A configuration that set `panSensitivity: 0.005` explicitly pans 200 times slower than 1:1; change it to `1`, or to the multiplier you want. 1:1 needs the view's height: `MetalViewportView` passes it through `ViewportController.updateViewportSize(_:)`, and an app that drives the controller from its own view should call that too.

---

### Drag direction: `dragRotation`

```swift
public var dragRotation: DragRotationConvention  // default .rotateObject
public var invertOrbitHorizontal: Bool           // default false
public var invertOrbitVertical: Bool             // default false
public var orbitDragSigns: SIMD2<Float> { get }  // (1, 1) by default
public var orbitRollSign: Float { get }          // 1 for .rotateObject, -1 for .orbitCamera
```

`dragRotation` sets which way every drag that resolves to `.orbit` turns the view: the iOS / visionOS one-finger drag (and the two-finger drag when bound to `.orbit`), the macOS mouse drag, the navigation cube, and the release momentum of each.

| `DragRotationConvention` | Drag right | Drag up |
|---|---|---|
| `.rotateObject` (default) | the model's near side moves right, with the finger | the near side moves up, with the finger |
| `.orbitCamera` | the camera moves right around the pivot, so the model turns left | the camera moves up, so the near side moves down |

`.rotateObject` feels as if the finger is turning the object directly. It holds for every `RotationStyle`: turntable (the default), arcball, and first-person.

- **Turntable:** past the pole the camera is upside down, so each drag decides at its start which way a horizontal drag turns, and the model keeps following the finger.
- **Arcball:** the convention also sets which way a drag outside the sphere rolls the view: with `.rotateObject` the model rolls with the pointer, with `.orbitCamera` against it (`orbitRollSign`). The invert flags leave the roll alone.
- **First-person** turns the camera in place, so there is no object to turn: `.rotateObject` drags the scene with the finger, as in a touch panorama viewer (drag right and the view turns left), and `.orbitCamera` is desktop mouse-look (drag right, look right).

Every preset uses `.rotateObject`. Blender's middle-mouse orbit and Fusion 360's orbit both carry the model's near side with the pointer on both axes, as do Shapr3D, Onshape and SolidWorks.

`invertOrbitHorizontal` and `invertOrbitVertical` stay as per-axis flips applied on top of the convention. `orbitDragSigns` is the result: `(1, 1)` for `.rotateObject`, `(-1, -1)` for `.orbitCamera`, with each set flag negating its axis. `CameraController.orbit(deltaX:deltaY:)` itself turns the model with the drag, so `ViewportController` multiplies the drag delta and the release velocity by these signs before passing them on.

> **Changed default.** Before `dragRotation` existed, the horizontal axis moved the camera (the model turned against the finger) while the vertical axis turned the model with it. Both axes now turn the model with the finger. An app that set `invertOrbitHorizontal = true` to get the object-follows-finger feel should drop it, since the flag now reverses the new default; set `dragRotation = .orbitCamera` to get camera-orbit on both axes.

---

### Inertia

```swift
public var enableInertia: Bool    // default true
public var dampingFactor: Float   // default 0.1
public var momentumScale: Float   // default 0.06
```

`enableInertia` enables post-gesture momentum. `dampingFactor` controls how quickly momentum decays: `0` means no damping (perpetual spin); `1` means instant stop. It is the fraction of velocity lost per 1/60 s, applied in proportion to elapsed time, so momentum coasts the same at 60 Hz, at 120 Hz, or when timer ticks coalesce. The `.visionOS` preset uses `0.15`.

`momentumScale` is the fraction of the release speed that orbit and pan momentum start with. At `1` the view carries on at the speed the pointer was moving when it let go. The default `0.06` keeps the short, gentle coast the viewport has always had. The release velocity (points per second) used to be multiplied by 0.001 and treated as points per 1/60 s, where the conversion needed 1/60: momentum started at 0.06 of the release speed, by accident. The conversion is now exact and the scale is explicit. With the default damping a release coasts about `0.16 s × momentumScale` times its speed: a 1500 pt/s flick coasts about 14 pt at the default and about 240 pt at `1`. `0` turns momentum off, as `enableInertia = false` does.

A new drag stops any momentum still coasting.

---

### iOS gesture mapping

```swift
public var singleFingerDrag: GestureAction  // default .orbit
public var twoFingerDrag:    GestureAction  // default .pan
public var pinchGesture:     GestureAction  // default .zoom
public var doubleTap:        GestureAction  // default .none
```

These also apply on visionOS. Each field supports a subset of `GestureAction`; any other value makes the router ignore that gesture, so `.none` disables it:

| Field | Supported actions |
|---|---|
| `singleFingerDrag`, `twoFingerDrag` | `.orbit`, `.pan`, `.zoom` |
| `pinchGesture` | `.zoom` |
| `doubleTap` | `.focusOnPoint`, `.resetView` |

---

### macOS gesture mapping

```swift
public var mouseDrag:     GestureAction  // default .orbit
public var shiftDrag:     GestureAction  // default .pan
public var optionDrag:    GestureAction  // default .zoom
public var commandDrag:   GestureAction  // default .select
public var scrollWheel:   GestureAction  // default .zoom
public var trackpadPinch: GestureAction  // default .zoom
public var doubleClick:   GestureAction  // default .none
```

| Field | Supported actions |
|---|---|
| `mouseDrag`, `shiftDrag`, `optionDrag`, `commandDrag` | `.orbit`, `.pan`, `.zoom` (`.select` leaves the drag to the app) |
| `scrollWheel`, `trackpadPinch` | `.zoom` |
| `doubleClick` (unmodified) | `.focusOnPoint`, `.resetView` |

`doubleTap` and `doubleClick` defaulted to `.focusOnPoint` in earlier releases, but nothing read them, and a double-tap on iOS always reset the view. Both now default to `.none`, and a double-tap no longer resets unless the app opts in. Bind view reset with `resetViewTriggers` (below); `.resetView` on these fields remains as a shorthand.

---

### View reset

```swift
public var resetViewTriggers: [ViewResetTrigger]  // default []
```

The inputs that reset the camera to `ViewportConfiguration.initialCameraState`. The list is empty by default, so nothing resets the view unless the app opts in. No preset ships a binding. List several triggers to cover more than one platform or input style.

```swift
var gestures = GestureConfiguration.default
gestures.resetViewTriggers = [
    .keyCombination(key: "h", modifiers: [.command, .shift]),  // ⇧⌘H on macOS
    .doubleTap,                                                // iPhone / iPad
]
```

The reset action itself is the public `ViewportController.reset(animated:)`. An app can call it from its own menu item, toolbar button or `.keyboardShortcut` instead of, or as well as, configuring a trigger.

#### `ViewResetTrigger`

```swift
public enum ViewResetTrigger: Sendable, Hashable {
    case keyCombination(key: Character, modifiers: ViewportModifierKeys)
    case doubleClick(modifiers: ViewportModifierKeys)
    case doubleTap
}
```

| Case | Fires on |
|---|---|
| `.keyCombination(key:modifiers:)` | `key` pressed with exactly `modifiers` held. `key` is the unshifted character and compares case-insensitively, so Shift+H is `.keyCombination(key: "h", modifiers: [.shift])`. On macOS, `MetalViewportView` handles these itself. Key equivalents (combinations with ⌘) work while the viewport's window is key. Other keys work while the viewport has focus, and when such a trigger is configured, clicking the viewport makes it first responder. The view claims keys only when a key trigger is configured. On other platforms, forward keys to `ViewportController.handleKeyCombination(_:modifiers:)`. |
| `.doubleClick(modifiers:)` | A macOS double-click with exactly `modifiers` held. Use `[]` for a plain double-click. |
| `.doubleTap` | An iOS / visionOS double-tap. |

#### `handleKeyCombination(_:modifiers:)`

```swift
@discardableResult
public func handleKeyCombination(_ key: Character, modifiers: ViewportModifierKeys) -> Bool
```

A method on `ViewportController`. It resets the camera if a `.keyCombination` trigger matches, and returns `true` if it did, so the caller can stop passing the key on.

```swift
// iPad with a hardware keyboard
.onKeyPress { press in
    let key = press.characters.first ?? " "
    var modifiers: ViewportModifierKeys = []
    if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if press.modifiers.contains(.control) { modifiers.insert(.control) }
    if press.modifiers.contains(.option) { modifiers.insert(.option) }
    if press.modifiers.contains(.command) { modifiers.insert(.command) }
    return controller.handleKeyCombination(key, modifiers: modifiers) ? .handled : .ignored
}
```

The helpers `GestureConfiguration.resetsView(onKey:modifiers:)`, `resetsView(onDoubleClickWith:)` and `resetsViewOnDoubleTap` expose the same matching for custom input layers.

---

### `init(...)`

```swift
public init(
    orbitSensitivity:     Float         = 0.005,
    panSensitivity:       Float         = 1,
    zoomSensitivity:      Float         = 1.0,
    scrollZoomSensitivity: Float        = 0.25,
    minPanSpeed:          Float         = 0,
    dragRotation:         DragRotationConvention = .rotateObject,
    invertOrbitHorizontal: Bool         = false,
    invertOrbitVertical:   Bool         = false,
    enableInertia:        Bool          = true,
    dampingFactor:        Float         = 0.1,
    momentumScale:        Float         = 0.06,
    singleFingerDrag:     GestureAction = .orbit,
    twoFingerDrag:        GestureAction = .pan,
    pinchGesture:         GestureAction = .zoom,
    doubleTap:            GestureAction = .none,
    mouseDrag:            GestureAction = .orbit,
    shiftDrag:            GestureAction = .pan,
    optionDrag:           GestureAction = .zoom,
    commandDrag:          GestureAction = .select,
    scrollWheel:          GestureAction = .zoom,
    trackpadPinch:        GestureAction = .zoom,
    doubleClick:          GestureAction = .none,
    resetViewTriggers:    [ViewResetTrigger] = []
)
```

Creates a gesture configuration. All parameters are optional; every field has a sensible default so you can pass only the fields you want to change.

```swift
// Camera-orbit drag on both axes instead of the default rotate-object
var config = ViewportConfiguration()
config.gestureConfiguration = GestureConfiguration(dragRotation: .orbitCamera)
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

## DragRotationConvention

```swift
public enum DragRotationConvention: String, CaseIterable, Sendable {
    case rotateObject   // default
    case orbitCamera
}
```

How an orbiting drag maps onto the view; set it with `GestureConfiguration.dragRotation`. The two cases differ only in sign.

- **`rotateObject`** turns the model under the finger: a drag right carries its near side right, a drag up carries it up.
- **`orbitCamera`** moves the camera around the pivot, so the model appears to turn against the drag on both axes.

Both hold in every `RotationStyle`. For the arcball the convention also sets the roll direction, and in first-person `.rotateObject` drags the scene while `.orbitCamera` is mouse-look. See [Drag direction](#drag-direction-dragrotation) for the presets, these per-style details and the invert flags.

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
| `.resetView` | Reset the camera to `initialCameraState` (honoured by `doubleTap` / `doubleClick`; prefer `resetViewTriggers`). |
| `.none` | No action; the gesture is ignored. |

`GestureAction` conforms to `CaseIterable`, so you can enumerate all cases to populate a preference UI.

```swift
// Build a picker for the "mouse drag" action
Picker("Mouse drag", selection: $config.mouseDrag) {
    ForEach(GestureAction.allCases, id: \.self) { action in
        Text(action.rawValue).tag(action)
    }
}
```
