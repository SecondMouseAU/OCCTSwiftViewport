// MeshletBuilder.swift
// OCCTSwiftViewport
//
// CPU-side partitioning of triangle meshes into meshlets for mesh shader rendering.
// Each meshlet is a group of triangles sharing vertices, with bounding sphere
// and normal cone for per-meshlet frustum and backface culling.

@preconcurrency import Metal
import simd

/// Maximum vertices per meshlet.
///
/// This and `kMeshletMaxTriangles` match the mesh shader's threadgroup output limits, so one
/// meshlet always fits in a single threadgroup's output.
let kMeshletMaxVertices: Int = 64
let kMeshletMaxTriangles: Int = 64

/// Descriptor for a single meshlet, uploaded to the GPU as raw bytes.
///
/// Field order and packing have to match the Metal shader's struct layout, so reordering
/// members here silently corrupts what the shader reads back.
struct MeshletDescriptor {
    var center: SIMD3<Float>  // Bounding sphere center
    var radius: Float  // Bounding sphere radius
    var coneAxis: SIMD3<Float>  // Normal cone axis (average normal)
    var coneCutoff: Float  // cos(cone half-angle), < 0 means no backface cull
    var vertexOffset: UInt32  // Offset into meshlet vertex index buffer
    var vertexCount: UInt32  // Number of unique vertices in this meshlet
    var triangleOffset: UInt32  // Offset into meshlet triangle index buffer
    var triangleCount: UInt32  // Number of triangles in this meshlet
    var faceIndexFirst: Int32  // Face index of first triangle (for picking)
    var _pad0: Int32 = 0
    var _pad1: Int32 = 0
    var _pad2: Int32 = 0
    // Size: 3*4 + 4 + 3*4 + 4 + 4*4 + 4 + 3*4 = 64 bytes
}

/// Per-body meshlet data uploaded to GPU.
struct MeshletBuffers {
    let descriptorBuffer: MTLBuffer  // MeshletDescriptor per meshlet
    let vertexIndexBuffer: MTLBuffer  // UInt32: global vertex indices (meshlet-local → global)
    let triangleIndexBuffer: MTLBuffer  // UInt8: meshlet-local triangle indices (3 per tri)
    let faceIndexBuffer: MTLBuffer  // Int32: per-triangle face index for picking
    let meshletCount: Int
}

/// Builds meshlets from triangle mesh data on CPU.
enum MeshletBuilder {

