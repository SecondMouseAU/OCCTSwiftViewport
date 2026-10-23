// GridAxisConfigurationTests.swift
// OCCTSwiftViewport Tests
//
// Issue #136 (M3, M13, M5): the grid and axis fields of `ViewportConfiguration` /
// `OffscreenRenderOptions` reach both renderers, the grid lies in the Z-up world's XY plane,
// `defaultFieldOfView` drives the initial camera, and the configured background wins in dark mode.

import CoreGraphics
import SwiftUI
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Pure geometry

@Suite("Grid and axis geometry")
struct GridAxisGeometryTests {

    @Test("The grid window centres on the pivot's XY projection and ignores its height")
    func windowCentresOnPivotXY() throws {
        let window = try #require(
            GridAxisGeometry.gridWindow(
                pivot: SIMD3(3.4, -2.6, 50), spacing: 1, halfCount: 15, gridSize: 0))
        #expect(window.minIndex == SIMD2<Int32>(-12, -18))
        #expect(window.maxIndex == SIMD2<Int32>(18, 12))
        #expect(window.columns == 31 && window.rows == 31)
        // The grid is the XY plane (Z-up world), not XZ.
        #expect(window.origin == SIMD3(-12, -18, GridAxisGeometry.gridPlaneZ))
    }

    @Test("gridSize clips the window to a square around the origin")
    func gridSizeClipsWindow() throws {
        let window = try #require(
            GridAxisGeometry.gridWindow(pivot: .zero, spacing: 1, halfCount: 15, gridSize: 8))
        #expect(window.minIndex == SIMD2(-4, -4))
        #expect(window.maxIndex == SIMD2(4, 4))

        // A pivot far outside the square leaves nothing to draw.
        #expect(
            GridAxisGeometry.gridWindow(
                pivot: SIMD3(500, 0, 0), spacing: 1, halfCount: 15, gridSize: 8) == nil)

        // Non-positive / infinite sizes leave the grid unbounded.
        for size: Float in [0, -1, .infinity] {
            let open = try #require(
                GridAxisGeometry.gridWindow(
                    pivot: .zero, spacing: 1, halfCount: 15, gridSize: size))
            #expect(open.columns == 31)
        }
        // Unusable spacing never traps.
        #expect(
            GridAxisGeometry.gridWindow(pivot: .zero, spacing: 0, halfCount: 15, gridSize: 8)
                == nil)
        #expect(
            GridAxisGeometry.gridWindow(
                pivot: SIMD3(.nan, .infinity, 0), spacing: 1, halfCount: 15, gridSize: 0)
                != nil)
    }

    @Test("Plane grid lines lie flat in XY and mark every subdivisions-th line as major")
    func gridLinesAreFlatWithMajorLines() throws {
        let window = try #require(
            GridAxisGeometry.gridWindow(pivot: .zero, spacing: 1, halfCount: 12, gridSize: 0))
        let colors = GridAxisGeometry.GridColors(background: SIMD4(0.95, 0.95, 0.95, 1))
        let vertices = GridAxisGeometry.gridLineVertices(
            window: window, subdivisions: 10, colors: colors)
        let stride = GridAxisGeometry.floatsPerVertex
        #expect(vertices.count == Int(window.columns + window.rows) * 2 * stride)

        var majorXs: Set<Float> = []
        for v in Swift.stride(from: 0, to: vertices.count, by: stride) {
            #expect(vertices[v + 2] == GridAxisGeometry.gridPlaneZ)
            let color = SIMD4(vertices[v + 3], vertices[v + 4], vertices[v + 5], vertices[v + 6])
            // Lines along Y (first half) carry their index in x.
            if v < vertices.count / 2, color == colors.majorLine {
                majorXs.insert(vertices[v])
            }
        }
        #expect(majorXs == [-10, 0, 10])
    }

    @Test("Constant-screen-width axes scale with the view; cylinder axes do not")
    func axisRadiusByStyle() {
        let near = CameraState(distance: 10)
        let far = CameraState(distance: 40)
        #expect(
            GridAxisGeometry.axisWorldRadius(style: .cylinder, baseRadius: 0.02, cameraState: far)
                == 0.02)
        let atDefault = GridAxisGeometry.axisWorldRadius(
            style: .constantScreenWidth, baseRadius: 0.02, cameraState: near)
        let atFar = GridAxisGeometry.axisWorldRadius(
            style: .constantScreenWidth, baseRadius: 0.02, cameraState: far)
        #expect(abs(atDefault - 0.02) < 1e-6)
        #expect(abs(atFar - 0.08) < 1e-5)

        var ortho = CameraState(orthographicScale: 2 * GridAxisGeometry.referenceVisibleHeight)
        ortho.isOrthographic = true
        let orthoRadius = GridAxisGeometry.axisWorldRadius(
            style: .constantScreenWidth, baseRadius: 0.02, cameraState: ortho)
        #expect(abs(orthoRadius - 0.04) < 1e-6)
        #expect(
            GridAxisGeometry.axisWorldRadius(style: .cylinder, baseRadius: -1, cameraState: near)
                == 0)
    }

    @Test("Axis cylinders are unit-sized along their own axis and scale per draw")
    func axisCylinders() {
        let vertices = GridAxisGeometry.axisCylinderVertices()
        let stride = GridAxisGeometry.floatsPerVertex
        let perAxis = GridAxisGeometry.verticesPerAxis
        #expect(vertices.count == 3 * perAxis * stride)
        for axis in 0..<3 {
            var maxAlong: Float = 0
            var maxAcross: Float = 0
            for i in 0..<perAxis {
                let base = (axis * perAxis + i) * stride
                let p = SIMD3(vertices[base], vertices[base + 1], vertices[base + 2])
                maxAlong = max(maxAlong, p[axis])
                var across = p
                across[axis] = 0
                maxAcross = max(maxAcross, simd_length(across))
                #expect(vertices[base + 3 + axis] == 1)  // red / green / blue
            }
            #expect(abs(maxAlong - 1) < 1e-6)
            #expect(abs(maxAcross - 1) < 1e-5)
        }
        let model = GridAxisGeometry.axisModelMatrix(axis: 1, length: 5, radius: 0.1)
        let tip = model * SIMD4<Float>(1, 1, 1, 1)
        #expect(tip == SIMD4(0.1, 5, 0.1, 1))
    }

    @Test("Grid colours keep a modest contrast against light and dark backgrounds")
    func gridColorsFollowBackground() {
        let light = GridAxisGeometry.GridColors(background: SIMD4(0.95, 0.95, 0.95, 1))
        #expect(abs(light.minorLine.x - 0.779) < 0.001)
        #expect(light.majorLine.x < light.minorLine.x)

        let dark = GridAxisGeometry.GridColors(
            background: ViewportConfiguration.defaultDarkModeBackgroundColor)
        // Lighter than the background, but nowhere near the light theme's 0.78 glare.
        #expect(dark.minorLine.x > 0.12 && dark.minorLine.x < 0.35)
        #expect(dark.majorLine.x > dark.minorLine.x)
        #expect(dark.dot.w == 1)
    }

    @Test("Automatic axis length follows the scene; an explicit length wins")
    func axisLengthFollowsScene() {
        let model = BoundingBox(min: SIMD3(-10, -4, 0), max: SIMD3(6, 4, 3))
        #expect(GridAxisGeometry.resolvedAxisLength(explicit: 3, sceneBounds: model) == 3)
        #expect(
            GridAxisGeometry.resolvedAxisLength(explicit: nil, sceneBounds: nil)
                == GridAxisGeometry.emptySceneAxisLength)
        #expect(
            abs(GridAxisGeometry.resolvedAxisLength(explicit: nil, sceneBounds: model) - 15) < 1e-4)

        // A model away from the origin: the diagonal term keeps the axes a visible size.
        let offset = BoundingBox(min: SIMD3(100, 100, 0), max: SIMD3(101, 101, 1))
        let length = GridAxisGeometry.resolvedAxisLength(explicit: nil, sceneBounds: offset)
        #expect(abs(length - 151.5) < 1e-3)

        // Degenerate bounds fall back instead of yielding zero or NaN.
        let point = BoundingBox(min: .zero, max: .zero)
        #expect(
            GridAxisGeometry.resolvedAxisLength(explicit: nil, sceneBounds: point)
                == GridAxisGeometry.emptySceneAxisLength)

        // Offscreen and onscreen settings resolve the same way.
        let fromOptions = GridAxisSettings(options: OffscreenRenderOptions(), sceneBounds: model)
        let fromConfig = GridAxisSettings(
            configuration: ViewportConfiguration(), sceneBounds: model)
        #expect(fromOptions.axisLength == fromConfig.axisLength)
    }

    @Test("Clip-range bounds take in the drawn grid and axes")
    func clipBoundsIncludeOverlays() throws {
        let camera = CameraState(distance: 10)
        var settings = GridAxisSettings(configuration: ViewportConfiguration())
        settings.axisLength = 50
        let scene = BoundingBox(min: SIMD3(repeating: -1), max: SIMD3(repeating: 1))

        let none = GridAxisGeometry.clipBounds(
            sceneBounds: scene, settings: settings, cameraState: camera,
            showGrid: false, showAxes: false)
        #expect(none == scene)

        let axes = try #require(
            GridAxisGeometry.clipBounds(
                sceneBounds: scene, settings: settings, cameraState: camera,
                showGrid: false, showAxes: true))
        #expect(axes.max.x >= 50 && axes.max.y >= 50 && axes.max.z >= 50)

        let grid = try #require(
            GridAxisGeometry.clipBounds(
                sceneBounds: nil, settings: settings, cameraState: camera,
                showGrid: true, showAxes: false))
        #expect(
            grid.min.z < GridAxisGeometry.gridPlaneZ && grid.max.z > GridAxisGeometry.gridPlaneZ)
        #expect(grid.max.x > 1 && grid.min.y < -1)

        // A tiny model under a large grid still clears the near plane.
        let tiny = BoundingBox(min: SIMD3(repeating: -0.001), max: SIMD3(repeating: 0.001))
        let close = CameraState(distance: 0.01)
        let fitted = GridAxisGeometry.clipBounds(
            sceneBounds: tiny,
            settings: GridAxisSettings(configuration: ViewportConfiguration()),
            cameraState: close, showGrid: true, showAxes: false)
        let clip = close.clipPlanes(sceneBounds: fitted)
        #expect(clip.near <= close.clipPlanes(sceneBounds: tiny).near + 1e-6)

        // Looking straight down at the bare grid, `near` stays in front of the plane.
        let topDown = try #require(
            GridAxisGeometry.clipBounds(
                sceneBounds: nil, settings: settings, cameraState: camera,
                showGrid: true, showAxes: false))
        #expect(camera.clipPlanes(sceneBounds: topDown).near < camera.distance - 0.1)
    }
}

