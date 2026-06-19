// SpikeView.swift
// Test UI for OCCTSwift Metal Demo.

import SwiftUI
import UniformTypeIdentifiers
import simd
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

struct SpikeView: View {
    @StateObject private var controller = ViewportController(configuration: SpikeView.makeConfiguration())

    /// Builds the viewport configuration, using the visionOS-tuned gesture preset
    /// when running on visionOS (issue #36, Phase 2).
    private static func makeConfiguration() -> ViewportConfiguration {
        #if os(visionOS)
        let gestures: GestureConfiguration = .visionOS
        #else
        let gestures: GestureConfiguration = .default
        #endif
        return ViewportConfiguration(
            rotationStyle: .turntable,
            gestureConfiguration: gestures,
            showViewCube: true,
            showAxes: true,
            showGrid: true,
            pickingConfiguration: PickingConfiguration(isEnabled: true)
        )
    }

    @StateObject private var selectionManager = SelectionManager()

    /// Stores the original (unselected) color for each body.
    @State private var originalColors: [String: SIMD4<Float>] = [:]

    @State private var bodies: [ViewportBody] = [
        .box(
            id: "box",
            width: 1.5, height: 1.5, depth: 1.5,
            color: SIMD4<Float>(0.4, 0.6, 0.9, 1.0)
        ),
        .cylinder(
            id: "cylinder",
            radius: 0.5, height: 2.0, segments: 32,
            color: SIMD4<Float>(0.9, 0.5, 0.3, 1.0)
        ),
        .sphere(
            id: "sphere",
            radius: 0.7, segments: 32, rings: 16,
            color: SIMD4<Float>(0.3, 0.8, 0.4, 1.0)
        ),
        // Edge-only body: a wireframe triangle on the ground plane
        ViewportBody(
            id: "wire-triangle",
            vertexData: [],
            indices: [],
            edges: [
                [
                    SIMD3<Float>(-1.0, 0.0, 2.0),
                    SIMD3<Float>( 1.0, 0.0, 2.0),
                    SIMD3<Float>( 0.0, 0.0, 4.0),
                    SIMD3<Float>(-1.0, 0.0, 2.0),
                ]
            ],
            color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0)
        ),
        // Analytic arc edge (issue #48): a smooth circle, tessellated adaptively
        // by the renderer regardless of zoom.
        ViewportBody(
            id: "arc-circle",
            vertexData: [],
            indices: [],
            edges: [],
            arcs: [
                ViewportArc.circle(
                    center: SIMD3<Float>(0, 0.8, 0),
                    radius: 2.4,
                    xAxis: SIMD3<Float>(1, 0, 0),
                    yAxis: SIMD3<Float>(0, 1, 0)
                )
            ],
            color: SIMD4<Float>(1.0, 0.2, 0.1, 1.0)
        ),
    ]

    /// CAD metadata for sub-body selection (populated by CADFileLoader or procedural primitives).
    @State private var cadMetadata: [String: CADBodyMetadata] = [:]

    /// Original OCCTSwift shapes for export, healing, and classification.
    @State private var loadedShapes: [OCCTSwift.Shape] = []

    /// Whether a file is currently loading.
    @State private var isLoadingFile = false

    /// Error message from the last load attempt.
    @State private var loadError: String?

    /// Status message for healing/export operations.
    @State private var operationStatus: String?

    /// Controls the file importer sheet.
    @State private var showFileImporter = false

    /// Controls the export file dialog.
    @State private var showExportDialog = false
    @State private var pendingExportFormat: ExportFormat?

    /// Proximity detection result text.
    @State private var proximityInfo: String?

    /// GD&T data from STEP files.
    @State private var dimensions: [DimensionInfo] = []
    @State private var geomTolerances: [GeomToleranceInfo] = []
    @State private var datums: [DatumInfo] = []

    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var showSettings = false

    @StateObject private var scriptWatcher = ScriptWatcher()

    @StateObject private var materialLibrary = MaterialLibrary()

    // Input-event inspector (issue #35 on-device verification).
    @StateObject private var inputLog = InputEventLog()
    @State private var showInputInspector = false

    var body: some View {
        viewportLayout
        .onAppear {
            // Position primitives so they don't overlap
            offsetBody(id: "box", dx: -2.5, dy: 0.75, dz: 0)
            offsetBody(id: "cylinder", dx: 0, dy: 1.0, dz: 0)
            offsetBody(id: "sphere", dx: 2.5, dy: 0.7, dz: 0)
            // Store original colors for selection highlighting
            for body in bodies {
                originalColors[body.id] = body.color
            }
            // Build procedural metadata for primitive face selection
            buildProceduralMetadata()

            // Feed the input-event inspector (issue #35).
            controller.onInputEvent = { [inputLog] event in
                inputLog.record(event)
            }

            // --test-all-demos is now handled in AppEntry.runHeadless before
            // SwiftUI boots — no need for a duplicate trigger here.
        }
        .onChange(of: controller.pickResult) {
            handleSelectionChange()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .onChange(of: showExportDialog) {
            if showExportDialog, let format = pendingExportFormat {
                showExportDialog = false
                exportShapes(format: format)
            }
        }
    }

    // MARK: - Content Types

    private var supportedContentTypes: [UTType] {
        let stepType = UTType(filenameExtension: "step") ?? .data
        let stpType = UTType(filenameExtension: "stp") ?? .data
        let stlType = UTType(filenameExtension: "stl") ?? .data
        let objType = UTType(filenameExtension: "obj") ?? .data
        let brepType = UTType(filenameExtension: "brep") ?? .data
        let brpType = UTType(filenameExtension: "brp") ?? .data
        return [stepType, stpType, stlType, objType, brepType, brpType]
    }

    // MARK: - Layout

    @ViewBuilder
    private var viewportLayout: some View {
        #if os(macOS)
        NavigationSplitView {
            sidebar
        } detail: {
            MetalViewportView(controller: controller, bodies: $bodies)
                .overlay(alignment: .topTrailing) { inputInspectorOverlay }
                .overlay(alignment: .bottom) { statusOverlay }
        }
        #else
        MetalViewportView(controller: controller, bodies: $bodies)
            .overlay(alignment: .topTrailing) { inputInspectorOverlay }
            .overlay(alignment: .topLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityIdentifier("settingsButton")
                .padding(12)
            }
            .overlay(alignment: .bottom) { statusOverlay }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    sidebar
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
        #endif
    }

    @ViewBuilder
    private var inputInspectorOverlay: some View {
        if showInputInspector {
            InputInspectorView(log: inputLog)
                .padding(12)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let status = operationStatus {
            Text(status)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 8)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            DisclosureGroup("Debug") {
                Toggle("Input event inspector", isOn: $showInputInspector)
                    .accessibilityIdentifier("inputInspectorToggle")
            }

            DisclosureGroup("File & Tools") {
                fileSection
                exportSection
                healingSection
                analysisSection
                scriptWatcherSection
            }

            DisclosureGroup("Materials") {
                MaterialEditorPanel(
                    bodies: $bodies,
                    controller: controller,
                    library: materialLibrary
                )
            }

            DisclosureGroup("Geometry Demos") {
                DisclosureGroup("Curves 2D") {
                    curve2DDemoButtons
                }
                DisclosureGroup("Curves 3D") {
                    curve3DDemoButtons
                }
                DisclosureGroup("Surfaces") {
                    surfaceDemoButtons
                }
                DisclosureGroup("Sweeps") {
                    sweepDemoButtons
                }
                DisclosureGroup("Projections") {
                    projectionDemoButtons
                }
                DisclosureGroup("Plates") {
                    plateDemoButtons
                }
            }

            DisclosureGroup("Modeling Demos") {
                DisclosureGroup("Medial Axis") {
                    medialAxisDemoButtons
                }
                DisclosureGroup("Naming") {
                    namingDemoButtons
                }
                DisclosureGroup("Annotations") {
                    annotationDemoButtons
                }
            }

            DisclosureGroup("OCCT 8 Features") {
                DisclosureGroup("Primitives & Analysis") {
                    occt8PrimitivesButtons
                }
                DisclosureGroup("Modeling Operations") {
                    occt8ModelingButtons
                }
                DisclosureGroup("Advanced Operations") {
                    occt8AdvancedButtons
                }
                DisclosureGroup("Curves & Geometry") {
                    occt8CurvesButtons
                }
                DisclosureGroup("Transforms & OCAF") {
                    occt8TransformsButtons
                }
                DisclosureGroup("I/O & Assembly") {
                    occt8IOButtons
                }
            }

            gdtSection

            DisclosureGroup("Viewport") {
                selectionModeSection
                selectionSection
                standardViewsSection
                displayModeSection
                overlaysSection
                projectionSection
                lightingSection
                shadowSection
                dofSection
                taaSection
                debugRenderingSection
            }

            statusSection
        }
        .navigationTitle("OCCTSwift Metal Demo")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        #endif
    }

    // MARK: - File Section

    private var fileSection: some View {
        Section("File") {
            Button {
                // On iOS, dismiss the settings sheet first so the file
                // importer can present without conflicting sheets.
                showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showFileImporter = true
                }
            } label: {
                Label("Open File (STEP/STL/OBJ/BREP)...", systemImage: "doc.badge.plus")
            }
            .disabled(isLoadingFile)

            if isLoadingFile {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = loadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if let status = operationStatus {
                Text(status)
                    .foregroundStyle(.green)
                    .font(.caption)
            }
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        Section("Export") {
            Button("Export as OBJ...") {
                pendingExportFormat = .obj
                showExportDialog = true
            }
            Button("Export as PLY...") {
                pendingExportFormat = .ply
                showExportDialog = true
            }
            Button("Export as STEP...") {
                pendingExportFormat = .step
                showExportDialog = true
            }
            Button("Export as BREP...") {
                pendingExportFormat = .brep
                showExportDialog = true
            }
        }
        .disabled(loadedShapes.isEmpty)
    }

    // MARK: - Script Watcher Section

    private var scriptWatcherSection: some View {
        Section("Script Watcher") {
            Toggle("Watch Scripts", isOn: $scriptWatcher.isWatching)

            if scriptWatcher.isWatching {
                Button("Reload") {
                    scriptWatcher.reload()
                }

                // Metadata display
                if let meta = scriptWatcher.manifestMetadata {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.caption.bold())
                        if let rev = meta.revision {
                            Text("Rev \(rev)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let source = meta.source {
                            Text(source)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let tags = meta.tags, !tags.isEmpty {
                            Text(tags.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !scriptWatcher.scriptBodies.isEmpty {
                    Text("\(scriptWatcher.scriptBodies.count) bodies loaded")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                if let time = scriptWatcher.lastLoadTime {
                    Text("Last: \(time.formatted(.dateTime.hour().minute().second()))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                if let error = scriptWatcher.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            // Gallery of available scripts
            if !scriptWatcher.availableScripts.isEmpty {
                ForEach(scriptWatcher.availableScripts) { entry in
                    Button {
                        scriptWatcher.loadScript(entry)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                    .font(.caption)
                                Text("\(entry.bodyCount) bodies · \(entry.timestamp.formatted(.dateTime.month().day().hour().minute()))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "cube")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: scriptWatcher.lastLoadTime) {
            guard !scriptWatcher.scriptBodies.isEmpty else { return }
            // Replace only script-prefixed bodies, keep others
            bodies.removeAll { $0.id.hasPrefix("script-") }
            bodies.append(contentsOf: scriptWatcher.scriptBodies)
            // Update shapes
            loadedShapes = scriptWatcher.scriptShapes
            // Update original colors
            for body in scriptWatcher.scriptBodies {
                originalColors[body.id] = body.color
            }
            focusOnBounds()
        }
    }

    // MARK: - Healing Section

    private var healingSection: some View {
        Section("Healing") {
            Button("Sew Faces") { applyHealing(.sew) }
            Button("Upgrade (Full Pipeline)") { applyHealing(.upgrade) }
            Button("Direct Faces") { applyHealing(.directFaces) }
            Button("Convert to BSpline") { applyHealing(.toBSpline) }
        }
        .disabled(loadedShapes.isEmpty)
    }

    // MARK: - Analysis Section

    private var analysisSection: some View {
        Section("Analysis") {
            Toggle("Curvature Overlays", isOn: $selectionManager.showCurvatureOverlays)

            Button("Check Proximity") {
                let result = selectionManager.checkProximity(
                    shapes: loadedShapes,
                    bodies: bodies,
                    metadata: cadMetadata
                )
                proximityInfo = result.info
                removeHighlights()
                bodies.append(contentsOf: result.bodies)
            }
            .disabled(loadedShapes.count < 2)

            if let info = proximityInfo {
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Curve2D Demo Section

    private enum Curve2DDemo {
        case showcase, intersections, hatching, gcc
    }

    @ViewBuilder
    private var curve2DDemoButtons: some View {
        Button("Curve Showcase") { loadCurve2DDemo(.showcase) }
        Button("Intersections") { loadCurve2DDemo(.intersections) }
        Button("Hatching") { loadCurve2DDemo(.hatching) }
        Button("Tangent Circles") { loadCurve2DDemo(.gcc) }
    }

    // MARK: - Curve3D Demo Section

    private enum Curve3DDemo {
        case showcase, helixAndSpirals, curvatureCombs, bsplineFitting
    }

    @ViewBuilder
    private var curve3DDemoButtons: some View {
        Button("3D Curve Showcase") { loadCurve3DDemo(.showcase) }
        Button("Helix & Spirals") { loadCurve3DDemo(.helixAndSpirals) }
        Button("Curvature Combs") { loadCurve3DDemo(.curvatureCombs) }
        Button("BSpline Fitting") { loadCurve3DDemo(.bsplineFitting) }
    }

    private func loadCurve3DDemo(_ demo: Curve3DDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .showcase:
            result = Curve3DGallery.curveShowcase()
        case .helixAndSpirals:
            result = Curve3DGallery.helixAndSpirals()
        case .curvatureCombs:
            result = Curve3DGallery.curvatureCombs()
        case .bsplineFitting:
            result = Curve3DGallery.bsplineFitting()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil
        focusOnBounds()
        // Use isometric view for 3D curves (not top-down)
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - Sweep Demo Section

    private enum SweepDemo {
        case constant, linearTaper, sCurve, interpolated
    }

    @ViewBuilder
    private var sweepDemoButtons: some View {
        Button("Constant Pipe") { loadSweepDemo(.constant) }
        Button("Linear Taper") { loadSweepDemo(.linearTaper) }
        Button("S-Curve Sweep") { loadSweepDemo(.sCurve) }
        Button("Interpolated Sweep") { loadSweepDemo(.interpolated) }
    }

    private func loadSweepDemo(_ demo: SweepDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .constant:
            result = SweepGallery.constantPipe()
        case .linearTaper:
            result = SweepGallery.linearTaper()
        case .sCurve:
            result = SweepGallery.sCurveSweep()
        case .interpolated:
            result = SweepGallery.interpolatedSweep()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - Medial Axis Demo Section

    private enum MedialAxisDemo {
        case rectangle, lShape, thicknessMap, customProfile
    }

    @ViewBuilder
    private var medialAxisDemoButtons: some View {
        Button("Rectangle Skeleton") { loadMedialAxisDemo(.rectangle) }
        Button("L-Shape Skeleton") { loadMedialAxisDemo(.lShape) }
        Button("Thickness Map") { loadMedialAxisDemo(.thicknessMap) }
        Button("Custom Profile") { loadMedialAxisDemo(.customProfile) }
    }

    private func loadMedialAxisDemo(_ demo: MedialAxisDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .rectangle:
            result = MedialAxisGallery.rectangleSkeleton()
        case .lShape:
            result = MedialAxisGallery.lShapeSkeleton()
        case .thicknessMap:
            result = MedialAxisGallery.thicknessMap()
        case .customProfile:
            result = MedialAxisGallery.customProfileSkeleton()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = result.description
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.top)
    }

    // MARK: - Naming Demo Section

    private enum NamingDemo {
        case primitive, modification, tracing, selection
    }

    @ViewBuilder
    private var namingDemoButtons: some View {
        Button("Primitive History") { loadNamingDemo(.primitive) }
        Button("Modification Tracking") { loadNamingDemo(.modification) }
        Button("Forward/Backward Trace") { loadNamingDemo(.tracing) }
        Button("Named Selection") { loadNamingDemo(.selection) }
    }

    private func loadNamingDemo(_ demo: NamingDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .primitive:
            result = NamingGallery.primitiveHistory()
        case .modification:
            result = NamingGallery.modificationTracking()
        case .tracing:
            result = NamingGallery.forwardBackwardTrace()
        case .selection:
            result = NamingGallery.namedSelection()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = result.description
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - Annotation Demo Section

    private enum AnnotationDemo {
        case length, radial, angle, labelsAndCloud
    }

    @ViewBuilder
    private var annotationDemoButtons: some View {
        Button("Length Dimensions") { loadAnnotationDemo(.length) }
        Button("Radius & Diameter") { loadAnnotationDemo(.radial) }
        Button("Angle Dimensions") { loadAnnotationDemo(.angle) }
        Button("Labels & Point Cloud") { loadAnnotationDemo(.labelsAndCloud) }
    }

    private func loadAnnotationDemo(_ demo: AnnotationDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .length:
            result = AnnotationGallery.lengthDimensions()
        case .radial:
            result = AnnotationGallery.radialDimensions()
        case .angle:
            result = AnnotationGallery.angleDimensions()
        case .labelsAndCloud:
            result = AnnotationGallery.labelsAndPointCloud()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = result.description
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - OCCT 8 Demo Section

    private enum OCCT8Demo {
        case helixCurves, kdTree, wedges, hatchPatterns, shapeOps, polynomials
        case transformOps, shapeAnalysis, intersections, volumeOps
        case quasiUniform, bezierFill, revolution, linearRib
        case asymmetricChamfer, loftAdvanced, offsetByJoin, featureOps
        case pipeTransitions, faceFromSurface
        case sectionAndValidation, shapeRepair, multiFuse, splitFaceByWire
        case projectionAndOffset, faceDivision, hollowAndAnalysis
        case orientedBoundingBox, fuseAndBlend, variableOffset
        case freeBoundsAndFeatures, inertiaAndDistance, surgeryAndDetection
        case solidAnd2DFillets, bsplineFillAndSubdivision
        case extremaAndArcs
        case fillingAndSelfIntersection, concavityAndInertia
        case localOpsAndValidation, splitOpsAndExtrema
        case extremaAndCurveAnalysis
        case conicsAndPolyDistance
        case transformsAndTopology
        case brepFillAndHealing
        case geometry2DCompletions
        case ocafFramework
        case ocafPersistenceAndSTEP
        case fileIOFormats
        case xdeAssembly
        case splitAndContours
        case pointCloudAndRays
        case curvatureAndIntersection
        case trihedronsAndFilling
        case featBooleansAndContours
        case tkG2dToolkit
        case fairCurveAndAnalysis
        case curveTransAndGeomFill
        case plateAndGeomFill
        case tkBoolIntersection
        case tkFeatOps
        case tkFilletOps
        case tkHlrOps
        case meshAndValidation
        case blendAndSampling
        case geomEntitiesAndBisector
        case gccAnaSolvers
        case shapeModifiersAndPolygons
        case evolvedAndMeshOps
        case extremaAndFactories
        case colorAndMaterial
        case dateAndPixMap
        case xcafDocAttributes
        case vrmlAndDocAttributes
        case unitsAndBinaryIO
        case extendedAttributesAndShapeFix
        case transformAndRecognition
        case tnamingAndPackedMaps
        case transactionsAndDeltas
        case pathAndPresentation
        case curveEvalAndQuaternion
        case obbAndClassification
        case patternsAndInterpolation
        case linearAlgebraAndConversions
        case conicConversionsAndSolvers
        case assemblyRefAndPaths
        case spatialQueryAndPrecision
        case analyticIntersections
        case compBezierToBSpline
        case fileIOAndWireframeFix
        case stlIOAndCurveAnalysis
        case trimmedCurveAndSurfaceAnalysis
        case adjacencyAndEdgeAnalysis
        case transformsAndGeometryProps
        case analyticBoundsAndQuadrics
        case geometryFactoriesAndPipeShell
        case surfaceFactoriesAndWireAnalysis
        case bsplineAndSewingDemo
        case geomPropertyCoverage
        case extremaAndConicDemo
        case mathSolversAndEvaluation
        case meshAndProjectionDemo
        case builderAndMassProperties
        case interpolationAndLofting
        case helixAndQuaternionDemo
        // Integration workflow demos
        case mountingBracket, involuteGear, bottleProfile
        case fluentChain, assemblyInterference
        case camPocketAndSlicing, camHoleAndContouring
        case draftAndThickness, booleanStressAndOBB
        case scallopCurvature, uvAndGeodesic
        // v0.117-v0.120 demos
        case v117LocalCurvature, v118BoundingBox
        case v119BrepAndBezier, v120ContinuityAndVectors
        case v121FilletChamfer, v122WireFixRepair, v123BuilderAndSection
        case v124WireAnalyzer, v125v126BSplineAndXDE
        case v130GeomEval, v131ApproxAndSurfaces
        case v132TopologyGraph, v133GraphGeometry, v134AssemblyRefs, v135GraphBuilder
        case v137RevolutionAxes, v137DrawingDimensions, v137AutoCentrelines
        case v138ThreadFeatures, v138DXFExport
        case v139ThreadFormV2
        case v140GDTWrite
        case v141TopologyRefs, v142ConstructionGeometry, v142SketchAndReconstructor
        case v143Measurements, v143DeferralsCleared
        case v144SectionAndHatch, v145SheetLayout, v146AnnotationCatalog
        case v147ConsumerPolish
        case v148DrawingAppend, v149AutomationTolerance, v150MultiFormatExport
        case v151SheetMetalCompose
        case v152InputBodyChain, v152JSONBoolean
        case v153StepAwareBends, v154FaceEdgeInits, v155ConvexBends
        case v1551WireFromShape, v1561DocumentNodeAt, v1562MeshFromArrays
        case v158MeshViewRead, v160TriangulationCacheWrite, v163ProductOpsAssembly, v164CacheInspection
        case v168ImportProgress
        case v169MeshProgress, v169ExportProgress
        case v1RootNodesAndEdgeRegularity
        case v120TopologyAttributes, v130InstancedAssembly, v131PatternCutAndEdges
        case v133MultiSectionPipe, v135HelicalSweep, v14ThreadedFasteners
        case v143PolyHLRDrawing, v147BooleanGlueFuzzy
        case v151SelfIntersecting, v152ShellsAndWireCurve
        case v160ThreadForms, v160CustomThreadProfile
        case v171NetworkSurface, v171GraphUIDsAndContinuity
    }

    // MARK: - OCCT 8 Sub-groups

    @ViewBuilder
    private var occt8PrimitivesButtons: some View {
        Button("Helix Curves") { loadOCCT8Demo(.helixCurves) }
        Button("KD-Tree Queries") { loadOCCT8Demo(.kdTree) }
        Button("Wedge Primitives") { loadOCCT8Demo(.wedges) }
        Button("Hatch Patterns") { loadOCCT8Demo(.hatchPatterns) }
        Button("Shape Operations") { loadOCCT8Demo(.shapeOps) }
        Button("Polynomial Roots") { loadOCCT8Demo(.polynomials) }
        Button("Transforms & Offset") { loadOCCT8Demo(.transformOps) }
        Button("Shape Analysis") { loadOCCT8Demo(.shapeAnalysis) }
        Button("Intersection Analysis") { loadOCCT8Demo(.intersections) }
        Button("Volume & Connected") { loadOCCT8Demo(.volumeOps) }
        Button("Curve Sampling") { loadOCCT8Demo(.quasiUniform) }
        Button("Bezier Surface Fill") { loadOCCT8Demo(.bezierFill) }
    }

    @ViewBuilder
    private var occt8ModelingButtons: some View {
        Button("Revolution from Curve") { loadOCCT8Demo(.revolution) }
        Button("Linear Rib") { loadOCCT8Demo(.linearRib) }
        Button("Asymmetric Chamfer") { loadOCCT8Demo(.asymmetricChamfer) }
        Button("Loft Advanced") { loadOCCT8Demo(.loftAdvanced) }
        Button("Offset by Join") { loadOCCT8Demo(.offsetByJoin) }
        Button("Feature Ops") { loadOCCT8Demo(.featureOps) }
        Button("Pipe Transitions") { loadOCCT8Demo(.pipeTransitions) }
        Button("Face from Surface") { loadOCCT8Demo(.faceFromSurface) }
        Button("Section & Validation") { loadOCCT8Demo(.sectionAndValidation) }
        Button("Shape Repair") { loadOCCT8Demo(.shapeRepair) }
        Button("Multi-Fuse") { loadOCCT8Demo(.multiFuse) }
        Button("Split Face by Wire") { loadOCCT8Demo(.splitFaceByWire) }
    }

    @ViewBuilder
    private var occt8AdvancedButtons: some View {
        Button("Projection & Offset") { loadOCCT8Demo(.projectionAndOffset) }
        Button("Face Division") { loadOCCT8Demo(.faceDivision) }
        Button("Hollow & Analysis") { loadOCCT8Demo(.hollowAndAnalysis) }
        Button("Oriented Bounding Box") { loadOCCT8Demo(.orientedBoundingBox) }
        Button("Fuse & Blend") { loadOCCT8Demo(.fuseAndBlend) }
        Button("Variable Offset") { loadOCCT8Demo(.variableOffset) }
        Button("Free Bounds & Features") { loadOCCT8Demo(.freeBoundsAndFeatures) }
        Button("Inertia & Distance") { loadOCCT8Demo(.inertiaAndDistance) }
        Button("Surgery & Detection") { loadOCCT8Demo(.surgeryAndDetection) }
        Button("Solid & 2D Fillets") { loadOCCT8Demo(.solidAnd2DFillets) }
        Button("BSpline Fill & Subdivision") { loadOCCT8Demo(.bsplineFillAndSubdivision) }
        Button("Extrema & Arcs") { loadOCCT8Demo(.extremaAndArcs) }
    }

    @ViewBuilder
    private var occt8CurvesButtons: some View {
        Button("Filling & Self-Intersection") { loadOCCT8Demo(.fillingAndSelfIntersection) }
        Button("Concavity & Inertia") { loadOCCT8Demo(.concavityAndInertia) }
        Button("Local Ops & Validation") { loadOCCT8Demo(.localOpsAndValidation) }
        Button("Split Ops & Extrema") { loadOCCT8Demo(.splitOpsAndExtrema) }
        Button("Extrema & Curve Analysis") { loadOCCT8Demo(.extremaAndCurveAnalysis) }
        Button("Conics & Poly Distance") { loadOCCT8Demo(.conicsAndPolyDistance) }
    }

    @ViewBuilder
    private var occt8TransformsButtons: some View {
        Button("Transforms & Topology") { loadOCCT8Demo(.transformsAndTopology) }
        Button("BRepFill & Healing") { loadOCCT8Demo(.brepFillAndHealing) }
        Button("2D Geometry Suite") { loadOCCT8Demo(.geometry2DCompletions) }
        Button("OCAF Framework") { loadOCCT8Demo(.ocafFramework) }
        Button("OCAF Persistence & STEP") { loadOCCT8Demo(.ocafPersistenceAndSTEP) }
    }

    @ViewBuilder
    private var occt8IOButtons: some View {
        Button("File I/O Formats") { loadOCCT8Demo(.fileIOFormats) }
        Button("XDE Assembly") { loadOCCT8Demo(.xdeAssembly) }
        Button("Split & Contours") { loadOCCT8Demo(.splitAndContours) }
        Button("Point Cloud & Rays") { loadOCCT8Demo(.pointCloudAndRays) }
        Button("Curvature & Intersection") { loadOCCT8Demo(.curvatureAndIntersection) }
        Button("Trihedrons & Filling") { loadOCCT8Demo(.trihedronsAndFilling) }
        Button("Feat Booleans & Contours") { loadOCCT8Demo(.featBooleansAndContours) }
        Button("TkG2d Toolkit") { loadOCCT8Demo(.tkG2dToolkit) }
        Button("FairCurve & Analysis") { loadOCCT8Demo(.fairCurveAndAnalysis) }
        Button("CurveTrans & GeomFill") { loadOCCT8Demo(.curveTransAndGeomFill) }
        Button("Plate & GeomFill") { loadOCCT8Demo(.plateAndGeomFill) }
        Button("TKBool Intersection") { loadOCCT8Demo(.tkBoolIntersection) }
        Button("TKFeat Operations") { loadOCCT8Demo(.tkFeatOps) }
        Button("TKFillet Operations") { loadOCCT8Demo(.tkFilletOps) }
        Button("HLR & Reflect Lines") { loadOCCT8Demo(.tkHlrOps) }
        Button("Mesh & Validation") { loadOCCT8Demo(.meshAndValidation) }
        Button("Blend & Sampling") { loadOCCT8Demo(.blendAndSampling) }
        Button("Geom Entities & Bisector") { loadOCCT8Demo(.geomEntitiesAndBisector) }
        Button("GccAna Solvers") { loadOCCT8Demo(.gccAnaSolvers) }
        Button("Modifiers & Polygons") { loadOCCT8Demo(.shapeModifiersAndPolygons) }
        Button("Evolved & Mesh Ops") { loadOCCT8Demo(.evolvedAndMeshOps) }
        Button("Extrema & Factories") { loadOCCT8Demo(.extremaAndFactories) }
        Button("Color & Material") { loadOCCT8Demo(.colorAndMaterial) }
        Button("Date & PixMap") { loadOCCT8Demo(.dateAndPixMap) }
        Button("XCAF Attributes") { loadOCCT8Demo(.xcafDocAttributes) }
        Button("VRML & Doc Attributes") { loadOCCT8Demo(.vrmlAndDocAttributes) }
        Button("Units & Binary I/O") { loadOCCT8Demo(.unitsAndBinaryIO) }
        Button("Ext Attributes & Fix") { loadOCCT8Demo(.extendedAttributesAndShapeFix) }
        Button("Transform & Recognition") { loadOCCT8Demo(.transformAndRecognition) }
        Button("TNaming & PackedMaps") { loadOCCT8Demo(.tnamingAndPackedMaps) }
        Button("Transactions & Deltas") { loadOCCT8Demo(.transactionsAndDeltas) }
        Button("Path & Presentation") { loadOCCT8Demo(.pathAndPresentation) }
        Button("Curve Eval & Quaternion") { loadOCCT8Demo(.curveEvalAndQuaternion) }
        Button("OBB & Classification") { loadOCCT8Demo(.obbAndClassification) }
        Button("Patterns & Interpolation") { loadOCCT8Demo(.patternsAndInterpolation) }
        Button("Linear Algebra & Conversions") { loadOCCT8Demo(.linearAlgebraAndConversions) }
        Button("Conic & Surface Conversions") { loadOCCT8Demo(.conicConversionsAndSolvers) }
        Button("Assembly Ref & Paths") { loadOCCT8Demo(.assemblyRefAndPaths) }
        Button("Spatial Query & Precision") { loadOCCT8Demo(.spatialQueryAndPrecision) }
        Button("Analytic Intersections") { loadOCCT8Demo(.analyticIntersections) }
        Button("CompBezier → BSpline") { loadOCCT8Demo(.compBezierToBSpline) }
        Button("File I/O & Wireframe Fix") { loadOCCT8Demo(.fileIOAndWireframeFix) }
        Button("STL I/O & Curve Analysis") { loadOCCT8Demo(.stlIOAndCurveAnalysis) }
        Button("Trimmed Curve & Surface") { loadOCCT8Demo(.trimmedCurveAndSurfaceAnalysis) }
        Button("Adjacency & Edge Analysis") { loadOCCT8Demo(.adjacencyAndEdgeAnalysis) }
        Button("Transforms & Geometry Props") { loadOCCT8Demo(.transformsAndGeometryProps) }
        Button("Analytic Bounds & Quadrics") { loadOCCT8Demo(.analyticBoundsAndQuadrics) }
        Button("Geometry Factories & Pipe") { loadOCCT8Demo(.geometryFactoriesAndPipeShell) }
        Button("Surface & Wire Analysis") { loadOCCT8Demo(.surfaceFactoriesAndWireAnalysis) }
        Button("BSpline & Sewing") { loadOCCT8Demo(.bsplineAndSewingDemo) }
        Button("Geom Property Coverage") { loadOCCT8Demo(.geomPropertyCoverage) }
        Button("Extrema & Conic 2D") { loadOCCT8Demo(.extremaAndConicDemo) }
        Button("Math Solvers & Eval") { loadOCCT8Demo(.mathSolversAndEvaluation) }
        Button("Mesh & Projection") { loadOCCT8Demo(.meshAndProjectionDemo) }
        Button("Builder & Mass Props") { loadOCCT8Demo(.builderAndMassProperties) }
        Button("Interpolation & Lofting") { loadOCCT8Demo(.interpolationAndLofting) }
        Button("Helix & Quaternion") { loadOCCT8Demo(.helixAndQuaternionDemo) }
        // Integration workflow demos
        Button("Mounting Bracket") { loadOCCT8Demo(.mountingBracket) }
        Button("Involute Gear") { loadOCCT8Demo(.involuteGear) }
        Button("Bottle Profile") { loadOCCT8Demo(.bottleProfile) }
        Button("Fluent Chain") { loadOCCT8Demo(.fluentChain) }
        Button("Assembly Interference") { loadOCCT8Demo(.assemblyInterference) }
        Button("CAM Pocket & Slicing") { loadOCCT8Demo(.camPocketAndSlicing) }
        Button("CAM Holes & Contouring") { loadOCCT8Demo(.camHoleAndContouring) }
        Button("Draft & Thickness") { loadOCCT8Demo(.draftAndThickness) }
        Button("Boolean Stress & OBB") { loadOCCT8Demo(.booleanStressAndOBB) }
        Button("Scallop Curvature") { loadOCCT8Demo(.scallopCurvature) }
        Button("UV Surface & Geodesic") { loadOCCT8Demo(.uvAndGeodesic) }
        Button("v0.117 Curvature & Solvers") { loadOCCT8Demo(.v117LocalCurvature) }
        Button("v0.118 BBox & Validation") { loadOCCT8Demo(.v118BoundingBox) }
        Button("v0.119 BREP & Bezier") { loadOCCT8Demo(.v119BrepAndBezier) }
        Button("v0.120 Continuity & Vectors") { loadOCCT8Demo(.v120ContinuityAndVectors) }
        Button("v0.121 Fillet & Chamfer Builders") { loadOCCT8Demo(.v121FilletChamfer) }
        Button("v0.122 Wire Fix & Repair") { loadOCCT8Demo(.v122WireFixRepair) }
        Button("v0.123 Builders & Section Ops") { loadOCCT8Demo(.v123BuilderAndSection) }
        Button("v0.124 WireAnalyzer & Queries") { loadOCCT8Demo(.v124WireAnalyzer) }
        Button("v0.125-126 BSpline & XDE") { loadOCCT8Demo(.v125v126BSplineAndXDE) }
        Button("v0.130 GeomEval & PointSet") { loadOCCT8Demo(.v130GeomEval) }
        Button("v0.131 Approx & Surfaces") { loadOCCT8Demo(.v131ApproxAndSurfaces) }
        Button("v0.132 Topology Graph") { loadOCCT8Demo(.v132TopologyGraph) }
        Button("v0.133 Graph Geometry") { loadOCCT8Demo(.v133GraphGeometry) }
        Button("v0.134 Assembly & Refs") { loadOCCT8Demo(.v134AssemblyRefs) }
        Button("v0.135 Graph Builder") { loadOCCT8Demo(.v135GraphBuilder) }
        Button("v0.137 Revolution Axes") { loadOCCT8Demo(.v137RevolutionAxes) }
        Button("v0.137 Drawing Dimensions") { loadOCCT8Demo(.v137DrawingDimensions) }
        Button("v0.137 Auto Centrelines") { loadOCCT8Demo(.v137AutoCentrelines) }
        Button("v0.138 Thread Features") { loadOCCT8Demo(.v138ThreadFeatures) }
        Button("v0.138 DXF Export") { loadOCCT8Demo(.v138DXFExport) }
        Button("v0.139 Thread Form v2") { loadOCCT8Demo(.v139ThreadFormV2) }
        Button("v0.140 GD&T Write") { loadOCCT8Demo(.v140GDTWrite) }
        Button("v0.141 Topology Refs") { loadOCCT8Demo(.v141TopologyRefs) }
        Button("v0.142 Construction Geometry") { loadOCCT8Demo(.v142ConstructionGeometry) }
        Button("v0.142 Sketch + Reconstructor") { loadOCCT8Demo(.v142SketchAndReconstructor) }
        Button("v0.143 Measurements") { loadOCCT8Demo(.v143Measurements) }
        Button("v0.143 Deferrals Cleared") { loadOCCT8Demo(.v143DeferralsCleared) }
        Button("v0.144 Section + Hatch") { loadOCCT8Demo(.v144SectionAndHatch) }
        Button("v0.145 Sheet Layout") { loadOCCT8Demo(.v145SheetLayout) }
        Button("v0.146 Annotations") { loadOCCT8Demo(.v146AnnotationCatalog) }
        Button("v0.147 Consumer Polish") { loadOCCT8Demo(.v147ConsumerPolish) }
        Button("v0.148 Drawing.append") { loadOCCT8Demo(.v148DrawingAppend) }
        Button("v0.149 Automation + Tolerance") { loadOCCT8Demo(.v149AutomationTolerance) }
        Button("v0.150 PDF/SVG/BOM") { loadOCCT8Demo(.v150MultiFormatExport) }
        Button("v0.151 SheetMetal Compose") { loadOCCT8Demo(.v151SheetMetalCompose) }
        Button("v0.152 inputBody Chain") { loadOCCT8Demo(.v152InputBodyChain) }
        Button("v0.152.1 JSON Boolean") { loadOCCT8Demo(.v152JSONBoolean) }
        Button("v0.153 Step-Aware Bends") { loadOCCT8Demo(.v153StepAwareBends) }
        Button("v0.154 Face/Edge Inits") { loadOCCT8Demo(.v154FaceEdgeInits) }
        Button("v0.155 Convex Bends") { loadOCCT8Demo(.v155ConvexBends) }
        Button("v0.155.1 Wire(Shape)") { loadOCCT8Demo(.v1551WireFromShape) }
        Button("v0.156.1 Document.node(at:)") { loadOCCT8Demo(.v1561DocumentNodeAt) }
        Button("v0.156.2 Mesh from arrays") { loadOCCT8Demo(.v1562MeshFromArrays) }
        Button("v0.158 MeshView Read") { loadOCCT8Demo(.v158MeshViewRead) }
        Button("v0.160 Triangulation+Cache Write") { loadOCCT8Demo(.v160TriangulationCacheWrite) }
        Button("v0.163 ProductOps Assembly") { loadOCCT8Demo(.v163ProductOpsAssembly) }
        Button("v0.164 Cache Inspection") { loadOCCT8Demo(.v164CacheInspection) }
        Button("v0.168 Import Progress") { loadOCCT8Demo(.v168ImportProgress) }
        Button("v0.169 Mesh Progress") { loadOCCT8Demo(.v169MeshProgress) }
        Button("v0.169 Export Progress") { loadOCCT8Demo(.v169ExportProgress) }
        Button("v1.0 RootNodes & EdgeRegularity") { loadOCCT8Demo(.v1RootNodesAndEdgeRegularity) }
        Button("v1.2 TopologyGraph Attributes") { loadOCCT8Demo(.v120TopologyAttributes) }
        Button("v1.3.0 Instanced Assembly (4×4)") { loadOCCT8Demo(.v130InstancedAssembly) }
        Button("v1.3.1 Pattern-Cut & Edge Selectors") { loadOCCT8Demo(.v131PatternCutAndEdges) }
        Button("v1.3.3 Multi-Section Pipe Shell") { loadOCCT8Demo(.v133MultiSectionPipe) }
        Button("v1.3.5 Helical Sweep (worm)") { loadOCCT8Demo(.v135HelicalSweep) }
        Button("v1.4 Threaded Fasteners") { loadOCCT8Demo(.v14ThreadedFasteners) }
        Button("v1.4.3 Poly HLR Drawing") { loadOCCT8Demo(.v143PolyHLRDrawing) }
        Button("v1.4.7 Boolean Glue & Fuzzy") { loadOCCT8Demo(.v147BooleanGlueFuzzy) }
        Button("v1.5.1 Self-Intersection Check") { loadOCCT8Demo(.v151SelfIntersecting) }
        Button("v1.5.2 Shells & WireCurve") { loadOCCT8Demo(.v152ShellsAndWireCurve) }
        Button("v1.6 Thread Forms") { loadOCCT8Demo(.v160ThreadForms) }
        Button("v1.6 Custom Thread Profile") { loadOCCT8Demo(.v160CustomThreadProfile) }
        Button("v1.7.1 Network (Gordon) Surface") { loadOCCT8Demo(.v171NetworkSurface) }
        Button("v1.7.1 Graph UIDs & Continuity") { loadOCCT8Demo(.v171GraphUIDsAndContinuity) }
    }

    private func loadOCCT8Demo(_ demo: OCCT8Demo) {
        let result: Curve2DGallery.GalleryResult
        var useTopView = false

        switch demo {
        case .helixCurves:
            result = OCCT8Gallery.helixCurves()
        case .kdTree:
            result = OCCT8Gallery.kdTreeQueries()
        case .wedges:
            result = OCCT8Gallery.wedgePrimitives()
        case .hatchPatterns:
            result = OCCT8Gallery.hatchPatterns()
            useTopView = true
        case .shapeOps:
            result = OCCT8Gallery.shapeOperations()
        case .polynomials:
            result = OCCT8Gallery.polynomialRoots()
            useTopView = true
        case .transformOps:
            result = OCCT8Gallery.transformOps()
        case .shapeAnalysis:
            result = OCCT8Gallery.shapeAnalysis()
        case .intersections:
            result = OCCT8Gallery.intersectionAnalysis()
        case .volumeOps:
            result = OCCT8Gallery.volumeOps()
        case .quasiUniform:
            result = OCCT8Gallery.quasiUniformSampling()
        case .bezierFill:
            result = OCCT8Gallery.bezierSurfaceFill()
        case .revolution:
            result = OCCT8Gallery.revolutionDemo()
        case .linearRib:
            result = OCCT8Gallery.linearRibDemo()
        case .asymmetricChamfer:
            result = OCCT8Gallery.asymmetricChamfer()
        case .loftAdvanced:
            result = OCCT8Gallery.loftAdvanced()
        case .offsetByJoin:
            result = OCCT8Gallery.offsetByJoin()
        case .featureOps:
            result = OCCT8Gallery.featureOps()
        case .pipeTransitions:
            result = OCCT8Gallery.pipeTransitions()
        case .faceFromSurface:
            result = OCCT8Gallery.faceFromSurface()
        case .sectionAndValidation:
            result = OCCT8Gallery.sectionAndValidation()
        case .shapeRepair:
            result = OCCT8Gallery.shapeRepair()
        case .multiFuse:
            result = OCCT8Gallery.multiFuse()
        case .splitFaceByWire:
            result = OCCT8Gallery.splitFaceByWire()
        case .projectionAndOffset:
            result = OCCT8Gallery.projectionAndOffset()
        case .faceDivision:
            result = OCCT8Gallery.faceDivision()
        case .hollowAndAnalysis:
            result = OCCT8Gallery.hollowAndAnalysis()
        case .orientedBoundingBox:
            result = OCCT8Gallery.orientedBoundingBox()
        case .fuseAndBlend:
            result = OCCT8Gallery.fuseAndBlend()
        case .variableOffset:
            result = OCCT8Gallery.variableOffset()
        case .freeBoundsAndFeatures:
            result = OCCT8Gallery.freeBoundsAndFeatures()
        case .inertiaAndDistance:
            result = OCCT8Gallery.inertiaAndDistance()
        case .surgeryAndDetection:
            result = OCCT8Gallery.surgeryAndDetection()
        case .solidAnd2DFillets:
            result = OCCT8Gallery.solidAnd2DFillets()
        case .bsplineFillAndSubdivision:
            result = OCCT8Gallery.bsplineFillAndSubdivision()
        case .extremaAndArcs:
            result = OCCT8Gallery.extremaAndArcs()
        case .fillingAndSelfIntersection:
            result = OCCT8Gallery.fillingAndSelfIntersection()
        case .concavityAndInertia:
            result = OCCT8Gallery.concavityAndInertia()
        case .localOpsAndValidation:
            result = OCCT8Gallery.localOpsAndValidation()
        case .splitOpsAndExtrema:
            result = OCCT8Gallery.splitOpsAndExtrema()
        case .extremaAndCurveAnalysis:
            result = OCCT8Gallery.extremaAndCurveAnalysis()
        case .conicsAndPolyDistance:
            result = OCCT8Gallery.conicsAndPolyDistance()
        case .transformsAndTopology:
            result = OCCT8Gallery.transformsAndTopology()
        case .brepFillAndHealing:
            result = OCCT8Gallery.brepFillAndHealing()
        case .geometry2DCompletions:
            result = OCCT8Gallery.geometry2DCompletions()
        case .ocafFramework:
            result = OCCT8Gallery.ocafFramework()
        case .ocafPersistenceAndSTEP:
            result = OCCT8Gallery.ocafPersistenceAndSTEP()
        case .fileIOFormats:
            result = OCCT8Gallery.fileIOFormats()
        case .xdeAssembly:
            result = OCCT8Gallery.xdeAssembly()
        case .splitAndContours:
            result = OCCT8Gallery.splitAndContours()
        case .pointCloudAndRays:
            result = OCCT8Gallery.pointCloudAndRays()
        case .curvatureAndIntersection:
            result = OCCT8Gallery.curvatureAndIntersection()
        case .trihedronsAndFilling:
            result = OCCT8Gallery.trihedronsAndFilling()
        case .featBooleansAndContours:
            result = OCCT8Gallery.featBooleansAndContours()
        case .tkG2dToolkit:
            result = OCCT8Gallery.tkG2dToolkit()
            useTopView = true
        case .fairCurveAndAnalysis:
            result = OCCT8Gallery.fairCurveAndAnalysis()
        case .curveTransAndGeomFill:
            result = OCCT8Gallery.curveTransAndGeomFill()
        case .plateAndGeomFill:
            result = OCCT8Gallery.plateAndGeomFill()
        case .tkBoolIntersection:
            result = OCCT8Gallery.tkBoolIntersection()
        case .tkFeatOps:
            result = OCCT8Gallery.tkFeatOps()
        case .tkFilletOps:
            result = OCCT8Gallery.tkFilletOps()
        case .tkHlrOps:
            result = OCCT8Gallery.tkHlrOps()
        case .meshAndValidation:
            result = OCCT8Gallery.meshAndValidation()
        case .blendAndSampling:
            result = OCCT8Gallery.blendAndSampling()
        case .geomEntitiesAndBisector:
            result = OCCT8Gallery.geomEntitiesAndBisector()
        case .gccAnaSolvers:
            result = OCCT8Gallery.gccAnaSolvers()
        case .shapeModifiersAndPolygons:
            result = OCCT8Gallery.shapeModifiersAndPolygons()
        case .evolvedAndMeshOps:
            result = OCCT8Gallery.evolvedAndMeshOps()
        case .extremaAndFactories:
            result = OCCT8Gallery.extremaAndFactories()
        case .colorAndMaterial:
            result = OCCT8Gallery.colorAndMaterial()
        case .dateAndPixMap:
            result = OCCT8Gallery.dateAndPixMap()
        case .xcafDocAttributes:
            result = OCCT8Gallery.xcafDocAttributes()
        case .vrmlAndDocAttributes:
            result = OCCT8Gallery.vrmlAndDocAttributes()
        case .unitsAndBinaryIO:
            result = OCCT8Gallery.unitsAndBinaryIO()
        case .extendedAttributesAndShapeFix:
            result = OCCT8Gallery.extendedAttributesAndShapeFix()
        case .transformAndRecognition:
            result = OCCT8Gallery.transformAndRecognition()
        case .tnamingAndPackedMaps:
            result = OCCT8Gallery.tnamingAndPackedMaps()
        case .transactionsAndDeltas:
            result = OCCT8Gallery.transactionsAndDeltas()
        case .pathAndPresentation:
            result = OCCT8Gallery.pathAndPresentation()
        case .curveEvalAndQuaternion:
            result = OCCT8Gallery.curveEvalAndQuaternion()
        case .obbAndClassification:
            result = OCCT8Gallery.obbAndClassification()
        case .patternsAndInterpolation:
            result = OCCT8Gallery.patternsAndInterpolation()
        case .linearAlgebraAndConversions:
            result = OCCT8Gallery.linearAlgebraAndConversions()
        case .conicConversionsAndSolvers:
            result = OCCT8Gallery.conicConversionsAndSolvers()
        case .assemblyRefAndPaths:
            result = OCCT8Gallery.assemblyRefAndPaths()
        case .spatialQueryAndPrecision:
            result = OCCT8Gallery.spatialQueryAndPrecision()
        case .analyticIntersections:
            result = OCCT8Gallery.analyticIntersections()
        case .compBezierToBSpline:
            result = OCCT8Gallery.compBezierToBSpline()
        case .fileIOAndWireframeFix:
            result = OCCT8Gallery.fileIOAndWireframeFix()
        case .stlIOAndCurveAnalysis:
            result = OCCT8Gallery.stlIOAndCurveAnalysis()
        case .trimmedCurveAndSurfaceAnalysis:
            result = OCCT8Gallery.trimmedCurveAndSurfaceAnalysis()
        case .adjacencyAndEdgeAnalysis:
            result = OCCT8Gallery.adjacencyAndEdgeAnalysis()
        case .transformsAndGeometryProps:
            result = OCCT8Gallery.transformsAndGeometryProps()
        case .analyticBoundsAndQuadrics:
            result = OCCT8Gallery.analyticBoundsAndQuadrics()
        case .geometryFactoriesAndPipeShell:
            result = OCCT8Gallery.geometryFactoriesAndPipeShell()
        case .surfaceFactoriesAndWireAnalysis:
            result = OCCT8Gallery.surfaceFactoriesAndWireAnalysis()
        case .bsplineAndSewingDemo:
            result = OCCT8Gallery.bsplineAndSewingDemo()
        case .geomPropertyCoverage:
            result = OCCT8Gallery.geomPropertyCoverage()
        case .extremaAndConicDemo:
            result = OCCT8Gallery.extremaAndConicDemo()
        case .mathSolversAndEvaluation:
            result = OCCT8Gallery.mathSolversAndEvaluation()
        case .meshAndProjectionDemo:
            result = OCCT8Gallery.meshAndProjectionDemo()
        case .builderAndMassProperties:
            result = OCCT8Gallery.builderAndMassProperties()
        case .interpolationAndLofting:
            result = OCCT8Gallery.interpolationAndLofting()
        case .helixAndQuaternionDemo:
            result = OCCT8Gallery.helixAndQuaternionDemo()
        case .mountingBracket:
            result = OCCT8Gallery.mountingBracketDemo()
        case .involuteGear:
            result = OCCT8Gallery.involuteGearDemo()
        case .bottleProfile:
            result = OCCT8Gallery.bottleProfileDemo()
        case .fluentChain:
            result = OCCT8Gallery.fluentChainDemo()
        case .assemblyInterference:
            result = OCCT8Gallery.assemblyInterferenceDemo()
        case .camPocketAndSlicing:
            result = OCCT8Gallery.camPocketAndSlicing()
        case .camHoleAndContouring:
            result = OCCT8Gallery.camHoleAndContouring()
        case .draftAndThickness:
            result = OCCT8Gallery.draftAndThicknessAnalysis()
        case .booleanStressAndOBB:
            result = OCCT8Gallery.booleanStressAndOBB()
        case .scallopCurvature:
            result = OCCT8Gallery.scallopCurvatureDemo()
        case .uvAndGeodesic:
            result = OCCT8Gallery.uvAndGeodesicDemo()
        case .v117LocalCurvature:
            result = OCCT8Gallery.v117LocalCurvatureAndSolvers()
        case .v118BoundingBox:
            result = OCCT8Gallery.v118BoundingBoxAndValidation()
        case .v119BrepAndBezier:
            result = OCCT8Gallery.v119BrepAndBezierControl()
        case .v120ContinuityAndVectors:
            result = OCCT8Gallery.v120ContinuityAndVectors()
        case .v121FilletChamfer:
            result = OCCT8Gallery.v121FilletChamferAndBSpline()
        case .v122WireFixRepair:
            result = OCCT8Gallery.v122WireFixAndRepair()
        case .v123BuilderAndSection:
            result = OCCT8Gallery.v123BuilderAndSectionOps()
        case .v124WireAnalyzer:
            result = OCCT8Gallery.v124WireAnalyzerAndBuilderQueries()
        case .v125v126BSplineAndXDE:
            result = OCCT8Gallery.v125v126BSplineAndXDE()
        case .v130GeomEval:
            result = OCCT8Gallery.v130GeomEvalAndPointSet()
        case .v131ApproxAndSurfaces:
            result = OCCT8Gallery.v131ApproxAndSurfaces()
        case .v132TopologyGraph:
            result = OCCT8Gallery.v132TopologyGraphCore()
        case .v133GraphGeometry:
            result = OCCT8Gallery.v133GraphGeometryAndHistory()
        case .v134AssemblyRefs:
            result = OCCT8Gallery.v134AssemblyAndRefs()
        case .v135GraphBuilder:
            result = OCCT8Gallery.v135GraphBuilder()
        case .v137RevolutionAxes:
            result = OCCT8Gallery.v137RevolutionAxes()
        case .v137DrawingDimensions:
            result = OCCT8Gallery.v137DrawingDimensions()
        case .v137AutoCentrelines:
            result = OCCT8Gallery.v137AutoCentrelines()
        case .v138ThreadFeatures:
            result = OCCT8Gallery.v138ThreadFeatures()
        case .v138DXFExport:
            result = OCCT8Gallery.v138DXFExport()
        case .v139ThreadFormV2:
            result = OCCT8Gallery.v139ThreadFormV2()
        case .v140GDTWrite:
            result = OCCT8Gallery.v140GDTWrite()
        case .v141TopologyRefs:
            result = OCCT8Gallery.v141TopologyRefsAndHistory()
        case .v142ConstructionGeometry:
            result = OCCT8Gallery.v142ConstructionGeometry()
        case .v142SketchAndReconstructor:
            result = OCCT8Gallery.v142SketchAndReconstructor()
        case .v143Measurements:
            result = OCCT8Gallery.v143Measurements()
        case .v143DeferralsCleared:
            result = OCCT8Gallery.v143DeferralsCleared()
        case .v144SectionAndHatch:
            result = OCCT8Gallery.v144SectionAndHatch()
        case .v145SheetLayout:
            result = OCCT8Gallery.v145SheetLayout()
        case .v146AnnotationCatalog:
            result = OCCT8Gallery.v146AnnotationCatalog()
        case .v147ConsumerPolish:
            result = OCCT8Gallery.v147ConsumerPolish()
        case .v148DrawingAppend:
            result = OCCT8Gallery.v148DrawingAppend()
        case .v149AutomationTolerance:
            result = OCCT8Gallery.v149AutomationTolerance()
        case .v150MultiFormatExport:
            result = OCCT8Gallery.v150MultiFormatExport()
        case .v151SheetMetalCompose:
            result = OCCT8Gallery.v151SheetMetalCompose()
        case .v152InputBodyChain:
            result = OCCT8Gallery.v152InputBodyChain()
        case .v152JSONBoolean:
            result = OCCT8Gallery.v152JSONBoolean()
        case .v153StepAwareBends:
            result = OCCT8Gallery.v153StepAwareBends()
        case .v154FaceEdgeInits:
            result = OCCT8Gallery.v154FaceEdgeInits()
        case .v155ConvexBends:
            result = OCCT8Gallery.v155ConvexBends()
        case .v1551WireFromShape:
            result = OCCT8Gallery.v155WireFromShape()
        case .v1561DocumentNodeAt:
            result = OCCT8Gallery.v1561DocumentNodeAt()
        case .v1562MeshFromArrays:
            result = OCCT8Gallery.v1562MeshFromArrays()
        case .v158MeshViewRead:
            result = OCCT8Gallery.v158MeshViewRead()
        case .v160TriangulationCacheWrite:
            result = OCCT8Gallery.v160TriangulationCacheWrite()
        case .v163ProductOpsAssembly:
            result = OCCT8Gallery.v163ProductOpsAssembly()
        case .v164CacheInspection:
            result = OCCT8Gallery.v164CacheInspection()
        case .v168ImportProgress:
            result = OCCT8Gallery.v168ImportProgress()
        case .v169MeshProgress:
            result = OCCT8Gallery.v169MeshProgress()
        case .v169ExportProgress:
            result = OCCT8Gallery.v169ExportProgress()
        case .v1RootNodesAndEdgeRegularity:
            result = OCCT8Gallery.v1RootNodesAndEdgeRegularity()
        case .v120TopologyAttributes:
            result = OCCT8Gallery.v120TopologyAttributes()
        case .v130InstancedAssembly:
            result = OCCT8Gallery.v130InstancedAssembly()
        case .v131PatternCutAndEdges:
            result = OCCT8Gallery.v131PatternCutAndEdges()
        case .v133MultiSectionPipe:
            result = OCCT8Gallery.v133MultiSectionPipe()
        case .v135HelicalSweep:
            result = OCCT8Gallery.v135HelicalSweep()
        case .v14ThreadedFasteners:
            result = OCCT8Gallery.v14ThreadedFasteners()
        case .v143PolyHLRDrawing:
            result = OCCT8Gallery.v143PolyHLRDrawing()
        case .v147BooleanGlueFuzzy:
            result = OCCT8Gallery.v147BooleanGlueFuzzy()
        case .v151SelfIntersecting:
            result = OCCT8Gallery.v151SelfIntersecting()
        case .v152ShellsAndWireCurve:
            result = OCCT8Gallery.v152ShellsAndWireCurve()
        case .v160ThreadForms:
            result = OCCT8Gallery.v160ThreadForms()
        case .v160CustomThreadProfile:
            result = OCCT8Gallery.v160CustomThreadProfile()
        case .v171NetworkSurface:
            result = OCCT8Gallery.v171NetworkSurface()
        case .v171GraphUIDsAndContinuity:
            result = OCCT8Gallery.v171GraphUIDsAndContinuity()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = result.description
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(useTopView ? .top : .isometricFrontRight)
    }

    // MARK: - Projection Demo Section

    private enum ProjectionDemo {
        case curveOnCylinder, curveOnSphere, composite, pointProjection
    }

    @ViewBuilder
    private var projectionDemoButtons: some View {
        Button("Curve on Cylinder") { loadProjectionDemo(.curveOnCylinder) }
        Button("Curve on Sphere") { loadProjectionDemo(.curveOnSphere) }
        Button("Composite Projection") { loadProjectionDemo(.composite) }
        Button("Point Projection") { loadProjectionDemo(.pointProjection) }
    }

    private func loadProjectionDemo(_ demo: ProjectionDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .curveOnCylinder:
            result = ProjectionGallery.curveOnCylinder()
        case .curveOnSphere:
            result = ProjectionGallery.curveOnSphere()
        case .composite:
            result = ProjectionGallery.compositeProjection()
        case .pointProjection:
            result = ProjectionGallery.pointProjection()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - Plate Demo Section

    private enum PlateDemo {
        case fromPoints, deformed, tangent
    }

    @ViewBuilder
    private var plateDemoButtons: some View {
        Button("Plate from Points") { loadPlateDemo(.fromPoints) }
        Button("Deformed Plate (G0)") { loadPlateDemo(.deformed) }
        Button("Tangent Deformation (G1)") { loadPlateDemo(.tangent) }
    }

    private func loadPlateDemo(_ demo: PlateDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .fromPoints:
            result = PlateGallery.plateFromPoints()
        case .deformed:
            result = PlateGallery.deformedPlate()
        case .tangent:
            result = PlateGallery.tangentDeformation()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    // MARK: - GD&T Section

    private var gdtSection: some View {
        Section("GD&T") {
            if dimensions.isEmpty && geomTolerances.isEmpty && datums.isEmpty {
                Text("No GD&T data (load STEP with PMI)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if !dimensions.isEmpty {
                ForEach(Array(dimensions.enumerated()), id: \.offset) { i, dim in
                    LabeledContent("Dim \(i)",
                                   value: String(format: "%.3f [%.3f, +%.3f]",
                                                 dim.value, dim.lowerTolerance, dim.upperTolerance))
                }
            }

            if !geomTolerances.isEmpty {
                ForEach(Array(geomTolerances.enumerated()), id: \.offset) { i, tol in
                    LabeledContent("Tol \(i)",
                                   value: String(format: "%.4f (type %d)", tol.value, tol.type))
                }
            }

            if !datums.isEmpty {
                ForEach(Array(datums.enumerated()), id: \.offset) { i, datum in
                    LabeledContent("Datum \(i)", value: datum.name)
                }
            }
        }
    }

    // MARK: - Surface Demo Section

    private enum SurfaceDemo {
        case analytic, swept, freeform, pipe, isoCurves
    }

    @ViewBuilder
    private var surfaceDemoButtons: some View {
        Button("Analytic Surfaces") { loadSurfaceDemo(.analytic) }
        Button("Swept Surfaces") { loadSurfaceDemo(.swept) }
        Button("Freeform Surfaces") { loadSurfaceDemo(.freeform) }
        Button("Pipe Surfaces") { loadSurfaceDemo(.pipe) }
        Button("Iso Curves") { loadSurfaceDemo(.isoCurves) }
    }

    private func loadSurfaceDemo(_ demo: SurfaceDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .analytic:
            result = SurfaceGallery.analyticSurfaces()
        case .swept:
            result = SurfaceGallery.sweptSurfaces()
        case .freeform:
            result = SurfaceGallery.freeformSurfaces()
        case .pipe:
            result = SurfaceGallery.pipeSurfaces()
        case .isoCurves:
            result = SurfaceGallery.isoCurves()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil
        focusOnBounds()
        controller.goToStandardView(.isometricFrontRight)
    }

    private func loadCurve2DDemo(_ demo: Curve2DDemo) {
        let result: Curve2DGallery.GalleryResult
        switch demo {
        case .showcase:
            result = Curve2DGallery.curveShowcase()
        case .intersections:
            result = Curve2DGallery.intersectionDemo()
        case .hatching:
            result = Curve2DGallery.hatchingDemo()
        case .gcc:
            result = Curve2DGallery.gccDemo()
        }

        bodies = result.bodies
        cadMetadata = [:]
        loadedShapes = []
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }
        selectionManager.clearSelection()
        controller.clearSelection()
        operationStatus = nil
        proximityInfo = nil

        // Focus camera and switch to top-down view for 2D curves
        focusOnBounds()
        controller.goToStandardView(.top)
    }

    // MARK: - Selection Mode Section

    private var selectionModeSection: some View {
        Section("Selection Mode") {
            Picker("Mode", selection: $selectionManager.mode) {
                ForEach(SelectionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Selection Section

    private var selectionSection: some View {
        Section("Selection") {
            if let pick = controller.pickResult {
                LabeledContent("Body", value: pick.bodyID)
                LabeledContent("Triangle", value: "\(pick.triangleIndex)")

                if !selectionManager.selectionInfo.isEmpty {
                    Text(selectionManager.selectionInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Clear Selection") {
                    controller.clearSelection()
                    selectionManager.clearSelection()
                    removeHighlights()
                    restoreAllColors()
                }
            } else {
                Text("Click a body to select")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var standardViewsSection: some View {
        Section("Standard Views") {
            Button("Fit All") { focusOnBounds(); controller.goToStandardView(.isometricFrontRight) }
            Button("Top") { controller.goToStandardView(.top) }
            Button("Front") { controller.goToStandardView(.front) }
            Button("Right") { controller.goToStandardView(.right) }
            Button("Isometric") { controller.goToStandardView(.isometricFrontRight) }
        }
    }

    private var displayModeSection: some View {
        Section("Display Mode") {
            Picker("Mode", selection: $controller.displayMode) {
                Text("Shaded").tag(DisplayMode.shaded)
                Text("Wireframe").tag(DisplayMode.wireframe)
                Text("Shaded + Edges").tag(DisplayMode.shadedWithEdges)
            }
            .pickerStyle(.inline)

            VStack(alignment: .leading) {
                Text("Edge Intensity: \(controller.edgeIntensity, specifier: "%.1f")")
                Slider(value: $controller.edgeIntensity, in: 0.5...10.0)
            }
        }
    }

    private var overlaysSection: some View {
        Section("Overlays") {
            Toggle("Grid", isOn: $controller.showGrid)
            Toggle("Axes", isOn: $controller.showAxes)
            Toggle("ViewCube", isOn: $controller.showViewCube)
        }
    }

    private var projectionSection: some View {
        Section("Projection") {
            Button(controller.cameraState.isOrthographic ? "Switch to Perspective" : "Switch to Orthographic") {
                controller.toggleProjection()
            }
        }
    }

    private var lightingSection: some View {
        Section("Lighting") {
            VStack(alignment: .leading) {
                Text("Specular Intensity: \(controller.lightingConfiguration.specularIntensity, specifier: "%.2f")")
                Slider(value: $controller.lightingConfiguration.specularIntensity, in: 0...1)
            }
            VStack(alignment: .leading) {
                Text("Shininess: \(controller.lightingConfiguration.specularPower, specifier: "%.0f")")
                Slider(value: $controller.lightingConfiguration.specularPower, in: 1...256)
            }
            VStack(alignment: .leading) {
                Text("Rim Light: \(controller.lightingConfiguration.fresnelIntensity, specifier: "%.2f")")
                Slider(value: $controller.lightingConfiguration.fresnelIntensity, in: 0...1)
            }
            VStack(alignment: .leading) {
                Text("Matcap Blend: \(controller.lightingConfiguration.matcapBlend, specifier: "%.2f")")
                Slider(value: $controller.lightingConfiguration.matcapBlend, in: 0...1)
            }
            VStack(alignment: .leading) {
                Text("Exposure: \(controller.lightingConfiguration.exposure, specifier: "%.2f")")
                Slider(value: $controller.lightingConfiguration.exposure, in: 0.5...3.0)
            }
            VStack(alignment: .leading) {
                Text("White Point: \(controller.lightingConfiguration.whitePoint, specifier: "%.2f")")
                Slider(value: $controller.lightingConfiguration.whitePoint, in: 0.5...2.0)
            }
        }
    }

    private var shadowSection: some View {
        Section("Shadows") {
            Toggle("Shadows", isOn: $controller.lightingConfiguration.shadowsEnabled)
            if controller.lightingConfiguration.shadowsEnabled {
                VStack(alignment: .leading) {
                    Text("Shadow Intensity: \(controller.lightingConfiguration.shadowIntensity, specifier: "%.2f")")
                    Slider(value: $controller.lightingConfiguration.shadowIntensity, in: 0...1)
                }
                VStack(alignment: .leading) {
                    Text("PCSS Light Size: \(controller.lightingConfiguration.shadowLightSize, specifier: "%.3f")")
                    Slider(value: $controller.lightingConfiguration.shadowLightSize, in: 0...0.1)
                }
                VStack(alignment: .leading) {
                    Text("PCSS Search Radius: \(controller.lightingConfiguration.shadowSearchRadius, specifier: "%.3f")")
                    Slider(value: $controller.lightingConfiguration.shadowSearchRadius, in: 0...0.05)
                }
            }
        }
    }

    private var dofSection: some View {
        Section("Depth of Field") {
            Toggle("Enable DoF", isOn: $controller.enableDepthOfField)
            if controller.enableDepthOfField {
                VStack(alignment: .leading) {
                    Text("Aperture: \(controller.dofAperture, specifier: "%.1f")")
                    Slider(value: $controller.dofAperture, in: 0.5...16.0)
                }
                VStack(alignment: .leading) {
                    Text("Focal Distance: \(controller.dofFocalDistance, specifier: "%.1f") (0 = auto)")
                    Slider(value: $controller.dofFocalDistance, in: 0...100.0)
                }
                VStack(alignment: .leading) {
                    Text("Max Blur: \(controller.dofMaxBlurRadius, specifier: "%.1f")")
                    Slider(value: $controller.dofMaxBlurRadius, in: 1...20)
                }
            }
        }
    }

    private var taaSection: some View {
        Section("Anti-Aliasing") {
            Toggle("Temporal AA (TAA)", isOn: $controller.enableTAA)
            if controller.enableTAA {
                VStack(alignment: .leading) {
                    Text("Blend Factor: \(controller.taaBlendFactor, specifier: "%.2f")")
                    Slider(value: $controller.taaBlendFactor, in: 0.5...0.98)
                }
                Toggle("Progressive accumulation (idle)", isOn: $controller.enableProgressiveAccumulation)
                    .help("Unbounded sub-pixel supersampling while the camera is still")
            }
        }
    }

    private var debugRenderingSection: some View {
        Section("Debug Rendering") {
            Toggle("1. Disable SSAO + Silhouettes", isOn: Binding(
                get: { !controller.lightingConfiguration.enableSSAO && !controller.configuration.enableSilhouettes },
                set: { disabled in
                    controller.lightingConfiguration.enableSSAO = !disabled
                }
            ))
            Toggle("2. Disable Edges (Shaded Only)", isOn: Binding(
                get: { controller.displayMode == .shaded },
                set: { shadedOnly in
                    controller.displayMode = shadedOnly ? .shaded : .shadedWithEdges
                }
            ))
            Toggle("3. Disable Shadows", isOn: Binding(
                get: { !controller.lightingConfiguration.shadowsEnabled },
                set: { disabled in
                    controller.lightingConfiguration.shadowsEnabled = !disabled
                }
            ))
            Toggle("4. Disable Curvature", isOn: $controller.debugDisableCurvature)
            Toggle("5. Disable Tessellation", isOn: $controller.debugDisableTessellation)
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Distance", value: String(format: "%.1f", controller.cameraState.distance))
            LabeledContent("Projection", value: controller.cameraState.isOrthographic ? "Orthographic" : "Perspective")
            LabeledContent("Display", value: controller.displayMode.displayName)
            LabeledContent("Bodies", value: "\(bodies.filter { !$0.id.hasPrefix("highlight-") }.count)")
        }
    }

    // MARK: - Selection Handling

    private func handleSelectionChange() {
        // Remove old highlights
        removeHighlights()

        // Restore all body colors
        restoreAllColors()

        guard let result = controller.pickResult else { return }

        // Delegate to SelectionManager for sub-body selection
        selectionManager.handlePick(
            result: result,
            ndc: controller.lastPickNDC,
            bodies: bodies,
            metadata: cadMetadata,
            cameraState: controller.cameraState,
            aspectRatio: controller.lastAspectRatio,
            shapes: loadedShapes
        )

        // In body mode, brighten the selected body
        if selectionManager.mode == .body {
            if let idx = bodies.firstIndex(where: { $0.id == result.bodyID }),
               let orig = originalColors[result.bodyID] {
                bodies[idx].color = SIMD4<Float>(
                    min(orig.x + 0.3, 1.0),
                    min(orig.y + 0.3, 1.0),
                    min(orig.z + 0.3, 1.0),
                    orig.w
                )
            }
        }

        // Add highlight overlays
        bodies.append(contentsOf: selectionManager.highlightBodies)
    }

    private func removeHighlights() {
        bodies.removeAll { $0.id.hasPrefix("highlight-") }
    }

    private func restoreAllColors() {
        for i in bodies.indices {
            if let orig = originalColors[bodies[i].id] {
                bodies[i].color = orig
            }
        }
    }

    // MARK: - File Import

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadCADFile(url)
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func loadCADFile(_ url: URL) {
        guard let format = CADFileFormat(fileExtension: url.pathExtension) else {
            loadError = "Unsupported file format: .\(url.pathExtension)"
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            loadError = "Cannot access file: permission denied"
            return
        }

        isLoadingFile = true
        loadError = nil
        operationStatus = nil

        Task {
            defer {
                url.stopAccessingSecurityScopedResource()
            }

            do {
                let result = try await CADFileLoader.load(from: url, format: format)

                bodies = result.bodies
                cadMetadata = result.metadata
                loadedShapes = result.shapes
                dimensions = result.dimensions
                geomTolerances = result.geomTolerances
                datums = result.datums

                originalColors = [:]
                for body in bodies {
                    originalColors[body.id] = body.color
                }

                proximityInfo = nil
                focusOnBounds()
                isLoadingFile = false
            } catch {
                loadError = error.localizedDescription
                isLoadingFile = false
            }
        }
    }

    // MARK: - Export

    private func exportShapes(format: ExportFormat) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.nameFieldStringValue = "export.\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            performExport(format: format, to: url)
        }
        #else
        // On iOS, export to a temp file and show share sheet
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export.\(format.fileExtension)")
        performExport(format: format, to: tempURL)
        #endif
    }

    private func performExport(format: ExportFormat, to url: URL) {
        operationStatus = nil
        Task {
            do {
                try await ExportManager.export(shapes: loadedShapes, format: format, to: url)
                operationStatus = "Exported \(format.rawValue) to \(url.lastPathComponent)"
            } catch {
                loadError = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Healing

    private enum HealingOperation {
        case sew, upgrade, directFaces, toBSpline
    }

    private func applyHealing(_ operation: HealingOperation) {
        guard !loadedShapes.isEmpty else { return }
        operationStatus = nil

        var newShapes: [OCCTSwift.Shape] = []
        var anyChanged = false

        for shape in loadedShapes {
            let healed: OCCTSwift.Shape?
            switch operation {
            case .sew:
                healed = shape.sewn()
            case .upgrade:
                healed = shape.upgraded()
            case .directFaces:
                healed = shape.directFaces()
            case .toBSpline:
                healed = shape.convertedToBSpline()
            }

            if let healed {
                newShapes.append(healed)
                anyChanged = true
            } else {
                newShapes.append(shape)
            }
        }

        guard anyChanged else {
            operationStatus = "Healing had no effect on geometry"
            return
        }

        // Re-mesh healed shapes
        loadedShapes = newShapes
        var newBodies: [ViewportBody] = []
        var newMetadata: [String: CADBodyMetadata] = [:]

        for (i, shape) in newShapes.enumerated() {
            let bodyID = "healed-\(i)"
            let color = SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
            let (body, meta) = CADFileLoader.shapeToBodyAndMetadata(shape, id: bodyID, color: color)
            if let body {
                newBodies.append(body)
                if let meta {
                    newMetadata[bodyID] = meta
                }
            }
        }

        bodies = newBodies
        cadMetadata = newMetadata
        originalColors = [:]
        for body in bodies {
            originalColors[body.id] = body.color
        }

        let opName: String
        switch operation {
        case .sew: opName = "Sew Faces"
        case .upgrade: opName = "Upgrade"
        case .directFaces: opName = "Direct Faces"
        case .toBSpline: opName = "Convert to BSpline"
        }
        operationStatus = "\(opName) applied successfully"
        focusOnBounds()
    }

    private func focusOnBounds() {
        var sceneMin = SIMD3<Float>(repeating: .infinity)
        var sceneMax = SIMD3<Float>(repeating: -.infinity)

        for body in bodies {
            guard let bb = body.boundingBox else { continue }
            sceneMin = simd_min(sceneMin, bb.min)
            sceneMax = simd_max(sceneMax, bb.max)
        }

        guard sceneMin.x < sceneMax.x else { return }

        let center = (sceneMin + sceneMax) * 0.5
        let extent = simd_length(sceneMax - sceneMin)
        let distance = extent * 1.5

        controller.focusOn(point: center, distance: distance, animated: true)
    }

    // MARK: - Procedural Metadata

    /// Builds CADBodyMetadata for procedural primitives so face/edge/vertex
    /// selection works on the default scene before any STEP file is loaded.
    private func buildProceduralMetadata() {
        for body in bodies {
            guard !body.faceIndices.isEmpty || !body.edges.isEmpty else { continue }

            let edgePolylines: [(edgeIndex: Int, points: [SIMD3<Float>])] =
                body.edges.enumerated().map { (idx, polyline) in
                    (edgeIndex: idx, points: polyline)
                }

            let vertices = deduplicateEdgeEndpoints(from: edgePolylines)

            cadMetadata[body.id] = CADBodyMetadata(
                faceIndices: body.faceIndices,
                edgePolylines: edgePolylines,
                vertices: vertices
            )
        }
    }

    private func deduplicateEdgeEndpoints(
        from edgePolylines: [(edgeIndex: Int, points: [SIMD3<Float>])]
    ) -> [SIMD3<Float>] {
        let tolerance: Float = 1e-5
        var unique: [SIMD3<Float>] = []
        for polyline in edgePolylines {
            guard let first = polyline.points.first, let last = polyline.points.last else { continue }
            for endpoint in [first, last] {
                let isDuplicate = unique.contains { existing in
                    simd_distance(existing, endpoint) < tolerance
                }
                if !isDuplicate {
                    unique.append(endpoint)
                }
            }
        }
        return unique
    }

    // MARK: - Helpers

    private func offsetBody(id: String, dx: Float, dy: Float, dz: Float) {
        guard let index = bodies.firstIndex(where: { $0.id == id }) else { return }
        var body = bodies[index]
        var newVerts: [Float] = []
        let vertexStride = 6
        for i in Swift.stride(from: 0, to: body.vertexData.count, by: vertexStride) {
            newVerts.append(body.vertexData[i] + dx)
            newVerts.append(body.vertexData[i + 1] + dy)
            newVerts.append(body.vertexData[i + 2] + dz)
            newVerts.append(body.vertexData[i + 3])
            newVerts.append(body.vertexData[i + 4])
            newVerts.append(body.vertexData[i + 5])
        }
        body.vertexData = newVerts
        body.edges = body.edges.map { polyline in
            polyline.map { p in SIMD3<Float>(p.x + dx, p.y + dy, p.z + dz) }
        }
        bodies[index] = body
    }
}
