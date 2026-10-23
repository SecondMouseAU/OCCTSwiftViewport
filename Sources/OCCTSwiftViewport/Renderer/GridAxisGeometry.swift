// GridAxisGeometry.swift
// OCCTSwiftViewport
//
// CPU-side geometry for the ground grid and the world axes, shared by ViewportRenderer and
// OffscreenRenderer (issue #136, M3 / M13).

@preconcurrency import Metal
import simd

/// Grid and axis settings, gathered from `ViewportConfiguration` or `OffscreenRenderOptions`.
///
/// Both renderers build one of these per frame and hand it to `RendererSharedSetup.encodeGrid` /
/// `encodeAxes`, so the live and headless paths read exactly the same fields. `axisLength` is
/// already resolved: an explicit length, or one derived from `sceneBounds` (see
/// `GridAxisGeometry.resolvedAxisLength`). So is `axisRadius` (see `resolvedAxisRadius`).
struct GridAxisSettings: Sendable, Equatable {
    var gridStyle: GridStyle
    var gridSize: Float
    var gridBaseSpacing: Float
    var gridSubdivisions: Int
    var axisLength: Float
    var axisRadius: Float
    var axisStyle: AxisStyle
    var gridColors: GridAxisGeometry.GridColors

    /// Settings for the live renderer.
    ///
    /// `sceneBounds` (the visible bodies' world bounds) sizes an automatic axis length;
    /// `background` (the colour the frame clears to) sets the grid colours.
    init(
        configuration: ViewportConfiguration,
        sceneBounds: BoundingBox? = nil,
        background: SIMD4<Float>? = nil
    ) {
        gridColors = GridAxisGeometry.GridColors(
            background: background ?? configuration.backgroundColor)
        gridStyle = configuration.gridStyle
        gridSize = configuration.gridSize
        gridBaseSpacing = configuration.gridBaseSpacing
        gridSubdivisions = configuration.gridSubdivisions
        axisLength = GridAxisGeometry.resolvedAxisLength(
            explicit: configuration.axisLength, sceneBounds: sceneBounds)
        axisRadius = GridAxisGeometry.resolvedAxisRadius(
            explicit: configuration.axisRadius, style: configuration.axisStyle,
            axisLength: axisLength)
        axisStyle = configuration.axisStyle
    }

    /// Settings for the headless renderer.
    ///
    /// `sceneBounds` (the rendered bodies' world bounds) sizes an automatic axis length;
    /// `background` (the colour the render clears to) sets the grid colours.
    init(
        options: OffscreenRenderOptions,
        sceneBounds: BoundingBox? = nil,
        background: SIMD4<Float>? = nil
    ) {
        gridColors = GridAxisGeometry.GridColors(background: background ?? options.backgroundColor)
        gridStyle = options.gridStyle
        gridSize = options.gridSize
        gridBaseSpacing = options.gridBaseSpacing
        gridSubdivisions = options.gridSubdivisions
        axisLength = GridAxisGeometry.resolvedAxisLength(
            explicit: options.axisLength, sceneBounds: sceneBounds)
        axisRadius = GridAxisGeometry.resolvedAxisRadius(
            explicit: options.axisRadius, style: options.axisStyle, axisLength: axisLength)
        axisStyle = options.axisStyle
    }
}

/// Pure geometry for the ground grid and the world axes.
///
/// The world is Z-up (the turntable orbits Z and `StandardView.top` looks down −Z), so the grid
/// lies in the XY plane. Vertices use the axis pipeline's interleaved layout: position (3 floats)
/// then RGBA colour (4 floats), stride 7.
enum GridAxisGeometry {

    /// Floats per vertex in the axis pipeline's layout (`float3` position + `float4` colour).
    static let floatsPerVertex = 7

    /// Height of the grid plane.
    ///
    /// A hair below z = 0, so faces lying on the ground plane win the depth test against the grid.
    static let gridPlaneZ: Float = -0.01

    /// Grid half-count, in spacings, for the `.dots` style (a 31 × 31 window around the pivot).
    static let dotHalfCount: Int32 = 15

    /// Grid half-count, in spacings, for the `.plane` style's lines.
    ///
    /// Wider than the dot window because lines that stop short read as a hard edge.
    static let lineHalfCount: Int32 = 50

