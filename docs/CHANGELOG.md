# Changelog

All notable changes to OCCTSwiftViewport are documented in this file.

## [1.1.22] — 2026-06-22

### Fixed
- **`NormalSmoothing` "brushed" striations on anisotropic meshes** (issue #81; root cause of OCCTSwift#255). `NormalSmoothing.smoothNormals` discarded the per-vertex normals it was given and recomputed each from an area-weighted *face*-normal average. On a highly anisotropic mesh — long thin triangles along a sweep, e.g. a `threadedShaft` helical flank — that average is directionally biased and renders as fine periodic "brushed" striations (a shading artifact that looks like a geometric ripple).
  - The fix assigns the **area-weighted average of the original per-vertex normals** within each crease group (snapshotted before the in-place write); face normals are still used for crease *detection* (hard edges stay crisp).
  - **Smooth B-rep meshes:** OCCT's accurate analytic normals are reproduced exactly (verified byte-identical to a raw-normal render of an M10×1.5 thread) → striations gone.
  - **Flat meshes (imported STL, vertex normal == face normal):** the vertex-normal average equals the old face-normal average → behaviour unchanged, backward-compatible.
  - New `smoothInputNormalsPreserved` + `flatInputMatchesFaceNormalAverage` tests; updated the crease test to seed realistic per-face normals. 163 tests pass.

## [1.1.21] — 2026-06-20

### Added
- **Unlit / flat-colour display mode** (issue #77). New `DisplayMode.unlit` draws each body in its constant base colour with **no lighting, ambient, shadows, fresnel, curvature, or tone mapping** — so vivid, colour-coded **diagnostic / debug renders** stay faithful and distinguishable. Previously `OffscreenRenderer` `.shaded` ran every body through the full PBR path (hemisphere ambient + fresnel rim + curvature; ACES tone map on the interactive post-pass), which desaturated and hue-shifted saturated colours (a bright magenta read as green-ish).
  - `shaded_fragment` early-returns `bodyUniforms.color` when the new `Uniforms.unlit` flag is set; clip-plane discard and selection tint still apply.
  - Both `OffscreenRenderer` (`options.displayMode`) and `ViewportRenderer` (`controller.displayMode`) set the flag; `.unlit` routes through the shaded pipeline via `showsSurfaces == true`. The interactive SSAO / ACES tone-map post-pass is skipped for `.unlit` so it can never re-desaturate.
  - `Uniforms` gains a `uint unlit` field, kept in sync Swift↔Metal by repacking the existing 16-byte clip-pad tail (stride unchanged elsewhere).
- New `UnlitColorTests`: a magenta panel renders faithfully in `.unlit` (R≈255, G≈38, B≈217) and measurably more saturated than `.shaded`. 161 tests total.

## [1.1.20] — 2026-06-12

### Added
- **Tap-to-measure** (issue #68). `ViewportController.measurementMode` (`.distance` / `.angle` / `.radius`) now actually drives interaction: while a mode is active, taps on geometry accumulate world-space surface points and commit a `ViewportMeasurement` (rendered by the existing `MeasurementOverlay`). Previously the property was published but consumed by nothing, so setting it did nothing — it read like a feature that silently didn't work.
  - Point order per mode: `.distance` → start, end (2 taps); `.angle` → armA, vertex, armB (3 taps); `.radius` → center, edge (2 taps).
  - New `ViewportBody.worldHitPoint(ray:triangleIndex:)` reconstructs the picked surface point in world space, **respecting the body's `transform`**.
  - New controller surface: `pendingMeasurementPoints` (published, for in-progress feedback), `addMeasurementPoint(_:)`, `handleMeasurementPick(result:ndc:bodies:aspectRatio:)`, `cancelPendingMeasurement()`, `clearMeasurements()`, and `static pointCount(for:)`. Changing the mode clears in-progress points; taps register on `.face` picks only and don't disturb the selection stream.
  - `MeasurementMode` is now `Equatable`.
- New `MeasurementModeTests` (14). 160 tests total.

## [1.1.16] — 2026-06-08

### Fixed
- **Navigation-cube drag direction** (follow-up to #60/v1.1.15). Dragging the cube orbited the camera the wrong way — v1.1.15 reused the viewport's grab-the-model sign, but the cube is a camera proxy, so it must orbit the camera *around* the model (opposite sign on both axes). Dragging the cube now spins the view the way the drag intends.

## [1.1.15] — 2026-06-08

### Changed
- **Navigation cube is now drag-to-orbit, with discoverable edge/corner targets** (follow-up to #60). Dragging the cube now orbits the camera (grab-and-spin, independent of the viewport's gesture-action mapping); a press that doesn't move past a small threshold is still treated as a tap that snaps to the region's view. The cube draws a 3×3 grid per visible face so the edge and corner hit zones are visible, and the overlay is larger (96 pt) so they're easier to hit on touch.
- The hit-test already resolved faces / edges / corners (verified by a new round-trip test under the isometric rotation); these changes make edges/corners practically reachable and add the expected CAD cube-drag interaction. 142 tests total.

## [1.1.14] — 2026-06-08

### Added
- **`ViewportBody.isPickable`** (issue #63, default `true`). A body can now be drawn but excluded from the GPU pick buffer, so always-on-top reference geometry (datum / ground planes, overlays) no longer steals face/edge/vertex picks from the geometry behind it. Gated alongside `isVisible` in every pick sub-pass — geometry, edge, arc, vertex, and the overlay pick pass — with the object index still advancing so remaining bodies keep stable pick IDs. Unlike `selectionFilter` (which rejects a pick *after* the GPU returns it), this stops the body from occluding the pick buffer at all, so the geometry behind it is actually sampled.
- New `PickabilityTests` (3). 141 tests total. Default `true` → no behaviour change for existing bodies.

## [1.1.13] — 2026-06-08

### Fixed
- **View-cube overlay now honours `ViewportConfiguration.viewCubePosition`** (issue #62). The overlay was hardcoded to bottom-trailing, so the cube couldn't be moved — a real problem on iPhone where a bottom sheet covers that corner. It now maps the `.topLeading` / `.topTrailing` / `.bottomLeading` / `.bottomTrailing` config to the overlay alignment (within the safe area), so a host can move the cube clear of other UI. Default stays bottom-trailing (no behaviour change).
- New `ViewCubePositionTests` (2). 138 tests total.

## [1.1.12] — 2026-06-08

### Added
- **Interactive 3D navigation cube** (issue #60) — a Shapr3D / Fusion-style `NavigationCubeView` replacing the orientation-gizmo `ViewCubeView` in the corner overlay. It renders a cube that tracks `cameraState.rotation`, with **clickable faces, edges, and corners** that animate to the matching plan / elevation / isometric view.
  - New `NavigationCube` — pure, SwiftUI-free projection + hit-testing. Taps are unprojected to a ray, intersected with the unit cube, and the frontmost surface point is classified into the 3×3-per-face grid → one of the 26 `ViewCubeRegion`s (faces / edges / corners). Robust on iOS (touch) and macOS (click + hover highlight).
  - New `ViewportController.goToRegion(_:duration:)` — animates to a region's orientation, preserving the current pivot / distance / projection.
  - `NavigationCube` / `NavigationCubeView` re-exported (`_NavigationCube` / `_NavigationCubeView`). `ViewCubeView` is retained (still re-exported) for source compatibility.
  - New `NavigationCubeTests` (5): region↔base-face mapping + 26-region lookup completeness, surface-point classification, ray-cube intersection, and end-to-end identity-rotation hit-testing (centre→face, edges, corners, miss). 136 tests total; cube rendering verified on the Vision Pro simulator.

## [1.1.11] — 2026-06-06

### Fixed
- **Z-fighting from a fixed near/far clip range** (issue #57). The renderers hard-coded `near = 0.01` / `far = 10000` (ratio 1e6), which collapses hyperbolic depth precision onto distant geometry — adjacent triangles on large / real-scale models (e.g. an mm-scale STL hundreds of units out) round to the same depth and flicker. Clip planes are now **scene-adaptive**: derived each frame from the camera distance and the visible scene's bounding radius (`CameraState.clipPlanes(sceneBounds:)`), keeping `far/near` ~1e3 at any model scale. Applied in both `ViewportRenderer` (cached per-body AABBs) and `OffscreenRenderer`. Empty scenes fall back to the old wide default. No consumer tuning required; no API change.
- New `ClipPlaneTests` (5) covering unit / mm-scale / camera-inside / tiny / huge cases (131 tests total). Live rendering verified unchanged on the Vision Pro simulator.

### Note
- Reversed-Z (the issue's "best for CAD" option) would push precision even further but requires flipping every depth state / clear / compare; scene-adaptive planes resolve the reported flicker with far less risk and are the change shipped here. The measurement-overlay projection in `MetalViewportView` keeps the wide range deliberately — near/far don't affect screen-space x/y, only depth.

## [1.1.10] — 2026-06-06

### Fixed
- **`OffscreenRenderer` now honours per-body `transform`** (issue #55). Headless renders previously drew every body at its local origin because the offscreen uniforms hard-coded `modelMatrix = identity` — so transformed / instanced / assembled bodies came out piled up. The shaded, transparent, point, and shadow passes now set `modelMatrix = body.transform`, and the shadow-frustum bounds use each body's *transformed* AABB so shadows follow the moved geometry. Matches `ViewportRenderer`. Identity-transform bodies are unchanged.
- New `OffscreenTransformTests` (2): a body translated out of frame disappears; a `+X` offset shifts its rendered centroid right (126 tests total).

## [1.1.9] — 2026-06-06

### Added
- **Per-body surface transparency** (issue #53, closes it). A body with `color.w` / `effectiveMaterial.opacity` < 1 now renders as a translucent surface compositing over the geometry behind it — enabling "focus one part, fade the rest" interactions.
  - Alpha blending (`.sourceAlpha` / `.oneMinusSourceAlpha`) enabled on all shaded pipelines (standard, tessellated, mesh-shader) in both `ViewportRenderer` and `OffscreenRenderer`. Opaque bodies (alpha = 1) are unaffected.
  - Translucent bodies are drawn in a dedicated pass **after** the opaque set, sorted **back-to-front** by camera distance, with depth **test on / write off** (new `transparentSurfaceDepthState`), so they composite correctly without occluding each other in depth. Opaque bodies stay fully z-correct among themselves.
  - Works headlessly in `OffscreenRenderer` (PNG) as well as live.
  - New `SurfaceTransparencyTests` — a differential GPU render (opaque vs translucent front panel) asserting the body behind shows through (124 tests total). Live opaque rendering verified unchanged on the Vision Pro simulator.

### Note
- The alpha plumbing already existed end-to-end (`shaded_fragment` outputs `bodyUniforms.color.a`); only blending + draw order were missing.

## [1.1.8] — 2026-06-06

### Added
- **Analytic arc picking** (follow-up to #48). `ViewportArc`s are now pickable: a hit reports `PickResult.kind == .edge` with `triangleIndex` = the arc's index in `ViewportBody.arcs`. The pick pass re-draws this frame's adaptively-sampled arc segments (reusing the display pass's buffer + ranges — no re-sampling) through a new `pick_arc` pipeline; because segment counts are per-frame adaptive, each arc is drawn separately and a `pick_arc_fragment` stamps the arc index (rather than `[[primitive_id]]`).
- Fixes a latent bug found while wiring this: the arc *display* pass set the model matrix once (identity) instead of per body, so arcs on a transformed body drew at the wrong place; now set per draw.
- New pick-decode contract test (123 total). Builds + runs on the Vision Pro simulator with the pick pass active.

### Note
- A body mixing polyline `edges` and `arcs` reports both as `kind == .edge`; `kind` alone can't disambiguate — prefer one edge representation per body.

## [1.1.7] — 2026-06-06

### Added
- **Analytic arc edges** (issue #48, part 3 — closes #48). New `ViewportArc` primitive (center / radius / in-plane basis / start+end angle) and `ViewportBody.arcs`. The renderer samples arcs to line segments **adaptively to their projected size each frame** (`ArcSampling.segmentCount`), so circular feature edges render smooth at any zoom, independent of mesh density — no consumer pre-faceting. Sampled once per frame into one reused buffer and drawn per body (inheriting transform / colour) through the existing wireframe pipeline. Re-exported as `_ViewportArc` / `_ArcSampling`.
- Demo shows a smooth analytic circle.

### Fixed
- **Arc-only / data-light bodies were dropped by the renderer.** `ensureBuffers` skipped any body with no vertex/edge/point buffer, so a body carrying only `arcs` never reached the draw passes. The guard now also admits bodies with arcs. (Surfaced by on-device verification on the Vision Pro simulator.)

### Tests
- New `ViewportArcTests` (6): arc evaluation, adaptive segment count (scaling, clamps, behind-camera fallback), body integration. 122 total green; arc rendering confirmed on the Vision Pro simulator.

With this, #48 is complete: `.cadHighQuality` adaptive surface tessellation (v1.1.5) + auto normal smoothing (v1.1.6) + analytic arc edges (v1.1.7).

## [1.1.6] — 2026-06-06

### Added
- **Renderer-side auto normal smoothing** (issue #48, part 2) — `ViewportConfiguration.autoSmoothNormals` (+ `normalSmoothingCreaseAngle`). When enabled, the renderer applies crease-aware `NormalSmoothing` to each body's mesh as its buffers are built, so meshes that arrive with flat / per-face normals (e.g. STL) can actually be rounded by `.enhanced` Phong tessellation — hard edges stay sharp via the crease angle. Computed once per body (generation-gated, cached), and the smoothed normals flow into the tessellation patch control points automatically (the patch builder reads the body vertex buffer).
- Enabled by default in `.cadHighQuality`. New tests: config wiring + crease preservation (116 total).
- README "Smooth Round Geometry" updated to point at `autoSmoothNormals`.

Analytic arc edges continue in #48 (part 3).

## [1.1.5] — 2026-06-06

### Added
- **`ViewportConfiguration.cadHighQuality` preset** (issue #48, part 1) — exposes the renderer's existing screen-space-adaptive PN-triangle (Phong) tessellation for smooth round geometry. Sets `renderingQuality = .enhanced` + `adaptiveTessellation` + a higher `tessellationMaxFactor`, so curved surfaces (cylinder / cone silhouettes, fillets) stay smooth at any zoom without the consumer pre-tessellating finely. The smoothness counterpart to `.performance`.
- **README "Smooth Round Geometry" section** — documents the surface-smoothness knobs (`renderingQuality`, `adaptiveTessellation`, `tessellationMaxFactor`, `NormalSmoothing`), the edge-sampling caveat, and the perf tradeoff.
- Config preset test (114 total).

Adaptive Phong tessellation already existed but was gated behind `.enhanced` (off by default); this makes it discoverable. Auto-smoothing flat input normals and analytic arc edges continue in #48.

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
