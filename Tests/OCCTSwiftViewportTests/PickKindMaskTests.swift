// PickKindMaskTests.swift
// OCCTSwiftViewport Tests
//
// `PickingConfiguration.pickableKinds` and `OffscreenRenderOptions.pickableKinds` (issue #260): a
// kind mask applied inside the pick pass and in the `pickRadius` neighbourhood choice, so a kind the
// app does not want is never stamped and never wins a pixel. These pin that every kind outside the
// mask is gone from the frame exactly as if the body did not carry it, that a face outside the mask
// still hides what is behind it where the mode draws surfaces, the acceptance case (a face-only mask
// returns the face under an edge band or a vertex square), the neighbourhood choice, the widget
// layer's bypass, that the live and the headless pick agree, and that the default (every kind) is
// the pick pass as it was.

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

private let allKinds = Set(PrimitiveKind.allCases)

/// Every subset of the three kinds, the empty one included.
private let everyMask: [Set<PrimitiveKind>] = [
    [], [.face], [.edge], [.vertex], [.face, .edge], [.face, .vertex], [.edge, .vertex],
    [.face, .edge, .vertex],
]

/// A mesh body (a box) that carries analytic arcs on its +Z face and no `edgeIndices`.
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

/// `body` as if it did not carry the kinds outside `kinds`.
///
/// No edges and arcs, no vertices. A body always carries faces, which a mask hides by blanking
/// them, so they are left.
private func stripped(_ body: ViewportBody, keeping kinds: Set<PrimitiveKind>) -> ViewportBody {
    var body = body
    if !kinds.contains(.edge) {
        body.edgeIndices = []
        body.arcs = []
    }
    if !kinds.contains(.vertex) {
        body.vertices = []
        body.vertexIndices = []
    }
    return body
}

/// `body` with no surface mesh at all, as an edge-and-vertex body.
private func withoutSurface(_ body: ViewportBody) -> ViewportBody {
    var wire = ViewportBody(
        id: body.id, vertexData: [], indices: [], edges: body.edges, arcs: body.arcs,
        color: body.color)
    wire.edgeIndices = body.edgeIndices
    wire.vertices = body.vertices
    wire.vertexIndices = body.vertexIndices
    wire.transform = body.transform
    return wire
}

@MainActor
@Suite("Pick kind mask (#260)")
struct PickKindMaskTests {

    // MARK: Headless helpers

    private static let size = 160

    /// Two overlapping boxes, so some of one's vertices and edges lie behind the other's faces,
    /// and a mesh body carrying arcs; every kind is on screen and something occludes something.
    private static func scene() -> [ViewportBody] {
        [
            pickableBox("a", at: SIMD3(-0.7, 0, 0)),
            pickableBox("b", at: SIMD3(0.6, 0.1, 0.5)),
            meshArcBody("m", at: SIMD3(0, 1.9, 0)),
        ]
    }

    private static func camera(fitting bodies: [ViewportBody]) -> CameraState {
        var camera = CameraState()
        camera.rotation =
            simd_quatf(angle: 0.6, axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -0.35, axis: SIMD3(1, 0, 0))
        if let fitted = camera.fit(to: bodies, aspectRatio: 1, padding: 1.25) { camera = fitted }
        return camera
    }

    private static func options(
        _ bodies: [ViewportBody], mode: DisplayMode, follows: Bool = true,
        kinds: Set<PrimitiveKind> = allKinds, radius: Int = 0
    ) -> OffscreenRenderOptions {
        var options = OffscreenRenderOptions(
            width: size, height: size, cameraState: camera(fitting: bodies), displayMode: mode,
            backgroundColor: SIMD4(0, 0, 0, 1), appearance: .light, showGrid: false,
            showAxes: false, msaaSampleCount: 1)
        options.edgeLineConfiguration = EdgeLineConfiguration(width: 4)
        options.pickFollowsDisplayMode = follows
        options.pickableKinds = kinds
        options.pickRadius = radius
        return options
    }

    private static func renderer() throws -> OffscreenRenderer {
        guard let renderer = OffscreenRenderer() else {
            Issue.record("Metal device unavailable; skipping")
            throw RigUnavailable()
        }
        return renderer
    }

