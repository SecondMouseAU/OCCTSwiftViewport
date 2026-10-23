# OCCTSwiftViewport Metal Architecture

## Overview

This document describes the architecture for replacing OCCTSwiftViewport's RealityKit renderer with a direct Metal implementation, and how it integrates with OCCTSwift as the geometry source.

### Why Replace RealityKit

RealityKit is designed for AR experiences and general-purpose 3D content. For a CAD viewport, it creates friction:

- **No wireframe rendering.** RealityKit provides no API to render edges or wireframes. The current `DisplayMode.wireframe` and `.shadedWithEdges` modes cannot be implemented.
- **No render pipeline access.** Custom shaders, depth bias for edge overlay, transparency control, and x-ray modes are not possible.
- **Entity overhead.** Scene elements like the dot grid require hundreds of individual `ModelEntity` instances (961 for a 31x31 grid) instead of a single instanced draw call.
- **AR-centric camera model.** The `PerspectiveCamera` + manual `Transform` approach works but fights the framework's assumptions.

A direct Metal renderer eliminates all of these constraints. For the CAD use case (flat colors, wireframes, simple shading), the Metal code is small and the performance ceiling is dramatically higher.

### Layer Separation

```
+------------------+
|     Your App     |   Connects OCCTSwift geometry to OCCTSwiftViewport display.
+--------+---------+   Owns the domain logic (what to show, when to update).
         |
    +----+----+
    |         |
+---v---+ +---v--------+
|OCCTSwift| |OCCTSwiftViewport|   Two independent libraries.
|       | |                 |   No dependency between them.
+-------+ +-----------------+
 Geometry    Rendering
  kernel     + viewport
```

**OCCTSwift** produces geometry: `Shape` -> `Mesh` (vertices, normals, indices, face associations), edge polylines, bounding boxes. It has no knowledge of rendering.

**OCCTSwiftViewport** consumes geometry and renders it: camera, gestures, Metal pipeline, display modes, selection feedback, grid, axes. It has no knowledge of OCCT or B-Rep topology.

**The app** bridges the two: tessellates shapes, extracts edges, feeds the data to OCCTSwiftViewport, and maps selection hits back to OCCT faces/edges.

This separation means:
- OCCTSwift can be used with any renderer (SceneKit, game engines, headless testing)
- OCCTSwiftViewport can display geometry from any source (procedural, file parsers, other CAD kernels)
- Either library can be replaced independently

---

## Data Flow

### Shape to Screen

```
OCCTSwift                          App                           OCCTSwiftViewport
---------                          ---                           -----------
Shape.mesh(params)          -->  Mesh                     -->  viewport.setMesh(...)
  .vertexData: [Float]             extract raw buffers           Metal vertex buffer
  .normalData: [Float]             per-body colors               Metal normal buffer
  .indices: [UInt32]               edge polylines                Metal index buffer
  .trianglesWithFaces()                                          face-index buffer

Shape.edges()               -->  [Edge]                   -->  viewport.setEdges(...)
  .points(count:): [SIMD3]        discretize to polylines       Metal line vertex buffer

Shape.boundingBox           -->  (min, max)               -->  viewport.focusOn(bounds:)
```

### Selection (Screen to Shape)

```
OCCTSwiftViewport                  App                           OCCTSwift
-----------                        ---                           ---------
User taps screen
  --> ray cast from camera
  --> intersect triangles
  --> HitResult {
        position: SIMD3<Float>,
        triangleIndex: Int,
        bodyIndex: Int
      }
                              -->  Map triangleIndex to          Shape.faces()[faceIndex]
                                   faceIndex via Mesh              --> highlight, inspect,
                                   .trianglesWithFaces()              or modify
```

The key data structure enabling this round-trip is `Triangle.faceIndex` from OCCTSwift's `Mesh.trianglesWithFaces()`. Each mesh triangle carries the index of the B-Rep face it was tessellated from. OCCTSwiftViewport doesn't interpret this value -- it stores it per-triangle and returns it in hit results. The app uses it to index back into the OCCT topology.

---

## OCCTSwiftViewport Public API

### Core Types

