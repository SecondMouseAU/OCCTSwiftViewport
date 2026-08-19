// NormalSmoothing.swift
// OCCTSwiftViewport
//
// CPU-side crease-aware vertex normal averaging.
// Smooths normals across shared vertices while preserving hard edges.

import simd

/// Crease-aware vertex normal smoothing for tessellated CAD geometry.
///
/// Averages vertex normals across adjacent triangles that share vertex positions,
/// preserving hard creases where face normals differ by more than the crease angle.
/// This eliminates visible faceting on curved surfaces while keeping sharp edges crisp.
public enum NormalSmoothing {

    /// Smooths vertex normals in-place within an interleaved vertex buffer.
    ///
    /// - Parameters:
    ///   - vertexData: Interleaved `[px, py, pz, nx, ny, nz, ...]` with stride 6.
    ///     Normals are modified in-place.
    ///   - indices: Triangle index buffer (3 indices per triangle).
    ///   - creaseAngle: Maximum angle (radians) between face normals before
    ///     treating the edge as a hard crease. Default 0.524 (~30°).
    public static func smoothNormals(
        vertexData: inout [Float],
        indices: [UInt32],
        creaseAngle: Float = 0.524
    ) {
        let vertexCount = vertexData.count / 6
        let triangleCount = indices.count / 3
        guard vertexCount > 0, triangleCount > 0 else { return }

        let cosCrease = cos(creaseAngle)

        // Snapshot the INPUT per-vertex normals before any in-place write. The fix for #81 is to
        // average THESE within each crease group (preserving OCCT's accurate analytic B-rep
        // normals) rather than recomputing from face normals. The face-normal average is
        // directionally biased on highly anisotropic meshes (long thin triangles along a sweep,
        // e.g. helical thread flanks) and shows up as fine "brushed" striations. Face normals are
        // still used below for crease *detection* (hard-edge preservation).
        let originalNormals: [SIMD3<Float>] = (0..<vertexCount).map { normal(vertexData, $0) }

        // --- Step 1: Compute face normals + triangle areas (areas weight the average) ---
        var faceNormals = [SIMD3<Float>](repeating: .zero, count: triangleCount)
        var faceAreas = [Float](repeating: 0, count: triangleCount)
        for t in 0..<triangleCount {
            let i0 = Int(indices[t * 3])
            let i1 = Int(indices[t * 3 + 1])
            let i2 = Int(indices[t * 3 + 2])
            let p0 = position(vertexData, i0)
            let p1 = position(vertexData, i1)
            let p2 = position(vertexData, i2)
            let cross = simd_cross(p1 - p0, p2 - p0)
            let len = simd_length(cross)
            faceNormals[t] = len > 1e-12 ? cross / len : .zero
            faceAreas[t] = len * 0.5
        }

        // --- Step 2: Build spatial hash of vertex positions ---
        // Maps quantized position → list of (vertexIndex, triangleIndex) pairs
        var positionMap: [SIMD3<Int32>: [(vertexIdx: Int, triIdx: Int)]] = [:]
        positionMap.reserveCapacity(vertexCount)

        for t in 0..<triangleCount {
            for c in 0..<3 {
                let vIdx = Int(indices[t * 3 + c])
                let key = quantize(position(vertexData, vIdx))
                positionMap[key, default: []].append((vertexIdx: vIdx, triIdx: t))
            }
        }

        // --- Step 3: Average normals within crease groups ---
        // Track which vertices have been processed to avoid redundant work
        var processed = [Bool](repeating: false, count: vertexCount)

        for (_, entries) in positionMap {
            // Deduplicate vertex indices at this position
            var uniqueVertices: [Int] = []
            var seen = Set<Int>()
            for entry in entries {
                if seen.insert(entry.vertexIdx).inserted {
                    uniqueVertices.append(entry.vertexIdx)
                }
            }

            // Collect all triangle indices touching this position
            var triSet = Set<Int>()
            for entry in entries {
                triSet.insert(entry.triIdx)
            }
            let adjacentTris = Array(triSet)

            if adjacentTris.count <= 1 {
                // Only one triangle, so nothing to average
                for vIdx in uniqueVertices { processed[vIdx] = true }
                continue
            }

            // Group triangles by crease connectivity
            let groups = groupByCrease(
                triangles: adjacentTris,
                faceNormals: faceNormals,
                cosThreshold: cosCrease
            )

            // For each crease group, assign the area-weighted average of the ORIGINAL per-vertex
            // normals of this position's vertices in the group (#81). For a smooth B-rep mesh those
            // input normals are ~equal, so the average reproduces them (striations gone); for a flat
            // mesh each vertex normal == its own face normal, so this reduces to the previous
            // area-weighted face-normal average (backward-compatible).
            for group in groups {
                let groupSet = Set(group)

                var sum = SIMD3<Float>.zero
                for entry in entries where groupSet.contains(entry.triIdx) {
                    sum += faceAreas[entry.triIdx] * originalNormals[entry.vertexIdx]
                }
                let averaged =
                    simd_length(sum) > 1e-12 ? simd_normalize(sum) : faceNormals[group[0]]

                // Assign to all vertices at this position that belong to triangles in this group
                for entry in entries where groupSet.contains(entry.triIdx) {
                    let vIdx = entry.vertexIdx
                    if !processed[vIdx] {
                        setNormal(&vertexData, vIdx, averaged)
                        processed[vIdx] = true
                    }
                }
            }
        }

        // Any unprocessed vertices keep their original normals
    }

