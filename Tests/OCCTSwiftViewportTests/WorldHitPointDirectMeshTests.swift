import Testing
import simd

@testable import OCCTSwiftViewport

/// `ViewportBody.worldHitPoint(ray:triangleIndex:)` on direct-mesh bodies (#247).
///
/// A direct-mesh body keeps its triangles in `meshPositions`; its `vertices` is the vertex-pick
/// array, which can be empty or hold unrelated points. Tap-to-measure has to read the mesh.
@Suite("worldHitPoint on direct-mesh bodies")
struct WorldHitPointDirectMeshTests {

    // A square in the z = 0 plane with corners (+-h, +-h), normal +Z. Two triangles:
    // (0, 1, 2) in the lower right half and (0, 2, 3) in the upper left half.
    private static let half: Float = 2
    private static let indices: [UInt32] = [0, 1, 2, 0, 2, 3]

    private static func corners(z: Float = 0) -> [SIMD3<Float>] {
        let h = half
        return [[-h, -h, z], [h, -h, z], [h, h, z], [-h, h, z]]
    }

    private static func flat(_ points: [SIMD3<Float>]) -> [Float] {
        points.flatMap { [$0.x, $0.y, $0.z] }
    }

    private static var normals: [Float] {
        flat(Array(repeating: SIMD3<Float>(0, 0, 1), count: 4))
    }

    /// Built with the memberwise initialiser, as an app that owns its own arrays builds one:
    /// `vertexData` empty and `vertices` left as the caller passes it.
    private static func initBuilt(
        vertices: [SIMD3<Float>] = [],
        transform: simd_float4x4 = matrix_identity_float4x4
    ) -> ViewportBody {
        ViewportBody(
            id: "direct",
            vertexData: [],
            indices: indices,
            edges: [],
            vertices: vertices,
            color: .one,
            transform: transform,
            meshPositions: flat(corners()),
            meshNormals: normals
        )
    }

    private static func factoryBuilt(
        transform: simd_float4x4 = matrix_identity_float4x4
    ) -> ViewportBody {
        ViewportBody.directMesh(
            id: "direct",
            positions: flat(corners()),
            normals: normals,
            indices: indices,
            color: .one,
            transform: transform
        )
    }

    private static func interleaved() -> ViewportBody {
        var vertexData: [Float] = []
        for c in corners() { vertexData += [c.x, c.y, c.z, 0, 0, 1] }
        return ViewportBody(
            id: "interleaved", vertexData: vertexData, indices: indices, edges: [], color: .one)
    }

    /// A point strictly inside triangle 0, off the diagonal the two triangles share (triangle 1
    /// is the half where y > x), so a test using it does not depend on how a boundary hit is
    /// classified. `issueProbe` is the one test that deliberately sits on that diagonal.
    private static let lowerRight: SIMD2<Float> = [1, -0.5]
    private static let upperLeft: SIMD2<Float> = [-1, 0.5]

    private static func down(at xy: SIMD2<Float> = lowerRight) -> Ray {
        Ray(origin: [xy.x, xy.y, 5], direction: [0, 0, -1])
    }

    private static let lowerRightHit: SIMD3<Float> = [1, -0.5, 0]

    private static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    private static func isNear(_ a: SIMD3<Float>?, _ b: SIMD3<Float>) -> Bool {
        guard let a else { return false }
        return simd_length(a - b) < 1e-5
    }

    // MARK: - Where the triangles are read from

