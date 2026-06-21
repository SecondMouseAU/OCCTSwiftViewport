---
title: Materials
parent: API Reference
---

# Materials

Four types handle PBR material authoring, preset management, and HDR environment map loading:
`PBRMaterial` holds the raw parameter set; `NamedMaterial` wraps it with identity for display and
persistence; `MaterialLibrary` manages the full in-memory and on-disk catalogue; `HDRLoader`
decodes Radiance RGBE files into linear-float pixel arrays for `MTLTexture` upload.

## Topics

- [PBRMaterial](#pbrmaterial) · [NamedMaterial](#namedmaterial) · [MaterialLibrary](#materiallibrary) · [HDRLoader](#hdrloader)

---

## PBRMaterial

```swift
public struct PBRMaterial: Sendable, Codable, Hashable
```

glTF 2.0 metallic-roughness material with optional KHR_materials_clearcoat and
KHR_materials_emissive_strength extensions. When `clearcoat == 0` the model reduces to standard
glTF metallic-roughness. All values are in linear space.

### `init(baseColor:metallic:roughness:ior:clearcoat:clearcoatRoughness:emissive:emissiveStrength:opacity:)`

```swift
public init(
    baseColor:          SIMD3<Float> = SIMD3<Float>(0.8, 0.8, 0.8),
    metallic:           Float        = 0,
    roughness:          Float        = 0.5,
    ior:                Float        = 1.5,
    clearcoat:          Float        = 0,
    clearcoatRoughness: Float        = 0.03,
    emissive:           SIMD3<Float> = SIMD3<Float>(0, 0, 0),
    emissiveStrength:   Float        = 1,
    opacity:            Float        = 1
)
```

All parameters have defaults — a zero-argument call produces a mid-grey dielectric with roughness 0.5.

```swift
// Custom anodised aluminium
let material = PBRMaterial(
    baseColor: SIMD3<Float>(0.30, 0.35, 0.40),
    metallic: 1,
    roughness: 0.20
)
```

---

### Properties

#### `baseColor`

```swift
public var baseColor: SIMD3<Float>
```

Albedo in linear RGB. Acts as diffuse tint for dielectrics (`metallic == 0`) and as the F0
specular colour for metals (`metallic == 1`). Default `(0.8, 0.8, 0.8)`.

#### `metallic`

```swift
public var metallic: Float
```

0 = dielectric, 1 = full metal. In-between values are physically undefined but produce smooth
visual transitions. Default `0`.

#### `roughness`

```swift
public var roughness: Float
```

Perceptual roughness. 0 = mirror, 1 = fully diffuse. Squared internally before use in the GGX
NDF. Default `0.5`.

#### `ior`

```swift
public var ior: Float
```

Index of refraction for dielectrics. Drives F0 = `((ior−1)/(ior+1))²`. Ignored when
`metallic >= 1`. Default `1.5` (plastic / glass).

#### `clearcoat`

```swift
public var clearcoat: Float
```

Clearcoat layer weight. 0 = no coat, 1 = full polyurethane-like coat. Default `0`.

#### `clearcoatRoughness`

```swift
public var clearcoatRoughness: Float
```

Roughness of the clearcoat layer, independent of base `roughness`. Default `0.03` (near-mirror
coat typical of automotive lacquer).

#### `emissive`

```swift
public var emissive: SIMD3<Float>
```

Linear RGB self-emission colour. Multiplied by `emissiveStrength` before tonemapping.
Default `(0, 0, 0)`.

#### `emissiveStrength`

```swift
public var emissiveStrength: Float
```

Emissive intensity multiplier. Values greater than 1 produce true HDR bloom-capable emission.
Default `1`.

#### `opacity`

```swift
public var opacity: Float
```

Surface opacity. `1` = fully opaque; less than `1` alpha-blends the surface against whatever
is behind it. This is not optical transmission — use it for ghost-style overlays.
Default `1`.

---

### Presets

#### `static let presets: [String: PBRMaterial]`

```swift
public static let presets: [String: PBRMaterial]
```

Twelve built-in materials keyed by stable lowercase identifiers. Keys are safe to store in
serialised assets across releases.

| Key                  | baseColor (R, G, B)        | metallic | roughness | Notes                          |
|----------------------|----------------------------|----------|-----------|--------------------------------|
| `"steel"`            | (0.56, 0.57, 0.58)         | 1        | 0.35      |                                |
| `"brushedAluminum"`  | (0.91, 0.92, 0.92)         | 1        | 0.55      |                                |
| `"brass"`            | (0.91, 0.78, 0.42)         | 1        | 0.30      |                                |
| `"copper"`           | (0.95, 0.64, 0.54)         | 1        | 0.30      |                                |
| `"chromedSteel"`     | (0.78, 0.78, 0.78)         | 1        | 0.05      | near-mirror chrome             |
| `"gold"`             | (1.00, 0.78, 0.34)         | 1        | 0.20      |                                |
| `"titanium"`         | (0.62, 0.61, 0.59)         | 1        | 0.45      |                                |
| `"plasticGlossy"`    | (0.20, 0.30, 0.55)         | 0        | 0.25      | ior 1.5                        |
| `"plasticMatte"`     | (0.55, 0.55, 0.55)         | 0        | 0.85      | ior 1.5                        |
| `"paintedAutomotive"`| (0.70, 0.05, 0.05)         | 0        | 0.65      | clearcoat 1, ccRoughness 0.04  |
| `"rubber"`           | (0.04, 0.04, 0.04)         | 0        | 0.95      | ior 1.5                        |
| `"glass"`            | (0.95, 0.97, 0.98)         | 0        | 0.05      | ior 1.5, opacity 0.3           |

```swift
// Look up by key
if let m = PBRMaterial.presets["brass"] {
    body.material = m
}
```

#### Static accessors

Convenience typed properties backed by `presets`. Safe to use directly — they crash only if the
preset table is edited without updating these accessors, which never happens in a release build.

```swift
public static var steel:             PBRMaterial { get }
public static var brushedAluminum:   PBRMaterial { get }
public static var brass:             PBRMaterial { get }
public static var copper:            PBRMaterial { get }
public static var chromedSteel:      PBRMaterial { get }
public static var gold:              PBRMaterial { get }
public static var titanium:          PBRMaterial { get }
public static var plasticGlossy:     PBRMaterial { get }
public static var plasticMatte:      PBRMaterial { get }
public static var paintedAutomotive: PBRMaterial { get }
public static var rubber:            PBRMaterial { get }
public static var glass:             PBRMaterial { get }
```

```swift
// Assign a preset directly
var body = ViewportBody(vertices: pts, normals: nrm, edges: [])
body.material = .chromedSteel

// Start from a preset and tweak
var custom = PBRMaterial.steel
custom.roughness = 0.10   // more polished
```

---

### Codable

`PBRMaterial` conforms to `Codable`. `SIMD3<Float>` fields are encoded as three-element `[Float]`
arrays. Fields added in future versions (`ior`, `clearcoat`, `clearcoatRoughness`,
`emissiveStrength`, `opacity`) decode with their default values when absent, so existing JSON
assets remain forward-compatible.

---

## NamedMaterial

```swift
public struct NamedMaterial: Sendable, Codable, Identifiable, Hashable
```

A `PBRMaterial` with a stable `UUID` identity, a user-visible `name`, and a flag marking
whether it is a built-in preset. Used throughout `MaterialLibrary` as the unit of storage,
display, and persistence.

### `init(id:name:material:isBuiltin:)`

```swift
public init(
    id:        UUID         = UUID(),
    name:      String,
    material:  PBRMaterial,
    isBuiltin: Bool         = false
)
```

The `id` defaults to a fresh `UUID()`. Pass an explicit `id` only when round-tripping from
persisted JSON.

```swift
let custom = NamedMaterial(
    name: "Brushed Titanium",
    material: PBRMaterial(
        baseColor: SIMD3<Float>(0.55, 0.54, 0.52),
        metallic: 1,
        roughness: 0.40
    )
)
```

### Properties

#### `id`

```swift
public let id: UUID
```

Stable identity across sessions when the material is persisted and reloaded.

#### `name`

```swift
public var name: String
```

User-visible display name. Mutable so the user can rename custom materials in a UI.

#### `material`

```swift
public var material: PBRMaterial
```

The underlying PBR parameters.

#### `isBuiltin`

```swift
public var isBuiltin: Bool
```

`true` for the twelve presets loaded from `PBRMaterial.presets`. Built-in materials are
protected from deletion in `MaterialLibrary.remove(id:)`.

---

## MaterialLibrary

```swift
@MainActor
public final class MaterialLibrary: ObservableObject
```

In-memory and on-disk registry of `NamedMaterial` values. Built-in presets are always loaded
fresh from `PBRMaterial.presets` at init; user-authored materials are persisted as JSON in
Application Support and merged at startup. The `@Published` `materials` array drives SwiftUI
material-picker views directly.

### `init(storageURL:)`

```swift
public init(storageURL: URL? = MaterialLibrary.defaultStorageURL())
```

Creates the library. If `storageURL` is non-nil and a valid JSON file exists there, user
materials are loaded from it and appended after the bundled presets. Pass `nil` to disable
persistence (useful in previews and tests).

```swift
// Default (persists to Application Support)
let library = await MaterialLibrary()

// In-memory only (no disk I/O)
let previewLibrary = await MaterialLibrary(storageURL: nil)
```

### `@Published var materials: [NamedMaterial]`

```swift
@Published public private(set) var materials: [NamedMaterial]
```

All materials in display order: bundled presets first, then user materials in save order.
Observable — bind directly to a `List` or `Picker`.

```swift
// SwiftUI picker
Picker("Material", selection: $selectedID) {
    ForEach(library.materials) { named in
        Text(named.name).tag(named.id)
    }
}
```

### `static func bundledPresets() -> [NamedMaterial]`

```swift
public static func bundledPresets() -> [NamedMaterial]
```

Returns the twelve built-in `NamedMaterial` values in canonical display order (steel through
glass), with human-readable names derived by inserting spaces at camel-case boundaries
(`"brushedAluminum"` → `"Brushed Aluminum"`). Each has `isBuiltin: true`.

```swift
let presets = MaterialLibrary.bundledPresets()
print(presets.map(\.name))
// ["Steel", "Brushed Aluminum", "Brass", "Copper", "Chromed Steel",
//  "Gold", "Titanium", "Plastic Glossy", "Plastic Matte",
//  "Painted Automotive", "Rubber", "Glass"]
```

### `static func defaultStorageURL() -> URL?`

```swift
public static func defaultStorageURL() -> URL?
```

Returns `<ApplicationSupport>/OCCTSwiftViewport/materials.json`, creating the directory if
needed. Returns `nil` if the Application Support directory cannot be resolved.

```swift
if let url = MaterialLibrary.defaultStorageURL() {
    print(url.path)
    // e.g. ~/Library/Application Support/OCCTSwiftViewport/materials.json
}
```

### `func saveUserMaterial(_:)`

```swift
public func saveUserMaterial(_ named: NamedMaterial)
```

Adds `named` to `materials` and persists to disk. If a material with the same `id` already
exists it is replaced in-place; otherwise it is appended. Persistence errors are silently
swallowed — the in-memory state is always updated.

```swift
let edited = NamedMaterial(
    id: existing.id,          // same id = replace
    name: "My Steel",
    material: custom
)
library.saveUserMaterial(edited)
```

### `func remove(id:)`

```swift
public func remove(id: UUID)
```

Removes the material with the given `id` from `materials` and persists. Built-in materials
(`isBuiltin == true`) are silently ignored — they cannot be deleted.

```swift
library.remove(id: custom.id)
```

### `func material(byID:)`

```swift
public func material(byID id: UUID) -> NamedMaterial?
```

Returns the first material whose `id` matches, or `nil` if not found.

```swift
if let named = library.material(byID: selectedID) {
    body.material = named.material
}
```

---

## HDRLoader

```swift
public enum HDRLoader
```

Namespace (caseless enum) for decoding Radiance RGBE environment map files into linear
`RGBA32Float` pixel arrays. The output is ready for direct upload to `MTLTexture` with pixel
format `.rgba32Float`. Pixel order is left-to-right, top-to-bottom (standard Y-down layout).

### `enum LoadError`

```swift
public enum LoadError: Error, CustomStringConvertible {
    case invalidHeader
    case unsupportedFormat(String)
    case truncated
    case invalidScanline
}
```

| Case | Meaning |
|------|---------|
| `invalidHeader` | Magic string absent or resolution line malformed |
| `unsupportedFormat(String)` | `FORMAT=` header or file extension not recognised |
| `truncated` | Byte stream ends before all scanlines are decoded |
| `invalidScanline` | RLE scanline marker width mismatches the declared image width (old RLE / non-standard ordering not supported) |

### `static func loadFromURL(_:)`

```swift
public static func loadFromURL(_ url: URL) throws -> (width: Int, height: Int, pixels: [Float])
```

Loads an HDR environment map from a file URL, dispatching to the correct decoder by extension.

**Supported extensions:** `.hdr`, `.rgbe`, `.pic` (all Radiance RGBE format).

- **Returns:** A tuple of `(width, height, pixels)` where `pixels` is a flat `[Float]` array
  of length `width × height × 4` in RGBA interleaved order, alpha always `1.0`.
- **Throws:** `LoadError` for format, header, or stream errors; `Data` / I/O errors from
  `Data(contentsOf:)` for missing or unreadable files.

```swift
guard let url = Bundle.main.url(forResource: "studio", withExtension: "hdr") else { return }
do {
    let (width, height, pixels) = try HDRLoader.loadFromURL(url)
    // Upload to MTLTexture
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float,
        width: width,
        height: height,
        mipmapped: false
    )
    if let texture = device.makeTexture(descriptor: descriptor) {
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size
        )
    }
} catch {
    print("HDR load failed: \(error)")
}
```

### `static func loadRGBE(_:)`

```swift
public static func loadRGBE(_ data: Data) throws -> (width: Int, height: Int, pixels: [Float])
```

Decodes Radiance RGBE bytes already in memory. Useful when the file data is fetched from a
bundle resource, a network response, or in-memory assets.

Accepts files with `FORMAT=32-bit_rle_rgbe` or `FORMAT=32-bit_rle_xyze`; other FORMAT values
throw `.unsupportedFormat`. Only modern per-channel RLE (`(2, 2, hi, lo)` scanline marker) is
supported; old/uncompressed RLE throws `.invalidScanline`.

- **Returns:** Same `(width, height, pixels)` as `loadFromURL(_:)`.
- **Throws:** `LoadError`.

```swift
let data = try Data(contentsOf: someURL)
if let (w, h, px) = try? HDRLoader.loadRGBE(data) {
    print("Decoded \(w)×\(h) HDR image")
}
```
