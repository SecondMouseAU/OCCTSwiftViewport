---
title: Display Modes
parent: Cookbook
nav_order: 2
---

# Display Modes

`DisplayMode` controls how geometry is rendered in the viewport. Set it on
`ViewportController.displayMode` — a `@Published` property, so SwiftUI views
update automatically.

```swift
controller.displayMode = .shadedWithEdges
```

---

## Modes at a glance

| Mode | `displayName` | Surfaces | Edges | Smooth | Transparent | Shortcut |
|---|---|:---:|:---:|:---:|:---:|:---:|
| `.wireframe` | Wireframe | — | ✓ | — | — | `w` |
| `.shaded` | Shaded | ✓ | — | ✓ | — | `s` |
| `.shadedWithEdges` | Shaded + Edges | ✓ | ✓ | ✓ | — | `e` |
| `.flat` | Flat | ✓ | — | — | — | — |
| `.unlit` | Unlit | ✓ | — | ✓ | — | — |
| `.xray` | X-Ray | ✓ | ✓ | ✓ | ✓ | `x` |
| `.rendered` | Rendered | ✓ | — | ✓ | — | — |

The `showsSurfaces`, `showsEdges`, `usesSmoothShading`, and `usesTransparency`
properties on `DisplayMode` expose these flags programmatically, useful if you
are building a toolbar or binding a picker. Both renderers read them, and the
GPU pick pass follows the Surfaces and Edges columns: hidden faces and edges
can't be picked (see
[Picking](../../reference/Picking.md#display-mode-and-pick-content)).

```swift
// Show the mode name in a label
Text(controller.displayMode.displayName)

// React to whether edges are drawn
if controller.displayMode.showsEdges {
    // ...
}
```

---

## Mode descriptions

### `.wireframe`

Draws only the polyline edge geometry — no surface fill. Useful for inspecting
mesh topology without surface occlusion. Keyboard shortcut: **W**.

![Wireframe render of a box and sphere scene](images/display-wireframe.png)

### `.shaded`

Three-light Cook-Torrance GGX + hemisphere ambient + Fresnel rim. The default and
most common mode for geometry review. Keyboard shortcut: **S**.

![Shaded render of a box and sphere scene](images/display-shaded.png)

### `.shadedWithEdges`

Shaded surfaces with contrast-adaptive wireframe edges overlaid. Helps show
both silhouette and internal topology simultaneously. Keyboard shortcut: **E**.

![Shaded-with-edges render of a box and sphere scene](images/display-shaded-edges.png)

### `.flat`

Shaded surfaces lit with each triangle's face normal instead of the
interpolated vertex normals, so every facet of the tessellation shows. Lights,
materials, shadows and IBL are the same as `.shaded`. Useful for inspecting
faceting or reviewing mesh density.

### `.unlit` — diagnostic / debug renders

Added in **v1.1.21** (issue #77). Each body is drawn in its constant base
colour with **no lighting, ambient, shadows, Fresnel rim, curvature weighting,
or tone mapping**. The interactive SSAO / ACES tone-map post-pass is skipped
entirely so it cannot re-desaturate colours after the fact.

This mode exists because the full PBR path (`shaded`) hue-shifts saturated
body colours — a bright magenta reads as greenish after ACES tone mapping, and
hemisphere ambient lifts dark hues. When colour-coding bodies for diagnostic
purposes (validation passes, per-feature heat maps, imported point data) you
need the colour you set to be the colour you see.

![Unlit render of a box and sphere scene](images/display-unlit.png)

Clip-plane discard and the selection tint still apply in `.unlit`, so
interactive picking and highlighting work normally.

```swift
// Colour-code bodies for a diagnostic render
for (index, body) in bodies.enumerated() {
    var coded = body
    coded.color = diagnosticColor(for: index)
    controller.viewportBodies.append(coded)
}
controller.displayMode = .unlit
```

### `.xray`

See-through surfaces with edges, so internal structure and bodies behind
others show through the model. Every surface is drawn translucent, at no more
than `DisplayMode.xraySurfaceOpacity` (0.4), in the sorted translucent pass that
bodies with opacity below 1 use in every mode; edges are drawn opaque.
`usesTransparency` is `true` only for this mode. Surfaces and edges both stay
pickable (the nearest surface wins). Keyboard shortcut: **X**.

### `.rendered`

Draws exactly like `.shaded`. The shaded path is already the full PBR
renderer, and its quality features (IBL, shadows, SSAO, TAA) are switched by
`LightingConfiguration` and `ViewportController`, not by the display mode.
`.rendered` is there for apps that want to label a "final look" view.

---

## Setting the mode

### From SwiftUI

Bind a `Picker` directly to `controller.displayMode`:

```swift
Picker("Display Mode", selection: $controller.displayMode) {
    ForEach(DisplayMode.allCases, id: \.self) { mode in
        Text(mode.displayName).tag(mode)
    }
}
.pickerStyle(.menu)
```

### From a toolbar button

```swift
Button("Wireframe") {
    controller.displayMode = .wireframe
}
```

### Cycling through modes

`ViewportController` exposes a `cycleDisplayMode()` method that steps through
all cases in declaration order — useful for a single keyboard shortcut or a
cycle button:

```swift
Button(action: controller.cycleDisplayMode) {
    Image(systemName: "circle.grid.2x2")
}
```

### Reading the keyboard shortcut

```swift
if let key = controller.displayMode.keyboardShortcut {
    Text("Shortcut: \(String(key))")
}
```

---

## Initial mode from configuration

Pass a `ViewportConfiguration` with a preset `displayMode` when constructing
the controller so the viewport opens in the right state:

```swift
var config = ViewportConfiguration()
config.displayMode = .shadedWithEdges

let controller = ViewportController(configuration: config)
```

---

## Choosing a mode

| Goal | Recommended mode |
|---|---|
| General geometry review | `.shadedWithEdges` |
| Clean presentation / screenshot | `.shaded` |
| Mesh / topology inspection | `.wireframe` |
| Colour-coded diagnostic render | `.unlit` |
| Inspect internal structure | `.xray` |
| Faceting / mesh density review | `.flat` |
