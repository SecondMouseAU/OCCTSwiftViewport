// LightingTintsAndIBLTests.swift
// OCCTSwiftViewport Tests
//
// Issues #168, #174 and #189: a loaded environment map replaces the hemisphere ambient instead of
// stacking on it, the equirect panorama is not mirrored, the selection and hover surface tint is
// configurable, and the ambient side and depth tints and procedural environment colours are
// LightingConfiguration fields. Packing logic is tested directly; the rest renders headlessly.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Fixtures

@MainActor
enum TintFixtures {

    /// A raw `environmentMapData` equirect.
    ///
    /// The layout is `Int32 width | Int32 height | RGBA32Float pixels`, `fill(column, row)` giving
    /// each texel. Row 0 is the top of the panorama.
    static func equirect(
        width: Int = 128, height: Int = 64, _ fill: (Int, Int) -> SIMD3<Float>
    ) -> Data {
        var data = Data()
        withUnsafeBytes(of: Int32(width)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(height)) { data.append(contentsOf: $0) }
        var pixels = [Float]()
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = fill(x, y)
                pixels += [c.x, c.y, c.z, 1]
            }
        }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func uniformEnvironment(_ color: SIMD3<Float>) -> Data {
        equirect(width: 16, height: 8) { _, _ in color }
    }

    /// A panorama with a bright marker on the horizon at four azimuths.
    ///
    /// Each marker is 13 texels wide (about 36 degrees). With the image centre (u = 0.5) facing
    /// world +X and the world Z-up, the markers belong at: green +X (u 0.5), red -Y (u 0.75), blue
    /// +Y (u 0.25), yellow -X (u 0 and 1, split by the seam). The rest is a dim grey, so each
    /// marker is unmistakable.
    static func markerPanorama() -> Data {
        equirect { x, y in
            let band = (26...38).contains(y)
            guard band else { return SIMD3(0.05, 0.05, 0.05) }
            func near(_ centre: Int) -> Bool { abs(x - centre) <= 6 }
            if near(64) { return SIMD3(0.2, 6, 0.2) }  // +X
            if near(96) { return SIMD3(6, 0.2, 0.2) }  // u 0.75: -Y
            if near(32) { return SIMD3(0.2, 0.2, 6) }  // u 0.25: +Y
            if x <= 6 || x >= 122 { return SIMD3(6, 6, 0.2) }  // seam: -X
            return SIMD3(0.05, 0.05, 0.05)
        }
    }

    /// A square panel of half-size 3 centred on the origin, facing `normal`, with the winding
    /// counter-clockwise as seen from the normal side.
    static func panel(
        facing normal: SIMD3<Float>, color: SIMD4<Float> = SIMD4(0.8, 0.8, 0.8, 1),
        roughness: Float = 0.5, metallic: Float = 0
    ) -> ViewportBody {
        let n = simd_normalize(normal)
        let helper: SIMD3<Float> = abs(n.z) > 0.9 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1)
        let t = simd_normalize(simd_cross(helper, n))
        let b = simd_cross(n, t)  // t x b = n
        let h: Float = 3
        func v(_ p: SIMD3<Float>) -> [Float] { [p.x, p.y, p.z, n.x, n.y, n.z] }
        return ViewportBody(
            id: "panel",
            vertexData: v(-t * h - b * h) + v(t * h - b * h) + v(t * h + b * h) + v(-t * h + b * h),
            indices: [0, 1, 2, 0, 2, 3], edges: [], color: color, roughness: roughness,
            metallic: metallic)
    }

    /// A camera 10 units from the origin looking straight at a panel facing `normal`, with +Z up
    /// (or +Y up when the panel faces up or down).
    static func camera(facing normal: SIMD3<Float>) -> CameraState {
        let view: StandardView
        switch (normal.x, normal.y, normal.z) {
        case (_, _, 1): view = .top
        case (_, _, -1): view = .bottom
        case (1, _, _): view = .right  // looks -X
        case (-1, _, _): view = .left  // looks +X
        case (_, 1, _): view = .back  // looks -Y
        default: view = .front  // looks +Y
        }
        return CameraState(rotation: view.rotation, distance: 10, pivot: .zero)
    }

    /// Lighting with every direct light, shadow, rim, matcap and SSAO term off, so only ambient
    /// and environment light remain.
    static func ambientOnly() -> LightingConfiguration {
        let off = LightSettings(direction: SIMD3(0, 0, -1), intensity: 0, isEnabled: false)
        return LightingConfiguration(
            keyLight: off, fillLight: off, backLight: off, ambientIntensity: 0.25,
            shadowsEnabled: false, fresnelIntensity: 0, matcapBlend: 0, enableSSAO: false)
    }

    /// Centre pixel of `bodies` rendered headlessly on black, with silhouettes off.
    static func centre(
        _ bodies: [ViewportBody], camera: CameraState, lighting: LightingConfiguration,
        displayMode: DisplayMode = .shaded, size: Int = 32,
        configure: (inout OffscreenRenderOptions) -> Void = { _ in }
    ) throws -> SIMD3<Int> {
        var options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera, displayMode: displayMode,
            lightingConfiguration: lighting, backgroundColor: SIMD4(0, 0, 0, 1),
            appearance: .light, showGrid: false, showAxes: false, enableSilhouettes: false)
        configure(&options)
        let (px, w, h) = try ParityRender.render(bodies, options)
        return ParityRender.rgb(px, width: w, x: w / 2, y: h / 2)
    }
}

