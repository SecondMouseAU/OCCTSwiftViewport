// SelectionManager.swift
// OCCTSwiftMetalDemo
//
// Manages sub-body selection (face, edge, vertex) and produces highlight overlays.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

/// Manages selection state and produces highlight overlay bodies.
@MainActor
final class SelectionManager: ObservableObject {

    /// Current selection mode.
    @Published var mode: SelectionMode = .body

    /// Highlight overlay bodies to add to the scene.
    @Published private(set) var highlightBodies: [ViewportBody] = []

    /// Human-readable description of the current selection.
    @Published private(set) var selectionInfo: String = ""

    /// Whether to show curvature direction overlays on face/edge selection.
    @Published var showCurvatureOverlays: Bool = true

    /// Clears all selection state.
    func clearSelection() {
        highlightBodies = []
        selectionInfo = ""
    }

    // MARK: - Handle Pick

    /// Processes a pick result and generates highlight overlays.
    func handlePick(
        result: PickResult?,
        ndc: SIMD2<Float>,
        bodies: [ViewportBody],
        metadata: [String: CADBodyMetadata],
        cameraState: CameraState,
        aspectRatio: Float,
        shapes: [Shape] = []
    ) {
        highlightBodies = []
        selectionInfo = ""

        guard let result = result else { return }
        guard let body = bodies.first(where: { $0.id == result.bodyID }) else { return }

        switch mode {
        case .body:
            handleBodySelection(result: result, body: body)
        case .face:
            handleFaceSelection(
                result: result, body: body, metadata: metadata, shapes: shapes,
                ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio
            )
        case .edge:
            handleEdgeSelection(
                result: result, body: body, metadata: metadata, shapes: shapes,
                ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio
            )
        case .vertex:
            handleVertexSelection(
                result: result, body: body, metadata: metadata,
                ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio
            )
        case .classify:
            handleClassification(
                result: result, body: body, shapes: shapes,
                ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio
            )
        }
    }

    // MARK: - Body Selection

    private func handleBodySelection(result: PickResult, body: ViewportBody) {
        selectionInfo = "Body: \(result.bodyID)"
        // Body selection is handled by the caller (color brightening)
    }

    // MARK: - Face Selection

    private func handleFaceSelection(
        result: PickResult,
        body: ViewportBody,
        metadata: [String: CADBodyMetadata],
        shapes: [Shape],
        ndc: SIMD2<Float>,
        cameraState: CameraState,
        aspectRatio: Float
    ) {
        guard let meta = metadata[result.bodyID] else {
            selectionInfo = "Face: (no metadata for \(result.bodyID))"
            return
        }

        guard !meta.faceIndices.isEmpty else {
            selectionInfo = "Face: (no face indices)"
            return
        }

        let triIndex = result.triangleIndex
        guard triIndex < meta.faceIndices.count else {
            selectionInfo = "Face: (triangle \(triIndex) out of range)"
            return
        }

        let faceIndex = meta.faceIndices[triIndex]
        var info = "Face \(faceIndex) on \(result.bodyID)"

        // Try to get the OCCTSwift Shape and Face for detailed analysis
        let shape = shapeForBody(bodyID: result.bodyID, shapes: shapes)
        let face = shape?.face(at: Int(faceIndex))

        if let face {
            info += "\nType: \(surfaceTypeName(face.surfaceType))"
            let area = face.area()
            info += "\nArea: \(String(format: "%.4f", area))"
            if let bounds = face.uvBounds {
                info += String(format: "\nUV: [%.2f..%.2f, %.2f..%.2f]",
                               bounds.uMin, bounds.uMax, bounds.vMin, bounds.vMax)
            }
        }

        // Get 3D hit point for curvature analysis
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        let hitPoint = GeometryUtils.hitPointOnTriangle(
            ray: ray, body: body, triangleIndex: result.triangleIndex
        )

        if let face, let hitPoint {
            let point3D = SIMD3<Double>(Double(hitPoint.x), Double(hitPoint.y), Double(hitPoint.z))
            if let proj = face.project(point: point3D) {
                if let gk = face.gaussianCurvature(atU: proj.u, v: proj.v) {
                    info += "\nGaussian K: \(String(format: "%.4g", gk))"
                }
                if let mk = face.meanCurvature(atU: proj.u, v: proj.v) {
                    info += "\nMean K: \(String(format: "%.4g", mk))"
                }

                // Add curvature direction overlays
                if showCurvatureOverlays {
                    addFaceCurvatureOverlays(
                        face: face, hitPoint: hitPoint, u: proj.u, v: proj.v,
                        cameraState: cameraState
                    )
                }
            }
        }

        selectionInfo = info

        // Build face highlight mesh overlay
        let faceOverlay = buildFaceOverlay(
            faceIndex: faceIndex, body: body, meta: meta
        )
        if let faceOverlay {
            highlightBodies.insert(faceOverlay, at: 0)
        }
    }

