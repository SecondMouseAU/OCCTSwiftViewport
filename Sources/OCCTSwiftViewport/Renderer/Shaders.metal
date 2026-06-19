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
    float4   ambientSkyColor;          // rgb = sky color, w = specularPower
    float4   ambientGroundColor;       // rgb = ground color, w = specularIntensity
    float4   materialParams;           // x = fresnelPower, y = fresnelIntensity,
                                       // z = matcapBlend, w = farPlane
    float4x4 lightViewProjectionMatrix; // for shadow mapping
    float4   shadowParams;             // x = bias, y = intensity, z = enabled, w = edgeIntensity
    float4   shadowParams2;            // x = lightSize, y = searchRadius, z/w = unused (PCSS)
    float4   iblParams;                // x = intensity, y = rotationY (radians),
                                       // z = backgroundExposure, w = hasEnvMap (>0.5)
    float4   clipPlanes[4];            // xyz = normal, w = distance (dot(N,P)+w < 0 → clip)
    uint     clipPlaneCount;           // number of active clip planes (0–4)
    uint     unlit;                    // 1 = unlit/flat-colour (skip lighting + tone map)
    float2   _clipPad;                 // padding to 16-byte alignment
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
    float3 worldPosition;
    float3 viewNormal;       // for matcap UV
    float4 clipPositionCopy; // for depth-based effects
};

