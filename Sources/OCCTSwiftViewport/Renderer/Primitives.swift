// Primitives.swift
// ViewportKit
//
// Procedural geometry generators for common primitives.

import simd

extension ViewportBody {

    // MARK: - Box

    /// Creates a box with flat-shaded faces.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - width: X-axis extent
    ///   - height: Y-axis extent
    ///   - depth: Z-axis extent
    ///   - color: RGBA colour
    /// - Returns: A ViewportBody containing box geometry
    public static func box(
        id: String,
        width: Float = 1,
        height: Float = 1,
        depth: Float = 1,
        color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
    ) -> ViewportBody {
        let hw = width * 0.5
        let hh = height * 0.5
        let hd = depth * 0.5

        // 6 faces, 4 vertices each (for flat normals), 24 vertices total
        // Each vertex: px, py, pz, nx, ny, nz
        var verts: [Float] = []
        var indices: [UInt32] = []
        var vertexIndex: UInt32 = 0

        // Face definitions: (normal, 4 corner positions)
        let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
            // Front (+Z)
            (
                SIMD3<Float>(0, 0, 1),
                [
                    SIMD3<Float>(-hw, -hh, hd), SIMD3<Float>(hw, -hh, hd),
                    SIMD3<Float>(hw, hh, hd), SIMD3<Float>(-hw, hh, hd),
                ]
            ),
            // Back (-Z)
            (
                SIMD3<Float>(0, 0, -1),
                [
                    SIMD3<Float>(hw, -hh, -hd), SIMD3<Float>(-hw, -hh, -hd),
                    SIMD3<Float>(-hw, hh, -hd), SIMD3<Float>(hw, hh, -hd),
                ]
            ),
            // Right (+X)
            (
                SIMD3<Float>(1, 0, 0),
                [
                    SIMD3<Float>(hw, -hh, hd), SIMD3<Float>(hw, -hh, -hd),
                    SIMD3<Float>(hw, hh, -hd), SIMD3<Float>(hw, hh, hd),
                ]
            ),
            // Left (-X)
            (
                SIMD3<Float>(-1, 0, 0),
                [
                    SIMD3<Float>(-hw, -hh, -hd), SIMD3<Float>(-hw, -hh, hd),
                    SIMD3<Float>(-hw, hh, hd), SIMD3<Float>(-hw, hh, -hd),
                ]
            ),
            // Top (+Y)
            (
                SIMD3<Float>(0, 1, 0),
                [
                    SIMD3<Float>(-hw, hh, hd), SIMD3<Float>(hw, hh, hd),
                    SIMD3<Float>(hw, hh, -hd), SIMD3<Float>(-hw, hh, -hd),
                ]
            ),
            // Bottom (-Y)
            (
                SIMD3<Float>(0, -1, 0),
                [
                    SIMD3<Float>(-hw, -hh, -hd), SIMD3<Float>(hw, -hh, -hd),
                    SIMD3<Float>(hw, -hh, hd), SIMD3<Float>(-hw, -hh, hd),
                ]
            ),
        ]

        for (normal, corners) in faces {
            for corner in corners {
                verts.append(contentsOf: [
                    corner.x, corner.y, corner.z, normal.x, normal.y, normal.z,
                ])
            }
            // Two triangles per face: 0-1-2, 0-2-3
            indices.append(contentsOf: [
                vertexIndex, vertexIndex + 1, vertexIndex + 2,
                vertexIndex, vertexIndex + 2, vertexIndex + 3,
            ])
            vertexIndex += 4
        }

