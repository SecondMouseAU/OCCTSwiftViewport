// OffscreenPickTests.swift
// OCCTSwiftViewport Tests
//
// OffscreenRenderer's GPU pick pass (issue #236). The reference is the live renderer: the same
// scene and camera are rendered through ViewportRenderer's headless path and picked with its
// `performPick` / `performRegionPick`, then every pixel sampled must give the same `PickResult`
// from `OffscreenRenderer.renderPickMap(...)`. The suites cover each body kind the live pick
// handles, and clip planes, the selection filter, `pickRadius` and the body transform.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

// MARK: - Scene helpers

private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

/// A unit-ish box with its 12 edges and 8 corners pickable.
private func pickableBox(
    _ id: String, at position: SIMD3<Float> = .zero, size: Float = 1.2,
    color: SIMD4<Float> = SIMD4(0.8, 0.8, 0.8, 1)
) -> ViewportBody {
    var body = ViewportBody.box(id: id, width: size, height: size, depth: size, color: color)
    body.edgeIndices = Array(0..<12)
    let h = size / 2
    body.vertices = [
        SIMD3(-h, -h, -h), SIMD3(h, -h, -h), SIMD3(h, h, -h), SIMD3(-h, h, -h),
        SIMD3(-h, -h, h), SIMD3(h, -h, h), SIMD3(h, h, h), SIMD3(-h, h, h),
    ]
    body.vertexIndices = Array(0..<8)
    body.transform = translation(position.x, position.y, position.z)
    return body
}

/// `box` re-expressed as a direct-mesh body (de-interleaved positions and normals).
private func directBox(_ id: String, at position: SIMD3<Float>) -> ViewportBody {
    let source = ViewportBody.box(id: id, width: 1.2, height: 1.2, depth: 1.2)
    var positions: [Float] = []
    var normals: [Float] = []
    for v in stride(from: 0, to: source.vertexData.count, by: 6) {
        positions += Array(source.vertexData[v..<(v + 3)])
        normals += Array(source.vertexData[(v + 3)..<(v + 6)])
    }
    var body = ViewportBody.directMesh(
        id: id, positions: positions, normals: normals, indices: source.indices,
        color: SIMD4(0.7, 0.8, 0.9, 1), edges: source.edges)
    body.edgeIndices = Array(0..<12)
    body.transform = translation(position.x, position.y, position.z)
    return body
}

