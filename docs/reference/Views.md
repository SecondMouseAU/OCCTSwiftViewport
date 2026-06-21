---
title: SwiftUI Views
parent: API Reference
---

# SwiftUI Views

Two types form the public entry point to the viewport: `MetalViewportView` is the SwiftUI `View` that renders the 3D scene and handles gestures; `ViewportController` is the `@MainActor ObservableObject` hub that everything—camera, display mode, picking, measurements, clip planes, post-processing—routes through.

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

A Metal-backed 3D viewport `View`. Wraps `MTKView` through platform-specific representables and wires up the full gesture stack: on iOS / visionOS — single-finger orbit (`DragGesture`), two-finger pan (`UIPanGestureRecognizer` overlay), pinch-to-zoom (`MagnifyGesture`), roll (`RotateGesture`), single tap (pick), double-tap (reset); on macOS — mouse drag (`DragGesture`), scroll-wheel zoom, trackpad magnify/rotate. Modifier-key interpretation for macOS (orbit / pan / zoom) lives in `ViewportController.dispatch(_:)` via `GestureConfiguration`.

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
public init(configuration: ViewportConfiguration = .cad)
```

Creates a controller initialised from `configuration`. All `@Published` properties seed from the configuration's values.

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

Whether the adaptive dot grid is rendered. Toggled by `toggleGrid()`.

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

Edge / wireframe intensity multiplier. `0` = invisible, `1` = default, `>1` = bold. Default `1.0`.

#### `clipPlanes`

```swift
@Published public var clipPlanes: [ClipPlane]
```

Active clipping planes (up to 4). Only planes with `isOn == true` are applied by the renderer each frame.

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

DoF focal distance in world units. `0` enables auto-focus. Default `0`.

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

Moves the camera orbit pivot to `point`. Optionally sets the camera-to-pivot `distance`; if `nil`, the current distance is kept. Pass `animated: false` for an instant jump.

#### `reset(animated:)`

```swift
public func reset(animated: Bool = true)
```

Resets the camera to the initial state defined by `configuration.initialCameraState`. A double-tap in `MetalViewportView` calls this automatically.

#### `toggleProjection()`

```swift
public func toggleProjection()
```

Toggles between perspective and orthographic projection, animated over 0.3 s.

#### `handleOrbit(translation:)`

```swift
public func handleOrbit(translation: CGSize)
```

Applies an incremental orbit delta (in points). Prefer `dispatch(_:)` for custom input sources.

#### `endOrbit(velocity:)`

```swift
public func endOrbit(velocity: CGSize)
```

Ends an orbit gesture, optionally applying inertia from the release velocity. At low speeds snaps to the nearest standard view if within 3°.

#### `handlePan(translation:)`

```swift
public func handlePan(translation: CGSize)
```

Applies an incremental pan translation (in points).

#### `endPan(velocity:)`

```swift
public func endPan(velocity: CGSize)
```

Ends a pan gesture, optionally applying inertia.

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

The most recent pick result for the user-geometry layer, or `nil` if nothing is selected. Updated by `handlePick(result:ndc:)`. Widget-layer picks are routed to `widgetPickResult` instead.

#### `widgetPickResult`

```swift
@Published public private(set) var widgetPickResult: PickResult?
```

The most recent pick result for the widget layer (bodies with `pickLayer == .widget`). Kept at its last value across miss-taps—the external consumer (e.g. OCCTSwiftAIS) decides when to clear it via `clearWidgetPick()`.

#### `selectedBodyIDs`

```swift
@Published public var selectedBodyIDs: Set<String>
```

The set of selected body IDs. Bodies in this set render with a highlight outline. Assign directly for programmatic selection, or use `selectBody(_:toggle:)` / `deselectAll()`.

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
public var selectionFilter: SelectionFilter?
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
| `.none` | — |
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

Converts a GPU pick result into a world-space surface point (ray / triangle intersection, respecting the body's transform) and feeds it to `addMeasurementPoint(_:)`. Only `.face` picks are accepted; edge / vertex picks and misses are ignored. Called by `MetalViewportView` while `measurementMode != .none`.

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

#### `handleKeyPress(_:)`

```swift
public func handleKeyPress(_ key: Character)
```

Processes a single keystroke. Checks `StandardView.keyboardShortcut` and `DisplayMode.keyboardShortcut`; the first match executes the corresponding action. Wire this to a `onKeyPress` modifier or a `Button` keyboard shortcut handler.

```swift
.onKeyPress { press in
    controller.handleKeyPress(press.characters.first ?? Character(""))
    return .handled
}
```

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
| `.tap(ndc:count:)` | Tap / click; `count >= 2` resets the view |
