// PickFollowsDisplayModeTests.swift
// OCCTSwiftViewport Tests
//
// `PickingConfiguration.followsDisplayMode` and `OffscreenRenderOptions.pickFollowsDisplayMode`
// (issue #250). With the default (true) the pick pass writes what the display mode draws, as since
// 1.3.0; with it off every kind a body carries is written in every mode. These pin the issue's
// table under both settings, that the live and the headless pick agree under both, the cases the
// table leaves out (arcs, overlay bodies, a heightfield, an edge-only body), that the setting draws
// nothing differently, and that clip planes, transforms and the selection filter still apply.

import CoreGraphics
import Foundation
import Testing
import simd

@testable import OCCTSwiftViewport

private struct RigUnavailable: Error {}

private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
}

/// A mesh body (a box) that carries analytic arcs on its +Z face and no `edgeIndices`, so its
/// arcs are its only edges.
private func meshArcBody(_ id: String, at position: SIMD3<Float>) -> ViewportBody {
    var body = ViewportBody.box(id: id, width: 1.2, height: 1.2, depth: 1.2)
    body.arcs = [
        .circle(
            center: SIMD3(0, 0, 0.6), radius: 0.42, xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 1, 0)),
        ViewportArc(
            center: SIMD3(0, 0, 0.6), radius: 0.2, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            startAngle: 0, endAngle: .pi),
    ]
    body.transform = translation(position.x, position.y, position.z)
    return body
}