/// Two arcs in the XY plane: a full circle and a half circle inside it.
private func arcBody(_ id: String, at position: SIMD3<Float>) -> ViewportBody {
    var body = ViewportBody(
        id: id, vertexData: [], indices: [], edges: [],
        arcs: [
            .circle(
                center: .zero, radius: 0.9, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
            ViewportArc(
                center: .zero, radius: 0.45, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
                startAngle: 0, endAngle: .pi),
        ],
        color: SIMD4(1, 0.8, 0.1, 1))
    body.transform = translation(position.x, position.y, position.z)
    return body
}

/// One line-of-sight summary of a pick, for failure messages.
private func describe(_ result: PickResult?) -> String {
    guard let result else { return "miss" }
    return "\(result.bodyID)#\(result.bodyIndex) \(result.kind) \(result.triangleIndex)"
}

// MARK: - Rig

private struct RigUnavailable: Error {}

/// One scene rendered through both renderers, with the pick results of each.
@MainActor
private struct PickParityRig {
    static let size = 96

    let controller: ViewportController
    let live: ViewportRenderer
    let offscreen: OffscreenRenderer
    let options: OffscreenRenderOptions
    let bodies: [ViewportBody]

    init(
        bodies: [ViewportBody], displayMode: DisplayMode = .shadedWithEdges,
        quality: RenderingQuality = .standard,
        edge: EdgeLineConfiguration = EdgeLineConfiguration(width: 4), pickRadius: Int = 0,
        clipPlanes: [ClipPlane] = [], filter: PickResultFilter? = nil
    ) throws {
        var camera = CameraState()
        camera.rotation =
            simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -0.35, axis: SIMD3(1, 0, 0))
        if let fitted = camera.fit(to: bodies, aspectRatio: 1, padding: 1.25) { camera = fitted }

        var config = ViewportConfiguration()
        config.initialCameraState = camera
        config.edgeLineConfiguration = edge
        config.backgroundColor = SIMD4(0, 0, 0, 1)
        config.showViewCube = false
        config.renderingQuality = quality
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: pickRadius)
        let controller = ViewportController(configuration: config)
        controller.displayMode = displayMode
        controller.showGrid = false
        controller.showAxes = false
        controller.enableTAA = false
        controller.clipPlanes = clipPlanes
        controller.selectionFilter = filter

        var options = OffscreenRenderOptions(
            matching: controller, width: Self.size, height: Self.size)
        options.appearance = .light

        guard let live = ViewportRenderer(controller: controller, bodies: .constant(bodies)),
            let offscreen = OffscreenRenderer()
        else {
            Issue.record("Metal device unavailable; skipping")
            throw RigUnavailable()
        }
        // Two frames: the live renderer fits its near/far planes to the bounds it cached on the
        // previous frame (see OffscreenParityTests).
        guard
            live.renderHeadlessBGRA(
                width: Self.size, height: Self.size, backgroundColor: SIMD4(0, 0, 0, 1),
                frameCount: 2) != nil
        else {
            Issue.record("headless render returned nil")
            throw RigUnavailable()
        }
        self.controller = controller
        self.live = live
        self.offscreen = offscreen
        self.options = options
        self.bodies = bodies
    }

    /// The live renderer's pick, filtered as the controller filters it.
    func livePick(_ pixel: SIMD2<Int>) async -> PickResult? {
        let result = await withCheckedContinuation { continuation in
            live.performPick(at: pixel) { continuation.resume(returning: $0) }
        }
        return ViewportController.applySelectionFilter(result, filter: controller.selectionFilter)
    }

    func liveRegion(_ rect: CGRect) async -> [PickResult] {
        let results = await withCheckedContinuation { continuation in
            live.performRegionPick(rect: rect) { continuation.resume(returning: $0) }
        }
        return ViewportController.applySelectionFilter(results, filter: controller.selectionFilter)
    }

    func pickMap(_ options: OffscreenRenderOptions? = nil) -> OffscreenPickMap? {
        offscreen.renderPickMap(bodies: bodies, options: options ?? self.options)
    }

    /// What sampling every `step`th pixel of both renderers found.
    struct Comparison {
        var checked = 0
        var hits = 0
        var mismatches: [String] = []
        var kinds: Set<PrimitiveKind> = []
        /// The kinds of the hits outside the widget layer, which a selection filter governs.
        var userKinds: Set<PrimitiveKind> = []
        var bodyIDs: Set<String> = []
        var bodyIndices: [String: Int] = [:]
        var layers: Set<PickLayer> = []
        var primitives: [PrimitiveKind: Set<Int>] = [:]
    }

    /// Picks a grid of pixels, and the whole frame and a few rectangles, from both renderers.
    func compare(step: Int = 3) async -> Comparison {
        var comparison = Comparison()
        guard let map = pickMap() else {
            comparison.mismatches.append("renderPickMap returned nil")
            return comparison
        }
        for y in stride(from: 1, to: Self.size, by: step) {
            for x in stride(from: 1, to: Self.size, by: step) {
                let pixel = SIMD2(x, y)
                let offscreenResult = map.pick(at: pixel)
                let liveResult = await livePick(pixel)
                comparison.checked += 1
                if offscreenResult != liveResult {
                    comparison.mismatches.append(
                        "(\(x), \(y)): offscreen \(describe(offscreenResult)), "
                            + "live \(describe(liveResult))")
                }
                if let hit = liveResult {
                    comparison.hits += 1
                    comparison.kinds.insert(hit.kind)
                    if hit.pickLayer == .userGeometry { comparison.userKinds.insert(hit.kind) }
                    comparison.bodyIDs.insert(hit.bodyID)
                    comparison.bodyIndices[hit.bodyID] = hit.bodyIndex
                    comparison.layers.insert(hit.pickLayer)
                    comparison.primitives[hit.kind, default: []].insert(hit.triangleIndex)
                }
            }
        }
        let full = CGFloat(Self.size)
        let rects = [
            CGRect(x: 0, y: 0, width: full, height: full),
            CGRect(x: 10, y: 20, width: 40, height: 30),
            CGRect(x: -20, y: -20, width: 60, height: 60),
            CGRect(x: 60, y: 50, width: 80, height: 80),
        ]
        for rect in rects {
            let offscreenResults = map.pickRegion(rect)
            let liveResults = await liveRegion(rect)
            comparison.checked += 1
            if offscreenResults != liveResults {
                comparison.mismatches.append(
                    "region \(rect): offscreen \(offscreenResults.map { describe($0) }), "
                        + "live \(liveResults.map { describe($0) })")
            }
        }
        return comparison
    }

    /// Expects `comparison` to have matched the live renderer everywhere, and to have seen
    /// enough hits that the match means something.
    func expectParity(
        _ comparison: Comparison, minimumHits: Int = 40,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            comparison.mismatches.isEmpty,
            "\(comparison.mismatches.count) of \(comparison.checked) differ: \(comparison.mismatches.prefix(5))",
            sourceLocation: sourceLocation)
        #expect(
            comparison.hits >= minimumHits, "only \(comparison.hits) hits: the scene is vacuous",
            sourceLocation: sourceLocation)
    }
}

