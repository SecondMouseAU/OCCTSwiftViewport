// LightingConfigFieldsTests.swift
// OCCTSwiftViewport Tests
//
// LightingConfiguration fields that used to be silently ignored (issue #136, M1), and the
// Z-up hemisphere / environment orientation (M13). Pure packing logic is tested directly;
// the shading effects are checked with headless OffscreenRenderer renders of a flat panel.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Packing

@Suite("Lighting scales packing")
struct LightingScalesPackingTests {

    @Test("The .threePoint preset is the reference: ambient and specular scales are 1")
    func threePointIsReference() {
        #expect(Uniforms.lightingScales(for: .threePoint) == SIMD4<Float>(1, 1, 1, 1))
    }

    @Test("ambientIntensity and ambientColor multiply into the ambient scale")
    func ambientScale() {
        var lighting = LightingConfiguration.threePoint
        lighting.ambientIntensity = 0.5
        lighting.ambientColor = SIMD3<Float>(1, 0.5, 0)
        let scales = Uniforms.lightingScales(for: lighting)
        #expect(scales.x == 2)
        #expect(scales.y == 1)
        #expect(scales.z == 0)

        lighting.ambientIntensity = 0
        #expect(Uniforms.lightingScales(for: lighting).x == 0)
    }

    @Test("specularIntensity maps to a GGX lobe scale, 0.5 = physically based")
    func specularScale() {
        var lighting = LightingConfiguration.threePoint
        lighting.specularIntensity = 0
        #expect(Uniforms.lightingScales(for: lighting).w == 0)
        lighting.specularIntensity = 1
        #expect(Uniforms.lightingScales(for: lighting).w == 2)
        #expect(Uniforms.lightingScales(for: .flat).w == 0)
    }

    @Test("Negative intensities and colour channels clamp to zero")
    func negativeClamps() {
        var lighting = LightingConfiguration.threePoint
        lighting.ambientIntensity = -1
        lighting.specularIntensity = -1
        #expect(Uniforms.lightingScales(for: lighting) == .zero)
        lighting.ambientIntensity = 0.25
        lighting.ambientColor = SIMD3<Float>(-1, 1, 1)
        #expect(Uniforms.lightingScales(for: lighting).x == 0)
    }
}

// MARK: - Environment map sync decisions

@Suite("Environment map configuration sync")
struct EnvironmentMapSyncTests {

    typealias Source = EnvironmentMapManager.ConfiguredSource

    @Test("environmentMapURL takes precedence over environmentMapData")
    func urlTakesPrecedence() {
        var lighting = LightingConfiguration.threePoint
        #expect(Source.from(lighting) == nil)
        lighting.environmentMapData = Data([1, 2, 3])
        guard case .data? = Source.from(lighting) else {
            Issue.record("expected a data source")
            return
        }
        lighting.environmentMapURL = URL(fileURLWithPath: "/tmp/sky.hdr")
        guard case .url(let url)? = Source.from(lighting) else {
            Issue.record("expected a URL source")
            return
        }
        #expect(url.lastPathComponent == "sky.hdr")
    }

    @Test("Unchanged sources do nothing, so an explicitly loaded map survives")
    func unchangedDoesNothing() {
        let big = Data(count: 100_000)
        #expect(EnvironmentMapManager.syncAction(previous: nil, current: nil) == .none)
        #expect(
            EnvironmentMapManager.syncAction(previous: .data(big), current: .data(big)) == .none)
        let url = URL(fileURLWithPath: "/tmp/a.hdr")
        #expect(EnvironmentMapManager.syncAction(previous: .url(url), current: .url(url)) == .none)
    }

    @Test("A new source loads; removing the configured source clears")
    func changesLoadOrClear() {
        let a = URL(fileURLWithPath: "/tmp/a.hdr")
        let b = URL(fileURLWithPath: "/tmp/b.hdr")
        #expect(EnvironmentMapManager.syncAction(previous: nil, current: .url(a)) == .load)
        #expect(EnvironmentMapManager.syncAction(previous: .url(a), current: .url(b)) == .load)
        #expect(
            EnvironmentMapManager.syncAction(previous: .url(a), current: .data(Data([1]))) == .load)
        #expect(EnvironmentMapManager.syncAction(previous: .url(a), current: nil) == .clear)
        // Small buffers compare by content.
        #expect(Source.same(.data(Data([1, 2])), .data(Data([1, 2]))))
        #expect(!Source.same(.data(Data([1, 2])), .data(Data([1, 3]))))
    }
}

// MARK: - Headless shading

@MainActor
@Suite("Lighting configuration fields affect shading")
struct LightingConfigShadingTests {

