// GeometryDepthShaderTests.swift
// OCCTSwiftViewport Tests
//
// Geometry and depth shader fixes found by the #136 audit follow-ups:
//
// - #193: the native edge depth bias is in pixels of the drawable, not a fixed fraction of NDC, so
//   a native edge on a steep face still beats the face on a small drawable, drawn and picked.
// - #213: normals go through the inverse transpose of the model matrix, so lighting is right
//   under non-uniform scale (shaded, direct-mesh, tessellated and mesh-shader surfaces).
//
// Each test renders a small deterministic scene headlessly and reads pixels or pick results.

import CoreGraphics
import Foundation
import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Helpers

@MainActor
enum DepthShaderRender {

    struct Unavailable: Error {}

    /// A live renderer around `bodies`, with the grid, axes and TAA off.
    ///
    /// The renderer holds its controller weakly, so keep both for as long as it is used.
    static func makeLive(
        bodies: [ViewportBody],
        camera: CameraState,
        displayMode: DisplayMode = .shaded,
        edge: EdgeLineConfiguration = .default,
        lighting: LightingConfiguration = .flat,
        quality: RenderingQuality = .standard
    ) throws -> (controller: ViewportController, renderer: ViewportRenderer) {
        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.edgeLineConfiguration = edge
        config.lightingConfiguration = lighting
        config.renderingQuality = quality
        config.backgroundColor = SIMD4(1, 1, 1, 1)
        config.showViewCube = false
        config.pickingConfiguration = PickingConfiguration(isEnabled: true)
        let controller = ViewportController(configuration: config)
        controller.displayMode = displayMode
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        guard let renderer = ViewportRenderer(controller: controller, bodies: .constant(bodies))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw Unavailable()
        }
        return (controller, renderer)
    }

    /// One frame of `renderer` at `width` x `height` on a white background (BGRA8, row-major).
    static func render(_ renderer: ViewportRenderer, width: Int, height: Int) throws -> [UInt8] {
        guard
            let pixels = renderer.renderHeadlessBGRA(
                width: width, height: height, backgroundColor: SIMD4(1, 1, 1, 1))
        else {
            Issue.record("headless render returned nil")
            throw Unavailable()
        }
        return pixels
    }

    /// Brightest colour channel of the pixel at `(x, y)`.
    static func brightness(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> Int {
        let i = (y * width + x) * 4
        return Int(max(pixels[i], pixels[i + 1], pixels[i + 2]))
    }
}

// MARK: - #193 native edge depth bias in pixels

@MainActor
@Suite("Native edge depth bias follows the drawable size (#193)")
struct NativeEdgeBiasPixelTests {

    /// A white face tilted away from a perspective camera (its depth changes steeply down the
    /// screen), with a native edge lying on it, slightly slanted so it crosses rows.
    static func tiltedPlane() -> ViewportBody {
        func v(_ x: Float, _ y: Float) -> [Float] { [x, y, 0, 0, 0, 1] }
        var plane = ViewportBody(
            id: "plane", vertexData: v(-7, -9) + v(13, -5) + v(9, 11) + v(-11, 6),
            indices: [0, 1, 2, 0, 2, 3], edges: [[SIMD3(-3, 0.1, 0), SIMD3(3, -0.1, 0)]],
            color: SIMD4<Float>(1, 1, 1, 1))
        plane.edgeIndices = [0]
        return plane
    }

    static let camera = CameraState(
        rotation: simd_quatf(angle: 1.1, axis: SIMD3<Float>(1, 0, 0)),
        distance: 30, pivot: .zero, fieldOfView: 30)

    static let nativeEdges = EdgeLineConfiguration(useQuadExpansion: false)