struct WireframeVertexOut {
    float4 clipPosition [[position]];
    float4 clipPositionCopy; // for depth-based edge alpha
    float3 worldPosition;    // for clip plane testing
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

// Procedural environment reflection: sky-ground gradient
inline float3 sampleEnvironment(float3 direction) {
    float t = direction.y * 0.5 + 0.5; // 0 = ground, 1 = sky
    float3 groundColor = float3(0.3, 0.28, 0.25);
    float3 horizonColor = float3(0.7, 0.72, 0.75);
    float3 skyColor = float3(0.85, 0.9, 1.0);
    // Two-segment blend: ground→horizon→sky
    if (t < 0.5) {
        return mix(groundColor, horizonColor, smoothstep(0.0, 0.5, t));
    } else {
        return mix(horizonColor, skyColor, smoothstep(0.5, 1.0, t));
    }
}

// MARK: - Shaded Pipeline

vertex ShadedVertexOut shaded_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    ShadedVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldNormal = normalize((uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.worldPosition = worldPos.xyz;
    // View-space normal for matcap
    out.viewNormal = normalize((uniforms.viewMatrix * uniforms.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.clipPositionCopy = out.clipPosition;
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
    if (uniforms.unlit != 0u) {
        float3 flatColor = bodyUniforms.color.rgb;
        if (bodyUniforms.isSelected == 1) {
            flatColor = mix(flatColor, float3(0.3, 0.5, 1.0), 0.15);
        } else if (bodyUniforms.isSelected == 2) {
            flatColor = mix(flatColor, float3(0.4, 0.6, 1.0), 0.08);
        }
        ShadedFragmentOut unlitOut;
        unlitOut.color = float4(flatColor, bodyUniforms.color.a);
        return unlitOut;
    }

    float3 N = normalize(in.worldNormal);
    float3 V = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    float NdotV = max(dot(N, V), 0.001);

    float fresnelPower = uniforms.materialParams.x;
    float fresnelIntensity = uniforms.materialParams.y;
    float matcapBlend = uniforms.materialParams.z;

    float roughness = clamp(bodyUniforms.roughness, 0.04, 1.0);
    float metallic = saturate(bodyUniforms.metallic);
    float3 bodyColor = bodyUniforms.color.rgb;
    float clearcoat = saturate(bodyUniforms.clearcoat);
    float coatRoughness = clamp(bodyUniforms.clearcoatRoughness, 0.04, 1.0);

    // PBR base reflectance: dielectric F0 from IOR, metal F0 = body colour.
    // For metallic > 0 the IOR term is irrelevant — `mix` resolves to bodyColor.
    float dielectricF0 = F0FromIOR(max(bodyUniforms.ior, 1.0));
    float3 F0 = mix(float3(dielectricF0), bodyColor, metallic);

    // Accumulate lighting from up to 3 lights
    float3 Lo = float3(0.0); // Outgoing radiance

    for (int i = 0; i < 3; i++) {
        float enabled = uniforms.lights[i].colorAndEnabled.a;
        if (enabled < 0.5) continue;

        float lightTypeVal = uniforms.lights[i].typeAndParams.x;
        float intensity = uniforms.lights[i].directionAndIntensity.w;
        float3 lightColor = uniforms.lights[i].colorAndEnabled.rgb;
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

        float3 specular = (D * G * F) / (4.0 * NdotV * NdotL + 0.0001);

        // Energy conservation: diffuse only for non-reflected light
        float3 kD = (1.0 - F) * (1.0 - metallic);
        float3 diffuse = kD * bodyColor / M_PI_F;
        float3 baseLobe = diffuse + specular;

        // Clearcoat lobe — sits on top of base, attenuates everything below by (1 - Fc·c).
        float3 contribution;
        if (clearcoat > 0.0) {
            float Fc;
            float3 coatSpec = evaluateClearcoat(NdotH, NdotV, NdotL, HdotV, coatRoughness, Fc);
            float attenuation = 1.0 - Fc * clearcoat;
            contribution = baseLobe * attenuation + coatSpec * clearcoat;
        } else {
            contribution = baseLobe;
        }

        Lo += contribution * lightColor * intensity * NdotL;
    }

    // Shadow mapping: darken key light contribution (PCSS soft shadows)
    if (uniforms.shadowParams.z > 0.5) {
        float4 lightSpacePos = uniforms.lightViewProjectionMatrix * uniforms.modelMatrix * float4(in.worldPosition, 1.0);
        float shadowFactor = sampleShadow(lightSpacePos, shadowMap, uniforms.shadowParams.x,
                                           uniforms.shadowParams2.x, uniforms.shadowParams2.y);
        float shadowDarkness = uniforms.shadowParams.y;
        Lo *= mix(1.0 - shadowDarkness, 1.0, shadowFactor);
    }

    // Tri-axis ambient: vary ambient by normal in all 3 directions (not just Y)
    // This breaks up uniform color on faces at the same elevation but different azimuths
    float3 skyColor = uniforms.ambientSkyColor.rgb;
    float3 groundColor = uniforms.ambientGroundColor.rgb;
    float3 ambientY = mix(groundColor, skyColor, N.y * 0.5 + 0.5);
    // Side axis: warm on +X, cool on -X (simulates fill/key side difference)
    float3 ambientX = mix(float3(0.35, 0.30, 0.28), float3(0.28, 0.30, 0.35), N.x * 0.5 + 0.5);
    // Depth axis: slightly brighter facing camera, darker facing away
    float3 ambientZ = mix(float3(0.25, 0.25, 0.27), float3(0.32, 0.32, 0.30), N.z * 0.5 + 0.5);
    float3 ambient = ((ambientY * 0.6) + (ambientX * 0.2) + (ambientZ * 0.2)) * bodyColor * (1.0 - metallic * 0.5);

    // Environment reflection: IBL when available, procedural fallback otherwise
    float3 R = reflect(-V, N);
    float3 envContribution;
    if (uniforms.iblParams.w > 0.5) {
        // Image-based lighting with split-sum approximation
        constexpr sampler iblSampler(filter::linear, mip_filter::linear, address::repeat);
        constexpr sampler brdfSampler(filter::linear, address::clamp_to_edge);
        float iblIntensity = uniforms.iblParams.x;
        float envRotation = uniforms.iblParams.y;
        // Apply environment rotation to sample directions only — geometry stays put.
        float3 R_env = rotateY(R, envRotation);
        float3 N_env = rotateY(N, envRotation);
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
        float3 envColor = sampleEnvironment(R);
        float envFresnel = pow(1.0 - NdotV, 5.0);
        float envStrength = mix(0.04, 1.0, metallic) * mix(0.3, 1.0, envFresnel) * (1.0 - roughness * 0.7);
        envContribution = envColor * mix(float3(dielectricF0), bodyColor, metallic) * envStrength;
    }

    // Fresnel rim (reduced for metallic surfaces)
    float fresnel = fresnelIntensity * (1.0 - metallic * 0.5) * pow(1.0 - NdotV, fresnelPower);
    float3 rimColor = float3(fresnel);

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
    if (uniforms.shadowParams2.z < 0.5) {
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
        float3 vn = normalize(in.viewNormal);
        float2 matcapUV = vn.xy * 0.5 + 0.5;
        constexpr sampler matcapSampler(filter::linear);
        float3 matcapColor = matcapTexture.sample(matcapSampler, matcapUV).rgb;
        litColor = mix(litColor, matcapColor * bodyColor, matcapBlend);
    }

    // Selection tint: subtle blue overlay for selected, lighter for hovered
    if (bodyUniforms.isSelected == 1) {
        litColor = mix(litColor, float3(0.3, 0.5, 1.0), 0.15);
    } else if (bodyUniforms.isSelected == 2) {
        litColor = mix(litColor, float3(0.4, 0.6, 1.0), 0.08);
    }

    ShadedFragmentOut out;
    out.color = float4(litColor, bodyUniforms.color.a);
    return out;
}

// MARK: - Pick-Only Pipeline (1x, no MSAA)

struct PickVertexOut {
    float4 clipPosition [[position]];
};

struct PickFragmentOut {
    uint pickID [[color(0)]];
};

vertex PickVertexOut pick_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    PickVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    return out;
}

// Pick encoding (must stay in sync with PickResult decoder):
//   bits  0-15 : objectIndex (16 bits)
//   bits 16-29 : primitiveID (14 bits, masked)
//   bits 30-31 : kind        (2 bits — 0=face, 1=edge, 2=vertex)
fragment PickFragmentOut pick_fragment(
    PickVertexOut in [[stage_in]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    PickFragmentOut out;
    out.pickID = bodyUniforms.objectIndex | ((primitiveID & 0x3FFFu) << 16) | (0u << 30);
    return out;
}

// Edge pick — kind=1.
fragment PickFragmentOut pick_line_fragment(
    PickVertexOut in [[stage_in]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    PickFragmentOut out;
    out.pickID = bodyUniforms.objectIndex | ((primitiveID & 0x3FFFu) << 16) | (1u << 30);
    return out;
}

// Analytic arc pick — kind=1 (edge). primitiveID is the ARC index, supplied per
// draw (each arc is drawn separately), since the arc's segment count is sampled
// adaptively per frame and `[[primitive_id]]` would only give a segment index.
fragment PickFragmentOut pick_arc_fragment(
    PickVertexOut in [[stage_in]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    constant uint &arcPrimID [[buffer(3)]]
) {
    PickFragmentOut out;
    out.pickID = bodyUniforms.objectIndex | ((arcPrimID & 0x3FFFu) << 16) | (1u << 30);
    return out;
}

// Point sprite vertex shader for vertex picking. Outputs `point_size` so
// individual vertices have a clickable footprint instead of a single pixel.
struct PickPointVertexOut {
    float4 clipPosition [[position]];
    float pointSize [[point_size]];
};

vertex PickPointVertexOut pick_point_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    PickPointVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.pointSize = 8.0; // 8x8 px clickable footprint
    return out;
}

// Vertex pick — kind=2.
fragment PickFragmentOut pick_point_fragment(
    PickPointVertexOut in [[stage_in]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]],
    uint primitiveID [[primitive_id]]
) {
    PickFragmentOut out;
    out.pickID = bodyUniforms.objectIndex | ((primitiveID & 0x3FFFu) << 16) | (2u << 30);
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
    uint   _pad;               // offset 28 — pad to 16-byte boundary
};

struct VisiblePointVertexOut {
    float4 clipPosition [[position]];
    float  pointSize    [[point_size]];
    float4 color;
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

    out.color = (params.useVertexColors != 0u) ? vertexColors[vid] : params.baseColor;
    return out;
}

fragment float4 visible_point_fragment(
    VisiblePointVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    // Mask to a disk inscribed in the [[point_coord]] unit square.
    float2 c = pointCoord - float2(0.5);
    if (dot(c, c) > 0.25) discard_fragment();
    return in.color;
}

// MARK: - Selection Outline Pipeline

struct SelectionOutlineParams {
    float4x4 viewProjectionMatrix;
    float4x4 modelMatrix;
    float3 outlineColor;
    float outlineScale;
};

struct SelectionOutlineVertexOut {
    float4 clipPosition [[position]];
};

// Renders geometry slightly scaled along normals for the outline effect
vertex SelectionOutlineVertexOut selection_outline_vertex(
    VertexIn in [[stage_in]],
    constant SelectionOutlineParams &params [[buffer(1)]]
) {
    // Scale vertex position along normal to create outline thickness
    float3 expandedPos = in.position + in.normal * params.outlineScale;
    float4 worldPos = params.modelMatrix * float4(expandedPos, 1.0);

    SelectionOutlineVertexOut out;
    out.clipPosition = params.viewProjectionMatrix * worldPos;
    return out;
}

struct SelectionOutlineFragmentOut {
    float4 color [[color(0)]];
};

fragment SelectionOutlineFragmentOut selection_outline_fragment(
    SelectionOutlineVertexOut in [[stage_in]],
    constant SelectionOutlineParams &params [[buffer(1)]]
) {
    SelectionOutlineFragmentOut out;
    out.color = float4(params.outlineColor, 1.0);
    return out;
}

// MARK: - Shadow Map Pipeline

struct ShadowUniforms {
    float4x4 lightViewProjectionMatrix;
    float4x4 modelMatrix;
};

struct ShadowVertexOut {
    float4 clipPosition [[position]];
};

vertex ShadowVertexOut shadow_vertex(
    VertexIn in [[stage_in]],
    constant ShadowUniforms &uniforms [[buffer(1)]]
) {
    ShadowVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
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
    return out;
}

// Empty fragment — only depth is written
fragment void depth_only_fragment() {
}

// MARK: - Wireframe Pipeline

vertex WireframeVertexOut wireframe_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    WireframeVertexOut out;
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    // Small depth bias to prevent z-fighting over shaded surfaces
    out.clipPosition.z -= 0.0001 * out.clipPosition.w;
    out.clipPositionCopy = out.clipPosition;
    out.worldPosition = worldPos.xyz;
    return out;
}

struct WireframeFragmentOut {
    float4 color [[color(0)]];
};

fragment WireframeFragmentOut wireframe_fragment(
    WireframeVertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant BodyUniforms &bodyUniforms [[buffer(2)]]
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
        out.color = float4(bodyColor, bodyAlpha);
        return out;
    }

    float edgeIntensity = max(uniforms.shadowParams.w, 0.0); // shadowParams.w = edge intensity

    // Contrast-adaptive edge color: light edges on dark bodies, dark edges on light bodies
    float luminance = dot(bodyColor, float3(0.299, 0.587, 0.114));
    float3 darkEdge = max(bodyColor * 0.25, float3(0.08));
    float3 lightEdge = bodyColor * 0.4 + 0.6;
    float3 edgeColor = mix(lightEdge, darkEdge, smoothstep(0.3, 0.6, luminance));

    // Depth-based edge alpha: near edges fully opaque, far edges fade
    float nearPlane = uniforms.cameraPosition.w;
    float farPlane = uniforms.materialParams.w;
    float clipZ = in.clipPositionCopy.z;
    float clipW = in.clipPositionCopy.w;
    float linearDepth = saturate((clipZ / clipW - nearPlane / farPlane) / (1.0 - nearPlane / farPlane));
    // edgeIntensity: 0 = invisible, 1 = normal, 2 = fully opaque at all depths
    float minAlpha = mix(0.2, 1.0, saturate(edgeIntensity));
    float edgeAlpha = mix(1.0, minAlpha, linearDepth) * saturate(edgeIntensity);

    WireframeFragmentOut out;
    out.color = float4(edgeColor, edgeAlpha);
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
    float3 worldPosition;
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

struct GridUniforms {
    float4x4 viewProjectionMatrix;
    float3   gridOrigin;
    float    spacing;
    int      halfCount;
    float    dotSize;
    float4   dotColor;
};

vertex GridVertexOut grid_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    constant GridUniforms &uniforms [[buffer(0)]]
) {
    int count = uniforms.halfCount * 2 + 1;
    int ix = int(instanceID) % count - uniforms.halfCount;
    int iz = int(instanceID) / count - uniforms.halfCount;

    float3 pos = uniforms.gridOrigin + float3(float(ix) * uniforms.spacing, 0.0, float(iz) * uniforms.spacing);
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
    float  exposure;            // tone mapping exposure (default 1.1)
    float  whitePoint;          // tone mapping white point (default 1.0)
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

// Linearize a reverse-Z depth value
inline float linearizeDepth(float depth, float near, float far) {
    return near * far / (far - depth * (far - near));
}

// SSAO-lite + Edge Silhouettes combined post-process
fragment float4 ssao_fragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> depthTexture [[texture(0)]],
    texture2d<float> colorTexture [[texture(1)]],
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

    float linearDepth = linearizeDepth(depth, params.nearPlane, params.farPlane);
    float result_ao = 1.0;
    float result_edge = 0.0;

    // --- SSAO ---
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
        float scaledRadius = params.radius / max(linearDepth, 0.1);

        for (int i = 0; i < 16; i++) {
            float2 sampleUV = in.texCoord + offsets[i] * scaledRadius * params.texelSize * 4.0;
            float sampleDepth = depthTexture.sample(pointSampler, sampleUV).r;
            float sampleLinear = linearizeDepth(sampleDepth, params.nearPlane, params.farPlane);

            float diff = linearDepth - sampleLinear;
            float rangeCheck = smoothstep(0.0, 1.0, scaledRadius / (abs(diff) + 0.001));
            occlusion += step(0.0005, diff) * rangeCheck;
        }

        result_ao = 1.0 - (occlusion / 16.0) * params.intensity;
        result_ao = clamp(result_ao, 0.0, 1.0);
    }

    // --- Edge Silhouettes (Sobel on depth) ---
    if (params.silhouetteIntensity > 0.001) {
        float2 ts = params.texelSize * params.silhouetteThickness;

        // Sample 3x3 neighborhood depths
        float d00 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x, -ts.y)).r, params.nearPlane, params.farPlane);
        float d10 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(  0.0, -ts.y)).r, params.nearPlane, params.farPlane);
        float d20 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x, -ts.y)).r, params.nearPlane, params.farPlane);
        float d01 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x,   0.0)).r, params.nearPlane, params.farPlane);
        float d21 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x,   0.0)).r, params.nearPlane, params.farPlane);
        float d02 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(-ts.x,  ts.y)).r, params.nearPlane, params.farPlane);
        float d12 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2(  0.0,  ts.y)).r, params.nearPlane, params.farPlane);
        float d22 = linearizeDepth(depthTexture.sample(pointSampler, in.texCoord + float2( ts.x,  ts.y)).r, params.nearPlane, params.farPlane);

        // Sobel X and Y
        float sobelX = -d00 + d20 - 2.0*d01 + 2.0*d21 - d02 + d22;
        float sobelY = -d00 - 2.0*d10 - d20 + d02 + 2.0*d12 + d22;

        // Normalize by center depth to make edges depth-invariant
        float edgeMag = sqrt(sobelX * sobelX + sobelY * sobelY) / max(linearDepth, 0.01);

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
            float sd = linearizeDepth(rawDepth, params.nearPlane, params.farPlane);
            // Skip samples at very different depths (silhouette boundary)
            if (abs(sd - linearDepth) / max(linearDepth, 0.01) > 0.3) continue;
            blurredDepth += sd;
            validSamples += 1.0;
        }

        if (validSamples > 2.0) {
            blurredDepth /= validSamples;
            float spatialImportance = (linearDepth - blurredDepth) / max(linearDepth, 0.01);
            depthContrast = 1.0 + spatialImportance * 0.2;
            depthContrast = clamp(depthContrast, 0.85, 1.15);
        }
    }

    // Combine: darken by AO, edge silhouettes, and depth contrast
    float3 finalColor = sceneColor.rgb * result_ao * depthContrast;
    finalColor = mix(finalColor, float3(0.1, 0.1, 0.12), result_edge);

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
                float3 sampleColor = colorTexture.sample(texSampler, sampleUV).rgb;
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

    // --- ACES Filmic Tone Mapping ---
    // Compresses dynamic range so highlights don't clip and shadows retain detail.
    // Uses the Narkowicz ACES approximation (industry standard).
    {
        float exposure = params.exposure;
        float wp = max(params.whitePoint, 0.01);
        float3 x = finalColor * exposure / wp;
        float a = 2.51;
        float b = 0.03;
        float c = 2.43;
        float d = 0.59;
        float e = 0.14;
        finalColor = saturate((x * (a * x + b)) / (x * (c * x + d) + e));
    }

    return float4(finalColor, sceneColor.a);
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
    float2 eqUV = float2(phi / (2.0 * M_PI_F) + 0.5, theta / M_PI_F + 0.5);

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

