// ViewportBody.swift
// ViewportKit
//
// Geometry-source-agnostic input type for Metal rendering.

import simd

/// Render-time layering for a body.
///
/// `.geometry` participates in normal depth testing. `.overlay` is drawn after the
/// selection outline pass with an always-pass depth state, so the body is visible
/// even when occluded by other geometry, which is what manipulator widgets and similar
/// always-on-top UI affordances need.
public enum RenderLayer: Hashable, Sendable {
    case geometry
    case overlay
}

/// Pick stream a body belongs to.
///
/// `.userGeometry` results land in `ViewportController.pickResult`. `.widget`
/// results land in `ViewportController.widgetPickResult`, so consumers (e.g.,
/// OCCTSwiftAIS manipulators) can run their own pick handling without leaking
/// into the user selection stream.
public enum PickLayer: Hashable, Sendable {
    case userGeometry
    case widget
}

/// What primitive type the renderer should draw a body as.
///
/// Existing bodies default to `.mesh` (vertexData + indices + optional edges),
/// so this is source-compatible. `.point` switches the body to a point-cloud
/// pass that draws `vertices` as visible point sprites, ignoring `vertexData` and
/// `indices`. `.wire` is reserved for an explicit wire-only intent; today
/// such bodies render through the existing edge-only path with `.mesh` and
/// `.wire` is treated identically by the renderer.
///
/// Named to avoid collision with the pick-result `PrimitiveKind` enum
/// (`.face/.edge/.vertex`).
public enum BodyPrimitiveKind: Sendable, Hashable {
    case mesh
    case point
    case wire
}

/// Per-triangle highlight style. `.zero` alpha = no highlight; non-zero alpha
/// composites the given color over the base shading at that triangle.
///
/// A single 32-bit-aligned `SIMD4<Float>` keeps the per-triangle memory cheap
/// (16 bytes × triangle count) and gives the renderer a uniform layout for
/// `[[primitive_id]]`-indexed lookup.
public struct TriangleStyle: Hashable, Sendable {
    /// Highlight colour composited over the triangle's base shading, in linear RGBA.
    ///
    /// Alpha doubles as the on/off switch: 0 leaves the triangle untouched, and any alpha
    /// above 0 composites this colour over the base shading at that triangle.
    public var color: SIMD4<Float>

    public init(color: SIMD4<Float> = .zero) { self.color = color }

    /// The no-op style: alpha is 0, so the renderer skips this triangle.
    public static let none = TriangleStyle(color: .zero)
}

/// A renderable body for the Metal viewport.
///
/// Contains interleaved vertex data, triangle indices, and edge polylines
/// for shaded and wireframe rendering.
public struct ViewportBody: Identifiable, Sendable {

    // Auto-incrementing generation counter for cache invalidation.
    private nonisolated(unsafe) static var _nextGeneration: UInt64 = 0

    /// Unique identifier for this body.
    public var id: String

    /// Monotonic tag that changes every time a body is initialised.
    ///
    /// Each `ViewportBody.init` call takes the next value, so the renderer can compare
    /// generations to decide whether the GPU buffers it cached for this `id` are stale.
    public let generation: UInt64

    /// Interleaved vertex data: [px, py, pz, nx, ny, nz, ...] with stride 6.
    public var vertexData: [Float]

    /// Triangle indices for shaded rendering.
    public var indices: [UInt32]

    /// Pre-sampled polylines drawn by the wireframe and edge passes, in body-local space.
    ///
    /// Each inner array is one connected polyline, so its points are consecutive rather
    /// than paired per segment. Sampling is fixed when the body is built, unlike `arcs`.
    public var edges: [[SIMD3<Float>]]

    /// Analytic arc and circle feature edges, in body-local space (issue #48).
    ///
    /// Unlike `edges` (pre-sampled polylines), these are tessellated to line segments by
    /// the renderer **adaptively to projected size each frame**, so they stay smooth at
    /// any zoom independent of mesh density. Empty by default.
    public var arcs: [ViewportArc]