    @Test(
        "A drawn native edge on a steep face is not eaten by the face on a small drawable",
        arguments: [64, 96, 128, 256, 512])
    func drawnEdgeBeatsFace(size: Int) throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping headless render test")
            return
        }
        let options = OffscreenRenderOptions(
            width: size, height: size, cameraState: Self.camera, displayMode: .shadedWithEdges,
            lightingConfiguration: .flat, backgroundColor: SIMD4<Float>(1, 1, 1, 1),
            appearance: .light, showGrid: false, showAxes: false, msaaSampleCount: 1,
            edgeLineConfiguration: Self.nativeEdges)
        guard let image = renderer.render(bodies: [Self.tiltedPlane()], options: options) else {
            Issue.record("renderer returned nil image")
            return
        }
        let pixels = ParityRender.bgra(image).0
        // The face is lit evenly, so a clearly darker pixel at the edge's row is the edge. The
        // edge runs along the middle of the frame (the pivot is at the origin), about 37% of the
        // frame wide; check its middle 30%.
        let face = DepthShaderRender.brightness(pixels, width: size, x: size / 2, y: size * 3 / 4)
        #expect(face > 100 && face < 255, "the face should be lit, got \(face)")
        let threshold = face * 6 / 10
        let rows = (size / 2 - 3)...(size / 2 + 3)
        let columns = (size * 35 / 100)...(size * 65 / 100)
        let missing = columns.filter { x in
            !rows.contains { y in
                DepthShaderRender.brightness(pixels, width: size, x: x, y: y) < threshold
            }
        }
        #expect(
            missing.isEmpty,
            "the face won the edge in \(missing.count) of \(columns.count) columns at \(size) px")
    }

    @Test(
        "A native edge on a steep face still picks as the edge on a small drawable",
        arguments: [64, 96, 128, 256, 512])
    func pickedEdgeBeatsFace(size: Int) async throws {
        let live = try DepthShaderRender.makeLive(
            bodies: [Self.tiltedPlane()], camera: Self.camera, displayMode: .shadedWithEdges,
            edge: Self.nativeEdges)
        _ = try DepthShaderRender.render(live.renderer, width: size, height: size)

        // For each column, does any pixel in a band round the centre row pick as the edge?
        var edgeColumns: [Int] = []
        for x in 0..<size {
            let rect = CGRect(x: x, y: size / 2 - 8, width: 1, height: 16)
            let kinds: Set<PrimitiveKind> = await withCheckedContinuation { continuation in
                live.renderer.performRegionPick(rect: rect) {
                    continuation.resume(returning: Set($0.map(\.kind)))
                }
            }
            if kinds.contains(.edge) { edgeColumns.append(x) }
        }
        let span = (edgeColumns.last ?? 0) - (edgeColumns.first ?? 0) + 1
        #expect(span > size / 4, "the edge picked across only \(span) columns")
        #expect(
            edgeColumns.count == span,
            "the face won \(span - edgeColumns.count) of the edge's \(span) columns at \(size) px")
    }
}

// MARK: - #213 normal matrix

@MainActor
@Suite("Normals use the inverse transpose of the model matrix (#213)")
struct NormalMatrixTests {

    // MARK: Normal matrix maths

    static func linear(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// `normal` transformed by the true inverse transpose of `m`, normalised.
    static func referenceNormal(_ normal: SIMD3<Float>, _ m: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(simd_transpose(simd_inverse(linear(m))) * normal)
    }

    static func scale(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(x, y, z, 1))
    }