// MARK: - Configuration wiring

@MainActor
@Suite("Grid, axis and camera configuration wiring")
struct GridAxisConfigurationWiringTests {

    @Test("defaultFieldOfView sets the initial camera's field of view")
    func defaultFieldOfViewDrivesInitialCamera() {
        let controller = ViewportController(
            configuration: ViewportConfiguration(defaultFieldOfView: 30))
        #expect(controller.cameraState.fieldOfView == 30)
        #expect(controller.cameraController.cameraState.fieldOfView == 30)

        controller.reset(animated: false)
        #expect(controller.cameraController.cameraState.fieldOfView == 30)
    }

    @Test("An initial camera's own field of view survives when defaultFieldOfView is unset")
    func initialCameraFieldOfViewKept() {
        var camera = CameraState.isometric
        camera.fieldOfView = 60
        let configuration = ViewportConfiguration(initialCameraState: camera)
        #expect(configuration.defaultFieldOfView == nil)
        let controller = ViewportController(configuration: configuration)
        #expect(controller.cameraState.fieldOfView == 60)
        controller.reset(animated: false)
        #expect(controller.cameraController.cameraState.fieldOfView == 60)

        // Assigning the camera after init (a common pattern) keeps its FOV too.
        var later = ViewportConfiguration()
        later.initialCameraState = camera
        #expect(later.effectiveInitialCameraState.fieldOfView == 60)

        var mutated = ViewportConfiguration()
        mutated.defaultFieldOfView = 25
        #expect(mutated.effectiveInitialCameraState.fieldOfView == 25)
    }