    /// Grid colours derived from the background they are drawn over.
    ///
    /// Each colour is the background mixed toward an "ink" (black over a light background, white
    /// over a dark one), so the grid keeps the same modest contrast in light and dark appearance
    /// instead of fixed light-grey lines glaring on a dark background. Over the default light grey
    /// (0.95) this gives the former minor 0.78 / major 0.57 lines.
    struct GridColors: Equatable, Sendable {
        /// Ordinary `.plane` grid lines.
        var minorLine: SIMD4<Float>
        /// Every `gridSubdivisions`-th `.plane` line.
        var majorLine: SIMD4<Float>
        /// `.dots` grid dots.
        var dot: SIMD4<Float>

        init(background: SIMD4<Float>) {
            let rgb = SIMD3(background.x, background.y, background.z)
            let luminance = simd_dot(rgb, SIMD3(0.2126, 0.7152, 0.0722))
            let ink = SIMD3<Float>(repeating: luminance > 0.5 ? 0 : 1)
            func mixed(_ t: Float) -> SIMD4<Float> {
                SIMD4(simd_mix(rgb, ink, SIMD3(repeating: t)), 1)
            }
            minorLine = mixed(0.18)
            majorLine = mixed(0.4)
            dot = mixed(0.45)
        }
    }

    /// Translucent tint of the `.plane` style's ground fill.
    static let planeFillColor = SIMD4<Float>(0.5, 0.5, 0.5, 0.08)

    /// Segments around each axis cylinder.
    static let axisSegments = 16

    /// Visible view height of the default camera (distance 10, 45° FOV), in world units.
    ///
    /// `.constantScreenWidth` axes have exactly `axisRadius` at this view height.
    static let referenceVisibleHeight: Float = 2 * 10 * tan(Float.pi / 8)

    // MARK: - Grid window

    /// The rectangle of grid indices to draw, in multiples of `spacing` from the world origin.
    struct GridWindow: Equatable, Sendable {
        /// World-unit distance between neighbouring grid lines or dots.
        var spacing: Float

        /// Lowest (x, y) grid index drawn, inclusive.
        var minIndex: SIMD2<Int32>

        /// Highest (x, y) grid index drawn, inclusive.
        var maxIndex: SIMD2<Int32>

        /// Number of grid columns (indices along X).
        var columns: Int32 { maxIndex.x - minIndex.x + 1 }

        /// Number of grid rows (indices along Y).
        var rows: Int32 { maxIndex.y - minIndex.y + 1 }

        /// World position of the `minIndex` corner on the grid plane.
        var origin: SIMD3<Float> {
            SIMD3(Float(minIndex.x) * spacing, Float(minIndex.y) * spacing, gridPlaneZ)
        }

        /// World-space bounds of the window on the XY plane: (min, max).
        var bounds: (min: SIMD2<Float>, max: SIMD2<Float>) {
            (SIMD2<Float>(minIndex) * spacing, SIMD2<Float>(maxIndex) * spacing)
        }
    }

    /// Converts a float grid coordinate to an index, saturating instead of trapping.
    private static func gridIndex(_ value: Float) -> Int32 {
        guard value.isFinite else { return value > 0 ? Int32.max / 4 : -(Int32.max / 4) }
        let limit = Float(Int32.max / 4)
        return Int32(min(max(value, -limit), limit))
    }

    /// The grid window centred on the pivot and clipped to the configured grid extent.
    ///
    /// - Parameters:
    ///   - pivot: Camera pivot; the window centres on its XY projection, snapped to the spacing.
    ///   - spacing: Distance between grid lines or dots, in world units.
    ///   - halfCount: Window half-size, in spacings.
    ///   - gridSize: Side length of the square grid, centred on the world origin. Zero, negative
    ///     or non-finite leaves the grid unbounded (only the pivot window applies).
    /// - Returns: The window, or `nil` when it is empty (the pivot window lies wholly outside the
    ///   grid extent) or the spacing is unusable.
    static func gridWindow(
        pivot: SIMD3<Float>,
        spacing: Float,
        halfCount: Int32,
        gridSize: Float
    ) -> GridWindow? {
        guard spacing > 0, spacing.isFinite, halfCount >= 0 else { return nil }
        let centerX = gridIndex((pivot.x / spacing).rounded())
        let centerY = gridIndex((pivot.y / spacing).rounded())
        var minIndex = SIMD2<Int32>(centerX - halfCount, centerY - halfCount)
        var maxIndex = SIMD2<Int32>(centerX + halfCount, centerY + halfCount)

        if gridSize > 0, gridSize.isFinite {
            let extent = gridIndex((gridSize * 0.5 / spacing).rounded(.down))
            minIndex = simd_max(minIndex, SIMD2(repeating: -extent))
            maxIndex = simd_min(maxIndex, SIMD2(repeating: extent))
        }
        guard minIndex.x <= maxIndex.x, minIndex.y <= maxIndex.y else { return nil }
        return GridWindow(spacing: spacing, minIndex: minIndex, maxIndex: maxIndex)
    }