    /// A rotation about Z after a non-uniform scale: tilts normals under the model matrix alone.
    static let skewed: simd_float4x4 =
        simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 0, 1))) * scale(2.5, 0.8, 1.0)

    @Test("The normal matrix is the inverse transpose, up to a positive scale")
    func matchesInverseTranspose() {
        var moved = Self.skewed
        moved.columns.3 = SIMD4(5, -2, 7, 1)
        let transforms: [simd_float4x4] = [
            matrix_identity_float4x4,
            simd_float4x4(simd_quatf(angle: 1.1, axis: simd_normalize(SIMD3(1, 2, 3)))),
            Self.scale(3, 3, 3),
            Self.scale(2, 0.5, 1),
            Self.skewed,
            Self.scale(-1, 1, 1),  // mirrored: negative determinant
            Self.scale(1e-3, 2, 1e3),
            moved,
        ]
        let normals: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), simd_normalize(SIMD3(1, 1, 0)), simd_normalize(SIMD3(1, 2, 3)),
            SIMD3(0, 0, -1),
        ]
        for transform in transforms {
            let matrix = Uniforms.normalMatrix(forModel: transform)
            for normal in normals {
                let got = simd_normalize(matrix * normal)
                let want = Self.referenceNormal(normal, transform)
                #expect(
                    simd_distance(got, want) < 1e-4,
                    "normal \(normal) under \(transform): got \(got), want \(want)")
            }
        }
        // A rotation stays that rotation.
        let rotation = simd_float4x4(simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0)))
        let n = Uniforms.normalMatrix(forModel: rotation)
        #expect(simd_distance(n.columns.0, Self.linear(rotation).columns.0) < 1e-5)
        #expect(
            Uniforms.normalMatrix(forModel: matrix_identity_float4x4) == matrix_identity_float3x3)
    }

    @Test("A flattened or non-finite transform still gives a usable normal matrix")
    func degenerateTransforms() {
        // Squashed flat along Z: the plane's normal survives.
        let flat = Uniforms.normalMatrix(forModel: Self.scale(2, 3, 0))
        #expect(simd_distance(simd_normalize(flat * SIMD3(0, 0, 1)), SIMD3(0, 0, 1)) < 1e-5)
        // Nothing to invert: the identity, never NaN.
        #expect(Uniforms.normalMatrix(forModel: Self.scale(0, 0, 0)) == matrix_identity_float3x3)
        #expect(
            Uniforms.normalMatrix(forModel: Self.scale(.nan, 1, 1)) == matrix_identity_float3x3)
    }

    @Test("Setting a model matrix refreshes the uniforms' normal matrix")
    func uniformsTrackModelMatrix() {
        var uniforms = Uniforms(
            viewProjection: matrix_identity_float4x4, viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero, nearPlane: 0.1, farPlane: 100, lighting: .threePoint,
            lightViewProjection: matrix_identity_float4x4, shadowParams: .zero,
            shadowParams2: .zero, unlit: false, viewportSize: SIMD2(200, 100))
        #expect(uniforms.normalMatrix == matrix_identity_float3x3)
        #expect(uniforms.viewportParams == SIMD4(200, 100, 0, 0))
        uniforms.modelMatrix = Self.skewed
        #expect(uniforms.normalMatrix == Uniforms.normalMatrix(forModel: Self.skewed))
        uniforms.modelMatrix = matrix_identity_float4x4
        #expect(uniforms.normalMatrix == matrix_identity_float3x3)
    }

    @Test("The Swift Uniforms layout matches the Metal struct's viewport and normal fields")
    func uniformsLayout() {
        // Metal: ..., toneMapWhitePoint (float), float4 viewportParams, float3x3 normalMatrix,
        // then the ambient / procedural-environment / tint fields (LightingTintsAndIBLTests).
        let viewport = MemoryLayout<Uniforms>.offset(of: \Uniforms.viewportParams)!
        let normal = MemoryLayout<Uniforms>.offset(of: \Uniforms.normalMatrix)!
        #expect(viewport % 16 == 0)
        #expect(normal == viewport + 16)
        #expect(MemoryLayout<simd_float3x3>.size == 48)
        #expect(MemoryLayout<Uniforms>.offset(of: \Uniforms.ambientAxisTints)! == normal + 48)
        #expect(MemoryLayout<Uniforms>.stride == MemoryLayout<Uniforms>.size)
    }

    // MARK: Lighting under non-uniform scale

    /// How a test sphere gets its transform: by the model matrix, or "baked" into its vertices.
    enum Bake {
        /// Left to the body's transform (the model matrix).
        case none
        /// Baked, with the true inverse-transpose normals: the reference image.
        case correct
        /// Baked, with the model matrix's own transform of the normals: the old shader's lighting.
        case modelMatrix
    }

    static func sphere(transform: simd_float4x4, bake: Bake, direct: Bool = false) -> ViewportBody {
        let source = ViewportBody.sphere(
            id: "ball", radius: 1.5, segments: 64, rings: 40, color: SIMD4(0.6, 0.6, 0.65, 1))
        var positions: [Float] = []
        var normals: [Float] = []
        var interleaved: [Float] = []
        var i = 0
        while i + 5 < source.vertexData.count {
            var p = SIMD3(source.vertexData[i], source.vertexData[i + 1], source.vertexData[i + 2])
            var n = SIMD3(
                source.vertexData[i + 3], source.vertexData[i + 4], source.vertexData[i + 5])
            switch bake {
            case .none:
                break
            case .correct:
                let q = transform * SIMD4(p, 1)
                p = SIMD3(q.x, q.y, q.z)
                n = referenceNormal(n, transform)
            case .modelMatrix:
                let q = transform * SIMD4(p, 1)
                p = SIMD3(q.x, q.y, q.z)
                let t = transform * SIMD4(n, 0)
                n = simd_normalize(SIMD3(t.x, t.y, t.z))
            }
            positions += [p.x, p.y, p.z]
            normals += [n.x, n.y, n.z]
            interleaved += [p.x, p.y, p.z, n.x, n.y, n.z]
            i += 6
        }
        let bodyTransform = bake == .none ? transform : matrix_identity_float4x4
        if direct {
            return ViewportBody.directMesh(
                id: "ball", positions: positions, normals: normals, indices: source.indices,
                color: source.color, transform: bodyTransform)
        }
        return ViewportBody(
            id: "ball", vertexData: interleaved, indices: source.indices, edges: [],
            color: source.color, transform: bodyTransform)
    }

    static func pixels(_ body: ViewportBody, quality: RenderingQuality = .standard) throws
        -> [UInt8]
    {
        var options = ParityRender.options(displayMode: .shaded)
        options.renderingQuality = quality
        return try ParityRender.render([body], options).pixels
    }

    /// Mean absolute channel difference, and the number of pixels differing by more than `limit`.
    static func difference(_ a: [UInt8], _ b: [UInt8], limit: Int = 10) -> (mean: Float, count: Int)
    {
        var total = 0
        var count = 0
        for p in stride(from: 0, to: a.count, by: 4) {
            var worst = 0
            for c in 0..<3 {
                let d = abs(Int(a[p + c]) - Int(b[p + c]))
                total += d
                worst = max(worst, d)
            }
            if worst > limit { count += 1 }
        }
        return (Float(total) / Float(a.count / 4 * 3), count)
    }

    @Test("The test scene lights differently with model-matrix normals, so it can tell them apart")
    func sceneSeparatesTheTwoNormalMaths() throws {
        let right = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .correct))
        let wrong = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .modelMatrix))
        let diff = Self.difference(right, wrong)
        #expect(diff.count > 400, "only \(diff.count) pixels differ between the two normal maths")
    }

    @Test("A non-uniformly scaled body is lit like the same geometry baked into vertices")
    func scaledBodyMatchesBakedGeometry() throws {
        let reference = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .correct))
        let scaled = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .none))
        let diff = Self.difference(reference, scaled)
        #expect(diff.mean < 0.5, "mean channel difference \(diff.mean)")
        #expect(diff.count < 40, "\(diff.count) pixels differ by more than 10")
    }

    @Test("A direct-mesh body is lit like the same geometry baked into vertices")
    func directMeshMatchesBakedGeometry() throws {
        let reference = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .correct))
        let scaled = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .none, direct: true))
        let diff = Self.difference(reference, scaled)
        #expect(diff.mean < 0.5, "mean channel difference \(diff.mean)")
        #expect(diff.count < 40, "\(diff.count) pixels differ by more than 10")
    }

    @Test("A tessellated body is lit like the same geometry baked into vertices")
    func tessellatedBodyMatchesBakedGeometry() throws {
        let reference = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .correct))
        let scaled = try Self.pixels(
            Self.sphere(transform: Self.skewed, bake: .none), quality: .enhanced)
        // PN triangles round the silhouette a little, so allow some edge pixels.
        let diff = Self.difference(reference, scaled)
        #expect(diff.mean < 1.0, "mean channel difference \(diff.mean)")
        let wrong = Self.difference(
            try Self.pixels(Self.sphere(transform: Self.skewed, bake: .modelMatrix)), scaled)
        #expect(
            wrong.count > 5 * max(diff.count, 1),
            "tessellated lighting is no closer to the correct normals (\(diff.count)) than to the model-matrix ones (\(wrong.count))"
        )
    }

    @Test("A mesh-shader body is lit like the same geometry baked into vertices")
    func meshShaderBodyMatchesBakedGeometry() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple9) else {
            return  // Mesh shaders need an Apple9 GPU (M3 / A17 Pro or later).
        }
        let reference = try Self.pixels(Self.sphere(transform: Self.skewed, bake: .correct))
        let scaled = try Self.pixels(
            Self.sphere(transform: Self.skewed, bake: .none), quality: .maximum)
        let diff = Self.difference(reference, scaled)
        #expect(diff.mean < 1.0, "mean channel difference \(diff.mean)")
        let wrong = Self.difference(
            try Self.pixels(Self.sphere(transform: Self.skewed, bake: .modelMatrix)), scaled)
        #expect(
            wrong.count > 5 * max(diff.count, 1),
            "mesh-shader lighting is no closer to the correct normals (\(diff.count)) than to the model-matrix ones (\(wrong.count))"
        )
    }
}