// Per-patch data: 10 Bezier control points + 3 corner normals + face index
// Uses packed_float3 (12 bytes, alignment 4) to avoid float3's 16-byte padding.
// Total: 13 * 12 + 4 + 4 = 164 bytes per patch.
struct PNPatchData {
    packed_float3 b300, b030, b003;           // Corner positions
    packed_float3 b210, b120, b201, b102, b021, b012; // Edge control points
    packed_float3 b111;                        // Center control point
    packed_float3 n200, n020, n002;           // Corner normals
    int32_t faceIndex;                         // For picking
    float _pad;                                // Alignment to 168? No — 164 is 4-aligned
};

// Tessellation factor parameters
struct TessFactorParams {
    float4x4 viewProjectionMatrix;
    float2 viewportSize;
    float targetEdgePixels;    // Target pixels per edge (default 16)
    float maxFactor;           // Max tessellation factor (default 16)
};

// --- Compute kernel: Build PN triangle patches from triangle mesh ---

kernel void compute_pn_patches(
    device float*       vertices     [[buffer(0)]],  // stride 6: px,py,pz,nx,ny,nz
    device uint32_t*    indices      [[buffer(1)]],  // 3 per triangle
    device PNPatchData* patches      [[buffer(2)]],  // output: 1 per triangle
    device int32_t*     faceIndices  [[buffer(3)]],  // per-triangle face index
    constant uint&      triangleCount [[buffer(4)]],
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
    float creaseThreshold = 0.866; // cos(30°)
    bool edge01_smooth = dot(n0, n1) > creaseThreshold;
    bool edge02_smooth = dot(n0, n2) > creaseThreshold;
    bool edge12_smooth = dot(n1, n2) > creaseThreshold;

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
    patch.faceIndex = faceIndices[gid];
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

[[patch(triangle, 3)]]
vertex ShadedVertexOut tessellated_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    PNPatchData p = patches[patchID];

    float u = bary.x;  // weight for b300 (vertex 0)
    float v = bary.y;  // weight for b030 (vertex 1)
    float w = bary.z;  // weight for b003 (vertex 2)

    float uu = u * u;
    float vv = v * v;
    float ww = w * w;

    // Evaluate cubic Bezier triangle
    float3 pos = p.b300 * uu * u
               + p.b030 * vv * v
               + p.b003 * ww * w
               + p.b210 * 3.0 * uu * v
               + p.b120 * 3.0 * u * vv
               + p.b201 * 3.0 * uu * w
               + p.b102 * 3.0 * u * ww
               + p.b021 * 3.0 * vv * w
               + p.b012 * 3.0 * v * ww
               + p.b111 * 6.0 * u * v * w;

    // Quadratically interpolate normals
    float3 normal = normalize(p.n200 * u + p.n020 * v + p.n002 * w);

    // Transform to world space
    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);

    ShadedVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.worldNormal = normalize((uniforms.modelMatrix * float4(normal, 0.0)).xyz);
    out.worldPosition = worldPos.xyz;
    out.viewNormal = normalize((uniforms.viewMatrix * uniforms.modelMatrix * float4(normal, 0.0)).xyz);
    out.clipPositionCopy = out.clipPosition;
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
    float u = bary.x, v = bary.y, w = bary.z;
    float uu = u*u, vv = v*v, ww = w*w;

    float3 pos = p.b300*uu*u + p.b030*vv*v + p.b003*ww*w
               + p.b210*3.0*uu*v + p.b120*3.0*u*vv
               + p.b201*3.0*uu*w + p.b102*3.0*u*ww
               + p.b021*3.0*vv*w + p.b012*3.0*v*ww
               + p.b111*6.0*u*v*w;

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    ShadowVertexOut out;
    out.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
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
    float u = bary.x, v = bary.y, w = bary.z;
    float uu = u*u, vv = v*v, ww = w*w;

    float3 pos = p.b300*uu*u + p.b030*vv*v + p.b003*ww*w
               + p.b210*3.0*uu*v + p.b120*3.0*u*vv
               + p.b201*3.0*uu*w + p.b102*3.0*u*ww
               + p.b021*3.0*vv*w + p.b012*3.0*v*ww
               + p.b111*6.0*u*v*w;

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    PickVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    return out;
}

