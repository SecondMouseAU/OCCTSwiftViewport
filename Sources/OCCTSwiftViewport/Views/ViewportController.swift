// ViewportController.swift
// ViewportKit
//
// Observable controller for viewport state management.

import Foundation
import Combine
import simd

/// Observable controller managing viewport state and interactions.
///
/// ViewportController is the main interface for controlling the viewport.
/// It manages camera state, handles user input, and coordinates with
/// the Metal renderer.
///
/// ## Example
///
/// ```swift
/// struct MyView: View {
///     @StateObject private var controller = ViewportController()
///     @State private var bodies: [ViewportBody] = [.box()]
///
///     var body: some View {
///         MetalViewportView(controller: controller, bodies: $bodies)
///             .toolbar {
///                 Button("Top") { controller.goToStandardView(.top) }
///             }
///     }
/// }
/// ```
@MainActor
public final class ViewportController: ObservableObject {

    // MARK: - Published Properties

    /// Current camera state.
    @Published public private(set) var cameraState: CameraState

    /// Current display mode.
    @Published public var displayMode: DisplayMode

    /// Whether the ViewCube is visible.
    @Published public var showViewCube: Bool

    /// Whether the coordinate axes are visible.
    @Published public var showAxes: Bool

    /// Whether the grid is visible.
    @Published public var showGrid: Bool

    /// Whether the screen-space orientation gnomon (HUD corner axes) is visible.
    @Published public var showOrientationGnomon: Bool

    /// Whether the screen-space scale bar (HUD) is visible.
    @Published public var showScaleBar: Bool

    /// Whether an animation is in progress.
    @Published public private(set) var isAnimating: Bool = false

    /// Lighting configuration for live adjustment.
    @Published public var lightingConfiguration: LightingConfiguration

    /// The most recent pick result on the user-geometry layer, or nil if nothing
    /// is selected. Pick events on bodies with `pickLayer == .widget` are routed
    /// to `widgetPickResult` instead.
    @Published public private(set) var pickResult: PickResult?

    /// The most recent pick result on the widget layer (e.g., manipulator handles
    /// from OCCTSwiftAIS), or nil. Populated for bodies with `pickLayer == .widget`.
    @Published public private(set) var widgetPickResult: PickResult?

    /// Set of currently selected body IDs. Bodies in this set render with a highlight outline.
    @Published public var selectedBodyIDs: Set<String> = []

    /// ID of the currently hovered body (mouse hover), or nil.
    @Published public var hoveredBodyID: String?

    /// NDC coordinates of the last pick tap (for sub-body selection).
    @Published public private(set) var lastPickNDC: SIMD2<Float> = .zero

    /// Edge/wireframe intensity multiplier (0 = invisible, 1 = default, 2+ = bold).
    @Published public var edgeIntensity: Float = 1.0

    /// Active clipping planes (up to 4). Only enabled planes are applied.
    @Published public var clipPlanes: [ClipPlane] = []

    /// Active measurement annotations displayed on the viewport.
    @Published public var measurements: [ViewportMeasurement] = []

    /// Current measurement interaction mode.
    @Published public var measurementMode: MeasurementMode = .none

    // MARK: - Post-Process Toggles (runtime-tunable)

    /// Whether depth of field is enabled.
    @Published public var enableDepthOfField: Bool = false

    /// DoF aperture (smaller = shallower).
    @Published public var dofAperture: Float = 2.8

    /// DoF focal distance (0 = autofocus).
    @Published public var dofFocalDistance: Float = 0

    /// Maximum DoF blur radius in pixels.
    @Published public var dofMaxBlurRadius: Float = 8.0

    /// Debug: disable screen-space curvature enhancement in shaded fragment.
    @Published public var debugDisableCurvature: Bool = false

    /// Debug: disable GPU tessellation (fall back to standard triangles).
    @Published public var debugDisableTessellation: Bool = false

    /// Whether temporal anti-aliasing is enabled.
    @Published public var enableTAA: Bool = false

    /// TAA blend factor (0 = no history, 1 = full history).
    @Published public var taaBlendFactor: Float = 0.9

    /// Whether progressive idle accumulation is enabled. Requires `enableTAA`.
    /// When the camera is still, history weight grows as `N/(N+1)` rather than
    /// the fixed `taaBlendFactor`, giving unbounded supersampling. Disabled by default.
    @Published public var enableProgressiveAccumulation: Bool = false

    // MARK: - Configuration

    /// Viewport configuration.
    public let configuration: ViewportConfiguration

    // MARK: - Internal Components

    /// The camera controller managing movement.
    public let cameraController: CameraController

    /// Cancellables for Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()

    /// Dynamic pivot strategy for automatic orbit center adjustment.
    private lazy var pivotStrategy = PivotStrategy()

    /// Current aspect ratio (updated by MetalViewportView).
    public internal(set) var lastAspectRatio: Float = 1.0

