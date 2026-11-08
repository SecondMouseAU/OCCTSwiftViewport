// SkyboxDirectionTests.swift
// OCCTSwiftViewport Tests
//
// The skybox draws one oversized full-screen triangle and gives each fragment a world-space view
// ray. Normalising that ray at the three corners, before the rasteriser interpolates it, skewed
// every direction in between (interpolated unit vectors are not the unit vector toward the
// interpolated point): about 4 degrees at the centre of a square frame and about 20 at 2:1
// (issue #228). Looking at the frame centre of a square view along an axis, where the error is
// smallest, passed either way.
//
// These tests put a small bright marker in an asymmetric panorama at a known azimuth and
// elevation, render the sky at square, wide and tall aspect ratios from tilted cameras, and
// compare the marker on screen with the one a CPU ray cast through the same camera predicts.
// They run through both renderers, which share `skybox_vertex`.

import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

@MainActor
@Suite("Skybox view directions (#228)")
struct SkyboxDirectionTests {

    // MARK: - Panorama

    /// Equirectangular panorama size: about 1.4 degrees per pixel.
    nonisolated static let panoWidth = 256
    nonisolated static let panoHeight = 128
    /// Half the marker's side in panorama pixels: the marker is 5 x 5, about 7 degrees across.
    nonisolated static let markerRadius = 2

    /// A panorama pixel, named by the world direction it holds: azimuth (degrees from +X toward
    /// +Y) and elevation above the XY plane, snapped to its pixel.
    ///
    /// The panorama maps `u = 0.5 - azimuth / 360` and `v = 0.5 - elevation / 180`: +X is the
    /// image centre, +Y is `u = 0.25`, -Y is `u = 0.75`, and row 0 is straight up
    /// (`worldToEnvironment` and `equirect_to_cubemap`).
    struct Marker: CustomStringConvertible, Sendable {
        let column: Int
        let row: Int

        init(azimuth: Float, elevation: Float) {
            column = Int((0.5 - azimuth / 360) * Float(SkyboxDirectionTests.panoWidth))
            row = Int((0.5 - elevation / 180) * Float(SkyboxDirectionTests.panoHeight))
        }

        var description: String { "marker(col \(column), row \(row))" }
    }