// MARK: - #213 highlights over mesh-shader surfaces

@MainActor
@Suite("Highlights over mesh-shader surfaces win their depth tie (#213)")
struct MeshletHighlightTests {

    static let size = 128

    /// A sphere with every triangle (or every other one) highlighted in opaque red.
    static func highlightedSphere(everyOther: Bool = false) -> ViewportBody {
        var body = ViewportBody.sphere(
            id: "ball", radius: 3, segments: 48, rings: 32, color: SIMD4(0.3, 0.3, 0.9, 1),
            up: .z)
        let red = TriangleStyle(color: SIMD4(1, 0, 0, 1))
        body.triangleStyles = (0..<body.indices.count / 3).map { i in
            everyOther && !i.isMultiple(of: 2) ? .none : red
        }
        return body
    }

    /// Whether the BGRA pixel at index `p` is the highlight red.
    static func isRed(_ pixels: [UInt8], _ p: Int) -> Bool {
        pixels[p + 2] > 200 && pixels[p + 1] < 60 && pixels[p] < 60
    }

    static func isBackground(_ pixels: [UInt8], _ p: Int) -> Bool {
        pixels[p] < 4 && pixels[p + 1] < 4 && pixels[p + 2] < 4
    }

    /// Counts highlight-red, leaked and drawn pixels of a render.
    ///
    /// "Leaked" pixels still show the sphere's blue base colour (a highlight that lost its depth
    /// test); "drawn" is every non-background pixel. Antialiased silhouette pixels are drawn but
    /// neither red nor blue.
    static func counts(_ pixels: [UInt8]) -> (red: Int, leaked: Int, drawn: Int) {
        var red = 0
        var leaked = 0
        var drawn = 0
        for p in stride(from: 0, to: pixels.count, by: 4) {
            if isRed(pixels, p) { red += 1 }
            if pixels[p] > 40 { leaked += 1 }
            if !isBackground(pixels, p) { drawn += 1 }
        }
        return (red, leaked, drawn)
    }

