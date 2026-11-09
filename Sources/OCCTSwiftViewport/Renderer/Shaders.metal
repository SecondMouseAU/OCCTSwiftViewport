// Shaders.metal
// ViewportKit
//
// Metal shaders for shaded and wireframe rendering.

#include <metal_stdlib>
using namespace metal;

// MARK: - Uniform Structs

struct LightData {
    float4 directionAndIntensity;  // xyz = normalized direction, w = intensity
    float4 colorAndEnabled;        // rgb = color, a = 1.0 if enabled, 0.0 if not
    float4 typeAndParams;          // x = type (0=directional, 1=point), y = radius, z/w = unused
    float4 positionAndPad;         // xyz = world position (point lights), w = unused
};

struct Uniforms {
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float4x4 viewMatrix;              // needed for matcap UV calculation
    float4   cameraPosition;           // xyz = position, w = nearPlane
    LightData lights[3];               // key, fill, back
    float4   ambientSkyColor;          // rgb = sky color, w = unused
    float4   ambientGroundColor;       // rgb = ground color, w = unused
    float4   lightingScales;           // rgb = ambient scale (ambientColor × ambientIntensity,
                                       // 1 = the .threePoint look), w = direct specular scale
    float4   materialParams;           // x = fresnelPower, y = fresnelIntensity,
                                       // z = matcapBlend, w = farPlane
    float4x4 lightViewProjectionMatrix; // for shadow mapping
    float4   shadowParams;             // x = bias, y = intensity, z = enabled, w = edgeIntensity
    float4   shadowParams2;            // x = lightSize, y = searchRadius, z/w = unused (PCSS)
    float4   iblParams;                // x = intensity, y = rotationY (radians),
                                       // z = backgroundExposure, w = hasEnvMap (>0.5)
    float4   clipPlanes[4];            // xyz = normal, w = distance (dot(N,P)+w < 0 → clip)
    uint     clipPlaneCount;           // number of active clip planes (0–4)
    uint     unlit;                    // 1 = unlit/flat-colour (skip lighting + tone map),
                                       // 2 = faceted (light with per-triangle face normals)
    float    toneMapExposure;          // LightingConfiguration.exposure
    float    toneMapWhitePoint;        // LightingConfiguration.whitePoint
    float4   viewportParams;           // xy = render target size in pixels, zw unused
    float3x3 normalMatrix;             // inverse transpose of modelMatrix's upper 3x3: the matrix
                                       // normals are transformed with (not modelMatrix itself)
    float4   ambientAxisTints[4];      // rgb = sRGB colour at -X, +X, -Y, +Y: the ambient side
                                       // (X) and depth (Y) tints, LightingConfiguration.ambientTint*
    float4   proceduralEnvironment[3]; // rgb = sRGB ground, horizon, sky of the procedural sky
    float4   selectionTint;            // rgb = sRGB tint colour, w = mix amount (0 = off)
    float4   hoverTint;                // same, for the hovered body
};

// IMPORTANT — Swift↔Metal sync (see Renderer/ViewportRenderer.swift `struct BodyUniforms`).
// Field order, types, and 16-byte alignment must stay identical. Total stride = 64 bytes.
struct BodyUniforms {
    float4 color;                  // offset  0 — base colour rgb, opacity in a
    uint   objectIndex;            // offset 16
    float  roughness;              // offset 20
    float  metallic;               // offset 24
    uint   isSelected;             // offset 28 (1 = selected, 2 = hovered)
    float  clearcoat;              // offset 32
    float  clearcoatRoughness;     // offset 36
    float  ior;                    // offset 40
    float  _pad0;                  // offset 44
    float4 emissiveAndStrength;    // offset 48 — xyz = emissive linear RGB, w = strength
};

// MARK: - Colour Pipeline

// Colour targets are plain bgra8Unorm and hold display-encoded (sRGB) values. Every authored
// colour (body/material base colour, background, grid, axes, edges, overlays) is an sRGB value.
// Lit surfaces are the one place that does maths on light, so `shaded_fragment` decodes its
// reflectance inputs to linear, lights and tone maps in linear, and encodes back to sRGB once at
// the end. Passes that only draw an authored colour (edges, grid, axes, unlit bodies,
// highlights, overlays, the clear colour) would decode and re-encode the same value, so they
// write it unchanged. Light colours, ambient colours, IBL radiance and emissive are lighting
// quantities and are already linear.

// IEC 61966-2-1 sRGB transfer functions.
inline float3 srgbToLinear(float3 c) {
    c = saturate(c);
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

inline float3 linearToSrgb(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

// Per-vertex colour mode word (#142): bits 0-1 = `VertexColorMode.rawValue` (0 ignores the vertex
// colour, 1 multiplies it into the base colour, 2 replaces the base colour), bit 2 = the vertex
// colours are linear light (`AuthoredColorSpace.linear`) rather than sRGB display values.
// `RendererSharedSetup.VertexColorBinding.packedMode` builds it; it is 0 whenever the body has no
// usable colours.
inline bool vertexColorsLinear(uint modeWord) {
    return (modeWord & 4u) != 0u && (modeWord & 3u) != 0u;
}

// The surface albedo as an sRGB value: the body / material base colour combined with the
// interpolated per-vertex colour (#142). Mode 0 returns `bodyColor` untouched. Vertex colours
// that are linear light are encoded for display after combining in linear (`.unlit` draws this
// value as is).
inline float3 surfaceAlbedo(float3 bodyColor, float3 vertexColor, uint modeWord) {
    uint mode = modeWord & 3u;
    if (vertexColorsLinear(modeWord)) {
        float3 linearVertex = saturate(vertexColor);
        float3 albedo = (mode == 1u) ? srgbToLinear(bodyColor) * linearVertex : linearVertex;
        return linearToSrgb(albedo);
    }
    if (mode == 1u) return bodyColor * vertexColor;
    if (mode == 2u) return vertexColor;
    return bodyColor;
}

// The same albedo as linear light, for lighting. sRGB vertex colours decode after combining, as
// before; linear ones are used as they are, with no sRGB decode.
inline float3 surfaceAlbedoLinear(float3 bodyColor, float3 vertexColor, uint modeWord) {
    if (vertexColorsLinear(modeWord)) {
        float3 linearVertex = saturate(vertexColor);
        return ((modeWord & 3u) == 1u) ? srgbToLinear(bodyColor) * linearVertex : linearVertex;
    }
    return srgbToLinear(surfaceAlbedo(bodyColor, vertexColor, modeWord));
}

// ACES filmic tone mapping (Narkowicz approximation) of a LINEAR colour, scaled by
// exposure / white point. Returns linear [0, 1]; callers encode with `linearToSrgb`.
inline float3 acesToneMap(float3 color, float exposure, float whitePoint) {
    float3 x = max(color, 0.0) * exposure / max(whitePoint, 0.01);
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// MARK: - Fragment Output (color-only for MSAA pass)

struct ShadedFragmentOut {
    float4 color [[color(0)]];
};

// MARK: - Vertex Structs

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

struct ShadedVertexOut {
    float4 clipPosition [[position]];
    float3 worldNormal;
    // Centroid-sampled (#164): with MSAA, a pixel whose centre lies outside the triangle but
    // whose samples do not would otherwise interpolate worldPosition at the centre, i.e.
    // extrapolate it past the triangle's edge. On a surface seen nearly edge-on that moves the
    // point a long way, so the section clip test in shaded_fragment kept samples of a
    // clipped-away wall and left a ghost line along its silhouette.
    float3 worldPosition [[centroid_perspective]];
    float3 viewNormal;       // for matcap UV
    float4 clipPositionCopy; // for depth-based effects
    // Per-vertex colour for mesh bodies (#142): the interpolated sRGB colour, and how it applies.
    // `vertexColorMode` is a flat mode word: bits 0-1 = VertexColorMode (0 ignored, 1 multiply,
    // 2 replace), bit 2 = the colours are linear light (AuthoredColorSpace.linear). A body that
    // ignores its vertex colours has the word 0, so it shades exactly as before.
    float3 vertexColor;
    uint   vertexColorMode [[flat]];
};

struct WireframeVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing and the edge depth fade
};

// MARK: - Grid / Axis Structs

struct GridVertexIn {
    float3 position [[attribute(0)]];
};

struct GridVertexOut {
    float4 clipPosition [[position]];
    float  pointSize [[point_size]];
};

struct LineVertexOut {
    float4 clipPosition [[position]];
};

// MARK: - PBR Helpers

// GGX/Trowbridge-Reitz normal distribution function
inline float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (M_PI_F * denom * denom + 1e-7);
}

// Schlick-GGX geometry function
inline float geometrySchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Smith's geometry function
inline float geometrySmith(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

// Schlick Fresnel approximation
inline float3 fresnelSchlick(float cosTheta, float3 F0) {
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

// Scalar Schlick — used for clearcoat layer where F0 is a single value.
inline float fresnelSchlickScalar(float cosTheta, float F0) {
    return F0 + (1.0 - F0) * pow(saturate(1.0 - cosTheta), 5.0);
}

// Dielectric F0 from index of refraction. Air→medium boundary: F0 = ((ior-1)/(ior+1))².
// Default ior=1.5 → F0=0.04, water 1.33 → 0.02, sapphire 1.77 → 0.077.
inline float F0FromIOR(float ior) {
    float r = (ior - 1.0) / (ior + 1.0);
    return r * r;
}

// Evaluates the clearcoat specular lobe (Filament §4.8.4).
// Returns the coat specular contribution and writes Fc out for base attenuation.
// Coat F0 is fixed at 0.04 (polyurethane, ior≈1.5).
inline float3 evaluateClearcoat(
    float NdotH, float NdotV, float NdotL, float HdotV,
    float coatRoughness,
    thread float &Fc
) {
    float D = distributionGGX(NdotH, coatRoughness);
    float G = geometrySmith(NdotV, NdotL, coatRoughness);
    Fc = fresnelSchlickScalar(HdotV, 0.04);
    float spec = (D * G * Fc) / (4.0 * NdotV * NdotL + 0.0001);
    return float3(spec);
}

// Y-axis rotation of a sampling direction. Rotates the *environment* —
// pass a positive angle to rotate the sky clockwise as viewed from +Y.
inline float3 rotateY(float3 v, float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float3(v.x * c - v.z * s, v.y, v.x * s + v.z * c);
}

// Maps a Z-up world direction into the Y-up space the environment cubemap is baked in
// (equirect_to_cubemap puts the image's top row at env +Y), then applies the environment
// rotation. World +Z → env +Y, world −Y → env +Z: a proper rotation, so nothing is mirrored,
// and rotating about env Y turns the environment about world up (Z).
inline float3 worldToEnvironment(float3 v, float angle) {
    return rotateY(float3(v.x, v.z, -v.y), angle);
}

// Procedural environment reflection: sky-ground gradient. World is Z-up. The three colours are
// sRGB values from LightingConfiguration.proceduralEnvironment*Color.
inline float3 sampleEnvironment(float3 direction, constant float4 *colors) {
    float t = direction.z * 0.5 + 0.5; // 0 = ground, 1 = sky
    float3 groundColor = colors[0].rgb;
    float3 horizonColor = colors[1].rgb;
    float3 skyColor = colors[2].rgb;
    // Two-segment blend: ground→horizon→sky
    if (t < 0.5) {
        return mix(groundColor, horizonColor, smoothstep(0.0, 0.5, t));
    } else {
        return mix(horizonColor, skyColor, smoothstep(0.5, 1.0, t));
    }
}

// Selection / hover surface tint (ViewportConfiguration.selectionTint / hoverTint): mixes the
// display-encoded colour toward the tint's sRGB colour by its strength. isSelected is
// 1 = selected, 2 = hovered; a strength of 0 leaves the colour untouched.
inline float3 applySelectionTint(float3 color, uint isSelected, constant Uniforms &uniforms) {
    if (isSelected == 1) {
        return mix(color, uniforms.selectionTint.rgb, uniforms.selectionTint.w);
    } else if (isSelected == 2) {
        return mix(color, uniforms.hoverTint.rgb, uniforms.hoverTint.w);
    }
    return color;
}

// MARK: - Shaded Pipeline

// Buffers 0 and 2 carry the vertex data (the direct-mesh path puts its normals at 2), and 1 the
// scene uniforms. `vertexColors` (3, stride 16, indexed by `[[vertex_id]]`, which for an indexed
// draw is the index value) and its mode word (4) are bound on every draw; `vertexColors` is only
// read when the mode word's bits 0-1 are non-zero (#142).
vertex ShadedVertexOut shaded_vertex(
    VertexIn in [[stage_in]],
    uint vid [[vertex_id]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device float4 *vertexColors [[buffer(3)]],
    constant uint &vertexColorMode [[buffer(4)]]
) {
    ShadedVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    // Normals use the inverse transpose of the model matrix, not the matrix itself, which tilts
    // them off the surface under non-uniform scale (#213).
    out.worldNormal = normalize(uniforms.normalMatrix * in.normal);
    out.worldPosition = worldPos.xyz;
    // View-space normal for matcap
    out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);
    out.clipPositionCopy = out.clipPosition;
    out.vertexColorMode = vertexColorMode;
    out.vertexColor = ((vertexColorMode & 3u) != 0u) ? vertexColors[vid].rgb : float3(1.0);
    return out;
}

// Poisson disk samples for PCSS (16 points)
constant float2 poissonDisk[16] = {
    float2(-0.94201624, -0.39906216), float2( 0.94558609, -0.76890725),
    float2(-0.09418410, -0.92938870), float2( 0.34495938,  0.29387760),
    float2(-0.91588581,  0.45771432), float2(-0.81544232, -0.87912464),
    float2(-0.38277543,  0.27676845), float2( 0.97484398,  0.75648379),
    float2( 0.44323325, -0.97511554), float2( 0.53742981, -0.47373420),
    float2(-0.26496911, -0.41893023), float2( 0.79197514,  0.19090188),
    float2(-0.24188840,  0.99706507), float2(-0.81409955,  0.91437590),
    float2( 0.19984126,  0.78641367), float2( 0.14383161, -0.14100790)
};

// PCSS shadow sampling: percentage-closer soft shadows
inline float sampleShadow(float4 lightSpacePos, depth2d<float> shadowMap,
                           float bias, float lightSize, float searchRadius) {
    // Perspective divide
    float3 projCoords = lightSpacePos.xyz / lightSpacePos.w;
    // Transform from [-1,1] to [0,1] UV space
    float2 shadowUV = projCoords.xy * 0.5 + 0.5;
    shadowUV.y = 1.0 - shadowUV.y; // Metal texture origin is top-left
    float currentDepth = projCoords.z;

    // Outside shadow map bounds → no shadow
    if (shadowUV.x < 0.0 || shadowUV.x > 1.0 || shadowUV.y < 0.0 || shadowUV.y > 1.0) {
        return 1.0;
    }

    constexpr sampler shadowSampler(filter::linear, address::clamp_to_edge, compare_func::less);
    float2 texelSize = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());

    // When lightSize is negligible, fall back to simple 4-tap PCF
    if (lightSize < 0.001) {
        float shadow = 0.0;
        const float2 offsets[4] = {
            float2(-0.5, -0.5), float2( 0.5, -0.5),
            float2(-0.5,  0.5), float2( 0.5,  0.5)
        };
        for (int i = 0; i < 4; i++) {
            float2 uv = shadowUV + offsets[i] * texelSize;
            shadow += shadowMap.sample_compare(shadowSampler, uv, currentDepth - bias);
        }
        return shadow / 4.0;
    }

    // Step 1: Blocker search — find average blocker depth
    constexpr sampler depthSampler(filter::nearest, address::clamp_to_edge);
    float blockerSum = 0.0;
    float blockerCount = 0.0;
    float sr = max(searchRadius, lightSize);

    for (int i = 0; i < 16; i++) {
        float2 uv = shadowUV + poissonDisk[i] * sr;
        float sampleDepth = shadowMap.sample(depthSampler, uv);
        if (sampleDepth < currentDepth - bias) {
            blockerSum += sampleDepth;
            blockerCount += 1.0;
        }
    }

    // No blockers found → fully lit
    if (blockerCount < 1.0) {
        return 1.0;
    }

    float avgBlockerDepth = blockerSum / blockerCount;

    // Step 2: Penumbra width estimation
    float penumbraWidth = lightSize * (currentDepth - avgBlockerDepth) / max(avgBlockerDepth, 0.0001);
    penumbraWidth = clamp(penumbraWidth, texelSize.x, lightSize * 4.0);

    // Step 3: PCF with variable radius
    float shadow = 0.0;
    for (int i = 0; i < 16; i++) {
        float2 uv = shadowUV + poissonDisk[i] * penumbraWidth;
        shadow += shadowMap.sample_compare(shadowSampler, uv, currentDepth - bias);
    }
    return shadow / 16.0;
}

// The shaded surface body, shared by `shaded_fragment` and the heightfield fragment (which builds
// its own normal and albedo per pixel and then shades them exactly as a mesh is shaded).
inline ShadedFragmentOut shadedFragmentBody(
    ShadedVertexOut in,
    constant Uniforms &uniforms,
    constant BodyUniforms &bodyUniforms,
    texture2d<float> matcapTexture,
    depth2d<float> shadowMap,
    texturecube<float> iblSpecular,
    texturecube<float> iblDiffuse,
    texture2d<float> brdfLUT
) {
    // Clip plane discard
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0) {
            discard_fragment();
        }
    }

    // Unlit / flat-colour mode (issue #77): emit the body's base colour directly,
    // skipping all lighting, ambient, shadows, fresnel, curvature and tone mapping —
    // so vivid diagnostic colours stay faithful and distinguishable. Clip planes and
    // selection tint still apply.
    if (uniforms.unlit == 1u) {
        float3 flatColor = applySelectionTint(
            surfaceAlbedo(bodyUniforms.color.rgb, in.vertexColor, in.vertexColorMode),
            bodyUniforms.isSelected, uniforms);
        ShadedFragmentOut unlitOut;
        unlitOut.color = float4(flatColor, bodyUniforms.color.a);
        return unlitOut;
    }

    float3 N = normalize(in.worldNormal);
    float3 viewN = in.viewNormal;
    // Faceted mode (DisplayMode.flat): light each triangle with its own face normal, rebuilt
    // from the screen-space derivatives of the world position, which are constant across a
    // triangle. Oriented to the interpolated normal's side so mesh winding doesn't matter.
    if (uniforms.unlit == 2u) {
        float3 faceN = cross(dfdx(in.worldPosition), dfdy(in.worldPosition));
        if (length_squared(faceN) > 1e-20) {
            faceN = normalize(faceN);
            N = dot(faceN, N) < 0.0 ? -faceN : faceN;
            viewN = (uniforms.viewMatrix * float4(N, 0.0)).xyz;
        }
    }
    float3 V = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    // A translucent body's far wall is seen through its near wall, and its vertex normals point
    // away from the camera there. Light it as the side being looked at, or the Fresnel rim and
    // the environment reflection (which peak as N·V → 0 and use reflect(-V, N)) light up the
    // whole far wall. Opaque bodies are left alone: their far walls are hidden by depth, and
    // interpolated normals that dip just past a silhouette must keep their side.
    float alpha = bodyUniforms.color.a;
    bool translucent = alpha < 0.999;
    if (translucent && dot(N, V) < 0.0) {
        N = -N;
        viewN = -viewN;
    }
    float NdotV = max(dot(N, V), 0.001);

    float fresnelPower = uniforms.materialParams.x;
    float fresnelIntensity = uniforms.materialParams.y;
    float matcapBlend = uniforms.materialParams.z;

    float roughness = clamp(bodyUniforms.roughness, 0.04, 1.0);
    float metallic = saturate(bodyUniforms.metallic);
    // Body / material base colour is authored in sRGB, and so are the per-vertex colours (#142)
    // unless `vertexColorSpace` says linear: combine them, then light the result in linear.
    float3 bodyColor = surfaceAlbedoLinear(
        bodyUniforms.color.rgb, in.vertexColor, in.vertexColorMode);
    float clearcoat = saturate(bodyUniforms.clearcoat);
    float coatRoughness = clamp(bodyUniforms.clearcoatRoughness, 0.04, 1.0);

    // PBR base reflectance: dielectric F0 from IOR, metal F0 = body colour.
    // For metallic > 0 the IOR term is irrelevant — `mix` resolves to bodyColor.
    float dielectricF0 = F0FromIOR(max(bodyUniforms.ior, 1.0));
    float3 F0 = mix(float3(dielectricF0), bodyColor, metallic);

    // Accumulate lighting from up to 3 lights
    float3 Lo = float3(0.0); // Outgoing radiance
    float3 specularLo = float3(0.0); // The specular share of Lo, for translucent alpha below

    for (int i = 0; i < 3; i++) {
        float enabled = uniforms.lights[i].colorAndEnabled.a;
        if (enabled < 0.5) continue;

        float lightTypeVal = uniforms.lights[i].typeAndParams.x;
        float intensity = uniforms.lights[i].directionAndIntensity.w;
        float3 lightColor = srgbToLinear(uniforms.lights[i].colorAndEnabled.rgb);
        float3 L;

        if (lightTypeVal > 0.5) {
            // Point light
            float3 lightPos = uniforms.lights[i].positionAndPad.xyz;
            float3 toLight = lightPos - in.worldPosition;
            float dist = length(toLight);
            L = toLight / max(dist, 0.0001);
            // Inverse-square falloff with windowed radius
            float lightRadius = max(uniforms.lights[i].typeAndParams.y, 0.01);
            float windowed = saturate(1.0 - pow(dist / lightRadius, 4.0));
            float attenuation = (windowed * windowed) / (dist * dist + 0.0001);
            intensity *= attenuation;
        } else {
            // Directional light
            L = normalize(-uniforms.lights[i].directionAndIntensity.xyz);
        }

        float3 H = normalize(L + V);

        float NdotL = max(dot(N, L), 0.0);
        float NdotH = max(dot(N, H), 0.0);
        float HdotV = max(dot(H, V), 0.0);

        // Base lobe — Cook-Torrance with GGX/Smith/Schlick
        float D = distributionGGX(NdotH, roughness);
        float G = geometrySmith(NdotV, NdotL, roughness);
        float3 F = fresnelSchlick(HdotV, F0);

        // lightingScales.w = LightingConfiguration.specularIntensity / 0.5 (1 = physically based).
        float3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001) * uniforms.lightingScales.w;

        // Energy conservation: diffuse only for non-reflected light
        float3 kD = (1.0 - F) * (1.0 - metallic);
        float3 diffuse = kD * bodyColor / M_PI_F;
        float3 baseLobe = diffuse + specular;

        // Clearcoat lobe — sits on top of base, attenuates everything below by (1 - Fc·c).
        float3 contribution;
        if (clearcoat > 0.0) {
            float Fc;
            float3 coatSpec = evaluateClearcoat(NdotH, NdotV, NdotL, HdotV, coatRoughness, Fc)
                * uniforms.lightingScales.w;
            float attenuation = 1.0 - Fc * clearcoat;
            contribution = baseLobe * attenuation + coatSpec * clearcoat;
            specularLo += (specular * attenuation + coatSpec * clearcoat)
                * lightColor * intensity * NdotL;
        } else {
            contribution = baseLobe;
            specularLo += specular * lightColor * intensity * NdotL;
        }

        Lo += contribution * lightColor * intensity * NdotL;
    }

    // Shadow mapping: darken key light contribution (PCSS soft shadows)
    if (uniforms.shadowParams.z > 0.5) {
        // in.worldPosition already includes the body transform (modelMatrix), matching the
        // shadow depth pass (shadow_vertex: lightVP * modelMatrix * position). Applying
        // modelMatrix again here would sample the shadow map at transform * transform * p.
        float4 lightSpacePos = uniforms.lightViewProjectionMatrix * float4(in.worldPosition, 1.0);
        float shadowFactor = sampleShadow(lightSpacePos, shadowMap, uniforms.shadowParams.x,
                                           uniforms.shadowParams2.x, uniforms.shadowParams2.y);
        float shadowDarkness = uniforms.shadowParams.y;
        Lo *= mix(1.0 - shadowDarkness, 1.0, shadowFactor);
        specularLo *= mix(1.0 - shadowDarkness, 1.0, shadowFactor);
    }

    // Tri-axis ambient: vary ambient by normal in all 3 directions (not just up/down).
    // This breaks up uniform color on faces at the same elevation but different azimuths.
    // The world is Z-up (turntable, StandardView), so the sky/ground hemisphere follows N.z.
    // The ambient rig (sky/ground colours and the side/depth tints) is authored and blended
    // in sRGB, as it always was; the blended ambient level is then decoded to linear, so each
    // face's ambient brightness reads as before.
    float3 skyColor = uniforms.ambientSkyColor.rgb;
    float3 groundColor = uniforms.ambientGroundColor.rgb;
    float3 ambientUp = mix(groundColor, skyColor, N.z * 0.5 + 0.5);
    // Side axis: warm on -X, cool on +X (simulates fill/key side difference). The four tints are
    // LightingConfiguration.ambientTint* (sRGB).
    float3 ambientX = mix(uniforms.ambientAxisTints[0].rgb, uniforms.ambientAxisTints[1].rgb,
                          N.x * 0.5 + 0.5);
    // Depth axis: slightly brighter facing the front-view camera (−Y), darker facing away
    float3 ambientDepth = mix(uniforms.ambientAxisTints[2].rgb, uniforms.ambientAxisTints[3].rgb,
                              N.y * 0.5 + 0.5);
    float3 ambientLevel = srgbToLinear((ambientUp * 0.6) + (ambientX * 0.2) + (ambientDepth * 0.2));
    float3 ambient = ambientLevel * bodyColor * (1.0 - metallic * 0.5);
    // ambientColor × ambientIntensity, normalised so the .threePoint preset's 0.25 is 1×.
    ambient *= uniforms.lightingScales.rgb;

    // Environment reflection: IBL when available, procedural fallback otherwise
    float3 R = reflect(-V, N);
    float3 envContribution;
    if (uniforms.iblParams.w > 0.5) {
        // Image-based lighting with split-sum approximation
        constexpr sampler iblSampler(filter::linear, mip_filter::linear, address::repeat);
        constexpr sampler brdfSampler(filter::linear, address::clamp_to_edge);
        float iblIntensity = uniforms.iblParams.x;
        float envRotation = uniforms.iblParams.y;
        // Z-up world → Y-up cubemap, plus the environment rotation (about world up) applied to
        // sample directions only — geometry stays put.
        float3 R_env = worldToEnvironment(R, envRotation);
        float3 N_env = worldToEnvironment(N, envRotation);
        // Base lobe IBL — sample at body roughness mip
        float baseMip = roughness * 7.0;            // 8 mip levels
        float3 prefilteredBase = iblSpecular.sample(iblSampler, R_env, level(baseMip)).rgb;
        float3 irradiance = iblDiffuse.sample(iblSampler, N_env).rgb;
        float2 brdfBase = brdfLUT.sample(brdfSampler, float2(NdotV, roughness)).rg;
        float3 F_ibl = fresnelSchlick(NdotV, F0);
        float3 specularBaseIBL = prefilteredBase * (F_ibl * brdfBase.x + brdfBase.y);
        float3 kD_ibl = (1.0 - F_ibl) * (1.0 - metallic);
        float3 diffuseIBL = irradiance * bodyColor;
        float3 baseIBL = kD_ibl * diffuseIBL + specularBaseIBL;

        if (clearcoat > 0.0) {
            // Clearcoat IBL — sample at coat roughness mip with fixed coat F0 = 0.04
            float coatMip = coatRoughness * 7.0;
            float3 prefilteredCoat = iblSpecular.sample(iblSampler, R_env, level(coatMip)).rgb;
            float2 brdfCoat = brdfLUT.sample(brdfSampler, float2(NdotV, coatRoughness)).rg;
            float Fc_ibl = fresnelSchlickScalar(NdotV, 0.04);
            float3 specularCoatIBL = prefilteredCoat * (Fc_ibl * brdfCoat.x + brdfCoat.y);
            float attenuation = 1.0 - Fc_ibl * clearcoat;
            envContribution = (baseIBL * attenuation + specularCoatIBL * clearcoat) * iblIntensity;
        } else {
            envContribution = baseIBL * iblIntensity;
        }
    } else {
        // Procedural environment fallback
        float3 envColor = srgbToLinear(sampleEnvironment(R, uniforms.proceduralEnvironment));
        float envFresnel = pow(1.0 - NdotV, 5.0);
        float envStrength = mix(0.04, 1.0, metallic) * mix(0.3, 1.0, envFresnel) * (1.0 - roughness * 0.7);
        envContribution = envColor * mix(float3(dielectricF0), bodyColor, metallic) * envStrength;
    }

    // Fresnel rim (reduced for metallic surfaces)
    float fresnel = fresnelIntensity * (1.0 - metallic * 0.5) * pow(1.0 - NdotV, fresnelPower);
    // The rim strength is tuned as a display-space amount; decode it like a colour.
    float3 rimColor = srgbToLinear(float3(fresnel));

    // Combine lighting
    float3 litColor = Lo + ambient + envContribution + rimColor;

    // Emissive — additive, ignores all lighting/shadow contributions.
    // Strength > 1 produces true HDR output that the tonemapper will compress.
    float3 emissive = bodyUniforms.emissiveAndStrength.rgb * bodyUniforms.emissiveAndStrength.a;
    litColor += emissive;

    // Screen-space curvature: brightens convex edges, darkens concave creases
    // Uses fragment derivatives of the world normal to detect surface curvature.
    // Suppressed at mesh boundaries where derivatives are discontinuous.
    // shadowParams2.z > 0.5 = debug disable curvature
    // Skipped in faceted mode: a face normal has no curvature inside a triangle, and its
    // derivatives only spike along the seams.
    if (uniforms.shadowParams2.z < 0.5 && uniforms.unlit != 2u) {
        float3 dx = dfdx(N);
        float3 dy = dfdy(N);
        float derivMag = length(dx) + length(dy);
        // Only apply curvature where derivatives are smooth (not at triangle seams)
        if (derivMag < 1.0) {
            float3 xneg = N - dx;
            float3 xpos = N + dx;
            float3 yneg = N - dy;
            float3 ypos = N + dy;
            float depth = in.clipPositionCopy.w;
            float curvature = (cross(xneg, xpos).y - cross(yneg, ypos).x) * 4.0 / max(depth, 0.01);
            // Smooth falloff near the derivative threshold to avoid hard transitions
            float strength = 0.2 * smoothstep(1.0, 0.3, derivMag);
            curvature = clamp(curvature, -1.0, 1.0);
            litColor *= 1.0 + curvature * strength;
        }
    }

    // Matcap
    if (matcapBlend > 0.001) {
        float3 vn = normalize(viewN);
        float2 matcapUV = vn.xy * 0.5 + 0.5;
        constexpr sampler matcapSampler(filter::linear);
        float3 matcapColor = srgbToLinear(matcapTexture.sample(matcapSampler, matcapUV).rgb);
        litColor = mix(litColor, matcapColor * bodyColor, matcapBlend);
    }

    // Tone map in linear, then encode to sRGB once. This runs on every frame, so `exposure` /
    // `whitePoint` apply whether or not the SSAO / silhouette composite runs, and live and
    // offscreen output agree (#136 H6).
    litColor = acesToneMap(litColor, uniforms.toneMapExposure, uniforms.toneMapWhitePoint);
    litColor = linearToSrgb(litColor);

    // Selection tint: a wash of the configured colour over a selected or hovered body (a subtle
    // blue by default). Applied to the display-encoded colour, like the unlit path, so it reads
    // the same in every mode.
    litColor = applySelectionTint(litColor, bodyUniforms.isSelected, uniforms);

    // Reflection is not attenuated by how transparent the surface is: glass at 10 % opacity
    // still shows a full-strength highlight. With "over" blending the whole colour is scaled by
    // alpha, so raise alpha where the direct specular is bright (tone mapped, as displayed). The
    // rest of the surface keeps its own opacity.
    if (translucent) {
        float3 shownSpecular =
            acesToneMap(specularLo, uniforms.toneMapExposure, uniforms.toneMapWhitePoint);
        float specularLevel = dot(shownSpecular, float3(0.2126, 0.7152, 0.0722));
        alpha = saturate(alpha + (1.0 - alpha) * specularLevel);
    }

    ShadedFragmentOut out;
    out.color = float4(litColor, alpha);
    return out;
}