    /// A dim panorama with one 5 x 5 pixel yellow HDR marker, in the raw `environmentMapData`
    /// layout (`Int32` width, `Int32` height, RGBA `Float` pixels).
    static func panorama(marker: Marker) -> Data {
        var pixels = [Float]()
        pixels.reserveCapacity(panoWidth * panoHeight * 4)
        for row in 0..<panoHeight {
            for column in 0..<panoWidth {
                let inMarker =
                    abs(column - marker.column) <= markerRadius
                    && abs(row - marker.row) <= markerRadius
                pixels += inMarker ? [10, 10, 0, 1] : [0.02, 0.02, 0.02, 1]
            }
        }
        var data = Data()
        withUnsafeBytes(of: Int32(panoWidth)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(panoHeight)) { data.append(contentsOf: $0) }
        pixels.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Lighting with the panorama drawn as the background and nothing else contributing.
    static func lighting(marker: Marker) -> LightingConfiguration {
        var lighting = ParityRender.plainLighting
        lighting.environmentMapData = panorama(marker: marker)
        lighting.drawBackground = true
        return lighting
    }

    // MARK: - Camera and expected marker

    /// A perspective camera looking along `azimuth` / `elevation` (degrees, as in `Marker`) with
    /// +Z up.
    static func camera(azimuth: Float, elevation: Float) -> CameraState {
        let a = azimuth * .pi / 180
        let e = elevation * .pi / 180
        let look = SIMD3(cos(e) * cos(a), cos(e) * sin(a), sin(e))
        return CameraState.lookAt(target: .zero, from: -10 * look, up: SIMD3(0, 0, 1))
    }

    /// The marker as the camera should see it, found by casting each pixel's ray on the CPU and
    /// looking it up in the panorama: the centroid (in pixels) and the number of pixels covered.
    ///
    /// A ray is `unproject(ndc, depth 1) - unproject(ndc, depth 0)` through the camera's own
    /// view-projection, in `Double`, so it shares no code with the shader. The marker covers the
    /// panorama pixels within `markerRadius` of its centre, plus `edge` of a pixel, because the
    /// bilinear lookups let a bright texel spill into its neighbours before the tone map clips
    /// it. Casting rays, rather than projecting the marker's centre, matters because a block of
    /// panorama pixels is not a symmetric blob on screen away from the equator.
    static func expectedMarker(
        _ marker: Marker, camera: CameraState, width: Int, height: Int, edge: Double = 0.6
    ) -> (centroid: SIMD2<Float>, count: Int) {
        let vp =
            camera.projectionMatrix(aspectRatio: Float(width) / Float(height), near: 0.1, far: 1000)
            * camera.viewMatrix
        let inverse = simd_inverse(vp)
        func unproject(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Double> {
            let p = inverse * SIMD4(x, y, z, 1)
            return SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) / Double(p.w)
        }
        let reach = Double(markerRadius) + 0.5 + edge
        var sum = SIMD2<Double>.zero
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let ndcX = (Float(x) + 0.5) / Float(width) * 2 - 1
                let ndcY = 1 - (Float(y) + 0.5) / Float(height) * 2
                let ray = unproject(ndcX, ndcY, 1) - unproject(ndcX, ndcY, 0)
                let d = ray / simd_length(ray)
                let u = 0.5 + atan2(-d.y, d.x) / (2 * .pi)
                let v = 0.5 - asin(max(-1, min(1, d.z))) / .pi
                var du = u * Double(panoWidth) - (Double(marker.column) + 0.5)
                du -= (du / Double(panoWidth)).rounded() * Double(panoWidth)  // across the seam
                let dv = v * Double(panoHeight) - (Double(marker.row) + 0.5)
                if abs(du) <= reach && abs(dv) <= reach {
                    sum += SIMD2(Double(x) + 0.5, Double(y) + 0.5)
                    count += 1
                }
            }
        }
        return (count > 0 ? SIMD2<Float>(sum / Double(count)) : .zero, count)
    }

    /// The centroid and size of the yellow marker in a BGRA8 frame.
    static func markerBlob(_ pixels: [UInt8], width: Int, height: Int)
        -> (centroid: SIMD2<Float>, count: Int)
    {
        var sum = SIMD2<Float>.zero
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let c = ParityRender.rgb(pixels, width: width, x: x, y: y)
                if c.x > 180 && c.y > 180 && c.z < 120 {
                    sum += SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                    count += 1
                }
            }
        }
        return (count > 0 ? sum / Float(count) : .zero, count)
    }

    /// Whether the marker is clear of the frame edge, so none of it is cropped.
    static func isWellInside(_ p: SIMD2<Float>, width: Int, height: Int) -> Bool {
        p.x > 16 && p.x < Float(width) - 16 && p.y > 16 && p.y < Float(height) - 16
    }

    /// Checks the rendered marker's centroid and size against the CPU-cast one.
    static func expectMarker(
        _ pixels: [UInt8], width: Int, height: Int,
        expected: (centroid: SIMD2<Float>, count: Int), view: ViewCase
    ) {
        let blob = markerBlob(pixels, width: width, height: height)
        let error = simd_length(blob.centroid - expected.centroid)
        #expect(blob.count > 30, "\(view): marker missing from the sky (\(blob.count) px)")
        #expect(
            error < tolerance,
            "\(view): marker centroid \(blob.centroid) is \(error) px from \(expected.centroid)")
        let ratio = Float(blob.count) / Float(max(expected.count, 1))
        #expect(
            ratio > 0.85 && ratio < 1.15,
            "\(view): marker covers \(blob.count) px, expected about \(expected.count)")
    }

    // MARK: - Cases

    /// One view: a frame size, a camera heading and where the marker sits.
    struct ViewCase: CustomStringConvertible, Sendable {
        let width: Int
        let height: Int
        let cameraAzimuth: Float
        let cameraElevation: Float
        let marker: Marker

        var description: String {
            "\(width)x\(height) camera az \(cameraAzimuth) el \(cameraElevation), \(marker)"
        }
    }

    /// Markers well off the frame centre, where the skew was largest, in square, wide (2:1) and
    /// tall (1:2) frames, from level and tilted cameras. The vertical field of view is 45 degrees,
    /// so the wide frame spans about 80 degrees across and the tall one about 23.
    nonisolated static let cases: [ViewCase] = [
        ViewCase(
            width: 256, height: 128, cameraAzimuth: 0, cameraElevation: 0,
            marker: Marker(azimuth: -25, elevation: 12)),
        ViewCase(
            width: 256, height: 128, cameraAzimuth: 0, cameraElevation: 0,
            marker: Marker(azimuth: 30, elevation: -10)),
        ViewCase(
            width: 128, height: 128, cameraAzimuth: 0, cameraElevation: 0,
            marker: Marker(azimuth: 14, elevation: 14)),
        ViewCase(
            width: 128, height: 256, cameraAzimuth: 0, cameraElevation: 0,
            marker: Marker(azimuth: -6, elevation: 15)),
        ViewCase(
            width: 256, height: 128, cameraAzimuth: 70, cameraElevation: 20,
            marker: Marker(azimuth: 92, elevation: 28)),
        ViewCase(
            width: 256, height: 128, cameraAzimuth: -160, cameraElevation: -30,
            marker: Marker(azimuth: -140, elevation: -38)),
    ]

    /// How far the marker's centroid may sit from the cast one, in pixels. The wide frame has
    /// about 3 pixels per degree, so this is about a degree; the skew was 4 to 20.
    nonisolated static let tolerance: Float = 2

    // MARK: - Tests

    @Test("OffscreenRenderer: the marker lands where its direction projects", arguments: cases)
    func offscreenMarkerPosition(_ view: ViewCase) throws {
        let camera = Self.camera(azimuth: view.cameraAzimuth, elevation: view.cameraElevation)
        let expected = Self.expectedMarker(
            view.marker, camera: camera, width: view.width, height: view.height)
        try #require(
            Self.isWellInside(expected.centroid, width: view.width, height: view.height),
            "\(view): the marker is not well inside the frame (\(expected.centroid))")

        let options = OffscreenRenderOptions(
            width: view.width, height: view.height, cameraState: camera, displayMode: .shaded,
            lightingConfiguration: Self.lighting(marker: view.marker),
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, enableSilhouettes: false)
        // Only the sky is under test; a hidden body gives the renderer a scene to draw.
        var hidden = ParityRender.quad(
            id: "hidden", x0: -1, y0: -1, x1: 1, y1: 1, color: SIMD4(0.5, 0.5, 0.5, 1))
        hidden.isVisible = false
        let (pixels, width, height) = try ParityRender.render([hidden], options)

        Self.expectMarker(pixels, width: width, height: height, expected: expected, view: view)
    }

    @Test("ViewportRenderer: the marker lands where its direction projects", arguments: cases)
    func liveMarkerPosition(_ view: ViewCase) throws {
        let camera = Self.camera(azimuth: view.cameraAzimuth, elevation: view.cameraElevation)
        let expected = Self.expectedMarker(
            view.marker, camera: camera, width: view.width, height: view.height)
        try #require(
            Self.isWellInside(expected.centroid, width: view.width, height: view.height),
            "\(view): the marker is not well inside the frame (\(expected.centroid))")

        let lighting = Self.lighting(marker: view.marker)
        let controller = ViewportController(
            configuration: ViewportConfiguration(
                initialCameraState: camera, displayMode: .shaded, lightingConfiguration: lighting,
                showAxes: false, showGrid: false, backgroundColor: SIMD4(0, 0, 0, 1),
                enableTAA: false))
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant([]))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        guard
            let pixels = renderer.renderHeadlessBGRA(
                width: view.width, height: view.height, backgroundColor: SIMD4(0, 0, 0, 1))
        else {
            Issue.record("live renderer returned no frame")
            return
        }

        Self.expectMarker(
            pixels, width: view.width, height: view.height, expected: expected, view: view)
    }

    // MARK: - Ray matrix conditioning

    @Test(
        "skyboxRayMatrix recovers each pixel's ray across a ten-million-to-one clip range",
        arguments: [false, true])
    func rayMatrixHoldsAtExtremeClipRanges(orthographic: Bool) {
        // The fitted clip planes of a frame can be this far apart, for example near 1e-3 and far
        // 1e7 around a huge model. A tilted camera, so no matrix entry is exactly zero.
        var camera = Self.camera(azimuth: -50, elevation: 35)
        camera.isOrthographic = orthographic
        let aspect: Float = 2
        let projection = camera.projectionMatrix(aspectRatio: aspect, near: 1e-3, far: 1e7)
        let matrix = RendererSharedSetup.skyboxRayMatrix(
            view: camera.viewMatrix, projection: projection)

        let tanHalf = tan(camera.fieldOfView * .pi / 360)
        for ndc in [SIMD2<Float>(0, 0), SIMD2(0.9, 0.7), SIMD2(-0.8, 0.6), SIMD2(3, -1), SIMD2(-1, 3)]
        {
            // What skybox_vertex computes, in Float as the shader does.
            func unproject(_ z: Float) -> SIMD3<Float> {
                let p = matrix * SIMD4(ndc.x, ndc.y, z, 1)
                return SIMD3(p.x, p.y, p.z) / p.w
            }
            let ray = simd_normalize(unproject(1) - unproject(0))
            let expected =
                orthographic
                ? camera.viewDirection
                : simd_normalize(
                    camera.viewDirection + camera.rightVector * (ndc.x * tanHalf * aspect)
                        + camera.upVector * (ndc.y * tanHalf))
            // The cross product's length is the angle for small ones; acos(dot) is too coarse.
            let angle = simd_length(simd_cross(ray, expected))
            #expect(
                angle < 1e-4,
                "ndc \(ndc): ray \(ray) is \(angle * 180 / .pi) degrees from \(expected)")
        }
    }
}