// MARK: - Parity with the live pick, per body kind

@MainActor
@Suite("OffscreenRenderer GPU pick matches the live pick (#236)")
struct OffscreenPickParityTests {

    @Test("Standard bodies: faces, draw-order indices, hidden and non-pickable bodies, transforms")
    func standardBodies() async throws {
        var hidden = pickableBox("hidden", at: SIMD3(0, 2, 0))
        hidden.isVisible = false
        var ghost = pickableBox("ghost", at: SIMD3(0, -2, 0))
        ghost.isPickable = false
        var turned = ViewportBody.sphere(id: "turned", radius: 0.7, color: SIMD4(0.9, 0.5, 0.2, 1))
        turned.transform =
            translation(1.8, 0, 0)
            * simd_float4x4(simd_quatf(angle: 0.7, axis: SIMD3(1, 1, 0).normalized))
        let bodies = [
            pickableBox("a", at: SIMD3(-1.6, 0, 0)), hidden, ghost, turned,
            pickableBox("b", at: SIMD3(0.2, 0.3, -1.6)),
        ]
        let rig = try PickParityRig(bodies: bodies, displayMode: .shaded)
        let result = await rig.compare()
        rig.expectParity(result)
        // `.shaded` hides edges, but the bodies' corner vertices are always pickable.
        #expect(result.kinds == [.face, .vertex], "\(result.kinds)")
        #expect(result.bodyIDs.isSuperset(of: ["a", "turned", "b"]))
        #expect(!result.bodyIDs.contains("hidden") && !result.bodyIDs.contains("ghost"))
        // `hidden` takes no index; `ghost` is skipped but keeps its.
        #expect(result.bodyIndices["a"] == 0)
        #expect(result.bodyIndices["ghost"] == nil)
        #expect(result.bodyIndices["turned"] == 2)
        #expect(result.bodyIndices["b"] == 3)
    }