    /// Coalescing work item for dynamic pivot updates.
    private var pivotWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    /// Creates a viewport controller with the specified configuration.
    public init(configuration: ViewportConfiguration = .cad) {
        self.configuration = configuration
        self.cameraState = configuration.initialCameraState
        self.displayMode = configuration.displayMode
        self.showViewCube = configuration.showViewCube
        self.showAxes = configuration.showAxes
        self.showGrid = configuration.showGrid
        self.showOrientationGnomon = configuration.showOrientationGnomon
        self.showScaleBar = configuration.showScaleBar
        self.lightingConfiguration = configuration.lightingConfiguration
        self.enableDepthOfField = configuration.enableDepthOfField
        self.dofAperture = configuration.dofAperture
        self.dofFocalDistance = configuration.dofFocalDistance
        self.dofMaxBlurRadius = configuration.dofMaxBlurRadius
        self.enableTAA = configuration.enableTAA
        self.taaBlendFactor = configuration.taaBlendFactor

        self.cameraController = CameraController(initialState: configuration.initialCameraState)
        cameraController.rotationStyle = configuration.rotationStyle
        cameraController.minDistance = configuration.minDistance
        cameraController.maxDistance = configuration.maxDistance

        // Apply gesture configuration
        let gc = configuration.gestureConfiguration
        cameraController.orbitSensitivity = gc.orbitSensitivity
        cameraController.panSensitivity = gc.panSensitivity
        cameraController.zoomSensitivity = gc.zoomSensitivity
        cameraController.scrollZoomSensitivity = gc.scrollZoomSensitivity
        cameraController.minPanSpeed = gc.minPanSpeed
        cameraController.enableInertia = gc.enableInertia
        cameraController.dampingFactor = gc.dampingFactor

        // Subscribe to camera controller updates.
        // Both objects are @MainActor so @Published already fires on main —
        // do NOT use .receive(on:) which re-dispatches asynchronously and
        // causes the renderer to read a stale cameraState for one frame.
        cameraController.$cameraState
            .sink { [weak self] state in
                self?.cameraState = state
            }
            .store(in: &cancellables)

        cameraController.$isAnimating
            .sink { [weak self] animating in
                self?.isAnimating = animating
            }
            .store(in: &cancellables)
    }

    // MARK: - Standard Views

    /// Animates to a standard view.
    ///
    /// - Parameters:
    ///   - view: The target standard view
    ///   - duration: Animation duration in seconds
    public func goToStandardView(_ view: StandardView, duration: Float = 0.3) {
        cameraController.animateTo(view, duration: duration)
    }

    /// Animates to a specific camera state.
    public func animateTo(_ state: CameraState, duration: Float = 0.3) {
        cameraController.animateTo(state, duration: duration)
    }

    // MARK: - Camera Control

    /// Handles orbit gesture input.
    public func handleOrbit(translation: CGSize) {
        cameraController.orbit(
            deltaX: Float(translation.width),
            deltaY: Float(translation.height)
        )
    }

    /// Ends orbit with velocity for inertia, snapping to a nearby axis view on gentle release.
    public func endOrbit(velocity: CGSize) {
        let speed = sqrt(velocity.width * velocity.width + velocity.height * velocity.height)

        // If release velocity is low, check for snap to nearby axis view
        if speed < 200 {
            if let snapView = cameraController.nearestStandardView(threshold: 3.0) {
                cameraController.animateTo(snapView, duration: 0.15)
                return
            }
        }

        cameraController.setAngularVelocity(SIMD2<Float>(
            Float(velocity.width) * 0.001,
            Float(velocity.height) * 0.001
        ))
    }

    /// Handles pan gesture input.
    public func handlePan(translation: CGSize) {
        cameraController.pan(
            deltaX: Float(translation.width),
            deltaY: Float(translation.height)
        )
    }

    /// Ends pan with velocity for inertia.
    public func endPan(velocity: CGSize) {
        cameraController.setPanVelocity(SIMD2<Float>(
            Float(velocity.width) * 0.001,
            Float(velocity.height) * 0.001
        ))
    }

    /// Handles zoom gesture input.
    public func handleZoom(magnification: CGFloat) {
        cameraController.zoom(factor: Float(magnification))
    }

    /// Handles scroll wheel zoom.
    public func handleScrollZoom(delta: CGFloat) {
        cameraController.scrollZoom(delta: Float(delta))
    }

    /// Handles scroll wheel zoom toward cursor position.
    public func handleScrollZoom(delta: CGFloat, cursorNormalized: SIMD2<Float>, aspectRatio: Float) {
        cameraController.scrollZoom(delta: Float(delta), cursorNormalized: cursorNormalized, aspectRatio: aspectRatio)
    }

    /// Handles roll gesture input.
    public func handleRoll(angle: CGFloat) {
        cameraController.roll(deltaAngle: Float(angle))
    }