// MARK: - Ambient and the environment map (#168)

@MainActor
@Suite("A loaded environment map replaces the hemisphere ambient")
struct EnvironmentAmbientTests {

    private let mapLoaded = SIMD4<Float>(1, 0, 1, 1)  // intensity 1, rotation 0, exposure 1, map

    @Test("The ambient fades out with environmentIntensity while a map is loaded")
    func scalesFadeWithIntensity() {
        let lighting = LightingConfiguration.threePoint
        let none = Uniforms.lightingScales(for: lighting)
        #expect(none == Uniforms.lightingScales(for: lighting, iblParams: SIMD4(1, 0, 1, 0)))

        let full = Uniforms.lightingScales(for: lighting, iblParams: mapLoaded)
        #expect(SIMD3(full.x, full.y, full.z) == .zero, "ambient left on at intensity 1: \(full)")
        #expect(full.w == none.w, "the direct specular scale must not change")

        let half = Uniforms.lightingScales(for: lighting, iblParams: SIMD4(0.25, 0, 1, 1))
        #expect(abs(half.x - none.x * 0.75) < 1e-6)

        let over = Uniforms.lightingScales(for: lighting, iblParams: SIMD4(3, 0, 1, 1))
        #expect(SIMD3(over.x, over.y, over.z) == .zero, "intensity above 1 must not go negative")
    }

    @Test("environmentReplacesAmbient = false keeps the ambient on top of the map")
    func additiveOptOut() {
        var lighting = LightingConfiguration.threePoint
        lighting.environmentReplacesAmbient = false
        #expect(
            Uniforms.lightingScales(for: lighting, iblParams: mapLoaded)
                == Uniforms.lightingScales(for: lighting))
    }

    @Test("The default keeps the ambient on and replacing on")
    func defaults() {
        #expect(LightingConfiguration.threePoint.environmentReplacesAmbient)
        #expect(LightingConfiguration.studio.environmentReplacesAmbient)
    }

    private func panelCentre(
        _ configure: (inout LightingConfiguration) -> Void
    ) throws -> SIMD3<Int> {
        var lighting = TintFixtures.ambientOnly()
        lighting.environmentMapData = TintFixtures.uniformEnvironment(SIMD3(0.4, 0.4, 0.4))
        configure(&lighting)
        return try TintFixtures.centre(
            [TintFixtures.panel(facing: SIMD3(0, 0, 1))],
            camera: TintFixtures.camera(facing: SIMD3(0, 0, 1)), lighting: lighting)
    }

    @Test("With a map loaded, the default ambient no longer stacks on the diffuse IBL")
    func defaultDoesNotDoubleCount() throws {
        let withAmbient = try panelCentre { $0.ambientIntensity = 0.3 }
        let noAmbient = try panelCentre { $0.ambientIntensity = 0 }
        #expect(
            withAmbient == noAmbient,
            "ambient still adds to the IBL: \(withAmbient) vs \(noAmbient)")
        #expect(noAmbient.y > 40, "the map should light the panel: \(noAmbient)")
    }

    @Test("environmentReplacesAmbient = false restores the stacked, brighter look")
    func optOutIsBrighter() throws {
        let replaced = try panelCentre { $0.ambientIntensity = 0.3 }
        let stacked = try panelCentre {
            $0.ambientIntensity = 0.3
            $0.environmentReplacesAmbient = false
        }
        #expect(stacked.y > replaced.y + 10, "stacked \(stacked) vs replaced \(replaced)")
    }

    @Test("Dimming the environment lets the ambient fill back in")
    func dimmedEnvironmentFillsWithAmbient() throws {
        let dimmed = try panelCentre {
            $0.ambientIntensity = 0.3
            $0.environmentIntensity = 0.5
        }
        let dimmedNoAmbient = try panelCentre {
            $0.ambientIntensity = 0
            $0.environmentIntensity = 0.5
        }
        #expect(dimmed.y > dimmedNoAmbient.y + 5, "\(dimmed) vs \(dimmedNoAmbient)")
    }

    @Test("Without a map the ambient is untouched by environmentReplacesAmbient")
    func noMapNoChange() throws {
        func centre(replaces: Bool) throws -> SIMD3<Int> {
            var lighting = TintFixtures.ambientOnly()
            lighting.ambientIntensity = 0.3
            lighting.environmentReplacesAmbient = replaces
            return try TintFixtures.centre(
                [TintFixtures.panel(facing: SIMD3(0, 0, 1))],
                camera: TintFixtures.camera(facing: SIMD3(0, 0, 1)), lighting: lighting)
        }
        let on = try centre(replaces: true)
        #expect(on == (try centre(replaces: false)))
        #expect(on.y > 40, "the ambient should light the panel: \(on)")
    }
}