    @Test("Direct-mesh bodies: faces and derived vertices")
    func directMeshBodies() async throws {
        let rig = try PickParityRig(
            bodies: [
                directBox("d1", at: SIMD3(-1.1, 0, 0)), directBox("d2", at: SIMD3(1.1, 0.2, 0)),
            ],
            displayMode: .shaded, pickRadius: 3)
        let result = await rig.compare()
        rig.expectParity(result)
        #expect(result.kinds.contains(.face))
        #expect(result.bodyIDs == ["d1", "d2"])
    }

    @Test("Edges and vertices, exact pixel and neighbourhood", arguments: [0, 3])
    func edgesAndVertices(pickRadius: Int) async throws {
        let rig = try PickParityRig(
            bodies: [
                pickableBox("a", at: SIMD3(-1, 0, 0)), pickableBox("b", at: SIMD3(1, 0.1, 0.3)),
            ],
            pickRadius: pickRadius)
        let result = await rig.compare(step: 2)
        rig.expectParity(result)
        #expect(result.kinds.contains(.face))
        if pickRadius > 0 {
            #expect(result.kinds.isSuperset(of: [.edge, .vertex]), "\(result.kinds)")
        } else {
            #expect(result.kinds.contains(.edge), "\(result.kinds)")
        }
    }

    @Test("Native 1 px edges (quad expansion off)")
    func nativeEdges() async throws {
        let rig = try PickParityRig(
            bodies: [pickableBox("a", at: SIMD3(-1, 0, 0)), pickableBox("b", at: SIMD3(1, 0, 0))],
            edge: EdgeLineConfiguration(width: 1, useQuadExpansion: false), pickRadius: 2)
        let result = await rig.compare(step: 2)
        rig.expectParity(result)
        #expect(result.kinds.contains(.edge))
    }

    @Test("A slice of a body's edges (edgeDrawRange) is all that can be picked")
    func edgeDrawRange() async throws {
        var body = pickableBox("a")
        body.edgeDrawRange = 0..<4
        let rig = try PickParityRig(bodies: [body], pickRadius: 3)
        let result = await rig.compare(step: 2)
        rig.expectParity(result)
        let edgeSegments = result.primitives[.edge] ?? []
        #expect(!edgeSegments.isEmpty && edgeSegments.allSatisfy { $0 < 4 }, "\(edgeSegments)")
    }

    @Test(
        "Analytic arcs report the arc index, with and without quad expansion",
        arguments: [true, false])
    func arcs(quad: Bool) async throws {
        let rig = try PickParityRig(
            bodies: [arcBody("rings", at: .zero), pickableBox("a", at: SIMD3(0, 0, -1.4))],
            edge: EdgeLineConfiguration(width: 4, useQuadExpansion: quad), pickRadius: 2)
        let result = await rig.compare(step: 2)
        rig.expectParity(result, minimumHits: 30)
        let ringPicks = result.primitives[.edge] ?? []
        #expect(ringPicks.contains(0) && ringPicks.contains(1), "arc indices \(ringPicks)")
    }

    @Test("Point-cloud bodies pick their points as vertices")
    func pointCloud() async throws {
        let points = (0..<24).map { i -> SIMD3<Float> in
            let t = Float(i) / 24 * 2 * .pi
            return SIMD3(cos(t) * 1.4, sin(t) * 1.4, Float(i % 3) * 0.2)
        }
        let cloud = ViewportBody(
            id: "cloud", vertexData: [], indices: [], edges: [], vertices: points,
            vertexIndices: Array(0..<24), color: SIMD4(0.2, 0.8, 0.4, 1), pointRadius: 0.12,
            primitiveKind: .point)
        let rig = try PickParityRig(
            bodies: [cloud, pickableBox("a")], displayMode: .shaded, pickRadius: 4)
        let result = await rig.compare(step: 2)
        rig.expectParity(result, minimumHits: 20)
        #expect(result.kinds.contains(.vertex))
        #expect(result.bodyIDs.contains("cloud"))
    }

