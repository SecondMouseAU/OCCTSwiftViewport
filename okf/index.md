---
type: repo
title: OCCTSwiftViewport
resource: https://github.com/SecondMouseAU/OCCTSwiftViewport
tags: [cad, metal, viewport, rendering, picking, swift, kernel]
description: Reusable Metal-based 3D viewport library for CAD apps on iOS/macOS — geometry-agnostic rendering, camera, GPU picking, with no OCCT dependency.
timestamp: 2026-06-22
---

# OCCTSwiftViewport

> A reusable Metal-based 3D viewport for CAD applications on iOS and macOS. It renders plain
> `ViewportBody` arrays (interleaved vertices + edges + color) and is **geometry-agnostic** — it
> knows nothing about OCCT, BREP, or any CAD kernel, so the app bridges geometry to display. Ships
> a Blinn-Phong renderer, arcball/turntable cameras, a ViewCube, GPU picking, clip planes,
> measurements, and adaptive PN-triangle tessellation, all Swift 6 / `Sendable` ready.

## Role in the ecosystem

- **Cluster:** kernel
- **Depends on:** nothing intra-org — this is a **leaf**. Its published library and test targets
  declare no OCCTSwift dependency, by design (avoids a package cycle with OCCTSwiftTools). The
  interactive demo, which does use the kernel, lives in its own `Examples/MetalDemo` package.
- **Feeds:** [OCCTSwiftTools](https://github.com/SecondMouseAU/OCCTSwiftTools) (the
  Shape → ViewportBody bridge) and, transitively, every app that displays OCCTSwift geometry.
  Dependents declare `depends_on: [OCCTSwiftViewport]`.

## Components

See [`components/`](components/index.md) for the public surface (`MetalViewportView`,
`ViewportController`, `ViewportBody`, camera/config/picking types).

## References

See [`references/`](references/index.md) for the Metal architecture doc, guides/cookbook,
changelog, the Swift Package Index page, and OpenCASCADE upstream.

## Notes

- Two products historically share this manifest, but the published library is just
  `OCCTSwiftViewport` (pure Metal, no deps). Cross-platform iOS 18+ / macOS 15+ / visionOS 1+.
- LGPL-2.1-only with the Open CASCADE Technology Exception 1.0.

## Policies

- [Query `context` first for OCCT / OCCTSwift docs](policies/context-first.md)