```swift
/// A renderable body in the viewport. Geometry-source agnostic.
public struct ViewportBody: Identifiable, Sendable {
    public let id: String

    /// Interleaved vertex data: [px, py, pz, nx, ny, nz, ...]
    /// Stride: 6 floats per vertex.
    public var vertexData: [Float]

    /// Triangle indices (3 per triangle).
    public var indices: [UInt32]

    /// Per-triangle source face index (parallel to triangle count).
    /// Used for selection mapping. Pass empty array if not needed.
    public var faceIndices: [Int32]

    /// Edge polylines for wireframe rendering.
    /// Each inner array is one polyline: [p0, p1, p2, ...] as SIMD3<Float>.
    public var edges: [[SIMD3<Float>]]

    /// Display color (RGBA, 0-1).
    public var color: SIMD4<Float>

    /// Per-face colors, indexed by face index. Overrides body color
    /// for individual faces (e.g. selection highlighting).
    /// Pass empty dictionary for uniform color.
    public var faceColors: [Int32: SIMD4<Float>]

    /// Opacity (0-1). Values < 1 enable transparency.
    public var opacity: Float

    /// Whether this body is visible.
    public var isVisible: Bool

    /// Whether this body participates in hit testing.
    public var isSelectable: Bool
}
```

```swift
/// Result of a hit test against viewport geometry.
public struct HitResult: Sendable {
    /// ID of the body that was hit.
    public let bodyID: String

    /// World-space position of the hit.
    public let position: SIMD3<Float>

    /// Index of the triangle that was hit.
    public let triangleIndex: Int

    /// Source face index from the body's faceIndices array.
    /// -1 if the body has no face index data.
    public let faceIndex: Int32

    /// Distance from the camera to the hit point.
    public let distance: Float
}
```

### ViewportView (Revised)

```swift
public struct ViewportView: View {
    public init(
        controller: ViewportController,
        bodies: [ViewportBody]
    )
}
```

The `entities: [Entity]` parameter from the RealityKit version is replaced with `bodies: [ViewportBody]`. Bodies are plain value types -- no RealityKit dependency.

### ViewportController Extensions

The existing `ViewportController` API (camera, gestures, display modes, toggles) remains unchanged. New additions:

```swift
extension ViewportController {
    /// Perform a hit test at a screen point.
    /// Returns hits sorted by distance (nearest first).
    @MainActor
    public func hitTest(at point: CGPoint) -> [HitResult]

    /// Focus the camera to frame the given bounding box.
    public func focusOn(
        min: SIMD3<Float>,
        max: SIMD3<Float>,
        animated: Bool = true
    )
}
```

### App-Level Usage

```swift
import OCCTSwift
import OCCTSwiftViewport

struct CADView: View {
    @StateObject private var controller = ViewportController(
        configuration: .cad
    )
    @State private var bodies: [ViewportBody] = []

    let shape: Shape

    var body: some View {
        ViewportView(controller: controller, bodies: bodies)
            .onAppear { loadGeometry() }
    }

    func loadGeometry() {
        let mesh = shape.mesh(linearDeflection: 0.1)

        // Extract edge polylines for wireframe
        let edges: [[SIMD3<Float>]] = shape.edges().map { edge in
            edge.points(count: 64)
        }

        // Build interleaved vertex data [px, py, pz, nx, ny, nz, ...]
        let verts = mesh.vertexData   // [px, py, pz, ...]
        let norms = mesh.normalData   // [nx, ny, nz, ...]
        var interleaved = [Float]()
        interleaved.reserveCapacity(mesh.vertexCount * 6)
        for i in 0..<mesh.vertexCount {
            interleaved.append(verts[i * 3])
            interleaved.append(verts[i * 3 + 1])
            interleaved.append(verts[i * 3 + 2])
            interleaved.append(norms[i * 3])
            interleaved.append(norms[i * 3 + 1])
            interleaved.append(norms[i * 3 + 2])
        }

        // Face indices for selection mapping
        let tris = mesh.trianglesWithFaces()
        let faceIndices = tris.map { $0.faceIndex }

        bodies = [
            ViewportBody(
                id: "part-1",
                vertexData: interleaved,
                indices: mesh.indices,
                faceIndices: faceIndices,
                edges: edges,
                color: SIMD4(0.7, 0.7, 0.7, 1.0),
                faceColors: [:],
                opacity: 1.0,
                isVisible: true,
                isSelectable: true
            )
        ]
    }
}
```

---

## Metal Renderer