    @Test("Wireframe: hidden surfaces are not pickable, edges are")
    func wireframeMode() async throws {
        let rig = try PickParityRig(
            bodies: [
                pickableBox("a", at: SIMD3(-0.9, 0, 0)), pickableBox("b", at: SIMD3(0.9, 0, 0)),
            ],
            displayMode: .wireframe, pickRadius: 3)
        let result = await rig.compare(step: 2)
        rig.expectParity(result, minimumHits: 20)
        #expect(!result.kinds.contains(.face), "\(result.kinds)")
        #expect(result.kinds.contains(.edge))
    }

    @Test("Overlay bodies win the pick over the geometry they cover, in the widget layer")
    func overlayLayer() async throws {
        var widget = pickableBox("widget", size: 0.8, color: SIMD4(1, 0.2, 0.2, 1))
        widget.renderLayer = .overlay
        widget.pickLayer = .widget
        widget.transform = translation(0, 0, -1)  // behind the box, yet it is drawn over it
        var arcs = arcBody("gizmo-ring", at: SIMD3(0, 0, 0.9))
        arcs.renderLayer = .overlay
        arcs.pickLayer = .widget
        let rig = try PickParityRig(
            bodies: [pickableBox("a", size: 1.6), widget, arcs], pickRadius: 2)
        let result = await rig.compare(step: 2)
        rig.expectParity(result)
        #expect(result.layers == [.userGeometry, .widget], "\(result.layers)")
        #expect(result.bodyIDs.contains("widget") && result.bodyIDs.contains("a"))
    }

    @Test("Tessellated surfaces (.enhanced) pick as the live tessellated pass does")
    func tessellated() async throws {
        let rig = try PickParityRig(
            bodies: [
                ViewportBody.sphere(id: "ball", radius: 0.8, segments: 16, rings: 10),
                pickableBox("a", at: SIMD3(1.7, 0, 0)),
            ], displayMode: .shaded, quality: .enhanced)
        guard rig.live.tessellatedPickPipeline != nil else { return }
        #expect(rig.offscreen.surfacePaths(for: rig.options).tessellation)
        let result = await rig.compare()
        rig.expectParity(result)
        #expect(result.bodyIDs == ["ball", "a"])
    }

    @Test("Mesh-shader surfaces (.maximum) pick as the live mesh-shader pass does")
    func meshShaders() async throws {
        let rig = try PickParityRig(
            bodies: [
                ViewportBody.sphere(id: "ball", radius: 0.8, segments: 16, rings: 10),
                pickableBox("a", at: SIMD3(1.7, 0, 0)),
            ], displayMode: .shaded, quality: .maximum)
        guard rig.live.meshShaderPickPipeline != nil else { return }
        #expect(rig.offscreen.surfacePaths(for: rig.options).meshShaders)
        let result = await rig.compare()
        rig.expectParity(result)
        #expect(result.bodyIDs == ["ball", "a"])
    }
}

// MARK: - Clip planes, selection filter, pick radius

@MainActor
@Suite("OffscreenRenderer pick honours clip planes, the selection filter and pickRadius (#236)")
struct OffscreenPickConfigurationTests {

    private static let scene = [
        pickableBox("a", at: SIMD3(-1, 0, 0)), pickableBox("b", at: SIMD3(1, 0, 0)),
    ]

    @Test("A section plane hides what it clips from the pick, as live")
    func clipPlanes() async throws {
        // Keep x > 0: body "a" is cut away entirely, body "b" survives.
        let rig = try PickParityRig(
            bodies: Self.scene, clipPlanes: [ClipPlane(normal: SIMD3(1, 0, 0), distance: -0.1)])
        let clipped = await rig.compare()
        rig.expectParity(clipped)
        #expect(clipped.bodyIDs == ["b"], "\(clipped.bodyIDs)")

        // The same scene with no plane picks both, so the plane is what removed "a".
        let open = try PickParityRig(bodies: Self.scene)
        let all = await open.compare(step: 6)
        #expect(all.bodyIDs == ["a", "b"])
    }