// --- Post-tessellation pick vertex ---

struct TessPatchPickVertexOut {
    float4 clipPosition [[position]];
    int32_t faceIndex;
};

[[patch(triangle, 3)]]
vertex TessPatchPickVertexOut tessellated_pick_vertex(
    uint patchID [[patch_id]],
    float3 bary [[position_in_patch]],
    const device PNPatchData* patches [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    PNPatchData p = patches[patchID];
    float u = bary.x, v = bary.y, w = bary.z;
    float uu = u*u, vv = v*v, ww = w*w;

    float3 pos = p.b300*uu*u + p.b030*vv*v + p.b003*ww*w
               + p.b210*3.0*uu*v + p.b120*3.0*u*vv
               + p.b201*3.0*uu*w + p.b102*3.0*u*ww
               + p.b021*3.0*vv*w + p.b012*3.0*v*ww
               + p.b111*6.0*u*v*w;

    float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
    TessPatchPickVertexOut out;
    out.clipPosition = uniforms.viewProjectionMatrix * worldPos;
    out.faceIndex = p.faceIndex;
    return out;
}

// Pick fragment for tessellated patches — uses face index from patch, not primitive_id.
// Kind tag stays 0 (face). primitiveID truncated to 14 bits to match decoder layout.
fragment PickFragmentOut tessellated_pick_fragment(
    TessPatchPickVertexOut in [[stage_in]],
    constant BodyUniforms& bodyUniforms [[buffer(2)]]
) {
    PickFragmentOut out;
    out.pickID = bodyUniforms.objectIndex | ((uint(in.faceIndex) & 0x3FFFu) << 16) | (0u << 30);
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
    int    faceIndexFirst;
    int    _pad0, _pad1, _pad2;
};

// Payload passed from object shader to mesh shader
struct MeshletPayload {
    uint meshletIndex;
};

// Mesh shader output vertex — matches ShadedVertexOut for fragment reuse
struct MeshVertex {
    float4 clipPosition [[position]];
    float3 worldNormal;
    float3 worldPosition;
    float3 viewNormal;
    float4 clipPositionCopy;
};

// Mesh output type: triangles, max 64 verts / 64 tris
using ShadedMeshOutput = mesh<MeshVertex, void, 64, 64, topology::triangle>;

// --- Object shader: per-meshlet frustum + backface culling ---

[[object, max_total_threads_per_threadgroup(1)]]
void meshlet_object(
    object_data MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]],
    uint gid [[threadgroup_position_in_grid]],
    mesh_grid_properties mgp
) {
    MeshletDesc m = meshlets[gid];

    // Frustum culling: project bounding sphere to clip space
    float4 centerClip = uniforms.viewProjectionMatrix * float4(m.center, 1.0);

    // Simple frustum cull: check if sphere is entirely outside any frustum plane
    // For now just check near plane and basic clip (could add full 6-plane test)
    bool visible = true;

    // Behind camera check
    if (centerClip.w + m.radius < 0.01) {
        visible = false;
    }

    // Backface culling via normal cone
    if (visible && m.coneCutoff > 0.1) {
        float3 camPos = uniforms.cameraPosition.xyz;
        float3 viewDir = normalize(m.center - camPos);
        float d = dot(viewDir, m.coneAxis);
        // If the entire cone faces away from the camera, cull
        if (d > m.coneCutoff) {
            visible = false;
        }
    }

    if (visible) {
        payload.meshletIndex = gid;
        mgp.set_threadgroups_per_grid(uint3(1, 1, 1));
    } else {
        mgp.set_threadgroups_per_grid(uint3(0, 0, 0));
    }
}

