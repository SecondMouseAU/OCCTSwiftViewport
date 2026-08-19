// LightingConfiguration.swift
// ViewportKit
//
// Lighting presets and configuration for 3D scenes.

import Foundation
import simd

/// Configuration for scene lighting.
///
/// Defines light positions, intensities, and colors for consistent
/// CAD visualization lighting.
public struct LightingConfiguration: Sendable {

    // MARK: - Properties

    /// Key light (main directional light).
    public var keyLight: LightSettings

    /// Fill light (secondary, softer light).
    public var fillLight: LightSettings

    /// Back/rim light (for edge definition).
    public var backLight: LightSettings

    /// Ambient light intensity (0-1).
    public var ambientIntensity: Float

    /// Ambient light color.
    public var ambientColor: SIMD3<Float>

    /// Whether shadows are enabled.
    public var shadowsEnabled: Bool

    /// Shadow softness (0 = hard, 1 = soft).
    public var shadowSoftness: Float

    /// Shadow map resolution (width and height in pixels).
    public var shadowMapSize: Int

    /// Shadow intensity (0 = no shadow, 1 = fully opaque).
    public var shadowIntensity: Float

    /// Depth bias to prevent shadow acne.
    public var shadowBias: Float

    /// Specular shininess exponent (higher = tighter highlight).
    public var specularPower: Float

    /// Specular highlight strength (0–1).
    public var specularIntensity: Float

    /// Fresnel rim falloff exponent.
    public var fresnelPower: Float

    /// Fresnel rim brightness (0–1).
    public var fresnelIntensity: Float

    /// Matcap blend factor (0 = pure lighting, 1 = pure matcap).
    public var matcapBlend: Float

    /// Hemisphere ambient sky color (upper hemisphere).
    public var ambientSkyColor: SIMD3<Float>

    /// Hemisphere ambient ground color (lower hemisphere).
    public var ambientGroundColor: SIMD3<Float>

    /// Whether screen-space ambient occlusion is enabled.
    public var enableSSAO: Bool

    /// SSAO sampling radius in view-space units.
    public var ssaoRadius: Float

    /// SSAO darkening intensity (0 = none, 1 = maximum).
    public var ssaoIntensity: Float

    /// Tone mapping exposure multiplier (default 1.1).
    public var exposure: Float

    /// White point for tone mapping normalization (default 1.0).
    public var whitePoint: Float

    /// PCSS light source size (larger = softer shadow penumbras).
    public var shadowLightSize: Float

    /// PCSS blocker search radius in light-space UV.
    public var shadowSearchRadius: Float

    /// Equirectangular environment map as raw bytes, or nil to fall back to the procedural sky.
    ///
    /// The legacy in-memory path, laid out as `Int32 width | Int32 height | RGBA32Float pixels`.
    /// Prefer `environmentMapURL` for `.hdr` files, which decodes them for you.
    public var environmentMapData: Data?

    /// File URL of a Radiance `.hdr` environment map, decoded through `HDRLoader`.
    ///
    /// Takes precedence over `environmentMapData` when both are set.
    public var environmentMapURL: URL?

    /// Environment map intensity multiplier, scaling the IBL contribution to lighting.
    public var environmentIntensity: Float

    /// Y-axis rotation of the environment, in radians.
    ///
    /// Turns the reflections and image-based lighting without moving scene geometry, so it
    /// aims the environment rather than the model. Typically 0...2π.
    public var environmentRotationY: Float

    /// Exposure of the visible sky background, separate from how brightly it lights the scene.
    ///
    /// Independent of `environmentIntensity`, so the background can be pulled down to a black
    /// product-shot backdrop while the environment keeps lighting the model.
    public var backgroundExposure: Float

    /// Whether the environment is drawn as a skybox behind the scene.
    ///
    /// When off, the background is the solid clear colour instead; the cubemap still lights
    /// the scene either way.
    public var drawBackground: Bool