    @Test("The configured background wins in dark mode unless a dark colour is set")
    func backgroundColorWinsInDarkMode() {
        let custom = SIMD4<Float>(0.2, 0.4, 0.6, 1)
        let defaultDark = ViewportConfiguration.defaultDarkModeBackgroundColor
        #expect(defaultDark == SIMD4<Float>(0.12, 0.12, 0.12, 1))

        // Following dark mode is on by default.
        let plain = ViewportConfiguration(backgroundColor: custom)
        #expect(plain.darkModeBackgroundColor == defaultDark)
        #expect(plain.resolvedBackgroundColor(isDark: true) == defaultDark)
        #expect(plain.resolvedBackgroundColor(isDark: false) == custom)

        // A custom dark colour.
        let navy = SIMD4<Float>(0.05, 0.05, 0.2, 1)
        let withDark = ViewportConfiguration(
            backgroundColor: custom, darkModeBackgroundColor: navy)
        #expect(withDark.resolvedBackgroundColor(isDark: true) == navy)
        #expect(withDark.resolvedBackgroundColor(isDark: false) == custom)

        // Opting out: the configured colour wins in both appearances.
        let optOut = ViewportConfiguration(backgroundColor: custom, darkModeBackgroundColor: nil)
        #expect(optOut.resolvedBackgroundColor(isDark: true) == custom)
    }

