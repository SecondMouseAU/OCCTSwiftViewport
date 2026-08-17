// RendererSharedSetupTests.swift
// OCCTSwiftViewport Tests
//
// The Metal setup ViewportRenderer and OffscreenRenderer used to hand-maintain in
// parallel now lives in RendererSharedSetup / RendererSharedBuffers / Uniforms+Scene
// (issue #101). These tests pin the extracted pure functions against the two
// implementations they replaced.

import Metal
import Testing
import simd

@testable import OCCTSwiftViewport

@Suite("Renderer shared setup")
struct RendererSharedSetupTests {

    // MARK: - Reference implementations (the code that was duplicated)

    /// `ViewportRenderer.computeGridSpacing(cameraState:config:)` as it stood before #101.
    private func legacyViewportGridSpacing(
        _ cameraState: CameraState, _ config: ViewportConfiguration
    ) -> Float {
        let distance = cameraState.distance
        let fovRadians = cameraState.fieldOfView * .pi / 180.0
        let visibleWidth = 2.0 * distance * tan(fovRadians / 2.0)
        let targetDivisions: Float = 15.0
        let idealSpacing = visibleWidth / targetDivisions
        let baseSpacing = config.gridBaseSpacing
        let subdivisions = Float(max(config.gridSubdivisions, 2))
        guard baseSpacing > 0, idealSpacing > 0 else {
            return baseSpacing > 0 ? baseSpacing : 1.0
        }
        let level = (log(idealSpacing / baseSpacing) / log(subdivisions)).rounded()
        return baseSpacing * pow(subdivisions, level)
    }

    /// `OffscreenRenderer.computeGridSpacing(cameraState:)` as it stood before #101 — the
    /// hardcoded copy that never read any configuration.
    private func legacyOffscreenGridSpacing(_ cameraState: CameraState) -> Float {
        let distance = cameraState.distance
        let fovRadians = cameraState.fieldOfView * .pi / 180.0
        let visibleWidth = 2.0 * distance * tan(fovRadians / 2.0)
        let idealSpacing = visibleWidth / 15.0
        let baseSpacing: Float = 1.0
        let subdivisions: Float = 5.0
        guard baseSpacing > 0, idealSpacing > 0 else { return 1.0 }
        let level = (log(idealSpacing / baseSpacing) / log(subdivisions)).rounded()
        return baseSpacing * pow(subdivisions, level)
    }

    /// Both renderers' `computeLightViewProjection(lightDir:bodies:)` as it stood before #101,
    /// parameterised over the one way the two copies had already diverged.
    private func legacyLightViewProjection(
        lightDir: SIMD3<Float>, bodies: [ViewportBody], applyingTransforms: Bool
    ) -> simd_float4x4 {
        var sceneMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var sceneMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var hasGeometry = false
        for body in bodies where body.isVisible {
            let box = applyingTransforms
                ? body.boundingBox?.transformed(by: body.transform) : body.boundingBox
            if let bb = box {
                sceneMin = simd_min(sceneMin, bb.min)
                sceneMax = simd_max(sceneMax, bb.max)
                hasGeometry = true
            }
        }
        if !hasGeometry {
            sceneMin = SIMD3<Float>(-5, -5, -5)
            sceneMax = SIMD3<Float>(5, 5, 5)
        }
        let center = (sceneMin + sceneMax) * 0.5
        let extents = sceneMax - sceneMin
        let radius = simd_length(extents) * 0.5
        let dir = simd_normalize(lightDir)
        let lightPos = center - dir * (radius * 2.0)
        let tentativeUp = SIMD3<Float>(0, 1, 0)
        let up: SIMD3<Float> =
            abs(simd_dot(dir, tentativeUp)) > 0.99 ? SIMD3<Float>(0, 0, 1) : tentativeUp
        let lightView = simd_float4x4.lookAt(eye: lightPos, target: center, up: up)
        let orthoSize = radius * 1.5
        let lightProj = simd_float4x4.orthographic(
            left: -orthoSize, right: orthoSize, bottom: -orthoSize, top: orthoSize,
            near: 0.01, far: radius * 4.0)
        return lightProj * lightView
    }