    // MARK: - Initialization

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
    ) {
        self.keyLight = keyLight
        self.fillLight = fillLight
        self.backLight = backLight
        self.ambientIntensity = ambientIntensity
        self.ambientColor = ambientColor
        self.shadowsEnabled = shadowsEnabled
        self.shadowSoftness = shadowSoftness
        self.shadowMapSize = shadowMapSize
        self.shadowIntensity = shadowIntensity
        self.shadowBias = shadowBias
        self.specularPower = specularPower
        self.specularIntensity = specularIntensity
        self.fresnelPower = fresnelPower
        self.fresnelIntensity = fresnelIntensity
        self.matcapBlend = matcapBlend
        self.ambientSkyColor = ambientSkyColor
        self.ambientGroundColor = ambientGroundColor
        self.enableSSAO = enableSSAO
        self.ssaoRadius = ssaoRadius
        self.ssaoIntensity = ssaoIntensity
        self.exposure = exposure
        self.whitePoint = whitePoint
        self.shadowLightSize = shadowLightSize
        self.shadowSearchRadius = shadowSearchRadius
        self.environmentMapData = environmentMapData
        self.environmentMapURL = environmentMapURL
        self.environmentIntensity = environmentIntensity
        self.environmentRotationY = environmentRotationY
        self.backgroundExposure = backgroundExposure
        self.drawBackground = drawBackground
    }

    // MARK: - Presets

    /// Standard three-point lighting for CAD.
    ///
    /// Provides clear definition of form with:
    /// - Key light from upper-right-front
    /// - Fill light from left to soften shadows
    /// - Back light for edge definition
    public static let threePoint = LightingConfiguration(
        keyLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(-0.5, -0.6, -0.6)),  // Higher elevation (30-45°)
            intensity: 1.0,
            color: SIMD3<Float>(1.0, 0.96, 0.90)  // Warmer key
        ),
        fillLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.6, -0.1, -0.5)),  // Slight downward angle
            intensity: 0.4,
            color: SIMD3<Float>(0.85, 0.92, 1.0)  // Cooler fill for contrast
        ),
        backLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.2, 0.8, 0.5)),  // From below-behind (kicker)
            intensity: 0.35,
            color: SIMD3<Float>(0.95, 0.97, 1.0)
        ),
        ambientIntensity: 0.25,
        shadowIntensity: 0.2,
        specularPower: 64.0,
        specularIntensity: 0.5,
        fresnelIntensity: 0.35,
        ssaoRadius: 0.8,
        ssaoIntensity: 0.8
    )

    /// Soft studio lighting.
    public static let studio = LightingConfiguration(
        keyLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(-0.3, -0.4, -0.8)),
            intensity: 0.8,
            color: SIMD3<Float>(1.0, 1.0, 1.0)
        ),
        fillLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.5, 0.2, -0.6)),
            intensity: 0.5,
            color: SIMD3<Float>(1.0, 1.0, 1.0)
        ),
        backLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.0, 0.6, 0.6)),
            intensity: 0.4,
            color: SIMD3<Float>(1.0, 1.0, 1.0)
        ),
        ambientIntensity: 0.35,
        shadowsEnabled: true,
        shadowSoftness: 0.5,
        specularPower: 32.0,
        specularIntensity: 0.6,
        fresnelIntensity: 0.4,
        matcapBlend: 0.15
    )

    /// Architectural visualization lighting (simulates outdoor).
    public static let architectural = LightingConfiguration(
        keyLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(-0.4, -0.5, -0.7)),
            intensity: 1.2,
            color: SIMD3<Float>(1.0, 0.95, 0.9)  // Warm sunlight
        ),
        fillLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.5, 0.3, -0.4)),
            intensity: 0.3,
            color: SIMD3<Float>(0.8, 0.9, 1.0)  // Sky blue fill
        ),
        backLight: LightSettings(
            direction: simd_normalize(SIMD3<Float>(0.1, 0.7, 0.5)),
            intensity: 0.2,
            color: SIMD3<Float>(0.9, 0.95, 1.0)
        ),
        ambientIntensity: 0.2,
        shadowsEnabled: true,
        shadowSoftness: 0.2
    )

    /// Flat lighting for technical visualization.
    public static let flat = LightingConfiguration(
        keyLight: LightSettings(
            direction: SIMD3<Float>(0, 0, -1),
            intensity: 0.8,
            color: SIMD3<Float>(1, 1, 1)
        ),
        fillLight: LightSettings(
            direction: SIMD3<Float>(0, 0, -1),
            intensity: 0.0,
            color: SIMD3<Float>(1, 1, 1)
        ),
        backLight: LightSettings(
            direction: SIMD3<Float>(0, 0, 1),
            intensity: 0.0,
            color: SIMD3<Float>(1, 1, 1)
        ),
        ambientIntensity: 0.6,
        shadowsEnabled: false,
        specularIntensity: 0.0,
        fresnelIntensity: 0.0,
        exposure: 0.9
    )
}

// MARK: - Light Type

/// Type of light source.
public enum LightType: Sendable, Equatable {
    /// Directional light (sun-like, no falloff).
    case directional
    /// Point light with smooth radius falloff.
    case point(radius: Float)
}

// MARK: - Light Settings

/// Settings for a single light source.
public struct LightSettings: Sendable {
    /// Normalized direction the light points, for directional lights.
    ///
    /// Ignored for `.point` lights, which take their direction from the light position
    /// relative to each shaded fragment.
    public var direction: SIMD3<Float>

    /// Light intensity (0-2 typical range).
    public var intensity: Float

    /// Light color (RGB, 0-1 range).
    public var color: SIMD3<Float>

    /// Whether this light is enabled.
    public var isEnabled: Bool

    /// Type of light source.
    public var lightType: LightType

    /// World-space position (used for point lights).
    public var position: SIMD3<Float>

    public init(
        direction: SIMD3<Float>,
        intensity: Float = 1.0,
        color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
        isEnabled: Bool = true,
        lightType: LightType = .directional,
        position: SIMD3<Float> = .zero
    ) {
        self.direction = direction
        self.intensity = intensity
        self.color = color
        self.isEnabled = isEnabled
        self.lightType = lightType
        self.position = position
    }
}