    /// Maps each triangle back to the B-Rep face it was tessellated from, for face selection.
    ///
    /// Parallel to the triangle count (`indices.count / 3`). Empty when the body has no
    /// B-Rep provenance, which leaves it pickable only as a whole.
    public var faceIndices: [Int32]

    /// Maps each drawn line segment back to the B-Rep edge it came from, for edge selection.
    ///
    /// Parallel to the line primitives of `edges` flattened
    /// (`[poly0.seg0, poly0.seg1, ..., poly1.seg0, ...]`). Empty leaves the body not
    /// edge-pickable.
    public var edgeIndices: [Int32]

    /// B-Rep vertex positions, drawn as point sprites in the pick pass so vertices can be picked.
    ///
    /// Each entry is one vertex position in body-local space. Empty leaves the body not
    /// vertex-pickable. Doubles as the bounding-box source for point-cloud bodies, which
    /// carry no `vertexData`.
    public var vertices: [SIMD3<Float>]

    /// Maps each entry of `vertices` back to its B-Rep vertex index, for vertex selection.
    ///
    /// Parallel to `vertices`. Empty means identity, so a pick result's `primitiveIndex` is
    /// already the vertex index.
    public var vertexIndices: [Int32]

    /// Per-point colour for point-cloud bodies, parallel to `vertices`.
    ///
    /// Empty (the default), or any count that does not match `vertices`, falls back to the
    /// body's `color` for every point. Read only by the point-cloud pass, so it has no
    /// effect unless `primitiveKind` is `.point`.
    public var vertexColors: [SIMD4<Float>]

    /// Radius of each point sprite in world units, for point-cloud bodies.
    ///
    /// Projected to a screen-space pixel size at draw time, then clamped by the shader to
    /// between 1 px and 64 px (Apple's `[[point_size]]` limit), so points stop tracking the
    /// world-space radius once they hit either end of that range.
    public var pointRadius: Float

    /// What primitive the renderer should draw this body as. `.mesh`
    /// (default) walks `vertexData`/`indices`/`edges` exactly as before.
    /// `.point` switches to the point-cloud pass and ignores the mesh +
    /// edge buffers.
    public var primitiveKind: BodyPrimitiveKind

    /// Per-triangle highlight overlay, e.g. to tint the triangles of a selected face.
    ///
    /// Empty (the default) skips the highlight pass for this body entirely. When populated,
    /// `count == indices.count / 3`.
    ///
    /// Set entries to non-zero-alpha colors to highlight specific triangles
    /// (e.g., the triangles of a selected face). The renderer composites the
    /// style color over the base shading in a dedicated pass with `.lessEqual`
    /// depth test, so identical-position highlights never silhouette-flicker.
    ///
    /// Mutating this field on an existing body forces the renderer to upload
    /// a fresh per-triangle style buffer; the rest of the body's GPU state
    /// (vertex / index / edge / point buffers) is preserved.
    public var triangleStyles: [TriangleStyle]

    /// Base colour in linear RGBA, used for shading when no `material` is set.
    ///
    /// The alpha channel doubles as opacity: any value below 1 moves the body out of the
    /// opaque pass into the depth-sorted transparent one (issue #53).
    public var color: SIMD4<Float>

    /// Perceptual surface roughness, from 0 (mirror) to 1 (fully rough); defaults to 0.5.
    ///
    /// Ignored when `material` is set, since `PBRMaterial` carries its own roughness.
    public var roughness: Float

    /// Metalness, from 0 (dielectric) to 1 (metal); defaults to 0.
    ///
    /// Ignored when `material` is set, since `PBRMaterial` carries its own metallic factor.
    public var metallic: Float

    /// Full PBR material, superseding the simpler `color`/`roughness`/`metallic` triple.
    ///
    /// Setting it unlocks what those three cannot express: clearcoat, IOR-driven F0, and
    /// emission. Read it through `effectiveMaterial` rather than directly, so the fallback
    /// to the legacy fields stays in one place.
    public var material: PBRMaterial?