    /// Focuses on a specific point.
    public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true) {
        cameraController.focusOn(point: point, distance: distance, animated: animated)
    }

    /// Resets the camera to the default view.
    public func reset(animated: Bool = true) {
        cameraController.reset(animated: animated)
    }

    // MARK: - Display Mode

    /// Cycles to the next display mode.
    public func cycleDisplayMode() {
        let modes = DisplayMode.allCases
        guard let currentIndex = modes.firstIndex(of: displayMode) else { return }
        let nextIndex = (currentIndex + 1) % modes.count
        displayMode = modes[nextIndex]
    }

    // MARK: - Toggle Methods

    /// Toggles ViewCube visibility.
    public func toggleViewCube() {
        showViewCube.toggle()
    }

    /// Toggles axes visibility.
    public func toggleAxes() {
        showAxes.toggle()
    }

    /// Toggles grid visibility.
    public func toggleGrid() {
        showGrid.toggle()
    }

    // MARK: - Projection Mode

    /// Toggles between perspective and orthographic projection.
    public func toggleProjection() {
        var state = cameraState
        state.isOrthographic.toggle()
        animateTo(state, duration: 0.3)
    }

    // MARK: - Picking

    /// Optional callback invoked when a user-geometry pick occurs.
    public var onPick: ((PickResult?) -> Void)?

    /// Optional callback invoked when a widget-layer pick occurs.
    public var onWidgetPick: ((PickResult?) -> Void)?

    /// Optional filter constraining what the user-geometry pick stream accepts.
    ///
    /// When set, a user-geometry pick that fails the filter is treated as a miss
    /// (clearing `pickResult`), since GPU picking resolves a single primitive per
    /// pixel and has no alternate candidate to fall through to. Widget-layer picks
    /// bypass the filter — that stream is owned by an external consumer.
    public var selectionFilter: SelectionFilter?

    /// Called by the view layer after a GPU pick readback completes.
    ///
    /// Routes the result to either `pickResult` (default) or `widgetPickResult`
    /// based on the picked body's `pickLayer`. A nil result clears `pickResult`
    /// only — `widgetPickResult` keeps its last value, since the widget-pick
    /// stream is owned by an external consumer (e.g., AIS) that decides when to
    /// reset it. The user-geometry stream additionally honours `selectionFilter`.
    public func handlePick(result: PickResult?) {
        if let result, result.pickLayer == .widget {
            widgetPickResult = result
            onWidgetPick?(result)
        } else {
            // A result that fails the selection filter is treated as a miss.
            let passed = result.flatMap { selectionFilter?.matches($0) == false ? nil : $0 }
            pickResult = passed
            onPick?(passed)
        }
    }

    /// Called by the view layer after a GPU pick readback completes, with NDC coordinates.
    public func handlePick(result: PickResult?, ndc: SIMD2<Float>) {
        lastPickNDC = ndc
        handlePick(result: result)
    }

    /// Clears the current selection.
    public func clearSelection() {
        pickResult = nil
        selectedBodyIDs.removeAll()
        onPick?(nil)
    }

    /// Clears the most recent widget-layer pick result.
    public func clearWidgetPick() {
        widgetPickResult = nil
        onWidgetPick?(nil)
    }

    /// Selects a body by ID, optionally toggling (for multi-select).
    public func selectBody(_ bodyID: String, toggle: Bool = false) {
        if toggle {
            if selectedBodyIDs.contains(bodyID) {
                selectedBodyIDs.remove(bodyID)
            } else {
                selectedBodyIDs.insert(bodyID)
            }
        } else {
            selectedBodyIDs = [bodyID]
        }
    }

    /// Deselects all bodies.
    public func deselectAll() {
        selectedBodyIDs.removeAll()
    }
}

// MARK: - Dynamic Pivot

extension ViewportController {

    /// Computes and applies a dynamic pivot update.
    internal func updateDynamicPivot(bodies: [ViewportBody]) {
        let config = configuration.dynamicPivotConfiguration
        guard config.isEnabled else { return }

        if let newPivot = pivotStrategy.computePivot(
            cameraState: cameraState,
            bodies: bodies,
            aspectRatio: lastAspectRatio,
            config: config
        ) {
            cameraController.adjustPivot(to: newPivot, duration: config.animationDuration)
        }
    }

    /// Schedules a dynamic pivot update with a 50ms coalesce delay.
    internal func scheduleDynamicPivotUpdate(bodies: [ViewportBody]) {
        pivotWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.updateDynamicPivot(bodies: bodies)
            }
        }
        pivotWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }
}

// MARK: - Keyboard Shortcuts

extension ViewportController {
    /// Handles keyboard shortcuts for standard views and display modes.
    public func handleKeyPress(_ key: Character) {
        // Standard view shortcuts
        for view in StandardView.allCases {
            if view.keyboardShortcut == key {
                goToStandardView(view)
                return
            }
        }

        // Display mode shortcuts
        for mode in DisplayMode.allCases {
            if mode.keyboardShortcut == key {
                displayMode = mode
                return
            }
        }
    }
}
