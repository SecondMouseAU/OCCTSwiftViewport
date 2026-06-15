# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OCCTSwiftViewport is a reusable Metal-based 3D viewport library for CAD applications, designed as a companion to [OCCTSwift](https://github.com/gsdali/OCCTSwift). The two libraries are fully independent — OCCTSwiftViewport has no knowledge of OCCT or B-Rep topology; OCCTSwift has no knowledge of rendering. The consuming app bridges them.

**Requirements:** iOS 18+ / macOS 15+, Swift 6.0+, Xcode 16+

## Build & Test Commands

```bash
# Build (Swift Package Manager)
swift build

# Run all tests (Swift Testing framework, 9 suites)
swift test

# Run a single test suite
swift test --filter CameraStateTests

# Run a single test
swift test --filter "CameraStateTests/Default initialization"

# Clean build (use if stale PCH errors after renames)
swift package clean && swift build

# Run the demo app via SPM (separate package — run from its directory)
cd Examples/MetalDemo && swift run OCCTSwiftMetalDemo
```

The Xcode project (`ViewportKit.xcodeproj`) is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen). It has two schemes: `OCCTSwiftMetalDemo_iOS` and `OCCTSwiftMetalDemo_macOS`. Regenerate after structural changes with `xcodegen`.

**Note:** OCCTSwift is a local path dependency (`../OCCTSwift` in `Package.swift`). The OCCTSwift source lives at `/Users/elb/Projects/OCCTSwift` — always search there for API signatures, not the SPM `.build/checkouts/` cache.

## Architecture

### Layer Separation

```
Your App (bridges OCCTSwift geometry → ViewportBody → OCCTSwiftViewport display)
    |                    |
OCCTSwift           OCCTSwiftViewport
(geometry kernel)   (rendering + viewport)
No dependency between them.
```

### Core Rendering Pipeline

```
ViewportController (@MainActor, ObservableObject — central hub)
  ├─ CameraController (@MainActor — orbit/pan/zoom with inertia + animation)
  │   └─ CameraState (immutable value type — rotation, distance, pivot, projection)
  ├─ PivotStrategy (@MainActor — dynamic orbit center based on zoom level)
  └─ ViewportRenderer (@MainActor, MTKViewDelegate — Metal render loop)
      ├─ Shaded pipeline (3-light Blinn-Phong + hemisphere ambient + Fresnel rim)
      ├─ Wireframe pipeline (contrast-adaptive edges, depth-biased)
      ├─ Grid pipeline (adaptive instanced dots)
      ├─ Axes pipeline (RGB colored lines)
      ├─ Shadow map pipeline (ShadowMapManager — directional light depth pass)
      ├─ Environment map (EnvironmentMapManager — image-based lighting)
      └─ Pick ID texture (R32Uint second color attachment, TBDR imageblock-based)
```

`MetalViewportView` is the SwiftUI entry point. It wraps `MTKView` via platform-specific representables and attaches gesture handlers (iOS: drag/pinch/rotation/tap; macOS: mouse with modifier keys + scroll wheel).

### Geometry Input

`ViewportBody` is the geometry-source-agnostic container. Vertex data is interleaved `[px, py, pz, nx, ny, nz, ...]` with stride 6 floats (24 bytes). Edge polylines are `[[SIMD3<Float>]]` for wireframe rendering. A generation counter (`nonisolated(unsafe)` static) enables buffer cache invalidation without diffing. Optional `faceIndices: [Int32]` maps triangles to face IDs for sub-body selection.

### GPU Picking

Pick IDs are encoded as `objectIndex | (primitiveID << 16)` into a R32Uint texture rendered as a second color attachment. `PickTextureManager` handles texture lifecycle. CPU-side raycasting (`SceneRaycast`) provides broadphase AABB culling then narrowphase Moller-Trumbore triangle intersection. `ProjectionUtility` provides screen-space ↔ world-space coordinate conversion.

### Shaders & Uniform Struct Sync

All Metal shaders are in `Sources/OCCTSwiftViewport/Renderer/Shaders.metal`. The uniform structs (`Uniforms`, `BodyUniforms`) are defined in **both** files and must stay in sync:

- **Swift side:** `Renderer/ViewportRenderer.swift` (search for `struct Uniforms` and `struct BodyUniforms`)
- **Metal side:** `Renderer/Shaders.metal` (search for `struct Uniforms` and `struct BodyUniforms`)

When modifying: maintain identical field order, matching types (`SIMD4<Float>` ↔ `float4`, `UInt32` ↔ `uint`), and 16-byte alignment for SIMD types.

### Camera System

Three rotation styles: **arcball** (Ken Shoemake virtual sphere), **turntable** (Z-up locked spherical coords), **first-person** (yaw/pitch). Animation uses SLERP for rotation with ease-out (t³) curves on a 60 FPS timer. `PivotStrategy` auto-adjusts the orbit center: scene center when zoomed out, raycast hit point when zoomed in, with smoothstep blending in the transition zone.

## Swift 6 Concurrency Model

- All mutable state holders are `@MainActor`: `ViewportController`, `CameraController`, `ViewportRenderer`, `PivotStrategy`
- All value types and configs are `Sendable`: `CameraState`, `ViewportBody`, `BoundingBox`, `Ray`, `ViewportConfiguration`, `GestureConfiguration`, `LightingConfiguration`
- MetalKit imported with `@preconcurrency` for MTL type conformance
- `ViewportBody` uses `nonisolated(unsafe)` only for its static generation counter
- `@Published` properties fire on main thread — no `.receive(on:)` needed in Combine subscriptions

