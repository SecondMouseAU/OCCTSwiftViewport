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

Faceted shading. Lit exactly like `.shaded` (same lights, materials, shadows and IBL), but each triangle is lit with its own face normal instead of the interpolated vertex normals, so the tessellation's facets show. The face normal is rebuilt in the fragment shader from the screen-space derivatives of the world position and oriented to the vertex normals' side, so it needs no extra vertex data and works for interleaved, direct-mesh, tessellated and mesh-shader bodies alike. The screen-space curvature shading term is skipped in this mode.

```swift
controller.displayMode = .flat
```

#### `unlit`

Each body is drawn in its constant base colour with no lighting, ambient contribution, shadows, Fresnel, or tone mapping. Added in v1.1.21 (issue #77) for diagnostic and debug renders where faithfully distinguishable per-body colours are more important than realistic shading.

```swift
controller.displayMode = .unlit
```

#### `xray`

See-through surfaces with edges. Every geometry-layer body's surface goes through the sorted translucent pass (issue #53's back-to-front, depth-test-on / depth-write-off pass) at `min(material opacity, xrayOpacity)`, so bodies and edges behind a surface show through it. Edges are drawn opaque before the surfaces, so they stay crisp and are only tinted by the surfaces in front of them. Overlay-layer bodies are unaffected. Selected bodies keep their tint and selection outline. In the pick buffer surfaces stay pickable (the nearest one wins) and so do edges; see [Picking](Picking.md#display-mode-and-pick-content).

`xrayOpacity` is a setting, default `DisplayMode.defaultXRayOpacity` (0.4), clamped to `0...1`. Change it live with `ViewportController.xrayOpacity` (seeded from `ViewportConfiguration.xrayOpacity`); headless renders take `OffscreenRenderOptions.xrayOpacity`, which has the same default. Lower is more see-through; at 1 x-ray surfaces draw opaque.

```swift
controller.displayMode = .xray
controller.xrayOpacity = 0.25   // more see-through
```

#### `rendered`

Draws exactly like `.shaded`. The shaded path is already the full physically based renderer: PBR materials, image-based lighting, shadows, SSAO and TAA. Each of those is switched by `LightingConfiguration` and `ViewportController` settings, not by the display mode, so `.rendered` adds nothing on top of `.shaded`. It exists so an app can label a "final look" view; turn on the quality features you want through the lighting configuration.

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

`true` for every mode except `.wireframe`. Indicates whether the renderer runs the shaded surface pipeline. Surfaces are written to the GPU pick buffer only when this is `true`.

```swift
if controller.displayMode.showsSurfaces {
    // shadow pass is active
}
```

#### `showsEdges`

```swift
public var showsEdges: Bool { get }
```

`true` for `.wireframe`, `.shadedWithEdges`, and `.xray`. Indicates whether the renderer draws edge polylines for bodies that have a surface mesh. Edge-only bodies draw their edges in every mode; see `drawsEdges(bodyHasMesh:)`.

```swift
if controller.displayMode.showsEdges {
    // wireframe pipeline is active
}
```

#### `usesSmoothShading`

```swift
public var usesSmoothShading: Bool { get }
```

`false` only for `.flat`; `true` for all other modes. When `false`, both renderers light each triangle with its face normal instead of the interpolated vertex normals (see [`flat`](#flat)).

#### `usesTransparency`

```swift
public var usesTransparency: Bool { get }
```

`true` only for `.xray`. When `true`, both renderers send every geometry-layer surface through the sorted translucent pass at `surfaceOpacity(forMaterialOpacity:)`. Bodies whose material opacity is below 1 use that pass in every mode.

```swift
if controller.displayMode.usesTransparency {
    // every surface is see-through
}
```

#### `defaultXRayOpacity`

```swift
public static let defaultXRayOpacity: Float  // 0.4
```

The default opacity ceiling for surfaces in `.xray`. It is the default of `ViewportConfiguration.xrayOpacity` (which seeds `ViewportController.xrayOpacity`) and of `OffscreenRenderOptions.xrayOpacity`, so live and headless renders match unless you change one.

#### `clampedXRayOpacity(_:)`

```swift
public static func clampedXRayOpacity(_ opacity: Float) -> Float
```

Clamps an x-ray opacity to `0...1`; NaN or infinity becomes `defaultXRayOpacity`. Every `xrayOpacity` setter applies it.

#### `surfaceOpacity(forMaterialOpacity:xrayOpacity:)`

```swift
public func surfaceOpacity(
    forMaterialOpacity opacity: Float, xrayOpacity: Float = defaultXRayOpacity
) -> Float
```

The opacity a surface with the given material opacity is drawn with in this mode: unchanged, except in a mode that `usesTransparency`, where it's capped at the (clamped) `xrayOpacity`. A body whose result is below 1 is drawn in the translucent pass.

#### `drawsEdges(bodyHasMesh:)`

```swift
public func drawsEdges(bodyHasMesh: Bool) -> Bool
```

Whether a body's edges are drawn, and written to the pick buffer, in this mode: `showsEdges`, or always for a body with no surface mesh, which would otherwise be invisible.

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

### Shading model

Surfaces are shaded with a metallic-roughness **Cook-Torrance** BRDF (GGX normal distribution, Smith geometry, Schlick Fresnel), not Blinn-Phong. Highlight size and sharpness come from each body's material (`ViewportBody.roughness`/`metallic`, or `PBRMaterial`), so the configuration has no shininess exponent. On top of the three direct lights the shader adds:

- **Hemisphere ambient**: `ambientGroundColor` → `ambientSkyColor` by how far the normal points up, blended with two fixed side tints, then multiplied by `ambientColor × ambientIntensity / 0.25` (so `.threePoint`'s 0.25 is the reference level and 0 removes ambient). The world is **Z-up**: faces pointing +Z take the sky colour.
- **Environment reflection**: image-based lighting when an environment map is loaded, otherwise a procedural ground→horizon→sky gradient, also Z-up.
- **Fresnel rim**, **matcap** blend, **PCSS shadows** on the direct light, **SSAO**, and screen-space curvature shading.

`specularIntensity` scales the direct-light GGX highlights (0.5 = the physically based lobe). It does not touch environment reflections.

### Stored Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `keyLight` | `LightSettings` | (required) | Main directional light — typically the dominant, warm source |
| `fillLight` | `LightSettings` | (required) | Secondary softer light to reduce shadow harshness |
| `backLight` | `LightSettings` | (required) | Rim/kicker light for edge definition |
| `ambientIntensity` | `Float` | `0.3` | Hemisphere ambient strength, relative to 0.25 (the `.threePoint` reference level); 0 removes ambient |
| `ambientColor` | `SIMD3<Float>` | `(1,1,1)` | Tint multiplied into the hemisphere ambient |
| `shadowsEnabled` | `Bool` | `true` | Master switch for the shadow-map pass |
| `shadowSoftness` | `Float` | `0.3` | **Deprecated, ignored.** PCSS softness comes from `shadowLightSize` |
| `shadowMapSize` | `Int` | `2048` | Shadow map resolution in pixels (width = height), spread over the world-space bounds of the visible `.geometry`-layer bodies; `.overlay` bodies neither cast into nor enlarge the shadow frustum |
| `shadowIntensity` | `Float` | `0.4` | Opacity of cast shadows (0 = invisible, 1 = opaque) |
| `shadowBias` | `Float` | `0.005` | Depth bias to prevent shadow acne |
| `specularPower` | `Float` | `64.0` | **Deprecated, ignored.** Shading is GGX; set the body's `roughness` (or `PBRMaterial.roughness`) to tighten highlights |
| `specularIntensity` | `Float` | `0.5` | Scales the direct-light GGX highlights: 0 = none, 0.5 = physically based, 1 = double |
| `fresnelPower` | `Float` | `3.0` | Fresnel rim falloff exponent |
| `fresnelIntensity` | `Float` | `0.3` | Fresnel rim brightness (0–1) |
| `matcapBlend` | `Float` | `0.0` | Matcap blend factor (0 = pure lighting, 1 = pure matcap) |
| `ambientSkyColor` | `SIMD3<Float>` | `(0.9,0.95,1.0)` | Hemisphere ambient — colour for normals pointing up (+Z) |
| `ambientGroundColor` | `SIMD3<Float>` | `(0.3,0.25,0.2)` | Hemisphere ambient — colour for normals pointing down (−Z) |
| `enableSSAO` | `Bool` | `true` | Enable screen-space ambient occlusion |
| `ssaoRadius` | `Float` | `0.5` | SSAO sampling radius in view-space units |
| `ssaoIntensity` | `Float` | `0.6` | SSAO darkening intensity (0 = none, 1 = maximum) |
| `exposure` | `Float` | `1.1` | Tone-mapping exposure multiplier |
| `whitePoint` | `Float` | `1.0` | White point for tone-mapping normalization |
| `shadowLightSize` | `Float` | `0.02` | PCSS light-source size (larger = softer penumbras) |
| `shadowSearchRadius` | `Float` | `0.01` | PCSS blocker-search radius in light-space UV |
| `environmentMapData` | `Data?` | `nil` | Legacy raw-bytes HDR: `Int32 width \| Int32 height \| RGBA32Float pixels`. Loaded automatically by both renderers when it changes; cleared when set back to `nil` |
| `environmentMapURL` | `URL?` | `nil` | File URL to a Radiance `.hdr` file; takes precedence over `environmentMapData`. Loaded automatically like it; a file that fails to decode is skipped |
| `environmentIntensity` | `Float` | `1.0` | IBL contribution multiplier |
| `environmentRotationY` | `Float` | `0` | Rotation of the environment about the world up axis (Z) in radians (0…2π). The panorama's horizon lies in the XY plane |
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

Soft neutral studio lighting. All three lights are pure white; key intensity 0.8, fill 0.5, back 0.4. `ambientIntensity` 0.35, `specularIntensity` 0.6, `matcapBlend` 0.15. Good for product visualisation.

```swift
controller.lightingConfiguration = .studio
```

#### `architectural`

```swift
public static let architectural: LightingConfiguration
```

Outdoor sun-sky simulation. Warm key (intensity 1.2, colour `(1.0, 0.95, 0.9)`), sky-blue fill (intensity 0.3), light back kicker (intensity 0.2). `ambientIntensity` 0.2. Good for architectural visualisation.

```swift
controller.lightingConfiguration = .architectural
```

#### `flat`

```swift
public static let flat: LightingConfiguration
```

Technical flat lighting. Single on-axis key (direction `(0, 0, -1)`, intensity 0.8); fill and back lights are disabled (intensity 0.0). `ambientIntensity` 0.3, shadows off, specular and Fresnel both 0.0, `exposure` 0.9. Closest to a 2D technical drawing look.

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