    @Test("The selection filter turns a rejected hit into a miss, widgets bypass it")
    func selectionFilter() async throws {
        var widget = pickableBox("widget", at: SIMD3(0, 0, 1.5), size: 0.7)
        widget.pickLayer = .widget
        let bodies = Self.scene + [widget]

        let facesOnly = try PickParityRig(bodies: bodies, pickRadius: 2, filter: .faces)
        let faces = await facesOnly.compare(step: 2)
        facesOnly.expectParity(faces)
        #expect(faces.userKinds == [.face], "\(faces.userKinds)")
        // The widget's edges and vertices bypass the filter.
        #expect(faces.kinds.isSuperset(of: [.face, .edge, .vertex]), "\(faces.kinds)")
        let widgetOnly = try PickParityRig(
            bodies: bodies, pickRadius: 2, filter: .excludingBodyIDs(["a", "b"]))
        let rest = await widgetOnly.compare(step: 2)
        widgetOnly.expectParity(rest, minimumHits: 10)
        #expect(rest.bodyIDs == ["widget"])

        let nothing = try PickParityRig(bodies: bodies, filter: PickResultFilter.nothing)
        let none = await nothing.compare(step: 3)
        nothing.expectParity(none, minimumHits: 5)
        #expect(none.layers == [.widget], "only the widget layer bypasses the filter")
    }

    @Test("pickRadius widens a pick onto a thin edge the cursor misses")
    func pickRadius() async throws {
        let body = pickableBox("a", size: 1.8)
        let exact = try PickParityRig(bodies: [body], pickRadius: 0)
        let wide = try PickParityRig(bodies: [body], pickRadius: 4)
        let exactResult = await exact.compare(step: 2)
        let wideResult = await wide.compare(step: 2)
        exact.expectParity(exactResult)
        wide.expectParity(wideResult)
        #expect(wideResult.kinds.contains(.vertex), "radius 4 reaches a corner")
    }

    @Test("The pick map's pickRadius is the options', clamped to 32")
    func pickRadiusClamp() {
        var options = OffscreenRenderOptions()
        options.pickRadius = 500
        #expect(options.pickRadius == 32)
        options.pickRadius = -3
        #expect(options.pickRadius == 0)
        #expect(OffscreenRenderOptions(pickRadius: 99).pickRadius == 32)
        #expect(OffscreenRenderOptions().pickRadius == 0)
        #expect(OffscreenRenderOptions().selectionFilter == nil)
    }

    @Test("OffscreenRenderOptions(matching:) copies the controller's pick settings")
    func matchingCopiesPickSettings() {
        var config = ViewportConfiguration()
        config.pickingConfiguration = PickingConfiguration(isEnabled: true, pickRadius: 5)
        let controller = ViewportController(configuration: config)
        controller.selectionFilter = .edges
        let options = OffscreenRenderOptions(matching: controller, width: 32, height: 32)
        #expect(options.pickRadius == 5)
        let filter = options.selectionFilter
        #expect(filter != nil)
        let someEdge = PickResult(
            pickValue: PickEncoding.encode(objectIndex: 0, primitiveIndex: 1, kind: .edge),
            indexMap: [0: "x"])
        let someFace = PickResult(
            pickValue: PickEncoding.encode(objectIndex: 0, primitiveIndex: 1, kind: .face),
            indexMap: [0: "x"])
        #expect(someEdge.map { filter?.matches($0) } == true)
        #expect(someFace.map { filter?.matches($0) } == false)
    }
}

// MARK: - API behaviour

@MainActor
@Suite("OffscreenRenderer pick entry points (#236)")
struct OffscreenPickAPITests {