### Architecture

```
ViewportView (SwiftUI)
  |
  +-- MetalViewRepresentable (UIViewRepresentable / NSViewRepresentable)
        |
        +-- MTKView (drawable surface)
              |
              +-- ViewportRenderer (MTKViewDelegate)
                    |
                    +-- Pipelines:
                    |     ShadedPipeline      (triangles, lit, flat color)
                    |     WireframePipeline    (lines, constant color, depth bias)
                    |     GridPipeline         (instanced dots or lines)
                    |     AxisPipeline         (colored cylinders, optional screen-space)
                    |
                    +-- Buffers:
                    |     Per-body vertex/index/faceIndex buffers
                    |     Uniform buffer (MVP, camera, lighting)
                    |     Grid instance buffer
                    |
                    +-- RenderGraph:
                          1. Clear (background color)
                          2. Grid (if enabled)
                          3. Axes (if enabled)
                          4. Bodies - opaque pass (sorted front-to-back)
                          5. Wireframe overlay (if display mode includes edges)
                          6. Bodies - transparent pass (sorted back-to-front)
                          7. Selection highlight overlay
```

### Shader Design

The rendering requirements are minimal. Four shader pairs cover all display modes.

#### Vertex Layout

```metal
struct Vertex {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
};
```

Matches the interleaved `[px, py, pz, nx, ny, nz]` layout of `ViewportBody.vertexData`. Stride: 24 bytes.

#### Uniforms

```metal
struct Uniforms {
    float4x4 modelMatrix;
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4x4 normalMatrix;      // transpose(inverse(modelView)), for lighting
    float3   cameraPosition;
    float3   lightDirection;     // single directional light
    float    lightIntensity;
    float    ambientIntensity;
};

struct BodyUniforms {
    float4 color;
    float  opacity;
    int    faceIndexOffset;     // offset into face-index buffer for this body
};
```

#### Shaded Pipeline (triangles, lit)

```metal
vertex VertexOut shaded_vertex(
    Vertex in [[stage_in]],
    constant Uniforms& u [[buffer(1)]]
) {
    VertexOut out;
    float4 worldPos = u.modelMatrix * float4(in.position, 1.0);
    out.position = u.projectionMatrix * u.viewMatrix * worldPos;
    out.worldNormal = (u.normalMatrix * float4(in.normal, 0.0)).xyz;
    out.worldPosition = worldPos.xyz;
    return out;
}

fragment float4 shaded_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(1)]],
    constant BodyUniforms& body [[buffer(2)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(-u.lightDirection);
    float diffuse = max(dot(N, L), 0.0) * u.lightIntensity;
    float ambient = u.ambientIntensity;
    float3 color = body.color.rgb * (diffuse + ambient);
    return float4(color, body.opacity);
}
```

This handles `DisplayMode.shaded`, `.flat` (skip normal interpolation), and `.rendered`. The fragment shader is intentionally simple -- no specular, no PBR. For CAD, diffuse + ambient with a single directional light is the standard.

#### Wireframe Pipeline (lines, depth-biased)

```metal
vertex float4 wireframe_vertex(
    float3 position [[attribute(0)]],
    constant Uniforms& u [[buffer(1)]]
) {
    float4 worldPos = u.modelMatrix * float4(position, 1.0);
    float4 clipPos = u.projectionMatrix * u.viewMatrix * worldPos;
    // Depth bias: pull edges slightly toward camera to prevent z-fighting
    clipPos.z -= 0.0001 * clipPos.w;
    return clipPos;
}

fragment float4 wireframe_fragment(
    constant BodyUniforms& body [[buffer(2)]]
) {
    return float4(body.color.rgb * 0.2, 1.0);  // darker than face color
}
```

Used for `DisplayMode.wireframe` (edges only) and `.shadedWithEdges` (edges overlaid on shaded pass). The edge vertex buffer contains polyline segments from `ViewportBody.edges`, drawn as `MTLPrimitiveType.line`.

#### X-Ray Pipeline (transparent, back-faces visible)

```metal
// Same vertex shader as shaded. Fragment shader adds transparency:
fragment float4 xray_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(1)]],
    constant BodyUniforms& body [[buffer(2)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(u.cameraPosition - in.worldPosition);
    // Fresnel-like falloff: more opaque at glancing angles
    float facing = abs(dot(N, V));
    float alpha = mix(0.4, 0.1, facing);
    return float4(body.color.rgb * 0.5, alpha);
}
```

