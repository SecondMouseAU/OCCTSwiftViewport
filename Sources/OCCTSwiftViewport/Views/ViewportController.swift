// ViewportController.swift
// ViewportKit
//
// Observable controller for viewport state management.

import Combine
import Foundation
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

    /// Opacity ceiling for surfaces in `.xray` mode, `0...1`, adjustable live.
    ///
    /// Starts at `configuration.xrayOpacity` (default `DisplayMode.defaultXRayOpacity`) and is
    /// clamped on set with `DisplayMode.clampedXRayOpacity(_:)`. Lower is more see-through; at 1
    /// x-ray surfaces are drawn opaque.
    @Published public var xrayOpacity: Float {
        didSet {
            let clamped = DisplayMode.clampedXRayOpacity(xrayOpacity)
            if clamped != xrayOpacity { xrayOpacity = clamped }
        }
    }

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
    /// is selected.
    ///
    /// Pick events on bodies with `pickLayer == .widget` are routed to
    /// `widgetPickResult` instead.
    @Published public private(set) var pickResult: PickResult?

    /// The most recent pick result on the widget layer (e.g., manipulator handles
    /// from OCCTSwiftAIS), or nil.
    ///
    /// Populated for bodies with `pickLayer == .widget`.
    @Published public private(set) var widgetPickResult: PickResult?

    /// Set of currently selected body IDs.
    ///
    /// Bodies in this set render with a highlight outline.
    @Published public var selectedBodyIDs: Set<String> = []

    /// ID of the currently hovered body (mouse hover), or nil.
    @Published public var hoveredBodyID: String?

    /// NDC coordinates of the last pick tap (for sub-body selection).
    @Published public private(set) var lastPickNDC: SIMD2<Float> = .zero

    /// Edge/wireframe intensity (0 = invisible, 1 = default and fully opaque; values above 1 act as 1).
    @Published public var edgeIntensity: Float = ViewportController.defaultEdgeIntensity

    /// The `edgeIntensity` a new controller starts with; `OffscreenRenderOptions` defaults to it.
    nonisolated public static let defaultEdgeIntensity: Float = 1.0

    /// Clipping planes for section views.
    ///
    /// Only enabled planes are applied, and at most ``ClipPlane/maxActivePlanes`` (4) of them,
    /// in array order. Enabled planes past the fourth are ignored by the renderer; debug builds
    /// log a warning when this is set with more.
    @Published public var clipPlanes: [ClipPlane] = [] {
        didSet {
            #if DEBUG
                let dropped = ClipPlane.activePlanes(in: clipPlanes).dropped
                if dropped > 0 {
                    NSLog(
                        "[ViewportController] %ld enabled clip plane(s) beyond the limit of %ld "
                            + "will not be applied", dropped, ClipPlane.maxActivePlanes)
                }
            #endif
        }
    }

    /// Active measurement annotations displayed on the viewport.
    @Published public var measurements: [ViewportMeasurement] = []

    /// Current measurement interaction mode.
    ///
    /// When set to anything other than `.none`, taps on geometry feed
    /// `addMeasurementPoint(_:)` instead of the selection stream, accumulating
    /// points until a measurement is complete (2 for `.distance`/`.radius`,
    /// 3 for `.angle`). Changing the mode clears any in-progress points.
    @Published public var measurementMode: MeasurementMode = .none {
        didSet {
            if measurementMode != oldValue {
                pendingMeasurementPoints.removeAll()
            }
        }
    }

    /// World-space points picked so far for the in-progress measurement, in the
    /// order they were tapped.
    ///
    /// Cleared when a measurement completes, the mode changes, or
    /// `cancelPendingMeasurement()` is called. Drives in-progress feedback
    /// (e.g. a rubber-band line) in the overlay.
    @Published public private(set) var pendingMeasurementPoints: [SIMD3<Float>] = []

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

    /// Whether progressive idle accumulation is enabled.
    ///
    /// Requires `enableTAA`. When the camera is still, history weight grows as
    /// `N/(N+1)` rather than the fixed `taaBlendFactor`, giving unbounded
    /// supersampling. Disabled by default.
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
    ///
    /// Internal so the input router's focus-on-point raycast shares its bounding-box cache.
    lazy var pivotStrategy = PivotStrategy()

    /// Current aspect ratio (updated by MetalViewportView).
    public internal(set) var lastAspectRatio: Float = 1.0

    /// Records the size of the view, in points, that gestures move over.
    ///
    /// Sets `lastAspectRatio` and `CameraController.viewportHeight`, which keeps pan 1:1 with the
    /// pointer. `MetalViewportView` calls it whenever its size changes; call it yourself when
    /// you drive the controller from another view. An empty size is ignored.
    public func updateViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastAspectRatio = Float(size.width / size.height)
        cameraController.viewportHeight = Float(size.height)
    }

    /// Coalescing work item for dynamic pivot updates.
    private var pivotWorkItem: DispatchWorkItem?

    // MARK: - Initialization

    /// The configuration `init()` uses when none is given: `.cad`.
    ///
    /// `OffscreenRenderOptions` takes its defaults from it, so a default offscreen render matches
    /// a default live viewport.
    nonisolated public static let defaultConfiguration = ViewportConfiguration.cad

    /// Creates a viewport controller with the specified configuration.
    public init(configuration: ViewportConfiguration = ViewportController.defaultConfiguration) {
        self.configuration = configuration
        self.cameraState = configuration.effectiveInitialCameraState
        self.displayMode = configuration.displayMode
        self.xrayOpacity = DisplayMode.clampedXRayOpacity(configuration.xrayOpacity)
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

        self.cameraController = CameraController(
            initialState: configuration.effectiveInitialCameraState)
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
        cameraController.preferredFramesPerSecond = configuration.preferredFramesPerSecond

        // Sync zoom-toward-cursor pivot shift with dynamic pivot config
        cameraController.zoomTowardShiftsPivot = configuration.dynamicPivotConfiguration.isEnabled

        // Subscribe to camera controller updates.
        // Both objects are @MainActor so @Published already fires on main:
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

    /// Animates to a ViewCube region (face / edge / corner), preserving the current
    /// pivot, distance and projection, so only the orientation changes (issue #60).
    public func goToRegion(_ region: ViewCubeRegion, duration: Float = 0.3) {
        var target = cameraState
        target.rotation = region.cameraState().rotation
        cameraController.animateTo(target, duration: duration)
    }

    // MARK: - Camera Control

    /// Handles orbit gesture input: a drag delta in points, y down.
    ///
    /// This is the raw call. The model always turns with the delta, and
    /// `GestureConfiguration.dragRotation` is not applied; `dispatch(_:)` applies it.
    public func handleOrbit(translation: CGSize) {
        cameraController.orbit(
            deltaX: Float(translation.width),
            deltaY: Float(translation.height)
        )
    }

    /// Ends orbit with velocity for inertia, snapping to a nearby axis view on gentle release.
    ///
    /// `velocity` is in points per second, signed like `handleOrbit(translation:)`. The momentum
    /// starts at `GestureConfiguration.momentumScale` of it. A `.firstPerson` drag never snaps,
    /// since snapping turns the view about the pivot and would move the camera.
    public func endOrbit(velocity: CGSize) {
        defer { cameraController.endOrbitDrag() }
        let speed = sqrt(velocity.width * velocity.width + velocity.height * velocity.height)

        // If release velocity is low, check for snap to nearby axis view
        if speed < 200, cameraController.rotationStyle != .firstPerson {
            if let snapView = cameraController.nearestStandardView(threshold: 3.0) {
                // Snap the orientation only. `animateTo(StandardView)` also takes the view's
                // projection, which turned a perspective camera orthographic on a slow release.
                var target = cameraState
                target.rotation = snapView.rotation
                cameraController.animateTo(target, duration: 0.15)
                return
            }
        }

        cameraController.setAngularVelocity(momentum(fromReleaseVelocity: velocity))
    }

    /// Converts a release velocity in points per second into the camera's momentum, in points
    /// per 1/60 s, scaled by `GestureConfiguration.momentumScale`.
    func momentum(fromReleaseVelocity velocity: CGSize) -> SIMD2<Float> {
        SIMD2(Float(velocity.width), Float(velocity.height))
            * (configuration.gestureConfiguration.momentumScale / 60)
    }

    /// Handles pan gesture input.
    public func handlePan(translation: CGSize) {
        cameraController.pan(
            deltaX: Float(translation.width),
            deltaY: Float(translation.height)
        )
    }

    /// Ends pan with velocity for inertia.
    ///
    /// `velocity` is in points per second; the momentum starts at
    /// `GestureConfiguration.momentumScale` of it.
    public func endPan(velocity: CGSize) {
        cameraController.setPanVelocity(momentum(fromReleaseVelocity: velocity))
    }

    /// Handles zoom gesture input, scaled by `GestureConfiguration.zoomSensitivity`.
    public func handleZoom(magnification: CGFloat) {
        cameraController.pinchZoom(magnification: Float(magnification))
    }

    /// Pinch zoom toward the gesture centre (NDC), so fingers stay over the same world point.
    ///
    /// The magnification is scaled by `GestureConfiguration.zoomSensitivity`.
    public func handleZoom(
        magnification: CGFloat, centerNormalized: SIMD2<Float>, aspectRatio: Float
    ) {
        cameraController.pinchZoom(
            magnification: Float(magnification), cursorNormalized: centerNormalized,
            aspectRatio: aspectRatio)
    }

    /// Handles scroll wheel zoom.
    public func handleScrollZoom(delta: CGFloat) {
        cameraController.scrollZoom(delta: Float(delta))
    }

    /// Handles scroll wheel zoom toward cursor position.
    public func handleScrollZoom(delta: CGFloat, cursorNormalized: SIMD2<Float>, aspectRatio: Float)
    {
        cameraController.scrollZoom(
            delta: Float(delta), cursorNormalized: cursorNormalized, aspectRatio: aspectRatio)
    }

    /// Handles roll gesture input.
    public func handleRoll(angle: CGFloat) {
        cameraController.roll(deltaAngle: Float(angle))
    }

    /// Focuses on a specific point.
    public func focusOn(point: SIMD3<Float>, distance: Float? = nil, animated: Bool = true) {
        cameraController.focusOn(point: point, distance: distance, animated: animated)
    }

    /// Resets the camera to `configuration.initialCameraState`.
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

    /// Optional observer of the portable input-event stream, fired for every event
    /// passed to `dispatch(_:)`.
    ///
    /// Useful for debugging / HUD input inspectors; does not affect interpretation.
    /// See `ViewportInputEvent`.
    public var onInputEvent: ((ViewportInputEvent) -> Void)?

    /// Drag mode the unified pointer drag is currently interpreted as.
    ///
    /// Tracked across `dragChanged` so `dragEnded` applies the matching inertia.
    /// Internal, used by the input router (`dispatch(_:)`).
    enum InputDragMode { case orbit, pan, zoom }
    var activeInputDragMode: InputDragMode = .orbit

    /// The primary drag's pointer, in points from the view centre (y down); `nil` between drags.
    ///
    /// Internal, used by the input router.
    var inputDragPointer: SIMD2<Float>?

    /// Where the next primary drag starts, from `setDragOrigin(offsetFromCenter:)`.
    var pendingDragOrigin: SIMD2<Float>?

    /// Whether a two-finger drag is in progress.
    ///
    /// Internal, used by the input router.
    var twoFingerDragActive = false

    /// The two-finger drag's centroid, in points from the view centre (y down).
    ///
    /// `nil` between drags. Internal, used by the input router.
    var twoFingerDragPointer: SIMD2<Float>?

    /// Where the next two-finger drag starts, from `setTwoFingerDragOrigin(offsetFromCenter:)`.
    var pendingTwoFingerDragOrigin: SIMD2<Float>?

    /// Scene bodies that a `.focusOnPoint` double-tap or double-click raycasts against.
    ///
    /// `MetalViewportView` refreshes this before it dispatches a tap. Internal, used by the
    /// input router (`dispatch(_:)`).
    var inputSceneBodies: [ViewportBody] = []

    /// Optional filter constraining what the user-geometry pick stream accepts.
    ///
    /// When set, a user-geometry pick that fails the filter is treated as a miss
    /// (clearing `pickResult`), since GPU picking resolves a single primitive per
    /// pixel and has no alternate candidate to fall through to. Widget-layer picks
    /// bypass the filter, since that stream is owned by an external consumer.
    public var selectionFilter: PickResultFilter?

    /// Called by the view layer after a GPU pick readback completes.
    ///
    /// Routes the result to either `pickResult` (default) or `widgetPickResult`
    /// based on the picked body's `pickLayer`. A nil result clears `pickResult`
    /// only: `widgetPickResult` keeps its last value, since the widget-pick
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

    // MARK: - Region Picking

    /// Weak back-reference to the renderer currently driving this controller's
    /// on-screen viewport.
    ///
    /// Set by `ViewportRenderer.init`. Lets the controller forward region-pick requests
    /// to the live GPU pick texture without extending the renderer's lifetime: the
    /// renderer itself is owned by `MetalViewportView`'s view state, not the controller.
    weak var attachedRenderer: ViewportRenderer?

    /// Drawable pixel size of the attached renderer's viewport, or `.zero` before the first
    /// frame has drawn (or if no renderer is attached yet). Use this to convert a
    /// screen-space rectangle (in SwiftUI view points, e.g. from your own drag/lasso gesture)
    /// into the pixel space `performRegionPick(pixelRect:completion:)` expects:
    /// ```swift
    /// let scale = controller.drawablePixelSize.width / viewSize.width
    /// let pixelRect = CGRect(x: dragRect.minX * scale, y: dragRect.minY * scale,
    ///                        width: dragRect.width * scale, height: dragRect.height * scale)
    /// ```
    public var drawablePixelSize: CGSize { attachedRenderer?.lastDrawableSize ?? .zero }

    /// The rendering quality the attached renderer actually draws with, or `nil` before a
    /// renderer is attached.
    ///
    /// Lower than `configuration.renderingQuality` when the device can't run it: `.maximum` runs
    /// `.enhanced` on a GPU without mesh shaders (before Apple9: M3 / A17 Pro). See
    /// `ViewportRenderer.effectiveRenderingQuality`.
    public var effectiveRenderingQuality: RenderingQuality? {
        attachedRenderer?.effectiveRenderingQuality
    }

    /// Requests a batched/region GPU pick (issue #90), the screen-space-rectangle
    /// analogue of the tap-driven single-pixel pick that already populates `pickResult`.
    ///
    /// Blits the whole rectangle from the pick texture in one GPU round trip, instead of
    /// one `performPick` call per pixel.
    ///
    /// Pull-based: unlike a point pick, this does not update `pickResult` or fire `onPick`,
    /// so results go only to `completion`. `selectionFilter` is honoured with the same
    /// widget-bypass semantics as `handlePick(result:)`: widget-layer picks pass through
    /// unfiltered (that stream is owned by an external consumer), and a user-geometry pick
    /// that fails the filter is dropped. Apply your own enclosure semantics (fully-inside vs.
    /// any-intersecting) over the returned candidates: this only resolves which primitives
    /// are under the rectangle, occlusion-aware and pixel-accurate.
    ///
    /// - Parameters:
    ///   - pixelRect: The rectangle to sample, in drawable **pixel** coordinates. See
    ///     `drawablePixelSize` to convert from SwiftUI view points.
    ///   - completion: Called with every distinct primitive under the rectangle, in scan
    ///     order of first appearance. `[]` if no renderer is attached yet, the rectangle
    ///     misses the pick texture, or every primitive was filtered out.
    public func performRegionPick(
        pixelRect: CGRect, completion: @escaping @Sendable ([PickResult]) -> Void
    ) {
        guard let attachedRenderer else {
            completion([])
            return
        }
        let filter = selectionFilter
        attachedRenderer.performRegionPick(rect: pixelRect) { results in
            completion(Self.applySelectionFilter(results, filter: filter))
        }
    }

    /// Applies the widget-bypass semantics of `selectionFilter` to a batch of region-pick
    /// results.
    ///
    /// Mirrors the per-primitive routing in `handlePick(result:)`. Pulled out as a pure
    /// function so the routing logic is directly unit-testable.
    nonisolated static func applySelectionFilter(
        _ results: [PickResult],
        filter: PickResultFilter?
    ) -> [PickResult] {
        guard let filter else { return results }
        return results.filter { $0.pickLayer == .widget || filter.matches($0) }
    }

    // MARK: - Measurement Interaction

    /// Number of world points a measurement of the given mode requires before it
    /// is committed. `.none` returns 0.
    public nonisolated static func pointCount(for mode: MeasurementMode) -> Int {
        switch mode {
        case .none: return 0
        case .distance, .radius: return 2
        case .angle: return 3
        }
    }

    /// Feeds a world-space point into the active measurement.
    ///
    /// Call this from the tap/pick path while `measurementMode != .none` (the
    /// view layer does this automatically). The point is appended to
    /// `pendingMeasurementPoints`; once enough points for the current mode have
    /// been gathered, a `ViewportMeasurement` is appended to `measurements` and
    /// the pending buffer is cleared, ready for the next measurement. A no-op
    /// when the mode is `.none`.
    ///
    /// Point order per mode:
    /// - `.distance`: start, end
    /// - `.angle`: armA, vertex, armB
    /// - `.radius`: center, edge point
    public func addMeasurementPoint(_ point: SIMD3<Float>) {
        guard measurementMode != .none else { return }
        pendingMeasurementPoints.append(point)

        let needed = ViewportController.pointCount(for: measurementMode)
        guard pendingMeasurementPoints.count >= needed else { return }

        let pts = pendingMeasurementPoints
        pendingMeasurementPoints.removeAll()

        switch measurementMode {
        case .none:
            break
        case .distance:
            measurements.append(.distance(DistanceMeasurement(start: pts[0], end: pts[1])))
        case .angle:
            measurements.append(
                .angle(AngleMeasurement(pointA: pts[0], vertex: pts[1], pointB: pts[2])))
        case .radius:
            measurements.append(.radius(RadiusMeasurement(center: pts[0], edgePoint: pts[1])))
        }
    }

    /// Routes a GPU pick to the active measurement instead of the selection
    /// stream, reconstructing the world-space surface point under the tap.
    ///
    /// Called by the view layer (in place of `handlePick`) while
    /// `measurementMode != .none`. Only `.face` picks yield a point; edge/vertex
    /// picks and misses are ignored. The point is the ray/triangle intersection
    /// in world space (respecting the body's transform), then fed to
    /// `addMeasurementPoint(_:)`. On a body with more than
    /// `PickResult.maxPrimitivesPerKind` triangles the wrapped triangle index is
    /// resolved first; a pick that cannot be resolved is ignored rather than
    /// measured on the wrong triangle.
    public func handleMeasurementPick(
        result: PickResult?,
        ndc: SIMD2<Float>,
        bodies: [ViewportBody],
        aspectRatio: Float
    ) {
        lastPickNDC = ndc
        guard measurementMode != .none, let result, result.kind == .face else { return }
        guard let body = Self.body(for: result, in: bodies) else { return }

        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        // A wrapped index (body over 16,384 triangles) would intersect the wrong triangle.
        let resolved = Self.resolveAmbiguousFacePick(result, ray: ray, bodies: bodies)
        guard !resolved.isPrimitiveIndexAmbiguous,
            let point = body.worldHitPoint(ray: ray, triangleIndex: resolved.triangleIndex)
        else {
            return
        }
        addMeasurementPoint(point)
    }

    /// Resolves an ambiguous face pick for the tap at `ndc` against the current camera.
    ///
    /// The view layer calls this before `handlePick(result:ndc:)`, so `pickResult` carries the
    /// exact triangle even on bodies with more than `PickResult.maxPrimitivesPerKind` triangles.
    func resolveAmbiguousFacePick(
        _ result: PickResult?, ndc: SIMD2<Float>, bodies: [ViewportBody], aspectRatio: Float
    ) -> PickResult? {
        guard let result, result.isPrimitiveIndexAmbiguous, result.kind == .face else {
            return result
        }
        let ray = Ray.fromCamera(ndc: ndc, cameraState: cameraState, aspectRatio: aspectRatio)
        return Self.resolveAmbiguousFacePick(result, ray: ray, bodies: bodies)
    }

    /// Replaces a wrapped face-pick triangle index with the exact one under `ray`.
    ///
    /// Returns `result` unchanged unless it is an `isPrimitiveIndexAmbiguous` `.face` pick. If the
    /// CPU ray test finds no candidate triangle, the result is returned still flagged ambiguous.
    /// Pure, so it is unit-testable without a GPU.
    nonisolated static func resolveAmbiguousFacePick(
        _ result: PickResult, ray: Ray, bodies: [ViewportBody]
    ) -> PickResult {
        guard result.isPrimitiveIndexAmbiguous, result.kind == .face,
            let body = body(for: result, in: bodies),
            let exact = body.resolveWrappedTriangleIndex(result.triangleIndex, ray: ray)
        else { return result }
        return result.resolvingPrimitiveIndex(exact)
    }

    /// The body a pick names: by draw-order index when that still matches the ID, else by ID.
    nonisolated static func body(for result: PickResult, in bodies: [ViewportBody]) -> ViewportBody?
    {
        if result.bodyIndex >= 0, result.bodyIndex < bodies.count,
            bodies[result.bodyIndex].id == result.bodyID
        {
            return bodies[result.bodyIndex]
        }
        return bodies.first { $0.id == result.bodyID }
    }

    /// Discards any in-progress measurement points without committing a measurement.
    ///
    /// The mode is left unchanged.
    public func cancelPendingMeasurement() {
        pendingMeasurementPoints.removeAll()
    }

    /// Removes all committed measurements and any in-progress points.
    public func clearMeasurements() {
        measurements.removeAll()
        pendingMeasurementPoints.removeAll()
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
    ///
    /// The pivot only slides along the line of sight, so the camera's position and view
    /// direction never change: releasing a pan, orbit, pinch or roll leaves the view where the
    /// gesture put it (issue #204).
    internal func updateDynamicPivot(bodies: [ViewportBody]) {
        let config = configuration.dynamicPivotConfiguration
        // First-person turns the camera in place and the pivot just follows it; moving the
        // pivot would move the camera.
        guard config.isEnabled, cameraController.rotationStyle != .firstPerson else { return }

        if let newPivot = pivotStrategy.computePivot(
            cameraState: cameraState,
            bodies: bodies,
            aspectRatio: lastAspectRatio,
            config: config,
            clipPlanes: clipPlanes
        ) {
            cameraController.slidePivotAlongLineOfSight(
                toDepthOf: newPivot, duration: config.animationDuration)
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
    ///
    /// Equivalent to `handleKeyPress(_:modifiers:)` with no modifiers held. Prefer that overload
    /// when the key event carries modifiers, so ⌘F or ⌘W are not taken as "f" or "w".
    public func handleKeyPress(_ key: Character) {
        handleKeyPress(key, modifiers: [])
    }

    /// Handles keyboard shortcuts for standard views and display modes.
    ///
    /// The shortcuts are bare keys, so a press with ⌘, ⌃ or ⌥ held is ignored: ⌘F and ⌘W stay
    /// with the app instead of switching to the front view or wireframe. Shift is allowed through,
    /// although the shortcuts are lowercase and match case-sensitively.
    ///
    /// - Returns: `true` if the key ran a shortcut.
    @discardableResult
    public func handleKeyPress(_ key: Character, modifiers: ViewportModifierKeys) -> Bool {
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }

        // Standard view shortcuts
        for view in StandardView.allCases {
            if view.keyboardShortcut == key {
                goToStandardView(view)
                return true
            }
        }

        // Display mode shortcuts
        for mode in DisplayMode.allCases {
            if mode.keyboardShortcut == key {
                displayMode = mode
                return true
            }
        }
        return false
    }
}
