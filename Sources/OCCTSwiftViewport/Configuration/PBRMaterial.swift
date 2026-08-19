// PBRMaterial.swift
// OCCTSwiftViewport
//
// glTF 2.0 metallic-roughness material model with KHR_materials_clearcoat
// and KHR_materials_emissive_strength extensions.
//
// References:
//   - glTF 2.0 spec §3.9 Materials
//   - KHR_materials_clearcoat
//   - KHR_materials_ior
//   - KHR_materials_emissive_strength
//   - Filament documentation §4.8 (clearcoat layer)

import simd

/// Physically based material parameters.
///
/// Two-lobe model: a metallic-roughness base and an optional polyurethane-like
/// clearcoat layer. When `clearcoat == 0` the material reduces to standard
/// glTF 2.0 metallic-roughness.
public struct PBRMaterial: Sendable, Codable, Hashable {

    /// Base colour in linear RGB, read differently by dielectrics and metals.
    ///
    /// Acts as albedo for dielectrics and as the F0 tint for metals, so the same value reads
    /// as paint on one material and as reflected-light colour on another.
    public var baseColor: SIMD3<Float>

    /// Metalness, from 0 (dielectric) to 1 (metal).
    ///
    /// Values in between are physically meaningless, but useful for transitioning between
    /// two materials.
    public var metallic: Float

    /// Perceptual roughness, from 0 (mirror) to 1 (fully rough).
    ///
    /// Perceptual rather than linear: the shader squares it before feeding GGX, which spreads
    /// the mid-range out over the values the eye actually distinguishes.
    public var roughness: Float

    /// Index of refraction for dielectrics, setting how much light the surface reflects head-on.
    ///
    /// Defaults to 1.5 (plastic, glass), and drives `F0 = ((ior - 1) / (ior + 1))²` for
    /// non-metals. Ignored once `metallic >= 1`, where F0 comes from `baseColor` instead.
    public var ior: Float

    /// Clearcoat layer strength. 0 = no coat, 1 = full coat.
    public var clearcoat: Float

    /// Roughness of the clearcoat layer, independent of the base `roughness`.
    ///
    /// Decoupling the two is what makes car paint work: a rough flake base under a sharp coat.
    public var clearcoatRoughness: Float

    /// Light the surface emits on its own, in linear RGB, before `emissiveStrength` scales it.
    ///
    /// Added after shading and ahead of tonemapping, so it is unaffected by scene lighting.
    public var emissive: SIMD3<Float>

    /// Multiplier on `emissive`, split out so emission can exceed the 0...1 colour range.
    ///
    /// Values above 1 give true HDR emission instead of clipping at the top of that range.
    public var emissiveStrength: Float

    /// Surface opacity. 1 = opaque. <1 alpha-blends; not a substitute for transmission.
    public var opacity: Float

    public init(
        baseColor: SIMD3<Float> = SIMD3<Float>(0.8, 0.8, 0.8),
        metallic: Float = 0,
        roughness: Float = 0.5,
        ior: Float = 1.5,
        clearcoat: Float = 0,
        clearcoatRoughness: Float = 0.03,
        emissive: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
        emissiveStrength: Float = 1,
        opacity: Float = 1
    ) {
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.ior = ior
        self.clearcoat = clearcoat
        self.clearcoatRoughness = clearcoatRoughness
        self.emissive = emissive
        self.emissiveStrength = emissiveStrength
        self.opacity = opacity
    }
}

// MARK: - Codable for SIMD types

extension PBRMaterial {

    private enum CodingKeys: String, CodingKey {
        case baseColor, metallic, roughness, ior
        case clearcoat, clearcoatRoughness
        case emissive, emissiveStrength, opacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bc = try c.decode([Float].self, forKey: .baseColor)
        let em = try c.decode([Float].self, forKey: .emissive)
        guard bc.count == 3, em.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .baseColor, in: c,
                debugDescription: "baseColor and emissive must have 3 components"
            )
        }
        self.init(
            baseColor: SIMD3<Float>(bc[0], bc[1], bc[2]),
            metallic: try c.decode(Float.self, forKey: .metallic),
            roughness: try c.decode(Float.self, forKey: .roughness),
            ior: try c.decodeIfPresent(Float.self, forKey: .ior) ?? 1.5,
            clearcoat: try c.decodeIfPresent(Float.self, forKey: .clearcoat) ?? 0,
            clearcoatRoughness: try c.decodeIfPresent(Float.self, forKey: .clearcoatRoughness)
                ?? 0.03,
            emissive: SIMD3<Float>(em[0], em[1], em[2]),
            emissiveStrength: try c.decodeIfPresent(Float.self, forKey: .emissiveStrength) ?? 1,
            opacity: try c.decodeIfPresent(Float.self, forKey: .opacity) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([baseColor.x, baseColor.y, baseColor.z], forKey: .baseColor)
        try c.encode(metallic, forKey: .metallic)
        try c.encode(roughness, forKey: .roughness)
        try c.encode(ior, forKey: .ior)
        try c.encode(clearcoat, forKey: .clearcoat)
        try c.encode(clearcoatRoughness, forKey: .clearcoatRoughness)
        try c.encode([emissive.x, emissive.y, emissive.z], forKey: .emissive)
        try c.encode(emissiveStrength, forKey: .emissiveStrength)
        try c.encode(opacity, forKey: .opacity)
    }
}