The x-ray pipeline renders with both front and back face culling disabled, blending enabled, and depth writes disabled. This gives the classic CAD x-ray look where internal edges and surfaces are visible.

#### Grid Pipeline (instanced)

```metal
struct GridInstance {
    float2 offset;
};

vertex float4 grid_vertex(
    float3 position [[attribute(0)]],          // unit quad
    constant Uniforms& u [[buffer(1)]],
    constant GridInstance* instances [[buffer(2)]],
    uint instanceID [[instance_id]]
) {
    float3 worldPos = position;
    worldPos.xz += instances[instanceID].offset;
    return u.projectionMatrix * u.viewMatrix * float4(worldPos, 1.0);
}
```

One draw call renders all 961 grid dots via instancing. The instance buffer contains the 2D offsets. When grid spacing changes, only the instance buffer is rebuilt -- the mesh (a single tiny quad) never changes.

### Display Mode Mapping

| DisplayMode       | Passes                                                        |
|--------------------|---------------------------------------------------------------|
| `.wireframe`       | Wireframe only (edges as lines)                               |
| `.shaded`          | Shaded triangles                                              |
| `.shadedWithEdges` | Shaded triangles, then wireframe overlay with depth bias      |
| `.flat`            | Shaded triangles with flat (face) normals instead of smooth   |
| `.xray`            | X-ray pass (transparent, no depth write), then wireframe      |
| `.rendered`        | Same as shaded (no PBR needed for CAD)                        |

### Buffer Management

Each `ViewportBody` maps to a set of Metal buffers:

```swift
struct BodyBuffers {
    let vertexBuffer: MTLBuffer      // interleaved positions + normals
    let indexBuffer: MTLBuffer       // triangle indices
    let faceIndexBuffer: MTLBuffer?  // per-triangle face index (for picking)
    let edgeVertexBuffer: MTLBuffer? // edge polyline vertices
    let edgeIndexBuffer: MTLBuffer?  // line segment indices
    let triangleCount: Int
    let edgeVertexCount: Int
}
```

Buffers are created/updated when `bodies` changes. The renderer diffs body IDs to avoid recreating buffers for unchanged bodies.

```swift
func updateBuffers(bodies: [ViewportBody], device: MTLDevice) {
    var newBufferMap: [String: BodyBuffers] = [:]

    for body in bodies {
        if let existing = bufferMap[body.id], !bodyChanged(body, existing) {
            newBufferMap[body.id] = existing  // reuse
        } else {
            newBufferMap[body.id] = createBuffers(for: body, device: device)
        }
    }

    bufferMap = newBufferMap
}
```

### Camera Integration

The existing `CameraState` already computes everything Metal needs:

```swift
// In ViewportRenderer, each frame:
var uniforms = Uniforms()
uniforms.viewMatrix = cameraState.viewMatrix        // new computed property
uniforms.projectionMatrix = cameraState.projectionMatrix(
    aspectRatio: Float(drawableSize.width / drawableSize.height)
)
uniforms.cameraPosition = cameraState.position
```

`CameraState` needs two new computed properties:

```swift
extension CameraState {
    /// View matrix (world -> camera space).
    public var viewMatrix: simd_float4x4 {
        let pos = position
        let target = pivot
        let up = upVector
        return simd_float4x4(lookAt: target, from: pos, up: up)
    }

    /// Projection matrix for the given aspect ratio.
    public func projectionMatrix(aspectRatio: Float) -> simd_float4x4 {
        if isOrthographic {
            let halfWidth = orthographicScale * aspectRatio / 2
            let halfHeight = orthographicScale / 2
            return simd_float4x4(
                orthographic: -halfWidth...halfWidth,
                bottom: -halfHeight, top: halfHeight,
                near: 0.01, far: maxDistance * 2
            )
        } else {
            return simd_float4x4(
                perspectiveFOV: fieldOfView * .pi / 180,
                aspectRatio: aspectRatio,
                near: 0.01,
                far: maxDistance * 2
            )
        }
    }
}
```

These replace the implicit projection that RealityKit's `PerspectiveCamera` was providing.

---

## Hit Testing (Selection)