fragment ShadedFragmentOut shaded_fragment(
    ShadedVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    texture2d<float> matcapTexture [[texture(0)]],
    depth2d<float> shadowMap [[texture(1)]],
    texturecube<float> iblSpecular [[texture(2)]],
    texturecube<float> iblDiffuse [[texture(3)]],
    texture2d<float> brdfLUT [[texture(4)]]
) {
    return shadedFragmentBody(
        in, uniforms, bodyUniforms, matcapTexture, shadowMap, iblSpecular, iblDiffuse, brdfLUT);
}

// MARK: - Pick-Only Pipeline (1x, no MSAA)

struct PickVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing
};

// The pick target is RG32Uint (#160). Pick encoding, one texel per pixel (must stay in sync with
// PickEncoding.swift, which the readback decodes with):
//   R : objectIndex (32 bits); 0xFFFFFFFF = no object
//   G : bits 0-29 primitiveID (30 bits, masked), bits 30-31 kind (0=face, 1=edge, 2=vertex)
struct PickFragmentOut {
    uint2 pickID [[color(0)]];
};

// Every pick fragment packs through this, so the layout lives in one place. A body whose object
// index is the reserved 0xFFFFFFFF writes the cleared (no-hit) texel, so it hides what is behind
// it but picks as a miss.
inline uint2 packPickID(uint objectIndex, uint primitiveID, uint kind) {
    if (objectIndex == 0xFFFFFFFFu) return uint2(0xFFFFFFFFu);
    return uint2(objectIndex, (primitiveID & 0x3FFFFFFFu) | (kind << 30));
}

// True when `worldPosition` lies on the clipped (negative) side of any active section plane.
// Same test the shaded/wireframe/highlight fragments run inline; the pick, depth-prepass,
// selection-mask and point-cloud fragments call this so sections hide geometry everywhere.
inline bool isClippedBySectionPlanes(float3 worldPosition, constant Uniforms &uniforms) {
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, worldPosition) + plane.w < 0.0) {
            return true;
        }
    }
    return false;
}

// Clip position of an edge vertex at `worldPos`, depth-biased so edges win over the faces they
// lie on. Shared by wireframe_vertex and pick_line_vertex, so a native edge is pickable wherever
// it is drawn (#182). Not a constant NDC offset: how much world depth a fixed NDC step spans
// depends on the near/far range, so with a wide range (the unfitted 0.01/10000 fallback, or near
// at its far * 1e-4 floor) a constant bias let hidden back edges show through faces (#157).
// Instead, like quad_edge_vertex, pull the vertex toward the viewer along its own view ray
// (screen position unchanged) by EDGE_BIAS_PX pixels, measured in world units at this depth.
// The pull is a number of pixels of the drawable (Uniforms.viewportParams), not a fixed fraction
// of NDC: how much depth a pixel spans on a tilted face does not change with the drawable's
// size, so a fraction of NDC height (0.006, ~3 px at 1000 px tall) fell below one pixel's depth
// on a drawable under ~256 px tall and the face won (#193). 3 px is quad_edge_vertex's pull for
// a 1 px line (EDGE_BIAS_SLOPE * (half width + 1 px)): enough for faces tilted up to ~63 degrees.
inline float4 edgeBiasedClipPosition(float4 worldPos, constant Uniforms &uniforms) {
    constexpr float EDGE_BIAS_PX = 3.0;
    // An unset size (0) keeps the 1000 px reference the old constant was tuned for.
    float viewportHeight = uniforms.viewportParams.y > 1.0 ? uniforms.viewportParams.y : 1000.0;
    float edgeBiasNDC = EDGE_BIAS_PX * 2.0 / viewportHeight;
    float4x4 vp = uniforms.viewProjectionMatrix;
    float4 clipPosition = vp * worldPos;
    float4x4 viewMatrix = uniforms.viewMatrix;
    float3 cameraUp = float3(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);
    float3 cameraBack = float3(viewMatrix[0][2], viewMatrix[1][2], viewMatrix[2][2]);
    bool orthographic = abs(vp[0][3]) + abs(vp[1][3]) + abs(vp[2][3]) < 1e-6;
    float baseW = max(clipPosition.w, 1e-6);
    float4 upClipPos = vp * (worldPos + float4(cameraUp, 0.0));
    float ndcPerWorld = abs(upClipPos.y / max(upClipPos.w, 1e-6) - clipPosition.y / baseW);
    if (ndcPerWorld > 1e-6) {
        float3 towardViewer = orthographic
            ? cameraBack
            : normalize(uniforms.cameraPosition.xyz - worldPos.xyz);
        float4 pulledClipPos = vp * (worldPos + float4(towardViewer * (edgeBiasNDC / ndcPerWorld), 0.0));
        if (pulledClipPos.w > 1e-6) {
            float unbiasedDepth = clipPosition.z / baseW;
            // Never let the bias alone push a vertex in front of the near plane: the near plane
            // is fitted to the scene bounds, so an edge at the front of the scene sits close to it.
            float biasedDepth = max(pulledClipPos.z / pulledClipPos.w, min(unbiasedDepth, 0.0));
            clipPosition.z = biasedDepth * clipPosition.w;
        }
    }
    return clipPosition;
}

vertex PickVertexOut pick_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    PickVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

// Edge and arc pick vertex: the same depth bias as wireframe_vertex, so on a tilted face the
// 1x pick pass resolves the edge the user sees drawn over it, not the face (#182). Faces keep
// the unbiased pick_vertex.
vertex PickVertexOut pick_line_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    PickVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = edgeBiasedClipPosition(worldPos, uniforms);
    out.worldPosition = worldPos.xyz;
    return out;
}

