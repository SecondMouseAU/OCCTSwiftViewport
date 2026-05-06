// OffscreenRendererMeasurementTests.swift
// OCCTSwiftViewport Tests
//
// Headless measurement overlay — issue #26.

import Testing
import simd
import CoreGraphics
@testable import OCCTSwiftViewport

@MainActor
@Suite("OffscreenRenderer measurement overlay")
struct OffscreenRendererMeasurementTests {

    @Test("Empty measurements list leaves the image unchanged")
    func emptyMeasurementsIsBaseline() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let body = ViewportBody.box(id: "m-empty")
        let opts = OffscreenRenderOptions(width: 256, height: 192)
        guard let image = renderer.render(bodies: [body], options: opts) else {
            Issue.record("renderer returned nil image")
            return
        }
        #expect(image.width == 256)
        #expect(image.height == 192)
    }

    @Test("Distance measurement writes overlay pixels into the output image")
    func distanceOverlayChangesPixels() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let body = ViewportBody.box(id: "m-distance")

        // Anchors that sit comfortably inside the view frustum at the default
        // camera (distance 10, looking down -Z). Spans the front face of the box.
        let measurement: ViewportMeasurement = .distance(
            DistanceMeasurement(
                start: SIMD3<Float>(-0.5, -0.5, 0.5),
                end: SIMD3<Float>(0.5, 0.5, 0.5),
                label: "1.41"
            )
        )

        let baseOpts = OffscreenRenderOptions(width: 256, height: 192)
        var overlayOpts = baseOpts
        overlayOpts.measurements = [measurement]

        guard let baseImage = renderer.render(bodies: [body], options: baseOpts),
              let overlayImage = renderer.render(bodies: [body], options: overlayOpts) else {
            Issue.record("renderer returned nil image")
            return
        }

        #expect(overlayImage.width == baseImage.width)
        #expect(overlayImage.height == baseImage.height)
        #expect(pixelDifference(baseImage, overlayImage) > 0,
                "Overlay should change at least one pixel relative to the bare render")
    }

    @Test("Angle and radius measurements render without nil-out")
    func angleAndRadiusRender() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let body = ViewportBody.box(id: "m-mixed")
        let measurements: [ViewportMeasurement] = [
            .angle(AngleMeasurement(
                pointA: SIMD3<Float>(0.5, -0.5, 0.5),
                vertex: SIMD3<Float>(0, 0, 0.5),
                pointB: SIMD3<Float>(-0.5, 0.5, 0.5)
            )),
            .radius(RadiusMeasurement(
                center: SIMD3<Float>(0, 0, 0.5),
                edgePoint: SIMD3<Float>(0.4, 0, 0.5),
                showDiameter: true
            ))
        ]
        var opts = OffscreenRenderOptions(width: 256, height: 192)
        opts.measurements = measurements
        let image = renderer.render(bodies: [body], options: opts)
        #expect(image != nil)
    }

    // MARK: - Helpers

    /// Counts pixels that differ between two images. Assumes matching size and
    /// 32-bit BGRA layout (which is what `OffscreenRenderer` emits).
    private func pixelDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return Int.max }
        let width = a.width
        let height = a.height
        let bytesPerRow = width * 4
        let bufSize = bytesPerRow * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue
        )

        var bufA = [UInt8](repeating: 0, count: bufSize)
        var bufB = [UInt8](repeating: 0, count: bufSize)

        bufA.withUnsafeMutableBytes { rawA in
            if let ctx = CGContext(
                data: rawA.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        bufB.withUnsafeMutableBytes { rawB in
            if let ctx = CGContext(
                data: rawB.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: bitmapInfo.rawValue
            ) {
                ctx.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        var diffs = 0
        for i in stride(from: 0, to: bufSize, by: 4) {
            if bufA[i] != bufB[i] || bufA[i+1] != bufB[i+1] || bufA[i+2] != bufB[i+2] {
                diffs += 1
            }
        }
        return diffs
    }
}