// MARK: - Equirect handedness (#168)

/// Pins the panorama's orientation with markers at known azimuths.
///
/// The centre column (u = 0.5) faces world +X and u grows toward -Y, so +Y is at u = 0.25 and -Y
/// at u = 0.75. A mirrored panorama would swap the red and blue markers.
///
/// The skybox cases look at the centre of a square frame and compare halves of it, never exact
/// azimuths: `skybox_vertex` normalises the ray at the corners of its oversized triangle before
/// interpolating, which skews directions off-axis (about 4 degrees at the centre of a square
/// frame, reported separately from #168). The mirror cases sample the cube map along an exact
/// reflection vector and carry the precise check.
@MainActor
@Suite("An equirect panorama is not mirrored")
struct EquirectHandednessTests {

    /// A skybox-only 128 x 128 view, 45 degrees across, with `rotation` as the camera.
    private func sky(_ panorama: Data, looking rotation: simd_quatf) throws
        -> (pixels: [UInt8], width: Int, height: Int)
    {
        var lighting = TintFixtures.ambientOnly()
        lighting.environmentMapData = panorama
        lighting.drawBackground = true
        let options = OffscreenRenderOptions(
            width: 128, height: 128,
            cameraState: CameraState(rotation: rotation, distance: 10, pivot: .zero),
            displayMode: .shaded, lightingConfiguration: lighting,
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, enableSilhouettes: false)
        // Only the sky is under test; a hidden body gives the renderer a scene to draw.
        var hidden = TintFixtures.panel(facing: SIMD3(0, 0, 1))
        hidden.isVisible = false
        return try ParityRender.render([hidden], options)
    }

    /// Whether `c` is dominated by the channels `colour` names.
    ///
    /// A bright HDR marker tone maps to 255 in its own channels and roughly 156 in the others.
    private func isMarker(_ c: SIMD3<Int>, _ colour: String) -> Bool {
        let margin = 60
        switch colour {
        case "red": return c.x > 200 && c.y < c.x - margin && c.z < c.x - margin
        case "green": return c.y > 200 && c.x < c.y - margin && c.z < c.y - margin
        case "blue": return c.z > 200 && c.x < c.z - margin && c.y < c.z - margin
        default: return c.x > 200 && c.y > 200 && c.z < c.x - margin  // yellow
        }
    }