// --- Mesh shader: emit triangles with PN triangle smoothing ---

[[mesh, max_total_threads_per_threadgroup(64)]]
void meshlet_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    device float* vertices [[buffer(1)]],          // stride 6: px,py,pz,nx,ny,nz
    device uint32_t* vertexIndices [[buffer(2)]],  // meshlet vertex index buffer
    device uint8_t* triangleIndices [[buffer(3)]],  // meshlet triangle index buffer (3 per tri)
    constant Uniforms& uniforms [[buffer(4)]],
    ShadedMeshOutput output,
    uint tid [[thread_index_in_threadgroup]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];

    // Set output counts
    output.set_primitive_count(m.triangleCount);

    // Emit vertices (each thread handles one vertex if tid < vertexCount)
    if (tid < m.vertexCount) {
        uint globalIdx = vertexIndices[m.vertexOffset + tid];
        float3 pos = float3(vertices[globalIdx*6], vertices[globalIdx*6+1], vertices[globalIdx*6+2]);
        float3 nrm = float3(vertices[globalIdx*6+3], vertices[globalIdx*6+4], vertices[globalIdx*6+5]);

        float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);

        MeshVertex v;
        v.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        v.worldNormal = normalize((uniforms.modelMatrix * float4(nrm, 0.0)).xyz);
        v.worldPosition = worldPos.xyz;
        v.viewNormal = normalize((uniforms.viewMatrix * uniforms.modelMatrix * float4(nrm, 0.0)).xyz);
        v.clipPositionCopy = v.clipPosition;
        output.set_vertex(tid, v);
    }

    // Emit triangles (each thread handles one triangle if tid < triangleCount)
    if (tid < m.triangleCount) {
        uint base = (m.triangleOffset + tid) * 3;
        uint i0 = triangleIndices[base];
        uint i1 = triangleIndices[base + 1];
        uint i2 = triangleIndices[base + 2];
        output.set_index(tid * 3, i0);
        output.set_index(tid * 3 + 1, i1);
        output.set_index(tid * 3 + 2, i2);
    }
}