    /// Whether this body should be rendered.
    public var isVisible: Bool

    /// Whether this body is written to the pick buffer, and so can be picked at all (issue #63).
    ///
    /// When `false` the body is still drawn, just left out of the pick pass, so it never wins
    /// a pick over the geometry behind it. Intended for always-on-top reference bodies (datum
    /// and ground planes, overlays) that should not steal face, edge or vertex picks.
    public var isPickable: Bool

    /// Render-time layer. `.overlay` bodies are drawn always-on-top.
    public var renderLayer: RenderLayer

    /// Pick stream this body belongs to. `.widget` results route to
    /// `ViewportController.widgetPickResult` instead of `pickResult`.
    public var pickLayer: PickLayer

    /// Model matrix applied to this body alone, on top of the scene-wide model matrix.
    ///
    /// Multiplied in the vertex shader, so moving a body (during a manipulator drag, say)
    /// costs a uniform update rather than a re-upload of its vertex data.
    public var transform: simd_float4x4

    /// De-interleaved triangle positions for the direct-mesh path, stride 3 (`[px, py, pz, …]`).
    ///
    /// Part of the Option A spike. When non-empty alongside `meshNormals`, the renderer uploads
    /// these straight to GPU buffers and skips the interleaved `vertexData`, so geometry from a
    /// kernel that already holds separate position/normal arrays (e.g. OCCT's
    /// `Poly_Triangulation`, surfaced as `Mesh.metalBufferData()`) renders without a CPU
    /// interleave/repack. Empty for the normal interleaved path.
    public var meshPositions: [Float]

    /// De-interleaved per-vertex normals for the direct-mesh path, stride 3.
    ///
    /// Parallel to `meshPositions`, and has to match it in length for the direct-mesh path to
    /// engage at all. See ``meshPositions``.
    public var meshNormals: [Float]

    /// Whether the renderer takes the direct-mesh path for this body instead of `vertexData`.
    ///
    /// True only when `meshPositions` is non-empty *and* `meshNormals` matches it in length, so
    /// a half-populated body silently falls back to the interleaved path rather than failing.
    /// See ``meshPositions``.
    public var usesDirectMesh: Bool {
        !meshPositions.isEmpty && meshNormals.count == meshPositions.count
    }

    public init(
        id: String,
        vertexData: [Float],
        indices: [UInt32],
        edges: [[SIMD3<Float>]],
        arcs: [ViewportArc] = [],
        faceIndices: [Int32] = [],
        edgeIndices: [Int32] = [],
        vertices: [SIMD3<Float>] = [],
        vertexIndices: [Int32] = [],
        vertexColors: [SIMD4<Float>] = [],
        triangleStyles: [TriangleStyle] = [],
        color: SIMD4<Float>,
        roughness: Float = 0.5,
        metallic: Float = 0.0,
        material: PBRMaterial? = nil,
        pointRadius: Float = 0.05,
        primitiveKind: BodyPrimitiveKind = .mesh,
        isVisible: Bool = true,
        isPickable: Bool = true,
        renderLayer: RenderLayer = .geometry,
        pickLayer: PickLayer = .userGeometry,
        transform: simd_float4x4 = matrix_identity_float4x4,
        meshPositions: [Float] = [],
        meshNormals: [Float] = []
    ) {
        ViewportBody._nextGeneration += 1
        self.generation = ViewportBody._nextGeneration
        self.id = id
        self.vertexData = vertexData
        self.indices = indices
        self.meshPositions = meshPositions
        self.meshNormals = meshNormals
        self.edges = edges
        self.arcs = arcs
        self.faceIndices = faceIndices
        self.edgeIndices = edgeIndices
        self.vertices = vertices
        self.vertexIndices = vertexIndices
        self.vertexColors = vertexColors
        self.triangleStyles = triangleStyles
        self.color = color
        self.roughness = roughness
        self.metallic = metallic
        self.material = material
        self.pointRadius = pointRadius
        self.primitiveKind = primitiveKind
        self.isVisible = isVisible
        self.isPickable = isPickable
        self.renderLayer = renderLayer
        self.pickLayer = pickLayer
        self.transform = transform
    }
}