    @Test(
        "Looking along each world axis shows the marker the panorama puts there",
        arguments: [
            (StandardView.left, SIMD3<Float>(1, 0, 0), "green"),  // looks +X: the image centre
            (StandardView.back, SIMD3<Float>(0, -1, 0), "red"),  // looks -Y: u = 0.75
            (StandardView.front, SIMD3<Float>(0, 1, 0), "blue"),  // looks +Y: u = 0.25
            (StandardView.right, SIMD3<Float>(-1, 0, 0), "yellow"),  // looks -X: the seam
        ])
    func skyAlongEachAxis(view: StandardView, look: SIMD3<Float>, colour: String) throws {
        let camera = CameraState(rotation: view.rotation, distance: 10, pivot: .zero)
        #expect(simd_length(camera.viewDirection - look) < 1e-4, "\(view) does not look \(look)")
        let (px, w, h) = try sky(TintFixtures.markerPanorama(), looking: view.rotation)
        let c = ParityRender.rgb(px, width: w, x: w / 2, y: h / 2)
        #expect(isMarker(c, colour), "looking \(look) should show \(colour), got \(c)")
    }

    @Test("The sky keeps the panorama's left-to-right order: -Y is on the right of +X")
    func skyLeftToRight() throws {
        // Facing +X with +Z up, the camera's right is world -Y.
        let camera = CameraState(rotation: StandardView.left.rotation, distance: 10, pivot: .zero)
        #expect(simd_length(camera.rightVector - SIMD3(0, -1, 0)) < 1e-4)
        #expect(simd_length(camera.upVector - SIMD3(0, 0, 1)) < 1e-4)

        // Red 12 to 24 degrees toward -Y of +X (u 0.535...0.566), blue as far toward +Y.
        let panorama = TintFixtures.equirect { x, y in
            guard (26...38).contains(y) else { return SIMD3(0.05, 0.05, 0.05) }
            if (68...72).contains(x) { return SIMD3(6, 0.2, 0.2) }
            if (56...60).contains(x) { return SIMD3(0.2, 0.2, 6) }
            return SIMD3(0.05, 0.05, 0.05)
        }
        let (px, w, h) = try sky(panorama, looking: StandardView.left.rotation)
        func count(_ half: Range<Int>, _ colour: String) -> Int {
            ParityRender.count(px, width: w, height: h, xs: half) { isMarker($0, colour) }
        }
        let left = 0..<(w / 2)
        let right = (w / 2)..<w
        #expect(count(right, "red") > 400 && count(left, "red") == 0, "red is not on the right")
        #expect(count(left, "blue") > 400 && count(right, "blue") == 0, "blue is not on the left")
    }

    @Test(
        "A mirror reflects the marker in the direction it faces",
        arguments: [
            (SIMD3<Float>(0, -1, 0), "red"),  // faces -Y
            (SIMD3<Float>(0, 1, 0), "blue"),  // faces +Y
            (SIMD3<Float>(1, 0, 0), "green"),  // faces +X
            (SIMD3<Float>(-1, 0, 0), "yellow"),  // faces -X
        ])
    func reflectionAzimuth(normal: SIMD3<Float>, colour: String) throws {
        var lighting = TintFixtures.ambientOnly()
        lighting.environmentMapData = TintFixtures.markerPanorama()
        let mirror = TintFixtures.panel(
            facing: normal, color: SIMD4(1, 1, 1, 1), roughness: 0, metallic: 1)
        let c = try TintFixtures.centre(
            [mirror], camera: TintFixtures.camera(facing: normal), lighting: lighting)
        #expect(isMarker(c, colour), "a mirror facing \(normal) should reflect \(colour), got \(c)")
    }
}

// MARK: - Ambient tints and procedural environment (#189)

@MainActor
@Suite("Ambient tints and procedural environment colours are configurable")
struct LightingTintFieldTests {

    @Test("Defaults are the values the shader used to hard-code")
    func defaultsMatchTheOldConstants() {
        for l in [
            LightingConfiguration.threePoint, .studio, .architectural, .flat,
        ] {
            #expect(l.ambientTintNegativeX == SIMD3(0.35, 0.30, 0.28))
            #expect(l.ambientTintPositiveX == SIMD3(0.28, 0.30, 0.35))
            #expect(l.ambientTintNegativeY == SIMD3(0.32, 0.32, 0.30))
            #expect(l.ambientTintPositiveY == SIMD3(0.25, 0.25, 0.27))
            #expect(l.proceduralEnvironmentGroundColor == SIMD3(0.3, 0.28, 0.25))
            #expect(l.proceduralEnvironmentHorizonColor == SIMD3(0.7, 0.72, 0.75))
            #expect(l.proceduralEnvironmentSkyColor == SIMD3(0.85, 0.9, 1.0))
        }
    }

