// SSAOBlurTests.swift
// OCCTSwiftViewport Tests
//
// The depth-aware blur of the SSAO term (issue #188). `ssao_fragment` rotates its sample kernel
// per pixel from a 4x4 ordered (Bayer) pattern, and nothing smoothed the result, so the pattern
// printed itself onto flat faces near an occluder. The occlusion now runs in its own pass into a
// texture, `ssao_blur_fragment` averages a 4x4 window of it weighted by depth, and the composite
// reads the blurred term. The scene is a long low wall on a plane seen from straight above, so
// the true occlusion is constant along every image row: any variation along a row is dither.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("SSAO blur (#188)")
struct SSAOBlurTests {

    /// A decoded render: row-major BGRA8.
    struct Image {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        /// Green channel (the scene is grey, so any channel will do).
        func g(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * width + x) * 4 + 1]) }
    }

    private static let size = 256
    private static let planeColor = SIMD4<Float>(0.6, 0.6, 0.6, 1)
    private static let wallColor = SIMD4<Float>(0.9, 0.9, 0.9, 1)

    /// A 16 x 16 plane and a wall along X, 0.6 wide and 0.4 tall.
    ///
    /// The wall runs off both sides of the
    /// frame so the occlusion has no ends. 0.4 is within the default SSAO radius (0.5), so the wall
    /// occludes the plane beside it; it is a different colour so its top face can be told apart
    /// with SSAO off.
    private static func scene() -> [ViewportBody] {
        let plane = ParityRender.quad(
            id: "plane", x0: -8, y0: -8, x1: 8, y1: 8, color: planeColor)
        var wall = ViewportBody.box(
            id: "wall", width: 16, height: 0.4, depth: 0.6, color: wallColor, up: .z)
        var move = matrix_identity_float4x4
        move.columns.3 = SIMD4(0, 0, 0.2, 1)
        wall.transform = move
        return [plane, wall]
    }

    /// Straight down from +Z, orthographic (12 world units tall) or perspective (distance 10).
    private static func camera(orthographic: Bool) -> CameraState {
        var camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10,
            pivot: .zero)
        if orthographic {
            camera.isOrthographic = true
            camera.orthographicScale = 12
        }
        return camera
    }

    private static func options(
        orthographic: Bool, size: Int = SSAOBlurTests.size, ssao: Bool = true,
        intensity: Float = 1, silhouettes: Bool = false, blur: Bool? = nil
    ) -> OffscreenRenderOptions {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = ssao
        lighting.ssaoIntensity = intensity
        // `nil` leaves `ssaoBlur` at its default, so most tests also cover that default.
        if let blur { lighting.ssaoBlur = blur }
        return OffscreenRenderOptions(
            width: size, height: size, cameraState: camera(orthographic: orthographic),
            displayMode: .shaded, lightingConfiguration: lighting,
            backgroundColor: SIMD4<Float>(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, msaaSampleCount: 1, enableSilhouettes: silhouettes)
    }

    private func render(
        _ options: OffscreenRenderOptions, bodies: [ViewportBody]? = nil,
        renderer: OffscreenRenderer? = nil
    ) throws -> Image {
        guard let renderer = renderer ?? OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw ParityRender.Unavailable()
        }
        let result = try ParityRender.render(
            bodies ?? Self.scene(), options, renderer: renderer)
        return Image(pixels: result.pixels, width: result.width, height: result.height)
    }

    // MARK: - Metrics

    /// The value of a pixel nowhere near the wall, which SSAO leaves alone.
    private static func openLevel(_ image: Image) -> Int { image.g(image.width / 2, 8) }

    /// The dither's amplitude in 8-bit levels.
    ///
    /// That is the mean, over the image rows the wall's occlusion darkens, of the standard
    /// deviation of the row's values across the middle of the frame: true occlusion is constant
    /// along a row of this scene. `rows` is how many rows were measured.
    private static func ditherAmplitude(_ image: Image) -> (std: Double, rows: Int) {
        let open = Double(openLevel(image))
        var stds: [Double] = []
        for y in 0..<image.height {
            let values = (image.width / 4..<image.width * 3 / 4).map { Double(image.g($0, y)) }
            let mean = values.reduce(0, +) / Double(values.count)
            guard mean < open - 6 else { continue }
            let variance =
                values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            stds.append(variance.squareRoot())
        }
        guard !stds.isEmpty else { return (0, 0) }
        return (stds.reduce(0, +) / Double(stds.count), stds.count)
    }

    /// 8-bit sRGB to linear light.
    private static func linear(_ value: Int) -> Double {
        let c = Double(value) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - The dither

    /// Without the blur the Bayer pattern shows as period-4 variation along the rows (2 to 7
    /// levels on this scene); with it the rows are flat to within one level.
    private func checkDither(orthographic: Bool) throws {
        let raw = try render(Self.options(orthographic: orthographic, blur: false))
        // The default setting blurs.
        let blurred = try render(Self.options(orthographic: orthographic))

        let before = Self.ditherAmplitude(raw)
        let after = Self.ditherAmplitude(blurred)
        #expect(
            before.rows >= 8 && after.rows >= 8, "measured only \(before.rows)/\(after.rows) rows")
        #expect(before.std > 2.0, "no dither without the blur: std \(before.std) levels")
        #expect(after.std < 0.75, "dither survives the blur: std \(after.std) levels")
        #expect(
            after.std < before.std / 4, "blur removed too little: \(before.std) to \(after.std)")
    }

    @Test("Orthographic: the blur removes the ordered dither from a flat face")
    func ditherOrthographic() throws {
        try checkDither(orthographic: true)
    }

    @Test("Perspective: the blur removes the ordered dither from a flat face")
    func ditherPerspective() throws {
        try checkDither(orthographic: false)
    }

    // MARK: - Depth discontinuities

    /// Checks the occlusion edge at the wall's silhouette in each of three columns.
    ///
    /// The wall's top face stays exactly as bright as with SSAO off right up to the silhouette, the
    /// plane pixel beside it keeps its full occlusion, and the step between them is one pixel.
    /// A blur that crossed the depth step would darken the top face's edge pixels with the
    /// plane's occlusion and lighten the plane's with the top face's.
    private func checkDepthStep(orthographic: Bool) throws {
        let off = try render(Self.options(orthographic: orthographic, ssao: false))
        let on = try render(Self.options(orthographic: orthographic))
        let open = Self.openLevel(off)
        let isTop: (Int, Int) -> Bool = { x, y in off.g(x, y) > open + 25 }

        var edges = 0
        for x in [96, 128, 160] {
            for y in 0..<(Self.size - 4) {
                if isTop(x, y) {
                    #expect(
                        abs(on.g(x, y) - off.g(x, y)) <= 2,
                        "top face darkened at (\(x), \(y)): on \(on.g(x, y)) off \(off.g(x, y))")
                }
                // A silhouette in this column: top face above, plane below, or the reverse.
                guard isTop(x, y) != isTop(x, y + 1) else { continue }
                edges += 1
                let planeY = isTop(x, y) ? y + 1 : y
                let outward = isTop(x, y) ? 3 : -3
                let darkening = off.g(x, planeY) - on.g(x, planeY)
                #expect(
                    darkening >= 20,
                    "plane pixel at the silhouette (\(x), \(planeY)) lost its occlusion: darkening \(darkening)"
                )
                #expect(
                    on.g(x, planeY) <= on.g(x, planeY + outward),
                    "occlusion at the wall's base is lighter than 3 px away: \(on.g(x, planeY)) vs \(on.g(x, planeY + outward))"
                )
                // The step from the top face to the plane is one pixel, not a ramp.
                #expect(
                    abs(on.g(x, y) - on.g(x, y + 1)) >= 25,
                    "soft silhouette at (\(x), \(y)): \(on.g(x, y)) to \(on.g(x, y + 1))")
            }
        }
        #expect(edges == 6, "expected 2 silhouettes in each of 3 columns, found \(edges)")
    }

    @Test("Orthographic: a box in front of a plane keeps a sharp occlusion edge")
    func depthStepOrthographic() throws {
        try checkDepthStep(orthographic: true)
    }

    @Test("Perspective: a box in front of a plane keeps a sharp occlusion edge")
    func depthStepPerspective() throws {
        try checkDepthStep(orthographic: false)
    }

    // MARK: - Settings

    @Test("ssaoBlur defaults to true in every preset and init(matching:) copies it")
    func ssaoBlurSetting() {
        #expect(LightingConfiguration.threePoint.ssaoBlur)
        #expect(LightingConfiguration.studio.ssaoBlur)
        #expect(LightingConfiguration.architectural.ssaoBlur)
        #expect(LightingConfiguration.flat.ssaoBlur)
        #expect(OffscreenRenderOptions().lightingConfiguration.ssaoBlur)
        #expect(
            !LightingConfiguration(
                keyLight: LightSettings(direction: SIMD3(0, 0, -1), intensity: 1),
                fillLight: LightSettings(direction: SIMD3(0, 0, -1), intensity: 0),
                backLight: LightSettings(direction: SIMD3(0, 0, -1), intensity: 0),
                ssaoBlur: false
            ).ssaoBlur)

        var lighting = LightingConfiguration.threePoint
        lighting.ssaoBlur = false
        let controller = ViewportController(
            configuration: ViewportConfiguration(lightingConfiguration: lighting))
        #expect(!controller.lightingConfiguration.ssaoBlur)
        let options = OffscreenRenderOptions(matching: controller, width: 64, height: 64)
        #expect(!options.lightingConfiguration.ssaoBlur)
    }

    @Test("ssaoBlur = false skips the blur pass and composites the raw dithered occlusion")
    func ssaoBlurOffSkipsThePass() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let off = try render(
            Self.options(orthographic: true, blur: false), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 1)
        #expect(renderer.ssaoOcclusionTargets.blurPassesEncoded == 0)

        let on = try render(Self.options(orthographic: true, blur: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 2)
        #expect(renderer.ssaoOcclusionTargets.blurPassesEncoded == 1)

        // The default is the same as an explicit `true`, pixel for pixel.
        let byDefault = try render(Self.options(orthographic: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.blurPassesEncoded == 2)
        #expect(byDefault.pixels == on.pixels)

        // Off differs from on, and carries the dither the blur removes.
        #expect(off.pixels != on.pixels)
        #expect(Self.ditherAmplitude(off).std > 2.0)
        #expect(Self.ditherAmplitude(on).std < 0.75)

        // Away from any occluder the two agree: the blur only touches occluded pixels.
        for x in [10, 128, 240] {
            #expect(off.g(x, 8) == on.g(x, 8))
        }

        // SSAO off runs neither pass, whatever `ssaoBlur` says.
        let before = renderer.ssaoOcclusionTargets.passesEncoded
        _ = try render(
            Self.options(orthographic: true, ssao: false, blur: true), renderer: renderer)
        _ = try render(
            Self.options(orthographic: true, ssao: false, blur: false), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == before)
        #expect(renderer.ssaoOcclusionTargets.blurPassesEncoded == 2)
    }

    @Test("The blurred occlusion still scales with ssaoIntensity")
    func intensityScalesBlurredOcclusion() throws {
        let off = try render(Self.options(orthographic: true, ssao: false))
        let full = try render(Self.options(orthographic: true, intensity: 1))
        let half = try render(Self.options(orthographic: true, intensity: 0.5))
        // The plane pixel next to the wall, where the occlusion is strongest.
        let x = Self.size / 2
        let y = (0..<Self.size).first { off.g(x, $0) > Self.openLevel(off) + 25 }!
        let planeY = (y..<Self.size).first { off.g(x, $0) <= Self.openLevel(off) + 25 }!
        let fullAO = 1 - Self.linear(full.g(x, planeY)) / Self.linear(off.g(x, planeY))
        let halfAO = 1 - Self.linear(half.g(x, planeY)) / Self.linear(off.g(x, planeY))
        #expect(fullAO > 0.15, "no occlusion at full intensity: \(fullAO)")
        #expect(
            abs(halfAO - fullAO / 2) < 0.04,
            "intensity 0.5 gave \(halfAO), expected about \(fullAO / 2)")
    }

    // MARK: - Cost when SSAO is off

    @Test("SSAO off encodes no occlusion pass and allocates no occlusion texture")
    func ssaoOffCostsNothing() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        // Silhouettes alone run the composite, but it multiplies in no occlusion.
        _ = try render(
            Self.options(orthographic: true, ssao: false, silhouettes: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 0)
        #expect(!renderer.ssaoOcclusionTargets.isAllocated)

        // enableSSAO with zero intensity is also off.
        _ = try render(Self.options(orthographic: true, intensity: 0), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 0)
        #expect(!renderer.ssaoOcclusionTargets.isAllocated)

        // Unlit bypasses the composite entirely.
        var unlit = Self.options(orthographic: true)
        unlit.displayMode = .unlit
        _ = try render(unlit, renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 0)
        #expect(!renderer.ssaoOcclusionTargets.isAllocated)
    }

    @Test("SSAO on runs one occlusion pass per frame; turning it off releases the textures")
    func ssaoOnRunsOnePassAndOffReleases() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        _ = try render(Self.options(orthographic: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 1)
        #expect(renderer.ssaoOcclusionTargets.isAllocated)
        _ = try render(Self.options(orthographic: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 2)

        _ = try render(Self.options(orthographic: true, ssao: false), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 2)
        #expect(!renderer.ssaoOcclusionTargets.isAllocated)

        // And back on: allocated again.
        _ = try render(Self.options(orthographic: true), renderer: renderer)
        #expect(renderer.ssaoOcclusionTargets.passesEncoded == 3)
        #expect(renderer.ssaoOcclusionTargets.isAllocated)
    }

    @Test("The occlusion textures follow the frame size")
    func texturesFollowResize() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        for size in [128, 192, 128] {
            _ = try render(Self.options(orthographic: true, size: size), renderer: renderer)
            let targets = renderer.ssaoOcclusionTargets
            #expect(targets.raw?.width == size && targets.raw?.height == size)
            #expect(targets.blurred?.width == size && targets.blurred?.height == size)
            #expect(targets.raw?.pixelFormat == .r32Float)
            #expect(targets.blurred?.pixelFormat == .r16Float)
        }
    }

    // MARK: - Live renderer

    /// Renders the same scene through the headless entry point of `ViewportRenderer`.
    private func renderLive(
        ssao: Bool, blur: Bool? = nil, renderer existing: ViewportRenderer? = nil
    ) -> (image: Image, renderer: ViewportRenderer)? {
        var lighting = LightingConfiguration.threePoint
        lighting.shadowsEnabled = false
        lighting.enableSSAO = ssao
        lighting.ssaoIntensity = 1
        if let blur { lighting.ssaoBlur = blur }
        let background = SIMD4<Float>(0, 0, 0, 1)
        let configuration = ViewportConfiguration(
            initialCameraState: Self.camera(orthographic: false), displayMode: .shaded,
            lightingConfiguration: lighting, showAxes: false, showGrid: false,
            backgroundColor: background, enableSilhouettes: false)
        let controller = ViewportController(configuration: configuration)
        controller.lightingConfiguration = lighting
        controller.showGrid = false
        controller.showAxes = false
        guard
            let renderer = existing
                ?? ViewportRenderer(controller: controller, bodies: .constant(Self.scene()))
        else { return nil }
        guard
            let pixels = renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: background)
        else { return nil }
        return (Image(pixels: pixels, width: Self.size, height: Self.size), renderer)
    }

    @Test("The live renderer blurs its occlusion too, and holds no AO textures with SSAO off")
    func liveRenderer() throws {
        guard let raw = renderLive(ssao: true, blur: false),
            let blurred = renderLive(ssao: true),
            let off = renderLive(ssao: false)
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let before = Self.ditherAmplitude(raw.image)
        let after = Self.ditherAmplitude(blurred.image)
        #expect(before.rows >= 8 && after.rows >= 8)
        #expect(before.std > 2.0, "no dither without the blur: std \(before.std) levels")
        #expect(after.std < 0.75, "dither survives the blur: std \(after.std) levels")

        #expect(blurred.renderer.ssaoOcclusionTargets.passesEncoded == 1)
        #expect(blurred.renderer.ssaoOcclusionTargets.blurPassesEncoded == 1)
        #expect(blurred.renderer.ssaoOcclusionTargets.isAllocated)
        #expect(raw.renderer.ssaoOcclusionTargets.passesEncoded == 1)
        #expect(raw.renderer.ssaoOcclusionTargets.blurPassesEncoded == 0)
        #expect(off.renderer.ssaoOcclusionTargets.passesEncoded == 0)
        #expect(!off.renderer.ssaoOcclusionTargets.isAllocated)
    }

    // MARK: - Before / after images (not asserted)

    /// Writes before / after images for a human to look at.
    ///
    /// With `OCCT_SSAO_BLUR_PNG_DIR` set, writes renders of a box and a cylinder on a plane, and
    /// 6x contrast-stretched crops of the plane beside the box where the dither shows. Does
    /// nothing otherwise.
    @Test("Writes before / after images when OCCT_SSAO_BLUR_PNG_DIR is set")
    func writeImages() throws {
        guard let directory = ProcessInfo.processInfo.environment["OCCT_SSAO_BLUR_PNG_DIR"]
        else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var box = ViewportBody.box(
            id: "box", width: 2, height: 1.5, depth: 2, color: SIMD4(0.75, 0.55, 0.3, 1), up: .z)
        var boxMove = matrix_identity_float4x4
        boxMove.columns.3 = SIMD4(-1.5, 0, 0.75, 1)
        box.transform = boxMove
        var cylinder = ViewportBody.cylinder(
            id: "cylinder", radius: 0.8, height: 2, color: SIMD4(0.35, 0.5, 0.75, 1), up: .z)
        var cylinderMove = matrix_identity_float4x4
        cylinderMove.columns.3 = SIMD4(1.8, 0.5, 1, 1)
        cylinder.transform = cylinderMove
        let plane = ParityRender.quad(
            id: "plane", x0: -8, y0: -8, x1: 8, y1: 8, color: Self.planeColor)

        for (name, orthographic) in [("perspective", false), ("orthographic", true)] {
            var camera = Self.camera(orthographic: orthographic)
            camera.rotation = simd_quatf(angle: 0.9, axis: SIMD3<Float>(1, 0, 0))
            camera.distance = 12
            camera.orthographicScale = 9
            var options = Self.options(orthographic: orthographic, size: 640)
            options.cameraState = camera
            options.width = 640
            options.height = 480
            options.lightingConfiguration.ssaoIntensity = 0.9
            for (label, blur) in [("before", false), ("after", true)] {
                options.lightingConfiguration.ssaoBlur = blur
                let image = try render(options, bodies: [plane, box, cylinder])
                try Self.writePNG(
                    image, to: folder.appendingPathComponent("\(name)-\(label).png"))
                try Self.writePNG(
                    image, to: folder.appendingPathComponent("\(name)-\(label)-crop.png"),
                    crop: (170, 232, 140, 60), scale: 6, stretch: 125...185)
            }
        }
        // The flat-plane test scene, as the dither tests see it.
        for (label, blur) in [("before", false), ("after", true)] {
            let image = try render(Self.options(orthographic: true, blur: blur))
            try Self.writePNG(
                image, to: folder.appendingPathComponent("wall-\(label)-crop.png"),
                crop: (64, 96, 128, 64), scale: 6, stretch: 100...164)
        }
    }

    private static func writePNG(
        _ image: Image, to url: URL, crop: (x: Int, y: Int, w: Int, h: Int)? = nil,
        scale: Int = 1, stretch: ClosedRange<Int>? = nil
    ) throws {
        let region = crop ?? (0, 0, image.width, image.height)
        let outWidth = region.w * scale
        let outHeight = region.h * scale
        var out = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                let sx = min(region.x + x / scale, image.width - 1)
                let sy = min(region.y + y / scale, image.height - 1)
                for channel in 0..<3 {
                    var value = Int(image.pixels[(sy * image.width + sx) * 4 + channel])
                    // Spread a narrow band of levels over 0...255 so a 2 to 7 level dither shows.
                    if let stretch {
                        value = min(
                            255,
                            max(
                                0,
                                (value - stretch.lowerBound) * 255
                                    / (stretch.upperBound - stretch.lowerBound)))
                    }
                    // BGRA to RGBA.
                    out[(y * outWidth + x) * 4 + (2 - channel)] = UInt8(value)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData),
            let cgImage = CGImage(
                width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: outWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ParityRender.Unavailable() }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ParityRender.Unavailable() }
    }
}