// Face pick — kind=0 (layout: see PickFragmentOut).
fragment PickFragmentOut pick_fragment(
    PickVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, primitiveID, 0u);
    return out;
}

// Edge pick — kind=1. `firstSegment` is the index of the draw's first segment: `[[primitive_id]]`
// restarts at 0 for each draw, and a ViewportBody.edgeDrawRange slice starts part-way in (#140).
fragment PickFragmentOut pick_line_fragment(
    PickVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant uint &firstSegment [[buffer(3)]],
    uint primitiveID [[primitive_id]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, firstSegment + primitiveID, 1u);
    return out;
}

// Analytic arc pick — kind=1 (edge). primitiveID is the ARC index, supplied per
// draw (each arc is drawn separately), since the arc's segment count is sampled
// adaptively per frame and `[[primitive_id]]` would only give a segment index.
fragment PickFragmentOut pick_arc_fragment(
    PickVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant uint &arcPrimID [[buffer(3)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, arcPrimID, 1u);
    return out;
}

// Point sprite vertex shader for vertex picking. Outputs `point_size` so
// individual vertices have a clickable footprint instead of a single pixel.
struct PickPointVertexOut {
    float4 clipPosition [[position]];
    float pointSize [[point_size]];
    float3 worldPosition;    // for clip plane testing
};

vertex PickPointVertexOut pick_point_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant float &spriteSize [[buffer(2)]] // drawable px: 8 pt x content scale
) {
    PickPointVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.pointSize = clamp(spriteSize, 1.0, 64.0);
    out.worldPosition = worldPos.xyz;
    return out;
}

// Vertex pick — kind=2.
fragment PickFragmentOut pick_point_fragment(
    PickPointVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, primitiveID, 2u);
    return out;
}

// MARK: - Visible Point-Cloud Pipeline
//
// Draws a body whose primitiveKind == .point as visible point sprites. Reads
// positions from `positions[buffer(0)]` indexed by [[vertex_id]] (no vertex
// descriptor needed) and an optional per-point colour buffer at buffer(1).
// `pxPerWorldFactor` = viewportHeight * projection[1][1] / 2 — the
// projection-aware scalar that, divided by clipPosition.w, gives screen
// pixels per world unit. Works for both perspective (w == -viewZ) and
// orthographic (w == 1) projections.
//
// IMPORTANT — Swift↔Metal sync (see Renderer/ViewportRenderer.swift
// `struct PointParamsSwift`). Field order, types, and 16-byte alignment must
// stay identical.
struct PointParams {
    float4 baseColor;          // offset  0 — fallback colour when vertexColors empty
    float  worldRadius;        // offset 16
    float  pxPerWorldFactor;   // offset 20
    uint   useVertexColors;    // offset 24 (0 or 1)
    uint   vertexColorSpace;   // offset 28 (0 = sRGB display values, 1 = linear; encoded for display)
};

struct VisiblePointVertexOut {
    float4 clipPosition [[position]];
    float  pointSize    [[point_size]];
    float4 color;
    float3 worldPosition;    // for clip plane testing
};

vertex VisiblePointVertexOut visible_point_vertex(
    uint vid [[vertex_id]],
    constant float3 *positions [[buffer(0)]],
    constant float4 *vertexColors [[buffer(1)]],
    constant Uniforms &uniforms [[buffer(2)]],
    constant PointParams &params [[buffer(3)]]
) {
    VisiblePointVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(positions[vid], 1.0);
    float4 clipPos = uniforms.viewProjectionMatrix * worldPos;
    out.clipPosition = clipPos;
    out.worldPosition = worldPos.xyz;

    // Convert world-space radius to a screen-space pixel diameter. The
    // factor `pxPerWorldFactor / clipPos.w` gives pixels per world unit at
    // this depth, and the diameter is twice the radius.
    float wDenom = max(abs(clipPos.w), 1e-4);
    float screenSize = 2.0 * params.worldRadius * params.pxPerWorldFactor / wDenom;
    // Apple GPUs clamp [[point_size]] at 64 px; clamp on the upper end so
    // the value we emit is what actually rasterizes (avoids visual cliffs
    // when clamping happens silently). 1 px lower bound keeps the sprite
    // visible at extreme depths.
    out.pointSize = clamp(screenSize, 1.0, 64.0);

    out.color = params.baseColor;
    if (params.useVertexColors != 0u) {
        out.color = vertexColors[vid];
        // Linear-light colours are encoded for the display target; sRGB ones are drawn as given.
        if (params.vertexColorSpace != 0u) out.color.rgb = linearToSrgb(out.color.rgb);
    }
    return out;
}

fragment float4 visible_point_fragment(
    VisiblePointVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant Uniforms &uniforms [[buffer(2)]]
) {
    // Section planes clip the whole sprite by its centre point.
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    // Mask to a disk inscribed in the [[point_coord]] unit square.
    float2 c = pointCoord - float2(0.5);
    if (dot(c, c) > 0.25) discard_fragment();
    return in.color;
}

// MARK: - Selection Outline Pipeline (#209)
//
// The outline is a screen-space dilation of each selected or hovered body's silhouette. A
// single-sample pass before the main pass rasterises those bodies into an R8Uint selection mask
// (1 = selected, 2 = hovered; 0 = neither) without testing depth, so a body hidden behind another
// is in the mask too (#177). The main pass then draws one full-screen triangle that, for each
// pixel, finds the nearest marked mask texel within the outline width and paints the outline
// there; the stencil (marked per sample by the same bodies) keeps it off the bodies themselves.
// Dilating the rasterised silhouette rings any mesh: the old vertex expansion along normals left
// no ring around a flat-normal mesh seen face-on (a box from the front), whose silhouette is made
// of side faces seen edge-on.

// Selection-mask fragment: writes the body's mask code (`selection_mask_vertex` is
// `depth_only_vertex` / `tessellated_depth_vertex`). Section-clipped fragments are left unmarked,
// so the ring follows the cut silhouette.
struct SelectionMaskFragmentOut {
    uint code [[color(0)]];
};

fragment SelectionMaskFragmentOut selection_mask_fragment(
    PickVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant uint &code [[buffer(2)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    SelectionMaskFragmentOut out;
    out.code = code;
    return out;
}

// IMPORTANT — Swift↔Metal sync (see Renderer/ViewportRenderer.swift
// `struct SelectionOutlineParamsSwift`). Field order, types, and alignment must stay identical.
// Total stride = 32 bytes.
struct SelectionOutlineParams {
    float4 selected;    // rgb = outline colour of selected bodies, w = width in drawable pixels
    float4 hovered;     // rgb = outline colour of the hovered body, w = width in drawable pixels
};

// The fragment's pixel position from `fullscreen_vertex` (its other outputs are unused).
struct SelectionOutlinePixel {
    float4 position [[position]];
};

// Coverage of a ring `width` pixels wide at `distance` pixels (centre to centre) from the nearest
// marked texel: 1 out to `width`, fading to 0 over the next pixel so the outer edge is smooth.
inline float selectionOutlineCoverage(float width, float squaredDistance) {
    if (width <= 0.0 || squaredDistance > 1e8) return 0.0;
    return saturate(width + 1.0 - sqrt(squaredDistance));
}

fragment float4 selection_outline_fragment(
    SelectionOutlinePixel in [[stage_in]],
    texture2d<uint, access::read> mask [[texture(0)]],
    constant SelectionOutlineParams &params [[buffer(0)]]
) {
    int2 pixel = int2(in.position.xy);
    int2 size = int2(mask.get_width(), mask.get_height());
    float maxWidth = max(params.selected.w, params.hovered.w);
    int radius = int(ceil(maxWidth)) + 1;
    float radiusSq = float(radius * radius);
    float nearestSelected = 1e9;
    float nearestHovered = 1e9;
    for (int dy = -radius; dy <= radius; dy++) {
        int y = pixel.y + dy;
        if (y < 0 || y >= size.y) continue;
        for (int dx = -radius; dx <= radius; dx++) {
            int x = pixel.x + dx;
            float d2 = float(dx * dx + dy * dy);
            if (x < 0 || x >= size.x || d2 > radiusSq) continue;
            uint code = mask.read(uint2(x, y)).r;
            if (code == 1u) {
                nearestSelected = min(nearestSelected, d2);
            } else if (code == 2u) {
                nearestHovered = min(nearestHovered, d2);
            }
        }
    }
    float selectedCoverage = selectionOutlineCoverage(params.selected.w, nearestSelected);
    float hoveredCoverage = selectionOutlineCoverage(params.hovered.w, nearestHovered);
    float coverage = max(selectedCoverage, hoveredCoverage);
    if (coverage <= 0.0) discard_fragment();
    float3 color = selectedCoverage >= hoveredCoverage ? params.selected.rgb : params.hovered.rgb;
    return float4(color, coverage);
}

// MARK: - Shadow Map Pipeline

struct ShadowUniforms {
    float4x4 lightViewProjectionMatrix;
    float4x4 modelMatrix;
};

struct ShadowVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing (shadow_clip_fragment)
};

vertex ShadowVertexOut shadow_vertex(
    VertexIn in [[stage_in]],
    constant ShadowUniforms &uniforms [[buffer(1)]]
) {
    ShadowVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

// MARK: - Depth-Only Pipeline (for SSAO depth pass)

vertex PickVertexOut depth_only_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    PickVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

// Shadow-map fragment: only depth is written, but geometry a section clip plane removed must
// not cast a shadow into what is left (#162). The frame's scene Uniforms (for its clip planes)
// are bound at fragment buffer 1; ShadowUniforms stay vertex-only.
fragment void shadow_clip_fragment(
    ShadowVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
}

// Depth-only fragment for the SSAO/silhouette prepass: honours section clip planes so the
// prepass depth matches what the shaded pass actually drew.
fragment void depth_only_clip_fragment(
    PickVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
}

// MARK: - Wireframe Pipeline

struct WireframeVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};

vertex WireframeVertexOut wireframe_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    WireframeVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = edgeBiasedClipPosition(worldPos, uniforms);
    out.worldPosition = worldPos.xyz;
    return out;
}

struct WireframeFragmentOut {
    float4 color [[color(0)]];
};

// Edge depth fade: 0 at the near plane, 1 at the far plane, linear in view-space distance (#181).
// Measured from the fragment's world position, not its clip-space z/w: perspective NDC depth is
// hyperbolic, so mapping it straight to 0-1 faded nearly everything past twice the near distance
// and changed the fade whenever the fitted near/far range changed. Using the world position also
// keeps the vertex stages' edge depth bias out of the fade. The camera looks down view-space -z.
inline float edgeFadeDepth(float3 worldPosition, float4x4 viewMatrix, float nearPlane, float farPlane) {
    float viewDepth = -(viewMatrix * float4(worldPosition, 1.0)).z;
    return saturate((viewDepth - nearPlane) / max(farPlane - nearPlane, 1e-6));
}

// Shared body of wireframe_fragment and wireframe_segment_fragment. With `hasSegmentColor`,
// `segmentColor` (sRGB RGBA from ViewportBody.edgeColors, drawn as given) replaces the body colour
// of an edge-only body and the contrast-adaptive edge colour of a meshed one; a meshed body's
// depth fade and edge intensity still apply, on top of the colour's alpha (#140).
inline WireframeFragmentOut wireframeFragmentColor(
    WireframeVertexOut in,
    constant Uniforms &uniforms,
    constant BodyUniforms &bodyUniforms,
    bool hasSegmentColor,
    float4 segmentColor
) {
    // Clip plane discard
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0) {
            discard_fragment();
        }
    }

    float3 bodyColor = bodyUniforms.color.rgb;
    float bodyAlpha = bodyUniforms.color.a;

    // Edge-only bodies (metallic == -1 sentinel): use body color directly
    if (bodyUniforms.metallic < 0.0) {
        WireframeFragmentOut out;
        out.color = hasSegmentColor ? segmentColor : float4(bodyColor, bodyAlpha);
        return out;
    }

    float edgeIntensity = max(uniforms.shadowParams.w, 0.0); // shadowParams.w = edge intensity

    // Contrast-adaptive edge color: light edges on dark bodies, dark edges on light bodies
    float luminance = dot(bodyColor, float3(0.299, 0.587, 0.114));
    float3 darkEdge = max(bodyColor * 0.25, float3(0.08));
    float3 lightEdge = bodyColor * 0.4 + 0.6;
    float3 edgeColor = mix(lightEdge, darkEdge, smoothstep(0.3, 0.6, luminance));
    if (hasSegmentColor) edgeColor = segmentColor.rgb;

    // Depth-based edge alpha: near edges fully opaque, far edges fade
    float nearPlane = uniforms.cameraPosition.w;
    float farPlane = uniforms.materialParams.w;
    float linearDepth = edgeFadeDepth(in.worldPosition, uniforms.viewMatrix, nearPlane, farPlane);
    // edgeIntensity: 0 = invisible, 1 = normal, 2 = fully opaque at all depths
    float minAlpha = mix(0.2, 1.0, saturate(edgeIntensity));
    float edgeAlpha = mix(1.0, minAlpha, linearDepth) * saturate(edgeIntensity);
    if (hasSegmentColor) edgeAlpha *= segmentColor.a;

    WireframeFragmentOut out;
    out.color = float4(edgeColor, edgeAlpha);
    return out;
}

fragment WireframeFragmentOut wireframe_fragment(
    WireframeVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]]
) {
    return wireframeFragmentColor(in, uniforms, bodyUniforms, false, float4(0.0));
}

// A segment colour for display. `segmentParams.y` is ViewportBody.edgeColorSpace: 0 = sRGB, drawn
// as given; 1 = linear, encoded to sRGB. Alpha is coverage, not a colour, and is never encoded.
inline float4 segmentDisplayColor(float4 color, uint2 segmentParams) {
    if (segmentParams.y != 0u) color.rgb = linearToSrgb(color.rgb);
    return color;
}

// Per-segment colour variant of wireframe_fragment (#140). Each native line is one segment, so its
// colour is `segmentColors[segmentParams.x + primitiveID]`: `[[primitive_id]]` restarts at 0 for
// each draw, and `segmentParams.x` is where the draw's slice (ViewportBody.edgeDrawRange) starts.
fragment WireframeFragmentOut wireframe_segment_fragment(
    WireframeVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant float4 *segmentColors [[buffer(3)]],
    constant uint2 &segmentParams [[buffer(4)]],
    uint primitiveID [[primitive_id]]
) {
    return wireframeFragmentColor(
        in, uniforms, bodyUniforms, true,
        segmentDisplayColor(segmentColors[segmentParams.x + primitiveID], segmentParams));
}

// MARK: - Quad-Expanded Wireframe Pipeline (variable width + dash patterns)

/// Vertex input for quad-expanded edges. Each vertex carries its endpoint,
/// arc length, quad corner, and local segment direction.
struct QuadEdgeVertexIn {
    float3 position [[attribute(0)]];
    float arcLength [[attribute(1)]];
    float2 quadCorner [[attribute(2)]];
    float3 segmentDirection [[attribute(3)]];
};

struct QuadEdgeVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition;
    float arcLength;
    float2 quadCorner;
};

struct EdgeUniforms {
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4   cameraPosition;
    float4   materialParams;
    float4   dashPatternParams;  // x = dashLength, y = gapLength, z = dotLength, w = phase
    float4   edgeParams;         // x = width in pixels, y = edgeIntensity
    float4   clipPlanes[4];
    uint     clipPlaneCount;
    uint     dashPatternType;
    float2   viewportSize;
    float2   _pad;
    float2   _pad2;  // explicit tail pad: Swift binds sizeof(EdgeUniforms) = 352 bytes (#231)
};

vertex QuadEdgeVertexOut quad_edge_vertex(
    QuadEdgeVertexIn in [[stage_in]],
    constant EdgeUniforms &uniforms [[buffer(1)]]
) {
    // quadCorner = (along, side): `along` is already baked into the vertex position (start/end);
    // `side` (+-0.5) is the perpendicular offset in units of the line width.
    float side = in.quadCorner.y;

    float3 localDirection = normalize(in.segmentDirection);
    if (dot(localDirection, localDirection) < 1e-8) {
        localDirection = float3(1.0, 0.0, 0.0);
    }

    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    float4 baseClipPos = uniforms.viewProjectionMatrix * worldPos;
    float3 worldDirection = normalize(
        (uniforms.modelMatrix * float4(localDirection, 0.0)).xyz);
    if (dot(worldDirection, worldDirection) < 1e-8) {
        worldDirection = float3(1.0, 0.0, 0.0);
    }

    float4 endClipPos = uniforms.viewProjectionMatrix
        * (worldPos + float4(worldDirection, 0.0));
    float baseW = max(baseClipPos.w, 1e-6);
    float endW = max(endClipPos.w, 1e-6);
    float2 directionNDC = endClipPos.xy / endW - baseClipPos.xy / baseW;
    float2 viewportSize = max(uniforms.viewportSize, float2(1.0, 1.0));
    float2 directionPixels = directionNDC * viewportSize;
    float directionLengthSq = dot(directionPixels, directionPixels);
    float2 perpendicular;
    if (directionLengthSq > 1e-12) {
        perpendicular = normalize(float2(-directionPixels.y, directionPixels.x));
    } else {
        perpendicular = float2(0.0, 1.0);
    }

    // side is +-0.5, so width * side is the per-side pixel offset; NDC spans 2 units per
    // viewport axis, hence the 2.0. Scaled by w below so the offset is constant in screen space.
    float2 ndcOffset = perpendicular
        * (uniforms.edgeParams.x * side * 2.0)
        * float2(1.0 / viewportSize.x, 1.0 / viewportSize.y);
    float4 expandedClipPos = baseClipPos;
    expandedClipPos.xy += ndcOffset * baseW;
    // Depth bias, so edges win over the faces they lie on. The quad's side corners keep the
    // centreline's depth, but on a face tilted away from the viewer the face's depth there
    // differs by up to (half width x the face's depth slope), so a constant bias alone (the
    // wireframe_vertex one) loses part of a wide edge to the face. Pull each vertex toward the
    // viewer along its own view ray (screen position unchanged) by its half width plus a pixel,
    // times EDGE_BIAS_SLOPE, in world units at this depth: enough for faces tilted up to ~63
    // degrees, and only a few pixels' worth of depth, so hidden edges stay hidden.
    constexpr float EDGE_BIAS_SLOPE = 2.0;
    float4x4 viewMatrix = uniforms.viewMatrix;
    float3 cameraRight = float3(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);
    float3 cameraBack = float3(viewMatrix[0][2], viewMatrix[1][2], viewMatrix[2][2]);
    float4x4 vp = uniforms.viewProjectionMatrix;
    bool orthographic = abs(vp[0][3]) + abs(vp[1][3]) + abs(vp[2][3]) < 1e-6;
    float4 rightClipPos = vp * (worldPos + float4(cameraRight, 0.0));
    float2 rightPixels = (rightClipPos.xy / max(rightClipPos.w, 1e-6) - baseClipPos.xy / baseW)
        * viewportSize * 0.5;
    float pixelsPerWorld = length(rightPixels);
    if (pixelsPerWorld > 1e-6) {
        float3 towardViewer = orthographic
            ? cameraBack
            : normalize(uniforms.cameraPosition.xyz - worldPos.xyz);
        float pull = EDGE_BIAS_SLOPE * (0.5 * uniforms.edgeParams.x + 1.0) / pixelsPerWorld;
        float4 pulledClipPos = vp * (worldPos + float4(towardViewer * pull, 0.0));
        if (pulledClipPos.w > 1e-6) {
            expandedClipPos.z = pulledClipPos.z / pulledClipPos.w * expandedClipPos.w;
        }
    }
    // No constant NDC bias on top (wireframe_vertex's 0.0001): with a wide near/far range, that
    // much NDC depth spans whole world units and lets hidden edges show through faces.
    // The near plane is fitted to the scene bounds, edges included (#135), so an edge at the
    // front of the scene sits right at it: never let the bias alone push a vertex past it.
    float unbiasedDepth = baseClipPos.z / baseW;
    expandedClipPos.z = max(expandedClipPos.z, min(unbiasedDepth, 0.0) * expandedClipPos.w);

    QuadEdgeVertexOut out;
    out.clipPosition = expandedClipPos;
    out.worldPosition = worldPos.xyz;
    out.arcLength = in.arcLength;
    out.quadCorner = in.quadCorner;
    return out;
}