// MARK: - Presets

extension PBRMaterial {

    /// Built-in materials covering the common engineering visualization palette.
    ///
    /// Keyed by stable lowerCamelCase identifiers, so the keys are safe to persist in
    /// serialized assets rather than being re-derived from display names.
    public static let presets: [String: PBRMaterial] = [
        "steel": PBRMaterial(
            baseColor: SIMD3<Float>(0.56, 0.57, 0.58),
            metallic: 1, roughness: 0.35
        ),
        "brushedAluminum": PBRMaterial(
            baseColor: SIMD3<Float>(0.91, 0.92, 0.92),
            metallic: 1, roughness: 0.55
        ),
        "brass": PBRMaterial(
            baseColor: SIMD3<Float>(0.91, 0.78, 0.42),
            metallic: 1, roughness: 0.30
        ),
        "copper": PBRMaterial(
            baseColor: SIMD3<Float>(0.95, 0.64, 0.54),
            metallic: 1, roughness: 0.30
        ),
        "chromedSteel": PBRMaterial(
            baseColor: SIMD3<Float>(0.78, 0.78, 0.78),
            metallic: 1, roughness: 0.05
        ),
        "gold": PBRMaterial(
            baseColor: SIMD3<Float>(1.00, 0.78, 0.34),
            metallic: 1, roughness: 0.20
        ),
        "titanium": PBRMaterial(
            baseColor: SIMD3<Float>(0.62, 0.61, 0.59),
            metallic: 1, roughness: 0.45
        ),
        "plasticGlossy": PBRMaterial(
            baseColor: SIMD3<Float>(0.20, 0.30, 0.55),
            metallic: 0, roughness: 0.25, ior: 1.5
        ),
        "plasticMatte": PBRMaterial(
            baseColor: SIMD3<Float>(0.55, 0.55, 0.55),
            metallic: 0, roughness: 0.85, ior: 1.5
        ),
        "paintedAutomotive": PBRMaterial(
            baseColor: SIMD3<Float>(0.70, 0.05, 0.05),
            metallic: 0, roughness: 0.65, ior: 1.5,
            clearcoat: 1, clearcoatRoughness: 0.04
        ),
        "rubber": PBRMaterial(
            baseColor: SIMD3<Float>(0.04, 0.04, 0.04),
            metallic: 0, roughness: 0.95, ior: 1.5
        ),
        "glass": PBRMaterial(
            baseColor: SIMD3<Float>(0.95, 0.97, 0.98),
            metallic: 0, roughness: 0.05, ior: 1.5,
            opacity: 0.3
        ),
    ]

    /// Named accessor for the `steel` preset.
    ///
    /// This and the accessors below force-unwrap `presets`: every key they name is defined in
    /// the same file as the table, so a missing one is a typo caught on first use rather than
    /// a runtime condition worth handling.
    public static var steel: PBRMaterial { presets["steel"]! }
    public static var brushedAluminum: PBRMaterial { presets["brushedAluminum"]! }
    public static var brass: PBRMaterial { presets["brass"]! }
    public static var copper: PBRMaterial { presets["copper"]! }
    public static var chromedSteel: PBRMaterial { presets["chromedSteel"]! }
    public static var gold: PBRMaterial { presets["gold"]! }
    public static var titanium: PBRMaterial { presets["titanium"]! }
    public static var plasticGlossy: PBRMaterial { presets["plasticGlossy"]! }
    public static var plasticMatte: PBRMaterial { presets["plasticMatte"]! }
    public static var paintedAutomotive: PBRMaterial { presets["paintedAutomotive"]! }
    public static var rubber: PBRMaterial { presets["rubber"]! }
    public static var glass: PBRMaterial { presets["glass"]! }
}
