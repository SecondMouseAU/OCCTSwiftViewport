import Testing
@testable import OCCTSwiftViewport

@Suite("PickResultFilter Tests")
struct PickResultFilterTests {

    // Build a decoded PickResult for a given kind / object index / layer.
    private static func make(kind: PrimitiveKind,
                             objectIndex: UInt32 = 0,
                             primitiveID: UInt32 = 0,
                             layer: PickLayer = .userGeometry) -> PickResult {
        let raw: UInt32 = (UInt32(kind.rawValue) << 30)
            | ((primitiveID & 0x3FFF) << 16)
            | (objectIndex & 0xFFFF)
        let indexMap: [Int: String] = [0: "a", 1: "b", 2: "c"]
        let layerMap: [String: PickLayer] = layer == .widget
            ? [indexMap[Int(objectIndex)] ?? "a": .widget]
            : [:]
        return PickResult(rawValue: raw, indexMap: indexMap, layerMap: layerMap)!
    }

    // MARK: - Built-ins

    @Test("all accepts everything, nothing rejects everything")
    func allAndNothing() {
        let face = Self.make(kind: .face)
        #expect(PickResultFilter.all.matches(face))
        #expect(!PickResultFilter.nothing.matches(face))
    }

    @Test("kind filters by sub-shape kind")
    func kindFilter() {
        #expect(PickResultFilter.edges.matches(Self.make(kind: .edge)))
        #expect(!PickResultFilter.edges.matches(Self.make(kind: .face)))
        #expect(PickResultFilter.faces.matches(Self.make(kind: .face)))
        #expect(PickResultFilter.vertices.matches(Self.make(kind: .vertex)))
    }

    @Test("kinds set accepts any member")
    func kindsSet() {
        let f = PickResultFilter.kinds([.edge, .vertex])
        #expect(f.matches(Self.make(kind: .edge)))
        #expect(f.matches(Self.make(kind: .vertex)))
        #expect(!f.matches(Self.make(kind: .face)))
    }

    @Test("layer filters by pick layer")
    func layerFilter() {
        let widgetOnly = PickResultFilter.layer(.widget)
        #expect(widgetOnly.matches(Self.make(kind: .face, layer: .widget)))
        #expect(!widgetOnly.matches(Self.make(kind: .face, layer: .userGeometry)))
    }

    @Test("bodyIDs allow-list and excludingBodyIDs deny-list")
    func bodyIDFilters() {
        let allow = PickResultFilter.bodyIDs(["a", "c"])
        #expect(allow.matches(Self.make(kind: .face, objectIndex: 0)))   // "a"
        #expect(!allow.matches(Self.make(kind: .face, objectIndex: 1)))  // "b"

        let deny = PickResultFilter.excludingBodyIDs(["b"])
        #expect(!deny.matches(Self.make(kind: .face, objectIndex: 1)))   // "b"
        #expect(deny.matches(Self.make(kind: .face, objectIndex: 2)))    // "c"
    }

    @Test("bodyIndices filters by draw-order index")
    func bodyIndexFilter() {
        let f = PickResultFilter.bodyIndices([2])
        #expect(f.matches(Self.make(kind: .face, objectIndex: 2)))
        #expect(!f.matches(Self.make(kind: .face, objectIndex: 0)))
    }

    // MARK: - Composition

    @Test("and requires both, or requires either, negated inverts")
    func composition() {
        let edgesOnB = PickResultFilter.edges.and(.bodyIDs(["b"]))
        #expect(edgesOnB.matches(Self.make(kind: .edge, objectIndex: 1)))  // edge + "b"
        #expect(!edgesOnB.matches(Self.make(kind: .face, objectIndex: 1))) // wrong kind
        #expect(!edgesOnB.matches(Self.make(kind: .edge, objectIndex: 0))) // wrong body

        let edgesOrVerts = PickResultFilter.edges.or(.vertices)
        #expect(edgesOrVerts.matches(Self.make(kind: .vertex)))
        #expect(!edgesOrVerts.matches(Self.make(kind: .face)))

        let notFaces = PickResultFilter.faces.negated
        #expect(!notFaces.matches(Self.make(kind: .face)))
        #expect(notFaces.matches(Self.make(kind: .edge)))
    }

    @Test("all(of:) ANDs the chain; empty chain accepts")
    func allOfChain() {
        let chain = PickResultFilter.all(of: [.edges, .bodyIDs(["a"])])
        #expect(chain.matches(Self.make(kind: .edge, objectIndex: 0)))
        #expect(!chain.matches(Self.make(kind: .edge, objectIndex: 1)))
        #expect(PickResultFilter.all(of: []).matches(Self.make(kind: .face)))
    }

    @Test("any(of:) ORs the chain; empty chain rejects")
    func anyOfChain() {
        let chain = PickResultFilter.any(of: [.faces, .vertices])
        #expect(chain.matches(Self.make(kind: .face)))
        #expect(chain.matches(Self.make(kind: .vertex)))
        #expect(!chain.matches(Self.make(kind: .edge)))
        #expect(!PickResultFilter.any(of: []).matches(Self.make(kind: .face)))
    }

    @Test("callAsFunction is equivalent to matches")
    func callAsFunction() {
        let f = PickResultFilter.faces
        let face = Self.make(kind: .face)
        #expect(f(face) == f.matches(face))
    }

    // MARK: - Controller integration

    @MainActor
    @Test("Controller applies filter to user-geometry stream, rejected pick clears")
    func controllerFiltersUserStream() {
        let controller = ViewportController()
        controller.selectionFilter = .edges

        controller.handlePick(result: Self.make(kind: .edge, objectIndex: 0))
        #expect(controller.pickResult?.kind == .edge)

        // A face fails the .edges filter → treated as a miss, clears pickResult.
        controller.handlePick(result: Self.make(kind: .face, objectIndex: 0))
        #expect(controller.pickResult == nil)
    }

    @MainActor
    @Test("Widget-layer picks bypass the selection filter")
    func widgetBypassesFilter() {
        let controller = ViewportController()
        controller.selectionFilter = .edges  // would reject a face on the user stream

        let widgetFace = Self.make(kind: .face, objectIndex: 1, layer: .widget)
        controller.handlePick(result: widgetFace)
        #expect(controller.widgetPickResult?.kind == .face)
        #expect(controller.pickResult == nil)
    }

    @MainActor
    @Test("No filter set passes everything through")
    func noFilterPassesThrough() {
        let controller = ViewportController()
        controller.handlePick(result: Self.make(kind: .face, objectIndex: 0))
        #expect(controller.pickResult?.kind == .face)
    }

    // MARK: - Deprecated alias

    // The test itself is marked deprecated so that referencing the deprecated
    // alias below does not warn; that reference is the point of the test.
    @available(*, deprecated)
    @Test("The deprecated SelectionFilter spelling still resolves to PickResultFilter")
    func deprecatedAliasStillResolves() {
        let viaAlias: SelectionFilter = .edges
        #expect(viaAlias.matches(Self.make(kind: .edge)))
        #expect(!viaAlias.matches(Self.make(kind: .face)))
        #expect(SelectionFilter.self == PickResultFilter.self)
    }
}
