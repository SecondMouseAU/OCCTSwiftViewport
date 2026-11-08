// Uniforms+Scene.swift
// OCCTSwiftViewport
//
// Scene-level uniform packing shared by ViewportRenderer and OffscreenRenderer.
// The struct definitions themselves live in ViewportRenderer.swift, alongside the
// Swift-Metal sync note they share with Renderer/Shaders.metal.

import simd

extension LightDataSwift {

    /// Packs one configured light into its shader representation.
    init(_ light: LightSettings) {
        let typeValue: Float
        let radiusValue: Float
        switch light.lightType {
        case .directional:
            typeValue = 0.0
            radiusValue = 0.0
        case .point(let radius):
            typeValue = 1.0
            radiusValue = radius
        }
        self.init(
            directionAndIntensity: SIMD4<Float>(light.direction, light.intensity),
            colorAndEnabled: SIMD4<Float>(light.color, light.isEnabled ? 1.0 : 0.0),
            typeAndParams: SIMD4<Float>(typeValue, radiusValue, 0, 0),
            positionAndPad: SIMD4<Float>(light.position, 0)
        )
    }
}

extension Uniforms {

    /// The `ambientIntensity` that reproduces the hard-coded ambient the shader used before
    /// `ambientIntensity` was wired in: the default `.threePoint` preset's value.
    nonisolated static let referenceAmbientIntensity: Float = 0.25

    /// The `specularIntensity` at which the GGX specular lobe is left at its physically based
    /// strength: the `LightingConfiguration` default.
    nonisolated static let referenceSpecularIntensity: Float = 0.5

    /// Packs the global ambient and specular controls into `lightingScales`.
    ///
    /// `rgb` multiplies the shader's hemisphere ambient: `ambientColor × ambientIntensity`,
    /// normalised so `.threePoint` (white, 0.25) is exactly 1 and keeps its look. `w` multiplies
    /// the direct-light GGX specular: `specularIntensity / 0.5`, so 0 removes highlights and the
    /// default 0.5 is the unscaled, physically based lobe. Negative inputs clamp to 0.
    ///
    /// With a loaded environment map (`iblParams.w > 0.5`) and `environmentReplacesAmbient`, the
    /// ambient is also multiplied by `1 - environmentIntensity` (`iblParams.x`), clamped at 0, so
    /// the map's diffuse irradiance replaces the hemisphere ambient instead of stacking on it
    /// (#168). Without a map the factor is 1.
    nonisolated static func lightingScales(
        for lighting: LightingConfiguration, iblParams: SIMD4<Float> = .zero
    ) -> SIMD4<Float> {
        var ambient =
            simd_max(lighting.ambientColor, .zero)
            * (max(lighting.ambientIntensity, 0) / referenceAmbientIntensity)
        if iblParams.w > 0.5 && lighting.environmentReplacesAmbient {
            ambient *= max(1 - iblParams.x, 0)
        }
        let specular = max(lighting.specularIntensity, 0) / referenceSpecularIntensity
        return SIMD4<Float>(ambient, specular)
    }

    /// Packs a tint style for the shader: clamped sRGB colour in `rgb`, mix amount in `w`.
    nonisolated static func packedTint(_ tint: SelectionTintStyle) -> SIMD4<Float> {
        SIMD4<Float>(
            simd_clamp(tint.color, .zero, SIMD3<Float>(repeating: 1)),
            min(max(tint.strength, 0), 1))
    }

    /// Builds the per-frame scene uniforms both renderers hand to the shaders.
    ///
    /// `modelMatrix` starts out as the identity; callers overwrite it per body.
    ///
    /// - Parameters:
    ///   - viewProjection: Combined projection × view matrix for this frame.
    ///   - viewMatrix: The camera's view matrix.
    ///   - cameraPosition: World-space camera position.
    ///   - nearPlane: Near clip distance, packed into `cameraPosition.w`.
    ///   - farPlane: Far clip distance, packed into `materialParams.w`.
    ///   - lighting: Light and material configuration for the frame, including the tone-mapping
    ///     `exposure` and `whitePoint` that `shaded_fragment` applies to every lit surface.
    ///   - lightViewProjection: Shadow-pass light matrix, or the identity when shadows are off.
    ///   - shadowParams: bias, intensity, enabled flag, edge intensity.
    ///   - shadowParams2: PCSS light size, search radius, and renderer-specific debug flags.
    ///   - iblParams: Environment-map intensity, rotation, background exposure, presence flag.
    ///   - clipPlanes: Up to four active section planes.
    ///   - clipPlaneCount: How many entries of `clipPlanes` are active.
    ///   - unlit: Whether the unlit display mode is active (skips lighting and tone mapping).
    ///   - flatShading: Whether to light each triangle with its face normal (`.flat`). Ignored
    ///     when `unlit` is set.
    ///   - selectionTint: Surface tint of selected bodies.
    ///   - hoverTint: Surface tint of the hovered body.
    init(
        viewProjection: simd_float4x4,
        viewMatrix: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        nearPlane: Float,
        farPlane: Float,
        lighting: LightingConfiguration,
        lightViewProjection: simd_float4x4,
        shadowParams: SIMD4<Float>,
        shadowParams2: SIMD4<Float>,
        iblParams: SIMD4<Float> = .zero,
        clipPlanes: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (
            .zero, .zero, .zero, .zero
        ),
        clipPlaneCount: UInt32 = 0,
        unlit: Bool,
        flatShading: Bool = false,
        selectionTint: SelectionTintStyle = .selection,
        hoverTint: SelectionTintStyle = .hover
    ) {
        self.init(
            viewProjectionMatrix: viewProjection,
            modelMatrix: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            cameraPosition: SIMD4<Float>(cameraPosition, nearPlane),
            light0: LightDataSwift(lighting.keyLight),
            light1: LightDataSwift(lighting.fillLight),
            light2: LightDataSwift(lighting.backLight),
            ambientSkyColor: SIMD4<Float>(lighting.ambientSkyColor, 0),
            ambientGroundColor: SIMD4<Float>(lighting.ambientGroundColor, 0),
            lightingScales: Self.lightingScales(for: lighting, iblParams: iblParams),
            materialParams: SIMD4<Float>(
                lighting.fresnelPower, lighting.fresnelIntensity, lighting.matcapBlend, farPlane),
            lightViewProjectionMatrix: lightViewProjection,
            shadowParams: shadowParams,
            shadowParams2: shadowParams2,
            iblParams: iblParams,
            clipPlanes: clipPlanes,
            clipPlaneCount: clipPlaneCount,
            unlit: unlit ? 1 : (flatShading ? 2 : 0),
            toneMapExposure: lighting.exposure,
            toneMapWhitePoint: lighting.whitePoint,
            ambientAxisTints: (
                SIMD4<Float>(lighting.ambientTintNegativeX, 0),
                SIMD4<Float>(lighting.ambientTintPositiveX, 0),
                SIMD4<Float>(lighting.ambientTintNegativeY, 0),
                SIMD4<Float>(lighting.ambientTintPositiveY, 0)
            ),
            proceduralEnvironment: (
                SIMD4<Float>(lighting.proceduralEnvironmentGroundColor, 0),
                SIMD4<Float>(lighting.proceduralEnvironmentHorizonColor, 0),
                SIMD4<Float>(lighting.proceduralEnvironmentSkyColor, 0)
            ),
            selectionTint: Self.packedTint(selectionTint),
            hoverTint: Self.packedTint(hoverTint)
        )
    }
}