    static var supportsMeshShaders: Bool {
        MTLCreateSystemDefaultDevice()?.supportsFamily(.apple9) ?? false
    }

    @Test("The depth bias toward the viewer is a few depth units, only over meshlet surfaces")
    func biasConstant() {
        #expect(RendererSharedSetup.meshletHighlightDepthBias < 0)
        #expect(RendererSharedSetup.meshletHighlightDepthBias >= -64)
    }

    @Test("Offscreen: a fully highlighted mesh-shader body is highlighted edge to edge")
    func offscreenFullHighlight() throws {
        guard Self.supportsMeshShaders else { return }  // Apple9 GPUs only.
        var options = ParityRender.options(displayMode: .shaded)
        options.renderingQuality = .maximum
        let meshlet = Self.counts(
            try ParityRender.render([Self.highlightedSphere()], options).pixels)
        options.renderingQuality = .standard
        let plain = Self.counts(try ParityRender.render([Self.highlightedSphere()], options).pixels)
        #expect(plain.drawn > 1500, "test premise: the sphere should be visible")
        #expect(plain.leaked == 0, "standard path: \(plain)")
        #expect(meshlet.leaked == 0, "mesh-shader path left unhighlighted pixels: \(meshlet)")
        #expect(meshlet.red > plain.red * 98 / 100, "mesh \(meshlet) vs standard \(plain)")
    }