// --- Shadow mesh shader variant ---

struct ShadowMeshVertex {
    float4 clipPosition [[position]];
};

using ShadowMeshOutput = mesh<ShadowMeshVertex, void, 64, 64, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(64)]]
void meshlet_shadow_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    device float* vertices [[buffer(1)]],
    device uint32_t* vertexIndices [[buffer(2)]],
    device uint8_t* triangleIndices [[buffer(3)]],
    constant ShadowUniforms& uniforms [[buffer(4)]],
    ShadowMeshOutput output,
    uint tid [[thread_index_in_threadgroup]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    output.set_primitive_count(m.triangleCount);

    if (tid < m.vertexCount) {
        uint globalIdx = vertexIndices[m.vertexOffset + tid];
        float3 pos = float3(vertices[globalIdx*6], vertices[globalIdx*6+1], vertices[globalIdx*6+2]);
        float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
        ShadowMeshVertex v;
        v.clipPosition = uniforms.lightViewProjectionMatrix * worldPos;
        output.set_vertex(tid, v);
    }

    if (tid < m.triangleCount) {
        uint base = (m.triangleOffset + tid) * 3;
        output.set_index(tid * 3, uint(triangleIndices[base]));
        output.set_index(tid * 3 + 1, uint(triangleIndices[base + 1]));
        output.set_index(tid * 3 + 2, uint(triangleIndices[base + 2]));
    }
}