    /// Partitions a triangle mesh into meshlets.
    ///
    /// - Parameters:
    ///   - vertexData: Interleaved vertex data (stride 6 floats)
    ///   - indices: Triangle index buffer
    ///   - faceIndices: Per-triangle face index
    ///   - device: Metal device for buffer allocation
    /// - Returns: MeshletBuffers or nil if mesh is empty
    static func build(
        vertexData: [Float],
        indices: [UInt32],
        faceIndices: [Int32],
        device: MTLDevice
    ) -> MeshletBuffers? {
        let triangleCount = indices.count / 3
        guard triangleCount > 0, faceIndices.count >= triangleCount else { return nil }

        var meshlets: [MeshletDescriptor] = []
        var allVertexIndices: [UInt32] = []  // Global vertex indices
        var allTriangleIndices: [UInt8] = []  // Meshlet-local triangle indices
        var allFaceIndices: [Int32] = []  // Per-triangle face index

        // Greedy meshlet construction
        var usedTriangles = [Bool](repeating: false, count: triangleCount)
        var currentVertices: [UInt32] = []  // Global vertex indices in current meshlet
        var vertexMap: [UInt32: UInt8] = [:]  // Global → local index
        var currentTriangles: [(UInt8, UInt8, UInt8)] = []
        var currentFaceIndices: [Int32] = []

        func flushMeshlet() {
            guard !currentTriangles.isEmpty else { return }

            // Compute bounding sphere
            var minP = SIMD3<Float>(
                Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude,
                Float.greatestFiniteMagnitude)
            var maxP = SIMD3<Float>(
                -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude,
                -Float.greatestFiniteMagnitude)
            var normalSum = SIMD3<Float>.zero

            for gIdx in currentVertices {
                let p = position(vertexData, Int(gIdx))
                let n = normal(vertexData, Int(gIdx))
                minP = simd_min(minP, p)
                maxP = simd_max(maxP, p)
                normalSum += n
            }
            let center = (minP + maxP) * 0.5
            var radius: Float = 0
            for gIdx in currentVertices {
                let d = simd_distance(position(vertexData, Int(gIdx)), center)
                if d > radius { radius = d }
            }

            // Normal cone
            let avgNormal =
                simd_length(normalSum) > 1e-6 ? simd_normalize(normalSum) : SIMD3<Float>(0, 1, 0)
            var minDot: Float = 1.0
            for gIdx in currentVertices {
                let n = normal(vertexData, Int(gIdx))
                let d = simd_dot(n, avgNormal)
                if d < minDot { minDot = d }
            }
            // coneCutoff: if all normals point roughly the same way, backface cull is possible
            // A negative cutoff means the cone is too wide for backface culling
            let coneCutoff = minDot

            let desc = MeshletDescriptor(
                center: center,
                radius: radius,
                coneAxis: avgNormal,
                coneCutoff: coneCutoff,
                vertexOffset: UInt32(allVertexIndices.count),
                vertexCount: UInt32(currentVertices.count),
                triangleOffset: UInt32(allTriangleIndices.count / 3),
                triangleCount: UInt32(currentTriangles.count),
                faceIndexFirst: currentFaceIndices.first ?? 0
            )
            meshlets.append(desc)

            allVertexIndices.append(contentsOf: currentVertices)
            for (a, b, c) in currentTriangles {
                allTriangleIndices.append(contentsOf: [a, b, c])
            }
            allFaceIndices.append(contentsOf: currentFaceIndices)

            currentVertices.removeAll(keepingCapacity: true)
            vertexMap.removeAll(keepingCapacity: true)
            currentTriangles.removeAll(keepingCapacity: true)
            currentFaceIndices.removeAll(keepingCapacity: true)
        }

        func canAddTriangle(_ i0: UInt32, _ i1: UInt32, _ i2: UInt32) -> Bool {
            var newVerts = 0
            if vertexMap[i0] == nil { newVerts += 1 }
            if vertexMap[i1] == nil { newVerts += 1 }
            if vertexMap[i2] == nil { newVerts += 1 }
            return currentVertices.count + newVerts <= kMeshletMaxVertices
                && currentTriangles.count + 1 <= kMeshletMaxTriangles
        }

        func addVertex(_ gIdx: UInt32) -> UInt8 {
            if let local = vertexMap[gIdx] { return local }
            let local = UInt8(currentVertices.count)
            vertexMap[gIdx] = local
            currentVertices.append(gIdx)
            return local
        }

        for t in 0..<triangleCount {
            if usedTriangles[t] { continue }

            let i0 = indices[t * 3]
            let i1 = indices[t * 3 + 1]
            let i2 = indices[t * 3 + 2]

            if !canAddTriangle(i0, i1, i2) {
                flushMeshlet()
            }

            let l0 = addVertex(i0)
            let l1 = addVertex(i1)
            let l2 = addVertex(i2)
            currentTriangles.append((l0, l1, l2))
            currentFaceIndices.append(faceIndices[t])
            usedTriangles[t] = true
        }
        flushMeshlet()

        guard !meshlets.isEmpty else { return nil }

        // Pad triangle indices to multiple of 4 for Metal alignment
        while allTriangleIndices.count % 4 != 0 {
            allTriangleIndices.append(0)
        }

        // Create Metal buffers
        guard
            let descBuf = device.makeBuffer(
                bytes: meshlets,
                length: meshlets.count * MemoryLayout<MeshletDescriptor>.stride,
                options: .storageModeShared
            )
        else { return nil }

        guard
            let viBuf = device.makeBuffer(
                bytes: allVertexIndices,
                length: allVertexIndices.count * MemoryLayout<UInt32>.size,
                options: .storageModeShared
            )
        else { return nil }

        guard
            let tiBuf = device.makeBuffer(
                bytes: allTriangleIndices,
                length: allTriangleIndices.count * MemoryLayout<UInt8>.size,
                options: .storageModeShared
            )
        else { return nil }

        guard
            let fiBuf = device.makeBuffer(
                bytes: allFaceIndices,
                length: allFaceIndices.count * MemoryLayout<Int32>.size,
                options: .storageModeShared
            )
        else { return nil }

        return MeshletBuffers(
            descriptorBuffer: descBuf,
            vertexIndexBuffer: viBuf,
            triangleIndexBuffer: tiBuf,
            faceIndexBuffer: fiBuf,
            meshletCount: meshlets.count
        )
    }

    // MARK: - Helpers

    private static func position(_ data: [Float], _ idx: Int) -> SIMD3<Float> {
        let b = idx * 6
        return SIMD3<Float>(data[b], data[b + 1], data[b + 2])
    }

    private static func normal(_ data: [Float], _ idx: Int) -> SIMD3<Float> {
        let b = idx * 6 + 3
        return SIMD3<Float>(data[b], data[b + 1], data[b + 2])
    }
}