    @Test("Offscreen: half-highlighted mesh-shader bodies show the same highlight as standard")
    func offscreenHalfHighlight() throws {
        guard Self.supportsMeshShaders else { return }
        var options = ParityRender.options(displayMode: .shaded)
        options.renderingQuality = .maximum
        let meshlet = Self.counts(
            try ParityRender.render([Self.highlightedSphere(everyOther: true)], options).pixels)
        options.renderingQuality = .standard
        let plain = Self.counts(
            try ParityRender.render([Self.highlightedSphere(everyOther: true)], options).pixels)
        #expect(plain.red > 100, "test premise: some highlight: \(plain)")
        #expect(
            abs(meshlet.red - plain.red) <= max(plain.red / 50, 4),
            "mesh \(meshlet) vs standard \(plain)")
    }

    @Test("Live: a fully highlighted mesh-shader body is highlighted edge to edge")
    func liveFullHighlight() throws {
        guard Self.supportsMeshShaders else { return }
        let live = try DepthShaderRender.makeLive(
            bodies: [Self.highlightedSphere()], camera: ParityRender.frontCamera,
            quality: .maximum)
        #expect(live.renderer.meshShadersEnabled)
        guard
            let pixels = live.renderer.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1))
        else {
            Issue.record("headless render returned nil")
            return
        }
        let meshlet = Self.counts(pixels)
        #expect(meshlet.drawn > 1500, "test premise: the sphere should be visible")
        #expect(meshlet.leaked == 0, "mesh-shader path left unhighlighted pixels: \(meshlet)")
    }
}

// MARK: - #217 orthographic depth range does not depend on the eye

@MainActor
@Suite("Orthographic depth range is eye-independent (#217)")
struct OrthographicDepthRangeTests {

    /// Three boxes stacked in depth along the view axis (-Z), offset so each shows beside the one
    /// in front, with edges for the depth fade and surfaces for SSAO and silhouettes.
    static func scene() -> [ViewportBody] {
        let colors: [SIMD4<Float>] = [
            SIMD4(0.8, 0.5, 0.3, 1), SIMD4(0.4, 0.7, 0.4, 1), SIMD4(0.4, 0.5, 0.9, 1),
        ]
        return (0..<3).map { i in
            var box = ViewportBody.box(
                id: "box\(i)", width: 3, height: 3, depth: 3, color: colors[i])
            box.transform.columns.3 = SIMD4(
                Float(i) * 1.6 - 1.6, Float(i) * 0.9 - 0.9, -Float(i) * 4, 1)
            return box
        }
    }