    // MARK: - Clip-range bounds

    /// `sceneBounds` grown to enclose the grid and axes that will be drawn this frame.
    ///
    /// The scene-adaptive near/far planes (issue #57) are fitted to the bodies alone, which
    /// near-clipped a grid that reaches past the scene toward the camera and far-clipped the axes.
    /// Feeding the overlays into the fit keeps them whole.
    static func clipBounds(
        sceneBounds: BoundingBox?,
        settings: GridAxisSettings,
        cameraState: CameraState,
        showGrid: Bool,
        showAxes: Bool
    ) -> BoundingBox? {
        var bounds = sceneBounds
        func include(_ box: BoundingBox) {
            bounds = bounds.map { $0.union(box) } ?? box
        }

        if showGrid {
            let spacing = RendererSharedSetup.adaptiveGridSpacing(
                cameraState: cameraState,
                baseSpacing: settings.gridBaseSpacing,
                subdivisions: settings.gridSubdivisions
            )
            let halfCount = settings.gridStyle == .dots ? dotHalfCount : lineHalfCount
            if let window = gridWindow(
                pivot: cameraState.pivot, spacing: spacing, halfCount: halfCount,
                gridSize: settings.gridSize)
            {
                // The window, not the whole `gridSize` square: the window scales with zoom, so a
                // large grid can't stretch `far` until its 1e-4 near floor clips a tiny model.
                // Padded by a spacing in Z: `clipPlanes` puts `near` exactly on the closest
                // point of the bounds, which for a camera looking straight down is the whole
                // (zero-thickness) grid plane, and would clip it away.
                let (lo, hi) = window.bounds
                include(
                    BoundingBox(
                        min: SIMD3(lo.x, lo.y, gridPlaneZ - spacing),
                        max: SIMD3(hi.x, hi.y, gridPlaneZ + spacing)))
            }
        }

        if showAxes, settings.axisLength > 0, settings.axisLength.isFinite {
            let radius = axisWorldRadius(
                style: settings.axisStyle, baseRadius: settings.axisRadius,
                cameraState: cameraState)
            include(
                BoundingBox(
                    min: SIMD3(repeating: -radius),
                    max: SIMD3(repeating: settings.axisLength + radius)))
        }
        return bounds
    }

    // MARK: - Grid geometry

    /// Line-list vertices for the `.plane` style's grid lines, on the XY plane.
    ///
    /// Every line whose absolute index is a multiple of `subdivisions` is a major line, so major
    /// lines sit exactly where the next-coarser spacing level's lines will be.
    static func gridLineVertices(
        window: GridWindow, subdivisions: Int, colors: GridColors
    ) -> [Float] {
        let major = Int32(max(subdivisions, 2))
        let (lo, hi) = window.bounds
        let z = gridPlaneZ
        var vertices: [Float] = []
        vertices.reserveCapacity(Int(window.columns + window.rows) * 2 * floatsPerVertex)

        func append(_ p: SIMD3<Float>, _ color: SIMD4<Float>) {
            vertices += [p.x, p.y, p.z, color.x, color.y, color.z, color.w]
        }

        for i in window.minIndex.x...window.maxIndex.x {
            let x = Float(i) * window.spacing
            let color = i % major == 0 ? colors.majorLine : colors.minorLine
            append(SIMD3(x, lo.y, z), color)
            append(SIMD3(x, hi.y, z), color)
        }
        for j in window.minIndex.y...window.maxIndex.y {
            let y = Float(j) * window.spacing
            let color = j % major == 0 ? colors.majorLine : colors.minorLine
            append(SIMD3(lo.x, y, z), color)
            append(SIMD3(hi.x, y, z), color)
        }
        return vertices
    }