### GPU Picking vs CPU Ray Casting

Two viable approaches:

**CPU ray casting** (recommended for initial implementation):
- Cast a ray from the camera through the tap point
- Intersect against all triangle meshes on CPU
- Use the face-index array to map hit triangle -> OCCT face
- Simple, no GPU readback latency, works on all hardware
- Performance: fine for < 100K triangles; for larger scenes, add a BVH

**GPU picking** (future optimisation):
- Render a face-index buffer to an offscreen texture (each pixel stores the face index)
- Read back the pixel at the tap point
- One draw call, constant time regardless of triangle count
- Requires an additional render pass and GPU -> CPU readback

### CPU Ray Cast Implementation

```swift
struct Ray {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>
}

func hitTest(ray: Ray, bodies: [ViewportBody]) -> [HitResult] {
    var hits: [HitResult] = []

    for body in bodies where body.isSelectable && body.isVisible {
        let vertices = body.vertexData  // stride 6
        let indices = body.indices

        for tri in 0..<(indices.count / 3) {
            let i0 = Int(indices[tri * 3])
            let i1 = Int(indices[tri * 3 + 1])
            let i2 = Int(indices[tri * 3 + 2])

            let v0 = SIMD3(vertices[i0*6], vertices[i0*6+1], vertices[i0*6+2])
            let v1 = SIMD3(vertices[i1*6], vertices[i1*6+1], vertices[i1*6+2])
            let v2 = SIMD3(vertices[i2*6], vertices[i2*6+1], vertices[i2*6+2])

            if let t = rayTriangleIntersection(ray: ray, v0: v0, v1: v1, v2: v2) {
                let position = ray.origin + ray.direction * t
                let faceIndex = tri < body.faceIndices.count
                    ? body.faceIndices[tri] : -1

                hits.append(HitResult(
                    bodyID: body.id,
                    position: position,
                    triangleIndex: tri,
                    faceIndex: faceIndex,
                    distance: t
                ))
            }
        }
    }

    return hits.sorted { $0.distance < $1.distance }
}
```

The `rayTriangleIntersection` function implements the Moller-Trumbore algorithm. Standard, fast, no dependencies.

### Selection Highlighting

When the app receives a `HitResult`, it can highlight the hit face by setting a face color:

```swift
func onTap(at point: CGPoint) {
    let hits = controller.hitTest(at: point)
    guard let hit = hits.first else { return }

    // Highlight the tapped face
    bodies[bodyIndex(for: hit.bodyID)].faceColors = [
        hit.faceIndex: SIMD4(0.2, 0.5, 1.0, 1.0)  // blue highlight
    ]
}
```

The renderer handles per-face coloring by checking the face-index buffer during fragment shading. If a face index has an entry in `faceColors`, that color is used instead of the body color. This avoids regenerating any buffers for selection feedback.

Implementation in the fragment shader:

```metal
fragment float4 shaded_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms& u [[buffer(1)]],
    constant BodyUniforms& body [[buffer(2)]],
    constant int32_t* faceIndices [[buffer(3)]],   // per-triangle
    constant float4* faceColors [[buffer(4)]],     // sparse override table
    constant int& faceColorCount [[buffer(5)]],
    uint primitiveID [[primitive_id]]
) {
    float4 baseColor = body.color;

    // Check for per-face color override
    int32_t faceIdx = faceIndices[primitiveID + body.faceIndexOffset];
    for (int i = 0; i < faceColorCount; i++) {
        // faceColors is packed as [faceIndex (as float), r, g, b, a, ...]
        // (actual implementation would use a lookup buffer)
    }

    // ... lighting as before ...
}
```

A cleaner approach for the sparse face-color lookup is a small buffer of (faceIndex, color) pairs, searched linearly in the shader. With typical selection counts (1-10 faces), this is effectively free.

---

## Grid and Axes