// Shared body of quad_edge_fragment and quad_edge_segment_fragment; `hasSegmentColor` and
// `segmentColor` behave as in wireframeFragmentColor (#140).
inline WireframeFragmentOut quadEdgeFragmentColor(
    QuadEdgeVertexOut in,
    constant EdgeUniforms &uniforms,
    constant BodyUniforms &bodyUniforms,
    bool hasSegmentColor,
    float4 segmentColor
) {
    // Clip plane discard
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0) {
            discard_fragment();
        }
    }

    // Dash test runs first so it applies to edge-only bodies too, which return early below.
    float alpha = 1.0;
    uint patternType = uniforms.dashPatternType;
    if (patternType != 0u) {
        float dashLength = max(uniforms.dashPatternParams.x, 0.0);
        float gapLength = max(uniforms.dashPatternParams.y, 0.0);
        float dotLength = max(uniforms.dashPatternParams.z, 0.0);
        float phase = uniforms.dashPatternParams.w;
        if (patternType == 3u) {
            float period = dashLength + gapLength + dotLength + gapLength;
            if (period > 0.0) {
                float pos = fmod(in.arcLength + phase, period);
                if (pos < 0.0) { pos += period; }
                if ((pos > dashLength && pos < dashLength + gapLength)
                    || pos > dashLength + gapLength + dotLength) {
                    discard_fragment();
                }
            }
        } else {
            float period = dashLength + gapLength;
            if (period > 0.0) {
                float pos = fmod(in.arcLength + phase, period);
                if (pos < 0.0) { pos += period; }
                if (pos > dashLength) {
                    discard_fragment();
                }
            }
        }
    }

    float3 bodyColor = bodyUniforms.color.rgb;
    float bodyAlpha = bodyUniforms.color.a;

    // Edge-only body (metallic = -1 sentinel): draw in the body colour, not the contrast edge colour.
    if (bodyUniforms.metallic < 0.0) {
        WireframeFragmentOut out;
        out.color = hasSegmentColor ? segmentColor : float4(bodyColor, bodyAlpha);
        return out;
    }

    float luminance = dot(bodyColor, float3(0.299, 0.587, 0.114));
    float3 darkEdge = max(bodyColor * 0.25, float3(0.08));
    float3 lightEdge = bodyColor * 0.4 + 0.6;
    float3 edgeColor = mix(lightEdge, darkEdge, smoothstep(0.3, 0.6, luminance));
    if (hasSegmentColor) edgeColor = segmentColor.rgb;

    // Depth fade and edgeIntensity scaling, identical to wireframe_fragment.
    float edgeIntensity = max(uniforms.edgeParams.y, 0.0);
    float nearPlane = uniforms.cameraPosition.w;
    float farPlane = uniforms.materialParams.w;
    float linearDepth = edgeFadeDepth(in.worldPosition, uniforms.viewMatrix, nearPlane, farPlane);
    float minAlpha = mix(0.2, 1.0, saturate(edgeIntensity));
    float edgeAlpha = alpha * mix(1.0, minAlpha, linearDepth) * saturate(edgeIntensity);
    if (hasSegmentColor) edgeAlpha *= segmentColor.a;

    WireframeFragmentOut out;
    out.color = float4(edgeColor, edgeAlpha);
    return out;
}

fragment WireframeFragmentOut quad_edge_fragment(
    QuadEdgeVertexOut in [[stage_in]],
    constant EdgeUniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]]
) {
    return quadEdgeFragmentColor(in, uniforms, bodyUniforms, false, float4(0.0));
}

// Per-segment colour variant of quad_edge_fragment (#140). Each segment is six strip vertices, so
// `[[primitive_id]] / 6` is its index within the draw (as in pick_quad_edge_fragment), and
// `segmentParams` is as in wireframe_segment_fragment: x = the draw's first segment, y = colour space.
fragment WireframeFragmentOut quad_edge_segment_fragment(
    QuadEdgeVertexOut in [[stage_in]],
    constant EdgeUniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant float4 *segmentColors [[buffer(3)]],
    constant uint2 &segmentParams [[buffer(4)]],
    uint primitiveID [[primitive_id]]
) {
    return quadEdgeFragmentColor(
        in, uniforms, bodyUniforms, true,
        segmentDisplayColor(segmentColors[segmentParams.x + primitiveID / 6u], segmentParams));
}

// Quad-expanded edge pick — kind=1, so picks cover the same width as the visible edge.
// primSource.y == 0: the segment index is primSource.x (the draw's first segment, 0 unless a
// ViewportBody.edgeDrawRange slice is drawn) + primitiveID / 6 (each segment is six strip
// vertices). primSource.y == 1: the id is primSource.x (the arc index, one draw per arc).
// The packing must match pick_line_fragment.
fragment PickFragmentOut pick_quad_edge_fragment(
    QuadEdgeVertexOut in [[stage_in]],
    constant EdgeUniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant uint2 &primSource [[buffer(3)]],
    uint primitiveID [[primitive_id]]
) {
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0) {
            discard_fragment();
        }
    }
    uint segmentID = primSource.y != 0u ? primSource.x : primSource.x + primitiveID / 6u;
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, segmentID, 1u);
    return out;
}

// MARK: - Per-triangle Highlight Pipeline (issue #25)
//
// Reads a per-triangle SIMD4<float> style buffer indexed by [[primitive_id]]
// and composites the style color over the existing fragment. Triangles with
// alpha == 0 are discarded, so the shader is a no-op on un-highlighted
// triangles. Identical positions to the shaded pass; depth state is
// .lessEqual + write disabled.

struct HighlightVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition [[centroid_perspective]];  // MSAA-safe clip test, as ShadedVertexOut (#164)
};

vertex HighlightVertexOut highlight_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    HighlightVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

struct HighlightFragmentOut {
    float4 color [[color(0)]];
};

fragment HighlightFragmentOut highlight_fragment(
    HighlightVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant float4 *triangleStyles [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    // Clip plane discard — match the shaded pass so highlight respects sections.
    for (uint cp = 0; cp < uniforms.clipPlaneCount; cp++) {
        float4 plane = uniforms.clipPlanes[cp];
        if (dot(plane.xyz, in.worldPosition) + plane.w < 0.0) {
            discard_fragment();
        }
    }

    float4 style = triangleStyles[primitiveID];
    if (style.a <= 0.0) {
        discard_fragment();
    }

    HighlightFragmentOut out;
    out.color = style;
    return out;
}

// MARK: - Grid Pipeline (Instanced Dots)

// Swift↔Metal sync: ViewportRenderer.swift `struct GridUniforms`.
struct GridUniforms {
    float4x4 viewProjectionMatrix;
    float3   gridOrigin;   // world position of the window's minimum-index dot
    float    spacing;
    int      columns;      // dots along X
    float    dotSize;
    int      rows;         // dots along Y
    float4   dotColor;
};

// Dots on the XY ground plane (Z-up world), `columns` x `rows` from `gridOrigin`.
vertex GridVertexOut grid_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant GridUniforms &uniforms [[buffer(0)]]
) {
    int ix = int(instanceID) % uniforms.columns;
    int iy = int(instanceID) / uniforms.columns;

    float3 pos = uniforms.gridOrigin + float3(float(ix) * uniforms.spacing, float(iy) * uniforms.spacing, 0.0);
    GridVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * float4(pos, 1.0);
    out.pointSize = uniforms.dotSize;
    return out;
}

struct GridFragmentOut {
    float4 color [[color(0)]];
};

fragment GridFragmentOut grid_fragment(
    GridVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant GridUniforms &uniforms [[buffer(0)]]
) {
    // Circular dot via distance from center
    float dist = length(pointCoord - float2(0.5));
    if (dist > 0.5) discard_fragment();

    GridFragmentOut out;
    out.color = uniforms.dotColor;
    return out;
}

// MARK: - Axis Pipeline (Coloured Lines)

struct AxisUniforms {
    float4x4 viewProjectionMatrix;
};

struct AxisVertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct AxisVertexOut {
    float4 clipPosition [[position]];
    float4 color;
};

vertex AxisVertexOut axis_vertex(
    AxisVertexIn in [[stage_in]],
    constant AxisUniforms &uniforms [[buffer(1)]]
) {
    AxisVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

struct AxisFragmentOut {
    float4 color [[color(0)]];
};

fragment AxisFragmentOut axis_fragment(
    AxisVertexOut in [[stage_in]]
) {
    AxisFragmentOut out;
    out.color = in.color;
    return out;
}

// MARK: - SSAO Post-Process

struct SSAOParams {
    float2 texelSize;    // 1.0 / textureSize
    float  radius;       // sample radius in UV space
    float  intensity;    // darkness multiplier
    float  nearPlane;
    float  farPlane;
    float  silhouetteThickness; // edge detection spread
    float  silhouetteIntensity; // edge darkness
    float  pixelsPerUnit;       // pixels per world unit at view depth 1 (ortho: everywhere)
    float  orthographic;        // 1 = orthographic (depth buffer is linear), 0 = perspective
    float  dofAperture;         // depth of field aperture
    float  dofFocalDistance;    // depth of field focal distance (0 = auto)
    float  dofMaxBlurRadius;    // maximum CoC blur radius in pixels
    float  dofEnabled;          // 1.0 if DoF active, 0.0 otherwise
};

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle (3 vertices cover entire screen, no vertex buffer needed)
vertex FullscreenVertexOut fullscreen_vertex(uint vertexID [[vertex_id]]) {
    FullscreenVertexOut out;
    // Generate a fullscreen triangle from vertex ID (0, 1, 2)
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    out.texCoord = float2(uv.x, 1.0 - uv.y);
    return out;
}

// View distance from a [0, 1] depth-buffer value (0 = near, 1 = far). Perspective depth is
// hyperbolic in distance; orthographic depth is linear, and used to be decoded as perspective.
inline float linearizeDepth(float depth, float near, float far, float orthographic) {
    if (orthographic > 0.5) {
        return near + depth * (far - near);
    }
    return near * far / (far - depth * (far - near));
}

// SSAO occlusion term (#188). Runs on its own full-screen pass into an R32Float texture, so
// `ssao_blur_fragment` can smooth the ordered-dither pattern out of it before `ssao_fragment`
// multiplies it into the scene. The result is `1 - occlusion * intensity` in [0, 1], 1 = open.
fragment float4 ssao_occlusion_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> depthTexture [[texture(0)]],
    constant SSAOParams &params [[buffer(0)]]
) {
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float depth = depthTexture.sample(pointSampler, in.texCoord).r;

    // Background (depth at or near 1.0) is never occluded.
    if (depth > 0.9999) {
        return float4(1.0, 0.0, 0.0, 1.0);
    }

    float linearDepth = linearizeDepth(depth, params.nearPlane, params.farPlane, params.orthographic);
    // The length the depth thresholds below are relative to ("a step of 5% of the distance"). In
    // perspective that is the view distance. An orthographic eye can sit anywhere on the line of
    // sight without changing the picture, so its distance to the surface says nothing about how
    // big a depth step is on screen; the height of the view in world units does, and is what
    // zooming changes, as moving closer does in perspective (#217).
    float depthScale = params.orthographic > 0.5
        ? 1.0 / max(params.pixelsPerUnit * params.texelSize.y, 1e-6)
        : linearDepth;
    float result_ao = 1.0;

    if (params.intensity > 0.001) {
        // Two-ring sample pattern: inner ring (tight creases) + outer ring (broader AO)
        const float2 offsets[16] = {
            // Inner ring (radius 1.0) — catches tight internal angles
            float2(-1.0,  0.0), float2( 1.0,  0.0),
            float2( 0.0, -1.0), float2( 0.0,  1.0),
            float2(-0.707, -0.707), float2( 0.707, -0.707),
            float2(-0.707,  0.707), float2( 0.707,  0.707),
            // Outer ring (radius 2.0) — broader ambient occlusion
            float2(-2.0,  0.0), float2( 2.0,  0.0),
            float2( 0.0, -2.0), float2( 0.0,  2.0),
            float2(-1.414, -1.414), float2( 1.414, -1.414),
            float2(-1.414,  1.414), float2( 1.414,  1.414)
        };

        float occlusion = 0.0;
        // Sample radius in pixels: `radius` world units projected at this pixel's depth. It
        // used to be `radius / depth` texels × 4, a fraction of a pixel at normal viewing
        // distances, so the samples hit the centre's own neighbours and AO never reached a
        // real crease. Clamped so close-ups don't sample half the screen.
        float radiusPx = params.radius * params.pixelsPerUnit
            / (params.orthographic > 0.5 ? 1.0 : max(linearDepth, 1e-4));
        radiusPx = clamp(radiusPx, 2.0, 64.0);

        // Surface-oriented test (#136 H6). A sample only occludes if it lies in FRONT of the
        // surface's tangent plane, i.e. in the normal-facing hemisphere. Comparing against the
        // centre depth instead made every sloped or curved surface occlude itself: half its
        // neighbours are always nearer the camera. The plane comes from the depth gradient:
        // the stored depth is affine in screen space across a plane (perspective and ortho),
        // so predicting it with a gradient is exact on flat faces. Each axis uses the smaller
        // one-sided difference so the gradient doesn't straddle a silhouette.
        float2 ts1 = params.texelSize;
        float dL = depthTexture.sample(pointSampler, in.texCoord - float2(ts1.x, 0.0)).r;
        float dR = depthTexture.sample(pointSampler, in.texCoord + float2(ts1.x, 0.0)).r;
        float dD = depthTexture.sample(pointSampler, in.texCoord - float2(0.0, ts1.y)).r;
        float dU = depthTexture.sample(pointSampler, in.texCoord + float2(0.0, ts1.y)).r;
        float gradX = (abs(depth - dL) < abs(dR - depth)) ? (depth - dL) : (dR - depth);
        float gradY = (abs(depth - dD) < abs(dU - depth)) ? (depth - dD) : (dU - depth);
        // Tolerance for depth-buffer precision and tessellation facets, relative to distance.
        float planeBias = 0.005 * depthScale;
        // Per-pixel kernel rotation and radius from a 4×4 ordered (Bayer) pattern, so the 16
        // fixed taps don't print their octagon outline onto the occlusion as hard-edged bands.
        // An ordered pattern reads as a fine, even dither rather than random grain.
        const float bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        uint2 cell = uint2(in.position.xy) & 3u;
        float noise = (bayer[cell.y * 4u + cell.x] + 0.5) / 16.0;
        float2 rot = float2(cos(noise * 0.7853982), sin(noise * 0.7853982));  // taps repeat every 45°
        // Radius jitter (decorrelated from the angle), so the rings don't show as halo bands.
        float ringScale = mix(0.6, 1.0, fract(noise * 5.0));

        for (int i = 0; i < 16; i++) {
            // Inner ring at half the radius, outer ring at the full radius. Offsets are
            // whole pixels: the depth is point-sampled, and a fractional offset would compare a
            // texel's depth with the plane predicted at a different point.
            float2 o = offsets[i] * (radiusPx * 0.5 * ringScale);
            float2 offsetPx = round(float2(o.x * rot.x - o.y * rot.y, o.x * rot.y + o.y * rot.x));
            float2 sampleUV = in.texCoord + offsetPx * params.texelSize;
            // Off-screen taps would read the clamped border texel, which is not geometry there.
            if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) continue;
            float sampleDepth = depthTexture.sample(pointSampler, sampleUV).r;
            float sampleLinear = linearizeDepth(sampleDepth, params.nearPlane, params.farPlane, params.orthographic);
            float planeDepth = saturate(depth + gradX * offsetPx.x + gradY * offsetPx.y);
            float planeLinear = linearizeDepth(planeDepth, params.nearPlane, params.farPlane, params.orthographic);

            float diff = planeLinear - sampleLinear;
            // Occluders more than the radius in front are a separate object floating in front,
            // not a crease: fade them out by twice the radius so they don't cast halos.
            float rangeCheck = 1.0 - smoothstep(params.radius, 2.0 * params.radius, diff);
            occlusion += smoothstep(planeBias, 2.0 * planeBias, diff) * rangeCheck;
        }

        result_ao = 1.0 - (occlusion / 16.0) * params.intensity;
        result_ao = clamp(result_ao, 0.0, 1.0);
    }

    return float4(result_ao, 0.0, 0.0, 1.0);
}