## Key Conventions

- **Public API re-export:** `Sources/OCCTSwiftViewport/OCCTSwiftViewport.swift` uses underscore-prefixed typealiases (`public typealias _CameraState = CameraState`) to aggregate ~40 public types. Consumers import the module and use `_TypeName` directly.
- **Primitives for testing:** `ViewportBody` has factory methods (`.box()`, `.cylinder()`, `.sphere()`, `.torus()`) in `Primitives.swift`
- **Platform branching:** `#if os(iOS)` / `#elseif os(macOS)` within shared files (not separate files per platform). macOS uses a custom `ScrollCaptureMTKView` subclass for scroll/mouse events.
- **Tests:** Swift Testing framework (`import Testing`, `@Test`, `@Suite`), not XCTest
- **Configuration presets:** `LightingConfiguration` (`.threePoint`, `.studio`, `.architectural`, `.flat`), `GestureConfiguration` (`.blender`, `.fusion360`, `.default`), `RotationStyle` (`.cadDefault`, `.modelingDefault`)
- **Clip planes:** `ClipPlane` in `Configuration/` for section views
- **Measurements:** `Measurement` type + `MeasurementOverlay` SwiftUI view for dimension display

## Demo App

`Examples/MetalDemo/Sources/OCCTSwiftMetalDemo/` is a gallery-based demo app exercising OCCTSwift features. It is a **standalone SPM package** (`Examples/MetalDemo/Package.swift`, taking Viewport via `path: "../.."`) — kept out of the root manifest to avoid a Viewport → Tools → Viewport cycle. Entry point is `MetalSpikeApp.swift` → `SpikeView.swift`. Each OCCTSwift capability gets its own gallery file (e.g., `Curve2DGallery.swift`, `SurfaceGallery.swift`, `OCCT8Gallery.swift`, `NamingGallery.swift`, `AnnotationGallery.swift`). The `SelectionManager` handles body/face selection with highlighting. `CADFileLoader` handles STEP/STL/OBJ/BREP file import. New demos for each OCCTSwift release are added as gallery functions — see existing galleries for the pattern.

## Script Harness

A companion SPM package at `/Users/elb/Projects/OCCTSwiftScripts/` provides a CadQuery/OpenSCAD-like workflow for OCCTSwift. Edit `Sources/Script/main.swift` using the **full OCCTSwift API** (~400+ methods), run `swift run Script`, and geometry appears automatically in the viewport.

The script has access to everything: primitives, sketches (`Wire.polygon`, `.circle`, `.rectangle`), extrude/revolve/sweep/loft, booleans (union/cut/intersect), fillets/chamfers, holes/pockets/bosses, offset/shell, transforms, patterns, curves (2D/3D), surfaces, constraint solvers (`GccAna`), `Document` (XDE assembly + GD&T), file I/O, and analysis.

### How It Works

```
OCCTSwiftScripts/Sources/Script/main.swift  (full OCCTSwift API access)
    │  swift run Script (~1-2s incremental)
    ▼
~/.occtswift-scripts/output/
    ├─ body-0.brep          (wire sketch — wireframe)
    ├─ body-1.brep          (filleted solid)
    ├─ body-2.brep          (bolt assembly)
    ├─ output.step           (combined — for external tools)
    └─ manifest.json         (written LAST — triggers watcher)
    │  kqueue file watcher (200ms debounce)
    ▼
Demo app (ScriptWatcher auto-reloads geometry into viewport)
```

### Usage

```bash
cd /Users/elb/Projects/OCCTSwiftScripts
swift build          # First time ~30s
# Edit Sources/Script/main.swift, then:
swift run Script     # ~1-2s incremental
```

In the demo app (macOS only): sidebar → File & Tools → Script Watcher → toggle on.

### ScriptContext API

```swift
let ctx = ScriptContext()           // also writes output.step on emit
let ctx = ScriptContext(exportSTEP: false)  // BREP only, faster
let C = ScriptContext.Colors.self   // .red .blue .steel .brass etc.

// Solids
try ctx.add(shape, id: "part", color: C.steel, name: "Bracket")

// Wires / sketches (displayed as wireframe edges)
try ctx.add(wire, id: "sketch", color: C.yellow)

// Edges
try ctx.add(edge, id: "axis", color: C.red)

// Compounds (assemblies)
try ctx.addCompound([part1, part2], id: "asm", color: C.gray)

// Emit — writes output.step + manifest.json (call LAST)
try ctx.emit(description: "My parametric design")
```

### Key Files

| File | Purpose |
|------|---------|
| `OCCTSwiftScripts/Sources/Script/main.swift` | User-editable script (full OCCTSwift API) |
| `OCCTSwiftScripts/Sources/ScriptHarness/ScriptContext.swift` | Shape/Wire/Edge accumulator, BREP+STEP writer |
| `OCCTSwiftScripts/Sources/ScriptHarness/Manifest.swift` | `ScriptManifest` / `BodyDescriptor` Codable types |
| `Examples/MetalDemo/Sources/OCCTSwiftMetalDemo/ScriptWatcher.swift` | kqueue file watcher (macOS only) |
| `Examples/MetalDemo/Sources/OCCTSwiftMetalDemo/ScriptManifest.swift` | Demo-side manifest Codable types |

### File Format Support

- **Import:** STEP (.step/.stp), STL (.stl), OBJ (.obj), BREP (.brep/.brp)
- **Export:** OBJ, PLY, STEP, BREP
- **Script output:** BREP per body (~1ms each) + combined STEP for external tools