// --- Depth-only mesh shader variant ---

struct DepthMeshVertex {
    float4 clipPosition [[position]];
};

using DepthMeshOutput = mesh<DepthMeshVertex, void, 64, 64, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(64)]]
void meshlet_depth_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    device float* vertices [[buffer(1)]],
    device uint32_t* vertexIndices [[buffer(2)]],
    device uint8_t* triangleIndices [[buffer(3)]],
    constant Uniforms& uniforms [[buffer(4)]],
    DepthMeshOutput output,
    uint tid [[thread_index_in_threadgroup]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    output.set_primitive_count(m.triangleCount);

    if (tid < m.vertexCount) {
        uint globalIdx = vertexIndices[m.vertexOffset + tid];
        float3 pos = float3(vertices[globalIdx*6], vertices[globalIdx*6+1], vertices[globalIdx*6+2]);
        float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
        DepthMeshVertex v;
        v.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        output.set_vertex(tid, v);
    }

    if (tid < m.triangleCount) {
        uint base = (m.triangleOffset + tid) * 3;
        output.set_index(tid * 3, uint(triangleIndices[base]));
        output.set_index(tid * 3 + 1, uint(triangleIndices[base + 1]));
        output.set_index(tid * 3 + 2, uint(triangleIndices[base + 2]));
    }
}