    private func maxDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        var worst: Float = 0
        for column in 0..<4 {
            for row in 0..<4 {
                worst = max(worst, abs(a[column][row] - b[column][row]))
            }
        }
        return worst
    }

    private func translated(_ body: ViewportBody, by offset: SIMD3<Float>) -> ViewportBody {
        var moved = body
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(offset.x, offset.y, offset.z, 1)
        moved.transform = transform
        return moved
    }

    // MARK: - Grid spacing

    @Test("Adaptive grid spacing reproduces the live renderer's config-driven implementation")
    func gridSpacingMatchesViewportRenderer() {
        let config = ViewportConfiguration()
        for distance in [Float(0.01), 0.5, 1, 3, 7.5, 20, 200, 5000] {
            var camera = CameraState()
            camera.distance = distance
            let shared = RendererSharedSetup.adaptiveGridSpacing(
                cameraState: camera,
                baseSpacing: config.gridBaseSpacing,
                subdivisions: config.gridSubdivisions)
            #expect(shared == legacyViewportGridSpacing(camera, config))
        }
    }

    @Test("Adaptive grid spacing reproduces the old headless hardcoded values when asked for them")
    func gridSpacingReproducesLegacyOffscreenValues() {
        for distance in [Float(0.5), 3, 20, 200] {
            var camera = CameraState()
            camera.distance = distance
            let shared = RendererSharedSetup.adaptiveGridSpacing(
                cameraState: camera, baseSpacing: 1.0, subdivisions: 5)
            #expect(shared == legacyOffscreenGridSpacing(camera))
        }
    }

    @Test("Offscreen grid options now default to the same values the live viewport uses")
    func offscreenGridDefaultsMatchViewportConfiguration() {
        let options = OffscreenRenderOptions()
        let config = ViewportConfiguration()
        #expect(options.gridBaseSpacing == config.gridBaseSpacing)
        #expect(options.gridSubdivisions == config.gridSubdivisions)

        // The headless copy hardcoded a subdivision factor of 5 while the live renderer's config
        // has always defaulted to 10, so the two disagreed at some zoom levels (issue #101).
        var camera = CameraState()
        camera.distance = 200
        let unified = RendererSharedSetup.adaptiveGridSpacing(
            cameraState: camera,
            baseSpacing: options.gridBaseSpacing,
            subdivisions: options.gridSubdivisions)
        #expect(unified == legacyViewportGridSpacing(camera, config))
        #expect(unified != legacyOffscreenGridSpacing(camera))
    }

    @Test("Grid spacing snaps to powers of the subdivision factor and guards bad inputs")
    func gridSpacingEdgeCases() {
        var camera = CameraState()
        camera.distance = 100

        // A subdivision factor below 2 is clamped to 2 rather than producing log(1) = 0.
        #expect(
            RendererSharedSetup.adaptiveGridSpacing(
                cameraState: camera, baseSpacing: 1, subdivisions: 1)
                == RendererSharedSetup.adaptiveGridSpacing(
                    cameraState: camera, baseSpacing: 1, subdivisions: 2))

        // A non-positive base spacing falls back to 1.0 rather than dividing by zero.
        #expect(
            RendererSharedSetup.adaptiveGridSpacing(
                cameraState: camera, baseSpacing: 0, subdivisions: 10) == 1.0)

        // The result is always base * subdivisions^k for an integer k.
        let spacing = RendererSharedSetup.adaptiveGridSpacing(
            cameraState: camera, baseSpacing: 2, subdivisions: 10)
        let level = log(spacing / 2) / log(Float(10))
        #expect(abs(level - level.rounded()) < 1e-4)
    }

    // MARK: - Shadow frustum

    @Test("Scene bounds union visible bodies, in local or world space")
    func sceneBoundsHonoursVisibilityAndTransforms() {
        let a = ViewportBody.box(id: "a", width: 2, height: 2, depth: 2, color: .zero)
        let b = translated(
            ViewportBody.box(id: "b", width: 2, height: 2, depth: 2, color: .zero),
            by: SIMD3<Float>(10, 0, 0))
        var hidden = translated(
            ViewportBody.box(id: "hidden", width: 2, height: 2, depth: 2, color: .zero),
            by: SIMD3<Float>(0, 100, 0))
        hidden.isVisible = false

        let local = RendererSharedSetup.sceneBounds(of: [a, b, hidden], applyingTransforms: false)
        let world = RendererSharedSetup.sceneBounds(of: [a, b, hidden], applyingTransforms: true)
        #expect(local != nil)
        #expect(world != nil)
        // Local space: both boxes sit on the origin, so the union is one box.
        #expect(abs((local?.max.x ?? 0) - 1) < 1e-4)
        // World space: the second box's translation widens the union.
        #expect(abs((world?.max.x ?? 0) - 11) < 1e-4)
        // The invisible body never contributes.
        #expect((world?.max.y ?? 0) < 50)

        #expect(RendererSharedSetup.sceneBounds(of: [], applyingTransforms: true) == nil)
        #expect(RendererSharedSetup.sceneBounds(of: [hidden], applyingTransforms: true) == nil)
    }

    @Test("Light view-projection matches the implementation both renderers duplicated")
    func lightViewProjectionMatchesLegacy() {
        let bodies = [
            ViewportBody.box(id: "a", width: 2, height: 2, depth: 2, color: .zero),
            translated(
                ViewportBody.sphere(id: "b", radius: 1.5, color: .zero),
                by: SIMD3<Float>(4, 1, -2)),
        ]
        let lightDir = SIMD3<Float>(-0.4, -0.8, -0.45)

        for applyingTransforms in [false, true] {
            let shared = RendererSharedSetup.lightViewProjection(
                lightDirection: lightDir,
                sceneBounds: RendererSharedSetup.sceneBounds(
                    of: bodies, applyingTransforms: applyingTransforms))
            let legacy = legacyLightViewProjection(
                lightDir: lightDir, bodies: bodies, applyingTransforms: applyingTransforms)
            #expect(maxDelta(shared, legacy) < 1e-5)
        }
    }

    @Test("Light view-projection falls back to a fixed box when nothing is visible")
    func lightViewProjectionEmptySceneFallback() {
        let lightDir = SIMD3<Float>(0, -1, 0)
        let shared = RendererSharedSetup.lightViewProjection(
            lightDirection: lightDir, sceneBounds: nil)
        let legacy = legacyLightViewProjection(
            lightDir: lightDir, bodies: [], applyingTransforms: true)
        #expect(maxDelta(shared, legacy) < 1e-5)

        // A light pointing straight down is parallel to the tentative up vector; the alternate up
        // keeps the matrix finite.
        for column in 0..<4 {
            for row in 0..<4 {
                #expect(shared[column][row].isFinite)
            }
        }
    }

    // MARK: - Uniform packing

    @Test("Light packing matches the packLight helper both renderers duplicated")
    func lightPackingMatchesLegacy() {
        let directional = LightSettings(
            direction: SIMD3<Float>(0.1, -0.9, 0.3), intensity: 1.4,
            color: SIMD3<Float>(0.9, 0.8, 0.7), isEnabled: true)
        let point = LightSettings(
            direction: SIMD3<Float>(0, -1, 0), intensity: 0.6,
            color: SIMD3<Float>(0.2, 0.4, 0.6), isEnabled: false,
            lightType: .point(radius: 2.5), position: SIMD3<Float>(1, 2, 3))

        let packedDirectional = LightDataSwift(directional)
        #expect(packedDirectional.directionAndIntensity == SIMD4<Float>(0.1, -0.9, 0.3, 1.4))
        #expect(packedDirectional.colorAndEnabled == SIMD4<Float>(0.9, 0.8, 0.7, 1.0))
        #expect(packedDirectional.typeAndParams == SIMD4<Float>(0, 0, 0, 0))
        #expect(packedDirectional.positionAndPad == SIMD4<Float>(0, 0, 0, 0))

        let packedPoint = LightDataSwift(point)
        #expect(packedPoint.colorAndEnabled.w == 0.0)
        #expect(packedPoint.typeAndParams == SIMD4<Float>(1.0, 2.5, 0, 0))
        #expect(packedPoint.positionAndPad == SIMD4<Float>(1, 2, 3, 0))
    }

    @Test("Scene uniforms pack the camera, clip range, lighting and mode flags")
    func sceneUniformsPackExpectedFields() {
        let lighting = LightingConfiguration.threePoint
        let lightVP = simd_float4x4(diagonal: SIMD4<Float>(2, 3, 4, 5))
        let uniforms = Uniforms(
            viewProjection: matrix_identity_float4x4,
            viewMatrix: matrix_identity_float4x4,
            cameraPosition: SIMD3<Float>(1, 2, 3),
            nearPlane: 0.25,
            farPlane: 750,
            lighting: lighting,
            lightViewProjection: lightVP,
            shadowParams: SIMD4<Float>(0.001, 0.5, 1, 0.8),
            shadowParams2: SIMD4<Float>(1, 2, 0, 0),
            unlit: true
        )

        #expect(uniforms.cameraPosition == SIMD4<Float>(1, 2, 3, 0.25))
        #expect(uniforms.materialParams.w == 750)
        #expect(uniforms.ambientSkyColor.w == lighting.specularPower)
        #expect(uniforms.ambientGroundColor.w == lighting.specularIntensity)
        #expect(uniforms.lightViewProjectionMatrix == lightVP)
        #expect(uniforms.unlit == 1)
        // Optional parameters default to "no IBL, no clip planes", as the headless path expects.
        #expect(uniforms.iblParams == .zero)
        #expect(uniforms.clipPlaneCount == 0)
        #expect(uniforms.modelMatrix == matrix_identity_float4x4)

        let lit = Uniforms(
            viewProjection: matrix_identity_float4x4,
            viewMatrix: matrix_identity_float4x4,
            cameraPosition: .zero,
            nearPlane: 0.1,
            farPlane: 100,
            lighting: lighting,
            lightViewProjection: matrix_identity_float4x4,
            shadowParams: .zero,
            shadowParams2: .zero,
            unlit: false
        )
        #expect(lit.unlit == 0)
    }

    // MARK: - Shared buffer building

    @Test("Edge polylines flatten to stride-6 line-segment pairs")
    func edgeLineVerticesFlattenPolylines() {
        let polylines: [[SIMD3<Float>]] = [
            [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(1, 1, 0)],
            [SIMD3<Float>(5, 5, 5)],  // degenerate: dropped
            [],  // empty: dropped
        ]
        let flat = RendererSharedBuffers.edgeLineVertices(from: polylines)

        // Two segments from the first polyline, two vertices each, stride 6.
        #expect(flat.count == 2 * 2 * 6)
        #expect(Array(flat[0..<6]) == [0, 0, 0, 0, 0, 0])
        #expect(Array(flat[6..<12]) == [1, 0, 0, 0, 0, 0])
        #expect(Array(flat[12..<18]) == [1, 0, 0, 0, 0, 0])
        #expect(Array(flat[18..<24]) == [1, 1, 0, 0, 0, 0])
        #expect(RendererSharedBuffers.edgeLineVertices(from: []).isEmpty)
    }

    @Test("Mesh buffer building routes direct-mesh and interleaved bodies to the right layout")
    @MainActor
    func meshBuffersRouteByBodyKind() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable; skipping buffer construction test")
            return
        }

        let interleaved = ViewportBody.box(id: "box", width: 1, height: 1, depth: 1, color: .zero)
        let interleavedBuffers = RendererSharedBuffers.makeMeshBuffers(
            device: device, body: interleaved)
        #expect(interleavedBuffers.vertexBuffer != nil)
        #expect(interleavedBuffers.normalBuffer == nil)
        #expect(interleavedBuffers.indexCount == interleaved.indices.count)
        #expect(interleavedBuffers.vertexCount == interleaved.vertexData.count / 6)

        var positions: [Float] = []
        var normals: [Float] = []
        var i = 0
        while i + 5 < interleaved.vertexData.count {
            positions.append(contentsOf: interleaved.vertexData[i..<(i + 3)])
            normals.append(contentsOf: interleaved.vertexData[(i + 3)..<(i + 6)])
            i += 6
        }
        let direct = ViewportBody.directMesh(
            id: "direct", positions: positions, normals: normals,
            indices: interleaved.indices, color: .zero)
        let directBuffers = RendererSharedBuffers.makeMeshBuffers(device: device, body: direct)
        #expect(directBuffers.vertexBuffer != nil)
        #expect(directBuffers.normalBuffer != nil)
        #expect(directBuffers.vertexCount == positions.count / 3)
        #expect(directBuffers.indexCount == interleaved.indices.count)

        // An edge-only body has no mesh at all.
        let edgeOnly = ViewportBody(
            id: "edges", vertexData: [], indices: [],
            edges: [[SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0)]], color: .zero)
        let none = RendererSharedBuffers.makeMeshBuffers(device: device, body: edgeOnly)
        #expect(none.vertexBuffer == nil)
        #expect(none.indexBuffer == nil)
        #expect(none.indexCount == 0)
    }

    // MARK: - Pipeline construction

    @Test("Both renderers still build every shared pipeline, at every rendering quality")
    @MainActor
    func renderersBuildTheirPipelines() {
        guard MTLCreateSystemDefaultDevice() != nil else {
            Issue.record("Metal device unavailable; skipping pipeline construction test")
            return
        }
        // Both inits return nil if any pipeline fails to compile, so a non-nil result covers the
        // whole shared-pipeline set. `.maximum` additionally exercises the tessellation and
        // mesh-shader branches that sit alongside the extracted code.
        #expect(OffscreenRenderer() != nil)
        for quality in [RenderingQuality.standard, .enhanced, .maximum] {
            let controller = ViewportController(
                configuration: ViewportConfiguration(renderingQuality: quality))
            let body = ViewportBody.box(id: "b", width: 1, height: 1, depth: 1, color: .zero)
            let renderer = ViewportRenderer(controller: controller, bodies: .constant([body]))
            #expect(renderer != nil, "ViewportRenderer init failed at quality \(quality)")
        }
    }

    @Test("Point colour buffers are dropped when they don't match the vertex count")
    @MainActor
    func pointColorBufferRequiresMatchingCount() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("Metal device unavailable; skipping buffer construction test")
            return
        }
        let vertices = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1)]
        #expect(
            RendererSharedBuffers.makePointPositionBuffer(device: device, vertices: vertices)
                != nil)
        #expect(RendererSharedBuffers.makePointPositionBuffer(device: device, vertices: []) == nil)
        #expect(
            RendererSharedBuffers.makePointColorBuffer(
                device: device, vertexColors: [SIMD4<Float>(1, 0, 0, 1)], vertexCount: 2) == nil)
        #expect(
            RendererSharedBuffers.makePointColorBuffer(
                device: device,
                vertexColors: [SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 1, 0, 1)],
                vertexCount: 2) != nil)
    }
}