    private func options(width: Int = 96, height: Int = 96) -> OffscreenRenderOptions {
        OffscreenRenderOptions(
            width: width, height: height,
            cameraState: CameraState(
                rotation: simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), distance: 6, pivot: .zero),
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false)
    }

    @Test("performPick and performRegionPick agree with the pick map")
    func entryPointsAgreeWithMap() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let bodies = [
            pickableBox("a", at: SIMD3(-0.8, 0, 0)), pickableBox("b", at: SIMD3(0.8, 0, 0)),
        ]
        var opts = options()
        opts.pickRadius = 2
        let map = try #require(renderer.renderPickMap(bodies: bodies, options: opts))
        #expect(map.width == 96 && map.height == 96 && map.pickRadius == 2)
        for pixel in [SIMD2(20, 48), SIMD2(48, 48), SIMD2(75, 40), SIMD2(2, 2)] {
            #expect(
                renderer.performPick(bodies: bodies, at: pixel, options: opts)
                    == map.pick(at: pixel))
        }
        let rect = CGRect(x: 0, y: 0, width: 96, height: 96)
        let region = renderer.performRegionPick(bodies: bodies, rect: rect, options: opts)
        #expect(region == map.pickRegion(rect))
        #expect(Set(region.map(\.bodyID)) == ["a", "b"])
    }

    @Test(
        "A pixel off the render clamps to its edge, a rectangle off it is empty, background misses")
    func outOfBounds() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let bodies = [pickableBox("a", size: 5)]  // fills the frame
        let map = try #require(renderer.renderPickMap(bodies: bodies, options: options()))
        #expect(map.pick(at: SIMD2(-50, -50)) == map.pick(at: SIMD2(0, 0)))
        #expect(map.pick(at: SIMD2(500, 500)) == map.pick(at: SIMD2(95, 95)))
        #expect(map.pickRegion(CGRect(x: 200, y: 200, width: 10, height: 10)).isEmpty)

        let empty = try #require(renderer.renderPickMap(bodies: [], options: options()))
        #expect(empty.pick(at: SIMD2(48, 48)) == nil)
        #expect(empty.pickRegion(CGRect(x: 0, y: 0, width: 96, height: 96)).isEmpty)
    }

    @Test("A non-positive size gives no map")
    func degenerateSize() {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        #expect(renderer.renderPickMap(bodies: [], options: options(width: 0)) == nil)
        #expect(
            renderer.performPick(bodies: [], at: SIMD2(0, 0), options: options(height: 0)) == nil)
    }

    @Test("One renderer picks at several sizes and between renders without disturbing them")
    func reuseAcrossSizesAndRenders() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let bodies = [pickableBox("a", size: 2)]
        let opts = options()
        let before = try #require(renderer.render(bodies: bodies, options: opts))
        let small = try #require(
            renderer.renderPickMap(bodies: bodies, options: options(width: 40, height: 30)))
        let large = try #require(
            renderer.renderPickMap(bodies: bodies, options: options(width: 160, height: 120)))
        #expect(small.pick(at: SIMD2(20, 15))?.bodyID == "a")
        #expect(large.pick(at: SIMD2(80, 60))?.bodyID == "a")
        #expect(large.pick(at: SIMD2(159, 119)) == nil)
        let after = try #require(renderer.render(bodies: bodies, options: opts))
        let beforePixels = ParityRender.bgra(before).0
        let afterPixels = ParityRender.bgra(after).0
        #expect(beforePixels == afterPixels, "picking changed what render draws")
    }

    @Test("A body edited between picks is picked as edited")
    func editedBody() throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        var body = pickableBox("a", size: 2)
        let first = try #require(renderer.renderPickMap(bodies: [body], options: options()))
        #expect(first.pick(at: SIMD2(48, 48))?.bodyID == "a")
        body.transform = translation(40, 0, 0)  // far out of view
        let second = try #require(renderer.renderPickMap(bodies: [body], options: options()))
        #expect(second.pick(at: SIMD2(48, 48)) == nil)
    }
}

extension SIMD3 where Scalar == Float {
    fileprivate var normalized: SIMD3<Float> { simd_normalize(self) }
}