    private static func map(
        _ renderer: OffscreenRenderer, _ bodies: [ViewportBody], _ options: OffscreenRenderOptions
    ) throws -> OffscreenPickMap {
        try #require(renderer.renderPickMap(bodies: bodies, options: options))
    }

    /// The kind of each texel, `nil` for background.
    private static func kinds(of texels: [UInt64]) -> [PrimitiveKind?] {
        texels.map { PickEncoding.decode($0)?.kind }
    }

    private static func count(_ kind: PrimitiveKind, in texels: [UInt64]) -> Int {
        kinds(of: texels).filter { $0 == kind }.count
    }

    private static let fullFrame = CGRect(x: 0, y: 0, width: size, height: size)

    // MARK: The pass writes exactly the kinds in the mask

    /// The frame a body that did not carry the kinds outside `kinds` gives, with the faces blanked
    /// if `kinds` leaves them out: a face outside the mask is stamped as an occluder, so it hides
    /// what is behind it and picks as a miss.
    private static func expectedTexels(
        _ renderer: OffscreenRenderer, _ bodies: [ViewportBody], mode: DisplayMode, follows: Bool,
        kinds: Set<PrimitiveKind>
    ) throws -> [UInt64] {
        let reduced = bodies.map { stripped($0, keeping: kinds) }
        let all = try map(renderer, reduced, options(bodies, mode: mode, follows: follows))
        return all.texels.map { texel in
            guard let decoded = PickEncoding.decode(texel), kinds.contains(decoded.kind)
            else { return PickEncoding.noHit }
            return texel
        }
    }