        // Edges: 12 edges of the box
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(-hw, -hh, -hd), SIMD3<Float>(hw, -hh, -hd),
            SIMD3<Float>(hw, hh, -hd), SIMD3<Float>(-hw, hh, -hd),
            SIMD3<Float>(-hw, -hh, hd), SIMD3<Float>(hw, -hh, hd),
            SIMD3<Float>(hw, hh, hd), SIMD3<Float>(-hw, hh, hd),
        ]
        let edgeIndices: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),  // back face
            (4, 5), (5, 6), (6, 7), (7, 4),  // front face
            (0, 4), (1, 5), (2, 6), (3, 7),  // connecting
        ]
        let edges = edgeIndices.map { (a, b) in [corners[a], corners[b]] }

        // 6 faces, 2 triangles each → face indices [0,0,1,1,2,2,3,3,4,4,5,5]
        let faceIndices: [Int32] = (0..<6).flatMap { face in [Int32(face), Int32(face)] }

        return ViewportBody(
            id: id, vertexData: verts, indices: indices, edges: edges, faceIndices: faceIndices,
            color: color)
    }

    // MARK: - Cylinder

    /// Creates a cylinder along the Y axis.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - radius: Cylinder radius
    ///   - height: Cylinder height
    ///   - segments: Number of radial segments
    ///   - color: RGBA colour
    /// - Returns: A ViewportBody containing cylinder geometry
    public static func cylinder(
        id: String,
        radius: Float = 0.5,
        height: Float = 1,
        segments: Int = 64,
        color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
    ) -> ViewportBody {
        let hh = height * 0.5
        var verts: [Float] = []
        var indices: [UInt32] = []
        var edges: [[SIMD3<Float>]] = []

        // --- Side ---
        let sideStart = UInt32(verts.count / 6)
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            let nx = cos(angle)
            let nz = sin(angle)

            // Bottom vertex
            verts.append(contentsOf: [x, -hh, z, nx, 0, nz])
            // Top vertex
            verts.append(contentsOf: [x, hh, z, nx, 0, nz])
        }

        for i in 0..<UInt32(segments) {
            let bl = sideStart + i * 2
            let br = sideStart + (i + 1) * 2
            let tl = bl + 1
            let tr = br + 1
            indices.append(contentsOf: [bl, br, tr, bl, tr, tl])
        }

        // --- Top cap ---
        let topCenterIdx = UInt32(verts.count / 6)
        verts.append(contentsOf: [0, hh, 0, 0, 1, 0])
        let topRingStart = UInt32(verts.count / 6)
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            verts.append(contentsOf: [cos(angle) * radius, hh, sin(angle) * radius, 0, 1, 0])
        }
        for i in 0..<UInt32(segments) {
            indices.append(contentsOf: [topCenterIdx, topRingStart + i, topRingStart + i + 1])
        }

        // --- Bottom cap ---
        let botCenterIdx = UInt32(verts.count / 6)
        verts.append(contentsOf: [0, -hh, 0, 0, -1, 0])
        let botRingStart = UInt32(verts.count / 6)
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            verts.append(contentsOf: [cos(angle) * radius, -hh, sin(angle) * radius, 0, -1, 0])
        }
        for i in 0..<UInt32(segments) {
            indices.append(contentsOf: [botCenterIdx, botRingStart + i + 1, botRingStart + i])
        }

        // --- Edges ---
        // Top ring
        var topRing: [SIMD3<Float>] = []
        var bottomRing: [SIMD3<Float>] = []
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            topRing.append(SIMD3<Float>(x, hh, z))
            bottomRing.append(SIMD3<Float>(x, -hh, z))
        }
        edges.append(topRing)
        edges.append(bottomRing)

        // Vertical lines (every 4th segment)
        let vertStep = max(1, segments / 8)
        for i in stride(from: 0, to: segments, by: vertStep) {
            let angle = Float(i) / Float(segments) * 2.0 * .pi
            let x = cos(angle) * radius
            let z = sin(angle) * radius
            edges.append([SIMD3<Float>(x, -hh, z), SIMD3<Float>(x, hh, z)])
        }

        // Face 0 = side (segments quads × 2 tris), face 1 = top cap, face 2 = bottom cap
        var faceIndices: [Int32] = []
        faceIndices.append(contentsOf: Array(repeating: Int32(0), count: segments * 2))  // side
        faceIndices.append(contentsOf: Array(repeating: Int32(1), count: segments))  // top cap
        faceIndices.append(contentsOf: Array(repeating: Int32(2), count: segments))  // bottom cap

        return ViewportBody(
            id: id, vertexData: verts, indices: indices, edges: edges, faceIndices: faceIndices,
            color: color)
    }

    // MARK: - Sphere

    /// Creates a UV sphere.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - radius: Sphere radius
    ///   - segments: Number of longitudinal segments
    ///   - rings: Number of latitudinal rings
    ///   - color: RGBA colour
    /// - Returns: A ViewportBody containing sphere geometry
    public static func sphere(
        id: String,
        radius: Float = 0.5,
        segments: Int = 48,
        rings: Int = 32,
        color: SIMD4<Float> = SIMD4<Float>(0.8, 0.8, 0.8, 1.0)
    ) -> ViewportBody {
        var verts: [Float] = []
        var indices: [UInt32] = []
        var edges: [[SIMD3<Float>]] = []

        // Generate vertices
        for ring in 0...rings {
            let phi = Float(ring) / Float(rings) * .pi
            let y = cos(phi) * radius
            let ringRadius = sin(phi) * radius

            for seg in 0...segments {
                let theta = Float(seg) / Float(segments) * 2.0 * .pi
                let x = cos(theta) * ringRadius
                let z = sin(theta) * ringRadius

                let nx = cos(theta) * sin(phi)
                let ny = cos(phi)
                let nz = sin(theta) * sin(phi)

                verts.append(contentsOf: [x, y, z, nx, ny, nz])
            }
        }

        // Generate indices
        let vertsPerRow = UInt32(segments + 1)
        for ring in 0..<UInt32(rings) {
            for seg in 0..<UInt32(segments) {
                let tl = ring * vertsPerRow + seg
                let tr = tl + 1
                let bl = tl + vertsPerRow
                let br = bl + 1

                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        // Edges: equator
        var equator: [SIMD3<Float>] = []
        let equatorRing = rings / 2
        let equatorPhi = Float(equatorRing) / Float(rings) * .pi
        let eqRingRadius = sin(equatorPhi) * radius
        let eqY = cos(equatorPhi) * radius
        for seg in 0...segments {
            let theta = Float(seg) / Float(segments) * 2.0 * .pi
            equator.append(SIMD3<Float>(cos(theta) * eqRingRadius, eqY, sin(theta) * eqRingRadius))
        }
        edges.append(equator)

        // Edges: 4 meridians
        for meridian in 0..<4 {
            let theta = Float(meridian) / 4.0 * 2.0 * .pi
            var meridianLine: [SIMD3<Float>] = []
            for ring in 0...rings {
                let phi = Float(ring) / Float(rings) * .pi
                let x = cos(theta) * sin(phi) * radius
                let y = cos(phi) * radius
                let z = sin(theta) * sin(phi) * radius
                meridianLine.append(SIMD3<Float>(x, y, z))
            }
            edges.append(meridianLine)
        }

        // Sphere is a single continuous surface → face 0 for all triangles
        let triangleCount = indices.count / 3
        let faceIndices = Array(repeating: Int32(0), count: triangleCount)

        return ViewportBody(
            id: id, vertexData: verts, indices: indices, edges: edges, faceIndices: faceIndices,
            color: color)
    }
}