    @Test("Uniforms carries the tints and environment colours to the shader")
    func uniformsPacking() {
        var lighting = LightingConfiguration.threePoint
        lighting.ambientTintNegativeX = SIMD3(0.1, 0.2, 0.3)
        lighting.ambientTintPositiveX = SIMD3(0.4, 0.5, 0.6)
        lighting.ambientTintNegativeY = SIMD3(0.7, 0.8, 0.9)
        lighting.ambientTintPositiveY = SIMD3(0.11, 0.12, 0.13)
        lighting.proceduralEnvironmentGroundColor = SIMD3(0.21, 0.22, 0.23)
        lighting.proceduralEnvironmentHorizonColor = SIMD3(0.31, 0.32, 0.33)
        lighting.proceduralEnvironmentSkyColor = SIMD3(0.41, 0.42, 0.43)
        let u = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: lighting,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false)
        #expect(u.ambientAxisTints.0 == SIMD4(0.1, 0.2, 0.3, 0))
        #expect(u.ambientAxisTints.1 == SIMD4(0.4, 0.5, 0.6, 0))
        #expect(u.ambientAxisTints.2 == SIMD4(0.7, 0.8, 0.9, 0))
        #expect(u.ambientAxisTints.3 == SIMD4(0.11, 0.12, 0.13, 0))
        #expect(u.proceduralEnvironment.0 == SIMD4(0.21, 0.22, 0.23, 0))
        #expect(u.proceduralEnvironment.1 == SIMD4(0.31, 0.32, 0.33, 0))
        #expect(u.proceduralEnvironment.2 == SIMD4(0.41, 0.42, 0.43, 0))
    }

    @Test("The Swift Uniforms layout matches the Metal struct")
    func uniformsLayout() {
        // The new fields start on a 16-byte boundary after the tone-map scalars and add
        // 4 + 3 + 2 float4 slots (144 bytes) to the struct.
        #expect(MemoryLayout<Uniforms>.offset(of: \.ambientAxisTints)! % 16 == 0)
        #expect(
            MemoryLayout<Uniforms>.offset(of: \.ambientAxisTints)!
                == MemoryLayout<Uniforms>.offset(of: \.toneMapWhitePoint)! + 4)
        #expect(
            MemoryLayout<Uniforms>.offset(of: \.proceduralEnvironment)!
                == MemoryLayout<Uniforms>.offset(of: \.ambientAxisTints)! + 64)
        #expect(
            MemoryLayout<Uniforms>.offset(of: \.selectionTint)!
                == MemoryLayout<Uniforms>.offset(of: \.proceduralEnvironment)! + 48)
        #expect(
            MemoryLayout<Uniforms>.offset(of: \.hoverTint)!
                == MemoryLayout<Uniforms>.offset(of: \.selectionTint)! + 16)
        #expect(MemoryLayout<Uniforms>.stride % 16 == 0)
    }

    /// A face-on panel lit by ambient alone, with the hemisphere term black so only the side or
    /// depth tint (0.2 of the blend) is left.
    private func ambientCentre(
        normal: SIMD3<Float>, _ configure: (inout LightingConfiguration) -> Void
    ) throws -> SIMD3<Int> {
        var lighting = TintFixtures.ambientOnly()
        lighting.ambientIntensity = 1
        lighting.ambientSkyColor = .zero
        lighting.ambientGroundColor = .zero
        configure(&lighting)
        return try TintFixtures.centre(
            [TintFixtures.panel(facing: normal, color: SIMD4(1, 1, 1, 1))],
            camera: TintFixtures.camera(facing: normal), lighting: lighting)
    }

    @Test(
        "Each ambient tint colours the faces that point along its axis end",
        arguments: [
            (SIMD3<Float>(1, 0, 0), "positiveX"),
            (SIMD3<Float>(-1, 0, 0), "negativeX"),
            (SIMD3<Float>(0, 1, 0), "positiveY"),
            (SIMD3<Float>(0, -1, 0), "negativeY"),
        ])
    func tintReachesTheFace(normal: SIMD3<Float>, field: String) throws {
        let neutral = try ambientCentre(normal: normal) { _ in }
        let tinted = try ambientCentre(normal: normal) { l in
            // Every tint black, then the one under test pure red.
            l.ambientTintNegativeX = .zero
            l.ambientTintPositiveX = .zero
            l.ambientTintNegativeY = .zero
            l.ambientTintPositiveY = .zero
            switch field {
            case "positiveX": l.ambientTintPositiveX = SIMD3(1, 0, 0)
            case "negativeX": l.ambientTintNegativeX = SIMD3(1, 0, 0)
            case "positiveY": l.ambientTintPositiveY = SIMD3(1, 0, 0)
            default: l.ambientTintNegativeY = SIMD3(1, 0, 0)
            }
        }
        #expect(
            abs(neutral.x - neutral.z) < 25, "the default tints should stay near grey: \(neutral)")
        #expect(
            tinted.x > tinted.y + 15 && tinted.x > tinted.z + 15,
            "\(field) = red should redden a face pointing \(normal): \(tinted)")
        #expect(tinted.y < 5 && tinted.z < 5, "a pure red tint should leave no green/blue")
    }

    private func mirrorCentre(
        normal: SIMD3<Float>, _ configure: (inout LightingConfiguration) -> Void
    ) throws -> SIMD3<Int> {
        var lighting = TintFixtures.ambientOnly()
        lighting.ambientIntensity = 0
        configure(&lighting)
        let mirror = TintFixtures.panel(
            facing: normal, color: SIMD4(1, 1, 1, 1), roughness: 0, metallic: 1)
        return try TintFixtures.centre(
            [mirror], camera: TintFixtures.camera(facing: normal), lighting: lighting)
    }

    @Test(
        "Each procedural environment colour shows in reflections of its direction",
        arguments: [
            (SIMD3<Float>(0, 0, 1), "sky"),
            (SIMD3<Float>(0, 0, -1), "ground"),
            (SIMD3<Float>(1, 0, 0), "horizon"),
        ])
    func proceduralColourReachesReflections(normal: SIMD3<Float>, field: String) throws {
        let neutral = try mirrorCentre(normal: normal) { _ in }
        let tinted = try mirrorCentre(normal: normal) { l in
            switch field {
            case "sky": l.proceduralEnvironmentSkyColor = SIMD3(1, 0, 0)
            case "ground": l.proceduralEnvironmentGroundColor = SIMD3(1, 0, 0)
            default: l.proceduralEnvironmentHorizonColor = SIMD3(1, 0, 0)
            }
        }
        #expect(
            abs(neutral.x - neutral.z) < 40, "the default environment is near grey: \(neutral)")
        #expect(
            tinted.x > tinted.y + 25 && tinted.x > tinted.z + 25,
            "\(field) = red should redden a mirror facing \(normal): \(tinted)")
    }

    @Test("Colours set on the configuration reach the headless live renderer too")
    func liveRendererHonoursTints() throws {
        var config = ViewportConfiguration()
        var lighting = LightingConfiguration.threePoint
        lighting.ambientTintPositiveX = SIMD3(1, 0, 0)
        lighting.proceduralEnvironmentSkyColor = SIMD3(1, 0, 0)
        config.lightingConfiguration = lighting
        var scene = OffscreenLiveParityTests.Scene(name: "tinted-lighting")
        scene.lighting = lighting
        scene.configuration = config
        guard let tinted = OffscreenLiveParityTests.renderBoth(scene),
            let plain = OffscreenLiveParityTests.renderBoth(
                OffscreenLiveParityTests.Scene(name: "plain"))
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(tinted.live != plain.live, "the live renderer ignored the tint fields")
        #expect(tinted.offscreen != plain.offscreen, "the offscreen renderer ignored them")
    }
}