    /// Builds the semi-transparent face highlight mesh.
    private func buildFaceOverlay(
        faceIndex: Int32,
        body: ViewportBody,
        meta: CADBodyMetadata
    ) -> ViewportBody? {
        // Reads `meshPositions`/`meshNormals` on a direct-mesh body and `vertexData` otherwise
        // (issue #264); `body.vertexData` alone is empty for a direct-mesh body.
        guard
            let mesh = MeshVertexReader.faceHighlightMesh(
                of: body, faceIndices: meta.faceIndices, face: faceIndex)
        else { return nil }

        return ViewportBody(
            id: "highlight-face",
            vertexData: mesh.vertexData,
            indices: mesh.indices,
            edges: [],
            color: SIMD4<Float>(0.2, 0.5, 1.0, 0.6)
        )
    }

    /// Adds curvature direction arrows and normal at the selected face point.
    private func addFaceCurvatureOverlays(
        face: Face,
        hitPoint: SIMD3<Float>,
        u: Double,
        v: Double,
        cameraState: CameraState
    ) {
        let arrowLength = cameraState.distance * 0.05

        // Face normal (blue)
        if let normal = face.normal(atU: u, v: v) {
            let n = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
            let end = hitPoint + n * arrowLength
            highlightBodies.append(ViewportBody(
                id: "highlight-face-normal",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, end]],
                color: SIMD4<Float>(0.3, 0.3, 1.0, 1.0)
            ))
        }

        // Principal curvature directions
        if let pc = face.principalCurvatures(atU: u, v: v) {
            let dMin = SIMD3<Float>(Float(pc.dirMin.x), Float(pc.dirMin.y), Float(pc.dirMin.z))
            let dMax = SIMD3<Float>(Float(pc.dirMax.x), Float(pc.dirMax.y), Float(pc.dirMax.z))

            // kMin direction (cyan)
            let minEnd = hitPoint + dMin * arrowLength
            highlightBodies.append(ViewportBody(
                id: "highlight-face-kmin",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, minEnd]],
                color: SIMD4<Float>(0.0, 0.9, 0.9, 1.0)
            ))

            // kMax direction (magenta)
            let maxEnd = hitPoint + dMax * arrowLength
            highlightBodies.append(ViewportBody(
                id: "highlight-face-kmax",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, maxEnd]],
                color: SIMD4<Float>(0.9, 0.0, 0.9, 1.0)
            ))
        }
    }

    // MARK: - Edge Selection

    private func handleEdgeSelection(
        result: PickResult,
        body: ViewportBody,
        metadata: [String: CADBodyMetadata],
        shapes: [Shape],
        ndc: SIMD2<Float>,
        cameraState: CameraState,
        aspectRatio: Float
    ) {
        guard let meta = metadata[result.bodyID] else {
            selectionInfo = "Edge: (no metadata for \(result.bodyID))"
            return
        }

        // Get 3D hit point from the picked triangle
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        guard let hitPoint = GeometryUtils.hitPointOnTriangle(
            ray: ray, body: body, triangleIndex: result.triangleIndex
        ) else {
            selectionInfo = "Edge: (no hit point)"
            return
        }

        // Find nearest edge polyline
        var bestDist: Float = .infinity
        var bestEdgeIdx = -1
        var bestPolyline: [SIMD3<Float>] = []

        for ep in meta.edgePolylines {
            let dist = GeometryUtils.pointToPolylineDistance(point: hitPoint, polyline: ep.points)
            if dist < bestDist {
                bestDist = dist
                bestEdgeIdx = ep.edgeIndex
                bestPolyline = ep.points
            }
        }

        guard bestEdgeIdx >= 0 else {
            selectionInfo = "Edge: (no edges found)"
            return
        }

        var info = "Edge \(bestEdgeIdx) on \(result.bodyID)"

        // Try to get the OCCTSwift Edge for detailed analysis
        let shape = shapeForBody(bodyID: result.bodyID, shapes: shapes)
        let edge = shape?.edge(at: bestEdgeIdx)

        if let edge {
            info += "\nType: \(curveTypeName(edge.curveType))"
            info += "\nLength: \(String(format: "%.4f", edge.length))"
            if let bounds = edge.parameterBounds {
                info += String(format: "\nParams: [%.3f..%.3f]", bounds.first, bounds.last)
            }

            // Project hit point onto edge for local properties
            let point3D = SIMD3<Double>(Double(hitPoint.x), Double(hitPoint.y), Double(hitPoint.z))
            if let proj = edge.project(point: point3D) {
                if let k = edge.curvature(at: proj.parameter) {
                    info += "\nCurvature: \(String(format: "%.4g", k))"
                }
                info += "\nProj dist: \(String(format: "%.4f", proj.distance))"

                // Add tangent/normal/curvature center overlays
                if showCurvatureOverlays {
                    addEdgeCurvatureOverlays(
                        edge: edge, hitPoint: hitPoint, parameter: proj.parameter,
                        cameraState: cameraState
                    )
                }
            }
        }

        selectionInfo = info

        // Build edge overlay body
        let highlight = ViewportBody(
            id: "highlight-edge",
            vertexData: [],
            indices: [],
            edges: [bestPolyline],
            color: SIMD4<Float>(0.0, 1.0, 0.3, 1.0)
        )
        highlightBodies.append(highlight)
    }

    /// Adds tangent, normal, and center of curvature overlays at the selected edge point.
    private func addEdgeCurvatureOverlays(
        edge: Edge,
        hitPoint: SIMD3<Float>,
        parameter: Double,
        cameraState: CameraState
    ) {
        let arrowLength = cameraState.distance * 0.05

        // Tangent direction (green)
        if let tangent = edge.tangent(at: parameter) {
            let t = SIMD3<Float>(Float(tangent.x), Float(tangent.y), Float(tangent.z))
            let tNorm = simd_normalize(t)
            let end = hitPoint + tNorm * arrowLength
            highlightBodies.append(ViewportBody(
                id: "highlight-edge-tangent",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, end]],
                color: SIMD4<Float>(0.2, 0.9, 0.2, 1.0)
            ))
        }

        // Normal direction (blue)
        if let normal = edge.normal(at: parameter) {
            let n = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
            let nNorm = simd_normalize(n)
            let end = hitPoint + nNorm * arrowLength
            highlightBodies.append(ViewportBody(
                id: "highlight-edge-normal",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, end]],
                color: SIMD4<Float>(0.3, 0.3, 1.0, 1.0)
            ))
        }

        // Center of curvature (small orange sphere)
        if let center = edge.centerOfCurvature(at: parameter) {
            let c = SIMD3<Float>(Float(center.x), Float(center.y), Float(center.z))
            let radius = cameraState.distance * 0.006
            var sphere = ViewportBody.sphere(
                id: "highlight-edge-coc",
                radius: radius,
                segments: 10,
                rings: 6,
                color: SIMD4<Float>(1.0, 0.6, 0.0, 1.0)
            )
            let stride = 6
            var offsetVerts: [Float] = []
            offsetVerts.reserveCapacity(sphere.vertexData.count)
            for i in Swift.stride(from: 0, to: sphere.vertexData.count, by: stride) {
                offsetVerts.append(sphere.vertexData[i] + c.x)
                offsetVerts.append(sphere.vertexData[i + 1] + c.y)
                offsetVerts.append(sphere.vertexData[i + 2] + c.z)
                offsetVerts.append(sphere.vertexData[i + 3])
                offsetVerts.append(sphere.vertexData[i + 4])
                offsetVerts.append(sphere.vertexData[i + 5])
            }
            sphere.vertexData = offsetVerts
            highlightBodies.append(sphere)

            // Line from hit point to center of curvature (dashed feel: thin gray)
            highlightBodies.append(ViewportBody(
                id: "highlight-edge-coc-line",
                vertexData: [],
                indices: [],
                edges: [[hitPoint, c]],
                color: SIMD4<Float>(0.5, 0.5, 0.5, 0.5)
            ))
        }
    }

    // MARK: - Vertex Selection

    private func handleVertexSelection(
        result: PickResult,
        body: ViewportBody,
        metadata: [String: CADBodyMetadata],
        ndc: SIMD2<Float>,
        cameraState: CameraState,
        aspectRatio: Float
    ) {
        guard let meta = metadata[result.bodyID] else {
            selectionInfo = "Vertex: (no metadata for \(result.bodyID))"
            return
        }

        guard !meta.vertices.isEmpty else {
            selectionInfo = "Vertex: (no vertices)"
            return
        }

        // Get 3D hit point from the picked triangle
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        guard let hitPoint = GeometryUtils.hitPointOnTriangle(
            ray: ray, body: body, triangleIndex: result.triangleIndex
        ) else {
            selectionInfo = "Vertex: (no hit point)"
            return
        }

        // Find nearest vertex
        var bestDist: Float = .infinity
        var bestVertex: SIMD3<Float> = .zero

        for v in meta.vertices {
            let dist = simd_distance(hitPoint, v)
            if dist < bestDist {
                bestDist = dist
                bestVertex = v
            }
        }

        guard bestDist < .infinity else {
            selectionInfo = "Vertex: (no vertex found)"
            return
        }

        selectionInfo = String(format: "Vertex (%.3f, %.3f, %.3f) on %@",
                              bestVertex.x, bestVertex.y, bestVertex.z, result.bodyID)

        // Build a small sphere at the vertex position, radius scaled by camera distance
        let radius = cameraState.distance * 0.008
        var sphere = ViewportBody.sphere(
            id: "highlight-vertex",
            radius: radius,
            segments: 12,
            rings: 8,
            color: SIMD4<Float>(1.0, 0.6, 0.0, 1.0)
        )

        // Offset sphere vertices to the vertex position
        let stride = 6
        var offsetVerts: [Float] = []
        offsetVerts.reserveCapacity(sphere.vertexData.count)
        for i in Swift.stride(from: 0, to: sphere.vertexData.count, by: stride) {
            offsetVerts.append(sphere.vertexData[i] + bestVertex.x)
            offsetVerts.append(sphere.vertexData[i + 1] + bestVertex.y)
            offsetVerts.append(sphere.vertexData[i + 2] + bestVertex.z)
            offsetVerts.append(sphere.vertexData[i + 3])
            offsetVerts.append(sphere.vertexData[i + 4])
            offsetVerts.append(sphere.vertexData[i + 5])
        }
        sphere.vertexData = offsetVerts

        highlightBodies = [sphere]
    }

    // MARK: - Classification

    private func handleClassification(
        result: PickResult,
        body: ViewportBody,
        shapes: [Shape],
        ndc: SIMD2<Float>,
        cameraState: CameraState,
        aspectRatio: Float
    ) {
        guard !shapes.isEmpty else {
            selectionInfo = "Classify: no shapes loaded (import a STEP/STL/OBJ file first)"
            return
        }

        // Get 3D hit point from the picked triangle
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        guard let hitPoint = GeometryUtils.hitPointOnTriangle(
            ray: ray, body: body, triangleIndex: result.triangleIndex
        ) else {
            selectionInfo = "Classify: (no hit point)"
            return
        }

        let point3D = SIMD3<Double>(Double(hitPoint.x), Double(hitPoint.y), Double(hitPoint.z))

        // Classify against each loaded shape
        var results: [String] = []
        for (i, shape) in shapes.enumerated() {
            let classification = shape.classify(point: point3D)
            let label: String
            switch classification {
            case .inside:
                label = "inside"
            case .outside:
                label = "outside"
            case .onBoundary:
                label = "on boundary"
            case .unknown:
                label = "unknown"
            }
            results.append("Shape \(i): \(label)")
        }

        selectionInfo = String(format: "Classify (%.3f, %.3f, %.3f)\n%@",
                              hitPoint.x, hitPoint.y, hitPoint.z,
                              results.joined(separator: "\n"))

        // Color-code the marker sphere
        let firstResult = shapes.first.map { $0.classify(point: point3D) }
        let markerColor: SIMD4<Float>
        switch firstResult {
        case .inside:
            markerColor = SIMD4(0.0, 0.9, 0.0, 1.0)    // green
        case .outside:
            markerColor = SIMD4(0.9, 0.0, 0.0, 1.0)    // red
        case .onBoundary:
            markerColor = SIMD4(1.0, 0.9, 0.0, 1.0)    // yellow
        default:
            markerColor = SIMD4(0.5, 0.5, 0.5, 1.0)    // gray
        }

        // Build a small sphere at the hit point
        let radius = cameraState.distance * 0.008
        var sphere = ViewportBody.sphere(
            id: "highlight-classify",
            radius: radius,
            segments: 12,
            rings: 8,
            color: markerColor
        )

        let stride = 6
        var offsetVerts: [Float] = []
        offsetVerts.reserveCapacity(sphere.vertexData.count)
        for i in Swift.stride(from: 0, to: sphere.vertexData.count, by: stride) {
            offsetVerts.append(sphere.vertexData[i] + hitPoint.x)
            offsetVerts.append(sphere.vertexData[i + 1] + hitPoint.y)
            offsetVerts.append(sphere.vertexData[i + 2] + hitPoint.z)
            offsetVerts.append(sphere.vertexData[i + 3])
            offsetVerts.append(sphere.vertexData[i + 4])
            offsetVerts.append(sphere.vertexData[i + 5])
        }
        sphere.vertexData = offsetVerts

        highlightBodies = [sphere]
    }

    // MARK: - Proximity Detection

    /// Checks proximity between two shapes and returns highlight bodies + info string.
    func checkProximity(
        shapes: [Shape],
        bodies: [ViewportBody],
        metadata: [String: CADBodyMetadata],
        tolerance: Double = 1.0
    ) -> (bodies: [ViewportBody], info: String) {
        guard shapes.count >= 2 else {
            return ([], "Need at least 2 shapes for proximity check")
        }

        var resultBodies: [ViewportBody] = []
        var info = ""

        // Check self-intersection of first shape
        let selfIntersects = shapes[0].selfIntersects
        info += "Shape 0 self-intersects: \(selfIntersects)"

        // Check proximity between first two shapes
        let pairs = shapes[0].proximityFaces(with: shapes[1], tolerance: tolerance)
        info += "\nProximity pairs (tol=\(String(format: "%.2f", tolerance))): \(pairs.count)"

        // Highlight the closest face pairs
        let colors: [SIMD4<Float>] = [
            SIMD4(1.0, 0.3, 0.3, 0.7),  // red
            SIMD4(0.3, 1.0, 0.3, 0.7),  // green
            SIMD4(1.0, 1.0, 0.3, 0.7),  // yellow
            SIMD4(0.3, 0.3, 1.0, 0.7),  // blue
        ]

        for (i, pair) in pairs.prefix(4).enumerated() {
            let color = colors[i % colors.count]

            // Highlight face on shape 0
            if let bodyIdx = bodyIndexForShape(shapeIndex: 0, bodies: bodies),
               let meta = metadata[bodies[bodyIdx].id] {
                if let overlay = buildFaceOverlay(
                    faceIndex: pair.face1Index, body: bodies[bodyIdx], meta: meta
                ) {
                    var b = overlay
                    b = ViewportBody(
                        id: "highlight-prox-\(i)-a",
                        vertexData: overlay.vertexData,
                        indices: overlay.indices,
                        edges: overlay.edges,
                        color: color
                    )
                    resultBodies.append(b)
                }
            }

            // Highlight face on shape 1
            if let bodyIdx = bodyIndexForShape(shapeIndex: 1, bodies: bodies),
               let meta = metadata[bodies[bodyIdx].id] {
                if let overlay = buildFaceOverlay(
                    faceIndex: pair.face2Index, body: bodies[bodyIdx], meta: meta
                ) {
                    var b = overlay
                    b = ViewportBody(
                        id: "highlight-prox-\(i)-b",
                        vertexData: overlay.vertexData,
                        indices: overlay.indices,
                        edges: overlay.edges,
                        color: color
                    )
                    resultBodies.append(b)
                }
            }

            info += "\n  Pair \(i): face \(pair.face1Index) ↔ face \(pair.face2Index)"
        }

        return (resultBodies, info)
    }

    // MARK: - Helpers

    /// Maps a body ID like "step-0" to an index into the shapes array.
    private func shapeForBody(bodyID: String, shapes: [Shape]) -> Shape? {
        // Body IDs follow the pattern "step-N", "stl-0", "obj-0", "healed-N"
        let parts = bodyID.split(separator: "-")
        guard parts.count >= 2, let index = Int(parts.last!) else { return nil }
        guard index < shapes.count else { return nil }
        return shapes[index]
    }

    /// Maps a shape index to the body index in the bodies array.
    private func bodyIndexForShape(shapeIndex: Int, bodies: [ViewportBody]) -> Int? {
        let prefixes = ["step-", "stl-", "obj-", "healed-"]
        for (i, body) in bodies.enumerated() {
            for prefix in prefixes {
                if body.id == "\(prefix)\(shapeIndex)" {
                    return i
                }
            }
        }
        return nil
    }

    private func surfaceTypeName(_ type: Face.SurfaceType) -> String {
        switch type {
        case .plane: return "Plane"
        case .cylinder: return "Cylinder"
        case .cone: return "Cone"
        case .sphere: return "Sphere"
        case .torus: return "Torus"
        case .bezierSurface: return "Bezier"
        case .bsplineSurface: return "BSpline"
        case .surfaceOfRevolution: return "Revolution"
        case .surfaceOfExtrusion: return "Extrusion"
        case .offsetSurface: return "Offset"
        case .other: return "Other"
        }
    }

    private func curveTypeName(_ type: Edge.CurveType) -> String {
        switch type {
        case .line: return "Line"
        case .circle: return "Circle"
        case .ellipse: return "Ellipse"
        case .hyperbola: return "Hyperbola"
        case .parabola: return "Parabola"
        case .bezierCurve: return "Bezier"
        case .bsplineCurve: return "BSpline"
        case .offsetCurve: return "Offset"
        case .other: return "Other"
        }
    }

    /// Builds the face overlay using an Int face index (for proximity).
    private func buildFaceOverlay(
        faceIndex: Int,
        body: ViewportBody,
        meta: CADBodyMetadata
    ) -> ViewportBody? {
        buildFaceOverlay(faceIndex: Int32(faceIndex), body: body, meta: meta)
    }
}