    @Test("An init-built direct-mesh body with empty vertices hits the mesh")
    func initBuiltEmptyVertices() {
        let body = Self.initBuilt()
        #expect(body.usesDirectMesh)
        #expect(body.vertices.isEmpty)
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, Self.lowerRightHit))
    }

    @Test("The probe from issue 247, on the edge the two triangles share, hits")
    func issueProbe() {
        // A ray from (0, 0, 5) along -Z through the middle of the square, triangle 0.
        let ray = Ray(origin: [0, 0, 5], direction: [0, 0, -1])
        let fromInit = Self.initBuilt().worldHitPoint(ray: ray, triangleIndex: 0)
        let fromFactory = Self.factoryBuilt().worldHitPoint(ray: ray, triangleIndex: 0)
        #expect(Self.isNear(fromInit, [0, 0, 0]))
        #expect(Self.isNear(fromFactory, [0, 0, 0]))
    }

    @Test("A body from ViewportBody.directMesh hits the mesh")
    func factoryBuilt() {
        let body = Self.factoryBuilt()
        #expect(body.usesDirectMesh)
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, Self.lowerRightHit))
    }

    @Test("Each triangle index addresses its own triangle")
    func triangleIndexSelectsTriangle() {
        let body = Self.initBuilt()
        let inLower = Self.down(at: Self.lowerRight)
        let inUpper = Self.down(at: Self.upperLeft)
        #expect(Self.isNear(body.worldHitPoint(ray: inLower, triangleIndex: 0), [1, -0.5, 0]))
        #expect(body.worldHitPoint(ray: inLower, triangleIndex: 1) == nil)
        #expect(Self.isNear(body.worldHitPoint(ray: inUpper, triangleIndex: 1), [-1, 0.5, 0]))
        #expect(body.worldHitPoint(ray: inUpper, triangleIndex: 0) == nil)
    }

    @Test("An out-of-range triangle index returns nil")
    func outOfRangeTriangle() {
        let body = Self.initBuilt()
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 2) == nil)
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 99) == nil)
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: -1) == nil)
    }

    @Test("An index past the end of meshPositions returns nil rather than trapping")
    func indexPastMeshPositions() {
        let body = ViewportBody(
            id: "short",
            vertexData: [],
            indices: [0, 1, 7],
            edges: [],
            color: .one,
            meshPositions: Self.flat(Self.corners()),
            meshNormals: Self.normals
        )
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 0) == nil)
    }

    // MARK: - Transform

    @Test("An init-built direct-mesh body applies its transform")
    func initBuiltTransform() {
        let body = Self.initBuilt(transform: Self.translation([10, 0, 0]))
        // The square now spans x in [8, 12]: the probe at x = 1 misses, x = 11 hits.
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 0) == nil)
        let hit = body.worldHitPoint(ray: Self.down(at: [11, -0.5]), triangleIndex: 0)
        #expect(Self.isNear(hit, [11, -0.5, 0]))
    }

    @Test("A factory-built direct-mesh body applies its transform")
    func factoryBuiltTransform() {
        let body = Self.factoryBuilt(transform: Self.translation([10, 0, 0]))
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 0) == nil)
        let hit = body.worldHitPoint(ray: Self.down(at: [11, -0.5]), triangleIndex: 0)
        #expect(Self.isNear(hit, [11, -0.5, 0]))
    }

    @Test("A scale and translation lift the hit point to world space")
    func scaleAndTranslation() {
        var m = Self.translation([0, 0, 3])
        m.columns.0.x = 2
        m.columns.1.y = 2
        let body = Self.initBuilt(transform: m)
        // The square now spans (+-4, +-4) at z = 3: world (2, -1) is local (1, -0.5), and
        // world x = 5 is outside.
        let inside = body.worldHitPoint(ray: Self.down(at: [2, -1]), triangleIndex: 0)
        #expect(Self.isNear(inside, [2, -1, 3]))
        #expect(body.worldHitPoint(ray: Self.down(at: [5, -1]), triangleIndex: 0) == nil)
    }

    // MARK: - vertices is not the mesh

    @Test("Sparse vertices are ignored")
    func sparseVertices() {
        // Two B-Rep corner points: fewer than the mesh has vertices.
        let body = Self.initBuilt(vertices: [[-2, -2, 0], [2, -2, 0]])
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, Self.lowerRightHit))
    }

    @Test("Unrelated vertices of the right count do not move the hit point")
    func unrelatedVertices() {
        // Same count as the mesh, but a square one unit up: reading them would hit at z = 1.
        let body = Self.initBuilt(vertices: Self.corners(z: 1))
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, Self.lowerRightHit))
    }

    @Test("A direct-mesh body wins over a stale vertexData")
    func meshWinsOverVertexData() {
        // The renderer draws meshPositions whenever usesDirectMesh is true, so a picked
        // triangle is a meshPositions triangle even if vertexData is also populated.
        var stale: [Float] = []
        for c in Self.corners(z: 1) { stale += [c.x, c.y, c.z, 0, 0, 1] }
        let body = ViewportBody(
            id: "both",
            vertexData: stale,
            indices: Self.indices,
            edges: [],
            color: .one,
            meshPositions: Self.flat(Self.corners()),
            meshNormals: Self.normals
        )
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, Self.lowerRightHit))
    }

    // MARK: - Layouts that are not direct-mesh

    @Test("An interleaved body still reads vertexData, whatever vertices holds")
    func interleavedUnchanged() {
        var body = Self.interleaved()
        let before = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(before, Self.lowerRightHit))
        body.vertices = Self.corners(z: 1)
        let after = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(after, Self.lowerRightHit))
    }

    @Test("A half-populated direct mesh falls back to vertices, as the raycast does")
    func halfPopulatedFallsBack() {
        // meshNormals does not match meshPositions, so usesDirectMesh is false and nothing but
        // vertices describes the triangles.
        let body = ViewportBody(
            id: "half",
            vertexData: [],
            indices: Self.indices,
            edges: [],
            vertices: Self.corners(z: 1),
            color: .one,
            meshPositions: Self.flat(Self.corners()),
            meshNormals: []
        )
        #expect(!body.usesDirectMesh)
        let hit = body.worldHitPoint(ray: Self.down(), triangleIndex: 0)
        #expect(Self.isNear(hit, [1, -0.5, 1]))
    }

    @Test("A body with no triangle positions returns nil")
    func noPositions() {
        let body = ViewportBody(
            id: "empty", vertexData: [], indices: Self.indices, edges: [], color: .one)
        #expect(body.worldHitPoint(ray: Self.down(), triangleIndex: 0) == nil)
    }

    // MARK: - End to end

    // Decoded face PickResult for body `objectIndex`, triangle `primitiveID`.
    private static func facePick(
        objectIndex: UInt32, primitiveID: UInt32, indexMap: [Int: String]
    ) -> PickResult {
        let raw = PickEncoding.encode(
            objectIndex: objectIndex, primitiveIndex: primitiveID, kind: .face)
        return PickResult(pickValue: raw, indexMap: indexMap, layerMap: [:])!
    }

    @MainActor
    @Test("A tap on an init-built direct-mesh body adds a measurement point")
    func tapMeasuresDirectMeshBody() {
        let controller = ViewportController()
        // Camera at +Z looking down -Z at the origin.
        let camera = CameraState(
            rotation: simd_quatf(angle: 0, axis: [0, 0, 1]), distance: 5, pivot: .zero)
        controller.animateTo(camera, duration: 0)
        controller.measurementMode = .distance
        let bodies = [Self.initBuilt()]
        let map: [Int: String] = [0: "direct"]

        // Two off-centre taps, one on each triangle.
        controller.handleMeasurementPick(
            result: Self.facePick(objectIndex: 0, primitiveID: 0, indexMap: map),
            ndc: [0.2, -0.2], bodies: bodies, aspectRatio: 1)
        #expect(controller.pendingMeasurementPoints.count == 1)

        controller.handleMeasurementPick(
            result: Self.facePick(objectIndex: 0, primitiveID: 1, indexMap: map),
            ndc: [-0.2, 0.2], bodies: bodies, aspectRatio: 1)
        #expect(controller.measurements.count == 1)
        guard case .distance(let measurement) = controller.measurements.first else {
            Issue.record("expected a distance measurement")
            return
        }
        // Each point is where the tap's ray meets the z = 0 plane, on the tapped triangle.
        let start = Self.planeHit(ndc: [0.2, -0.2], camera: camera)
        let end = Self.planeHit(ndc: [-0.2, 0.2], camera: camera)
        #expect(Self.isNear(measurement.start, start))
        #expect(Self.isNear(measurement.end, end))
        #expect(abs(measurement.distance - simd_length(end - start)) < 1e-4)
    }

    // Where the camera ray through `ndc` meets the z = 0 plane, worked out without the body.
    private static func planeHit(ndc: SIMD2<Float>, camera: CameraState) -> SIMD3<Float> {
        let ray = Ray.fromCamera(ndc: ndc, cameraState: camera, aspectRatio: 1)
        return ray.origin + ray.direction * (-ray.origin.z / ray.direction.z)
    }
}