    @Test("Offscreen renders pick light or dark backgrounds from their appearance")
    func offscreenAppearance() {
        let custom = SIMD4<Float>(0.2, 0.4, 0.6, 1)
        var options = OffscreenRenderOptions(backgroundColor: custom)
        #expect(options.appearance == .light)
        #expect(options.resolvedBackgroundColor == custom)
        options.appearance = .dark
        #expect(
            options.resolvedBackgroundColor == ViewportConfiguration.defaultDarkModeBackgroundColor)
        options.darkModeBackgroundColor = nil
        #expect(options.resolvedBackgroundColor == custom)
        #expect(
            OffscreenRenderOptions().darkModeBackgroundColor
                == ViewportConfiguration().darkModeBackgroundColor)
    }

    @Test("groundPlane cuts at Z = 0 in the Z-up world; yPlane keeps the old Y = 0 cut")
    func groundPlaneIsZUp() {
        #expect(ClipPlane.groundPlane.normal == SIMD3(0, 0, 1))
        #expect(ClipPlane.groundPlane.distance == 0)
        #expect(ClipPlane.yPlane.normal == SIMD3(0, 1, 0))
    }

    @Test("OffscreenRenderOptions defaults match ViewportConfiguration's grid and axis defaults")
    func offscreenDefaultsMatch() {
        let options = OffscreenRenderOptions()
        let configuration = ViewportConfiguration()
        var fromConfig = GridAxisSettings(configuration: configuration)
        fromConfig.gridBaseSpacing = options.gridBaseSpacing
        fromConfig.gridSubdivisions = options.gridSubdivisions
        #expect(GridAxisSettings(options: options) == fromConfig)
    }
}

// MARK: - Rendering

/// Headless pixel checks against both renderers, from a top-down camera.
///
/// `StandardView.top` (identity rotation) looks down −Z with +X right and +Y up, so a grid in
/// the XY plane faces the camera, while the old XZ grid was seen edge-on as a single row.
@MainActor
@Suite("Grid and axis rendering")
struct GridAxisRenderingTests {

    static let size = 128
    static let black = SIMD4<Float>(0, 0, 0, 1)

    private var topCamera: CameraState { CameraState(distance: 10) }

