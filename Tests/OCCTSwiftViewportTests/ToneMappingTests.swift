// ToneMappingTests.swift
// OCCTSwiftViewport Tests
//
// Linear-space lighting and tone mapping on every frame (issue #136, finding H6). Tone mapping
// and `LightingConfiguration.exposure` / `whitePoint` used to run only inside the SSAO /
// silhouette composite, on an image that had already clipped. With both effects off (the
// `.performance` preset) and in every `OffscreenRenderer` image, HDR highlights clipped to 255,
// `exposure` did nothing, and live and offscreen output differed. `shaded_fragment` now decodes
// its sRGB inputs, lights and tone maps in linear, and encodes to sRGB once; authored colours
// drawn without lighting (unlit bodies, edges, background) pass through unchanged.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Tone mapping on every frame (#136 H6)")
struct ToneMappingTests {

    private static let size = 64

    // Camera at +Z (identity rotation) looking down -Z at the origin.
    private static let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero
    )

    private static let black = SIMD4<Float>(0, 0, 0, 1)

    /// A flat quad facing the camera that covers the centre of the frame.
    ///
    /// With `emissive` set, the lit colour is well above 1.0 (HDR), which is what tone mapping
    /// exists to compress instead of clipping.
    private static func panel(
        color: SIMD4<Float> = SIMD4<Float>(0.9, 0.9, 0.9, 1),
        emissive: Float = 0,
        edges: Bool = false
    ) -> ViewportBody {
        let z: Float = 3
        let half: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        let idx: [UInt32] = [0, 1, 2, 0, 2, 3]
        // A horizontal edge through the centre, for the edge-colour test.
        let edgeLines: [[SIMD3<Float>]] =
            edges ? [[SIMD3<Float>(-half, 0, z + 0.01), SIMD3<Float>(half, 0, z + 0.01)]] : []
        var body = ViewportBody(
            id: "panel", vertexData: verts, indices: idx, edges: edgeLines, color: color)
        if emissive > 0 {
            body.material = PBRMaterial(
                baseColor: SIMD3<Float>(color.x, color.y, color.z),
                emissive: SIMD3<Float>(1, 1, 1), emissiveStrength: emissive)
        }
        return body
    }

    /// `.threePoint` with shadows off, SSAO on or off, and the given exposure.
    private static func lighting(
        ssao: Bool = false, ssaoIntensity: Float = 0.6, exposure: Float = 1.1
    ) -> LightingConfiguration {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = ssao
        lighting.ssaoIntensity = ssaoIntensity
        lighting.exposure = exposure
        return lighting
    }

    // MARK: Rendering

    /// Centre pixel (r, g, b) of an `OffscreenRenderer` frame, or `nil` without Metal.
    private func offscreenCentre(
        _ body: ViewportBody, lighting: LightingConfiguration, mode: DisplayMode = .shaded
    ) -> SIMD3<Int>? {
        guard let renderer = OffscreenRenderer() else { return nil }
        var options = OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: Self.camera, displayMode: mode,
            lightingConfiguration: lighting, backgroundColor: Self.black)
        options.appearance = .light  // reproducible: don't follow the system dark mode
        options.showGrid = false
        options.showAxes = false
        guard let image = renderer.render(bodies: [body], options: options) else { return nil }
        return Self.centre(Self.readBGRA(image))
    }

    /// Centre pixel (r, g, b) of a headless `ViewportRenderer` frame, or `nil` without Metal.
    private func liveCentre(
        _ body: ViewportBody, lighting: LightingConfiguration, silhouettes: Bool = false,
        mode: DisplayMode = .shaded
    ) -> SIMD3<Int>? {
        let configuration = ViewportConfiguration(
            initialCameraState: Self.camera, displayMode: mode, lightingConfiguration: lighting,
            showAxes: false, showGrid: false, backgroundColor: Self.black,
            enableSilhouettes: silhouettes)
        let controller = ViewportController(configuration: configuration)
        controller.displayMode = mode
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        guard
            let renderer = ViewportRenderer(controller: controller, bodies: .constant([body])),
            let pixels = renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: Self.black)
        else { return nil }
        return Self.centre(pixels)
    }

    private static func centre(_ bgra: [UInt8]) -> SIMD3<Int> {
        let i = (size / 2) * size * 4 + (size / 2) * 4
        return SIMD3<Int>(Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i]))
    }

    private static func readBGRA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private static func maxDelta(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
        let d = a &- b
        return max(abs(d.x), abs(d.y), abs(d.z))
    }

    // MARK: Tests

    @Test("Uniforms carry exposure and white point without changing the struct's size")
    func uniformsPackToneMapping() {
        var lighting = LightingConfiguration.flat
        lighting.whitePoint = 1.7
        let uniforms = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: lighting,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false)
        #expect(uniforms.toneMapExposure == 0.9)
        #expect(uniforms.toneMapWhitePoint == 1.7)
        // The two floats took the place of the old `_clipPad: float2`, so the Metal struct's
        // 16-byte tail slot (clipPlaneCount, unlit, exposure, whitePoint) is unchanged.
        #expect(
            MemoryLayout<Uniforms>.offset(of: \Uniforms.toneMapExposure)
                == MemoryLayout<Uniforms>.offset(of: \Uniforms.unlit)! + 4)
        #expect(MemoryLayout<Uniforms>.stride % 16 == 0)
    }

    @Test("Offscreen: an HDR surface is compressed, not clipped to 255")
    func offscreenHDRDoesNotClip() throws {
        guard let rgb = offscreenCentre(Self.panel(emissive: 1.5), lighting: Self.lighting())
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        // Lit colour is ~2.0+ per channel. Un-tone-mapped it clips to 255; ACES maps it to ~235.
        #expect(rgb.x < 250 && rgb.y < 250 && rgb.z < 250, "clipped: \(rgb)")
        #expect(rgb.x > 180, "should still be bright: \(rgb)")
    }

    @Test("Live with SSAO and silhouettes off: an HDR surface is compressed, not clipped")
    func liveNoCompositeHDRDoesNotClip() throws {
        guard let rgb = liveCentre(Self.panel(emissive: 1.5), lighting: Self.lighting()) else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(rgb.x < 250 && rgb.y < 250 && rgb.z < 250, "clipped: \(rgb)")
        #expect(rgb.x > 180, "should still be bright: \(rgb)")
    }

    @Test("exposure changes the output with SSAO and silhouettes off, live and offscreen")
    func exposureAppliesWithoutComposite() throws {
        let body = Self.panel()
        guard
            let liveDim = liveCentre(body, lighting: Self.lighting(exposure: 0.5)),
            let liveBright = liveCentre(body, lighting: Self.lighting(exposure: 1.6)),
            let offDim = offscreenCentre(body, lighting: Self.lighting(exposure: 0.5)),
            let offBright = offscreenCentre(body, lighting: Self.lighting(exposure: 1.6))
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(liveBright.x - liveDim.x > 30, "live: dim \(liveDim) bright \(liveBright)")
        #expect(offBright.x - offDim.x > 30, "offscreen: dim \(offDim) bright \(offBright)")
    }

    @Test("Offscreen matches live, with and without the composite pass running")
    func offscreenMatchesLive() throws {
        let body = Self.panel(emissive: 0.4)
        let exposure: Float = 1.4
        // Composite running but neutral: SSAO on at zero intensity, silhouettes off. It used to
        // tone map here (live only), so offscreen never matched.
        guard
            let off = offscreenCentre(body, lighting: Self.lighting(exposure: exposure)),
            let liveNoComposite = liveCentre(body, lighting: Self.lighting(exposure: exposure)),
            let liveComposite = liveCentre(
                body, lighting: Self.lighting(ssao: true, ssaoIntensity: 0, exposure: exposure))
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(Self.maxDelta(off, liveNoComposite) <= 2, "off \(off) live \(liveNoComposite)")
        #expect(
            Self.maxDelta(off, liveComposite) <= 2, "off \(off) live+composite \(liveComposite)")
    }

    @Test("Unlit bodies and edge colours ignore exposure")
    func unlitAndEdgesIgnoreExposure() throws {
        let magenta = SIMD4<Float>(1.0, 0.15, 0.85, 1)
        let edged = Self.panel(color: SIMD4<Float>(0, 0, 0, 1), edges: true)
        guard
            let unlitLow = offscreenCentre(
                Self.panel(color: magenta), lighting: Self.lighting(exposure: 0.4), mode: .unlit),
            let unlitHigh = offscreenCentre(
                Self.panel(color: magenta), lighting: Self.lighting(exposure: 2.0), mode: .unlit),
            let edgeLow = liveCentre(
                edged, lighting: Self.lighting(exposure: 0.4), mode: .wireframe),
            let edgeHigh = liveCentre(
                edged, lighting: Self.lighting(exposure: 2.0), mode: .wireframe)
        else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(unlitLow == unlitHigh, "unlit moved with exposure: \(unlitLow) vs \(unlitHigh)")
        #expect(unlitLow.x > 240 && unlitLow.y < 60, "unlit should stay magenta: \(unlitLow)")
        #expect(edgeLow == edgeHigh, "edge moved with exposure: \(edgeLow) vs \(edgeHigh)")
        #expect(edgeLow.x + edgeLow.y + edgeLow.z > 0, "edge should be drawn: \(edgeLow)")
    }

    @Test("The background colour is an sRGB value written as given, live and offscreen")
    func backgroundPassesThrough() throws {
        let background = SIMD4<Float>(0.5, 0.25, 0.75, 1)
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var options = OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: Self.camera,
            lightingConfiguration: Self.lighting(), backgroundColor: background)
        options.appearance = .light  // reproducible: don't follow the system dark mode
        options.showGrid = false
        options.showAxes = false
        // A small body off to the side keeps the frame non-empty; the centre stays background.
        var body = Self.panel()
        body.transform = simd_float4x4(diagonal: SIMD4<Float>(0.05, 0.05, 1, 1))
        body.transform.columns.3 = SIMD4<Float>(2.5, 2.5, 0, 1)
        let image = try #require(renderer.render(bodies: [body], options: options))
        let off = Self.centre(Self.readBGRA(image))

        let configuration = ViewportConfiguration(
            initialCameraState: Self.camera, lightingConfiguration: Self.lighting(ssao: true),
            showAxes: false, showGrid: false, backgroundColor: background)
        let controller = ViewportController(configuration: configuration)
        controller.lightingConfiguration = Self.lighting(ssao: true)
        controller.showGrid = false
        controller.showAxes = false
        let live = try #require(
            ViewportRenderer(controller: controller, bodies: .constant([body]))?
                .renderHeadlessBGRA(
                    width: Self.size, height: Self.size, backgroundColor: background
                )
                .map(Self.centre))
        let expected = SIMD3<Int>(128, 64, 191)
        #expect(Self.maxDelta(off, expected) <= 1, "offscreen background \(off)")
        #expect(Self.maxDelta(live, expected) <= 1, "live background \(live)")
    }

    @Test("The selection outline colour is an sRGB value drawn as given, at any exposure")
    func selectionOutlinePassesThrough() throws {
        // A small selected panel in the middle, so the outline ring lies over the background.
        var body = Self.panel()
        body.transform = simd_float4x4(diagonal: SIMD4<Float>(0.3, 0.3, 1, 1))
        var counts: [Int] = []
        for exposure: Float in [0.4, 2.0] {
            var configuration = ViewportConfiguration(
                initialCameraState: Self.camera,
                lightingConfiguration: Self.lighting(ssao: true, exposure: exposure),
                showAxes: false, showGrid: false, backgroundColor: Self.black)
            configuration.selectionOutline = SelectionOutlineStyle(
                color: SIMD3<Float>(1.0, 0.5, 0.0), width: 4)
            let controller = ViewportController(configuration: configuration)
            controller.lightingConfiguration = Self.lighting(ssao: true, exposure: exposure)
            controller.showGrid = false
            controller.showAxes = false
            controller.selectedBodyIDs = ["panel"]
            guard
                let pixels = ViewportRenderer(controller: controller, bodies: .constant([body]))?
                    .renderHeadlessBGRA(
                        width: Self.size, height: Self.size, backgroundColor: Self.black)
            else {
                Issue.record("Metal device unavailable; skipping")
                return
            }
            var exact = 0
            for p in stride(from: 0, to: pixels.count, by: 4) {
                let rgb = SIMD3<Int>(Int(pixels[p + 2]), Int(pixels[p + 1]), Int(pixels[p]))
                if Self.maxDelta(rgb, SIMD3<Int>(255, 128, 0)) <= 1 { exact += 1 }
            }
            counts.append(exact)
        }
        #expect(counts[0] > 20, "outline not drawn in its exact colour: \(counts)")
        #expect(counts[0] == counts[1], "outline changed with exposure: \(counts)")
    }
}