// MARK: - Selection and hover tint (#174)

@MainActor
@Suite("Selection and hover surface tint is configurable")
struct SelectionTintTests {

    @Test("Defaults reproduce the previously hard-coded tints")
    func defaults() {
        #expect(SelectionTintStyle.selection.color == SIMD3(0.3, 0.5, 1.0))
        #expect(SelectionTintStyle.selection.strength == 0.15)
        #expect(SelectionTintStyle.hover.color == SIMD3(0.4, 0.6, 1.0))
        #expect(SelectionTintStyle.hover.strength == 0.08)
        #expect(SelectionTintStyle.off.strength == 0)
        let config = ViewportConfiguration()
        #expect(config.selectionTint == .selection)
        #expect(config.hoverTint == .hover)
        let options = OffscreenRenderOptions()
        #expect(options.selectionTint == .selection)
        #expect(options.hoverTint == .hover)
    }

    @Test("Uniforms packs the tint and clamps colour and strength")
    func packing() {
        let u = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false,
            selectionTint: SelectionTintStyle(color: SIMD3(2, -1, 0.5), strength: 4),
            hoverTint: SelectionTintStyle(color: SIMD3(0.2, 0.3, 0.4), strength: -1))
        #expect(u.selectionTint == SIMD4(1, 0, 0.5, 1))
        #expect(u.hoverTint == SIMD4(0.2, 0.3, 0.4, 0))

