---
title: Display & Lighting
parent: API Reference
---

# Display & Lighting

Four types control how geometry is rendered and how the scene is lit: `DisplayMode` selects the rendering style applied to all visible bodies; `LightingConfiguration` defines the full lighting rig with presets for common CAD workflows; `LightSettings` describes a single light source; and `LightType` identifies whether a light is directional (sun-like) or positional.

## Topics

- [DisplayMode](#displaymode) · [LightingConfiguration](#lightingconfiguration) · [LightSettings](#lightsettings) · [LightType](#lighttype)

---

## DisplayMode

`public enum DisplayMode: String, CaseIterable, Sendable`

Display mode for rendering geometry in the viewport. Assign to `ViewportController.displayMode` to switch the visual representation of all visible bodies.

### Cases

#### `wireframe`

Edges only — no surface shading. The fastest mode; useful for verifying topology.

```swift
controller.displayMode = .wireframe
```

#### `shaded`

Surfaces lit by the current `LightingConfiguration`; no edge overlay. The default for CAD work.

```swift
controller.displayMode = .shaded
```

#### `shadedWithEdges`

Shaded surfaces with a wireframe edge overlay drawn on top. Combines readability of shading with topology visibility.

```swift
controller.displayMode = .shadedWithEdges
```

#### `flat`

Flat (facet) shading — Gouraud interpolation disabled. Surface normals are computed per-triangle rather than smoothed at vertices.

```swift
controller.displayMode = .flat
```

#### `unlit`

Each body is drawn in its constant base colour with no lighting, ambient contribution, shadows, Fresnel, or tone mapping. Added in v1.1.21 (issue #77) for diagnostic and debug renders where faithfully distinguishable per-body colours are more important than realistic shading.

```swift
controller.displayMode = .unlit
```

#### `xray`

Transparent rendering with visible internal edges. Useful for inspecting hidden structure without clipping.

```swift
controller.displayMode = .xray
```

#### `rendered`

Full rendering with materials and environment-map–based reflections.

```swift
controller.displayMode = .rendered
```

---

### Computed Properties

#### `displayName`

```swift
public var displayName: String { get }
```

Human-readable label for the mode, suitable for UI display.

| Case | `displayName` |
|---|---|
| `.wireframe` | `"Wireframe"` |
| `.shaded` | `"Shaded"` |
| `.shadedWithEdges` | `"Shaded + Edges"` |
| `.flat` | `"Flat"` |
| `.unlit` | `"Unlit"` |
| `.xray` | `"X-Ray"` |
| `.rendered` | `"Rendered"` |

```swift
Text(controller.displayMode.displayName)
```

#### `showsSurfaces`

```swift
public var showsSurfaces: Bool { get }
```

`true` for every mode except `.wireframe`. Indicates whether the renderer runs the shaded surface pipeline.

```swift
if controller.displayMode.showsSurfaces {
    // shadow pass is active
}
```

#### `showsEdges`

```swift
public var showsEdges: Bool { get }
```

`true` for `.wireframe`, `.shadedWithEdges`, and `.xray`. Indicates whether the renderer draws edge polylines.

```swift
if controller.displayMode.showsEdges {
    // wireframe pipeline is active
}
```

#### `usesSmoothShading`

```swift
public var usesSmoothShading: Bool { get }
```

`false` only for `.flat`; `true` for all other modes. When `false` the renderer skips Gouraud interpolation and uses per-face normals.

#### `usesTransparency`

```swift
public var usesTransparency: Bool { get }
```

`true` only for `.xray`. Indicates that the transparency (alpha-blend) pipeline is active.

```swift
if controller.displayMode.usesTransparency {
    // translucent sort pass is active
}
```

#### `keyboardShortcut`

```swift
public var keyboardShortcut: Character? { get }
```

Single-character keyboard shortcut to activate this mode, or `nil` if no shortcut is defined.

| Case | Shortcut |
|---|---|
| `.wireframe` | `"w"` |
| `.shaded` | `"s"` |
| `.shadedWithEdges` | `"e"` |
| `.xray` | `"x"` |
| `.flat`, `.unlit`, `.rendered` | `nil` |

```swift
if let key = mode.keyboardShortcut {
    // register key handler for String(key)
}
```

---

## LightingConfiguration

`public struct LightingConfiguration: Sendable`

Full scene-lighting rig. Assign to `ViewportController.lightingConfiguration` (or pass to `ViewportRenderer`) to reconfigure shading in the next render frame. All properties have defaults and the struct is `Sendable`, so configurations can be prepared on any actor and sent to the main actor.

### Stored Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `keyLight` | `LightSettings` | (required) | Main directional light — typically the dominant, warm source |
| `fillLight` | `LightSettings` | (required) | Secondary softer light to reduce shadow harshness |
| `backLight` | `LightSettings` | (required) | Rim/kicker light for edge definition |
| `ambientIntensity` | `Float` | `0.3` | Scalar ambient contribution (0–1) |
| `ambientColor` | `SIMD3<Float>` | `(1,1,1)` | Tint applied to the ambient term |
| `shadowsEnabled` | `Bool` | `true` | Master switch for the shadow-map pass |
| `shadowSoftness` | `Float` | `0.3` | PCSS penumbra softness (0 = hard, 1 = soft) |
| `shadowMapSize` | `Int` | `2048` | Shadow map resolution in pixels (width = height) |
| `shadowIntensity` | `Float` | `0.4` | Opacity of cast shadows (0 = invisible, 1 = opaque) |
| `shadowBias` | `Float` | `0.005` | Depth bias to prevent shadow acne |
| `specularPower` | `Float` | `64.0` | Blinn-Phong shininess exponent (higher = tighter highlight) |
| `specularIntensity` | `Float` | `0.5` | Specular highlight strength (0–1) |
| `fresnelPower` | `Float` | `3.0` | Fresnel rim falloff exponent |
| `fresnelIntensity` | `Float` | `0.3` | Fresnel rim brightness (0–1) |
| `matcapBlend` | `Float` | `0.0` | Matcap blend factor (0 = pure lighting, 1 = pure matcap) |
| `ambientSkyColor` | `SIMD3<Float>` | `(0.9,0.95,1.0)` | Hemisphere ambient — upper (sky) colour |
| `ambientGroundColor` | `SIMD3<Float>` | `(0.3,0.25,0.2)` | Hemisphere ambient — lower (ground) colour |
| `enableSSAO` | `Bool` | `true` | Enable screen-space ambient occlusion |
| `ssaoRadius` | `Float` | `0.5` | SSAO sampling radius in view-space units |
| `ssaoIntensity` | `Float` | `0.6` | SSAO darkening intensity (0 = none, 1 = maximum) |
| `exposure` | `Float` | `1.1` | Tone-mapping exposure multiplier |
| `whitePoint` | `Float` | `1.0` | White point for tone-mapping normalization |
| `shadowLightSize` | `Float` | `0.02` | PCSS light-source size (larger = softer penumbras) |
| `shadowSearchRadius` | `Float` | `0.01` | PCSS blocker-search radius in light-space UV |
| `environmentMapData` | `Data?` | `nil` | Legacy raw-bytes HDR: `Int32 width \| Int32 height \| RGBA32Float pixels` |
| `environmentMapURL` | `URL?` | `nil` | File URL to a Radiance `.hdr` file; takes precedence over `environmentMapData` |
| `environmentIntensity` | `Float` | `1.0` | IBL contribution multiplier |
| `environmentRotationY` | `Float` | `0` | Y-axis rotation of the environment map in radians (0…2π) |
| `backgroundExposure` | `Float` | `1.0` | Exposure for the visible skybox background; independent of `environmentIntensity` |
| `drawBackground` | `Bool` | `false` | Render the environment map as a skybox; `false` uses a solid clear colour |

### Initializer

```swift
public init(
    keyLight: LightSettings,
    fillLight: LightSettings,
    backLight: LightSettings,
    ambientIntensity: Float = 0.3,
    ambientColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
    shadowsEnabled: Bool = true,
    shadowSoftness: Float = 0.3,
    shadowMapSize: Int = 2048,
    shadowIntensity: Float = 0.4,
    shadowBias: Float = 0.005,
    specularPower: Float = 64.0,
    specularIntensity: Float = 0.5,
    fresnelPower: Float = 3.0,
    fresnelIntensity: Float = 0.3,
    matcapBlend: Float = 0.0,
    ambientSkyColor: SIMD3<Float> = SIMD3<Float>(0.9, 0.95, 1.0),
    ambientGroundColor: SIMD3<Float> = SIMD3<Float>(0.3, 0.25, 0.2),
    enableSSAO: Bool = true,
    ssaoRadius: Float = 0.5,
    ssaoIntensity: Float = 0.6,
    exposure: Float = 1.1,
    whitePoint: Float = 1.0,
    shadowLightSize: Float = 0.02,
    shadowSearchRadius: Float = 0.01,
    environmentMapData: Data? = nil,
    environmentMapURL: URL? = nil,
    environmentIntensity: Float = 1.0,
    environmentRotationY: Float = 0,
    backgroundExposure: Float = 1.0,
    drawBackground: Bool = false
)
```

All parameters except the three lights have defaults, so you can create a custom rig by starting from a preset and mutating:

```swift
var config = LightingConfiguration.threePoint
config.shadowsEnabled = false
config.exposure = 1.3
controller.lightingConfiguration = config
```

---

### Presets

#### `threePoint`

```swift
public static let threePoint: LightingConfiguration
```

Standard three-point CAD lighting. Key light from upper-right-front (warm, intensity 1.0), fill from left (cool, intensity 0.4), back/kicker from below-behind (intensity 0.35). `ambientIntensity` 0.25, `shadowIntensity` 0.2, `ssaoIntensity` 0.8. Good for mechanical part review.

```swift
controller.lightingConfiguration = .threePoint
```

#### `studio`

```swift
public static let studio: LightingConfiguration
```

Soft neutral studio lighting. All three lights are pure white; key intensity 0.8, fill 0.5, back 0.4. `ambientIntensity` 0.35, `shadowSoftness` 0.5, `specularPower` 32.0, `matcapBlend` 0.15. Good for product visualisation.

```swift
controller.lightingConfiguration = .studio
```

#### `architectural`

```swift
public static let architectural: LightingConfiguration
```

Outdoor sun-sky simulation. Warm key (intensity 1.2, colour `(1.0, 0.95, 0.9)`), sky-blue fill (intensity 0.3), light back kicker (intensity 0.2). `ambientIntensity` 0.2, `shadowSoftness` 0.2. Good for architectural visualisation.

```swift
controller.lightingConfiguration = .architectural
```

#### `flat`

```swift
public static let flat: LightingConfiguration
```

Technical flat lighting. Single on-axis key (direction `(0, 0, -1)`, intensity 0.8); fill and back lights are disabled (intensity 0.0). Shadows off, specular and Fresnel both 0.0, `exposure` 0.9. Closest to a 2D technical drawing look.

```swift
controller.lightingConfiguration = .flat
```

---

## LightSettings

`public struct LightSettings: Sendable`

Settings for a single light source in a `LightingConfiguration`. Three `LightSettings` values (key, fill, back) make up every configuration.

### Stored Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `direction` | `SIMD3<Float>` | (required) | Normalised direction the light points toward. Ignored for `.point` lights. |
| `intensity` | `Float` | `1.0` | Light intensity. Typical range 0–2; values above 1 are valid for HDR. |
| `color` | `SIMD3<Float>` | `(1,1,1)` | RGB light colour in linear 0–1 space. |
| `isEnabled` | `Bool` | `true` | Whether this light contributes to shading. |
| `lightType` | `LightType` | `.directional` | Whether this is a directional or point light. |
| `position` | `SIMD3<Float>` | `.zero` | World-space position. Used only for `.point` lights. |

### Initializer

```swift
public init(
    direction: SIMD3<Float>,
    intensity: Float = 1.0,
    color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
    isEnabled: Bool = true,
    lightType: LightType = .directional,
    position: SIMD3<Float> = .zero
)
```

```swift
// Warm key light from upper-right-front
let key = LightSettings(
    direction: simd_normalize(SIMD3<Float>(-0.5, -0.6, -0.6)),
    intensity: 1.0,
    color: SIMD3<Float>(1.0, 0.96, 0.90)
)

// Disabled fill slot
let fill = LightSettings(
    direction: SIMD3<Float>(1, 0, 0),
    intensity: 0.0,
    isEnabled: false
)

// Point light at a fixed world position
let point = LightSettings(
    direction: .zero,               // ignored for point lights
    intensity: 0.8,
    lightType: .point(radius: 5.0),
    position: SIMD3<Float>(0, 2, 4)
)
```

---

## LightType

`public enum LightType: Sendable, Equatable`

Identifies how a light's intensity falls off with distance.

### Cases

#### `directional`

```swift
case directional
```

Sun-like parallel light with no distance falloff. The `direction` field of `LightSettings` determines the illumination angle. This is the default for all three lights in every built-in preset.

```swift
let sunLight = LightSettings(
    direction: simd_normalize(SIMD3<Float>(-1, -1, -0.5)),
    lightType: .directional
)
```

#### `point(radius:)`

```swift
case point(radius: Float)
```

Positional light that radiates in all directions with smooth falloff over `radius` model units. The `direction` field of `LightSettings` is ignored; `position` is used instead.

- `radius` — the world-space falloff radius. Intensity reaches zero at this distance.

```swift
let lamp = LightSettings(
    direction: .zero,
    intensity: 1.5,
    color: SIMD3<Float>(1.0, 0.9, 0.7),
    lightType: .point(radius: 8.0),
    position: SIMD3<Float>(2, 3, 4)
)

// Mutating the radius
var config = LightingConfiguration.threePoint
if case .point(let r) = config.keyLight.lightType {
    config.keyLight.lightType = .point(radius: r * 2)
}
```
