// OffscreenSampleCountTests.swift
// OCCTSwiftViewport Tests
//
// `OffscreenRenderOptions.msaaSampleCount` (issue #134). `OffscreenRenderer` used to build every
// pipeline for a hard-coded 4 samples and always make multisample textures, so a count of 1
// aborted on Metal validation and any count other than 4 mismatched the pipelines. These render a
// panel at each count, including switching counts on one renderer, and pin the count mapping.

import CoreGraphics
import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Offscreen MSAA sample count mapping")
struct OffscreenSampleCountMappingTests {

    private static func all(_ count: Int) -> Bool { true }

    @Test("Counts below 2 mean no MSAA")
    func belowTwoIsOne() {
        for requested in [-3, 0, 1] {
            #expect(OffscreenRenderer.supportedSampleCount(requested, supports: Self.all) == 1)
        }
    }

    @Test("Supported counts pass through, others round down to the next supported one")
    func roundsDown() {
        #expect(OffscreenRenderer.supportedSampleCount(2, supports: Self.all) == 2)
        #expect(OffscreenRenderer.supportedSampleCount(4, supports: Self.all) == 4)
        #expect(OffscreenRenderer.supportedSampleCount(8, supports: Self.all) == 8)
        #expect(OffscreenRenderer.supportedSampleCount(6, supports: Self.all) == 4)
        #expect(OffscreenRenderer.supportedSampleCount(32, supports: Self.all) == 8)
    }

    @Test("A count the device does not support falls back to a smaller one")
    func unsupportedFallsBack() {
        let noEight: (Int) -> Bool = { $0 != 8 }
        #expect(OffscreenRenderer.supportedSampleCount(8, supports: noEight) == 4)
        let none: (Int) -> Bool = { _ in false }
        #expect(OffscreenRenderer.supportedSampleCount(4, supports: none) == 1)
    }
}

@MainActor
@Suite("Offscreen MSAA sample count rendering")
struct OffscreenSampleCountRenderTests {

    // Camera at +Z (identity rotation) looking down -Z at the origin.
    private let camera = CameraState(
        rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1)),
        distance: 10,
        pivot: .zero
    )

    /// A flat white quad facing the camera, covering the centre of the frame.
    private func panel() -> ViewportBody {
        let z: Float = 3
        let half: Float = 3
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, z, 0, 0, 1] }
        let verts = v(-half, -half) + v(half, -half) + v(half, half) + v(-half, half)
        return ViewportBody(
            id: "panel", vertexData: verts, indices: [0, 1, 2, 0, 2, 3], edges: [],
            color: SIMD4<Float>(1, 1, 1, 1))
    }

    @Test(
        "Every sample count renders the panel, switching counts on one renderer",
        arguments: [1, 2, 4, 8, 4, 1])
    func rendersAtEachCount(sampleCount: Int) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        // Render at the default first, so the requested count is a switch on a warmed-up renderer.
        for count in [OffscreenRenderer.defaultSampleCount, sampleCount] {
            let options = OffscreenRenderOptions(
                width: 64, height: 64, cameraState: camera, displayMode: .unlit,
                backgroundColor: SIMD4<Float>(0, 0, 0, 1), appearance: .light, showGrid: false, showAxes: false,
                msaaSampleCount: count)
            let image = try #require(renderer.render(bodies: [panel()], options: options))
            let centre = centrePixelLuminance(image)
            #expect(
                centre > 200,
                "msaaSampleCount \(count): centre should be the white panel, got \(centre)")
        }
    }

    // MARK: - Helpers

    private func centrePixelLuminance(_ image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        buffer.withUnsafeMutableBytes { raw in
            if let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        let i = (height / 2) * bytesPerRow + (width / 2) * 4
        return max(Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]))
    }
}
