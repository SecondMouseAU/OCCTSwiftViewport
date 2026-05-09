# Changelog

All notable changes to OCCTSwiftViewport are documented in this file.

## [0.55.2] — 2026-05-04

### Fixed
- **xcodebuild conflicting-identity crash for downstream consumers** (issue #27). The demo target's `OCCTSwiftTools` dep is now a versioned remote URL (`from: "0.4.1"`) instead of `.package(path: "../OCCTSwiftTools")`. Pure-SPM (`swift build` / `swift test`) tolerated the path identity, but xcodebuild's SPM integration treated the path-identity and URL-identity as distinct packages with the same name and crashed in `IDESPMWorkspaceDelegate.registerDependencyFileReferences` whenever a downstream consumer (e.g. OCCTDesignLoop) also declared `OCCTSwiftTools` as a remote dep. Closes the option-(c) workaround that landed with #22 in v0.51.0; consumers can now adopt anything from `v0.51.0` onward in xcodeproj-based projects.

`project.yml` updated in lockstep so the regenerated Xcode project also pulls OCCTSwiftTools by URL.

## [0.55.1] — 2026-05-03

### Added

- **Per-triangle highlight overlay** (issue #25). Replaces the "cheap-route" overlay-body pattern OCCTSwiftAIS v0.1 used for face highlighting.
  - `ViewportBody.triangleStyles: [TriangleStyle]` — empty by default, no behavioural change. When populated (`count == indices.count / 3`), the renderer composites each non-zero-alpha entry over the base shading at that triangle.
  - `TriangleStyle` is a single `SIMD4<Float>` color (16 bytes per triangle). `TriangleStyle.none` and the zero-alpha default skip the highlight pass for that triangle.
  - New render pass between the shaded pass and the selection-outline pass. `MTLRenderPipelineState` (`triangle_highlight`) + `highlight_vertex` / `highlight_fragment` MSL shaders. Depth state is `.lessEqual` + write disabled, so identical-position highlights win the depth tie without disturbing depth state for subsequent passes.
  - Per-body `triangleStyleBuffer: MTLBuffer?` cached alongside the existing vertex / index / edge buffers; built only when `triangleStyles` is populated, nil otherwise. The fragment shader indexes by `[[primitive_id]]`.

### Why this beats the v0.1 cheap route

- **No silhouette flicker.** Identical geometry depth-tests cleanly with `.lessEqual` instead of needing the bbox-diagonal nudge.
- **No vertex-data churn.** Selection / hover state changes flip per-triangle alpha; no overlay body to spawn / kill on every selection change.
- **No body-count blow-up.** Style buffer scales with triangle count, not selection count.
- **Hover + multi-select for free.** Per-triangle style means hover at low alpha and primary selection at higher alpha can coexist without spawning N overlay bodies.

### Driver

OCCTSwiftAIS v0.6+ will adopt this and drop its `makeFaceOverlay(...)` cheap-route helper. Body-level selection still routes through `viewport.selectedBodyIDs` (already works).

### References

- [Issue #25](https://github.com/gsdali/OCCTSwiftViewport/issues/25)
- [OCCTSwiftAIS SPEC.md §"Hover / highlight rendering"](https://github.com/gsdali/OCCTSwiftAIS/blob/main/SPEC.md#hover--highlight-rendering)

## [0.55.0] — 2026-05-03

### Added
- **Edge / vertex picking** for OCCTSwiftAIS v0.3 (issue #24). The single GPU pick pass now resolves to face / edge / vertex via a 2-bit kind tag in the high bits of the pick raw value, so consumers get a uniform pick API across all three sub-shapes.
  - `ViewportBody` gains:
    - `edgeIndices: [Int32]` — per-line-segment source-edge index, parallel to the line primitives in `edges` flattened. Empty by default → body is not edge-pickable.
    - `vertices: [SIMD3<Float>]` — point list rendered as point sprites (8×8 px) for vertex picking. Empty by default → body is not vertex-pickable.
    - `vertexIndices: [Int32]` — per-point source-vertex index. Empty defaults to identity.
  - `PickResult.kind: PrimitiveKind` (`.face` / `.edge` / `.vertex`). New `PrimitiveKind` enum re-exported from the module.
  - Pick encoding: bits 0-15 objectIndex (unchanged), bits 16-29 primitiveID (14 bits, masked everywhere it's emitted — including the existing `pick_fragment` and `tessellated_pick_fragment`), bits 30-31 kind. `triangleIndex` keeps its name and now carries the primitive index for whatever kind matched.
  - New `pick_line_fragment`, `pick_point_vertex`, `pick_point_fragment` shaders; new `pickLinePipeline` + `pickPointPipeline` + `pickEdgeOrPointDepthState` (`.lessEqual`) so edges/vertices coplanar with a face win the pick over the face.
  - 8 new `PickResultTests` pin the encoding contract that AIS will rely on.

## [0.54.0] — 2026-05-03

### Changed
- **Bumped OCCTSwift dep to `from: "0.169.0"`** (was 0.168.0). v0.169 extends the `ImportProgress` channel to three more long-running operations: `Shape.meshWithProgress(linearDeflection:angularDeflection:progress:)`, `Exporter.writeSTEP(shape:to:progress:)` / `writeIGES(shape:to:progress:)`, and `Document.writeSTEP(to:progress:)`. New `Exporter.ExportError.cancelled` case.

### Added
- **v0.169 Mesh Progress demo** (`v169MeshProgress`): builds a sphere, runs `meshWithProgress` at fine deflection (4 progress callbacks observed end-to-end), then runs again with a cancel-after-first observer to verify `ImportError.cancelled`.
- **v0.169 Export Progress demo** (`v169ExportProgress`): builds a torus, runs `Exporter.writeSTEP` (7 callbacks), `Exporter.writeIGES` (3 callbacks), and `Document.writeSTEP` (7 callbacks) each with a recording observer, plus a STEP export with cancel-after-first that verifies `ExportError.cancelled`.

Both demos wired into the OCCT 8 sub-group of `SpikeView` and into the headless `--test-all-demos` runner (201 demos total).

## [0.53.0] — 2026-05-03

### Changed
- **Bumped OCCTSwift dep to `from: "0.168.0"`** (was 0.165.0). Pulls in:
  - v0.166.0 / v0.166.1 — Swift Package Index metadata + platform-plan docs (no API change).
  - v0.167.0 — visionOS + tvOS xcframework slices (no API change).
  - v0.168.0 — `ImportProgress` protocol + cooperative cancellation for `Shape.loadSTEP` / `loadIGES` / `loadIGESRobust` and `Document.load` / `loadSTEP`.

### Added
- **v0.168 Import Progress demo** in `OCCT8Gallery` (`v168ImportProgress`). Writes a small fused box+cylinder STEP, then re-loads three times: with a recording observer (75 progress callbacks at last run), with an observer that requests cancellation after the first callback (catches `ImportError.cancelled`), and with `progress: nil` to confirm source-compat. Wired into the OCCT 8 sub-group in `SpikeView` and into the headless `--test-all-demos` runner.

## [0.52.0] — 2026-05-03

### Added
- **Renderer-side support for OCCTSwiftAIS manipulator widgets** (issue #23):
  - `ViewportBody.renderLayer: RenderLayer` (`.geometry` / `.overlay`). Overlay bodies are drawn after the selection outline with `depthCompareFunction = .always`, so manipulator arrows remain grabbable even when occluded by their target body. Overlay bodies are also rendered into the pick texture with always-pass depth.
  - `ViewportBody.pickLayer: PickLayer` (`.userGeometry` / `.widget`). `ViewportController.pickResult` now exposes only user-geometry picks; `ViewportController.widgetPickResult` (new) carries widget-layer picks. A single GPU pick pass populates both via the body's layer. Adds `onWidgetPick` callback and `clearWidgetPick()`.
  - `ViewportBody.transform: simd_float4x4`. Drives the per-body model matrix in the main, shadow, pick, and selection-outline passes — manipulator drags can now move a body without re-uploading vertex data.
  - `PickResult.pickLayer` field; the existing `init(rawValue:indexMap:)` gains an optional `layerMap:` parameter (existing call sites stay source-compatible).

## [0.51.0] — 2026-05-03

### Removed (breaking)
- **`OCCTSwiftTools` library product** has been extracted to its own repository: <https://github.com/gsdali/OCCTSwiftTools>. Consumers depending on the viewport's `OCCTSwiftTools` product must migrate to the standalone package (`>= 0.1.0`). This unblocks SwiftPM target-name uniqueness and lets OCCTSwiftTools tag its v0.1.0 release.
  - Removed sources: `BodyUtilities.swift`, `CADFileLoader.swift`, `CurveConverter.swift`, `ExportManager.swift`, `ScriptManifest.swift`, `SurfaceConverter.swift`, `WireConverter.swift` (already mirrored in the standalone repo).

### Changed
- `OCCTSwiftMetalDemo` (executable, dev aid only — not a library product) now depends on the external `OCCTSwiftTools` package via a local path dep (`../OCCTSwiftTools`) so the demo continues to build during the transition. This will be switched to a versioned remote dep once `OCCTSwiftTools v0.1.0` is published.

## [0.26.0] — 2026-02-15

### Added
- **Annotation Gallery** (`AnnotationGallery.swift`): Demonstrates OCCTSwift AIS annotation features — dimension measurements, text labels, and colored point clouds.
  - Length dimensions (point-to-point) with rendered dimension geometry (extension lines, markers)
  - Radius & diameter dimensions on cylinders and spheres
  - Angle dimensions between edges and from three-point configurations
  - Text labels at 3D positions with marker spheres and leader lines
  - Colored point cloud (50 points, spherical distribution, height-colored)
- Sidebar section: **Annotation Demos**

## [0.25.0] — 2026-02-15

### Added
- **Naming Gallery** (`NamingGallery.swift`): Demonstrates OCCTSwift TNaming — topological naming history tracking on XDE documents.
  - Primitive history: creates a box, records it as a primitive, queries stored/current shape and naming history
  - Modification tracking: box → filleted box, records both steps, shows old (dim) vs new (shaded) with history
  - Forward/backward tracing: box − cylinder boolean, traces the naming graph in both directions
  - Named selection persistence: selects a face by name and resolves it back from the naming graph
- Sidebar section: **Naming Demos**

## [0.24.0] — 2026-02-15

### Added
- **Medial Axis Gallery** (`MedialAxisGallery.swift`): Computes and visualizes the Voronoi skeleton (medial axis) of planar shapes using OCCTSwift `MedialAxis` (BRepMAT2d).
  - Rectangle skeleton with inscribed circle node markers
  - L-shaped profile showing branching skeleton topology
  - Thickness map with arcs colored red (thin) to blue (thick) by wall distance
  - Custom T-profile skeleton with node/arc statistics
  - `computeForShape(_:)` API for use with STEP face selection
- Sidebar section: **Medial Axis Demos**

## [0.23.0] — 2026-02-15

### Added
- **Projection Gallery** (`ProjectionGallery.swift`): Projects 3D curves and points onto parametric surfaces using OCCTSwift `Surface.projectCurve3D`, `projectCurveSegments`, and `projectPoint`.
  - Curve on cylinder (diagonal line → helix on surface)
  - Curve on sphere (tilted circle → geodesic-like projection)
  - Composite projection with multi-segment UV coloring
  - Point projection with 20 scattered points, distance-colored lines (green=close, red=far)
- **Plate Gallery** (`PlateGallery.swift`): Creates and deforms plate surfaces using OCCTSwift `Surface.plateThrough`, `nlPlateDeformed` (G0), and `nlPlateDeformedG1` (G1).
  - Plate from scattered 3D points (terrain-like)
  - G0 position-constrained deformation (flat → curved)
  - G1 tangent-controlled deformation with direction arrows
- Sidebar sections: **Projection Demos**, **Plate Demos**

## [0.22.0] — 2026-02-15

### Added
- **Sweep Gallery** (`SweepGallery.swift`): Variable-section pipe sweeps using OCCTSwift `LawFunction` and `Shape.pipeShellWithLaw`.
  - Constant pipe (uniform cross-section)
  - Linear taper (narrowing from start to end)
  - S-curve sweep (smooth bulge)
  - Interpolated sweep (custom varying profile)
  - Each demo includes a 2D law function plot and spine wireframe overlay
- **GD&T display**: When STEP files with PMI data are loaded, dimensions, geometric tolerances, and datums are extracted and shown in a new **GD&T** sidebar section.

### Changed
- `CADLoadResult` now includes `dimensions: [DimensionInfo]`, `geomTolerances: [GeomToleranceInfo]`, and `datums: [DatumInfo]` arrays extracted from STEP documents via `Document.dimensions`, `Document.geomTolerances`, `Document.datums`.

## [0.21.0] — 2026-02-15

### Added
- **Surface Gallery** (`SurfaceGallery.swift`): Interactive surface demos using OCCTSwift `Surface` class.
  - Analytic surfaces: plane, cylinder, cone, sphere, torus (arranged in a row, trimmed, as UV grids)
  - Swept surfaces: extrusion along direction, revolution around axis
  - Freeform surfaces: 4×4 Bezier patch with control net overlay, 3×3 Bezier patch
  - Pipe surfaces: circular and elliptical cross-section pipes along curved spines
  - Iso-curves: U-iso (red) and V-iso (cyan) parameter curves highlighted on a Bezier surface
- Sidebar section: **Surface Demos**

## [0.20.0] — 2026-02-15

### Added
- **Curve3D Gallery** (`Curve3DGallery.swift`): 3D curve demos using OCCTSwift `Curve3D` class.
  - 3D curve showcase: line, circle, arc, ellipse, BSpline, Bezier in 3D space
  - Helix & spirals: helical interpolation, conical spiral, reversed + trimmed curves
  - Curvature combs: perpendicular comb teeth proportional to local curvature, with tip envelope
  - BSpline fitting: noisy point cloud with fitted curve (blue) vs exact interpolation (green)
- Sidebar section: **Curve3D Demos**

## [0.19.0] — 2026-02-15

### Added
- **3D geometry analysis in selection panel**: Selecting a face or edge on STEP geometry now shows rich property data in the selection info panel.
  - **Face selection**: surface type (Plane, Cylinder, BSpline, etc.), area, UV bounds, Gaussian curvature, mean curvature at the hit point
  - **Edge selection**: curve type (Line, Circle, BSpline, etc.), length, parameter bounds, curvature, projection distance at the hit point
- **Curvature direction overlays**: Toggleable overlays rendered at the selected point.
  - Faces: principal curvature directions (cyan kMin, magenta kMax) and surface normal (blue)
  - Edges: tangent direction (green), normal direction (blue), center of curvature (orange sphere + gray connector line)
- **Proximity detection**: "Check Proximity" button in the new **Analysis** sidebar section. When 2+ shapes are loaded, finds closest face pairs between shape 0 and shape 1, highlights them in color, and reports self-intersection status.
- Sidebar section: **Analysis** (curvature overlay toggle + proximity check)

## [0.18.0] — 2025-12-30

### Added
- Multi-format import (STEP, STL, OBJ) with face/edge/vertex selection
- Export to OBJ and PLY formats
- Shape healing operations (sew, upgrade, direct faces, convert to BSpline)
- Point classification (inside/outside/on boundary)

## [0.17.0] — 2025-12-30

### Added
- Curve2D gallery with showcase, intersections, hatching, and Gcc demos

## [0.16.0] — 2025-12-30

### Added
- STEP file import with face/edge/vertex selection
