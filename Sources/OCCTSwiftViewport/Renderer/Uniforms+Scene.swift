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
    ///   - lighting: Light and material configuration for the frame.
    ///   - lightViewProjection: Shadow-pass light matrix, or the identity when shadows are off.
    ///   - shadowParams: bias, intensity, enabled flag, edge intensity.
    ///   - shadowParams2: PCSS light size, search radius, and renderer-specific debug flags.
    ///   - iblParams: Environment-map intensity, rotation, background exposure, presence flag.
    ///   - clipPlanes: Up to four active section planes.
    ///   - clipPlaneCount: How many entries of `clipPlanes` are active.
    ///   - unlit: Whether the unlit display mode is active (skips lighting and tone mapping).
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
        unlit: Bool
    ) {
        self.init(
            viewProjectionMatrix: viewProjection,
            modelMatrix: matrix_identity_float4x4,
            viewMatrix: viewMatrix,
            cameraPosition: SIMD4<Float>(cameraPosition, nearPlane),
            light0: LightDataSwift(lighting.keyLight),
            light1: LightDataSwift(lighting.fillLight),
            light2: LightDataSwift(lighting.backLight),
            ambientSkyColor: SIMD4<Float>(lighting.ambientSkyColor, lighting.specularPower),
            ambientGroundColor: SIMD4<Float>(
                lighting.ambientGroundColor, lighting.specularIntensity),
            materialParams: SIMD4<Float>(
                lighting.fresnelPower, lighting.fresnelIntensity, lighting.matcapBlend, farPlane),
            lightViewProjectionMatrix: lightViewProjection,
            shadowParams: shadowParams,
            shadowParams2: shadowParams2,
            iblParams: iblParams,
            clipPlanes: clipPlanes,
            clipPlaneCount: clipPlaneCount,
            unlit: unlit ? 1 : 0
        )
    }
}