// Depth-aware blur of the SSAO term (#188). The occlusion pass rotates its kernel per pixel from
// a 4x4 ordered (Bayer) pattern; averaging a 4x4 window covers every cell of that pattern exactly
// once, so on a continuous surface the dither cancels. Taps are weighted by how well their depth
// matches the plane through the centre pixel (the same depth-gradient prediction the occlusion
// pass uses, so sloped and curved faces blur like flat ones), which keeps the blur from crossing
// a depth discontinuity: occlusion neither bleeds onto a nearer silhouette nor lightens the far
// side of it. Works on linearised depth, so it is the same in perspective and orthographic.
fragment float4 ssao_blur_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> aoTexture [[texture(0)]],
    texture2d<float> depthTexture [[texture(1)]],
    constant SSAOParams &params [[buffer(0)]]
) {
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float centreAO = aoTexture.sample(pointSampler, in.texCoord).r;
    float depth = depthTexture.sample(pointSampler, in.texCoord).r;
    if (depth > 0.9999) {
        return float4(centreAO, 0.0, 0.0, 1.0);
    }

    float2 ts = params.texelSize;
    float dL = depthTexture.sample(pointSampler, in.texCoord - float2(ts.x, 0.0)).r;
    float dR = depthTexture.sample(pointSampler, in.texCoord + float2(ts.x, 0.0)).r;
    float dD = depthTexture.sample(pointSampler, in.texCoord - float2(0.0, ts.y)).r;
    float dU = depthTexture.sample(pointSampler, in.texCoord + float2(0.0, ts.y)).r;
    float gradX = (abs(depth - dL) < abs(dR - depth)) ? (depth - dL) : (dR - depth);
    float gradY = (abs(depth - dD) < abs(dU - depth)) ? (depth - dD) : (dU - depth);

    float linearDepth = linearizeDepth(depth, params.nearPlane, params.farPlane, params.orthographic);
    // Same relative depth tolerance as the occlusion pass's plane bias: a tap further than twice
    // this from the centre's plane belongs to another surface and gets no weight.
    float tolerance = 0.005 * linearDepth;

    float sum = 0.0;
    float weightSum = 0.0;
    // Offsets -2...1 on both axes: exactly one period of the 4x4 pattern.
    for (int j = -2; j <= 1; j++) {
        for (int i = -2; i <= 1; i++) {
            float2 sampleUV = in.texCoord + float2(float(i), float(j)) * ts;
            // Off-screen taps would read the clamped border texel, which is not this surface.
            if (any(sampleUV < 0.0) || any(sampleUV > 1.0)) continue;
            float sampleDepth = depthTexture.sample(pointSampler, sampleUV).r;
            if (sampleDepth > 0.9999) continue;
            float planeDepth = saturate(depth + gradX * float(i) + gradY * float(j));
            float diff = abs(
                linearizeDepth(sampleDepth, params.nearPlane, params.farPlane, params.orthographic)
                - linearizeDepth(planeDepth, params.nearPlane, params.farPlane, params.orthographic));
            float weight = 1.0 - smoothstep(tolerance, 2.0 * tolerance, diff);
            sum += aoTexture.sample(pointSampler, sampleUV).r * weight;
            weightSum += weight;
        }
    }
    // The centre tap always has weight 1, so the sum is never empty.
    return float4(sum / max(weightSum, 1e-4), 0.0, 0.0, 1.0);
}

// SSAO-lite + Edge Silhouettes combined post-process
fragment float4 ssao_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> depthTexture [[texture(0)]],
    texture2d<float> colorTexture [[texture(1)]],
    texture2d<float> aoTexture [[texture(2)]],  // blurred SSAO term; read only when intensity > 0
    constant SSAOParams &params [[buffer(0)]]
) {
    constexpr sampler texSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float4 sceneColor = colorTexture.sample(texSampler, in.texCoord);
    float depth = depthTexture.sample(pointSampler, in.texCoord).r;

    // Skip background (depth at or near 1.0)
    if (depth > 0.9999) {
        return sceneColor;
    }

    float linearDepth = linearizeDepth(depth, params.nearPlane, params.farPlane, params.orthographic);
    // The length the silhouette and unsharp thresholds below are relative to: the view distance in
    // perspective, the height of the view in world units in orthographic (as in
    // `ssao_occlusion_fragment`, #217).
    float depthScale = params.orthographic > 0.5
        ? 1.0 / max(params.pixelsPerUnit * params.texelSize.y, 1e-6)
        : linearDepth;
    float result_ao = 1.0;
    float result_edge = 0.0;

    // --- SSAO ---
    // Read from the blurred occlusion texture (`ssao_occlusion_fragment` + `ssao_blur_fragment`,
    // #188). The renderers bind a placeholder when SSAO is off, and this branch is not taken.
    if (params.intensity > 0.001) {
        result_ao = aoTexture.sample(pointSampler, in.texCoord).r;
    }

    // --- Edge Silhouettes (Sobel on depth) ---
    if (params.silhouetteIntensity > 0.001) {
        float2 ts = params.texelSize * params.silhouetteThickness;

        // Sample 3x3 neighborhood depths
        float d00 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x, -ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d10 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(  0.0, -ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d20 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x, -ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d01 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x,   0.0)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d21 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x,   0.0)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d02 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x,  ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d12 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(  0.0,  ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);
        float d22 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x,  ts.y)).r, params.nearPlane, params.farPlane, params.orthographic);

        // Sobel X and Y
        float sobelX = -d00 + d20 - 2.0*d01 + 2.0*d21 - d02 + d22;
        float sobelY = -d00 - 2.0*d10 - d20 + d02 + 2.0*d12 + d22;

        // Normalize by center depth to make edges depth-invariant
        float edgeMag = sqrt(sobelX * sobelX + sobelY * sobelY) / max(depthScale, 0.01);

        // Threshold: raised to ignore subtle tessellation sub-triangle depth steps.
        // Only major feature edges (creases, silhouettes against background) trigger.
        result_edge = smoothstep(0.08, 0.4, edgeMag) * params.silhouetteIntensity;
    }

    // --- Depth Unsharp Masking ---
    // Computes average depth in a neighborhood and boosts contrast where depth
    // deviates from the local average, enhancing perception of depth separation
    // between adjacent faces. Only uses samples at similar depths to avoid
    // silhouette halo artifacts.
    float depthContrast = 1.0;
    if (params.intensity > 0.001) {
        float blurredDepth = 0.0;
        float validSamples = 0.0;
        const float2 unsharpOffsets[8] = {
            float2(-3.0,  0.0), float2( 3.0,  0.0),
            float2( 0.0, -3.0), float2( 0.0,  3.0),
            float2(-2.12, -2.12), float2( 2.12, -2.12),
            float2(-2.12,  2.12), float2( 2.12,  2.12)
        };
        for (int i = 0; i < 8; i++) {
            float2 sampleUV = in.texCoord + unsharpOffsets[i] * params.texelSize * 3.0;
            float rawDepth = depthTexture.sample(pointSampler, sampleUV).r;
            // Skip background samples to avoid silhouette halos
            if (rawDepth > 0.9999) continue;
            float sd = linearizeDepth(rawDepth, params.nearPlane, params.farPlane, params.orthographic);
            // Skip samples at very different depths (silhouette boundary)
            if (abs(sd - linearDepth) / max(depthScale, 0.01) > 0.3) continue;
            blurredDepth += sd;
            validSamples += 1.0;
        }

        if (validSamples > 2.0) {
            blurredDepth /= validSamples;
            float spatialImportance = (linearDepth - blurredDepth) / max(depthScale, 0.01);
            depthContrast = 1.0 + spatialImportance * 0.2;
            depthContrast = clamp(depthContrast, 0.85, 1.15);
        }
    }

    // Combine: darken by AO, edge silhouettes, and depth contrast. The colour target holds
    // sRGB, so decode, darken in linear, and re-encode once at the end.
    float3 finalColor = srgbToLinear(sceneColor.rgb) * result_ao * depthContrast;
    finalColor = mix(finalColor, srgbToLinear(float3(0.1, 0.1, 0.12)), result_edge);

    // --- Depth of Field (CoC-based disk blur) ---
    if (params.dofEnabled > 0.5) {
        float focalDist = params.dofFocalDistance;
        float aperture = max(params.dofAperture, 0.1);
        float maxBlur = params.dofMaxBlurRadius;

        // Circle of confusion diameter
        float coc = abs(linearDepth - focalDist) / aperture;
        coc = clamp(coc * maxBlur, 0.0, maxBlur);

        if (coc > 0.5) {
            // 8-tap disk blur
            float3 blurColor = float3(0.0);
            float totalWeight = 0.0;
            const float2 dofOffsets[8] = {
                float2( 1.0,  0.0), float2(-1.0,  0.0),
                float2( 0.0,  1.0), float2( 0.0, -1.0),
                float2( 0.707,  0.707), float2(-0.707,  0.707),
                float2( 0.707, -0.707), float2(-0.707, -0.707)
            };
            for (int i = 0; i < 8; i++) {
                float2 sampleUV = in.texCoord + dofOffsets[i] * params.texelSize * coc;
                float3 sampleColor = srgbToLinear(colorTexture.sample(texSampler, sampleUV).rgb);
                // Apply AO and depth contrast to sample too
                blurColor += sampleColor * result_ao * depthContrast;
                totalWeight += 1.0;
            }
            blurColor /= totalWeight;
            // Blend between sharp and blurred based on CoC
            float blendFactor = smoothstep(0.5, 2.0, coc);
            finalColor = mix(finalColor, blurColor, blendFactor);
        }
    }

    // Tone mapping is not done here: `shaded_fragment` already applied it to lit surfaces
    // (it must happen before the bgra8 colour target clips HDR values, and must also run
    // when this composite is skipped). Applying it again would double tone map.

    return float4(linearToSrgb(finalColor), sceneColor.a);
}

// MARK: - Temporal Anti-Aliasing Resolve

struct TAAParams {
    float  blendFactor;   // history weight (e.g. 0.9 for moving, N/(N+1) for progressive)
    float  disableClamp;  // 1.0 = skip neighborhood AABB clamp (use for static scenes)
    float2 jitterOffset;  // sub-pixel jitter applied this frame, in pixels
    float2 texelSize;
};

fragment float4 taa_resolve_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> currentTexture [[texture(0)]],
    texture2d<float> historyTexture [[texture(1)]],
    constant TAAParams &params [[buffer(0)]]
) {
    constexpr sampler texSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge);

    float4 current = currentTexture.sample(pointSampler, in.texCoord);

    // Sample history (unjitter by subtracting this frame's jitter)
    float2 historyUV = in.texCoord - params.jitterOffset * params.texelSize;
    float4 history = historyTexture.sample(texSampler, historyUV);

    // 3x3 neighborhood clamp reduces ghosting from rapid motion. Skip when
    // the scene is known static (progressive accumulation mode), since clamping
    // throws away valid super-sampled detail.
    if (params.disableClamp < 0.5) {
        float3 nearMin = current.rgb;
        float3 nearMax = current.rgb;
        const float2 offsets[8] = {
            float2(-1, -1), float2(0, -1), float2(1, -1),
            float2(-1,  0),                float2(1,  0),
            float2(-1,  1), float2(0,  1), float2(1,  1)
        };
        for (int i = 0; i < 8; i++) {
            float3 s = currentTexture.sample(pointSampler,
                in.texCoord + offsets[i] * params.texelSize).rgb;
            nearMin = min(nearMin, s);
            nearMax = max(nearMax, s);
        }
        history.rgb = clamp(history.rgb, nearMin, nearMax);
    }

    // Blend
    float4 result = mix(current, history, params.blendFactor);
    return result;
}

// MARK: - IBL Compute Kernels