    /// Camera above the origin looking down −Z (identity rotation = the top view).
    private let topCamera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)), distance: 10, pivot: .zero)

    /// Camera below the origin looking up +Z.
    private let bottomCamera = CameraState(
        rotation: simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)), distance: 10, pivot: .zero)

    /// A flat square at z = 0 whose normal is `+Z` (`up`) or `−Z`, filling the frame centre.
    private func panel(
        up: Bool, color: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1), roughness: Float = 0.5
    )
        -> ViewportBody
    {
        let n: Float = up ? 1 : -1
        let h: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, n] }
        let verts = v(-h, -h) + v(h, -h) + v(h, h) + v(-h, h)
        let idx: [UInt32] = up ? [0, 1, 2, 0, 2, 3] : [0, 2, 1, 0, 3, 2]
        return ViewportBody(
            id: "panel", vertexData: verts, indices: idx, edges: [], color: color,
            roughness: roughness)
    }

    /// Lighting with every direct light, shadow, rim and matcap term switched off, so the only
    /// light left is the ambient hemisphere (and environment reflection).
    private func ambientOnly() -> LightingConfiguration {
        let off = LightSettings(direction: SIMD3<Float>(0, 0, -1), intensity: 0, isEnabled: false)
        return LightingConfiguration(
            keyLight: off, fillLight: off, backLight: off,
            ambientIntensity: 0.25, shadowsEnabled: false, fresnelIntensity: 0,
            matcapBlend: 0, enableSSAO: false)
    }

    private func centre(
        _ body: ViewportBody, _ lighting: LightingConfiguration, camera: CameraState? = nil
    ) -> (r: Int, g: Int, b: Int)? {
        guard let renderer = OffscreenRenderer() else { return nil }
        let options = OffscreenRenderOptions(
            width: 32, height: 32, cameraState: camera ?? topCamera, displayMode: .shaded,
            lightingConfiguration: lighting, backgroundColor: SIMD4<Float>(0, 0, 0, 1))
        guard let image = renderer.render(bodies: [body], options: options) else { return nil }
        return Self.centrePixel(image)
    }

    @Test("ambientIntensity scales the brightness of a face lit only by ambient")
    func ambientIntensityScalesBrightness() throws {
        var dim = ambientOnly()
        dim.ambientIntensity = 0
        var bright = ambientOnly()
        bright.ambientIntensity = 0.5
        guard let d = centre(panel(up: true), dim), let b = centre(panel(up: true), bright) else {
            Issue.record("Metal device unavailable or render failed")
            return
        }
        #expect(b.g > d.g + 60, "ambientIntensity 0.5 should be much brighter than 0: \(b) vs \(d)")
        #expect(d.g < 40, "ambientIntensity 0 should leave the face nearly black, got \(d)")
    }

    @Test("ambientColor tints the ambient term")
    func ambientColorTints() throws {
        var lighting = ambientOnly()
        lighting.ambientColor = SIMD3<Float>(1, 0, 0)
        guard let c = centre(panel(up: true), lighting) else {
            Issue.record("Metal device unavailable or render failed")
            return
        }
        #expect(
            c.r > c.g + 60 && c.r > c.b + 60, "a red ambientColor should tint the face red: \(c)")
    }

    @Test("The ambient hemisphere is Z-up: sky on +Z faces, ground on −Z faces")
    func hemisphereIsZUp() throws {
        var lighting = ambientOnly()
        lighting.ambientSkyColor = SIMD3<Float>(0, 0, 1)
        lighting.ambientGroundColor = SIMD3<Float>(1, 0, 0)
        guard let top = centre(panel(up: true), lighting),
            let bottom = centre(panel(up: false), lighting, camera: bottomCamera)
        else {
            Issue.record("Metal device unavailable or render failed")
            return
        }
        #expect(top.b > top.r + 60, "an up-facing face should take the sky colour: \(top)")
        #expect(
            bottom.r > bottom.b + 60, "a down-facing face should take the ground colour: \(bottom)")
    }

    @Test("specularIntensity scales the direct-light GGX highlight")
    func specularIntensityScalesHighlight() throws {
        var lighting = ambientOnly()
        lighting.ambientIntensity = 0
        lighting.keyLight = LightSettings(direction: SIMD3<Float>(0, 0, -1), intensity: 1)
        var none = lighting
        none.specularIntensity = 0
        let body = panel(up: true, color: SIMD4<Float>(0.05, 0.05, 0.05, 1), roughness: 0.3)
        guard let withSpec = centre(body, lighting), let without = centre(body, none) else {
            Issue.record("Metal device unavailable or render failed")
            return
        }
        #expect(
            withSpec.g > without.g + 60,
            "specularIntensity 0 should remove the highlight: \(withSpec) vs \(without)")
    }

    @Test("environmentMapData auto-loads in the headless renderer, sky above (+Z)")
    func environmentMapDataAutoLoads() throws {
        // 64×32 equirect: top half bright green sky, bottom half near-black ground.
        let w = 64
        let h = 32
        var data = Data()
        withUnsafeBytes(of: Int32(w)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(h)) { data.append(contentsOf: $0) }
        var pixels = [Float]()
        for y in 0..<h {
            let px: [Float] = y < h / 2 ? [0, 1, 0, 1] : [0.02, 0, 0, 1]
            for _ in 0..<w { pixels += px }
        }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }

        var lighting = ambientOnly()
        lighting.ambientIntensity = 0
        lighting.environmentMapData = data
        guard let top = centre(panel(up: true), lighting),
            let bottom = centre(panel(up: false), lighting, camera: bottomCamera)
        else {
            Issue.record("Metal device unavailable or render failed")
            return
        }
        #expect(
            top.g > 80 && top.g > top.r + 50, "an up-facing face should be lit by the sky: \(top)")
        #expect(bottom.g < top.g / 2, "a down-facing face should see the dark ground: \(bottom)")
    }

    // MARK: - Pixel helpers

    private static func centrePixel(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo)
            {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let i = (height / 2) * bytesPerRow + (width / 2) * 4
        return (Int(buffer[i + 2]), Int(buffer[i + 1]), Int(buffer[i]))
    }
}