    static var bounds: BoundingBox { RendererSharedSetup.sceneBounds(of: scene())! }

    /// An orthographic camera on +Z, `distance` from the pivot.
    static func camera(distance: Float) -> CameraState {
        CameraState(
            rotation: simd_quatf(angle: 0.35, axis: simd_normalize(SIMD3<Float>(1, 0.4, 0))),
            distance: distance, pivot: .zero, orthographicScale: 14, isOrthographic: true)
    }

    /// A frame at `distance`.
    ///
    /// With `explicitBounds` the camera is perspective and the projection is orthographic by
    /// `explicitOrthoBounds`, which the renderer treats as orthographic too.
    static func render(distance: Float, explicitBounds: Bool = false) throws -> [UInt8] {
        var state = camera(distance: distance)
        if explicitBounds { state.isOrthographic = false }
        var options = OffscreenRenderOptions(
            width: 160, height: 160, cameraState: state,
            displayMode: .shadedWithEdges, lightingConfiguration: .threePoint,
            backgroundColor: SIMD4(1, 1, 1, 1), appearance: .light, showGrid: false,
            showAxes: false, msaaSampleCount: 1, enableSilhouettes: true)
        if explicitBounds {
            options.explicitOrthoBounds = OrthoBounds(left: -7, right: 7, bottom: -7, top: 7)
        }
        options.edgeIntensity = 0.3  // below 1, edges fade with depth
        options.lightingConfiguration.enableSSAO = true
        options.lightingConfiguration.shadowsEnabled = false
        return try ParityRender.render(scene(), options).pixels
    }

    @Test("The fitted planes keep their span and the scene's place in them as the eye moves")
    func clipPlanesAreEyeIndependent() {
        let bounds = Self.bounds
        var previous: (near: Float, far: Float, nearest: Float)?
        for distance: Float in [25, 40, 90, 400] {
            let state = Self.camera(distance: distance)
            let clip = state.clipPlanes(sceneBounds: bounds)
            let nearest = CameraState.nearestDepth(
                of: bounds, from: state.position, along: state.viewDirection)
            let farthest = nearest + bounds.diagonalLength
            #expect(clip.near <= nearest, "near \(clip.near) is past the scene's front \(nearest)")
            #expect(clip.far >= farthest, "far \(clip.far) is before the scene's back \(farthest)")
            if let previous {
                // Same distance from the front of the scene to each plane, whatever the eye.
                #expect(abs((clip.near - nearest) - (previous.near - previous.nearest)) < 1e-3)
                #expect(abs((clip.far - nearest) - (previous.far - previous.nearest)) < 1e-3)
            }
            previous = (clip.near, clip.far, nearest)
        }
    }

    @Test("An orthographic eye inside the scene gets a near plane at or behind it")
    func nearPlaneGoesNegative() {
        let bounds = Self.bounds
        // The eye in the middle of the scene: its front is behind the eye.
        let state = CameraState(
            distance: 0.001, pivot: bounds.center, orthographicScale: 14, isOrthographic: true)
        let clip = state.clipPlanes(sceneBounds: bounds)
        let nearest = CameraState.nearestDepth(
            of: bounds, from: state.position, along: state.viewDirection)
        #expect(nearest < 0, "test premise: the scene starts behind the eye")
        #expect(clip.near < 0 && clip.near <= nearest, "near \(clip.near), scene front \(nearest)")
        #expect(clip.far > 0)
        // Every corner of the scene is inside the depth range.
        let projection = state.projectionMatrix(aspectRatio: 1, near: clip.near, far: clip.far)
        for corner in 0..<8 {
            let point = SIMD3<Float>(
                corner & 1 == 0 ? bounds.min.x : bounds.max.x,
                corner & 2 == 0 ? bounds.min.y : bounds.max.y,
                corner & 4 == 0 ? bounds.min.z : bounds.max.z)
            let clipSpace = projection * state.viewMatrix * SIMD4(point, 1)
            #expect(clipSpace.z >= 0 && clipSpace.z <= 1, "corner \(point): z \(clipSpace.z)")
        }
    }