// Equirectangular → Cubemap conversion
kernel void equirect_to_cubemap(
    texture2d<float, access::sample> equirect [[texture(0)]],
    texturecube<float, access::write> cubeMap [[texture(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint face = gid.z;
    uint size = cubeMap.get_width();
    if (gid.x >= size || gid.y >= size) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 dir;
    switch (face) {
        case 0: dir = float3( 1.0, -uv.y, -uv.x); break; // +X
        case 1: dir = float3(-1.0, -uv.y,  uv.x); break; // -X
        case 2: dir = float3( uv.x,  1.0,  uv.y); break; // +Y
        case 3: dir = float3( uv.x, -1.0, -uv.y); break; // -Y
        case 4: dir = float3( uv.x, -uv.y,  1.0); break; // +Z
        case 5: dir = float3(-uv.x, -uv.y, -1.0); break; // -Z
        default: dir = float3(0); break;
    }
    dir = normalize(dir);

    // Convert direction to equirectangular UV
    float phi = atan2(dir.z, dir.x);
    float theta = asin(clamp(dir.y, -1.0, 1.0));
    // Image row 0 is the top of the panorama (HDRLoader keeps the Y-down layout), so +Y (up)
    // must sample v = 0, not v = 1 — otherwise the sky lands underneath the scene.
    float2 eqUV = float2(phi / (2.0 * M_PI_F) + 0.5, 0.5 - theta / M_PI_F);

    constexpr sampler s(filter::linear, address::repeat);
    float4 color = equirect.sample(s, eqUV);
    cubeMap.write(color, gid.xy, face);
}

// Prefilter environment for specular IBL (roughness-based mip levels)
kernel void prefilter_environment(
    texturecube<float, access::sample> envMap [[texture(0)]],
    texturecube<float, access::write> filtered [[texture(1)]],
    constant float &roughness [[buffer(0)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint face = gid.z;
    uint size = filtered.get_width();
    if (gid.x >= size || gid.y >= size) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 N;
    switch (face) {
        case 0: N = normalize(float3( 1.0, -uv.y, -uv.x)); break;
        case 1: N = normalize(float3(-1.0, -uv.y,  uv.x)); break;
        case 2: N = normalize(float3( uv.x,  1.0,  uv.y)); break;
        case 3: N = normalize(float3( uv.x, -1.0, -uv.y)); break;
        case 4: N = normalize(float3( uv.x, -uv.y,  1.0)); break;
        case 5: N = normalize(float3(-uv.x, -uv.y, -1.0)); break;
        default: N = float3(0); break;
    }
    constexpr sampler s(filter::linear, mip_filter::linear, address::repeat);
    float totalWeight = 0.0;
    float3 prefilteredColor = float3(0.0);
    const uint SAMPLE_COUNT = 64u;

    for (uint i = 0u; i < SAMPLE_COUNT; i++) {
        // Hammersley sequence
        float fi = float(i);
        uint bits = i;
        bits = (bits << 16u) | (bits >> 16u);
        bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
        bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
        bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
        bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
        float2 Xi = float2(fi / float(SAMPLE_COUNT), float(bits) * 2.3283064365386963e-10);

        // GGX importance sampling
        float a = roughness * roughness;
        float phi = 2.0 * M_PI_F * Xi.x;
        float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
        float3 H = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

        // Tangent space to world
        float3 up = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
        float3 T = normalize(cross(up, N));
        float3 B = cross(N, T);
        float3 sampleDir = T * H.x + B * H.y + N * H.z;

        float NdotL = max(dot(N, sampleDir), 0.0);
        if (NdotL > 0.0) {
            prefilteredColor += envMap.sample(s, sampleDir).rgb * NdotL;
            totalWeight += NdotL;
        }
    }
    prefilteredColor /= max(totalWeight, 0.001);
    filtered.write(float4(prefilteredColor, 1.0), gid.xy, face);
}

// Diffuse irradiance convolution
kernel void irradiance_convolution(
    texturecube<float, access::sample> envMap [[texture(0)]],
    texturecube<float, access::write> irradiance [[texture(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    uint face = gid.z;
    uint size = irradiance.get_width();
    if (gid.x >= size || gid.y >= size) return;

    float2 uv = (float2(gid.xy) + 0.5) / float(size) * 2.0 - 1.0;
    float3 N;
    switch (face) {
        case 0: N = normalize(float3( 1.0, -uv.y, -uv.x)); break;
        case 1: N = normalize(float3(-1.0, -uv.y,  uv.x)); break;
        case 2: N = normalize(float3( uv.x,  1.0,  uv.y)); break;
        case 3: N = normalize(float3( uv.x, -1.0, -uv.y)); break;
        case 4: N = normalize(float3( uv.x, -uv.y,  1.0)); break;
        case 5: N = normalize(float3(-uv.x, -uv.y, -1.0)); break;
        default: N = float3(0); break;
    }

    constexpr sampler s(filter::linear, address::repeat);
    float3 irr = float3(0.0);
    float3 up = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 right = normalize(cross(up, N));
    up = cross(N, right);

    float sampleDelta = 0.05;
    float nrSamples = 0.0;
    for (float phi = 0.0; phi < 2.0 * M_PI_F; phi += sampleDelta) {
        for (float theta = 0.0; theta < 0.5 * M_PI_F; theta += sampleDelta) {
            float3 tangentSample = float3(sin(theta) * cos(phi),
                                           sin(theta) * sin(phi),
                                           cos(theta));
            float3 sampleVec = tangentSample.x * right + tangentSample.y * up + tangentSample.z * N;
            irr += envMap.sample(s, sampleVec).rgb * cos(theta) * sin(theta);
            nrSamples += 1.0;
        }
    }
    irr = M_PI_F * irr / max(nrSamples, 1.0);
    irradiance.write(float4(irr, 1.0), gid.xy, face);
}

// BRDF integration LUT (2D texture, x=NdotV, y=roughness → (scale, bias))
kernel void brdf_integration(
    texture2d<float, access::write> lut [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint size = lut.get_width();
    if (gid.x >= size || gid.y >= size) return;

    float NdotV = (float(gid.x) + 0.5) / float(size);
    float roughness = (float(gid.y) + 0.5) / float(size);
    NdotV = max(NdotV, 0.001);

    float3 V;
    V.x = sqrt(1.0 - NdotV * NdotV);
    V.y = 0.0;
    V.z = NdotV;

    float A = 0.0;
    float B = 0.0;
    const uint SAMPLE_COUNT = 256u;

    for (uint i = 0u; i < SAMPLE_COUNT; i++) {
        float fi = float(i);
        uint bits = i;
        bits = (bits << 16u) | (bits >> 16u);
        bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
        bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
        bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
        bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
        float2 Xi = float2(fi / float(SAMPLE_COUNT), float(bits) * 2.3283064365386963e-10);

        float a = roughness * roughness;
        float phi = 2.0 * M_PI_F * Xi.x;
        float cosTheta = sqrt((1.0 - Xi.y) / (1.0 + (a * a - 1.0) * Xi.y));
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
        float3 H = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
        float3 L = normalize(2.0 * dot(V, H) * H - V);

        float NdotL_s = max(L.z, 0.0);
        float NdotH = max(H.z, 0.0);
        float VdotH = max(dot(V, H), 0.0);

        if (NdotL_s > 0.0) {
            float G = geometrySmith(NdotV, NdotL_s, roughness);
            float G_Vis = (G * VdotH) / (NdotH * NdotV + 0.0001);
            float Fc = pow(1.0 - VdotH, 5.0);
            A += (1.0 - Fc) * G_Vis;
            B += Fc * G_Vis;
        }
    }
    A /= float(SAMPLE_COUNT);
    B /= float(SAMPLE_COUNT);
    lut.write(float4(A, B, 0.0, 1.0), gid);
}

// =====================================================================
// MARK: - Hardware Tessellation (PN Triangles)
// =====================================================================

// Per-patch data: 10 Bezier control points + 3 corner normals.
// Uses packed_float3 (12 bytes, alignment 4) to avoid float3's 16-byte padding.
// Total: 13 * 12 = 156 bytes per patch; TessellationManager.patchStride must match.
struct PNPatchData {
    packed_float3 b300, b030, b003;           // Corner positions
    packed_float3 b210, b120, b201, b102, b021, b012; // Edge control points
    packed_float3 b111;                        // Center control point
    packed_float3 n200, n020, n002;           // Corner normals
};

// The cubic Bezier triangle at barycentric `bary`. Every post-tessellation vertex function
// evaluates the surface through this one function, so the shaded, shadow, depth, pick,
// highlight, stencil-mask and selection-mask passes produce bit-identical positions and the
// `.lessEqual` highlight wins its depth tie with the shaded surface (#202).
//
// That relies on the compiler emitting the same arithmetic for the same expression in every
// pipeline. Apple GPUs do, but Metal only guarantees it for [[invariant]] positions in a library
// compiled with preserveInvariance, which the build-time default.metallib cannot be (SwiftPM and
// Xcode pass no such flag to it). Compiling the source at run time was considered and deferred
// (#209 item 3): revisit if the build-time metallib gains a preserve-invariance option, or if a
// highlight z-fights its tessellated surface.
inline float3 pnPatchPosition(PNPatchData p, float3 bary) {
    float u = bary.x, v = bary.y, w = bary.z;
    float uu = u*u, vv = v*v, ww = w*w;
    return p.b300*uu*u + p.b030*vv*v + p.b003*ww*w
         + p.b210*3.0*uu*v + p.b120*3.0*u*vv
         + p.b201*3.0*uu*w + p.b102*3.0*u*ww
         + p.b021*3.0*vv*w + p.b012*3.0*v*ww
         + p.b111*6.0*u*v*w;
}

// Tessellation factor parameters
struct TessFactorParams {
    float4x4 viewProjectionMatrix;
    float2 viewportSize;
    float targetEdgePixels;    // Target pixels per edge (adaptive mode)
    float maxFactor;           // Max tessellation factor (clamped to 2...64 on the Swift side)
    float uniformFactor;       // > 0: uniform tessellation at this factor (adaptive off)
    float _pad0;
    float _pad1;
    float _pad2;
};

// --- Compute kernel: Build PN triangle patches from triangle mesh ---

kernel void compute_pn_patches(
    device float*       vertices     [[buffer(0)]],  // stride 6: px,py,pz,nx,ny,nz
    device uint32_t*    indices      [[buffer(1)]],  // 3 per triangle
    device PNPatchData* patches      [[buffer(2)]],  // output: 1 per triangle
    constant uint&      triangleCount [[buffer(3)]],
    constant float&     creaseCos    [[buffer(4)]],  // cos(normalSmoothingCreaseAngle), #202
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= triangleCount) return;

    // Read triangle vertex data
    uint i0 = indices[gid * 3];
    uint i1 = indices[gid * 3 + 1];
    uint i2 = indices[gid * 3 + 2];

    float3 p0 = float3(vertices[i0*6], vertices[i0*6+1], vertices[i0*6+2]);
    float3 p1 = float3(vertices[i1*6], vertices[i1*6+1], vertices[i1*6+2]);
    float3 p2 = float3(vertices[i2*6], vertices[i2*6+1], vertices[i2*6+2]);

    float3 n0 = normalize(float3(vertices[i0*6+3], vertices[i0*6+4], vertices[i0*6+5]));
    float3 n1 = normalize(float3(vertices[i1*6+3], vertices[i1*6+4], vertices[i1*6+5]));
    float3 n2 = normalize(float3(vertices[i2*6+3], vertices[i2*6+4], vertices[i2*6+5]));

    // Corner control points
    float3 b300 = p0;
    float3 b030 = p1;
    float3 b003 = p2;

    // Crease detection: if normals differ by more than ~30 degrees along an edge,
    // keep that edge flat (linear interpolation) to prevent scalloping artifacts
    // at sharp feature edges like cylinder-side-to-cap transitions.
    // The threshold is normalSmoothingCreaseAngle, the angle crease-aware smoothing uses, so a
    // coarse mesh whose neighbouring normals differ by more than a fixed 30° still rounds when the
    // app raises it (#202).
    bool edge01_smooth = dot(n0, n1) > creaseCos;
    bool edge02_smooth = dot(n0, n2) > creaseCos;
    bool edge12_smooth = dot(n1, n2) > creaseCos;

    // Linear 1/3 and 2/3 points for flat edges
    float3 lin_b210 = (2.0 * p0 + p1) / 3.0;
    float3 lin_b120 = (p0 + 2.0 * p1) / 3.0;
    float3 lin_b201 = (2.0 * p0 + p2) / 3.0;
    float3 lin_b102 = (p0 + 2.0 * p2) / 3.0;
    float3 lin_b021 = (2.0 * p1 + p2) / 3.0;
    float3 lin_b012 = (p1 + 2.0 * p2) / 3.0;

    // Edge control points: project 1/3 and 2/3 edge points onto tangent planes
    // wij = dot(pj - pi, ni)  =>  bij = (2*pi + pj - wij*ni) / 3
    float3 b210, b120, b201, b102, b021, b012;

    // PN amplification: 1.0 = mathematically correct PN triangles.
    // Higher values exaggerate curvature (useful for coarse meshes).
    float pnScale = 1.0;

    if (edge01_smooth) {
        float w01 = dot(p1 - p0, n0) * pnScale;
        float w10 = dot(p0 - p1, n1) * pnScale;
        b210 = (2.0 * p0 + p1 - w01 * n0) / 3.0;
        b120 = (2.0 * p1 + p0 - w10 * n1) / 3.0;
    } else {
        b210 = lin_b210;
        b120 = lin_b120;
    }

    if (edge02_smooth) {
        float w02 = dot(p2 - p0, n0) * pnScale;
        float w20 = dot(p0 - p2, n2) * pnScale;
        b201 = (2.0 * p0 + p2 - w02 * n0) / 3.0;
        b102 = (2.0 * p2 + p0 - w20 * n2) / 3.0;
    } else {
        b201 = lin_b201;
        b102 = lin_b102;
    }

    if (edge12_smooth) {
        float w12 = dot(p2 - p1, n1) * pnScale;
        float w21 = dot(p1 - p2, n2) * pnScale;
        b021 = (2.0 * p1 + p2 - w12 * n1) / 3.0;
        b012 = (2.0 * p2 + p1 - w21 * n2) / 3.0;
    } else {
        b021 = lin_b021;
        b012 = lin_b012;
    }

    // Center control point with correction
    float3 E = (b210 + b120 + b201 + b102 + b021 + b012) / 6.0;
    float3 V = (p0 + p1 + p2) / 3.0;
    float3 b111 = E + (E - V) * 0.5;

    // Write patch
    PNPatchData patch;
    patch.b300 = b300; patch.b030 = b030; patch.b003 = b003;
    patch.b210 = b210; patch.b120 = b120;
    patch.b201 = b201; patch.b102 = b102;
    patch.b021 = b021; patch.b012 = b012;
    patch.b111 = b111;
    patch.n200 = n0; patch.n020 = n1; patch.n002 = n2;
    patches[gid] = patch;
}

// --- Compute kernel: Adaptive tessellation factors ---

kernel void compute_tess_factors(
    device PNPatchData*                          patches  [[buffer(0)]],
    device MTLTriangleTessellationFactorsHalf*   factors  [[buffer(1)]],
    constant TessFactorParams&                   params   [[buffer(2)]],
    constant uint&                               patchCount [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= patchCount) return;

    PNPatchData patch = patches[gid];

    // Project corners to screen space
    float4 c0 = params.viewProjectionMatrix * float4(patch.b300, 1.0);
    float4 c1 = params.viewProjectionMatrix * float4(patch.b030, 1.0);
    float4 c2 = params.viewProjectionMatrix * float4(patch.b003, 1.0);

    // NDC → pixel coordinates
    float2 s0 = (c0.xy / c0.w * 0.5 + 0.5) * params.viewportSize;
    float2 s1 = (c1.xy / c1.w * 0.5 + 0.5) * params.viewportSize;
    float2 s2 = (c2.xy / c2.w * 0.5 + 0.5) * params.viewportSize;

    // Edge lengths in pixels
    float e0 = length(s1 - s2); // edge opposite vertex 0
    float e1 = length(s0 - s2); // edge opposite vertex 1
    float e2 = length(s0 - s1); // edge opposite vertex 2

    // Curvature boost: if normals differ, the surface is curved and needs more subdivision.
    // Even small normal differences produce visible silhouette faceting.
    float nd01 = 1.0 - dot(patch.n200, patch.n020);
    float nd02 = 1.0 - dot(patch.n200, patch.n002);
    float nd12 = 1.0 - dot(patch.n020, patch.n002);

    // Aggressive curvature boost: flat triangles get factor 1, curved get up to 4x
    float curvBoost2 = 1.0 + nd01 * 8.0; // edge 2 (v0-v1)
    float curvBoost0 = 1.0 + nd12 * 8.0; // edge 0 (v1-v2)
    float curvBoost1 = 1.0 + nd02 * 8.0; // edge 1 (v0-v2)

    float target = max(params.targetEdgePixels, 1.0);
    float maxF = params.maxFactor;

    // Edge factors
    half f0 = half(clamp(e0 * curvBoost0 / target, 1.0, maxF));
    half f1 = half(clamp(e1 * curvBoost1 / target, 1.0, maxF));
    half f2 = half(clamp(e2 * curvBoost2 / target, 1.0, maxF));

    // Inside factor: average of edge factors
    half fInside = half(clamp(float(f0 + f1 + f2) / 3.0, 1.0, maxF));

    // Uniform mode (adaptiveTessellation == false): one fixed factor for every patch.
    if (params.uniformFactor > 0.0) {
        half fu = half(clamp(params.uniformFactor, 1.0, maxF));
        f0 = fu; f1 = fu; f2 = fu; fInside = fu;
    }

    // Handle degenerate/behind-camera patches: if any w <= 0, use factor 1
    if (c0.w <= 0.001 || c1.w <= 0.001 || c2.w <= 0.001) {
        f0 = 1; f1 = 1; f2 = 1; fInside = 1;
    }

    MTLTriangleTessellationFactorsHalf tf;
    tf.edgeTessellationFactor[0] = f0;
    tf.edgeTessellationFactor[1] = f1;
    tf.edgeTessellationFactor[2] = f2;
    tf.insideTessellationFactor = fInside;
    factors[gid] = tf;
}

// --- Post-tessellation vertex function: evaluate PN triangle ---

// Patch k is triangle k, so its three corners' per-vertex colours (#142) are `vertexColors` at
// `indices[3k...3k+2]`, blended with the same barycentric weights as the normal. They are bound,
// with the mode, on every draw and only read when the mode is non-zero.
[[patch(triangle, 3)]]
vertex ShadedVertexOut tessellated_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    const device uint* indices [[buffer(2)]],
    const device float4* vertexColors [[buffer(3)]],
    constant uint& vertexColorMode [[buffer(4)]]
) {
    PNPatchData p = patches[patchID];

    float u = bary.x;  // weight for b300 (vertex 0)
    float v = bary.y;  // weight for b030 (vertex 1)
    float w = bary.z;  // weight for b003 (vertex 2)

    // Evaluate cubic Bezier triangle
    float3 pos = pnPatchPosition(p, bary);

    // Quadratically interpolate normals
    float3 normal = normalize(p.n200 * u + p.n020 * v + p.n002 * w);

    // Transform to world space
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);

    ShadedVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldNormal = normalize(uniforms.normalMatrix * normal);
    out.worldPosition = worldPos.xyz;
    out.viewNormal = normalize((uniforms.viewMatrix * float4(out.worldNormal, 0.0)).xyz);
    out.clipPositionCopy = out.clipPosition;
    out.vertexColorMode = vertexColorMode;
    out.vertexColor = float3(1.0);
    if ((vertexColorMode & 3u) != 0u) {
        out.vertexColor = vertexColors[indices[patchID * 3]].rgb * u
                        + vertexColors[indices[patchID * 3 + 1]].rgb * v
                        + vertexColors[indices[patchID * 3 + 2]].rgb * w;
    }
    return out;
}

// --- Post-tessellation shadow vertex ---

[[patch(triangle, 3)]]
vertex ShadowVertexOut tessellated_shadow_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant ShadowUniforms& uniforms [[buffer(1)]]
) {
    PNPatchData p = patches[patchID];
    float3 pos = pnPatchPosition(p, bary);

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    ShadowVertexOut out;
    out.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

// --- Post-tessellation depth-only vertex ---

[[patch(triangle, 3)]]
vertex PickVertexOut tessellated_depth_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    PNPatchData p = patches[patchID];
    float3 pos = pnPatchPosition(p, bary);

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    PickVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

// --- Post-tessellation pick vertex ---

struct TessPatchPickVertexOut {
    float4 clipPosition [[position]];
    // Input triangle index. Patches are built one per triangle (compute_pn_patches writes
    // patches[gid] for triangle gid) and drawn with patchStart 0 and no patch index buffer, so
    // [[patch_id]] is the triangle index PickResult.triangleIndex promises (issue #136, H7).
    uint triangleIndex [[flat]];
    float3 worldPosition;    // for clip plane testing
};

[[patch(triangle, 3)]]
vertex TessPatchPickVertexOut tessellated_pick_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    PNPatchData p = patches[patchID];
    float3 pos = pnPatchPosition(p, bary);

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    TessPatchPickVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.triangleIndex = patchID;
    out.worldPosition = worldPos.xyz;
    return out;
}

// Pick fragment for tessellated patches — uses the patch (input triangle) index, not
// primitive_id, which would count post-tessellation sub-triangles.
// Kind tag stays 0 (face).
fragment PickFragmentOut tessellated_pick_fragment(
    TessPatchPickVertexOut in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]],
    constant BodyUniforms& bodyUniforms [[buffer(2)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, in.triangleIndex, 0u);
    return out;
}

// --- Overlay passes on the PN-tessellated surface (#202) ---
//
// The per-triangle highlight, the selection stencil mask and the selection mask used to draw the
// flat input mesh over a PN-bulged surface: a `.lessEqual` highlight then lost the depth test
// where the surface bulged in front of it, and the outline ring sat inside the tessellated
// silhouette. These post-tessellation vertex functions (and `tessellated_depth_vertex`, which the
// two masks use) evaluate the same Bezier patch as `tessellated_vertex`, so the passes cover
// exactly the surface that was drawn.

struct TessHighlightVertexOut {
    float4 clipPosition [[position]];
    float3 worldPosition [[centroid_perspective]];  // MSAA-safe clip test (#164)
    // Input triangle index: one patch per triangle, drawn with patchStart 0 (see
    // TessPatchPickVertexOut), so it indexes the per-triangle style buffer.
    uint triangleIndex [[flat]];
};

[[patch(triangle, 3)]]
vertex TessHighlightVertexOut tessellated_highlight_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(patches[patchID], bary), 1.0);
    TessHighlightVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.triangleIndex = patchID;
    return out;
}

fragment HighlightFragmentOut tessellated_highlight_fragment(
    TessHighlightVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant float4 *triangleStyles [[buffer(2)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    float4 style = triangleStyles[in.triangleIndex];
    if (style.a <= 0.0) discard_fragment();
    HighlightFragmentOut out;
    out.color = style;
    return out;
}

// =====================================================================
// MARK: - Mesh Shaders (Apple9+ / M3+ / A17+)
// =====================================================================
#if __METAL_VERSION__ >= 310

#include <metal_mesh>
using metal::mesh;

// Meshlet descriptor — must match Swift MeshletDescriptor layout
struct MeshletDesc {
    float3 center;
    float  radius;
    float3 coneAxis;
    float  coneCutoff;
    uint   vertexOffset;
    uint   vertexCount;
    uint   triangleOffset;
    uint   triangleCount;
};

// --- PN-triangle subdivision in the mesh stage (#175) ---
//
// At `.maximum` a meshlet's triangles are subdivided like the hardware-tessellated path
// (`tessellated_vertex`): each input triangle is evaluated as the cubic Bezier patch
// `compute_pn_patches` built for it (`pnPatchPosition`), on a barycentric grid of M segments per
// edge, so the shaded, shadow-map, depth, pick, highlight and selection-mask passes all draw the
// same surface as `.enhanced`.
//
// The factors come from the same per-patch buffer `compute_tess_factors` fills for the hardware
// path each frame, so `tessellationMaxFactor`, `adaptiveTessellation` and
// `uniformTessellationFactor` act on meshlets too. Each edge factor is rounded up to an integer
// segment count 1...PN_MAX_SEGMENTS. The edge factors of the triangles that share an edge agree,
// and the grid's boundary vertices are snapped onto that edge's own segment count, so
// neighbouring triangles, and meshlets, subdivided at different levels still meet without cracks.
//
// A mesh threadgroup can write 256 vertices and 512 primitives, and one meshlet of 64 triangles at
// M = 2 already needs 384 vertices, so the object stage splits a meshlet into "chunks" of whole
// triangles that fit (`pnPlanMeshlet`) and launches one mesh threadgroup per chunk. The vertices
// of a triangle are not shared with its neighbours, as in the hardware path.
//
// Mesh output sizes are the hardware maxima. PN_MAX_SEGMENTS = 16 caps the subdivision: one
// triangle (153 vertices, 256 primitives) then always fits a chunk, and a 4 px segment spans a
// 64 px edge. The hardware path goes up to 64; the cap is mirrored by `kMeshletMaxSegments` in
// MeshletBuilder.swift.
#define PN_MAX_SEGMENTS 16u
#define PN_MAX_MESHLET_TRIANGLES 64u
#define PN_CHUNK_VERTICES 256u
#define PN_CHUNK_PRIMITIVES 512u
#define PN_MESH_THREADS 128u

// Payload passed from object shader to mesh shader: the meshlet, how its triangles are split into
// chunks, and each triangle's segment counts.
struct MeshletPayload {
    uint meshletIndex;
    uint chunkCount;
    uint chunkFirst[PN_MAX_MESHLET_TRIANGLES + 1];  // meshlet-local first triangle of each chunk
    uchar4 segments[PN_MAX_MESHLET_TRIANGLES];      // per triangle: M, edge 0, edge 1, edge 2
};

// Segments per edge for a tessellation factor: the next integer up, 1...PN_MAX_SEGMENTS.
inline uint pnEdgeSegments(half factor) {
    return clamp(uint(ceil(float(factor))), 1u, PN_MAX_SEGMENTS);
}

// (M, F0, F1, F2) for one triangle: F_e is the segment count of edge e (edge 0 is u = 0, between
// vertices 1 and 2; edge 1 is v = 0; edge 2 is w = 0, as in compute_tess_factors) and M is the
// interior grid's segment count, the largest of them and the inside factor.
inline uchar4 pnTriangleSegments(MTLTriangleTessellationFactorsHalf f) {
    uint f0 = pnEdgeSegments(f.edgeTessellationFactor[0]);
    uint f1 = pnEdgeSegments(f.edgeTessellationFactor[1]);
    uint f2 = pnEdgeSegments(f.edgeTessellationFactor[2]);
    uint m = max(max(f0, f1), max(f2, pnEdgeSegments(f.insideTessellationFactor)));
    return uchar4(m, f0, f1, f2);
}

// Vertices and primitives of a triangle subdivided into M segments per edge.
inline uint pnVertexCount(uint m) { return (m + 1u) * (m + 2u) / 2u; }
inline uint pnPrimitiveCount(uint m) { return m * m; }

// Splits a meshlet's triangles into chunks that each fit one mesh threadgroup's output and writes
// the payload. Returns the number of chunks, which is the mesh grid size.
inline uint pnPlanMeshlet(
    object_data MeshletPayload& payload, uint meshletIndex, uint triangleOffset,
    uint triangleCount, device const MTLTriangleTessellationFactorsHalf* factors
) {
    payload.meshletIndex = meshletIndex;
    payload.chunkFirst[0] = 0;
    uint chunk = 0, vertices = 0, primitives = 0;
    for (uint t = 0; t < triangleCount; t++) {
        uchar4 seg = pnTriangleSegments(factors[triangleOffset + t]);
        uint v = pnVertexCount(seg.x);
        uint p = pnPrimitiveCount(seg.x);
        if (vertices + v > PN_CHUNK_VERTICES || primitives + p > PN_CHUNK_PRIMITIVES) {
            chunk++;
            payload.chunkFirst[chunk] = t;
            vertices = 0;
            primitives = 0;
        }
        vertices += v;
        primitives += p;
        payload.segments[t] = seg;
    }
    payload.chunkFirst[chunk + 1] = triangleCount;
    payload.chunkCount = chunk + 1;
    return chunk + 1;
}

// Where each triangle of a chunk starts in the chunk's vertex and primitive output.
struct PNChunkLayout {
    uint vertexBase[PN_MAX_MESHLET_TRIANGLES + 1];
    uint primitiveBase[PN_MAX_MESHLET_TRIANGLES + 1];  // [count] is the chunk's total
};

// Fills `layout` for the chunk `[first, first + count)`. Every thread of the threadgroup must
// call it: it ends in a barrier.
inline void pnBuildLayout(
    threadgroup PNChunkLayout& layout, object_data const MeshletPayload& payload,
    uint first, uint count, uint tid
) {
    if (tid == 0) {
        uint v = 0, p = 0;
        for (uint i = 0; i < count; i++) {
            uint m = payload.segments[first + i].x;
            layout.vertexBase[i] = v;
            layout.primitiveBase[i] = p;
            v += pnVertexCount(m);
            p += pnPrimitiveCount(m);
        }
        layout.vertexBase[count] = v;
        layout.primitiveBase[count] = p;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
}

// The triangle of a chunk (0...count-1) whose output range contains `slot`.
inline uint pnFindTriangle(threadgroup const uint* base, uint count, uint slot) {
    uint lo = 0, hi = count;
    while (hi - lo > 1u) {
        uint mid = (lo + hi) >> 1;
        if (base[mid] <= slot) { lo = mid; } else { hi = mid; }
    }
    return lo;
}

// Index of grid vertex (a, b) in a triangle of M segments: rows of constant b, `M - b + 1` long.
inline uint pnGridIndex(uint a, uint b, uint m) {
    return b * (m + 1u) - ((b * (b - 1u)) >> 1) + a;
}

// Grid coordinates (a, b) of the vertex at `index`, the inverse of pnGridIndex.
inline uint2 pnGridCoordinates(uint index, uint m) {
    uint b = 0, rowStart = 0;
    for (; b < m; b++) {
        uint rowLength = m - b + 1u;
        if (index < rowStart + rowLength) { break; }
        rowStart += rowLength;
    }
    return uint2(index - rowStart, b);
}

// Barycentric (u, v, w) of grid vertex (a, b): u weighs the first corner, v the second, w the
// third. A vertex on an edge is moved to the nearest vertex at or before it on that edge's own
// F-segment subdivision, so the two triangles sharing the edge place identical vertices on it
// whatever their interior resolutions.
inline float3 pnBarycentric(uint a, uint b, uchar4 seg) {
    uint m = seg.x;
    uint c = m - a - b;
    if (b == 0u) {            // w = 0, vertices 0 to 1
        uint f = seg.w, k = (a * f) / m;
        return float3(float(f - k) / float(f), float(k) / float(f), 0.0);
    }
    if (a == 0u) {            // v = 0, vertices 0 to 2
        uint f = seg.z, k = (b * f) / m;
        return float3(float(f - k) / float(f), 0.0, float(k) / float(f));
    }
    if (c == 0u) {            // u = 0, vertices 1 to 2
        uint f = seg.y, k = (b * f) / m;
        return float3(0.0, float(f - k) / float(f), float(k) / float(f));
    }
    return float3(float(c), float(a), float(b)) / float(m);
}

// One output vertex: the triangle (meshlet-local) it belongs to and its barycentric coordinates.
struct PNVertexRef {
    uint triangle;
    float3 bary;
};

inline PNVertexRef pnLocateVertex(
    threadgroup const PNChunkLayout& layout, object_data const MeshletPayload& payload,
    uint first, uint count, uint slot
) {
    uint i = pnFindTriangle(layout.vertexBase, count, slot);
    uchar4 seg = payload.segments[first + i];
    uint2 ab = pnGridCoordinates(slot - layout.vertexBase[i], seg.x);
    PNVertexRef ref;
    ref.triangle = first + i;
    ref.bary = pnBarycentric(ab.x, ab.y, seg);
    return ref;
}

// One output primitive: its triangle (meshlet-local) and the chunk-local indices of its corners.
struct PNPrimitiveRef {
    uint triangle;
    uint3 corners;
};

inline PNPrimitiveRef pnLocatePrimitive(
    threadgroup const PNChunkLayout& layout, object_data const MeshletPayload& payload,
    uint first, uint count, uint slot
) {
    uint i = pnFindTriangle(layout.primitiveBase, count, slot);
    uint m = payload.segments[first + i].x;
    uint q = slot - layout.primitiveBase[i];
    // Row b holds M - b upward triangles and M - b - 1 downward ones, interleaved.
    uint b = 0, rowStart = 0;
    for (; b + 1u < m; b++) {
        uint rowLength = 2u * (m - b) - 1u;
        if (q < rowStart + rowLength) { break; }
        rowStart += rowLength;
    }
    uint k = q - rowStart;
    uint a = k >> 1;
    uint base = layout.vertexBase[i];
    PNPrimitiveRef ref;
    ref.triangle = first + i;
    // Both keep the winding of the input triangle.
    if ((k & 1u) == 0u) {
        ref.corners = uint3(
            pnGridIndex(a, b, m), pnGridIndex(a + 1u, b, m), pnGridIndex(a, b + 1u, m));
    } else {
        ref.corners = uint3(
            pnGridIndex(a + 1u, b, m), pnGridIndex(a + 1u, b + 1u, m),
            pnGridIndex(a, b + 1u, m));
    }
    ref.corners += base;
    return ref;
}

// Mesh shader output vertex — matches ShadedVertexOut for fragment reuse
struct MeshVertex {
    float4 clipPosition [[position]];
    float3 worldNormal;
    float3 worldPosition [[centroid_perspective]];  // as ShadedVertexOut (#164)
    float3 viewNormal;
    float4 clipPositionCopy;
    float3 vertexColor;              // per-vertex colour (#142), as ShadedVertexOut
    uint   vertexColorMode [[flat]];
};

// Mesh output type: triangles, up to a chunk's vertices and primitives (see PN_CHUNK_*).
using ShadedMeshOutput =
    mesh<MeshVertex, void, PN_CHUNK_VERTICES, PN_CHUNK_PRIMITIVES, topology::triangle>;

// --- Object shaders: per-meshlet behind-camera culling ---
//
// Meshlet bounds are in the body's local space, so they go through modelMatrix first. There is
// deliberately no normal-cone backface cull: the standard and tessellated paths draw back faces
// (no cull mode), and the old cone test ran in local space against a world-space camera, so it
// removed front-facing meshlets of rotated or moved bodies and back faces (open shells, clip
// sections) that every other path draws.
//
// The scene passes read `Uniforms` (meshlet_object); the shadow map reads the 128-byte
// ShadowUniforms (meshlet_shadow_object). They are separate functions because Metal validates a
// bound buffer against the struct its function declares: the shadow pass used to bind
// ShadowUniforms at meshlet_object's `Uniforms` slot, which aborts under MTL_DEBUG_LAYER and
// otherwise reads past the bound bytes (#229). Both share meshletInFront.

// Whether any of the meshlet's world-space bounding sphere is in front of the eye of
// `viewProjection` (the camera, or the light for the shadow map).
inline bool meshletInFront(MeshletDesc m, float4x4 viewProjection, float4x4 modelMatrix) {
    // World-space bounding sphere: transform the centre and scale the radius by the largest
    // axis scale, so the sphere stays conservative under non-uniform scale.
    float4 worldCenter = modelMatrix * float4(m.center, 1.0);
    float maxScale = max(length(modelMatrix[0].xyz),
                         max(length(modelMatrix[1].xyz),
                             length(modelMatrix[2].xyz)));
    float worldRadius = m.radius * maxScale;

    // Behind-camera check (a full 6-plane frustum test could be added later).
    float4 centerClip = viewProjection * worldCenter;
    return centerClip.w + worldRadius >= 0.01;
}

[[object, max_total_threads_per_threadgroup(1)]]
void meshlet_object(
    object_data MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    device const MTLTriangleTessellationFactorsHalf* factors [[buffer(2)]],
    uint gid [[threadgroup_position_in_grid]],
    mesh_grid_properties mgp
) {
    MeshletDesc m = meshlets[gid];
    if (meshletInFront(m, uniforms.viewProjectionMatrix, uniforms.modelMatrix)) {
        uint chunks = pnPlanMeshlet(payload, gid, m.triangleOffset, m.triangleCount, factors);
        mgp.set_threadgroups_per_grid(uint3(chunks, 1, 1));
    } else {
        mgp.set_threadgroups_per_grid(uint3(0, 0, 0));
    }
}

[[object, max_total_threads_per_threadgroup(1)]]
void meshlet_shadow_object(
    object_data MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant ShadowUniforms& uniforms [[buffer(1)]],
    device const MTLTriangleTessellationFactorsHalf* factors [[buffer(2)]],
    uint gid [[threadgroup_position_in_grid]],
    mesh_grid_properties mgp
) {
    MeshletDesc m = meshlets[gid];
    if (meshletInFront(m, uniforms.lightViewProjectionMatrix, uniforms.modelMatrix)) {
        uint chunks = pnPlanMeshlet(payload, gid, m.triangleOffset, m.triangleCount, factors);
        mgp.set_threadgroups_per_grid(uint3(chunks, 1, 1));
    } else {
        mgp.set_threadgroups_per_grid(uint3(0, 0, 0));
    }
}

// --- Mesh shader: emit PN-subdivided triangles ---
//
// Every mesh function below follows the same shape: rebuild the chunk's layout, then run a strided
// loop over its vertices and one over its primitives. A vertex is a point of one input triangle's
// PN patch, evaluated with `pnPatchPosition` exactly as the tessellated path does, so all the
// passes place a surface point identically. `patches` holds one PNPatchData per input triangle
// and `m.triangleOffset + ref.triangle` is the input triangle's index (MeshletBuilder keeps
// triangles in input order).

[[mesh, max_total_threads_per_threadgroup(PN_MESH_THREADS)]]
void meshlet_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    device uint32_t* vertexIndices [[buffer(2)]],  // meshlet vertex index buffer
    device uint8_t* triangleIndices [[buffer(3)]],  // meshlet triangle index buffer (3 per tri)
    constant Uniforms& uniforms [[buffer(4)]],
    const device float4* vertexColors [[buffer(5)]],  // per-vertex colour (#142), by globalIdx
    constant uint& vertexColorMode [[buffer(6)]],     // 0 = ignored; bound on every shaded draw
    const device PNPatchData* patches [[buffer(7)]],
    ShadedMeshOutput output,
    uint tid [[thread_index_in_threadgroup]],
    uint chunk [[threadgroup_position_in_grid]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    uint first = payload.chunkFirst[chunk];
    uint count = payload.chunkFirst[chunk + 1] - first;
    threadgroup PNChunkLayout layout;
    pnBuildLayout(layout, payload, first, count, tid);
    output.set_primitive_count(layout.primitiveBase[count]);

    for (uint slot = tid; slot < layout.vertexBase[count]; slot += PN_MESH_THREADS) {
        PNVertexRef ref = pnLocateVertex(layout, payload, first, count, slot);
        uint triangle = m.triangleOffset + ref.triangle;
        PNPatchData p = patches[triangle];
        float u = ref.bary.x, v = ref.bary.y, w = ref.bary.z;

        // As tessellated_vertex: the corner normals blended by the barycentric weights, and the
        // per-vertex colours (#142) of the triangle's three corners.
        float3 normal = normalize(p.n200 * u + p.n020 * v + p.n002 * w);
        float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(p, ref.bary), 1.0);

        MeshVertex vert;
        vert.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        vert.worldNormal = normalize(uniforms.normalMatrix * normal);
        vert.worldPosition = worldPos.xyz;
        vert.viewNormal = normalize((uniforms.viewMatrix * float4(vert.worldNormal, 0.0)).xyz);
        vert.clipPositionCopy = vert.clipPosition;
        vert.vertexColorMode = vertexColorMode;
        vert.vertexColor = float3(1.0);
        if ((vertexColorMode & 3u) != 0u) {
            uint corner = triangle * 3;
            vert.vertexColor =
                vertexColors[vertexIndices[m.vertexOffset + triangleIndices[corner]]].rgb * u
                + vertexColors[vertexIndices[m.vertexOffset + triangleIndices[corner + 1]]].rgb * v
                + vertexColors[vertexIndices[m.vertexOffset + triangleIndices[corner + 2]]].rgb * w;
        }
        output.set_vertex(slot, vert);
    }

    for (uint slot = tid; slot < layout.primitiveBase[count]; slot += PN_MESH_THREADS) {
        PNPrimitiveRef prim = pnLocatePrimitive(layout, payload, first, count, slot);
        output.set_index(slot * 3, prim.corners.x);
        output.set_index(slot * 3 + 1, prim.corners.y);
        output.set_index(slot * 3 + 2, prim.corners.z);
    }
}

// --- Shadow mesh shader variant ---

struct ShadowMeshVertex {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing (shadow_clip_fragment)
};

using ShadowMeshOutput =
    mesh<ShadowMeshVertex, void, PN_CHUNK_VERTICES, PN_CHUNK_PRIMITIVES, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(PN_MESH_THREADS)]]
void meshlet_shadow_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant ShadowUniforms& uniforms [[buffer(4)]],
    const device PNPatchData* patches [[buffer(7)]],
    ShadowMeshOutput output,
    uint tid [[thread_index_in_threadgroup]],
    uint chunk [[threadgroup_position_in_grid]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    uint first = payload.chunkFirst[chunk];
    uint count = payload.chunkFirst[chunk + 1] - first;
    threadgroup PNChunkLayout layout;
    pnBuildLayout(layout, payload, first, count, tid);
    output.set_primitive_count(layout.primitiveBase[count]);

    for (uint slot = tid; slot < layout.vertexBase[count]; slot += PN_MESH_THREADS) {
        PNVertexRef ref = pnLocateVertex(layout, payload, first, count, slot);
        PNPatchData p = patches[m.triangleOffset + ref.triangle];
        float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(p, ref.bary), 1.0);
        ShadowMeshVertex vert;
        vert.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
        vert.worldPosition = worldPos.xyz;
        output.set_vertex(slot, vert);
    }

    for (uint slot = tid; slot < layout.primitiveBase[count]; slot += PN_MESH_THREADS) {
        PNPrimitiveRef prim = pnLocatePrimitive(layout, payload, first, count, slot);
        output.set_index(slot * 3, prim.corners.x);
        output.set_index(slot * 3 + 1, prim.corners.y);
        output.set_index(slot * 3 + 2, prim.corners.z);
    }
}

// --- Depth-only mesh shader variant ---
//
// Also the geometry of the selection stencil mask and selection mask (#175).

struct DepthMeshVertex {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing (depth_only_clip_fragment)
};

using DepthMeshOutput =
    mesh<DepthMeshVertex, void, PN_CHUNK_VERTICES, PN_CHUNK_PRIMITIVES, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(PN_MESH_THREADS)]]
