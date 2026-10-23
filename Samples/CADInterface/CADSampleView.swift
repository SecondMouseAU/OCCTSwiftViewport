// CADSampleView.swift
// OCCTSwiftViewport Sample - CAD Interface
//
// This sample demonstrates how to build a CAD-like interface using OCCTSwiftViewport.
// It is compiled by the package next to it (and by CI), so it tracks the current API.

import OCCTSwiftViewport
import SwiftUI
import simd

/// Sample CAD interface demonstrating OCCTSwiftViewport integration.
///
/// This view shows how to:
/// - Set up a MetalViewportView with ViewportBody content
/// - Add toolbar controls for standard views
/// - Create a sidebar with display options
/// - Handle keyboard shortcuts
///
/// ## Usage
///
/// ```swift
/// @main
/// struct CADApp: App {
///     var body: some Scene {
///         WindowGroup {
///             CADSampleView()
///         }
///     }
/// }
/// ```
public struct CADSampleView: View {

    // MARK: - State

    @StateObject private var viewportController = ViewportController(
        configuration: .cad
    )

    @State private var bodies: [ViewportBody] = []

    @State private var showInspector: Bool = true

    // MARK: - Body

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // Left sidebar - Tools
            toolsSidebar
        } detail: {
            // Main viewport
            ZStack {
                MetalViewportView(controller: viewportController, bodies: $bodies)

                // Top toolbar overlay
                VStack {
                    topToolbar
                    Spacer()
                    bottomStatusBar
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            // Right panel - Properties
            propertiesInspector
        }
        .onAppear { bodies = Self.buildSampleBodies() }
        #if os(macOS)
            .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    // MARK: - Sample Content

    /// A short length of track laid out in the viewport's Z-up world: it runs along Y, and the bed,
    /// sleepers and rails stack up along +Z on the XY grid.
    private static func buildSampleBodies() -> [ViewportBody] {
        var result: [ViewportBody] = []

        // Track bed: 2 wide (X), 5 long (Y), 0.2 tall (Z), resting on the grid.
        var bed = ViewportBody.box(
            id: "bed", width: 2, height: 0.2, depth: 5,
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1), up: .z)
        offsetVertices(&bed, dx: 0, dy: 0, dz: 0.1)
        result.append(bed)

        // Sleepers on the bed, spaced along the track.
        let sleeperColor = SIMD4<Float>(0.4, 0.3, 0.2, 1)
        var sleeperIndex = 0
        for i in stride(from: -2.0, through: 2.0, by: 0.5) {
            var sleeper = ViewportBody.box(
                id: "sleeper\(sleeperIndex)", width: 1.5, height: 0.1, depth: 0.15,
                color: sleeperColor, up: .z)
            offsetVertices(&sleeper, dx: 0, dy: Float(i), dz: 0.25)
            result.append(sleeper)
            sleeperIndex += 1
        }

        // Rails on the sleepers: cylinders whose axis runs along the track (Y).
        for (id, x) in [("leftRail", Float(-0.5)), ("rightRail", Float(0.5))] {
            var rail = ViewportBody.cylinder(
                id: id, radius: 0.05, height: 5,
                color: SIMD4<Float>(0.5, 0.5, 0.5, 1), up: .y)
            offsetVertices(&rail, dx: x, dy: 0, dz: 0.35)
            result.append(rail)
        }

        return result
    }

    /// Offsets all vertex positions and edge polylines in-place.
    private static func offsetVertices(_ body: inout ViewportBody, dx: Float, dy: Float, dz: Float)
    {
        let stride = 6
        for i in Swift.stride(from: 0, to: body.vertexData.count, by: stride) {
            body.vertexData[i] += dx
            body.vertexData[i + 1] += dy
            body.vertexData[i + 2] += dz
        }
        body.edges = body.edges.map { polyline in
            polyline.map { p in SIMD3<Float>(p.x + dx, p.y + dy, p.z + dz) }
        }
    }

    // MARK: - Tools Sidebar

    private var toolsSidebar: some View {
        List {
            Section("View") {
                ForEach([StandardView.top, .front, .right, .isometricFrontRight], id: \.self) {
                    view in
                    Button(view.displayName) {
                        viewportController.goToStandardView(view)
                    }
                }
            }

            Section("Display") {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Button {
                        viewportController.displayMode = mode
                    } label: {
                        HStack {
                            Text(mode.displayName)
                            Spacer()
                            if viewportController.displayMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section("Options") {
                Toggle("ViewCube", isOn: $viewportController.showViewCube)
                Toggle("Axes", isOn: $viewportController.showAxes)
                Toggle("Grid", isOn: $viewportController.showGrid)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Tools")
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack {
            // View buttons
            HStack(spacing: 4) {
                toolbarButton(icon: "arrow.up.square", tooltip: "Top View") {
                    viewportController.goToStandardView(.top)
                }
                toolbarButton(icon: "arrow.right.square", tooltip: "Front View") {
                    viewportController.goToStandardView(.front)
                }
                toolbarButton(icon: "arrow.right.square.fill", tooltip: "Right View") {
                    viewportController.goToStandardView(.right)
                }
                toolbarButton(icon: "cube", tooltip: "Isometric") {
                    viewportController.goToStandardView(.isometricFrontRight)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Display mode
            HStack(spacing: 4) {
                toolbarButton(
                    icon: viewportController.displayMode == .wireframe ? "square" : "cube.fill",
                    tooltip: "Display Mode"
                ) {
                    viewportController.cycleDisplayMode()
                }

                toolbarButton(
                    icon: viewportController.cameraState.isOrthographic
                        ? "square.dashed" : "perspective",
                    tooltip: "Toggle Projection"
                ) {
                    viewportController.toggleProjection()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Reset view
            toolbarButton(icon: "arrow.counterclockwise", tooltip: "Reset View") {
                viewportController.reset()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
    }

    private func toolbarButton(icon: String, tooltip: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Bottom Status Bar

    private var bottomStatusBar: some View {
        HStack {
            // Camera info
            Text(String(format: "Distance: %.1f", viewportController.cameraState.distance))
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Projection mode
            Text(viewportController.cameraState.isOrthographic ? "Orthographic" : "Perspective")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Display mode
            Text(viewportController.displayMode.displayName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    // MARK: - Properties Inspector

    private var propertiesInspector: some View {
        List {
            Section("Camera") {
                LabeledContent(
                    "Distance",
                    value: String(format: "%.2f", viewportController.cameraState.distance))
                LabeledContent(
                    "FOV",
                    value: String(format: "%.0f°", viewportController.cameraState.fieldOfView))
                LabeledContent(
                    "Projection",
                    value: viewportController.cameraState.isOrthographic ? "Ortho" : "Persp")
            }

            Section("Pivot") {
                let pivot = viewportController.cameraState.pivot
                LabeledContent("X", value: String(format: "%.2f", pivot.x))
                LabeledContent("Y", value: String(format: "%.2f", pivot.y))
                LabeledContent("Z", value: String(format: "%.2f", pivot.z))
            }

            Section("Rotation Style") {
                Picker(
                    "Style",
                    selection: Binding(
                        get: { viewportController.cameraController.rotationStyle },
                        set: { viewportController.cameraController.rotationStyle = $0 }
                    )
                ) {
                    Text("Turntable").tag(RotationStyle.turntable)
                    Text("Arcball").tag(RotationStyle.arcball)
                }
                .pickerStyle(.segmented)
            }
        }
        .inspectorColumnWidth(min: 200, ideal: 250, max: 300)
    }
}

// MARK: - Preview

#if DEBUG
    struct CADSampleView_Previews: PreviewProvider {
        static var previews: some View {
            CADSampleView()
        }
    }
#endif