/// A box as a direct-mesh body (de-interleaved positions and normals) with its edges pickable.
private func directBoxBody(_ id: String, at position: SIMD3<Float>) -> ViewportBody {
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

/// A body with edges and no surface mesh (a wire box), pickable by `edgeIndices`.
private func wireBody(_ id: String, at position: SIMD3<Float>) -> ViewportBody {
    let source = ViewportBody.box(id: id, width: 1.2, height: 1.2, depth: 1.2)
    var body = ViewportBody(
        id: id, vertexData: [], indices: [], edges: source.edges, color: SIMD4(0.9, 0.9, 0.2, 1))
    body.edgeIndices = Array(0..<12)
    body.transform = translation(position.x, position.y, position.z)
    return body
}

@MainActor
@Suite("Picking independent of the display mode (#250)")
struct PickFollowsDisplayModeTests {

    // MARK: Headless helpers

    private static let size = 160

    /// The camera of `PickParityRig`: turned and tilted, fitted to `bodies`.
    private static func camera(fitting bodies: [ViewportBody]) -> CameraState {
        var camera = CameraState()
        camera.rotation =
            simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -0.35, axis: SIMD3(1, 0, 0))
        if let fitted = camera.fit(to: bodies, aspectRatio: 1, padding: 1.25) { camera = fitted }
        return camera
    }

    /// Options for a render of `bodies` from the rig's camera.
    private static func options(
        _ bodies: [ViewportBody], mode: DisplayMode, follows: Bool
    ) -> OffscreenRenderOptions {
        var options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera(fitting: bodies), displayMode: mode,
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, msaaSampleCount: 1)
        options.edgeLineConfiguration = EdgeLineConfiguration(width: 4)
        options.pickFollowsDisplayMode = follows
        return options
    }

    /// Every hit of the frame, by the kind it reports and the bodies it is on.
    private static func hits(
        _ bodies: [ViewportBody], mode: DisplayMode, follows: Bool
    ) throws -> [PrimitiveKind: Set<String>] {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            throw RigUnavailable()
        }
        let map = try #require(
            renderer.renderPickMap(
                bodies: bodies, options: options(bodies, mode: mode, follows: follows)))
        var byKind: [PrimitiveKind: Set<String>] = [:]
        for hit in map.pickRegion(CGRect(x: 0, y: 0, width: size, height: size)) {
            byKind[hit.kind, default: []].insert(hit.bodyID)
        }
        return byKind
    }

    // MARK: The issue's table

    /// The kinds a box is picked as in each mode, as 1.3.2 reports them.
    ///
    /// The box has `edgeIndices` and, with `vertices`, its corners. Written out, not derived from
    /// `DisplayMode`.
    private static func following(_ mode: DisplayMode, vertices: Bool) -> Set<PrimitiveKind> {
        var kinds: Set<PrimitiveKind>
        switch mode {
        case .wireframe: kinds = [.edge]
        case .shaded, .flat, .unlit, .rendered: kinds = [.face]
        case .shadedWithEdges, .xray: kinds = [.edge, .face]
        }
        if vertices { kinds.insert(.vertex) }
        return kinds
    }

    @Test(
        "A box with edgeIndices: faces and edges by display mode as before, every kind with it off",
        arguments: DisplayMode.allCases, [false, true])
    func boxTable(mode: DisplayMode, vertices: Bool) throws {
        var box = pickableBox("box", size: 1.2)
        if !vertices {
            box.vertices = []
            box.vertexIndices = []
        }
        // Default: 1.3.2's table.
        let following = try Self.hits([box], mode: mode, follows: true)
        #expect(
            Set(following.keys) == Self.following(mode, vertices: vertices),
            "\(mode) following: \(following.keys)")
        // Opted out: faces and edges in every mode, vertices when the body has them.
        let free = try Self.hits([box], mode: mode, follows: false)
        let everything: Set<PrimitiveKind> = vertices ? [.edge, .face, .vertex] : [.edge, .face]
        #expect(Set(free.keys) == everything, "\(mode) free: \(free.keys)")
    }

    @Test(
        "An edge-only body is picked by its edges in every mode, either way",
        arguments: DisplayMode.allCases, [true, false])
    func wireBodyRow(mode: DisplayMode, follows: Bool) throws {
        let hits = try Self.hits([wireBody("wire", at: .zero)], mode: mode, follows: follows)
        #expect(Set(hits.keys) == [.edge], "\(mode), follows \(follows): \(hits.keys)")
        #expect(hits[.edge] == ["wire"])
    }

    // MARK: What each kind is on

    private static let arcScene = [
        pickableBox("box", at: SIMD3(-1.1, 0, 0)), meshArcBody("arcs", at: SIMD3(1.1, 0, 0)),
    ]

    @Test("Arcs of a mesh body follow the mode by default and are picked in every mode when off")
    func arcsOfAMeshBody() throws {
        let shaded = try Self.hits(Self.arcScene, mode: .shaded, follows: true)
        #expect(shaded[.edge] == nil, "no edge in .shaded: \(shaded[.edge] ?? [])")
        let free = try Self.hits(Self.arcScene, mode: .shaded, follows: false)
        #expect(free[.edge] == ["box", "arcs"], "\(free[.edge] ?? [])")
        let wire = try Self.hits(Self.arcScene, mode: .wireframe, follows: true)
        #expect(wire[.face] == nil, "no face in .wireframe: \(wire[.face] ?? [])")
        #expect(wire[.edge] == ["box", "arcs"], "\(wire[.edge] ?? [])")
        let wireFree = try Self.hits(Self.arcScene, mode: .wireframe, follows: false)
        #expect(wireFree[.face] == ["box", "arcs"], "\(wireFree[.face] ?? [])")
        #expect(wireFree[.edge] == ["box", "arcs"], "\(wireFree[.edge] ?? [])")
    }

    @Test("The setting changes nothing that is drawn: the live frame is the same pixel for pixel")
    func liveFrameUnchanged() throws {
        // Arcs of a mesh body are sampled for the pick when the setting is off, in `.shaded`
        // where the main pass must not draw them: those of a geometry body, and of an overlay one.
        var gizmo = meshArcBody("gizmo", at: SIMD3(0, 1.8, 0))
        gizmo.renderLayer = .overlay
        gizmo.pickLayer = .widget
        for scene in [Self.arcScene, Self.arcScene + [gizmo]] {
            try Self.expectSameLiveFrames(scene)
        }
    }

    /// Renders `scene` live with the setting on and off, in three modes, and expects equal frames.
    private static func expectSameLiveFrames(
        _ scene: [ViewportBody], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for mode in [DisplayMode.shaded, .wireframe, .shadedWithEdges] {
            var frames: [[UInt8]] = []
            for follows in [true, false] {
                var config = ViewportConfiguration()
                config.initialCameraState = camera(fitting: scene)
                config.backgroundColor = SIMD4(0, 0, 0, 1)
                config.showViewCube = false
                config.msaaSampleCount = 1
                config.pickingConfiguration = PickingConfiguration(
                    isEnabled: true, followsDisplayMode: follows)
                let controller = ViewportController(configuration: config)
                controller.displayMode = mode
                controller.showGrid = false
                controller.showAxes = false
                controller.enableTAA = false
                guard
                    let live = ViewportRenderer(controller: controller, bodies: .constant(scene))
                else {
                    Issue.record("Metal device unavailable; skipping")
                    return
                }
                frames.append(
                    try #require(
                        live.renderHeadlessBGRA(
                            width: size, height: size, backgroundColor: SIMD4(0, 0, 0, 1),
                            frameCount: 2),
                        sourceLocation: sourceLocation))
            }
            #expect(
                frames[0] == frames[1], "\(mode) draws differently with the setting off",
                sourceLocation: sourceLocation)
        }
    }

    @Test("Overlay bodies: their edges are written in every mode when the setting is off")
    func overlayBodies() throws {
        var widget = pickableBox("widget", size: 0.8)
        widget.renderLayer = .overlay
        widget.pickLayer = .widget
        widget.transform = translation(0, 0, -1)
        var arcs = meshArcBody("ring", at: SIMD3(1.5, 0, 0))
        arcs.renderLayer = .overlay
        arcs.pickLayer = .widget
        let scene = [pickableBox("a", size: 1.6), widget, arcs]
        let following = try Self.hits(scene, mode: .shaded, follows: true)
        #expect(following[.face]?.isSuperset(of: ["widget", "ring"]) == true)
        #expect(following[.vertex]?.contains("widget") == true)
        #expect(following[.edge] == nil, "\(following[.edge] ?? []) .shaded hides mesh edges")
        let free = try Self.hits(scene, mode: .shaded, follows: false)
        #expect(free[.edge]?.isSuperset(of: ["widget", "ring"]) == true, "\(free[.edge] ?? [])")
        // Faces are the overlay's in every mode, either way.
        let wire = try Self.hits(scene, mode: .wireframe, follows: true)
        #expect(wire[.face]?.isSuperset(of: ["widget", "ring"]) == true, "\(wire[.face] ?? [])")
    }

    // MARK: The live pick agrees

    @Test(
        "The live pick equals the offscreen one under both settings",
        arguments: [DisplayMode.shaded, .wireframe, .xray], [true, false])
    func liveEqualsOffscreen(mode: DisplayMode, follows: Bool) async throws {
        let rig = try PickParityRig(
            bodies: Self.arcScene + [wireBody("wire", at: SIMD3(0, 1.8, 0))], displayMode: mode,
            followsDisplayMode: follows)
        let result = await rig.compare(step: 3)
        rig.expectParity(result, minimumHits: 40)
        let kinds = result.bodiesByKind
        #expect((kinds[.face] != nil) == (!follows || mode != .wireframe), "\(mode) faces")
        #expect(
            (kinds[.edge]?.contains("box") == true) == (!follows || mode != .shaded),
            "\(mode) edges of the box")
        #expect(kinds[.edge]?.contains("wire") == true, "the wire body is picked in every mode")
    }

    @Test(
        "Direct-mesh bodies are picked like interleaved ones, live and offscreen",
        arguments: [DisplayMode.shaded, .wireframe], [true, false])
    func directMeshBodies(mode: DisplayMode, follows: Bool) async throws {
        let rig = try PickParityRig(
            bodies: [
                directBoxBody("d1", at: SIMD3(-1.1, 0, 0)),
                directBoxBody("d2", at: SIMD3(1.1, 0, 0)),
            ], displayMode: mode, followsDisplayMode: follows)
        let result = await rig.compare(step: 3)
        rig.expectParity(result, minimumHits: 20)
        // A direct-mesh body derives its vertices, which are picked in every mode.
        let expected: Set<PrimitiveKind>
        if follows {
            expected = mode == .wireframe ? [.edge, .vertex] : [.face, .vertex]
        } else {
            expected = [.edge, .face, .vertex]
        }
        #expect(result.kinds == expected, "\(mode), follows \(follows): \(result.kinds)")
    }

    @Test(
        "Tessellated and mesh-shader surfaces are picked in .wireframe only when the setting is off",
        arguments: [RenderingQuality.enhanced, .maximum], [true, false])
    func refinedSurfaces(quality: RenderingQuality, follows: Bool) async throws {
        let rig = try PickParityRig(
            bodies: [
                ViewportBody.sphere(id: "ball", radius: 0.8, segments: 16, rings: 10),
                pickableBox("a", at: SIMD3(1.7, 0, 0)),
            ], displayMode: .wireframe, quality: quality, followsDisplayMode: follows)
        if quality == .enhanced {
            guard rig.live.tessellatedPickPipeline != nil else { return }
            #expect(rig.offscreen.surfacePaths(for: rig.options).tessellation)
        } else {
            guard rig.live.meshShaderPickPipeline != nil else { return }
            #expect(rig.offscreen.surfacePaths(for: rig.options).meshShaders)
        }
        let result = await rig.compare(step: 3)
        rig.expectParity(result, minimumHits: 20)
        #expect(result.bodiesByKind[.face] == (follows ? nil : ["ball", "a"]), "\(quality)")
        #expect(result.bodiesByKind[.edge] == ["a"], "\(quality)")
    }

    @Test("A region pick agrees too, with a selection filter narrowing to one kind")
    func filterNarrowsToOneKind() async throws {
        let scene = Self.arcScene
        // Wireframe, faces only: faces are picked although the mode draws none.
        let faces = try PickParityRig(
            bodies: scene, displayMode: .wireframe, pickRadius: 0, followsDisplayMode: false,
            filter: .faces)
        let faceHits = await faces.compare(step: 3)
        faces.expectParity(faceHits, minimumHits: 30)
        #expect(faceHits.userKinds == [.face], "\(faceHits.userKinds)")
        // Shaded, edges only: edges are picked although the mode hides them.
        let edges = try PickParityRig(
            bodies: scene, displayMode: .shaded, pickRadius: 2, followsDisplayMode: false,
            filter: .edges)
        let edgeHits = await edges.compare(step: 2)
        edges.expectParity(edgeHits, minimumHits: 10)
        #expect(edgeHits.userKinds == [.edge], "\(edgeHits.userKinds)")
        // The same filter and mode with the default setting finds nothing: the filter cannot
        // make a hidden kind appear.
        let hidden = try PickParityRig(
            bodies: [pickableBox("a"), meshArcBody("m", at: SIMD3(1.5, 0, 0))],
            displayMode: .shaded, pickRadius: 2, filter: .edges)
        let none = await hidden.compare(step: 3)
        #expect(none.hits == 0, "\(none.hits) edge hits in .shaded with the default setting")
    }

    @Test("Clip planes and body transforms apply with the setting off")
    func clipPlanesAndTransforms() async throws {
        var turned = ViewportBody.sphere(id: "turned", radius: 0.7, color: SIMD4(0.9, 0.5, 0.2, 1))
        turned.transform =
            translation(1.8, 0, 0)
            * simd_float4x4(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 1, 0))))
        let scene = [
            pickableBox("a", at: SIMD3(-1.6, 0, 0)), turned,
            pickableBox("b", at: SIMD3(0.2, 0.3, -1.6)),
        ]
        let open = try PickParityRig(
            bodies: scene, displayMode: .wireframe, followsDisplayMode: false)
        let all = await open.compare(step: 3)
        open.expectParity(all)
        #expect(all.bodiesByKind[.face] == ["a", "turned", "b"], "\(all.bodiesByKind)")
        // Keep x > 0.1: "a" is cut away from every kind, "b" and the sphere survive.
        let clipped = try PickParityRig(
            bodies: scene, displayMode: .wireframe, followsDisplayMode: false,
            clipPlanes: [ClipPlane(normal: SIMD3(1, 0, 0), distance: -0.1)])
        let cut = await clipped.compare(step: 3)
        clipped.expectParity(cut, minimumHits: 20)
        #expect(!cut.bodyIDs.contains("a"), "\(cut.bodyIDs)")
        #expect(cut.bodiesByKind[.face]?.contains("turned") == true)
    }

    // MARK: Heightfields

    @Test("A heightfield in .wireframe: the lattice lines by default, its whole surface when off")
    func heightfieldInWireframe() async throws {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            return
        }
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        var options = LatticeScene.options(LatticeSetup())
        options.pickRadius = 0
        let onLine = SIMD2(87, 80)
        let gaps = [SIMD2(78, 80), SIMD2(62, 62), SIMD2(95, 95)]

        // Default: a line is picked, a gap is not.
        #expect(renderer.performPick(bodies: bodies, at: onLine, options: options) != nil)
        for gap in gaps {
            #expect(
                renderer.performPick(bodies: bodies, at: gap, options: options) == nil,
                "\(gap) picked between the lines")
        }

        // Off: the surface, so the gaps pick the cell under them, as .shaded does.
        var free = options
        free.pickFollowsDisplayMode = false
        var shaded = options
        shaded.displayMode = .shaded
        for pixel in gaps + [onLine] {
            let hit = try #require(
                renderer.performPick(bodies: bodies, at: pixel, options: free),
                "\(pixel) missed with the setting off")
            #expect(hit.kind == .face)
            let cell = try #require(hit.heightfield)
            let expected = HeightfieldLatticeTests.cell(atPixel: pixel)
            #expect(
                abs(cell.cell.x - expected.x) <= 1 && cell.cell.y == expected.y,
                "\(cell.cell) vs \(expected)")
            #expect(hit.triangleIndex == cell.cellIndex)
            #expect(hit == renderer.performPick(bodies: bodies, at: pixel, options: shaded))
        }

        // A field in another mode is unchanged by the setting.
        for mode in [DisplayMode.shaded, .shadedWithEdges, .xray] {
            var a = options
            a.displayMode = mode
            var b = a
            b.pickFollowsDisplayMode = false
            let one = try #require(renderer.renderPickMap(bodies: bodies, options: a))
            let two = try #require(renderer.renderPickMap(bodies: bodies, options: b))
            let full = CGRect(x: 0, y: 0, width: 160, height: 160)
            #expect(one.pickRegion(full) == two.pickRegion(full), "\(mode)")
            #expect(one.pick(at: gaps[0]) == two.pick(at: gaps[0]), "\(mode)")
        }
    }

    @Test("The live pick of a heightfield in .wireframe equals the offscreen one, both settings")
    func heightfieldLive() async throws {
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        guard let renderer = OffscreenRenderer() else { return }
        for follows in [true, false] {
            let rig = try HeightfieldPickRig(
                bodies: bodies, camera: LatticeScene.topDown, width: LatticeScene.size,
                height: LatticeScene.size, sampleCount: 1, followsDisplayMode: follows)
            rig.controller.displayMode = .wireframe
            _ = try #require(
                rig.renderer.renderHeadlessBGRA(
                    width: LatticeScene.size, height: LatticeScene.size,
                    backgroundColor: HeightfieldScene.background))
            var options = LatticeScene.options(LatticeSetup())
            options.pickRadius = 0
            options.pickFollowsDisplayMode = follows
            for pixel in [SIMD2(87, 80), SIMD2(78, 80), SIMD2(62, 62), SIMD2(100, 60)] {
                let live = await rig.pick(pixel)
                let offscreen = renderer.performPick(bodies: bodies, at: pixel, options: options)
                #expect(live == offscreen, "follows \(follows) at \(pixel)")
                if !follows { #expect(live != nil, "the surface is picked at \(pixel)") }
            }
        }
    }

    // MARK: The policy and the API

    @Test("PickStampRules is the table: 7 modes, both settings, with and without a mesh")
    func stampRules() {
        for mode in DisplayMode.allCases {
            let following = PickStampRules(displayMode: mode, followsDisplayMode: true)
            let free = PickStampRules(displayMode: mode, followsDisplayMode: false)
            #expect(following.stampsSurfaces == (mode != .wireframe), "\(mode)")
            #expect(free.stampsSurfaces, "\(mode)")
            for hasMesh in [true, false] {
                let drawn = !hasMesh || [.wireframe, .shadedWithEdges, .xray].contains(mode)
                #expect(following.stampsEdges(bodyHasMesh: hasMesh) == drawn, "\(mode) \(hasMesh)")
                #expect(free.stampsEdges(bodyHasMesh: hasMesh), "\(mode) \(hasMesh)")
            }
            #expect(following.stampsHeightfieldLattice == (mode == .wireframe), "\(mode)")
            #expect(!free.stampsHeightfieldLattice, "\(mode)")
            #expect(!following.samplesHiddenArcs, "\(mode)")
            #expect(free.samplesHiddenArcs, "\(mode)")
        }
    }

    @Test("A sampled arc is stamped if it is drawn, or whatever the mode when the setting is off")
    func arcStampRule() {
        func arc(drawn: Bool) -> RendererSharedBuffers.SampledArcDraw {
            RendererSharedBuffers.SampledArcDraw(
                body: meshArcBody("m", at: .zero), objectIndex: 0, arcIndex: 0, start: 0, count: 2,
                quadStart: 0, quadCount: 0, isDrawn: drawn)
        }
        for mode in DisplayMode.allCases {
            let following = PickStampRules(displayMode: mode, followsDisplayMode: true)
            let free = PickStampRules(displayMode: mode, followsDisplayMode: false)
            #expect(following.stampsArc(arc(drawn: true)), "\(mode)")
            #expect(!following.stampsArc(arc(drawn: false)), "\(mode)")
            #expect(free.stampsArc(arc(drawn: true)), "\(mode)")
            #expect(free.stampsArc(arc(drawn: false)), "\(mode)")
        }
    }

    @Test("sampleArcs flags the arcs a mode hides, and samples them only when asked")
    func sampledArcFlags() {
        let mesh = meshArcBody("mesh", at: .zero)
        let edgeOnly = meshArcBody("edgeOnly", at: .zero)
        let bodies: [(body: ViewportBody, objectIndex: UInt32, hasMesh: Bool)] = [
            (mesh, 0, true), (edgeOnly, 1, false),
        ]
        func sample(_ mode: DisplayMode, hidden: Bool) -> [RendererSharedBuffers.SampledArcDraw] {
            RendererSharedBuffers.sampleArcs(
                bodies: bodies, displayMode: mode, viewProjection: matrix_identity_float4x4,
                viewportSize: SIMD2(100, 100), quadExpansion: false, includeHidden: hidden
            ).draws
        }
        // `.shaded` draws a mesh body's arcs never and an edge-only body's always.
        #expect(Set(sample(.shaded, hidden: false).map(\.body.id)) == ["edgeOnly"])
        let all = sample(.shaded, hidden: true)
        #expect(Set(all.map(\.body.id)) == ["mesh", "edgeOnly"])
        #expect(all.filter { $0.body.id == "mesh" }.allSatisfy { !$0.isDrawn })
        #expect(all.filter { $0.body.id == "edgeOnly" }.allSatisfy { $0.isDrawn })
        // A body the pick skips (not pickable) has no hidden arcs sampled for it.
        var unpickable = meshArcBody("unpickable", at: .zero)
        unpickable.isPickable = false
        let withUnpickable = RendererSharedBuffers.sampleArcs(
            bodies: [(unpickable, 0, true)], displayMode: .shaded,
            viewProjection: matrix_identity_float4x4, viewportSize: SIMD2(100, 100),
            quadExpansion: false, includeHidden: true)
        #expect(withUnpickable.draws.isEmpty)
        // `.wireframe` draws every arc, so nothing is hidden.
        let wire = sample(.wireframe, hidden: true)
        #expect(Set(wire.map(\.body.id)) == ["mesh", "edgeOnly"] && wire.allSatisfy { $0.isDrawn })
        #expect(sample(.wireframe, hidden: false).count == wire.count)
    }

    @Test("followsDisplayMode defaults to true, is settable, and reaches the offscreen options")
    func settingPlumbing() {
        #expect(PickingConfiguration().followsDisplayMode)
        #expect(PickingConfiguration(isEnabled: true, pickRadius: 3).followsDisplayMode)
        let off = PickingConfiguration(isEnabled: true, pickRadius: 3, followsDisplayMode: false)
        #expect(!off.followsDisplayMode && off.pickRadius == 3 && off.isEnabled)
        var config = ViewportConfiguration()
        #expect(config.pickingConfiguration.followsDisplayMode)
        config.pickingConfiguration.followsDisplayMode = false
        #expect(!config.pickingConfiguration.followsDisplayMode)

        #expect(OffscreenRenderOptions().pickFollowsDisplayMode)
        #expect(!OffscreenRenderOptions(pickFollowsDisplayMode: false).pickFollowsDisplayMode)
        let controller = ViewportController(configuration: config)
        let matching = OffscreenRenderOptions(matching: controller, width: 32, height: 32)
        #expect(!matching.pickFollowsDisplayMode)
        let defaults = OffscreenRenderOptions(
            matching: ViewportController(configuration: ViewportConfiguration()), width: 32,
            height: 32)
        #expect(defaults.pickFollowsDisplayMode)
    }
}