void meshlet_depth_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(4)]],
    const device PNPatchData* patches [[buffer(7)]],
    DepthMeshOutput output,
    uint tid [[thread_index_in_threadgroup]],
    uint chunk [[threadgroup_position_in_grid]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    uint first = payload.chunkFirst[chunk];
    uint count = payload.chunkFirst[chunk + 1] - first;
    threadgroup PNChunkLayout layout;
    pnBuildLayout(layout, payload, first, count, tid);
    output.set_primitive_count(layout.primitiveBase[count]);

    for (uint slot = tid; slot < layout.vertexBase[count]; slot += PN_MESH_THREADS) {
        PNVertexRef ref = pnLocateVertex(layout, payload, first, count, slot);
        PNPatchData p = patches[m.triangleOffset + ref.triangle];
        float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(p, ref.bary), 1.0);
        DepthMeshVertex vert;
        vert.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        vert.worldPosition = worldPos.xyz;
        output.set_vertex(slot, vert);
    }

    for (uint slot = tid; slot < layout.primitiveBase[count]; slot += PN_MESH_THREADS) {
        PNPrimitiveRef prim = pnLocatePrimitive(layout, payload, first, count, slot);
        output.set_index(slot * 3, prim.corners.x);
        output.set_index(slot * 3 + 1, prim.corners.y);
        output.set_index(slot * 3 + 2, prim.corners.z);
    }
}

// --- Per-triangle highlight mesh shader variant (#175) ---
//
// The highlight over a mesh-shader surface, drawn from the same subdivided triangles as the
// surface so it covers exactly what was shaded. Each sub-triangle carries its input triangle's
// index, which indexes the style buffer.

struct HighlightMeshVertex {
    float4 clipPosition [[position]];
    float3 worldPosition [[centroid_perspective]];  // MSAA-safe clip test, as HighlightVertexOut
};

struct HighlightMeshPrimitive {
    uint triangleIndex [[flat]];
};

using HighlightMeshOutput =
    mesh<HighlightMeshVertex, HighlightMeshPrimitive, PN_CHUNK_VERTICES, PN_CHUNK_PRIMITIVES,
         topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(PN_MESH_THREADS)]]
void meshlet_highlight_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(4)]],
    const device PNPatchData* patches [[buffer(7)]],
    HighlightMeshOutput output,
    uint tid [[thread_index_in_threadgroup]],
    uint chunk [[threadgroup_position_in_grid]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    uint first = payload.chunkFirst[chunk];
    uint count = payload.chunkFirst[chunk + 1] - first;
    threadgroup PNChunkLayout layout;
    pnBuildLayout(layout, payload, first, count, tid);
    output.set_primitive_count(layout.primitiveBase[count]);

    for (uint slot = tid; slot < layout.vertexBase[count]; slot += PN_MESH_THREADS) {
        PNVertexRef ref = pnLocateVertex(layout, payload, first, count, slot);
        PNPatchData p = patches[m.triangleOffset + ref.triangle];
        float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(p, ref.bary), 1.0);
        HighlightMeshVertex vert;
        vert.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        vert.worldPosition = worldPos.xyz;
        output.set_vertex(slot, vert);
    }

    for (uint slot = tid; slot < layout.primitiveBase[count]; slot += PN_MESH_THREADS) {
        PNPrimitiveRef ref = pnLocatePrimitive(layout, payload, first, count, slot);
        output.set_index(slot * 3, ref.corners.x);
        output.set_index(slot * 3 + 1, ref.corners.y);
        output.set_index(slot * 3 + 2, ref.corners.z);
        HighlightMeshPrimitive prim;
        prim.triangleIndex = m.triangleOffset + ref.triangle;
        output.set_primitive(slot, prim);
    }
}

