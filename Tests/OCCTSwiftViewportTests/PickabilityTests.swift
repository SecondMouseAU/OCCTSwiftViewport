import Testing
import simd
@testable import OCCTSwiftViewport

@Suite("ViewportBody pickability")
struct PickabilityTests {

    @Test("isPickable defaults to true and is source-compatible (#63)")
    func defaultsPickable() {
        let body = ViewportBody(id: "a", vertexData: [], indices: [], edges: [], color: .one)
        #expect(body.isPickable)
    }

    @Test("A body can be marked non-pickable while staying visible")
    func nonPickableStaysVisible() {
        let body = ViewportBody(id: "datum", vertexData: [], indices: [], edges: [],
                                color: .one, isVisible: true, isPickable: false)
        #expect(body.isVisible)      // still drawn
        #expect(!body.isPickable)    // excluded from the pick buffer
    }

    @Test("Primitive factory bodies are pickable by default")
    func primitivesPickable() {
        #expect(ViewportBody.box(id: "box").isPickable)
    }
}