        let standard = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false)
        #expect(standard.selectionTint == SIMD4(0.3, 0.5, 1.0, 0.15))
        #expect(standard.hoverTint == SIMD4(0.4, 0.6, 1.0, 0.08))
    }

    @Test("init(matching:) copies the controller's tints")
    func matchingController() {
        var config = ViewportConfiguration()
        config.selectionTint = SelectionTintStyle(color: SIMD3(1, 0.5, 0), strength: 0.4)
        config.hoverTint = .off
        let controller = ViewportController(configuration: config)
        let options = OffscreenRenderOptions(matching: controller, width: 64, height: 64)
        #expect(options.selectionTint == config.selectionTint)
        #expect(options.hoverTint == .off)
    }

    // MARK: Rendering

    private let grey = SIMD4<Float>(0.5, 0.5, 0.5, 1)

    private func unlit(
        selected: Bool = false, hovered: Bool = false,
        selectionTint: SelectionTintStyle = .selection, hoverTint: SelectionTintStyle = .hover
    ) throws -> SIMD3<Int> {
        let body = ViewportBody.sphere(id: "s", radius: 2, color: grey, up: .z)
        return try TintFixtures.centre(
            [body], camera: StandardView.top.cameraState(), lighting: .threePoint,
            displayMode: .unlit
        ) {
            $0.selectedBodyIDs = selected ? ["s"] : []
            $0.hoveredBodyID = hovered ? "s" : nil
            $0.selectionTint = selectionTint
            $0.hoverTint = hoverTint
        }
    }

    private func expectClose(_ c: SIMD3<Int>, _ expected: SIMD3<Float>, _ label: String) {
        let e = SIMD3<Int>(expected * 255 + 0.5)
        #expect(
            abs(c.x - e.x) <= 2 && abs(c.y - e.y) <= 2 && abs(c.z - e.z) <= 2,
            "\(label): got \(c), expected about \(e)")
    }

    @Test("The default selected and hovered tints give the same pixels as before (unlit)")
    func defaultUnlitPixels() throws {
        let plain = try unlit()
        expectClose(plain, SIMD3(0.5, 0.5, 0.5), "unselected")
        expectClose(
            try unlit(selected: true),
            simd_mix(SIMD3(0.5, 0.5, 0.5), SIMD3(0.3, 0.5, 1.0), SIMD3(repeating: 0.15)),
            "selected")
        expectClose(
            try unlit(hovered: true),
            simd_mix(SIMD3(0.5, 0.5, 0.5), SIMD3(0.4, 0.6, 1.0), SIMD3(repeating: 0.08)),
            "hovered")
    }

    @Test("A custom tint colour and strength are applied (unlit)")
    func customUnlitTint() throws {
        let orange = SelectionTintStyle(color: SIMD3(1, 0.5, 0), strength: 0.5)
        expectClose(
            try unlit(selected: true, selectionTint: orange), SIMD3(0.75, 0.5, 0.25),
            "orange selection")
        let green = SelectionTintStyle(color: SIMD3(0, 1, 0), strength: 0.25)
        expectClose(
            try unlit(hovered: true, hoverTint: green), SIMD3(0.375, 0.625, 0.375), "green hover")
    }

    @Test("Strength 0 turns the tint off, and selection wins over hover (unlit)")
    func offAndPrecedence() throws {
        #expect(try unlit(selected: true, selectionTint: .off) == (try unlit()))
        #expect(
            try unlit(
                selected: true,
                selectionTint: SelectionTintStyle(color: SIMD3(1, 0, 0), strength: 0))
                == (try unlit()))
        #expect(try unlit(hovered: true, hoverTint: .off) == (try unlit()))
        // Both: the selected tint is used.
        let both = try unlit(selected: true, hovered: true)
        #expect(both == (try unlit(selected: true)))
    }

    private func lit(
        selected: Bool = false, selectionTint: SelectionTintStyle = .selection,
        hovered: Bool = false, hoverTint: SelectionTintStyle = .hover
    ) throws -> SIMD3<Int> {
        let body = ViewportBody.sphere(id: "s", radius: 2, color: grey, up: .z)
        return try TintFixtures.centre(
            [body], camera: StandardView.top.cameraState(), lighting: .threePoint
        ) {
            $0.selectedBodyIDs = selected ? ["s"] : []
            $0.hoveredBodyID = hovered ? "s" : nil
            $0.selectionTint = selectionTint
            $0.hoverTint = hoverTint
        }
    }

    @Test("In lit shading, off leaves the body as if unselected, and a tint shifts its colour")
    func litTint() throws {
        let plain = try lit()
        #expect(try lit(selected: true, selectionTint: .off) == plain)
        #expect(try lit(hovered: true, hoverTint: .off) == plain)

        // The default blue wash raises blue and lowers red; an orange one does the opposite.
        let blue = try lit(selected: true)
        #expect(blue.z > plain.z && blue.x < plain.x, "default tint: \(blue) vs \(plain)")
        let orange = try lit(
            selected: true,
            selectionTint: SelectionTintStyle(color: SIMD3(1, 0.5, 0), strength: 0.5))
        #expect(orange.x > plain.x + 20 && orange.z < plain.z - 20, "orange tint: \(orange)")

        // The tint is a mix of the lit, encoded colour toward the tint colour.
        let expected = simd_mix(
            SIMD3<Float>(plain) / 255, SIMD3<Float>(1, 0.5, 0), SIMD3(repeating: 0.5))
        expectClose(orange, expected, "lit orange")
    }

    @Test("The tint is independent of the outline colour")
    func independentOfOutline() throws {
        let plain = try lit()
        let a = try TintFixtures.centre(
            [ViewportBody.sphere(id: "s", radius: 2, color: grey, up: .z)],
            camera: StandardView.top.cameraState(), lighting: .threePoint
        ) {
            $0.selectedBodyIDs = ["s"]
            $0.selectionOutline = SelectionOutlineStyle(color: SIMD3(1, 0.5, 0), width: 4)
        }
        // Orange outline, default (blue) tint: the body is still washed blue, not orange.
        #expect(a.z > plain.z && a.x < plain.x, "tint followed the outline colour: \(a)")
    }

    @Test("The live renderer applies the configured tint")
    func liveRendererHonoursTint() throws {
        func scene(_ tint: SelectionTintStyle) -> OffscreenLiveParityTests.Scene {
            var config = ViewportConfiguration()
            config.selectionTint = tint
            return OffscreenLiveParityTests.Scene(
                name: "tint", configuration: config, selectedBodyIDs: ["sphere"])
        }
        let orange = SelectionTintStyle(color: SIMD3(1, 0.5, 0), strength: 0.6)
        guard let standard = OffscreenLiveParityTests.renderBoth(scene(.selection)),
            let custom = OffscreenLiveParityTests.renderBoth(scene(orange)),
            let off = OffscreenLiveParityTests.renderBoth(scene(.off))
        else {
            Issue.record("Metal device unavailable")
            return
        }
        #expect(standard.live != custom.live, "live renderer ignored selectionTint")
        #expect(standard.live != off.live, "live renderer ignored selectionTint = .off")
        #expect(custom.live != off.live)
        // Live and offscreen agree about the tinted body, to within MSAA edge coverage.
        func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
            var n = 0
            for p in stride(from: 0, to: a.count, by: 4) {
                let d = (0..<3).map { abs(Int(a[p + $0]) - Int(b[p + $0])) }.max() ?? 0
                if d > 8 { n += 1 }
            }
            return n
        }
        let total = OffscreenLiveParityTests.width * OffscreenLiveParityTests.height
        #expect(differing(custom.live, custom.offscreen) < total / 50)
    }
}
