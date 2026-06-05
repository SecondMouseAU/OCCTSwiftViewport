// OCCTSwiftViewport
// A reusable 3D viewport component for CAD applications using Metal
//
// Copyright (c) 2026. All rights reserved.
// SPDX-License-Identifier: LGPL-2.1-only WITH OCCT-exception-1.0

/// OCCTSwiftViewport provides a complete 3D viewport solution for CAD applications.
///
/// ## Overview
///
/// OCCTSwiftViewport is built on Metal and provides:
/// - Smooth camera controls (orbit, pan, zoom) with inertia
/// - Arcball and turntable rotation styles
/// - ViewCube for orientation and quick navigation
/// - Configurable gestures for iOS and macOS
/// - Standard view presets (Top, Front, Isometric, etc.)
/// - Professional three-point lighting
/// - Wireframe, shaded, and depth-edge display modes
/// - CPU raycast and dynamic pivot
///
/// ## Quick Start
///
/// ```swift
/// import SwiftUI
/// import OCCTSwiftViewport
///
/// struct ContentView: View {
///     @StateObject private var controller = ViewportController()
///     @State private var bodies: [ViewportBody] = [
///         .box(size: 1, color: .gray)
///     ]
///
///     var body: some View {
///         MetalViewportView(controller: controller, bodies: $bodies)
///     }
/// }
/// ```
///
/// ## Camera Control
///
/// The viewport supports multiple camera control styles:
///
/// ```swift
/// // Configure rotation style
/// controller.cameraController.rotationStyle = .turntable  // Z-up locked
/// controller.cameraController.rotationStyle = .arcball    // Free rotation
///
/// // Animate to standard views
/// controller.goToStandardView(.top)
/// controller.goToStandardView(.isometricFrontRight)
///
/// // Focus on a point
/// controller.focusOn(point: SIMD3<Float>(0, 0, 0), distance: 10)
/// ```
///
/// ## Gesture Configuration
///
/// Customize gesture behavior for your application:
///
/// ```swift
/// let config = ViewportConfiguration(
///     gestureConfiguration: GestureConfiguration(
///         singleFingerDrag: .orbit,
///         twoFingerDrag: .pan,
///         pinchGesture: .zoom
///     )
/// )
/// let controller = ViewportController(configuration: config)
/// ```

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

// HUD overlays
public typealias _OrientationGnomon = OrientationGnomon
public typealias _ScaleBarView = ScaleBarView
public typealias _ScaleBarMetrics = ScaleBarMetrics