// --- Pick mesh shader variant ---

struct PickMeshVertex {
    float4 clipPosition [[position]];
};

using PickMeshOutput = mesh<PickMeshVertex, void, 64, 64, topology::triangle>;

[[mesh, max_total_threads_per_threadgroup(64)]]
void meshlet_pick_mesh(
    object_data const MeshletPayload& payload [[payload]],
    device MeshletDesc* meshlets [[buffer(0)]],
    device float* vertices [[buffer(1)]],
    device uint32_t* vertexIndices [[buffer(2)]],
    device uint8_t* triangleIndices [[buffer(3)]],
    constant Uniforms& uniforms [[buffer(4)]],
    PickMeshOutput output,
    uint tid [[thread_index_in_threadgroup]]
) {
    MeshletDesc m = meshlets[payload.meshletIndex];
    output.set_primitive_count(m.triangleCount);

    if (tid < m.vertexCount) {
        uint globalIdx = vertexIndices[m.vertexOffset + tid];
        float3 pos = float3(vertices[globalIdx*6], vertices[globalIdx*6+1], vertices[globalIdx*6+2]);
        float4 worldPos = uniforms.modelMatrix * float4(pos, 1.0);
        PickMeshVertex v;
        v.clipPosition = uniforms.viewProjectionMatrix * worldPos;
        output.set_vertex(tid, v);
    }

    if (tid < m.triangleCount) {
        uint base = (m.triangleOffset + tid) * 3;
        output.set_index(tid * 3, uint(triangleIndices[base]));
        output.set_index(tid * 3 + 1, uint(triangleIndices[base + 1]));
        output.set_index(tid * 3 + 2, uint(triangleIndices[base + 2]));
    }
}

#endif // __METAL_VERSION__ >= 310

// MARK: - Skybox Pipeline

// Renders the IBL cubemap as the scene background using a fullscreen triangle.
// Drawn before geometry with depth = 1 in NDC; depth test must be `lessEqual`
// so any geometry overwrites the sky.

struct SkyboxUniforms {
    float4x4 inverseViewProjection;  // for reconstructing world-space view rays
    float4   params;                 // x = rotationY, y = backgroundExposure,
                                     // z = mipLevel (0 = sharp, 7 = blurred), w = unused
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

    // Reconstruct world-space view direction by inverse-projecting near and far points.
    float4 worldNear = u.inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 worldFar  = u.inverseViewProjection * float4(ndc, 1.0, 1.0);
    out.viewDirection = normalize(worldFar.xyz / worldFar.w - worldNear.xyz / worldNear.w);
    return out;
}

fragment float4 skybox_fragment(
    SkyboxVertexOut in [[stage_in]],
    texturecube<float> sky [[texture(0)]],
    constant SkyboxUniforms &u [[buffer(0)]]
) {
    // Apply environment rotation
    float c = cos(u.params.x);
    float s = sin(u.params.x);
    float3 dir = normalize(in.viewDirection);
    float3 rotDir = float3(dir.x * c - dir.z * s, dir.y, dir.x * s + dir.z * c);

    constexpr sampler skySampler(filter::linear, mip_filter::linear);
    float3 color = sky.sample(skySampler, rotDir, level(u.params.z)).rgb;
    return float4(color * u.params.y, 1.0);
}