struct HighlightMeshFragmentIn {
    HighlightMeshVertex vert;
    HighlightMeshPrimitive prim;
};

fragment HighlightFragmentOut meshlet_highlight_fragment(
    HighlightMeshFragmentIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant float4 *triangleStyles [[buffer(2)]]
) {
    if (isClippedBySectionPlanes(in.vert.worldPosition, uniforms)) discard_fragment();
    float4 style = triangleStyles[in.prim.triangleIndex];
    if (style.a <= 0.0) discard_fragment();
    HighlightFragmentOut out;
    out.color = style;
    return out;
}

// --- Pick mesh shader variant ---

struct PickMeshVertex {
    float4 clipPosition [[position]];
    float3 worldPosition;    // for clip plane testing (meshlet_pick_fragment)
};

// In a mesh pipeline [[primitive_id]] is the meshlet-local primitive (0-63), so the global
// triangle index travels as per-primitive data instead (issue #136, L10). MeshletBuilder keeps
// triangles in input order, so the global index is triangleOffset + local index. Every
// sub-triangle of a subdivided input triangle carries that input triangle's index (#175).
struct PickMeshPrimitive {
    uint triangleIndex [[flat]];
};

using PickMeshOutput =
    mesh<PickMeshVertex, PickMeshPrimitive, PN_CHUNK_VERTICES, PN_CHUNK_PRIMITIVES,
         topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(PN_MESH_THREADS)]]
void meshlet_pick_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(4)]],
    const device PNPatchData* patches [[buffer(7)]],
    PickMeshOutput output,
    uint tid [[thread_index_in_threadgroup]],
    uint chunk [[threadgroup_position_in_grid]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    uint first = payload.chunkFirst[chunk];
    uint count = payload.chunkFirst[chunk + 1] - first;
    threadgroup PNChunkLayout layout;
    pnBuildLayout(layout, payload, first, count, tid);
    output.set_primitive_count(layout.primitiveBase[count]);

    for (uint slot = tid; slot < layout.vertexBase[count]; slot += PN_MESH_THREADS) {
        PNVertexRef ref = pnLocateVertex(layout, payload, first, count, slot);
        PNPatchData p = patches[m.triangleOffset + ref.triangle];
        float4 worldPos = uniforms.modelMatrix * float4(pnPatchPosition(p, ref.bary), 1.0);
        PickMeshVertex vert;
        vert.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        vert.worldPosition = worldPos.xyz;
        output.set_vertex(slot, vert);
    }

    for (uint slot = tid; slot < layout.primitiveBase[count]; slot += PN_MESH_THREADS) {
        PNPrimitiveRef ref = pnLocatePrimitive(layout, payload, first, count, slot);
        output.set_index(slot * 3, ref.corners.x);
        output.set_index(slot * 3 + 1, ref.corners.y);
        output.set_index(slot * 3 + 2, ref.corners.z);
        PickMeshPrimitive prim;
        prim.triangleIndex = m.triangleOffset + ref.triangle;
        output.set_primitive(slot, prim);
    }
}

struct PickMeshFragmentIn {
    PickMeshVertex vert;
    PickMeshPrimitive prim;
};

// Face pick for the mesh-shader path — kind=0, global triangle index from the primitive data.
fragment PickFragmentOut meshlet_pick_fragment(
    PickMeshFragmentIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]]
) {
    if (isClippedBySectionPlanes(in.vert.worldPosition, uniforms)) discard_fragment();
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, in.prim.triangleIndex, 0u);
    return out;
}

#endif // __METAL_VERSION__ >= 310

// MARK: - Skybox Pipeline

// Renders the IBL cubemap as the scene background using a fullscreen triangle.
// Drawn before geometry with depth = 1 in NDC; depth test must be `lessEqual`
// so any geometry overwrites the sky.

struct SkyboxUniforms {
    float4x4 inverseViewProjection;  // for reconstructing world-space view rays
    float4   params;                 // x = rotation about world up (Z), y = backgroundExposure,
                                     // z = mipLevel (0 = sharp, 7 = blurred),
                                     // w = tone-map scale (exposure / whitePoint)
};

struct SkyboxVertexOut {
    float4 clipPosition [[position]];
    float3 viewDirection;
};

vertex SkyboxVertexOut skybox_vertex(
    uint vertexID [[vertex_id]],
    constant SkyboxUniforms &u [[buffer(0)]]
) {
    // Fullscreen triangle covering [-1,1]² in NDC (3 verts, no buffer needed).
    float2 ndc = float2((vertexID == 1) ? 3.0 : -1.0,
                        (vertexID == 2) ? 3.0 : -1.0);
    SkyboxVertexOut out;
    out.clipPosition = float4(ndc, 1.0, 1.0); // depth = 1 in NDC

    // Reconstruct the world-space view ray by inverse-projecting near and far points. Leave it
    // un-normalised: the ray is affine in NDC xy, so the rasteriser interpolates it exactly, and
    // skybox_fragment normalises the result. Normalising here instead interpolated unit
    // vectors, which skews every direction between the corners (issue #228).
    float4 worldNear = u.inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 worldFar  = u.inverseViewProjection * float4(ndc, 1.0, 1.0);
    out.viewDirection = worldFar.xyz / worldFar.w - worldNear.xyz / worldNear.w;
    return out;
}

fragment float4 skybox_fragment(
    SkyboxVertexOut in [[stage_in]],
    texturecube<float> sky [[texture(0)]],
    constant SkyboxUniforms &u [[buffer(0)]]
) {
    // Z-up world direction → Y-up cubemap space, with the environment rotation applied
    float3 rotDir = worldToEnvironment(normalize(in.viewDirection), u.params.x);

    constexpr sampler skySampler(filter::linear, mip_filter::linear);
    float3 color = sky.sample(skySampler, rotDir, level(u.params.z)).rgb;
    // HDR radiance is linear: tone map with the scene's exposure / white point (params.w),
    // then encode, the same as lit surfaces.
    return float4(linearToSrgb(acesToneMap(color * u.params.y, u.params.w, 1.0)), 1.0);
}

// MARK: - Heightfield (issue #139 spike)

// A heightfield is a grid of cell heights drawn as 64 x 64-cell tiles, displaced in the vertex
// stage. The CPU picks a level of detail per tile (stride 1 << level cells) and issues one
// instanced indexed draw per level; every pass's vertex function calls `hfDisplace`, so the
// positions are identical in the shaded, shadow, depth and pick passes.
//
// The height texture is mipmapped. Mip level L holds the pyramid for stride 1 << L: texel k stands
// for fine cell k << L (clamped to the last cell) and holds the MINIMUM height of the cells it
// covers, so pits, slots and steps survive coarse levels (`heightfield_build_pyramid`). The
// texture is padded so every level has an exact size.
//
// Cracks: along an edge shared with a coarser tile, the finer tile snaps its edge vertices onto
// the coarser tile's edge (linear interpolation between the coarser tile's vertices). Both tiles
// read the shared edge at the coarser tile's level, and a tile corner at the coarsest level of
// the four tiles meeting there, so they agree to the bit. `HeightfieldTile.levels` packs those.

#define HF_TILE_CELLS 64u

struct HeightfieldTile {
    uint2 origin;   // the tile's first vertex, in fine cells (a multiple of HF_TILE_CELLS)
    uint  levels;   // levels shared with neighbours, 3 bits each. Bits 0-11: edges -X +X -Y +Y.
                    // Bits 12-23: corners -X-Y, +X-Y, -X+Y, +X+Y
    uint  _pad;
};

// Swift mirror: HeightfieldDrawParams in HeightfieldRenderer.swift. Stride 48.
struct HeightfieldParams {
    uint2  size;       // field size in cells
    uint   level;      // level of detail of this draw
    uint   quads;      // quads per tile side at this level (HF_TILE_CELLS >> level)
    float2 cellSize;
    float2 origin;     // body-local XY of the corner of cell (0, 0)
    uint   rampMode;   // vertex colour mode word for ramp-coloured cells (2, plus 4 if linear)
    uint   _pad0;
    uint   _pad1;
    uint   _pad2;
};

struct HeightfieldVertex {
    float3 position;   // body-local
    float2 gridPos;    // the cell the vertex stands for, in fine cells
};

inline uint2 hfMaxTexel(uint2 size, uint level) {
    uint s = 1u << level;
    return (size - 1u + (s - 1u)) >> level;
}

// The pyramid height at the fine position `fine`, read at `level`.
inline float hfReadAt(texture2d<float> heights, constant HeightfieldParams &p, uint level, uint2 fine) {
    uint2 k = min(fine >> level, hfMaxTexel(p.size, level));
    return heights.read(k, level).r;
}

inline uint hfLevelBits(uint packed, uint slot) {
    return (packed >> (3u * slot)) & 7u;
}

// The height of a vertex on the tile's boundary as the neighbours see it: a corner at its corner
// level, any other edge vertex at the shared edge's level.
inline float hfBoundaryHeight(
    texture2d<float> heights, constant HeightfieldParams &p, HeightfieldTile tile, uint2 ij,
    uint edgeLevel
) {
    uint n = p.quads;
    bool xEdge = ij.x == 0u || ij.x == n;
    bool yEdge = ij.y == 0u || ij.y == n;
    uint level = edgeLevel;
    if (xEdge && yEdge) {
        uint corner = (ij.x == n ? 1u : 0u) | (ij.y == n ? 2u : 0u);
        level = hfLevelBits(tile.levels, 4u + corner);
    }
    return hfReadAt(heights, p, level, tile.origin + (ij << p.level));
}

// The height of vertex `ij` (tile-local grid coordinates) of `tile`, with the crack-free snapping.
inline float hfVertexHeight(
    texture2d<float> heights, constant HeightfieldParams &p, HeightfieldTile tile, uint2 ij
) {
    uint L = p.level;
    uint n = p.quads;
    bool xEdge = ij.x == 0u || ij.x == n;
    bool yEdge = ij.y == 0u || ij.y == n;
    if (!xEdge && !yEdge) return hfReadAt(heights, p, L, tile.origin + (ij << L));
    if (xEdge && yEdge) return hfBoundaryHeight(heights, p, tile, ij, L);

    // An edge vertex that is not a corner. Slots: -X +X -Y +Y.
    bool alongX = yEdge;
    uint slot = alongX ? (ij.y == 0u ? 2u : 3u) : (ij.x == 0u ? 0u : 1u);
    uint edgeLevel = hfLevelBits(tile.levels, slot);
    if (edgeLevel <= L) return hfReadAt(heights, p, L, tile.origin + (ij << L));

    // The neighbour is coarser: interpolate between its vertices on this edge.
    uint ratio = 1u << (edgeLevel - L);
    uint m = alongX ? ij.x : ij.y;
    uint m0 = (m / ratio) * ratio;
    float h0 = hfBoundaryHeight(
        heights, p, tile, alongX ? uint2(m0, ij.y) : uint2(ij.x, m0), edgeLevel);
    if (m == m0) return h0;
    uint m1 = m0 + ratio;
    float h1 = hfBoundaryHeight(
        heights, p, tile, alongX ? uint2(m1, ij.y) : uint2(ij.x, m1), edgeLevel);
    return mix(h0, h1, float(m - m0) / float(ratio));
}

inline HeightfieldVertex hfDisplace(
    uint vid, uint iid, const device HeightfieldTile *tiles, constant HeightfieldParams &p,
    texture2d<float> heights
) {
    uint n = p.quads;
    uint2 ij = uint2(vid % (n + 1u), vid / (n + 1u));
    HeightfieldTile tile = tiles[iid];
    uint L = p.level;
    uint2 fine = tile.origin + (ij << L);
    uint2 k = min(fine >> L, hfMaxTexel(p.size, L));
    uint2 xy = min(k << L, p.size - 1u);
    HeightfieldVertex v;
    v.gridPos = float2(xy);
    v.position = float3(
        p.origin + (float2(xy) + 0.5) * p.cellSize, hfVertexHeight(heights, p, tile, ij));
    return v;
}

// MARK: Heightfield pyramid

struct HeightfieldPyramidParams {
    uint2 size;        // field size in cells
    uint  level;       // the level to write (>= 1); it reads level - 1
    uint  tileTexels;  // texels per tile side at `level`
    uint  tileCount;
    uint  _pad0;
    uint  _pad1;
    uint  _pad2;
};

// Level L texel k = min over level L-1 texels 2k-1, 2k, 2k+1 (both axes), clamped to the level.
// The windows nest, so the interpolated coarse surface never rises above the true one. One
// thread per texel of each dirty tile plus a one-texel halo (a changed cell reaches one texel
// further at every level).
kernel void heightfield_build_pyramid(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant HeightfieldPyramidParams &p [[buffer(0)]],
    const device uint2 *dirtyTiles [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    uint side = p.tileTexels + 2u;
    uint perTile = side * side;
    uint tile = tid / perTile;
    if (tile >= p.tileCount) return;
    uint local = tid % perTile;
    int2 k = int2(dirtyTiles[tile]) * int(p.tileTexels)
        + int2(int(local % side), int(local / side)) - 1;
    uint2 kmax = hfMaxTexel(p.size, p.level);
    if (k.x < 0 || k.y < 0 || k.x > int(kmax.x) || k.y > int(kmax.y)) return;
    uint2 srcMax = hfMaxTexel(p.size, p.level - 1u);
    int2 lo = max(2 * k - 1, int2(0));
    int2 hi = min(2 * k + 1, int2(srcMax));
    float m = INFINITY;
    for (int y = lo.y; y <= hi.y; y++) {
        for (int x = lo.x; x <= hi.x; x++) {
            m = min(m, src.read(uint2(x, y)).r);
        }
    }
    dst.write(float4(m, 0.0, 0.0, 0.0), uint2(k));
}

// MARK: Heightfield passes

struct HeightfieldShadedOut {
    float4 clipPosition [[position]];
    float3 worldPosition [[centroid_perspective]];
    float4 clipPositionCopy;
    float2 gridPos;
};

vertex HeightfieldShadedOut heightfield_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device HeightfieldTile *tiles [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]],
    texture2d<float> heights [[texture(0)]]
) {
    HeightfieldVertex v = hfDisplace(vid, iid, tiles, params, heights);
    HeightfieldShadedOut out;
    float4 worldPos = uniforms.modelMatrix * float4(v.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.clipPositionCopy = out.clipPosition;
    out.worldPosition = worldPos.xyz;
    out.gridPos = v.gridPos;
    return out;
}

// Central-difference normal (body-local, Z up) of fine cell `c`, from the full-resolution heights.
inline float3 hfCellNormal(texture2d<float> heights, constant HeightfieldParams &p, int2 c) {
    int2 hiMax = int2(p.size) - 1;
    int2 c0 = max(c - 1, int2(0));
    int2 c1 = min(c + 1, hiMax);
    float dx = heights.read(uint2(c1.x, c.y)).r - heights.read(uint2(c0.x, c.y)).r;
    float dy = heights.read(uint2(c.x, c1.y)).r - heights.read(uint2(c.x, c0.y)).r;
    float sx = max(float(c1.x - c0.x), 1.0) * p.cellSize.x;
    float sy = max(float(c1.y - c0.y), 1.0) * p.cellSize.y;
    return normalize(float3(-dx / sx, -dy / sy, 1.0));
}

fragment ShadedFragmentOut heightfield_fragment(
    HeightfieldShadedOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]],
    constant float4 *ramp [[buffer(4)]],
    texture2d<float> matcapTexture [[texture(0)]],
    depth2d<float> shadowMap [[texture(1)]],
    texturecube<float> iblSpecular [[texture(2)]],
    texturecube<float> iblDiffuse [[texture(3)]],
    texture2d<float> brdfLUT [[texture(4)]],
    texture2d<float> heights [[texture(5)]],
    texture2d<uint> attributes [[texture(6)]]
) {
    int2 cell = clamp(int2(floor(in.gridPos + 0.5)), int2(0), int2(params.size) - 1);
    float3 localNormal = hfCellNormal(heights, params, cell);
    uint attribute = attributes.read(uint2(cell)).r;

    ShadedVertexOut sv;
    sv.clipPosition = in.clipPosition;
    sv.worldNormal = normalize(uniforms.normalMatrix * localNormal);
    sv.worldPosition = in.worldPosition;
    sv.viewNormal = normalize((uniforms.viewMatrix * float4(sv.worldNormal, 0.0)).xyz);
    sv.clipPositionCopy = in.clipPositionCopy;
    // Attribute 0 is the untouched surface and shades as the body's material; any other value
    // replaces the albedo with its ramp colour.
    sv.vertexColor = attribute == 0u ? float3(1.0) : ramp[attribute].rgb;
    sv.vertexColorMode = attribute == 0u ? 0u : params.rampMode;
    return shadedFragmentBody(
        sv, uniforms, bodyUniforms, matcapTexture, shadowMap, iblSpecular, iblDiffuse, brdfLUT);
}

// MARK: Heightfield pick

struct HeightfieldPickOut {
    float4 clipPosition [[position]];
    float3 worldPosition;
    float2 gridPos;
};

vertex HeightfieldPickOut heightfield_pick_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device HeightfieldTile *tiles [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]],
    texture2d<float> heights [[texture(0)]]
) {
    HeightfieldVertex v = hfDisplace(vid, iid, tiles, params, heights);
    HeightfieldPickOut out;
    float4 worldPos = uniforms.modelMatrix * float4(v.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    out.gridPos = v.gridPos;
    return out;
}

// Face pick (kind 0) whose primitive is the CELL index, `y * width + x`, of the pixel's position
// on the drawn surface. The cell comes from the interpolated grid position, not from a triangle
// index, so it is exact laterally at every level of detail; the height, attribute and id are read
// from the CPU mirror by cell.
fragment PickFragmentOut heightfield_pick_fragment(
    HeightfieldPickOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]]
) {
    if (isClippedBySectionPlanes(in.worldPosition, uniforms)) discard_fragment();
    int2 cell = clamp(int2(floor(in.gridPos + 0.5)), int2(0), int2(params.size) - 1);
    PickFragmentOut out;
    out.pickID = packPickID(bodyUniforms.objectIndex, uint(cell.y) * params.size.x + uint(cell.x), 0u);
    return out;
}

// MARK: Heightfield shadow and depth

vertex ShadowVertexOut heightfield_shadow_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant ShadowUniforms &uniforms [[buffer(1)]],
    const device HeightfieldTile *tiles [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]],
    texture2d<float> heights [[texture(0)]]
) {
    HeightfieldVertex v = hfDisplace(vid, iid, tiles, params, heights);
    ShadowVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(v.position, 1.0);
    out.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}

vertex PickVertexOut heightfield_depth_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant Uniforms &uniforms [[buffer(1)]],
    const device HeightfieldTile *tiles [[buffer(2)]],
    constant HeightfieldParams &params [[buffer(3)]],
    texture2d<float> heights [[texture(0)]]
) {
    HeightfieldVertex v = hfDisplace(vid, iid, tiles, params, heights);
    PickVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(v.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldPosition = worldPos.xyz;
    return out;
}
