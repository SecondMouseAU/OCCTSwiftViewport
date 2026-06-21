---
title: Gestures & Input
parent: Cookbook
nav_order: 11
---

# Gestures & Input

OCCTSwiftViewport ships with a platform-neutral input architecture built around three layers:

1. **`GestureConfiguration`** — declares *what* each gesture or modifier+drag means (orbit, pan, zoom, select, …)
2. **`ViewportInputEvent`** — the portable event type that carries deltas and modifier state, decoupled from AppKit/UIKit
3. **`ViewportController.dispatch(_:)`** — the single interpretation entry point that applies the configuration and drives the camera

Native platform gesture recognisers (iOS drag/pinch/rotate; macOS mouse/scroll) are already wired in by `MetalViewportView`. You only need this page if you want to change the *mapping*, intercept events for inspection, or feed *synthetic* input (tests, XR, Catalyst, scripting).

---

## Gesture Presets

`GestureConfiguration` is a `Sendable` value type. Assign a preset to `ViewportConfiguration.gestureConfiguration` before (or after) creating the controller.

### `.default` — Shapr3D style (the out-of-the-box preset)

| Input | Action |
|---|---|
| Single-finger drag / unmodified mouse drag | Orbit |
| Two-finger drag | Pan |
| Pinch / scroll wheel | Zoom |
| Shift+drag (macOS) | Pan |
| Option+drag (macOS) | Zoom |
| Command+drag (macOS) | Select |
| Double-tap / double-click | Focus on point |

### `.blender` — Blender style

Unmodified mouse drag selects; orbit is behind **Option**, pan behind **Shift**, zoom behind **Command**.

| Input | Action |
|---|---|
| Unmodified mouse drag | Select |
| Shift+drag | Pan |
| Option+drag | Orbit |
| Command+drag | Zoom |

Touch gestures (iOS/visionOS) are unchanged from `.default`.

### `.fusion360` — Fusion 360 style

| Input | Action |
|---|---|
| Unmodified mouse drag | Select |
| Shift+drag | Orbit |
| Option+drag | Pan |
| Command+drag | Zoom |

### `.visionOS` — spatial (indirect pinch) input

Identical iOS touch mapping with `dampingFactor` raised to `0.15` so inertia settles more predictably with indirect input. Tune further on real hardware.

---

## Applying a Preset

```swift
import OCCTSwiftViewport

// 1. Build a ViewportConfiguration with the desired gesture preset.
var config = ViewportConfiguration()
config.gestureConfiguration = .blender

// 2. Pass it to the controller.
let controller = ViewportController(configuration: config)
```

You can swap the preset at runtime — the controller re-reads `configuration.gestureConfiguration` on every event:

```swift
controller.configuration.gestureConfiguration = .fusion360
```

---

## Fine-Tuning Sensitivity and Orbit Direction

All sensitivity values are properties on `GestureConfiguration`. Start from a preset and mutate:

```swift
var gestures = GestureConfiguration.default
gestures.orbitSensitivity = 0.008         // radians per point (default 0.005)
gestures.panSensitivity = 0.005           // multiplier (default 0.005)
gestures.zoomSensitivity = 1.2            // pinch scale multiplier (default 1.0)
gestures.scrollZoomSensitivity = 0.4      // scroll-wheel zoom (default 0.25)
gestures.enableInertia = true             // momentum after release (default true)
gestures.dampingFactor = 0.1             // 0 = frictionless, 1 = instant stop (default 0.1)
gestures.invertOrbitHorizontal = true     // "grab model" feel vs "orbit camera" (default false)
gestures.invertOrbitVertical = false      // (default false)

controller.configuration.gestureConfiguration = gestures
```

---

## `GestureAction` Values

`GestureAction` is a `CaseIterable` `String`-backed enum. The full set:

| Case | Effect |
|---|---|
| `.orbit` | Rotate camera around pivot |
| `.pan` | Translate camera parallel to view plane |
| `.zoom` | Dolly in/out |
| `.select` | Initiates a pick (observational — picking runs on its own renderer path) |
| `.focusOnPoint` | Recentres the pivot under the cursor |
| `.resetView` | Resets to default camera pose |
| `.none` | No-op |

---

## `ViewportModifierKeys`

`ViewportModifierKeys` is a platform-neutral `OptionSet` used to encode which keyboard modifiers are active. The four flags:

```swift
ViewportModifierKeys.shift    // rawValue 1
ViewportModifierKeys.control  // rawValue 2
ViewportModifierKeys.option   // rawValue 4
ViewportModifierKeys.command  // rawValue 8
```

Bridge from platform types at the point where you translate native input:

```swift
// macOS — inside an NSResponder / NSEvent handler
let modifiers = ViewportModifierKeys(event.modifierFlags)  // NSEvent.ModifierFlags

// iOS / Catalyst — from a UIKeyModifierFlags (e.g. a hardware-keyboard gesture)
let modifiers = ViewportModifierKeys(command.modifierFlags)  // UIKeyModifierFlags
```

Resolve a drag action against the active modifiers:

```swift
let action = controller.configuration.gestureConfiguration.dragAction(for: modifiers)
// Priority: command → shift → option → unmodified
```