    private func offscreen(
        _ options: OffscreenRenderOptions, bodies: [ViewportBody] = []
    ) -> [UInt8]? {
        guard let renderer = OffscreenRenderer(),
            let image = renderer.render(bodies: bodies, options: options)
        else { return nil }
        return Self.readBGRA(image)
    }

    private func baseOptions() -> OffscreenRenderOptions {
        OffscreenRenderOptions(
            width: Self.size, height: Self.size, cameraState: topCamera,
            backgroundColor: Self.black)
    }

    private func live(
        _ configuration: ViewportConfiguration, bodies: [ViewportBody] = []
    ) -> [UInt8]? {
        let controller = ViewportController(configuration: configuration)
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else { return nil }
        return renderer.renderHeadlessBGRA(
            width: Self.size, height: Self.size, backgroundColor: Self.black, frameCount: 2)
    }

    // MARK: Pixel helpers

    static func readBGRA(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let info =
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    /// (x, y) of every pixel matching `predicate(r, g, b)`.
    static func pixels(_ bgra: [UInt8], where predicate: (Int, Int, Int) -> Bool) -> [(Int, Int)] {
        var hits: [(Int, Int)] = []
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                if predicate(Int(bgra[i + 2]), Int(bgra[i + 1]), Int(bgra[i])) {
                    hits.append((x, y))
                }
            }
        }
        return hits
    }

    /// Grey grid pixels (lines or dots) clearly above the black background and the faint fill.
    static func gridPixels(_ bgra: [UInt8]) -> [(Int, Int)] {
        pixels(bgra) { r, g, b in r > 25 && abs(r - g) < 20 && abs(g - b) < 20 }
    }

    static func redPixels(_ bgra: [UInt8]) -> [(Int, Int)] {
        pixels(bgra) { r, g, b in r > 120 && g < 80 && b < 80 }
    }

    // MARK: Tests

    @Test("The grid lies in the XY plane: a top view sees it face-on (offscreen)")
    func gridFacesTopViewOffscreen() throws {
        var options = baseOptions()
        options.showGrid = true
        let bgra = try #require(offscreen(options))
        let rows = Set(Self.gridPixels(bgra).map(\.1))
        #expect(rows.count > Self.size / 2, "grid seen edge-on: only \(rows.count) rows lit")
    }

    @Test("The grid lies in the XY plane: a top view sees it face-on (live renderer)")
    func gridFacesTopViewLive() throws {
        let bgra = try #require(
            live(ViewportConfiguration(initialCameraState: topCamera, showGrid: true)))
        let rows = Set(Self.gridPixels(bgra).map(\.1))
        #expect(rows.count > Self.size / 2, "grid seen edge-on: only \(rows.count) rows lit")
    }

    @Test("Default axes grow past a large model; an explicit length stays inside it")
    func defaultAxesScaleToScene() throws {
        // A 10 x 10 x 1 slab centred on the origin hides the X axis from a top view at distance 30
        // unless the axis pokes out past x = 5. Auto length is 7.5; an explicit 2 stays hidden.
        let slab = ViewportBody.box(
            id: "slab", width: 10, height: 10, depth: 1, color: SIMD4(0.2, 0.2, 0.8, 1))
        let camera = CameraState(distance: 30)
        func red(explicit: Float?, live useLive: Bool) throws -> Int {
            if useLive {
                let config = ViewportConfiguration(
                    initialCameraState: camera, displayMode: .unlit, showAxes: true,
                    axisLength: explicit, showGrid: false)
                return Self.redPixels(try #require(live(config, bodies: [slab]))).count
            }
            var options = baseOptions()
            options.cameraState = camera
            options.displayMode = .unlit
            options.showAxes = true
            options.axisLength = explicit
            return Self.redPixels(try #require(offscreen(options, bodies: [slab]))).count
        }
        for useLive in [false, true] {
            #expect(try red(explicit: nil, live: useLive) > 0, "live=\(useLive): auto axes hidden")
            #expect(try red(explicit: 2, live: useLive) == 0, "live=\(useLive): explicit 2 visible")
        }
    }

    @Test("Offscreen .dark renders the dark background, .light the light one")
    func offscreenDarkBackground() throws {
        var options = OffscreenRenderOptions(
            width: 16, height: 16, cameraState: topCamera,
            backgroundColor: SIMD4(0.95, 0.95, 0.95, 1))
        let light = try #require(offscreen(options))
        options.appearance = .dark
        let dark = try #require(offscreen(options))
        // BGRA: check the red channel of the first pixel.
        #expect(light[2] > 200, "light background \(light[2])")
        #expect(dark[2] < 60, "dark background \(dark[2])")
    }

    @Test("The default axes stop at axisLength instead of running off-screen")
    func defaultAxesStopAtAxisLength() throws {
        // Visible half-height at distance 10 / 45° is ~4.14 units = 64 px, so 2 units ≈ 31 px.
        var options = baseOptions()
        options.showAxes = true
        let offscreenRed = Self.redPixels(try #require(offscreen(options)))
        let liveRed = Self.redPixels(
            try #require(
                live(
                    ViewportConfiguration(
                        initialCameraState: topCamera, showAxes: true,
                        showGrid: false))))
        for (name, red) in [("offscreen", offscreenRed), ("live", liveRed)] {
            let maxX = red.map(\.0).max() ?? 0
            #expect(maxX > 85 && maxX < 105, "\(name): X axis ends at x = \(maxX)")
        }
    }

    @Test("axisLength, gridStyle and gridSize reach the offscreen renderer")
    func offscreenHonoursAxisLengthAndGridSize() throws {
        var options = baseOptions()
        options.showAxes = true
        options.axisLength = 3
        let maxX = Self.redPixels(try #require(offscreen(options))).map(\.0).max() ?? 0
        #expect(maxX > 100 && maxX < 120, "3-unit X axis ends at x = \(maxX)")

        // A 4-unit grid spans ±2 units ≈ ±31 px around the centre.
        var grid = baseOptions()
        grid.showGrid = true
        grid.gridSize = 4
        for style in [GridStyle.plane, .dots] {
            grid.gridStyle = style
            let lit = Self.gridPixels(try #require(offscreen(grid)))
            #expect(!lit.isEmpty, "\(style): nothing drawn")
            let xs = lit.map(\.0)
            #expect(
                (xs.min() ?? 0) > 25 && (xs.max() ?? 0) < 103,
                "\(style): grid spills outside gridSize: x in \(xs.min() ?? -1)...\(xs.max() ?? -1)"
            )
        }
    }

    @Test("Constant-screen-width axes keep their pixel width as the camera zooms out")
    func constantScreenWidthAxes() throws {
        func redThickness(style: AxisStyle, distance: Float, live useLive: Bool) throws -> Int {
            let camera = CameraState(distance: distance)
            let bgra: [UInt8]
            if useLive {
                bgra = try #require(
                    live(
                        ViewportConfiguration(
                            initialCameraState: camera, showAxes: true, axisLength: 8,
                            axisRadius: 0.2, axisStyle: style, showGrid: false)))
            } else {
                var options = baseOptions()
                options.cameraState = camera
                options.showAxes = true
                options.axisLength = 8
                options.axisRadius = 0.2
                options.axisStyle = style
                bgra = try #require(offscreen(options))
            }
            // Red pixels in one column right of the origin, crossing the X axis.
            return Self.redPixels(bgra).filter { $0.0 == Self.size / 2 + 20 }.count
        }
        for useLive in [false, true] {
            let near = try redThickness(style: .constantScreenWidth, distance: 10, live: useLive)
            let far = try redThickness(style: .constantScreenWidth, distance: 40, live: useLive)
            let cylinderFar = try redThickness(style: .cylinder, distance: 40, live: useLive)
            #expect(near >= 5, "live=\(useLive): axis only \(near) px wide")
            #expect(abs(near - far) <= 1, "live=\(useLive): \(near) px vs \(far) px")
            #expect(cylinderFar < far, "live=\(useLive): cylinder axes should thin with zoom")
        }
    }
}
