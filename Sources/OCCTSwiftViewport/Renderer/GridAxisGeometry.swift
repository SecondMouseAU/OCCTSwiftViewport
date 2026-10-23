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
/// `encodeAxes`, so the live and headless paths read exactly the same fields.
struct GridAxisSettings: Sendable, Equatable {
    var gridStyle: GridStyle
    var gridSize: Float
    var gridBaseSpacing: Float
    var gridSubdivisions: Int
    var axisLength: Float
    var axisRadius: Float
    var axisStyle: AxisStyle

    init(configuration: ViewportConfiguration) {
        gridStyle = configuration.gridStyle
        gridSize = configuration.gridSize
        gridBaseSpacing = configuration.gridBaseSpacing
        gridSubdivisions = configuration.gridSubdivisions
        axisLength = configuration.axisLength
        axisRadius = configuration.axisRadius
        axisStyle = configuration.axisStyle
    }

    init(options: OffscreenRenderOptions) {
        gridStyle = options.gridStyle
        gridSize = options.gridSize
        gridBaseSpacing = options.gridBaseSpacing
        gridSubdivisions = options.gridSubdivisions
        axisLength = options.axisLength
        axisRadius = options.axisRadius
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

    /// Dot colour for the `.dots` style.
    static let dotColor = SIMD4<Float>(0.6, 0.6, 0.6, 1.0)

    /// Colour of ordinary grid lines in the `.plane` style.
    static let minorLineColor = SIMD4<Float>(0.78, 0.78, 0.78, 1.0)

    /// Colour of every `gridSubdivisions`-th line in the `.plane` style.
    static let majorLineColor = SIMD4<Float>(0.58, 0.58, 0.58, 1.0)

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
    static func gridLineVertices(window: GridWindow, subdivisions: Int) -> [Float] {
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
            let color = i % major == 0 ? majorLineColor : minorLineColor
            append(SIMD3(x, lo.y, z), color)
            append(SIMD3(x, hi.y, z), color)
        }
        for j in window.minIndex.y...window.maxIndex.y {
            let y = Float(j) * window.spacing
            let color = j % major == 0 ? majorLineColor : minorLineColor
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

    private var lineKey: (window: GridAxisGeometry.GridWindow, subdivisions: Int)?
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

    /// The `.plane` grid-line buffer for `window`, rebuilt only when the window changes.
    func gridLines(
        window: GridAxisGeometry.GridWindow,
        subdivisions: Int
    ) -> (buffer: MTLBuffer, vertexCount: Int)? {
        let vertexCount = Int(window.columns + window.rows) * 2
        if let key = lineKey, key.window == window, key.subdivisions == subdivisions,
            let buffer = lineBuffer
        {
            return (buffer, vertexCount)
        }
        let vertices = GridAxisGeometry.gridLineVertices(
            window: window, subdivisions: subdivisions)
        guard
            let buffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
        else { return nil }
        lineKey = (window, subdivisions)
        lineBuffer = buffer
        return (buffer, vertexCount)
    }
}