---

## The Portable Event Model: `ViewportInputEvent`

`ViewportInputEvent` is a `Sendable`, `Equatable` enum. Every native gesture recogniser converts to one of these before calling `dispatch(_:)`. The full case list:

| Case | Payload | Typical source |
|---|---|---|
| `.dragChanged(delta:modifiers:)` | point delta + modifiers | Mouse drag / single-finger |
| `.dragEnded(velocity:modifiers:)` | release velocity + modifiers | Drag release (inertia) |
| `.twoFingerPanChanged(translation:)` | cumulative translation | Two-finger pan |
| `.twoFingerPanEnded(velocity:)` | release velocity | Two-finger release |
| `.pinchChanged(scale:)` | incremental scale ratio (1.0 = no change) | Pinch gesture |
| `.pinchAtChanged(scale:centerNDC:aspectRatio:)` | scale + pinch centre in NDC | Pinch-to-zoom at cursor |
| `.pinchEnded` | — | Pinch release |
| `.rotateChanged(radians:)` | incremental angle | Two-finger rotation |
| `.rotateEnded` | — | Rotation release |
| `.scroll(delta:cursorNDC:aspectRatio:)` | scroll amount + cursor NDC | Scroll wheel |
| `.tap(ndc:count:)` | NDC position + tap count | Tap / click |

NDC coordinates are in the range −1…+1 on each axis. A double-tap (`count >= 2`) resets the view; single taps are observational via `dispatch` (picking runs on a separate renderer path).

---

## `ViewportController.dispatch(_:)`

`dispatch(_:)` is the single entry point for all input. The built-in gesture recognisers call it automatically. You call it directly for synthetic or external input:

```swift
// Synthesise an orbit drag (e.g. from a game controller thumbstick)
let delta = SIMD2<Float>(thumbstick.x * 3.0, thumbstick.y * 3.0)
controller.dispatch(.dragChanged(delta: delta, modifiers: []))
controller.dispatch(.dragEnded(velocity: .zero, modifiers: []))

// Synthesise a scroll-wheel zoom toward view centre (NDC 0,0)
controller.dispatch(.scroll(delta: -0.5, cursorNDC: .zero, aspectRatio: 1.0))

// Synthesise a pinch zoom toward a specific screen point
let pinchCentre = SIMD2<Float>(0.3, -0.1)  // NDC
controller.dispatch(.pinchAtChanged(scale: 1.05, centerNDC: pinchCentre, aspectRatio: aspectRatio))
controller.dispatch(.pinchEnded)
```

The dispatch implementation resolves the `GestureAction` (using `GestureConfiguration.dragAction(for:)` on macOS, `singleFingerDrag` on iOS), applies sign conventions, and calls the underlying camera methods. All interpretation lives in `dispatch`; the platform translation layer only produces deltas.

---

## Observing the Event Stream: `onInputEvent`

`ViewportController.onInputEvent` is an optional `((ViewportInputEvent) -> Void)` callback fired on every event *before* interpretation. It does not affect camera behaviour — use it for debugging, HUD inspectors, or logging:

```swift
controller.onInputEvent = { event in
    switch event {
    case let .dragChanged(delta, modifiers):
        let action = controller.configuration.gestureConfiguration.dragAction(for: modifiers)
        print("drag \(delta) → \(action)")
    case let .scroll(delta, cursor, _):
        print("scroll \(delta) at NDC \(cursor)")
    default:
        break
    }
}
```

Remove the observer by setting it to `nil`:

```swift
controller.onInputEvent = nil
```

---

## Building a Custom Mapping

For a mapping not covered by the presets, construct `GestureConfiguration` directly. Example — Maya-style (Alt+LMB orbit, Alt+MMB pan, Alt+RMB zoom; bare click selects):

```swift
var maya = GestureConfiguration(
    mouseDrag: .select,
    shiftDrag: .pan,
    optionDrag: .orbit,    // Alt+drag → orbit
    commandDrag: .none
)
// Alt is the `option` modifier; there is no middle-mouse button on a trackpad,
// so put pan behind Shift as a practical fallback.
maya.orbitSensitivity = 0.006
maya.enableInertia = false   // Maya-style: no momentum

controller.configuration.gestureConfiguration = maya
```

---

## Feeding a Non-Apple Input Source

For visionOS immersive space, external game-controller APIs, or test harnesses that have no gesture recognisers at all, translate your native input into `ViewportInputEvent` and call `dispatch(_:)` directly. No AppKit or UIKit types are required:

```swift
// Example: map a visionOS SpatialEventGesture update to a drag event
func handleSpatialUpdate(translation: SIMD3<Float>) {
    let delta = SIMD2<Float>(translation.x, translation.y)
    controller.dispatch(.dragChanged(delta: delta * 50, modifiers: []))
}

func handleSpatialEnd(velocity: SIMD3<Float>) {
    let v = SIMD2<Float>(velocity.x, velocity.y)
    controller.dispatch(.dragEnded(velocity: v, modifiers: []))
}
```

Because `ViewportInputEvent` is `Sendable` and `Equatable`, events can be constructed, stored, replayed, or diffed in tests without any UI framework.