    @Test(
        "Every mask gives the frame of a body without the other kinds, in every mode and setting",
        arguments: DisplayMode.allCases, [true, false])
    func maskEqualsAbsence(mode: DisplayMode, follows: Bool) throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        for kinds in everyMask {
            // With the setting off, a face outside the mask in `.wireframe` has nothing to hide
            // behind: the mode draws no surface, so the edges and vertices behind it stay pickable.
            // That is `wireframeFaceFreeMask` below, not an absent kind.
            if !follows && !mode.showsSurfaces && !kinds.contains(.face) { continue }
            let masked = try Self.map(
                renderer, bodies, Self.options(bodies, mode: mode, follows: follows, kinds: kinds))
            let expected = try Self.expectedTexels(
                renderer, bodies, mode: mode, follows: follows, kinds: kinds)
            let differing = zip(masked.texels, expected).filter { $0 != $1 }.count
            #expect(
                masked.texels == expected,
                "\(mode), follows \(follows), \(kinds): \(differing) of \(expected.count) differ")
            // Non-vacuous: the kinds in the mask that the setting stamps are on screen.
            let present = Set(Self.kinds(of: masked.texels).compactMap { $0 })
            #expect(present.isSubset(of: kinds), "\(mode), \(follows), \(kinds): \(present)")
        }
    }

    @Test("The kinds a mask leaves on screen are the mask's, in the mode's table")
    func kindsOnScreen() throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        for kinds in everyMask {
            // Opted out of the display mode, `.shaded` stamps every kind it is given.
            let shaded = try Self.map(
                renderer, bodies,
                Self.options(bodies, mode: .shaded, follows: false, kinds: kinds))
            let present = Set(Self.kinds(of: shaded.texels).compactMap { $0 })
            #expect(present == kinds, "shaded, opted out, \(kinds): \(present)")
        }
        // Following the mode, `.shaded` writes faces and vertices, `.wireframe` edges and vertices.
        for (mode, shown) in [
            (DisplayMode.shaded, Set<PrimitiveKind>([.face, .vertex])),
            (.shadedWithEdges, [.face, .edge, .vertex]), (.wireframe, [.edge, .vertex]),
        ] {
            for kinds in everyMask {
                let found = try Self.map(
                    renderer, bodies, Self.options(bodies, mode: mode, kinds: kinds))
                let present = Set(Self.kinds(of: found.texels).compactMap { $0 })
                #expect(present == kinds.intersection(shown), "\(mode), \(kinds): \(present)")
            }
        }
    }

    // MARK: The acceptance case

    /// The frame of `bodies` with their edges, arcs and vertices removed: what is under an edge
    /// band or a vertex square once those kinds are gone.
    private static func faceReference(
        _ renderer: OffscreenRenderer, _ bodies: [ViewportBody], mode: DisplayMode, radius: Int = 0
    ) throws -> OffscreenPickMap {
        try map(
            renderer, bodies.map { stripped($0, keeping: [.face]) },
            options(bodies, mode: mode, follows: false, radius: radius))
    }

    @Test(
        "A faces-only mask returns the face under an edge band or a vertex square",
        arguments: [DisplayMode.shaded, .shadedWithEdges, .flat, .xray], [false, true])
    func facesOnlyReturnsTheFaceUnderneath(mode: DisplayMode, follows: Bool) throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        // Opted out of the display mode every kind is written in every mode; `follows` on is
        // exercised too, where `.shadedWithEdges` and `.xray` write edges and `.shaded` does not.
        let everything = try Self.map(
            renderer, bodies, Self.options(bodies, mode: mode, follows: false))
        let facesOnly = try Self.map(
            renderer, bodies,
            Self.options(bodies, mode: mode, follows: follows, kinds: [.face]))
        let reference = try Self.faceReference(renderer, bodies, mode: mode)
        var filtered = Self.options(bodies, mode: mode, follows: false)
        filtered.selectionFilter = .faces
        let byFilter = try Self.map(renderer, bodies, filtered)

        var edgePixels = 0
        var vertexPixels = 0
        var filterLostTheFace = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size {
                let pixel = SIMD2(x, y)
                guard let was = everything.pick(at: pixel), was.kind != .face else { continue }
                // What is under it: the face, or nothing where the band hangs off a silhouette.
                let underneath = reference.pick(at: pixel)
                let now = facesOnly.pick(at: pixel)
                #expect(now == underneath, "\(mode) \(pixel): \(String(describing: now))")
                guard underneath != nil else { continue }
                #expect(now?.kind == .face, "\(mode) \(pixel)")
                if was.kind == .edge { edgePixels += 1 } else { vertexPixels += 1 }
                // As the selection filter alone does it today: the pixel is a miss.
                if byFilter.pick(at: pixel) == nil { filterLostTheFace += 1 }
            }
        }
        // Not vacuous: the frame has edge bands and vertex squares over faces to land on.
        #expect(edgePixels > 100, "\(mode): only \(edgePixels) edge pixels over a face")
        #expect(vertexPixels > 20, "\(mode): only \(vertexPixels) vertex pixels over a face")
        #expect(
            filterLostTheFace == edgePixels + vertexPixels,
            "\(mode): the filter alone kept some of the \(edgePixels + vertexPixels) pixels")
    }

    @Test("Acceptance, as the issue words it: .shaded, followsDisplayMode off, a faces-only mask")
    func acceptance() throws {
        let renderer = try Self.renderer()
        let bodies = [pickableBox("box", size: 1.6)]
        let options = Self.options(bodies, mode: .shaded, follows: false, kinds: [.face])
        let map = try Self.map(renderer, bodies, options)
        let all = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .shaded, follows: false))
        let reference = try Self.faceReference(renderer, bodies, mode: .shaded)
        // A vertex square and an edge band over the box's faces, found in the unmasked frame.
        func first(_ kind: PrimitiveKind) -> SIMD2<Int>? {
            for index in 0..<(Self.size * Self.size) {
                let pixel = SIMD2(index % Self.size, index / Self.size)
                if all.pick(at: pixel)?.kind == kind, reference.pick(at: pixel) != nil {
                    return pixel
                }
            }
            return nil
        }
        for kind in [PrimitiveKind.vertex, .edge] {
            let pixel = try #require(first(kind), "no \(kind) pixel over a face")
            let now = try #require(map.pick(at: pixel), "\(pixel) is a miss")
            #expect(now.kind == .face && now.bodyID == "box", "\(pixel): \(now)")
            #expect(now == reference.pick(at: pixel))
            // The face is a triangle of the box.
            #expect(now.triangleIndex < bodies[0].indices.count / 3)
        }
    }

    // MARK: A face outside the mask still hides what is behind it

    @Test("A face outside the mask hides what is behind it where the mode draws surfaces")
    func facesOutsideTheMaskStillOccludeInShaded() throws {
        let renderer = try Self.renderer()
        // A small box inside a big one: every corner and edge of the small one is behind a face of
        // the big one, from any side.
        let bodies = [pickableBox("front", size: 3), pickableBox("back", size: 0.8)]
        for follows in [true, false] {
            let vertices = try Self.map(
                renderer, bodies,
                Self.options(bodies, mode: .shaded, follows: follows, kinds: [.vertex]))
            // `back`'s vertices lie inside `front`: none can be picked, although no face is.
            let hits = vertices.pickRegion(Self.fullFrame)
            #expect(!hits.isEmpty, "follows \(follows): front's own vertices are picked")
            #expect(
                hits.allSatisfy { $0.bodyID == "front" },
                "follows \(follows): \(hits.map(\.bodyID))")
        }
        // In .wireframe nothing is drawn over `back`, so it is picked (the setting off, so the
        // faces that would hide it are the ones the mask leaves out).
        let wire = try Self.map(
            renderer, bodies,
            Self.options(bodies, mode: .wireframe, follows: false, kinds: [.edge, .vertex]))
        #expect(Set(wire.pickRegion(Self.fullFrame).map(\.bodyID)) == ["front", "back"])
        // With the faces in the mask, `front`'s faces hide `back` there, as the issue's table says.
        let withFaces = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .wireframe, follows: false))
        #expect(
            withFaces.pickRegion(Self.fullFrame).filter { $0.kind != .face }.allSatisfy {
                $0.bodyID == "front"
            })
    }

    @Test("A face outside the mask in .wireframe: the frame of a body with no surface")
    func wireframeFaceFreeMask() throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        let wireOnly = bodies.map(withoutSurface)
        for follows in [true, false] {
            for kinds in everyMask where !kinds.contains(.face) {
                let masked = try Self.map(
                    renderer, bodies,
                    Self.options(bodies, mode: .wireframe, follows: follows, kinds: kinds))
                let reference = Self.options(bodies, mode: .wireframe, follows: follows)
                let expected = try Self.map(
                    renderer, wireOnly.map { stripped($0, keeping: kinds) }, reference)
                #expect(
                    masked.texels == expected.texels,
                    "follows \(follows), \(kinds): the frame is not a surface-free one")
            }
        }
    }

    // MARK: The pickRadius neighbourhood

    private static let names: [Int: String] = [0: "a", 1: "b", 2: "w"]

    private static func texel(_ kind: PrimitiveKind, body: UInt32, _ primitive: UInt32) -> UInt64 {
        PickEncoding.encode(objectIndex: body, primitiveIndex: primitive, kind: kind)
    }

    private static func choose(
        _ values: [UInt64], kinds: Set<PrimitiveKind>, layers: [String: PickLayer] = [:]
    ) -> PickResult? {
        ViewportRenderer.bestNeighborhoodPickResult(
            values, width: 3, center: SIMD2(1, 1), indexMap: names, layerMap: layers,
            pickableKinds: kinds)
    }

    @Test("The neighbourhood choice only considers the kinds in the mask")
    func neighbourhoodChoice() {
        // A vertex, an edge and a face in reach of the cursor; the vertex is farthest.
        let values = [
            Self.texel(.vertex, body: 0, 7), PickEncoding.noHit, PickEncoding.noHit,
            PickEncoding.noHit, Self.texel(.edge, body: 0, 3), PickEncoding.noHit,
            PickEncoding.noHit, PickEncoding.noHit, Self.texel(.face, body: 0, 1),
        ]
        #expect(Self.choose(values, kinds: allKinds)?.kind == .vertex)
        #expect(Self.choose(values, kinds: [.face, .edge])?.kind == .edge)
        #expect(Self.choose(values, kinds: [.face, .vertex])?.kind == .vertex)
        #expect(Self.choose(values, kinds: [.face])?.kind == .face)
        #expect(Self.choose(values, kinds: [.face])?.triangleIndex == 1)
        #expect(Self.choose(values, kinds: [.edge])?.triangleIndex == 3)
        // Nothing in the mask in reach: a miss, not the nearest other kind.
        #expect(Self.choose(values, kinds: []) == nil)
        let noFace = Array(values.dropLast()) + [PickEncoding.noHit]
        #expect(Self.choose(noFace, kinds: [.face]) == nil)
        // The default argument is every kind.
        #expect(
            ViewportRenderer.bestNeighborhoodPickResult(
                values, width: 3, center: SIMD2(1, 1), indexMap: Self.names, layerMap: [:])?.kind
                == .vertex)
    }

    @Test("A widget-layer hit in the neighbourhood ignores the mask, as it ignores the filter")
    func neighbourhoodWidget() {
        let values = [
            Self.texel(.vertex, body: 2, 4), PickEncoding.noHit, PickEncoding.noHit,
            PickEncoding.noHit, PickEncoding.noHit, PickEncoding.noHit,
            PickEncoding.noHit, PickEncoding.noHit, Self.texel(.face, body: 0, 1),
        ]
        let hit = Self.choose(values, kinds: [.face], layers: ["w": .widget])
        #expect(hit?.kind == .vertex && hit?.bodyID == "w")
        // The same texel on a user-geometry body is dropped.
        #expect(Self.choose(values, kinds: [.face])?.kind == .face)
    }

    @Test("A pick map reads its neighbourhood among its kinds, whatever its texels hold")
    func mapChoosesAmongItsKinds() throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        let all = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .shadedWithEdges, radius: 4))
        // The same texels, read for a mask that is narrower than what they were drawn with: the
        // neighbourhood choice has to leave the other kinds out itself.
        func reading(_ kinds: Set<PrimitiveKind>) -> OffscreenPickMap {
            OffscreenPickMap(
                width: all.width, height: all.height, pickRadius: all.pickRadius,
                pickableKinds: kinds, selectionFilter: nil, texels: all.texels,
                indexMap: all.indexMap, layerMap: all.layerMap, heightfields: all.heightfields)
        }
        var seen: [Set<PrimitiveKind>: Set<PrimitiveKind>] = [:]
        for kinds in everyMask where !kinds.isEmpty {
            let map = reading(kinds)
            for y in stride(from: 0, to: Self.size, by: 3) {
                for x in stride(from: 0, to: Self.size, by: 3) {
                    guard let hit = map.pick(at: SIMD2(x, y)) else { continue }
                    seen[kinds, default: []].insert(hit.kind)
                }
            }
        }
        for kinds in everyMask where !kinds.isEmpty {
            #expect(seen[kinds, default: []].isSubset(of: kinds), "\(kinds): \(seen[kinds] ?? [])")
        }
        #expect(
            seen[allKinds] == allKinds, "the unmasked read is not vacuous: \(seen[allKinds] ?? [])")
        #expect(seen[[.face]] == [.face])
        #expect(reading([]).pick(at: SIMD2(80, 80)) == nil)
    }

    @Test("pickRadius with a mask: a pixel beside an edge or a vertex picks the face, not nothing")
    func radiusWithAMask() throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        let radius = 3
        let unmasked = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .shaded, follows: false, radius: radius))
        let masked = try Self.map(
            renderer, bodies,
            Self.options(bodies, mode: .shaded, follows: false, kinds: [.face], radius: radius))
        // What the neighbourhood holds once the other kinds are gone from the scene.
        let reference = try Self.faceReference(renderer, bodies, mode: .shaded, radius: radius)
        var whereTheMaskMatters = 0
        for y in stride(from: 0, to: Self.size, by: 2) {
            for x in stride(from: 0, to: Self.size, by: 2) {
                let pixel = SIMD2(x, y)
                let now = masked.pick(at: pixel)
                #expect(now == reference.pick(at: pixel), "\(pixel)")
                if let now { #expect(now.kind == .face, "\(pixel): \(now.kind)") }
                if let was = unmasked.pick(at: pixel), was.kind != .face, now != nil {
                    whereTheMaskMatters += 1
                }
            }
        }
        #expect(
            whereTheMaskMatters > 200, "only \(whereTheMaskMatters) pixels had a face to fall to")
    }

    // MARK: Widgets

    @Test("A widget-layer body ignores the mask, as it ignores the selection filter")
    func widgetsIgnoreTheMask() throws {
        var gizmo = pickableBox("gizmo", size: 0.7)
        gizmo.renderLayer = .overlay
        gizmo.pickLayer = .widget
        gizmo.transform = translation(0, 0, -1.2)
        let bodies = [pickableBox("a", size: 1.8), gizmo]
        let renderer = try Self.renderer()
        let map = try Self.map(
            renderer, bodies,
            Self.options(bodies, mode: .shaded, follows: false, kinds: [.face]))
        let hits = map.pickRegion(Self.fullFrame)
        let user = Set(hits.filter { $0.pickLayer == .userGeometry }.map(\.kind))
        let widget = Set(hits.filter { $0.pickLayer == .widget }.map(\.kind))
        #expect(user == [.face], "\(user)")
        #expect(widget == [.face, .edge, .vertex], "\(widget)")
        // Empty mask: the user's geometry is gone, the widget is not.
        let none = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .shaded, follows: false, kinds: []))
        #expect(none.pickRegion(Self.fullFrame).allSatisfy { $0.pickLayer == .widget })
        #expect(!none.pickRegion(Self.fullFrame).isEmpty)
    }

    @Test("The mask is kinds only: the selection filter still decides bodies, after it")
    func filterStillApplies() throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        var options = Self.options(bodies, mode: .shaded, follows: false, kinds: [.face, .vertex])
        options.selectionFilter = .excludingBodyIDs(["b"])
        let map = try Self.map(renderer, bodies, options)
        let hits = map.pickRegion(Self.fullFrame)
        #expect(Set(hits.map(\.kind)) == [.face, .vertex])
        #expect(Set(hits.map(\.bodyID)) == ["a", "m"])
    }

    // MARK: The live pick agrees

    /// One configuration of the live-versus-offscreen comparison.
    struct LiveCase: Sendable, CustomTestStringConvertible {
        var mode: DisplayMode
        var follows: Bool
        var kinds: Set<PrimitiveKind>
        var radius: Int

        var testDescription: String {
            "\(mode), follows \(follows), \(kinds.map(\.rawValue).sorted()), radius \(radius)"
        }
    }

    @Test(
        "The live pick equals the offscreen one under a mask",
        arguments: [
            LiveCase(mode: .shaded, follows: false, kinds: [.face], radius: 0),
            LiveCase(mode: .shaded, follows: false, kinds: [.face], radius: 3),
            LiveCase(mode: .shadedWithEdges, follows: true, kinds: [.face], radius: 0),
            LiveCase(mode: .shadedWithEdges, follows: false, kinds: [.face], radius: 2),
            LiveCase(mode: .shaded, follows: false, kinds: [.edge], radius: 0),
            LiveCase(mode: .shaded, follows: true, kinds: [.vertex], radius: 0),
            LiveCase(mode: .wireframe, follows: false, kinds: [.edge, .vertex], radius: 0),
            LiveCase(mode: .wireframe, follows: true, kinds: [.edge], radius: 2),
            LiveCase(mode: .shaded, follows: false, kinds: [], radius: 0),
        ])
    func liveEqualsOffscreen(_ test: LiveCase) async throws {
        let rig = try PickParityRig(
            bodies: Self.scene(), displayMode: test.mode, pickRadius: test.radius,
            followsDisplayMode: test.follows, pickableKinds: test.kinds)
        let result = await rig.compare(step: 3)
        rig.expectParity(result, minimumHits: test.kinds.isEmpty ? 0 : 10)
        #expect(result.kinds.isSubset(of: test.kinds), "\(test.testDescription): \(result.kinds)")
        if test.kinds.isEmpty { #expect(result.hits == 0) }
        // The options a controller makes carry the mask.
        #expect(rig.options.pickableKinds == test.kinds)
    }

    @Test("Live and offscreen agree on a face-only mask with a widget over the scene")
    func liveWidget() async throws {
        var gizmo = pickableBox("gizmo", size: 0.7)
        gizmo.renderLayer = .overlay
        gizmo.pickLayer = .widget
        gizmo.transform = translation(0, 0, 1.4)
        let rig = try PickParityRig(
            bodies: [pickableBox("a", size: 1.8), gizmo], displayMode: .shaded,
            followsDisplayMode: false, pickableKinds: [.face])
        let result = await rig.compare(step: 3)
        rig.expectParity(result, minimumHits: 40)
        #expect(result.userKinds == [.face], "\(result.userKinds)")
        #expect(result.kinds == [.face, .edge, .vertex], "\(result.kinds)")
    }

    // MARK: Heightfields

    @Test(
        "A heightfield's surface is a face: left out of the mask it is a miss that still occludes")
    func heightfieldSurface() throws {
        let renderer = try Self.renderer()
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        var options = LatticeScene.options(LatticeSetup(mode: .shaded))
        options.pickRadius = 0
        let gap = SIMD2(78, 80)
        let all = try #require(renderer.performPick(bodies: bodies, at: gap, options: options))
        #expect(all.kind == .face && all.heightfield != nil)
        var masked = options
        masked.pickableKinds = [.edge, .vertex]
        #expect(renderer.performPick(bodies: bodies, at: gap, options: masked) == nil)
        masked.pickableKinds = [.face]
        #expect(renderer.performPick(bodies: bodies, at: gap, options: masked) == all)
    }

    @Test("A heightfield's lattice lines stand for its faces: gone when faces are outside the mask")
    func heightfieldLattice() throws {
        let renderer = try Self.renderer()
        let field = try LatticeScene.field { i, j in Float(i + j) * 0.05 }
        let bodies = [LatticeScene.body(field)]
        var options = LatticeScene.options(LatticeSetup())
        options.pickRadius = 0
        let onLine = SIMD2(87, 80)
        let line = try #require(renderer.performPick(bodies: bodies, at: onLine, options: options))
        var masked = options
        masked.pickableKinds = [.face]
        #expect(renderer.performPick(bodies: bodies, at: onLine, options: masked) == line)
        masked.pickableKinds = [.edge, .vertex]
        #expect(renderer.performPick(bodies: bodies, at: onLine, options: masked) == nil)
        // Opted out of the display mode, the surface is stamped in `.wireframe` too, and it is a
        // face, so it follows the mask the same way.
        var free = options
        free.pickFollowsDisplayMode = false
        let surface = try #require(
            renderer.performPick(bodies: bodies, at: SIMD2(78, 80), options: free))
        #expect(surface.kind == .face)
        free.pickableKinds = [.edge]
        #expect(renderer.performPick(bodies: bodies, at: SIMD2(78, 80), options: free) == nil)
    }

    // MARK: The default is the pick pass as it was

    @Test(
        "The default mask is every kind, and writes what 1.3.3 wrote",
        arguments: DisplayMode.allCases, [true, false])
    func defaultIsUnchanged(mode: DisplayMode, follows: Bool) throws {
        let renderer = try Self.renderer()
        let bodies = Self.scene()
        var plain = Self.options(bodies, mode: mode, follows: follows)
        plain.pickableKinds = OffscreenRenderOptions().pickableKinds
        let explicit = Self.options(bodies, mode: mode, follows: follows, kinds: allKinds)
        let defaulted = try Self.map(renderer, bodies, plain)
        let all = try Self.map(renderer, bodies, explicit)
        #expect(defaulted.texels == all.texels)
        // The kinds a mode writes by default, written out as 1.3.3 had them, and what a body
        // without edges or vertices does: an empty mask is what is new, not a default one.
        let present = Set(Self.kinds(of: defaulted.texels).compactMap { $0 })
        let expected: Set<PrimitiveKind>
        if !follows {
            expected = allKinds
        } else {
            switch mode {
            case .wireframe: expected = [.edge, .vertex]
            case .shaded, .flat, .unlit, .rendered: expected = [.face, .vertex]
            case .shadedWithEdges, .xray: expected = allKinds
            }
        }
        #expect(present == expected, "\(mode), follows \(follows): \(present)")
    }

    // MARK: The policy and the API

    @Test("PickStampRules is the table: modes, settings, masks, with and without a mesh")
    func stampRulesWithAMask() {
        func shown(_ mode: DisplayMode) -> Bool { mode != .wireframe }
        for mode in DisplayMode.allCases {
            for follows in [true, false] {
                for kinds in everyMask {
                    let rules = PickStampRules(
                        displayMode: mode, followsDisplayMode: follows, pickableKinds: kinds)
                    let note = "\(mode) follows \(follows) \(kinds)"
                    #expect(
                        rules.stampsSurfaces
                            == (kinds.contains(.face) && (!follows || shown(mode))), "\(note)")
                    #expect(
                        rules.stampsBlankSurfaces == (!kinds.contains(.face) && shown(mode)),
                        "\(note)")
                    #expect(rules.stampsOverlaySurfaces == kinds.contains(.face), "\(note)")
                    #expect(rules.stampsVertices == kinds.contains(.vertex), "\(note)")
                    #expect(
                        rules.stampsHeightfieldLattice
                            == (kinds.contains(.face) && follows && mode == .wireframe), "\(note)")
                    #expect(rules.samplesHiddenArcs == !follows, "\(note)")
                    for hasMesh in [true, false] {
                        let drawn =
                            !hasMesh || [.wireframe, .shadedWithEdges, .xray].contains(mode)
                        #expect(
                            rules.stampsEdges(bodyHasMesh: hasMesh)
                                == (kinds.contains(.edge) && (!follows || drawn)),
                            "\(note) mesh \(hasMesh)")
                    }
                    for isDrawn in [true, false] {
                        let arc = RendererSharedBuffers.SampledArcDraw(
                            body: meshArcBody("m", at: .zero), objectIndex: 0, arcIndex: 0,
                            start: 0, count: 2, quadStart: 0, quadCount: 0, isDrawn: isDrawn)
                        #expect(
                            rules.stampsArc(arc)
                                == (kinds.contains(.edge) && (!follows || isDrawn)),
                            "\(note) arc drawn \(isDrawn)")
                    }
                }
            }
        }
    }

    @Test("rules(for:) frees a widget-layer body from the mask and nobody else")
    func rulesForBody() {
        let rules = PickStampRules(
            displayMode: .shaded, followsDisplayMode: false, pickableKinds: [.face])
        var widget = pickableBox("w")
        widget.pickLayer = .widget
        #expect(rules.rules(for: widget).pickableKinds == allKinds)
        #expect(rules.rules(for: pickableBox("u")).pickableKinds == [.face])
        var overlay = pickableBox("o")
        overlay.renderLayer = .overlay
        #expect(rules.rules(for: overlay).pickableKinds == [.face], "the render layer is not it")
        #expect(rules.rules(for: widget).displayMode == .shaded)
    }

    @Test("pickableKinds defaults to every kind, is settable, and reaches the offscreen options")
    func settingPlumbing() {
        #expect(PrimitiveKind.allCases.count == 3)
        #expect(PickingConfiguration().pickableKinds == allKinds)
        // Existing call shapes are unchanged.
        let old = PickingConfiguration(isEnabled: true, pickRadius: 3, followsDisplayMode: false)
        #expect(old.pickableKinds == allKinds && old.pickRadius == 3 && !old.followsDisplayMode)
        let faces = PickingConfiguration(
            isEnabled: true, pickRadius: 3, followsDisplayMode: false, pickableKinds: [.face])
        #expect(faces.pickableKinds == [.face] && faces.pickRadius == 3 && faces.isEnabled)
        var config = ViewportConfiguration()
        #expect(config.pickingConfiguration.pickableKinds == allKinds)
        config.pickingConfiguration.pickableKinds = [.edge]
        #expect(config.pickingConfiguration.pickableKinds == [.edge])

        #expect(OffscreenRenderOptions().pickableKinds == allKinds)
        #expect(OffscreenRenderOptions(pickableKinds: [.vertex]).pickableKinds == [.vertex])
        let controller = ViewportController(configuration: config)
        let matching = OffscreenRenderOptions(matching: controller, width: 32, height: 32)
        #expect(matching.pickableKinds == [.edge])
        let defaults = OffscreenRenderOptions(
            matching: ViewportController(configuration: ViewportConfiguration()), width: 32,
            height: 32)
        #expect(defaults.pickableKinds == allKinds)
    }

    @Test("A pick map carries the mask it was rendered with")
    func mapCarriesTheMask() throws {
        let renderer = try Self.renderer()
        let bodies = [pickableBox("a")]
        let map = try Self.map(
            renderer, bodies, Self.options(bodies, mode: .shaded, kinds: [.face, .vertex]))
        #expect(map.pickableKinds == [.face, .vertex])
        #expect(
            try Self.map(renderer, bodies, Self.options(bodies, mode: .shaded)).pickableKinds
                == allKinds)
    }
}
