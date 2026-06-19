// DemoTestRunner.swift
// OCCTSwiftMetalDemo
//
// Automated test runner that cycles through all demo galleries,
// validating each produces bodies without crashing.
//
// Launch flags:
//   --test-all-demos       Run every demo once (default behaviour)
//   --render               Pipe each demo's bodies through OffscreenRenderer
//                          and assert a non-nil CGImage. Catches "geometry
//                          generates but Metal fails to rasterize" regressions.
//   --iterations N         Run the full demo set N times, logging RSS delta
//                          between runs. Default 1. Use N>=3 to surface leaks.
//   --baseline-check PATH  Compare elapsed against PATH (JSON). Fail any demo
//                          exceeding 2× its baseline.
//   --write-baseline PATH  After the final iteration, write current timings
//                          to PATH. Use to seed or refresh the baseline file.

import Foundation
import simd
import Darwin
import OCCTSwift
import OCCTSwiftViewport
import OCCTSwiftTools

/// Describes a single demo to test.
struct DemoEntry {
    let category: String
    let name: String
    let run: () -> Curve2DGallery.GalleryResult
}

/// Runs all demos and reports results.
@MainActor
enum DemoTestRunner {

    static var isTestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--test-all-demos")
    }

    /// Per-run configuration parsed from CommandLine arguments.
    struct RunOptions {
        var render: Bool = false
        var iterations: Int = 1
        /// Multiplier applied to baseline timings when checking for regressions.
        /// 2× tolerance is enough to absorb noise on warm CPUs but tight enough
        /// to catch a doubling in OCCT internals.
        var regressionThreshold: Double = 2.0
        var baselineURL: URL?
        var writeBaselineURL: URL?

        static func fromCommandLine() -> RunOptions {
            var opts = RunOptions()
            let args = ProcessInfo.processInfo.arguments
            opts.render = args.contains("--render")
            if let i = args.firstIndex(of: "--iterations"),
               i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 {
                opts.iterations = n
            }
            if let i = args.firstIndex(of: "--baseline-check"),
               i + 1 < args.count {
                opts.baselineURL = URL(fileURLWithPath: args[i + 1])
            }
            if let i = args.firstIndex(of: "--write-baseline"),
               i + 1 < args.count {
                opts.writeBaselineURL = URL(fileURLWithPath: args[i + 1])
            }
            return opts
        }
    }

    /// Resident-set size in bytes via Mach task info. Returns 0 on failure.
    static func processRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    /// All demos across every gallery category.
    static var allDemos: [DemoEntry] {
        var demos: [DemoEntry] = []

        // Curve 2D
        demos.append(DemoEntry(category: "Curve2D", name: "showcase", run: Curve2DGallery.curveShowcase))
        demos.append(DemoEntry(category: "Curve2D", name: "intersections", run: Curve2DGallery.intersectionDemo))
        demos.append(DemoEntry(category: "Curve2D", name: "hatching", run: Curve2DGallery.hatchingDemo))
        demos.append(DemoEntry(category: "Curve2D", name: "gcc", run: Curve2DGallery.gccDemo))

        // Curve 3D
        demos.append(DemoEntry(category: "Curve3D", name: "showcase", run: Curve3DGallery.curveShowcase))
        demos.append(DemoEntry(category: "Curve3D", name: "helixAndSpirals", run: Curve3DGallery.helixAndSpirals))
        demos.append(DemoEntry(category: "Curve3D", name: "curvatureCombs", run: Curve3DGallery.curvatureCombs))
        demos.append(DemoEntry(category: "Curve3D", name: "bsplineFitting", run: Curve3DGallery.bsplineFitting))

        // Surfaces
        demos.append(DemoEntry(category: "Surface", name: "analytic", run: SurfaceGallery.analyticSurfaces))
        demos.append(DemoEntry(category: "Surface", name: "swept", run: SurfaceGallery.sweptSurfaces))
        demos.append(DemoEntry(category: "Surface", name: "freeform", run: SurfaceGallery.freeformSurfaces))
        demos.append(DemoEntry(category: "Surface", name: "pipe", run: SurfaceGallery.pipeSurfaces))
        demos.append(DemoEntry(category: "Surface", name: "isoCurves", run: SurfaceGallery.isoCurves))

        // Sweeps
        demos.append(DemoEntry(category: "Sweep", name: "constant", run: SweepGallery.constantPipe))
        demos.append(DemoEntry(category: "Sweep", name: "linearTaper", run: SweepGallery.linearTaper))
        demos.append(DemoEntry(category: "Sweep", name: "sCurve", run: SweepGallery.sCurveSweep))
        demos.append(DemoEntry(category: "Sweep", name: "interpolated", run: SweepGallery.interpolatedSweep))

        // Projection
        demos.append(DemoEntry(category: "Projection", name: "curveOnCylinder", run: ProjectionGallery.curveOnCylinder))
        demos.append(DemoEntry(category: "Projection", name: "curveOnSphere", run: ProjectionGallery.curveOnSphere))
        demos.append(DemoEntry(category: "Projection", name: "composite", run: ProjectionGallery.compositeProjection))
        demos.append(DemoEntry(category: "Projection", name: "pointProjection", run: ProjectionGallery.pointProjection))

        // Plates
        demos.append(DemoEntry(category: "Plate", name: "fromPoints", run: PlateGallery.plateFromPoints))
        demos.append(DemoEntry(category: "Plate", name: "deformed", run: PlateGallery.deformedPlate))
        demos.append(DemoEntry(category: "Plate", name: "tangent", run: PlateGallery.tangentDeformation))

        // Medial Axis
        demos.append(DemoEntry(category: "MedialAxis", name: "rectangle", run: MedialAxisGallery.rectangleSkeleton))
        demos.append(DemoEntry(category: "MedialAxis", name: "lShape", run: MedialAxisGallery.lShapeSkeleton))
        demos.append(DemoEntry(category: "MedialAxis", name: "thicknessMap", run: MedialAxisGallery.thicknessMap))
        demos.append(DemoEntry(category: "MedialAxis", name: "customProfile", run: MedialAxisGallery.customProfileSkeleton))

        // Naming
        demos.append(DemoEntry(category: "Naming", name: "primitive", run: NamingGallery.primitiveHistory))
        demos.append(DemoEntry(category: "Naming", name: "modification", run: NamingGallery.modificationTracking))
        demos.append(DemoEntry(category: "Naming", name: "tracing", run: NamingGallery.forwardBackwardTrace))
        demos.append(DemoEntry(category: "Naming", name: "selection", run: NamingGallery.namedSelection))

        // Annotations
        demos.append(DemoEntry(category: "Annotation", name: "length", run: AnnotationGallery.lengthDimensions))
        demos.append(DemoEntry(category: "Annotation", name: "radial", run: AnnotationGallery.radialDimensions))
        demos.append(DemoEntry(category: "Annotation", name: "angle", run: AnnotationGallery.angleDimensions))
        demos.append(DemoEntry(category: "Annotation", name: "labelsAndCloud", run: AnnotationGallery.labelsAndPointCloud))

        // OCCT 8 (all cases)
        let occt8: [(String, () -> Curve2DGallery.GalleryResult)] = [
            ("helixCurves", OCCT8Gallery.helixCurves),
            ("kdTree", OCCT8Gallery.kdTreeQueries),
            ("wedges", OCCT8Gallery.wedgePrimitives),
            ("hatchPatterns", OCCT8Gallery.hatchPatterns),
            ("shapeOps", OCCT8Gallery.shapeOperations),
            ("polynomials", OCCT8Gallery.polynomialRoots),
            ("transformOps", OCCT8Gallery.transformOps),
            ("shapeAnalysis", OCCT8Gallery.shapeAnalysis),
            ("intersections", OCCT8Gallery.intersectionAnalysis),
            ("volumeOps", OCCT8Gallery.volumeOps),
            ("quasiUniform", OCCT8Gallery.quasiUniformSampling),
            ("bezierFill", OCCT8Gallery.bezierSurfaceFill),
            ("revolution", OCCT8Gallery.revolutionDemo),
            ("linearRib", OCCT8Gallery.linearRibDemo),
            ("asymmetricChamfer", OCCT8Gallery.asymmetricChamfer),
            ("loftAdvanced", OCCT8Gallery.loftAdvanced),
            ("offsetByJoin", OCCT8Gallery.offsetByJoin),
            ("featureOps", OCCT8Gallery.featureOps),
            ("pipeTransitions", OCCT8Gallery.pipeTransitions),
            ("faceFromSurface", OCCT8Gallery.faceFromSurface),
            ("sectionAndValidation", OCCT8Gallery.sectionAndValidation),
            ("shapeRepair", OCCT8Gallery.shapeRepair),
            ("multiFuse", OCCT8Gallery.multiFuse),
            ("splitFaceByWire", OCCT8Gallery.splitFaceByWire),
            ("projectionAndOffset", OCCT8Gallery.projectionAndOffset),
            ("faceDivision", OCCT8Gallery.faceDivision),
            ("hollowAndAnalysis", OCCT8Gallery.hollowAndAnalysis),
            ("orientedBoundingBox", OCCT8Gallery.orientedBoundingBox),
            ("fuseAndBlend", OCCT8Gallery.fuseAndBlend),
            ("variableOffset", OCCT8Gallery.variableOffset),
            ("freeBoundsAndFeatures", OCCT8Gallery.freeBoundsAndFeatures),
            ("inertiaAndDistance", OCCT8Gallery.inertiaAndDistance),
            ("surgeryAndDetection", OCCT8Gallery.surgeryAndDetection),
            ("solidAnd2DFillets", OCCT8Gallery.solidAnd2DFillets),
            ("bsplineFillAndSubdivision", OCCT8Gallery.bsplineFillAndSubdivision),
            ("extremaAndArcs", OCCT8Gallery.extremaAndArcs),
            ("fillingAndSelfIntersection", OCCT8Gallery.fillingAndSelfIntersection),
            ("concavityAndInertia", OCCT8Gallery.concavityAndInertia),
            ("localOpsAndValidation", OCCT8Gallery.localOpsAndValidation),
            ("splitOpsAndExtrema", OCCT8Gallery.splitOpsAndExtrema),
            ("extremaAndCurveAnalysis", OCCT8Gallery.extremaAndCurveAnalysis),
            ("conicsAndPolyDistance", OCCT8Gallery.conicsAndPolyDistance),
            ("transformsAndTopology", OCCT8Gallery.transformsAndTopology),
            ("brepFillAndHealing", OCCT8Gallery.brepFillAndHealing),
            ("geometry2DCompletions", OCCT8Gallery.geometry2DCompletions),
            ("ocafFramework", OCCT8Gallery.ocafFramework),
            ("ocafPersistenceAndSTEP", OCCT8Gallery.ocafPersistenceAndSTEP),
            ("fileIOFormats", OCCT8Gallery.fileIOFormats),
            ("xdeAssembly", OCCT8Gallery.xdeAssembly),
            ("splitAndContours", OCCT8Gallery.splitAndContours),
            ("pointCloudAndRays", OCCT8Gallery.pointCloudAndRays),
            ("curvatureAndIntersection", OCCT8Gallery.curvatureAndIntersection),
            ("trihedronsAndFilling", OCCT8Gallery.trihedronsAndFilling),
            ("featBooleansAndContours", OCCT8Gallery.featBooleansAndContours),
            ("tkG2dToolkit", OCCT8Gallery.tkG2dToolkit),
            ("fairCurveAndAnalysis", OCCT8Gallery.fairCurveAndAnalysis),
            ("curveTransAndGeomFill", OCCT8Gallery.curveTransAndGeomFill),
            ("plateAndGeomFill", OCCT8Gallery.plateAndGeomFill),
            ("tkBoolIntersection", OCCT8Gallery.tkBoolIntersection),
            ("tkFeatOps", OCCT8Gallery.tkFeatOps),
            ("tkFilletOps", OCCT8Gallery.tkFilletOps),
            ("tkHlrOps", OCCT8Gallery.tkHlrOps),
            ("meshAndValidation", OCCT8Gallery.meshAndValidation),
            ("blendAndSampling", OCCT8Gallery.blendAndSampling),
            ("geomEntitiesAndBisector", OCCT8Gallery.geomEntitiesAndBisector),
            ("gccAnaSolvers", OCCT8Gallery.gccAnaSolvers),
            ("shapeModifiersAndPolygons", OCCT8Gallery.shapeModifiersAndPolygons),
            ("evolvedAndMeshOps", OCCT8Gallery.evolvedAndMeshOps),
            ("extremaAndFactories", OCCT8Gallery.extremaAndFactories),
            ("colorAndMaterial", OCCT8Gallery.colorAndMaterial),
            ("dateAndPixMap", OCCT8Gallery.dateAndPixMap),
            ("xcafDocAttributes", OCCT8Gallery.xcafDocAttributes),
            ("vrmlAndDocAttributes", OCCT8Gallery.vrmlAndDocAttributes),
            ("unitsAndBinaryIO", OCCT8Gallery.unitsAndBinaryIO),
            ("extendedAttributesAndShapeFix", OCCT8Gallery.extendedAttributesAndShapeFix),
            ("transformAndRecognition", OCCT8Gallery.transformAndRecognition),
            ("tnamingAndPackedMaps", OCCT8Gallery.tnamingAndPackedMaps),
            ("transactionsAndDeltas", OCCT8Gallery.transactionsAndDeltas),
            ("pathAndPresentation", OCCT8Gallery.pathAndPresentation),
            ("curveEvalAndQuaternion", OCCT8Gallery.curveEvalAndQuaternion),
            ("obbAndClassification", OCCT8Gallery.obbAndClassification),
            ("patternsAndInterpolation", OCCT8Gallery.patternsAndInterpolation),
            ("linearAlgebraAndConversions", OCCT8Gallery.linearAlgebraAndConversions),
            ("conicConversionsAndSolvers", OCCT8Gallery.conicConversionsAndSolvers),
            ("assemblyRefAndPaths", OCCT8Gallery.assemblyRefAndPaths),
            ("spatialQueryAndPrecision", OCCT8Gallery.spatialQueryAndPrecision),
            ("analyticIntersections", OCCT8Gallery.analyticIntersections),
            ("compBezierToBSpline", OCCT8Gallery.compBezierToBSpline),
            ("fileIOAndWireframeFix", OCCT8Gallery.fileIOAndWireframeFix),
            ("stlIOAndCurveAnalysis", OCCT8Gallery.stlIOAndCurveAnalysis),
            ("trimmedCurveAndSurfaceAnalysis", OCCT8Gallery.trimmedCurveAndSurfaceAnalysis),
            ("adjacencyAndEdgeAnalysis", OCCT8Gallery.adjacencyAndEdgeAnalysis),
            ("transformsAndGeometryProps", OCCT8Gallery.transformsAndGeometryProps),
            ("analyticBoundsAndQuadrics", OCCT8Gallery.analyticBoundsAndQuadrics),
            ("geometryFactoriesAndPipeShell", OCCT8Gallery.geometryFactoriesAndPipeShell),
            ("surfaceFactoriesAndWireAnalysis", OCCT8Gallery.surfaceFactoriesAndWireAnalysis),
            ("bsplineAndSewingDemo", OCCT8Gallery.bsplineAndSewingDemo),
            ("geomPropertyCoverage", OCCT8Gallery.geomPropertyCoverage),
            ("extremaAndConicDemo", OCCT8Gallery.extremaAndConicDemo),
            ("mathSolversAndEvaluation", OCCT8Gallery.mathSolversAndEvaluation),
            ("meshAndProjectionDemo", OCCT8Gallery.meshAndProjectionDemo),
            ("builderAndMassProperties", OCCT8Gallery.builderAndMassProperties),
            ("interpolationAndLofting", OCCT8Gallery.interpolationAndLofting),
            ("helixAndQuaternionDemo", OCCT8Gallery.helixAndQuaternionDemo),
            // Integration workflow demos
            ("mountingBracket", OCCT8Gallery.mountingBracketDemo),
            ("involuteGear", OCCT8Gallery.involuteGearDemo),
            ("bottleProfile", OCCT8Gallery.bottleProfileDemo),
            ("fluentChain", OCCT8Gallery.fluentChainDemo),
            ("assemblyInterference", OCCT8Gallery.assemblyInterferenceDemo),
            ("camPocketAndSlicing", OCCT8Gallery.camPocketAndSlicing),
            ("camHoleAndContouring", OCCT8Gallery.camHoleAndContouring),
            ("draftAndThickness", OCCT8Gallery.draftAndThicknessAnalysis),
            ("booleanStressAndOBB", OCCT8Gallery.booleanStressAndOBB),
            ("scallopCurvature", OCCT8Gallery.scallopCurvatureDemo),
            ("uvAndGeodesic", OCCT8Gallery.uvAndGeodesicDemo),
            // v0.117-v0.120 demos
            ("v117LocalCurvature", OCCT8Gallery.v117LocalCurvatureAndSolvers),
            ("v118BoundingBox", OCCT8Gallery.v118BoundingBoxAndValidation),
            ("v119BrepAndBezier", OCCT8Gallery.v119BrepAndBezierControl),
            ("v120ContinuityAndVectors", OCCT8Gallery.v120ContinuityAndVectors),
            // v0.121-v0.126 demos
            ("v121FilletChamfer", OCCT8Gallery.v121FilletChamferAndBSpline),
            ("v122WireFixAndRepair", OCCT8Gallery.v122WireFixAndRepair),
            ("v123BuilderAndSection", OCCT8Gallery.v123BuilderAndSectionOps),
            ("v124WireAnalyzer", OCCT8Gallery.v124WireAnalyzerAndBuilderQueries),
            ("v125v126BSplineAndXDE", OCCT8Gallery.v125v126BSplineAndXDE),
            ("v130GeomEval", OCCT8Gallery.v130GeomEvalAndPointSet),
            ("v131ApproxAndSurfaces", OCCT8Gallery.v131ApproxAndSurfaces),
            ("v132TopologyGraph", OCCT8Gallery.v132TopologyGraphCore),
            ("v133GraphGeometry", OCCT8Gallery.v133GraphGeometryAndHistory),
            ("v134AssemblyRefs", OCCT8Gallery.v134AssemblyAndRefs),
            ("v135GraphBuilder", OCCT8Gallery.v135GraphBuilder),
            ("v137RevolutionAxes", OCCT8Gallery.v137RevolutionAxes),
            ("v137DrawingDimensions", OCCT8Gallery.v137DrawingDimensions),
            ("v137AutoCentrelines", OCCT8Gallery.v137AutoCentrelines),
            ("v138ThreadFeatures", OCCT8Gallery.v138ThreadFeatures),
            ("v138DXFExport", OCCT8Gallery.v138DXFExport),
            ("v139ThreadFormV2", OCCT8Gallery.v139ThreadFormV2),
            ("v140GDTWrite", OCCT8Gallery.v140GDTWrite),
            ("v141TopologyRefs", OCCT8Gallery.v141TopologyRefsAndHistory),
            ("v142ConstructionGeometry", OCCT8Gallery.v142ConstructionGeometry),
            ("v142SketchAndReconstructor", OCCT8Gallery.v142SketchAndReconstructor),
            ("v143Measurements", OCCT8Gallery.v143Measurements),
            ("v143DeferralsCleared", OCCT8Gallery.v143DeferralsCleared),
            ("v144SectionAndHatch", OCCT8Gallery.v144SectionAndHatch),
            ("v145SheetLayout", OCCT8Gallery.v145SheetLayout),
            ("v146AnnotationCatalog", OCCT8Gallery.v146AnnotationCatalog),
            ("v147ConsumerPolish", OCCT8Gallery.v147ConsumerPolish),
            ("v148DrawingAppend", OCCT8Gallery.v148DrawingAppend),
            ("v149AutomationTolerance", OCCT8Gallery.v149AutomationTolerance),
            ("v150MultiFormatExport", OCCT8Gallery.v150MultiFormatExport),
            ("v151SheetMetalCompose", OCCT8Gallery.v151SheetMetalCompose),
            ("v152InputBodyChain", OCCT8Gallery.v152InputBodyChain),
            ("v152JSONBoolean", OCCT8Gallery.v152JSONBoolean),
            ("v153StepAwareBends", OCCT8Gallery.v153StepAwareBends),
            ("v154FaceEdgeInits", OCCT8Gallery.v154FaceEdgeInits),
            ("v155ConvexBends", OCCT8Gallery.v155ConvexBends),
            ("v155WireFromShape", OCCT8Gallery.v155WireFromShape),
            ("v1561DocumentNodeAt", OCCT8Gallery.v1561DocumentNodeAt),
            ("v1562MeshFromArrays", OCCT8Gallery.v1562MeshFromArrays),
            ("v158MeshViewRead", OCCT8Gallery.v158MeshViewRead),
            ("v160TriangulationCacheWrite", OCCT8Gallery.v160TriangulationCacheWrite),
            ("v163ProductOpsAssembly", OCCT8Gallery.v163ProductOpsAssembly),
            ("v164CacheInspection", OCCT8Gallery.v164CacheInspection),
            ("v168ImportProgress", OCCT8Gallery.v168ImportProgress),
            ("v169MeshProgress", OCCT8Gallery.v169MeshProgress),
            ("v169ExportProgress", OCCT8Gallery.v169ExportProgress),
            ("v1RootNodesAndEdgeRegularity", OCCT8Gallery.v1RootNodesAndEdgeRegularity),
            ("v120TopologyAttributes", OCCT8Gallery.v120TopologyAttributes),
            ("v130InstancedAssembly", OCCT8Gallery.v130InstancedAssembly),
            ("v131PatternCutAndEdges", OCCT8Gallery.v131PatternCutAndEdges),
            ("v133MultiSectionPipe", OCCT8Gallery.v133MultiSectionPipe),
            ("v135HelicalSweep", OCCT8Gallery.v135HelicalSweep),
            ("v14ThreadedFasteners", OCCT8Gallery.v14ThreadedFasteners),
            ("v143PolyHLRDrawing", OCCT8Gallery.v143PolyHLRDrawing),
            ("v147BooleanGlueFuzzy", OCCT8Gallery.v147BooleanGlueFuzzy),
            ("v151SelfIntersecting", OCCT8Gallery.v151SelfIntersecting),
            ("v152ShellsAndWireCurve", OCCT8Gallery.v152ShellsAndWireCurve),
            ("v160ThreadForms", OCCT8Gallery.v160ThreadForms),
            ("v160CustomThreadProfile", OCCT8Gallery.v160CustomThreadProfile),
            ("v171NetworkSurface", OCCT8Gallery.v171NetworkSurface),
            ("v171GraphUIDsAndContinuity", OCCT8Gallery.v171GraphUIDsAndContinuity),
        ]
        for (name, run) in occt8 {
            demos.append(DemoEntry(category: "OCCT8", name: name, run: run))
        }

        return demos
    }

    /// Run all demos sequentially, logging results.
    /// Calls the completion handler with bodies for each demo so SpikeView can display them.
    /// Uses batched scheduling to avoid main queue stalls from accumulated SwiftUI/Metal state.
    ///
    /// Honours the launch flags documented in the file header (`--render`,
    /// `--iterations`, `--baseline-check`, `--write-baseline`).
    static func runAll(
        loadDemo: @escaping ([ViewportBody], String) -> Void,
        completion: @escaping (Int, Int) -> Void
    ) {
        let opts = RunOptions.fromCommandLine()
        let demos = allDemos
        let total = demos.count

        // Lazy-init the renderer once if --render is set. OffscreenRenderer
        // is @MainActor and re-uses its Metal device across calls.
        let renderer: OffscreenRenderer? = opts.render ? OffscreenRenderer() : nil
        if opts.render && renderer == nil {
            print("⚠️  --render requested but OffscreenRenderer init failed; render checks will be skipped")
            fflush(stdout)
        }

        // Optional baseline lookup table (key = "category/name", value = seconds).
        let baseline: [String: Double] = {
            guard let url = opts.baselineURL,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONDecoder().decode([String: Double].self, from: data)
            else { return [:] }
            return json
        }()
        if opts.baselineURL != nil && baseline.isEmpty {
            print("⚠️  --baseline-check supplied but baseline file is missing or empty; regression checks skipped")
            fflush(stdout)
        }

        // Aggregated timings across iterations (key = "category/name").
        var summedTimings: [String: Double] = [:]
        var totalPassed = 0
        var totalFailed = 0
        var totalRegressions = 0
        var totalRenderFailures = 0
        let initialRSS = processRSS()
        var rssTrace: [(iter: Int, rss: UInt64)] = [(0, initialRSS)]

        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  DEMO TEST RUNNER — \(total) demos × \(opts.iterations) iter                       ║")
        print("╚══════════════════════════════════════════════════════════════╝")
        if opts.render { print("  --render        : ON (verifying CGImage emission)") }
        if !baseline.isEmpty {
            print("  --baseline-check: ON (\(baseline.count) entries; threshold \(opts.regressionThreshold)×)")
        }
        if opts.iterations > 1 {
            print("  --iterations    : \(opts.iterations) (initial RSS = \(formatRSS(initialRSS)))")
        }
        fflush(stdout)

        var iteration = 1
        var index = 0
        var iterationPassed = 0
        var iterationFailed = 0
        var iterationRegressions = 0
        var iterationRenderFailures = 0
        var iterationTimings: [String: Double] = [:]
        let iterationStart = CFAbsoluteTimeGetCurrent()

        func startIteration() {
            iterationPassed = 0
            iterationFailed = 0
            iterationRegressions = 0
            iterationRenderFailures = 0
            iterationTimings.removeAll(keepingCapacity: true)
            index = 0
            if opts.iterations > 1 {
                print("")
                print("── iteration \(iteration)/\(opts.iterations) ──")
                fflush(stdout)
            }
        }

        func finishIteration() {
            let elapsed = CFAbsoluteTimeGetCurrent() - iterationStart
            for (k, v) in iterationTimings { summedTimings[k, default: 0] += v }
            totalPassed += iterationPassed
            totalFailed += iterationFailed
            totalRegressions += iterationRegressions
            totalRenderFailures += iterationRenderFailures

            if opts.iterations > 1 {
                let rss = processRSS()
                let delta = Int64(rss) - Int64(rssTrace.last?.rss ?? initialRSS)
                let deltaStr = (delta >= 0 ? "+" : "") + formatRSS(UInt64(abs(delta)))
                rssTrace.append((iteration, rss))
                print("── iteration \(iteration) done: \(iterationPassed)/\(total) passed, \(String(format: "%.1fs", elapsed)), RSS \(formatRSS(rss)) (\(deltaStr))")
                fflush(stdout)
            }
        }

        func writeBaselineIfRequested() {
            guard let url = opts.writeBaselineURL else { return }
            // Average per-demo timings across iterations.
            var averaged: [String: Double] = [:]
            for (k, v) in summedTimings { averaged[k] = v / Double(opts.iterations) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(averaged)
                try data.write(to: url)
                print("✏️  Wrote baseline (\(averaged.count) entries) → \(url.path)")
            } catch {
                print("⚠️  Failed to write baseline to \(url.path): \(error)")
            }
            fflush(stdout)
        }

        func printFinalSummary() {
            print("")
            print("════════════════════════════════════════════════════════════════")
            print("  RESULTS: \(totalPassed) passed, \(totalFailed) failed out of \(total * opts.iterations)")
            if opts.render {
                print("  Render failures: \(totalRenderFailures)")
            }
            if !baseline.isEmpty {
                print("  Timing regressions: \(totalRegressions) (>\(opts.regressionThreshold)× baseline)")
            }
            if opts.iterations > 1 {
                print("  RSS trace:")
                for entry in rssTrace {
                    let label = entry.iter == 0 ? "initial" : "after iter \(entry.iter)"
                    print("    \(label): \(formatRSS(entry.rss))")
                }
                let totalDelta = Int64(rssTrace.last?.rss ?? 0) - Int64(initialRSS)
                let leakStr = (totalDelta >= 0 ? "+" : "-") + formatRSS(UInt64(abs(totalDelta)))
                print("  Net RSS delta: \(leakStr)")
            }
            print("════════════════════════════════════════════════════════════════")
            fflush(stdout)
        }

        startIteration()

        func runNext() {
            // Process a batch of demos before yielding to the run loop.
            let batchSize = 10
            var batchCount = 0

            while index < demos.count && batchCount < batchSize {
                let demo = demos[index]
                let num = index + 1
                let key = "\(demo.category)/\(demo.name)"
                index += 1
                batchCount += 1

                let startTime = CFAbsoluteTimeGetCurrent()
                let result = demo.run()
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                iterationTimings[key] = elapsed

                let bodyCount = result.bodies.count
                let hasContent = !result.bodies.isEmpty || !result.description.isEmpty

                // Render verification: pass bodies through OffscreenRenderer.
                var renderOK = true
                var renderNote = ""
                if let renderer, hasContent, !result.bodies.isEmpty {
                    let opts = OffscreenRenderOptions(width: 256, height: 256)
                    if renderer.render(bodies: result.bodies, options: opts) == nil {
                        renderOK = false
                        renderNote = " RENDER-FAIL"
                        iterationRenderFailures += 1
                    }
                }

                // Baseline regression check.
                var regressionNote = ""
                if let baselineSec = baseline[key],
                   baselineSec > 0.05,  // ignore sub-50ms entries — too noisy
                   elapsed > baselineSec * opts.regressionThreshold {
                    iterationRegressions += 1
                    regressionNote = String(format: " REGRESSION(%.2fs vs %.2fs)", elapsed, baselineSec)
                }

                let status: String
                if hasContent && renderOK && regressionNote.isEmpty {
                    iterationPassed += 1
                    status = "✅"
                } else {
                    iterationFailed += 1
                    status = "❌"
                }

                let timeStr = String(format: "%.2fs", elapsed)
                print("\(status) [\(num)/\(total)] \(key) — \(bodyCount) bodies, \(timeStr)\(renderNote)\(regressionNote)")
                if !result.description.isEmpty {
                    let desc = result.description.prefix(120)
                    print("   └─ \(desc)")
                }
                fflush(stdout)
            }

            // Release per-batch geometry so Metal buffers don't accumulate.
            loadDemo([], "")

            if index >= demos.count {
                finishIteration()
                if iteration < opts.iterations {
                    iteration += 1
                    startIteration()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        runNext()
                    }
                    return
                }
                writeBaselineIfRequested()
                printFinalSummary()
                completion(totalPassed, totalFailed)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                runNext()
            }
        }

        runNext()
    }

    /// Human-friendly RSS formatter.
    private static func formatRSS(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}
