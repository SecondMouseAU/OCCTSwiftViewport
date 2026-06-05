# Changelog

All notable changes to OCCTSwiftViewport are documented in this file.

## [1.1.4] — 2026-06-05

### Added
- **`GestureConfiguration.visionOS` preset** (issue #36, Phase 2) — a spatial-input starting point for windowed / volumetric visionOS. Keeps the touch-style mapping (single pinch-drag orbits; two-handed pinch/twist zoom/roll) and raises inertia damping for more predictable settling with indirect (pinch + look) input. Re-exported via `_GestureConfiguration`. The demo adopts it automatically on visionOS.
  - New preset test (113 total). Builds + runs on the Vision Pro simulator.

> The exact sensitivities are a starting point: indirect spatial input feels different from a touchscreen, so final tuning — and richer `SpatialEventGesture` integration — is best done on Vision Pro hardware. Tracked in #36 (Phase 2 refinement); immersive / XR is Phase 3.

## [1.1.3] — 2026-06-05

### Changed
- **Reduced per-body CPU overhead in the main draw pass** (issue #42, part 3) — closes #42. Each visible body's GPU buffers and stable pick index are now resolved **once per frame** into a single list that the main geometry pass iterates, instead of re-filtering `bodies` and re-hashing the `String`-keyed `bodyBufferCache[body.id]` on the pass. Frustum culling moved inline on that list using the cached local AABB, dropping the separate per-frame `Set<String>` and its extra per-body hash. No render or API change (verified unchanged on the Vision Pro simulator); 112 tests green.

The remaining larger lever for extreme body counts — merging many small static bodies — is consumer-side and documented in the README "Performance & Scaling" section.

## [1.1.2] — 2026-06-05

### Added
- **Per-body frustum culling** (issue #42, part 2) — the main lever for large scenes. Bodies whose world-space bounds fall entirely outside the camera are skipped in the main geometry pass, so cost scales with what's *on screen* rather than total body count.
  - New `Frustum` (Gribb–Hartmann plane extraction, Metal `[0,1]` depth) with a conservative AABB `intersects(_:)`, and `BoundingBox.transformed(by:)` for world-space bounds (identity-transform fast path).
  - Per-body local AABBs are computed once and cached in the renderer's buffer cache (no per-frame vertex rescans); the culled set is built once per frame.
  - Pick-ID indices stay stable (culled bodies still advance the object index). The shadow pass is **not** camera-culled (off-screen casters can shadow visible geometry); bodies with no bounding box are never culled.
  - New `ViewportConfiguration.enableFrustumCulling` (default `true` — off-screen bodies aren't visible anyway; set `false` to opt out).
  - New `Frustum`/`BoundingBox.transformed` tests (8 → 112 total). Verified rendering unchanged on the Vision Pro simulator.

Per-body CPU overhead reduction continues in #42 (part 3).

## [1.1.1] — 2026-06-05

### Added
- **`ViewportConfiguration.performance` preset** (issue #42, part 1) — a discoverable fast path for large / many-body scenes on mobile. Disables the per-frame whole-scene passes that dominate cost on big models: directional shadow map, SSAO, MSAA (sample count 1), and silhouettes. Replaces hand-assembling those levers.
- **README "Performance & Scaling" section** — guidance on the two cost sources (per-frame passes vs per-body CPU overhead), batching many small static bodies into shared-material `ViewportBody`s (keeping sub-component picking via `faceIndices`), and recommended body counts.
- New `ViewportConfigurationTests` (2 tests → 104 total).

Renderer-side scaling (frustum culling, reduced per-body overhead) continues in #42.

## [1.1.0] — 2026-06-05

### Added
- **visionOS platform support (windowed / shared space)** — Phases 0+1 of #36. The viewport now builds and runs on visionOS, rendering through the existing UIKit `MTKView` + SwiftUI gesture path in a window / volume. Verified end-to-end on the Apple Vision Pro simulator (visionOS 26.5).
  - `Package.swift` declares `.visionOS(.v1)` (matching the OCCTSwift / OCCTSwiftTools ecosystem; the library uses no visionOS-2-only APIs).
  - `MetalViewRepresentable` and the `MetalViewportView` gesture / two-finger-pan code are gated `#if os(iOS) || os(visionOS)` (shared UIKit).
  - Point→pixel scale for picking is derived from the renderer's actual drawable size (new `ViewportRenderer.lastDrawableSize`) instead of `UIScreen.main` (unavailable on visionOS) / `NSScreen.main` — more correct on all platforms and removes the screen-API dependency.
  - Demo (`Examples/MetalDemo`) gains a visionOS target / `OCCTSwiftMetalDemo_visionOS` scheme.
  - No behaviour change on iOS / macOS; 102 tests green.
  - Follow-ups tracked in #36: spatial-input polish (Phase 2), immersive / XR (Phase 3).

> First minor bump in the 1.x line: a new platform is a capability expansion rather than a purely additive API, so it gets a MINOR rather than the usual PATCH.

## [1.0.8] — 2026-06-05

### Added
- **Portable input-event model** (issue #35, completing the layer). A source-neutral event type plus a single observable dispatch entry, so synthetic / XR / test input can drive the camera without any AppKit / UIKit type.
  - **`ViewportInputEvent`** — `Sendable` / `Equatable` enum (drag, two-finger pan, pinch, rotate, scroll, tap) with raw deltas. Re-exported as `_ViewportInputEvent`.
  - **`ViewportController.dispatch(_:)`** — the single interpretation entry point. It owns gesture-action resolution, the orbit X-axis inversion, and the drag-to-zoom curve; the platform layer is now a thin native→event adapter. macOS resolves drag actions via modifiers (`dragAction(for:)`); iOS via `singleFingerDrag` (both config fields preserved — no behaviour change).
  - **`ViewportController.onInputEvent`** — observation hook for the whole event stream (drives the demo's input inspector; useful for debugging / HUDs).
  - iOS + macOS gesture, scroll, and tap handlers rerouted through `dispatch`; behaviour preserved (Views keep delta math + dynamic-pivot scheduling).
  - New `ViewportInputRouterTests` (8 tests → 102 total, all green). iOS (arm64) + macOS demo builds verified.

### Demo
- **Input inspector** overlay (sidebar → Debug → "Input event inspector") showing the live `ViewportInputEvent` stream — for on-device verification of gesture interpretation.

### Fixed
- **Two-finger rotate (roll) never fired on iOS / macOS trackpad.** Pinch and rotate were attached as separate `.gesture()` modifiers, which SwiftUI treats as mutually exclusive, so pinch always won. Both two-finger continuous gestures are now `.simultaneousGesture`, so pinch + rotate coexist. (Pre-existing bug, surfaced by on-device verification of #35.)

### Note
- This closes the #35 follow-up. The shipped seam is what #36 (visionOS/XR) builds on: XR / synthetic input produces `ViewportInputEvent`s and calls `dispatch(_:)` directly.

## [1.0.7] — 2026-06-05

### Added
- **Portable input-interpretation seam** (issue #35, first increment) — an `Aspect_VKey` analogue decoupling gesture interpretation from `NSEvent` / `UIEvent`.
  - **`ViewportModifierKeys`** — a `Sendable` `OptionSet` (`.shift` / `.control` / `.option` / `.command`) with bridging initialisers from `NSEvent.ModifierFlags` (AppKit) and `UIKeyModifierFlags` (UIKit). Re-exported as `_ViewportModifierKeys`.
  - **`GestureConfiguration.dragAction(for:)`** — resolves a drag's `GestureAction` from modifier keys, preserving the historical priority (command → shift → option → unmodified).
  - The macOS drag handler now bridges native flags into `ViewportModifierKeys` and calls the resolver instead of branching on `NSEvent` inline; a stray debug `print` was removed. Behaviour is unchanged.
  - New `InputAbstractionTests` (7 tests → 94 total, all green).

### Note
- This is the modifier/key portion of #35. A full portable pointer/scroll/pinch event model remains; #35 stays open to track it. This seam is the foundation the visionOS work (#36) builds on.

## [1.0.6] — 2026-06-05

### Added
- **Screen-space HUD overlays** (issue #34) — the `Graphic3d_TransMode` analogue: orientation-only overlays pinned to viewport corners, distinct from the world-space axes/grid. Implemented as SwiftUI overlays (the ViewCube pattern), no extra Metal pass.
  - **`OrientationGnomon`** — top-leading corner gnomon drawing the world X/Y/Z axes (red/green/blue) under the current camera rotation; back-to-front depth sorted. Re-exported as `_OrientationGnomon`.
  - **`ScaleBarView`** — bottom-leading scale bar reporting the world length of a ~100-point span at the camera's focus (pivot) depth. Re-exported as `_ScaleBarView`.
  - **`CameraState.worldUnitsPerPoint(viewportHeightPoints:)`** — unified perspective (`2·distance·tan(fov/2)`) + orthographic (`orthographicScale`) world-units-per-point.
  - **`ScaleBarMetrics`** — snaps the represented length to a nice 1/2/5×10ⁿ value, recomputes the bar's point length, and formats an optional unit label. Re-exported as `_ScaleBarMetrics`.
  - **Config:** `ViewportConfiguration.showOrientationGnomon` / `showScaleBar` / `scaleBarUnitLabel` (all default off / empty → source-compatible), mirrored by `ViewportController.showOrientationGnomon` / `showScaleBar` published toggles.
  - New `HUDOverlayTests` (10 tests → 87 total, all green). Additive, no API break (PATCH).
  - Note: for perspective cameras the scale bar is exact only at the pivot depth (scale varies with depth); orthographic is exact everywhere.

## [1.0.5] — 2026-06-05

### Added
- **Selection filter chains** (issue #33). A composable `SelectionFilter` predicate over `PickResult`, the OCCTSwiftViewport analogue of OCCT's `SelectMgr_Filter`. Lets consumers constrain what the user-geometry pick stream accepts.
  - `SelectionFilter` is a `Sendable` wrapper over `@Sendable (PickResult) -> Bool`, exposing `matches(_:)` and `callAsFunction`. Re-exported as `_SelectionFilter`.
  - Built-ins: `.all` / `.nothing`, `.kind(_)` / `.kinds(_)` / `.faces` / `.edges` / `.vertices`, `.layer(_)`, `.bodyIDs(_)` / `.excludingBodyIDs(_)`, `.bodyIndices(_)`.
  - Composition: `.and(_)`, `.or(_)`, `.negated`, and chain combinators `.all(of:)` (AND) / `.any(of:)` (OR).
  - `ViewportController.selectionFilter: SelectionFilter?` — applied in `handlePick` to the user-geometry stream. A pick that fails the filter is treated as a miss (clears `pickResult`), since GPU picking resolves a single primitive per pixel with no alternate candidate to fall through to. Widget-layer picks bypass the filter (that stream is owned by an external consumer, e.g. OCCTSwiftAIS manipulators).
  - New `SelectionFilterTests` (13 tests). No public API break — additive (PATCH).
  - Builds on the face/edge/vertex pick discrimination shipped in v0.55.0.
  - Note: depth/distance filtering is intentionally absent — the GPU `PickResult` carries no depth value; use the CPU `SceneRaycast` path for distance-aware filtering.

## [1.0.4] — 2026-05-26

### Fixed
- **Package-level dependency cycle** (issue #32). OCCTSwiftViewport's manifest declared a dependency on OCCTSwiftTools (used only by the demo executable), while OCCTSwiftTools depends back on OCCTSwiftViewport — a cycle that broke `swift build` on a fresh checkout whenever the working-copy directory wasn't named exactly `OCCTSwiftViewport` (SwiftPM resolved a stale 0.55.3 copy and failed). The demo moved into its own standalone package at `Examples/MetalDemo` (takes Viewport via `path: "../.."`). The published OCCTSwiftViewport package now has **zero external dependencies**; the root `Package.resolved` was removed. Library consumers were never affected (SwiftPM prunes the demo-only Tools dep). `project.yml` and `scripts/overnight-stress.sh` updated to the new demo path.

## [1.0.3] — 2026-05-21

### Fixed
- **`quantize()` traps on out-of-range / non-finite vertex coords** (issue #30, PR #31). `NormalSmoothing.quantize` now drops non-finite coords (→0) and clamps into the Int32 range (limit `2e9`, *not* `Float(Int32.max)` which rounds up to 2³¹ and traps) before the trapping `Int32(_: Float)` init. Previously any vertex coord beyond ±21,474.8 model units, or `NaN`/`±inf`, `fatalError`'d on every body load via `CADFileLoader.loadFromManifest`. Only affects the welding key — clamped extremes simply don't weld. Added `NormalSmoothingTests` (3 tests). Source/binary compatible with 1.0.2.

## [1.0.2] — 2026-05-09

### Added
- **Point-cloud rendering pipeline** (issue #28, PR #29). New `visiblePointPipeline` in both `ViewportRenderer` and `OffscreenRenderer`.
  - `BodyPrimitiveKind` enum (`.mesh` / `.point` / `.wire`, named to avoid colliding with the pick-side `PrimitiveKind`).
  - `ViewportBody.primitiveKind` / `pointRadius` / `vertexColors` (all defaulted → source-compatible); `boundingBox` falls back to `vertices`.
  - World-radius → screen-pixels via `pxPerWorldFactor / clipPosition.w` (unified perspective + ortho), `[[point_size]]` clamped to `[1, 64]`, premultiplied-alpha blending. Mesh + wireframe paths skip `.point` bodies.
  - New `ViewportPointCloudRenderingTests` (4 tests).

## [1.0.1] — 2026-05-09

### Changed
- Docs polish + UX smoke coverage. README adds an ecosystem-map cross-link; `CHANGELOG.md` moved into `docs/` with the README link updated; `PBR_UPGRADE_PLAN.md` removed (shipped in 0.50.0); `DemoSmokeTests` now covers the v0.168 / v0.169 / v1.0 demo buttons. No library API changes.

## [1.0.0] — 2026-05-08

### Changed
- **SemVer-stable graduation** (issue #21), aligning with the OCCTSwift v1.0 family pin to OCCT 8.0.0 GA (released 2026-05-07). Demo deps bumped: OCCTSwift `from: 1.0.1`, OCCTSwiftTools `from: 1.0.0` (transitively OCCTSwiftIO 1.0.0). The viewport library itself has no OCCTSwift dependency — the bump only affects the demo + `project.yml`.
- Demo `v0.130 PointSetLib` block excised (API removed in OCCT 8.0.0 GA, no replacement). Added a `v1RootNodesAndEdgeRegularity` demo showing `NodeKind.product/occurrence` and the consolidated `setEdgeRegularity(edge, face1, face2, continuity)`.

## [0.55.3] — 2026-05-07

### Added
- **Headless measurement overlay in `OffscreenRenderer`** (issue #26). Measurement annotations now composite into offscreen renders without an on-screen `MTKView`, so server-side / snapshot pipelines get the same dimension overlays as the interactive viewport.

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
