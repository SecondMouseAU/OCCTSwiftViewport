// OCCTSwiftViewport
// A reusable 3D viewport component for CAD applications using Metal
//
// Copyright (c) 2026. All rights reserved.
// SPDX-License-Identifier: LGPL-2.1-only WITH OCCT-exception-1.0

// This file aggregates the module's public API surface as underscore-prefixed re-exports (below).
// For the Quick Start, camera control, and gesture configuration walkthroughs that used to live
// here as a module-level doc comment, see README.md and docs/index.md — this file is not a doc
// comment's declaration target, so per okf/policies/code-style.md's single-source-of-truth rule
// that content lives in docs/ rather than duplicated (and drifting) in source. Closes #96.

// MARK: - Public API

// Camera
public typealias _CameraState = CameraState
public typealias _CameraController = CameraController
public typealias _StandardView = StandardView
public typealias _RotationStyle = RotationStyle
public typealias _ViewCubeFace = ViewCubeFace

// Views
public typealias _MetalViewportView = MetalViewportView
public typealias _ViewportController = ViewportController

// Metal Renderer
public typealias _ViewportBody = ViewportBody
public typealias _ViewportArc = ViewportArc
public typealias _ArcSampling = ArcSampling
public typealias _BodyPrimitiveKind = BodyPrimitiveKind
public typealias _RenderLayer = RenderLayer
public typealias _PickLayer = PickLayer
public typealias _ViewportRenderer = ViewportRenderer
public typealias _OffscreenRenderer = OffscreenRenderer
public typealias _OffscreenRenderOptions = OffscreenRenderOptions
public typealias _OffscreenRenderError = OffscreenRenderError
public typealias _OrthoBounds = OrthoBounds

// Configuration
public typealias _ViewportConfiguration = ViewportConfiguration
public typealias _GestureConfiguration = GestureConfiguration
public typealias _GestureAction = GestureAction
public typealias _ViewportModifierKeys = ViewportModifierKeys
public typealias _ViewportInputEvent = ViewportInputEvent
public typealias _ViewCubePosition = ViewCubePosition
public typealias _ClipPlane = ClipPlane
public typealias _RenderingQuality = RenderingQuality

// Display
public typealias _DisplayMode = DisplayMode
public typealias _LightingConfiguration = LightingConfiguration
public typealias _LightSettings = LightSettings
public typealias _PBRMaterial = PBRMaterial
public typealias _HDRLoader = HDRLoader
public typealias _MaterialLibrary = MaterialLibrary
public typealias _NamedMaterial = NamedMaterial

// Math / Raycasting
public typealias _BoundingBox = BoundingBox
public typealias _Ray = Ray
public typealias _RaycastHit = RaycastHit
public typealias _SceneRaycast = SceneRaycast
public typealias _ProjectionUtility = ProjectionUtility

// Measurements
public typealias _ViewportMeasurement = ViewportMeasurement
public typealias _DistanceMeasurement = DistanceMeasurement
public typealias _AngleMeasurement = AngleMeasurement
public typealias _RadiusMeasurement = RadiusMeasurement
public typealias _MeasurementMode = MeasurementMode

// Picking
public typealias _PickResult = PickResult
public typealias _PrimitiveKind = PrimitiveKind
public typealias _PickingConfiguration = PickingConfiguration
public typealias _SelectionFilter = SelectionFilter

// Dynamic Pivot
public typealias _PivotStrategy = PivotStrategy
public typealias _DynamicPivotConfiguration = DynamicPivotConfiguration

// ViewCube
public typealias _ViewCubeView = ViewCubeView
public typealias _ViewCubeRegion = ViewCubeRegion
public typealias _NavigationCubeView = NavigationCubeView
public typealias _NavigationCube = NavigationCube

// HUD overlays
public typealias _OrientationGnomon = OrientationGnomon
public typealias _ScaleBarView = ScaleBarView
public typealias _ScaleBarMetrics = ScaleBarMetrics