    /// Triangle-list vertices for the `.plane` style's translucent ground fill.
    ///
    /// The fill spans the same window as the lines, so it ends at the outermost line.
    static func gridFillVertices(window: GridWindow) -> [Float] {
        let (lo, hi) = window.bounds
        let z = gridPlaneZ
        let c = planeFillColor
        let corners: [SIMD2<Float>] = [
            lo, SIMD2(hi.x, lo.y), hi,
            lo, hi, SIMD2(lo.x, hi.y),
        ]
        return corners.flatMap { [$0.x, $0.y, z, c.x, c.y, c.z, c.w] }
    }

    // MARK: - Axis geometry

    /// Automatic axis length when there is no scene to size it from.
    static let emptySceneAxisLength: Float = 2.0

    /// Automatic `.cylinder` radius as a fraction of the axis length (0.02 at the 2-unit length).
    static let automaticRadiusFraction: Float = 0.01

    /// Automatic `.constantScreenWidth` radius at the reference view height.
    static let automaticScreenWidthRadius: Float = 0.02

    /// The axis radius to draw: `explicit` when the app set one, otherwise automatic.
    ///
    /// Automatic `.cylinder` axes are `automaticRadiusFraction` of `axisLength` thick, so axes
    /// sized to a large scene stay proportionate instead of shrinking to the 1 px centre line.
    /// Automatic `.constantScreenWidth` axes use `automaticScreenWidthRadius`, since their width
    /// already follows the zoom.
    static func resolvedAxisRadius(explicit: Float?, style: AxisStyle, axisLength: Float) -> Float {
        if let explicit { return explicit }
        switch style {
        case .cylinder:
            let radius = automaticRadiusFraction * axisLength
            return radius.isFinite && radius > 0 ? radius : 0
        case .constantScreenWidth:
            return automaticScreenWidthRadius
        }
    }

    /// The axis length to draw: `explicit` when the app set one, otherwise sized to the scene.
    ///
    /// The automatic length is `max(1.5 × reach, 0.5 × diagonal)`, where `reach` is the largest
    /// absolute coordinate of `sceneBounds` on any axis. The axes start at the origin, so a length
    /// past `reach` is what makes them poke out of a model that contains the origin; the diagonal
    /// term keeps them visible beside a model that sits away from it. With no scene, or unusable
    /// bounds, it is `emptySceneAxisLength`.
    static func resolvedAxisLength(explicit: Float?, sceneBounds: BoundingBox?) -> Float {
        if let explicit { return explicit }
        guard let bounds = sceneBounds else { return emptySceneAxisLength }
        let reach = simd_reduce_max(simd_max(simd_abs(bounds.min), simd_abs(bounds.max)))
        let length = max(1.5 * reach, 0.5 * bounds.diagonalLength)
        guard length.isFinite, length > 0 else { return emptySceneAxisLength }
        return length
    }

    /// World-space radius of the axis cylinders for the current camera.
    ///
    /// `.cylinder` returns `baseRadius` unchanged. `.constantScreenWidth` scales it by the view's
    /// visible height at the pivot relative to `referenceVisibleHeight`, so the axes keep the
    /// on-screen width they would have from the default camera (distance 10, 45° FOV) at any zoom.
    static func axisWorldRadius(
        style: AxisStyle,
        baseRadius: Float,
        cameraState: CameraState
    ) -> Float {
        let radius = max(baseRadius, 0)
        switch style {
        case .cylinder:
            return radius
        case .constantScreenWidth:
            let visibleHeight: Float
            if cameraState.isOrthographic {
                visibleHeight = cameraState.orthographicScale
            } else {
                let halfFov = cameraState.fieldOfView * .pi / 360.0
                visibleHeight = 2 * cameraState.distance * tan(halfFov)
            }
            guard visibleHeight.isFinite, visibleHeight > 0 else { return radius }
            return radius * visibleHeight / referenceVisibleHeight
        }
    }

    /// Vertices per axis in `axisCylinderVertices()`: the side wall plus the far-end cap.
    static var verticesPerAxis: Int { axisSegments * 9 }

    /// Triangle-list vertices for three unit cylinders: X (red), Y (green), Z (blue).
    ///
    /// Each cylinder runs from 0 to 1 along its own axis with radius 1, so one static buffer
    /// serves every length and radius: `axisModelMatrix` scales it per draw. Axis `k`'s vertices
    /// start at `k * verticesPerAxis`.
    static func axisCylinderVertices() -> [Float] {
        let colors: [SIMD4<Float>] = [
            SIMD4(1, 0, 0, 1), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1),
        ]
        var vertices: [Float] = []
        vertices.reserveCapacity(3 * verticesPerAxis * floatsPerVertex)