    @Test("Perspective clip planes are unchanged")
    func perspectiveUnchanged() {
        let bounds = Self.bounds
        var state = Self.camera(distance: 30)
        state.isOrthographic = false
        let clip = state.clipPlanes(sceneBounds: bounds)
        let radius = bounds.diagonalLength / 2
        #expect(abs(clip.far - (simd_length(state.position - bounds.center) + radius) * 2) < 1e-3)
        #expect(clip.near > 0)
    }

    @Test(
        "Edges, SSAO and silhouettes look the same wherever the orthographic eye sits",
        arguments: [false, true])
    func renderIsEyeIndependent(explicitBounds: Bool) throws {
        let base = try Self.render(distance: 14, explicitBounds: explicitBounds)
        var worst = 0
        var differing = 0
        for distance: Float in [20, 40, 90, 300] {
            let moved = try Self.render(distance: distance, explicitBounds: explicitBounds)
            var count = 0
            for i in 0..<base.count where i % 4 != 3 {
                let d = abs(Int(base[i]) - Int(moved[i]))
                worst = max(worst, d)
                if d > 6 { count += 1 }
            }
            differing = max(differing, count)
        }
        #expect(
            differing <= 20, "\(differing) channel values differ by more than 6 (worst \(worst))")
    }
}

// MARK: - #217 orthographic depth of field decodes linear depth

@MainActor
@Suite("Orthographic depth of field follows the scene, not the eye (#217)")
struct OrthographicDepthOfFieldTests {

    static func frame(distance: Float, depthOfField: Bool) throws -> [UInt8] {
        var lighting = LightingConfiguration.threePoint
        lighting.enableSSAO = true
        lighting.shadowsEnabled = false
        var config = ViewportConfiguration()
        config.initialCameraState = OrthographicDepthRangeTests.camera(distance: distance)
        config.lightingConfiguration = lighting
        config.showViewCube = false
        let controller = ViewportController(configuration: config)
        controller.displayMode = .shaded
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        controller.enableDepthOfField = depthOfField
        controller.dofAperture = 0.6
        controller.dofMaxBlurRadius = 6
        guard
            let renderer = ViewportRenderer(
                controller: controller, bodies: .constant(OrthographicDepthRangeTests.scene())),
            let pixels = renderer.renderHeadlessBGRA(
                width: 160, height: 160, backgroundColor: SIMD4(1, 1, 1, 1))
        else {
            Issue.record("Metal device unavailable; skipping headless render test")
            throw DepthShaderRender.Unavailable()
        }
        return pixels
    }

    static func difference(_ a: [UInt8], _ b: [UInt8]) -> (worst: Int, count: Int) {
        var worst = 0
        var count = 0
        for i in 0..<a.count where i % 4 != 3 {
            let d = abs(Int(a[i]) - Int(b[i]))
            worst = max(worst, d)
            if d > 6 { count += 1 }
        }
        return (worst, count)
    }

    @Test("Auto-focus blur is the same wherever the orthographic eye sits")
    func blurIsEyeIndependent() throws {
        let sharp = try Self.frame(distance: 14, depthOfField: false)
        let near = try Self.frame(distance: 14, depthOfField: true)
        let far = try Self.frame(distance: 90, depthOfField: true)
        #expect(Self.difference(sharp, near).count > 200, "test premise: depth of field blurs")
        let moved = Self.difference(near, far)
        #expect(moved.count <= 20, "\(moved.count) channel values differ (worst \(moved.worst))")
    }
}