    // MARK: - Private Helpers

    /// Extracts position from interleaved vertex data.
    private static func position(_ data: [Float], _ idx: Int) -> SIMD3<Float> {
        let base = idx * 6
        return SIMD3<Float>(data[base], data[base + 1], data[base + 2])
    }

    /// Extracts the per-vertex normal from interleaved vertex data.
    private static func normal(_ data: [Float], _ idx: Int) -> SIMD3<Float> {
        let base = idx * 6 + 3
        return SIMD3<Float>(data[base], data[base + 1], data[base + 2])
    }

    /// Writes a normal into interleaved vertex data.
    private static func setNormal(_ data: inout [Float], _ idx: Int, _ n: SIMD3<Float>) {
        let base = idx * 6 + 3
        data[base] = n.x
        data[base + 1] = n.y
        data[base + 2] = n.z
    }

    /// Quantizes a position to a grid for spatial hashing (tolerance ~1e-5).
    ///
    /// Non-finite coordinates map to 0 and coordinates beyond the Int32 range are
    /// clamped, so an out-of-range or `NaN`/`±inf` tessellation vertex can never trap
    /// the trapping `Int32(_: Float)` initializer. This only affects the welding key:
    /// welding matters only for near-coincident vertices, so a clamped extreme simply
    /// fails to weld with anything, which is correct.
    private static func quantize(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let scale: Float = 1e5
        // Inside the Int32 range and exactly representable as Float. Clamping to
        // Float(Int32.max) would itself trap, since that rounds up to 2³¹.
        let limit: Float = 2_000_000_000
        func q(_ v: Float) -> Int32 {
            let s = (v * scale).rounded()
            guard s.isFinite else { return 0 }
            return Int32(min(max(s, -limit), limit))
        }
        return SIMD3<Int32>(q(p.x), q(p.y), q(p.z))
    }

    /// Groups triangle indices by crease-angle connectivity.
    ///
    /// Two triangles are in the same group if their face normals' dot product
    /// exceeds the cosine threshold (i.e., angle between normals < crease angle).
    /// Uses flood-fill: triangles within crease angle of any group member are added.
    private static func groupByCrease(
        triangles: [Int],
        faceNormals: [SIMD3<Float>],
        cosThreshold: Float
    ) -> [[Int]] {
        var assigned = [Bool](repeating: false, count: triangles.count)
        var groups: [[Int]] = []

        for i in 0..<triangles.count {
            guard !assigned[i] else { continue }

            // Flood-fill from this triangle
            var group = [triangles[i]]
            assigned[i] = true
            var queue = [i]

            while !queue.isEmpty {
                let current = queue.removeFirst()
                let currentNormal = faceNormals[triangles[current]]

                for j in 0..<triangles.count {
                    guard !assigned[j] else { continue }
                    let candidateNormal = faceNormals[triangles[j]]
                    let dot = simd_dot(currentNormal, candidateNormal)
                    if dot >= cosThreshold {
                        assigned[j] = true
                        group.append(triangles[j])
                        queue.append(j)
                    }
                }
            }

            groups.append(group)
        }

        return groups
    }
}