// MARK: - Direct mesh (Option A spike)

extension ViewportBody {

    /// Builds a body from de-interleaved position/normal/index arrays, skipping the CPU repack.
    ///
    /// This is the shape a geometry kernel already produces (e.g. OCCT's `Mesh.vertexData`,
    /// `.normalData` and `.indices`), so nothing needs interleaving before upload: the renderer
    /// detects ``usesDirectMesh`` and uploads `positions`/`normals` to separate GPU buffers.
    ///
    /// `positions` and `normals` are stride-3 (`[x, y, z, …]`) and must be the same length.
    /// `vertices` (for bounding box, fit and CPU picking) is derived from `positions`.
    public static func directMesh(
        id: String,
        positions: [Float],
        normals: [Float],
        indices: [UInt32],
        color: SIMD4<Float>,
        faceIndices: [Int32] = [],
        edges: [[SIMD3<Float>]] = [],
        material: PBRMaterial? = nil,
        transform: simd_float4x4 = matrix_identity_float4x4
    ) -> ViewportBody {
        // Derive SIMD3 vertices for bounding box / fit / CPU raycast (cheap reshape, no normals).
        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(positions.count / 3)
        var i = 0
        while i + 2 < positions.count {
            verts.append(SIMD3(positions[i], positions[i + 1], positions[i + 2]))
            i += 3
        }
        return ViewportBody(
            id: id,
            vertexData: [],
            indices: indices,
            edges: edges,
            faceIndices: faceIndices,
            vertices: verts,
            vertexIndices: indices.map { Int32($0) },
            color: color,
            material: material,
            transform: transform,
            meshPositions: positions,
            meshNormals: normals
        )
    }
}

// MARK: - Effective material

extension ViewportBody {

    /// The material to shade this body with, resolving material-versus-legacy-fields in one place.
    ///
    /// Returns `material` when set, and otherwise synthesises a `PBRMaterial` from the legacy
    /// `color`/`roughness`/`metallic` fields, mapping `color.w` to opacity. Renderers should
    /// read this rather than either source directly.
    public var effectiveMaterial: PBRMaterial {
        if let material { return material }
        return PBRMaterial(
            baseColor: SIMD3<Float>(color.x, color.y, color.z),
            metallic: metallic,
            roughness: roughness,
            opacity: color.w
        )
    }
}

// MARK: - Bounding Box

extension ViewportBody {

    /// Computes the axis-aligned bounding box from vertex positions.
    ///
    /// Falls back to `vertices` when `vertexData` is empty, so point-cloud
    /// bodies (`primitiveKind == .point`) report a usable extent for
    /// shadow-pass framing, picking, and `CameraState.fit(to:)`.
    /// Returns `nil` if neither source has any points.
    public var boundingBox: BoundingBox? {
        let stride = 6
        let vertexCount = vertexData.count / stride
        if vertexCount > 0 {
            var bbMin = SIMD3<Float>(vertexData[0], vertexData[1], vertexData[2])
            var bbMax = bbMin
            for i in 1..<vertexCount {
                let base = i * stride
                let p = SIMD3<Float>(vertexData[base], vertexData[base + 1], vertexData[base + 2])
                bbMin = simd_min(bbMin, p)
                bbMax = simd_max(bbMax, p)
            }
            return BoundingBox(min: bbMin, max: bbMax)
        }

        guard let first = vertices.first else { return nil }
        var bbMin = first
        var bbMax = first
        for i in 1..<vertices.count {
            bbMin = simd_min(bbMin, vertices[i])
            bbMax = simd_max(bbMax, vertices[i])
        }
        return BoundingBox(min: bbMin, max: bbMax)
    }
}