> **Shipped implementation (issue #136):** the grid lies in the XY plane of the Z-up world and
> honours `gridStyle` (`.plane` = translucent fill + minor/major lines, `.dots` = instanced dots)
> and `gridSize`; the axes are unit cylinders scaled per draw by `axisLength` / `axisRadius`, with
> `axisStyle == .constantScreenWidth` scaling the radius by the visible view height. See
> `Renderer/GridAxisGeometry.swift` and `RendererSharedSetup.encodeGrid` / `encodeAxes`. The
> sketches below are the original design.

### Grid (Metal)

The adaptive dot grid algorithm from the current implementation carries over, but rendering changes from 961 entities to one instanced draw call:

```swift
struct GridRenderer {
    let dotMesh: MTLBuffer          // 4 vertices for a tiny quad
    var instanceBuffer: MTLBuffer   // 961 x GridInstance (float2 offset)
    var currentSpacing: Float = 0

    mutating func update(
        cameraState: CameraState,
        config: ViewportConfiguration,
        device: MTLDevice
    ) {
        let spacing = computeSpacing(
            distance: cameraState.distance,
            fov: cameraState.fieldOfView,
            baseSpacing: config.gridBaseSpacing,
            subdivisions: config.gridSubdivisions
        )

        guard spacing != currentSpacing else { return }
        currentSpacing = spacing

        // Rebuild instance buffer (961 offsets)
        var instances = [SIMD2<Float>]()
        let pivot = cameraState.pivot
        let cx = (pivot.x / spacing).rounded() * spacing
        let cz = (pivot.z / spacing).rounded() * spacing

        for ix in -15...15 {
            for iz in -15...15 {
                instances.append(SIMD2(
                    cx + Float(ix) * spacing,
                    cz + Float(iz) * spacing
                ))
            }
        }

        instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )!
    }

    func draw(encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(dotMesh, offset: 0, index: 0)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: 6,           // two triangles for quad
            indexType: .uint16,
            indexBuffer: quadIndices,
            indexBufferOffset: 0,
            instanceCount: 961
        )
    }
}
```

One draw call instead of 961 entities. The spacing algorithm is identical to the current implementation.

### Axes (Metal)

Axes are three coloured cylinders. For the `.constantScreenWidth` style, scale the radius uniform instead of the entity transform:

```swift
struct AxisRenderer {
    let cylinderMesh: MTLBuffer     // shared cylinder geometry
    let cylinderIndices: MTLBuffer

    func draw(
        encoder: MTLRenderCommandEncoder,
        config: ViewportConfiguration,
        cameraState: CameraState
    ) {
        let radius: Float
        if config.axisStyle == .constantScreenWidth {
            let scale = cameraState.distance / config.initialCameraState.distance
            radius = config.axisRadius * scale
        } else {
            radius = config.axisRadius
        }

        // Draw X (red), Y (green), Z (blue) with per-axis model matrix
        for (color, modelMatrix) in axisTransforms(length: config.axisLength) {
            var bodyUniforms = BodyUniforms(color: color, opacity: 1.0)
            encoder.setVertexBytes(&bodyUniforms, length: ..., index: 2)
            // ... set model matrix, draw
        }
    }
}
```

Three draw calls total for all axes. The cylinder mesh is generated once at initialisation.

---

## SwiftUI Integration

### MetalViewRepresentable

```swift
#if os(iOS)
struct MetalViewRepresentable: UIViewRepresentable {
    let renderer: ViewportRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(...)
        view.preferredFramesPerSecond = configuration.preferredFramesPerSecond  // default 120
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // Trigger buffer updates when bodies change
        renderer.bodiesDidChange()
    }
}
#elseif os(macOS)
struct MetalViewRepresentable: NSViewRepresentable {
    // Same pattern with NSView
}
#endif
```

### Gesture Handling

The existing gesture architecture (SwiftUI gestures on macOS, UIKit two-finger pan on iOS) attaches to the `MetalViewRepresentable` the same way it currently attaches to `RealityView`. The `ViewportController` API is unchanged -- gestures still call `handleOrbit`, `handlePan`, `handleZoom`, etc.

The only addition is tap-to-select:

```swift
#if os(iOS)
private var tapGesture: some Gesture {
    SpatialTapGesture()
        .onEnded { value in
            let hits = controller.hitTest(at: value.location)
            onHit?(hits.first)
        }
}
#endif
```

---

## Migration Path

### Phase 1: Metal Renderer (core)

Replace `RealityView` with `MTKView`. Implement:
- `ViewportRenderer` (MTKViewDelegate)
- Shaded pipeline (triangles with flat-color lighting)
- Wireframe pipeline (line rendering with depth bias)
- Uniform management (MVP from CameraState)
- `ViewportBody` as the geometry input type
- `MetalViewRepresentable` for SwiftUI

At this point, `DisplayMode.shaded`, `.wireframe`, and `.shadedWithEdges` all work. The grid and axes render via Metal instead of entities.

### Phase 2: Selection

Implement:
- CPU ray casting (`hitTest`)
- Face-index buffer plumbing
- `HitResult` type
- Per-face colour overrides in the fragment shader
- Tap gesture integration

### Phase 3: Advanced Display Modes

Implement:
- X-ray pipeline (transparency, no depth write, fresnel falloff)
- Flat shading (face normals instead of vertex normals)
- Section planes (clip via fragment discard or stencil)

### Phase 4: Performance

If needed for large models:
- BVH for ray casting
- Frustum culling per body
- GPU picking (offscreen face-index render pass)
- LOD (multiple tessellation levels per body, select by distance)

### What Gets Removed

- `RealityKit` import and all `RealityKit` types
- `RealityView` make/update closures
- `Entity`-based grid and axis management
- `PerspectiveCamera` setup
- The `entities: [Entity]` parameter on `ViewportView`

### What Stays Unchanged

- `ViewportController` (camera state, gesture handling, display mode, toggles)
- `CameraState` (with new `viewMatrix` / `projectionMatrix` computed properties)
- `CameraController` (orbit, pan, zoom, inertia, animation)
- `ViewportConfiguration` (all settings, including the new axis/grid properties)
- `GestureConfiguration` (sensitivity, inertia, key mappings)
- `DisplayMode` enum (cases and properties)
- `StandardView` and `ViewCubeView`
- All gesture code (iOS two-finger pan, macOS modifier keys, etc.)

---

## File Structure (Projected)

```
Sources/OCCTSwiftViewport/
  Camera/
    CameraState.swift              (+ viewMatrix, projectionMatrix)
    CameraController.swift         (unchanged)
    RotationStyle.swift            (unchanged)
    StandardView.swift             (unchanged)
  Configuration/
    ViewportConfiguration.swift    (unchanged)
    GestureConfiguration.swift     (unchanged)
  Display/
    DisplayMode.swift              (unchanged)
    LightingConfiguration.swift    (unchanged)
  Renderer/                        (new directory)
    ViewportRenderer.swift         (MTKViewDelegate, render loop)
    ShadedPipeline.swift           (triangle rendering)
    WireframePipeline.swift        (edge rendering)
    XRayPipeline.swift             (transparent pass)
    GridRenderer.swift             (instanced dot grid)
    AxisRenderer.swift             (coloured cylinders)
    Shaders.metal                  (all MSL shaders)
    BufferManager.swift            (body -> Metal buffer management)
    HitTesting.swift               (ray casting, Moller-Trumbore)
  Views/
    ViewportView.swift             (rewritten: MTKView instead of RealityView)
    ViewportController.swift       (+ hitTest method)
    ViewCubeView.swift             (unchanged)
    MetalViewRepresentable.swift   (new: UIViewRepresentable/NSViewRepresentable)
  Types/                           (new directory)
    ViewportBody.swift             (geometry input type)
    HitResult.swift                (selection output type)
```

---

## Dependencies

After migration:
- **Metal** (system framework) -- rendering
- **MetalKit** (system framework) -- MTKView
- **simd** (system framework) -- math types
- **SwiftUI** (system framework) -- view integration
- **Combine** (system framework) -- controller state observation

RealityKit is removed entirely. No external dependencies.

---

## Performance Characteristics

| Operation | RealityKit (current) | Metal (projected) |
|-----------|---------------------|-------------------|
| Grid (961 dots) | 961 entities, 961 draw calls | 1 instanced draw call |
| Wireframe | Not possible | 1 draw call per body |
| Shaded + edges | Not possible | 2 draw calls per body |
| Body with 50K triangles | 1 RealityKit entity | 1 draw call |
| Selection highlight | Regenerate entity material | Update 16-byte uniform |
| X-ray mode | Not possible | 1 draw call per body |
| Memory (grid) | ~961 Entity objects + components | ~8 KB instance buffer |

The Metal renderer should maintain 60 fps for scenes with < 1M triangles on any Apple Silicon device. For reference, a typical mechanical assembly (100 parts) tessellated at interactive quality produces ~200K-500K triangles total.
