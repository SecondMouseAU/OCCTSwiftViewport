---
title: SwiftUI Views
parent: API Reference
---

# SwiftUI Views

Two types form the public entry point to the viewport: `MetalViewportView` is the SwiftUI `View` that renders the 3D scene and handles gestures; `ViewportController` is the `@MainActor ObservableObject` hub that everything (camera, display mode, picking, measurements, clip planes, post-processing) routes through.

## Topics

- [MetalViewportView](#metalviewportview) · [ViewportController](#viewportcontroller)
  - [Initialisation](#initialisation)
  - [Scene & Display](#scene--display)
  - [Camera Control](#camera-control)
  - [Toggles & Display Mode](#toggles--display-mode)
  - [Selection & Picking](#selection--picking)
  - [Measurement](#measurement)
  - [Keyboard](#keyboard)
  - [Input Dispatch](#input-dispatch)

---

## MetalViewportView

A Metal-backed 3D viewport `View`. Wraps `MTKView` through platform-specific representables and wires up the full gesture stack: on iOS / visionOS: single-finger orbit (`DragGesture`), two-finger pan, pinch-to-zoom and roll (`UIPanGestureRecognizer`, `UIPinchGestureRecognizer` and `UIRotationGestureRecognizer` on one transparent overlay, all simultaneous), single tap (pick), double-tap; on macOS: mouse drag, scroll-wheel zoom, trackpad magnify/rotate, double-click and configured reset key combinations, all handled natively by the `MTKView` subclass. Double-taps, double-clicks and keys do nothing unless `GestureConfiguration.resetViewTriggers`, `doubleTap` or `doubleClick` opt in. On iOS / visionOS the double-tap recognizer is attached only when something uses it, so single-tap picks are not held back waiting for a possible second tap. Modifier-key interpretation for macOS (orbit / pan / zoom) lives in `ViewportController.dispatch(_:)` via `GestureConfiguration`.

The view passes its size to `ViewportController.updateViewportSize(_:)` whenever it changes, which keeps pan 1:1 with the pointer. On iOS / visionOS it tells the controller where each drag starts: the one-finger drag's start (`setDragOrigin(offsetFromCenter:)`) and the two-finger pan's centroid where the fingers went down (`setTwoFingerDragOrigin(offsetFromCenter:)`), so an arcball drag of either kind can roll.

The one-finger drag stands aside while a two-finger pan runs (issue #200). A second finger landing during a one-finger drag ends that drag at once, without momentum, and the rest of it is ignored even after the second finger lifts. The pan clears itself when it ends; previously only the one-finger drag's end cleared it, so a two-finger pan that never started the one-finger drag swallowed the whole next one-finger drag. A one-finger drag cut short by the second finger used to be left open, so the next drag continued it; and a cancelled drag, whose end SwiftUI never delivers, left a stale translation that made the next drag jump. A drag that starts somewhere new now ends any drag still open first.

A drag ended either way (by a second finger, or because its end never came) is *interrupted*, not released (issue #204): it ends through `ViewportController`'s internal `interruptDrag()`, with no momentum and never the slow-release snap to a nearby axis view. It used to end as a zero-velocity `.dragEnded`, which reads as a gentle release, so within 3° of an axis view the view snapped. A cancelled two-finger pan ends the same way. `onInputEvent` still sees a zero-velocity `.dragEnded` (or `.twoFingerPanEnded`) for these, so an input inspector shows the drag ending.

Pinch and roll use UIKit recognizers rather than SwiftUI's `MagnifyGesture` and `RotateGesture` (issue #204). Those skip `onEnded` when cancelled, which left the last cumulative value they kept stale and skewed the first step of the next pinch or twist; each recognizer's value is now reset after every step, and a cancel ends the gesture. A pinch zooms toward the fingers' centroid *now*, so a pinch whose fingers drift keeps the point under them under them; `MagnifyGesture` only reported where the pinch started.

The measurement overlay projects with the near/far planes the renderer fitted for its last frame, falling back to `CameraState.clipPlanes(sceneBounds: nil)` before the first frame, rather than a fixed 0.01/10000 (issue #204).

Built-in overlays that the view manages automatically:

| Overlay | Shown when |
|---|---|
| Navigation cube (`NavigationCubeView`) | `controller.showViewCube == true` |
| Orientation gnomon (`OrientationGnomon`) | `controller.showOrientationGnomon == true` |
| Scale bar (`ScaleBarView`) | `controller.showScaleBar == true` |
| Measurement annotations (`MeasurementOverlay`) | `controller.measurements` is non-empty |

### `init(controller:bodies:)`

```swift
public init(
    controller: ViewportController,
    bodies: Binding<[ViewportBody]>
)
```

Creates the viewport, binding it to an external `[ViewportBody]` array. The binding is read each frame by the renderer; mutations to the array (add, remove, replace elements) are picked up automatically on the next render cycle.

```swift
struct ContentView: View {
    @StateObject private var controller = ViewportController(configuration: .cad)
    @State private var bodies: [ViewportBody] = [
        .box(id: "box", color: SIMD4<Float>(0.5, 0.7, 1.0, 1.0))
    ]

    var body: some View {
        MetalViewportView(controller: controller, bodies: $bodies)
    }
}
```

---

## ViewportController

```swift
@MainActor
public final class ViewportController: ObservableObject
```

Central hub for all viewport state. Create one with `@StateObject` and pass it to `MetalViewportView`. Every `@Published` property causes SwiftUI to re-render observers on the main actor; no `.receive(on:)` is needed.

---

### Initialisation

#### `init(configuration:)`

```swift
public init(configuration: ViewportConfiguration = ViewportController.defaultConfiguration)

nonisolated public static let defaultConfiguration: ViewportConfiguration  // .cad
nonisolated public static let defaultEdgeIntensity: Float                 // 1.0
```

Creates a controller initialised from `configuration`. All `@Published` properties seed from the configuration's values. `defaultConfiguration` and `defaultEdgeIntensity` are also where `OffscreenRenderOptions` takes its defaults, so a default offscreen render matches a default controller.

```swift
let controller = ViewportController(configuration: .cadHighQuality)
```

#### `configuration`

```swift
public let configuration: ViewportConfiguration
```

The configuration the controller was created with. Immutable after initialisation.

#### `cameraController`

```swift
public let cameraController: CameraController
```

The underlying camera controller. Exposed for advanced use (e.g. adjusting `rotationStyle`, `minDistance`, `maxDistance`, `enableInertia` at runtime). For common operations prefer the high-level methods below.

#### `lastAspectRatio`

```swift
public internal(set) var lastAspectRatio: Float
```

The most recently observed viewport aspect ratio (width / height). Updated automatically by `MetalViewportView` whenever the geometry changes.

#### `updateViewportSize(_:)`

```swift
public func updateViewportSize(_ size: CGSize)
```

Records the size of the view, in points, that gestures move over: sets `lastAspectRatio` and `CameraController.viewportHeight`, which pan uses to stay 1:1 with the pointer. `MetalViewportView` calls it whenever its size changes; call it yourself when you drive the controller from another view. An empty size is ignored.

---

### Scene & Display

#### `cameraState`

```swift
@Published public private(set) var cameraState: CameraState
```

Current camera state (rotation, distance, pivot, projection). Read-only from outside; updated by the camera controller and animations.

#### `displayMode`

```swift
@Published public var displayMode: DisplayMode
```

Current display mode (e.g. `.shaded`, `.wireframe`, `.shadedWithEdges`). Writable; cycles via `cycleDisplayMode()`.

#### `xrayOpacity`

```swift
@Published public var xrayOpacity: Float
```

Opacity ceiling for surfaces in `.xray` mode, adjustable live (bind it to a `Slider`). Starts at `configuration.xrayOpacity` (default `DisplayMode.defaultXRayOpacity`, 0.2) and is clamped to `0...1` on set; NaN or infinity resets it to the default. Lower is more see-through; at 1 x-ray surfaces draw opaque.

#### `showViewCube`

```swift
@Published public var showViewCube: Bool
```

Whether the navigation cube overlay is visible. Toggled by `toggleViewCube()`.

#### `showAxes`

```swift
@Published public var showAxes: Bool
```

Whether the world-space axis triad is rendered. Toggled by `toggleAxes()`.

#### `showGrid`

```swift
@Published public var showGrid: Bool
```

Whether the ground grid is rendered, in the style `configuration.gridStyle` sets. Toggled by `toggleGrid()`.

#### `showOrientationGnomon`

```swift
@Published public var showOrientationGnomon: Bool
```

Whether the screen-space orientation gnomon (HUD corner axes) is visible.

#### `showScaleBar`

```swift
@Published public var showScaleBar: Bool
```

Whether the screen-space scale bar (HUD) is visible.

#### `isAnimating`

```swift
@Published public private(set) var isAnimating: Bool
```

`true` while a camera animation is in progress. Useful for disabling UI controls during a fly-to.

#### `lightingConfiguration`

```swift
@Published public var lightingConfiguration: LightingConfiguration
```

Live lighting configuration. Assign a preset (`.threePoint`, `.studio`, `.architectural`, `.flat`) or a custom value; changes take effect on the next frame.

#### `edgeIntensity`

```swift
@Published public var edgeIntensity: Float
```

Edge / wireframe intensity. `1` (the default) draws edges fully opaque; lower values make them fainter, more so with depth, and `0` hides them. Values above `1` behave as `1`. Applies to both the quad-expanded and the native edge paths, including arcs and overlay edges. Edge-only bodies (no mesh) ignore it and draw in their body colour.

#### `clipPlanes`

```swift
@Published public var clipPlanes: [ClipPlane]
```

Clipping planes for section views. Only planes with `isEnabled == true` are applied by the renderer each frame, and at most `ClipPlane.maxActivePlanes` (4) of them, in array order. Enabled planes past the fourth are ignored; debug builds log a warning when the array is set with more. Clipped geometry is hidden from every drawn pass and from GPU picking (see `ClipPlane`).

#### `measurements`

```swift
@Published public var measurements: [ViewportMeasurement]
```

Committed measurement annotations rendered by `MeasurementOverlay`. Append directly for programmatic annotations, or let the tap-to-measure flow populate it via `measurementMode`.

---

### Post-Processing

#### `enableDepthOfField`

```swift
@Published public var enableDepthOfField: Bool
```

Whether depth-of-field blur is active. Default `false`.

#### `dofAperture`

```swift
@Published public var dofAperture: Float
```

DoF aperture value. Smaller = shallower depth of field. Default `2.8`.

#### `dofFocalDistance`

```swift
@Published public var dofFocalDistance: Float
```

DoF focal distance in world units. `0` enables auto-focus on the world-space centre of the visible geometry bodies. Default `0`.

#### `dofMaxBlurRadius`

```swift
@Published public var dofMaxBlurRadius: Float
```

Maximum DoF blur radius in pixels. Default `8.0`.

#### `enableTAA`

```swift
@Published public var enableTAA: Bool
```

Whether temporal anti-aliasing is active.

#### `taaBlendFactor`

```swift
@Published public var taaBlendFactor: Float
```

TAA blend factor: `0` = no history, `1` = full history. Default `0.9`.

#### `enableProgressiveAccumulation`

```swift
@Published public var enableProgressiveAccumulation: Bool
```

When `true` (requires `enableTAA`), history weight grows as `N/(N+1)` while the camera is still, giving unbounded supersampling during idle. Default `false`.

#### `debugDisableCurvature`

```swift
@Published public var debugDisableCurvature: Bool
```

Debug toggle: disables screen-space curvature enhancement in the shaded fragment shader. Default `false`.

#### `debugDisableTessellation`

```swift
@Published public var debugDisableTessellation: Bool
```

Debug toggle: disables GPU tessellation and falls back to standard triangles. Default `false`.

---

### Camera Control

#### `goToStandardView(_:duration:)`

```swift
public func goToStandardView(_ view: StandardView, duration: Float = 0.3)
```

Animates to a preset standard view (`.top`, `.front`, `.right`, `.isometric`, etc.) over `duration` seconds.

```swift
Button("Top") { controller.goToStandardView(.top) }
Button("ISO") { controller.goToStandardView(.isometric, duration: 0.5) }
```

#### `animateTo(_:duration:)`

```swift
public func animateTo(_ state: CameraState, duration: Float = 0.3)
```

Animates to an arbitrary `CameraState`. Use this to restore saved camera positions.

#### `goToRegion(_:duration:)`

```swift
public func goToRegion(_ region: ViewCubeRegion, duration: Float = 0.3)
```

Animates to the orientation corresponding to a `ViewCubeRegion` (face, edge, or corner), preserving the current pivot, distance, and projection. Called by `NavigationCubeView` when the user taps the cube.

#### `focusOn(point:distance:animated:)`

```swift
public func focusOn(
    point: SIMD3<Float>,
    distance: Float? = nil,
    animated: Bool = true
)
```

Moves the camera orbit pivot to `point`. Optionally sets the camera-to-pivot `distance`; if `nil`, the current distance is kept. Pass `animated: false` for an instant jump. Either way it stops orbit and pan momentum; previously an instant jump left momentum coasting, which carried the camera straight off the point.

#### `reset(animated:)`

```swift
public func reset(animated: Bool = true)
```

Resets the camera to the initial state defined by `configuration.initialCameraState`. Nothing calls it by default. `MetalViewportView` calls it for any input listed in `GestureConfiguration.resetViewTriggers` (a key combination, a double-click with modifiers, or a double-tap). Apps can also call it from their own menu item or shortcut.

#### `toggleProjection()`

```swift
public func toggleProjection()
```

Toggles between perspective and orthographic projection, animated over 0.3 s.

#### `handleOrbit(translation:)`

```swift
public func handleOrbit(translation: CGSize)
```

Applies an incremental orbit delta (in points, y down). This is the raw call: the model always turns with the delta, and `GestureConfiguration.dragRotation` is not applied. Prefer `dispatch(_:)` for custom input sources, which applies it.

#### `endOrbit(velocity:)`

```swift
public func endOrbit(velocity: CGSize)
```

Ends an orbit gesture, optionally applying inertia from the release velocity (points per second; the momentum starts at `GestureConfiguration.momentumScale` of it). At low speeds snaps to the nearest standard view's orientation if within 3°, keeping the current projection (previously the snap also switched a perspective camera to orthographic), except in `.firstPerson`, where snapping would move the camera. Also ends the camera controller's orbit drag (`CameraController.endOrbitDrag()`), so the next `handleOrbit` begins a new one. A drag the touch view interrupts (a second finger lands, or the gesture is cancelled) does not end through here, so it never snaps (issue #204).

#### `handlePan(translation:)`

```swift
public func handlePan(translation: CGSize)
```

Applies an incremental pan translation (in points). At the default `GestureConfiguration.panSensitivity` of `1` the pan is 1:1: the point under the pointer (at the pivot's depth in perspective) stays under it. See `CameraController.pan(deltaX:deltaY:)`.

#### `endPan(velocity:)`

```swift
public func endPan(velocity: CGSize)
```

Ends a pan gesture, optionally applying inertia from the release velocity (points per second, scaled by `GestureConfiguration.momentumScale`).

#### `handleZoom(magnification:)`

```swift
public func handleZoom(magnification: CGFloat)
```

Zooms by a scale ratio relative to the current distance.

#### `handleZoom(magnification:centerNormalized:aspectRatio:)`

```swift
public func handleZoom(
    magnification: CGFloat,
    centerNormalized: SIMD2<Float>,
    aspectRatio: Float
)
```

Zooms toward a specific point in NDC (−1…+1 on both axes), so the world point under the pinch centre stays fixed on screen. Used for pinch-to-zoom and scroll-at-cursor.

#### `handleScrollZoom(delta:)`

```swift
public func handleScrollZoom(delta: CGFloat)
```

Applies a scroll-wheel zoom delta toward the view centre.

#### `handleScrollZoom(delta:cursorNormalized:aspectRatio:)`

```swift
public func handleScrollZoom(
    delta: CGFloat,
    cursorNormalized: SIMD2<Float>,
    aspectRatio: Float
)
```

Applies a scroll-wheel zoom delta toward the cursor position in NDC.

#### `handleRoll(angle:)`

```swift
public func handleRoll(angle: CGFloat)
```

Applies an incremental roll (in-plane rotation) in radians.

---

### Toggles & Display Mode

#### `cycleDisplayMode()`

```swift
public func cycleDisplayMode()
```

Advances `displayMode` through all `DisplayMode` cases in order.

#### `toggleViewCube()`

```swift
public func toggleViewCube()
```

Flips `showViewCube`.

#### `toggleAxes()`

```swift
public func toggleAxes()
```

Flips `showAxes`.

#### `toggleGrid()`

```swift
public func toggleGrid()
```

Flips `showGrid`.

---

### Selection & Picking

#### `pickResult`

```swift
@Published public private(set) var pickResult: PickResult?
```

The most recent pick result for the user-geometry layer, or `nil` if nothing is selected. Updated by `handlePick(result:ndc:)`. Widget-layer picks are routed to `widgetPickResult` instead. On a tap, `MetalViewportView` resolves a wrapped face index (body over 16,384 triangles) before calling `handlePick`, so a face pick here is exact unless `isPrimitiveIndexAmbiguous` is still set; see [Picking limits](Picking.md#limits).

#### `widgetPickResult`

```swift
@Published public private(set) var widgetPickResult: PickResult?
```

The most recent pick result for the widget layer (bodies with `pickLayer == .widget`). Kept at its last value across miss-taps; the external consumer (e.g. OCCTSwiftAIS) decides when to clear it via `clearWidgetPick()`.

#### `selectedBodyIDs`

```swift
@Published public var selectedBodyIDs: Set<String>
```

The set of selected body IDs. Bodies in this set render with a highlight outline, styled by `ViewportConfiguration.selectionOutline` (colour and pixel width). Assign directly for programmatic selection, or use `selectBody(_:toggle:)` / `deselectAll()`.

#### `hoveredBodyID`

```swift
@Published public var hoveredBodyID: String?
```

The ID of the hovered body (macOS mouse hover), or `nil`.

#### `lastPickNDC`

```swift
@Published public private(set) var lastPickNDC: SIMD2<Float>
```

NDC coordinates (−1…+1) of the most recent pick tap, for sub-body operations.

#### `selectionFilter`

```swift
public var selectionFilter: PickResultFilter?
```

Optional filter constraining the user-geometry pick stream. A pick that fails the filter is treated as a miss (clearing `pickResult`). Widget-layer picks bypass the filter.

#### `onPick`

```swift
public var onPick: ((PickResult?) -> Void)?
```

Callback invoked whenever a user-geometry pick resolves (including misses, where the argument is `nil`).

#### `onWidgetPick`

```swift
public var onWidgetPick: ((PickResult?) -> Void)?
```

Callback invoked whenever a widget-layer pick resolves.

#### `handlePick(result:)`

```swift
public func handlePick(result: PickResult?)
```

Routes a GPU pick result to the appropriate stream. Normally called by the view layer; call this from a custom renderer or test harness.

#### `handlePick(result:ndc:)`

```swift
public func handlePick(result: PickResult?, ndc: SIMD2<Float>)
```

As `handlePick(result:)`, additionally recording `ndc` in `lastPickNDC`.

#### `selectBody(_:toggle:)`

```swift
public func selectBody(_ bodyID: String, toggle: Bool = false)
```

Selects a body by ID. When `toggle` is `true`, the body is added to or removed from `selectedBodyIDs` (multi-select); when `false`, `selectedBodyIDs` is replaced with just this ID.

```swift
// Single-select on pick:
controller.selectBody(result.bodyID)

// Add to existing selection:
controller.selectBody(result.bodyID, toggle: true)
```

#### `deselectAll()`

```swift
public func deselectAll()
```

Clears `selectedBodyIDs`.

#### `clearSelection()`

```swift
public func clearSelection()
```

Clears `pickResult`, clears `selectedBodyIDs`, and fires `onPick(nil)`.

#### `clearWidgetPick()`

```swift
public func clearWidgetPick()
```

Clears `widgetPickResult` and fires `onWidgetPick(nil)`.

---

### Measurement

#### `measurementMode`

```swift
@Published public var measurementMode: MeasurementMode
```

Active measurement mode. When not `.none`, taps on geometry feed the measurement accumulator instead of the selection stream. Changing the mode discards any in-progress points. Default `.none`.

| Value | Points needed |
|---|---|
| `.none` | none |
| `.distance` | 2 (start, end) |
| `.angle` | 3 (armA, vertex, armB) |
| `.radius` | 2 (center, edge point) |

#### `pendingMeasurementPoints`

```swift
@Published public private(set) var pendingMeasurementPoints: [SIMD3<Float>]
```

World-space points accumulated so far for the in-progress measurement, in tap order. Expose these to drive a rubber-band line overlay before the measurement commits.

#### `pointCount(for:)`

```swift
public nonisolated static func pointCount(for mode: MeasurementMode) -> Int
```

Returns the number of world-space points required before a measurement in `mode` is committed. Returns `0` for `.none`.

#### `addMeasurementPoint(_:)`

```swift
public func addMeasurementPoint(_ point: SIMD3<Float>)
```

Feeds a world-space point into the active measurement. When enough points for the current mode are accumulated, a `ViewportMeasurement` is appended to `measurements` and `pendingMeasurementPoints` is cleared. A no-op when `measurementMode == .none`. `MetalViewportView` calls this automatically on tap; call it directly for programmatic measurement.

#### `handleMeasurementPick(result:ndc:bodies:aspectRatio:)`

```swift
public func handleMeasurementPick(
    result: PickResult?,
    ndc: SIMD2<Float>,
    bodies: [ViewportBody],
    aspectRatio: Float
)
```

Converts a GPU pick result into a world-space surface point (ray / triangle intersection, respecting the body's transform) and feeds it to `addMeasurementPoint(_:)`. Only `.face` picks are accepted; edge / vertex picks and misses are ignored. On a body with more than `PickResult.maxPrimitivesPerKind` triangles, the wrapped triangle index is first resolved with `ViewportBody.resolveWrappedTriangleIndex(_:ray:)`; a pick that cannot be resolved is ignored rather than measured on the wrong triangle. Called by `MetalViewportView` while `measurementMode != .none`.

#### `cancelPendingMeasurement()`

```swift
public func cancelPendingMeasurement()
```

Discards in-progress points without committing a measurement. `measurementMode` is unchanged.

```swift
// Cancel in-progress angle measurement:
controller.cancelPendingMeasurement()
```

#### `clearMeasurements()`

```swift
public func clearMeasurements()
```

Removes all committed measurements from `measurements` and clears any in-progress points.

---

### Keyboard

#### `handleKeyPress(_:modifiers:)`

```swift
@discardableResult
public func handleKeyPress(_ key: Character, modifiers: ViewportModifierKeys) -> Bool
public func handleKeyPress(_ key: Character)  // same, with no modifiers held
```

Processes a single keystroke. Checks `StandardView.keyboardShortcut` and `DisplayMode.keyboardShortcut`; the first match executes the corresponding action and returns `true`. The shortcuts are bare keys, so a press with ⌘, ⌃ or ⌥ held is ignored and returns `false`. App shortcuts such as ⌘F or ⌘W therefore pass through instead of switching to the front view or wireframe. Wire this to an `onKeyPress` modifier, passing the modifiers along.

```swift
.onKeyPress { press in
    var modifiers: ViewportModifierKeys = []
    if press.modifiers.contains(.command) { modifiers.insert(.command) }
    if press.modifiers.contains(.control) { modifiers.insert(.control) }
    if press.modifiers.contains(.option) { modifiers.insert(.option) }
    let key = press.characters.first ?? " "
    return controller.handleKeyPress(key, modifiers: modifiers) ? .handled : .ignored
}
```

Previously the single-argument form was the only one, so ⌘F reached it as a bare "f" and switched to the front view.

---

### Input Dispatch

#### `dispatch(_:)`

```swift
public func dispatch(_ event: ViewportInputEvent)
```

The single entry point for portable input. `MetalViewportView` calls this for every gesture; custom input sources (visionOS spatial input, tests, scripting) produce the same events.

`onInputEvent` fires before any interpretation, so observers see every event regardless of how it is handled.

```swift
// Synthetic orbit from an external gamepad:
controller.dispatch(.dragChanged(
    delta: SIMD2<Float>(dx, dy),
    modifiers: []
))
```

#### `onInputEvent`

```swift
public var onInputEvent: ((ViewportInputEvent) -> Void)?
```

Observational callback fired for every event passed to `dispatch(_:)`. Does not affect how the event is interpreted. Useful for HUD input inspectors and debugging.

---

## ViewportInputEvent

```swift
public enum ViewportInputEvent: Sendable, Equatable
```

Platform-neutral viewport input event. Pass to `ViewportController.dispatch(_:)`. All deltas and velocities are in points / points-per-second; sign conventions and gesture-action mapping live in the dispatch layer, not the platform translation layer.

| Case | Description |
|---|---|
| `.dragChanged(delta:modifiers:)` | Primary pointer drag (mouse on macOS, single finger on iOS) |
| `.dragEnded(velocity:modifiers:)` | Release with velocity for inertia |
| `.twoFingerPanChanged(translation:)` | Two-finger pan translation |
| `.twoFingerPanEnded(velocity:)` | Two-finger pan release |
| `.pinchChanged(scale:)` | Pinch, incremental scale ratio (1.0 = no change) |
| `.pinchAtChanged(scale:centerNDC:aspectRatio:)` | Pinch with known gesture centre in NDC |
| `.pinchEnded` | Pinch gesture ended |
| `.rotateChanged(radians:)` | In-plane rotation, incremental radians |
| `.rotateEnded` | Rotation gesture ended |
| `.scroll(delta:cursorNDC:aspectRatio:)` | Scroll-wheel zoom toward cursor (macOS) |
| `.tap(ndc:count:)` | Tap / click; `count >= 2` runs a matching `resetViewTriggers` entry or `doubleTap` / `doubleClick` (nothing by default) |