        for axis in 0..<3 {
            let color = colors[axis]
            // (along, u, v) → world, with `along` on this axis and (u, v) on the other two.
            func point(_ along: Float, _ u: Float, _ v: Float) -> SIMD3<Float> {
                switch axis {
                case 0: return SIMD3(along, u, v)
                case 1: return SIMD3(v, along, u)
                default: return SIMD3(u, v, along)
                }
            }
            func append(_ p: SIMD3<Float>) {
                vertices += [p.x, p.y, p.z, color.x, color.y, color.z, color.w]
            }
            for s in 0..<axisSegments {
                let a0 = Float(s) / Float(axisSegments) * 2 * .pi
                let a1 = Float(s + 1) / Float(axisSegments) * 2 * .pi
                let (u0, v0, u1, v1) = (cos(a0), sin(a0), cos(a1), sin(a1))
                // Side wall: two triangles.
                append(point(0, u0, v0))
                append(point(1, u0, v0))
                append(point(1, u1, v1))
                append(point(0, u0, v0))
                append(point(1, u1, v1))
                append(point(0, u1, v1))
                // Far-end cap.
                append(point(1, 0, 0))
                append(point(1, u0, v0))
                append(point(1, u1, v1))
            }
        }
        return vertices
    }

    /// Scales unit cylinder `axis` (0 = X, 1 = Y, 2 = Z) to `length` along it and `radius` across.
    static func axisModelMatrix(axis: Int, length: Float, radius: Float) -> simd_float4x4 {
        var scale = SIMD3<Float>(repeating: radius)
        scale[axis] = length
        return simd_float4x4(diagonal: SIMD4(scale, 1))
    }

    /// Line-list vertices for the axes' 1 px centre lines, `length` long.
    ///
    /// Drawn alongside the cylinders so the axes never vanish when the radius is sub-pixel.
    static func axisCenterLineVertices(length: Float) -> [Float] {
        let ends: [(SIMD3<Float>, SIMD4<Float>)] = [
            (SIMD3(length, 0, 0), SIMD4(1, 0, 0, 1)),
            (SIMD3(0, length, 0), SIMD4(0, 1, 0, 1)),
            (SIMD3(0, 0, length), SIMD4(0, 0, 1, 1)),
        ]
        return ends.flatMap { end, c in
            [0, 0, 0, c.x, c.y, c.z, c.w, end.x, end.y, end.z, c.x, c.y, c.z, c.w]
        }
    }
}

/// GPU buffers for the grid and axes, owned one per renderer.
///
/// The axis cylinders are static. The `.plane` grid lines change only when the spacing level or
/// the pivot's snapped cell changes, so the buffer is cached on its window and rebuilt (never
/// mutated in place, so in-flight frames keep reading the old one) when that changes.
final class GridAxisBuffers {
    let device: MTLDevice

    /// Three unit cylinders; see `GridAxisGeometry.axisCylinderVertices()`.
    let axisCylinders: MTLBuffer

    private var lineKey:
        (
            window: GridAxisGeometry.GridWindow, subdivisions: Int,
            colors: GridAxisGeometry.GridColors
        )?
    private var lineBuffer: MTLBuffer?

    init?(device: MTLDevice) {
        let vertices = GridAxisGeometry.axisCylinderVertices()
        guard
            let buffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        else { return nil }
        self.device = device
        self.axisCylinders = buffer
    }

    /// The `.plane` grid-line buffer for `window`, rebuilt only when the window, subdivisions or
    /// colours change.
    func gridLines(
        window: GridAxisGeometry.GridWindow,
        subdivisions: Int,
        colors: GridAxisGeometry.GridColors
    ) -> (buffer: MTLBuffer, vertexCount: Int)? {
        let vertexCount = Int(window.columns + window.rows) * 2
        if let key = lineKey, key.window == window, key.subdivisions == subdivisions,
            key.colors == colors, let buffer = lineBuffer
        {
            return (buffer, vertexCount)
        }
        let vertices = GridAxisGeometry.gridLineVertices(
            window: window, subdivisions: subdivisions, colors: colors)
        guard
            let buffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        else { return nil }
        lineKey = (window, subdivisions, colors)
        lineBuffer = buffer
        return (buffer, vertexCount)
    }
}
