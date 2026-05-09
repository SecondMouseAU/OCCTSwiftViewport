// DemoSmokeTests.swift
// Systematically taps every demo button to verify no crashes.
//
// Uses XCUIAutomation APIs (XCUIApplication, XCUIElement) via XCTest.
// Run with: xcodebuild test -project OCCTSwiftViewport.xcodeproj -scheme OCCTSwiftMetalDemoUITests_macOS -destination 'platform=macOS'
//       or: xcodebuild test -project OCCTSwiftViewport.xcodeproj -scheme OCCTSwiftMetalDemoUITests_iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

@preconcurrency import XCTest
@preconcurrency import XCUIAutomation

final class DemoSmokeTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()

        #if os(iOS)
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings button not found")
        gear.tap()
        Thread.sleep(forTimeInterval: 0.5)
        // Expand the sheet to full height by swiping up on the navigation bar area
        let navBar = app.navigationBars.firstMatch
        if navBar.waitForExistence(timeout: 3) {
            navBar.swipeUp()
            Thread.sleep(forTimeInterval: 0.3)
        }
        #endif
    }

    // MARK: - Curve2D Demos

    func testCurve2DDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Curves 2D")
        tapDemo("Curve Showcase")
        tapDemo("Intersections")
        tapDemo("Hatching")
        tapDemo("Tangent Circles")
    }

    // MARK: - Curve3D Demos

    func testCurve3DDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Curves 3D")
        tapDemo("3D Curve Showcase")
        tapDemo("Helix & Spirals")
        tapDemo("Curvature Combs")
        tapDemo("BSpline Fitting")
    }

    // MARK: - Surface Demos

    func testSurfaceDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Surfaces")
        tapDemo("Analytic Surfaces")
        tapDemo("Swept Surfaces")
        tapDemo("Freeform Surfaces")
        tapDemo("Pipe Surfaces")
        tapDemo("Iso Curves")
    }

    // MARK: - Sweep Demos

    func testSweepDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Sweeps")
        tapDemo("Constant Pipe")
        tapDemo("Linear Taper")
        tapDemo("S-Curve Sweep")
        tapDemo("Interpolated Sweep")
    }

    // MARK: - Projection Demos

    func testProjectionDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Projections")
        tapDemo("Curve on Cylinder")
        tapDemo("Curve on Sphere")
        tapDemo("Composite Projection")
        tapDemo("Point Projection")
    }

    // MARK: - Plate Demos

    func testPlateDemos() {
        expandGroup("Geometry Demos")
        expandGroup("Plates")
        tapDemo("Plate from Points")
        tapDemo("Deformed Plate (G0)")
        tapDemo("Tangent Deformation (G1)")
    }

    // MARK: - Medial Axis Demos

    func testMedialAxisDemos() {
        expandGroup("Modeling Demos")
        expandGroup("Medial Axis")
        tapDemo("Rectangle Skeleton")
        tapDemo("L-Shape Skeleton")
        tapDemo("Thickness Map")
        tapDemo("Custom Profile")
    }

    // MARK: - Naming Demos

    func testNamingDemos() {
        expandGroup("Modeling Demos")
        expandGroup("Naming")
        tapDemo("Primitive History")
        tapDemo("Modification Tracking")
        tapDemo("Forward/Backward Trace")
        tapDemo("Named Selection")
    }

    // MARK: - Annotation Demos

    func testAnnotationDemos() {
        expandGroup("Modeling Demos")
        expandGroup("Annotations")
        tapDemo("Length Dimensions")
        tapDemo("Radius & Diameter")
        tapDemo("Angle Dimensions")
        tapDemo("Labels & Point Cloud")
    }

    // MARK: - OCCT 8 Demos (Part 1: geometry primitives & analysis)

    func testOCCT8DemosPart1() {
        expandGroup("OCCT 8 Features")
        expandGroup("Primitives & Analysis")
        tapDemo("Helix Curves")
        tapDemo("KD-Tree Queries")
        tapDemo("Wedge Primitives")
        tapDemo("Hatch Patterns")
        tapDemo("Shape Operations")
        tapDemo("Polynomial Roots")
        tapDemo("Transforms & Offset")
        tapDemo("Shape Analysis")
        tapDemo("Intersection Analysis")
        tapDemo("Volume & Connected")
        tapDemo("Curve Sampling")
        tapDemo("Bezier Surface Fill")
    }

    // MARK: - OCCT 8 Demos (Part 2: modeling operations)

    func testOCCT8DemosPart2() {
        expandGroup("OCCT 8 Features")
        expandGroup("Modeling Operations")
        tapDemo("Revolution from Curve")
        tapDemo("Linear Rib")
        tapDemo("Asymmetric Chamfer")
        tapDemo("Loft Advanced")
        tapDemo("Offset by Join")
        tapDemo("Feature Ops")
        tapDemo("Pipe Transitions")
        tapDemo("Face from Surface")
        tapDemo("Section & Validation")
        tapDemo("Shape Repair")
        tapDemo("Multi-Fuse")
        tapDemo("Split Face by Wire")
    }

    // MARK: - OCCT 8 Demos (Part 3: advanced operations)

    func testOCCT8DemosPart3() {
        expandGroup("OCCT 8 Features")
        expandGroup("Advanced Operations")
        tapDemo("Projection & Offset")
        tapDemo("Face Division")
        tapDemo("Hollow & Analysis")
        tapDemo("Oriented Bounding Box")
        tapDemo("Fuse & Blend")
        tapDemo("Variable Offset")
        tapDemo("Free Bounds & Features")
        tapDemo("Inertia & Distance")
        tapDemo("Surgery & Detection")
        tapDemo("Solid & 2D Fillets")
        tapDemo("BSpline Fill & Subdivision")
        tapDemo("Extrema & Arcs")
    }

    // MARK: - OCCT 8 Demos (Part 4: curves, geometry & OCAF)

    func testOCCT8DemosPart4() {
        expandGroup("OCCT 8 Features")
        expandGroup("Curves & Geometry")
        tapDemo("Filling & Self-Intersection")
        tapDemo("Concavity & Inertia")
        tapDemo("Local Ops & Validation")
        tapDemo("Split Ops & Extrema")
        tapDemo("Extrema & Curve Analysis")
        tapDemo("Conics & Poly Distance")
        expandGroup("Transforms & OCAF")
        tapDemo("Transforms & Topology")
        tapDemo("BRepFill & Healing")
        tapDemo("2D Geometry Suite")
        tapDemo("OCAF Framework")
        tapDemo("OCAF Persistence & STEP")
    }

    // MARK: - OCCT 8 Demos (Part 5: I/O, assembly, advanced geometry)

    func testOCCT8DemosPart5() {
        expandGroup("OCCT 8 Features")
        expandGroup("I/O & Assembly")
        tapDemo("File I/O Formats")
        tapDemo("XDE Assembly")
        tapDemo("Split & Contours")
        tapDemo("Point Cloud & Rays")
        tapDemo("Curvature & Intersection")
        tapDemo("Trihedrons & Filling")
        tapDemo("Feat Booleans & Contours")
        tapDemo("TkG2d Toolkit")
        tapDemo("FairCurve & Analysis")
        tapDemo("CurveTrans & GeomFill")
        tapDemo("Plate & GeomFill")
        tapDemo("TKBool Intersection")
        tapDemo("TKFeat Operations")
        tapDemo("TKFillet Operations")
        tapDemo("HLR & Reflect Lines")
        tapDemo("Mesh & Validation")
        tapDemo("Blend & Sampling")
        tapDemo("Geom Entities & Bisector")
        tapDemo("GccAna Solvers")
        tapDemo("Modifiers & Polygons")
        tapDemo("Evolved & Mesh Ops")
        tapDemo("Extrema & Factories")
        tapDemo("Color & Material")
        tapDemo("Date & PixMap")
        tapDemo("XCAF Attributes")
        tapDemo("VRML & Doc Attributes")
        tapDemo("Units & Binary I/O")
        tapDemo("Ext Attributes & Fix")
        // v0.87 onward — added to the same I/O & Assembly group.
        tapDemo("Transform & Recognition")
        tapDemo("TNaming & PackedMaps")
        tapDemo("Transactions & Deltas")
        tapDemo("Path & Presentation")
        tapDemo("Curve Eval & Quaternion")
        tapDemo("OBB & Classification")
        tapDemo("Patterns & Interpolation")
        tapDemo("Linear Algebra & Conversions")
        tapDemo("Conic & Surface Conversions")
        tapDemo("Assembly Ref & Paths")
        tapDemo("Spatial Query & Precision")
        tapDemo("Analytic Intersections")
        tapDemo("CompBezier → BSpline")
        tapDemo("File I/O & Wireframe Fix")
        tapDemo("STL I/O & Curve Analysis")
        tapDemo("Trimmed Curve & Surface")
        tapDemo("Adjacency & Edge Analysis")
        tapDemo("Transforms & Geometry Props")
        tapDemo("Analytic Bounds & Quadrics")
        tapDemo("Geometry Factories & Pipe")
        tapDemo("Surface & Wire Analysis")
        tapDemo("BSpline & Sewing")
        tapDemo("Geom Property Coverage")
        tapDemo("Extrema & Conic 2D")
        tapDemo("Math Solvers & Eval")
        tapDemo("Mesh & Projection")
        tapDemo("Builder & Mass Props")
        tapDemo("Interpolation & Lofting")
        tapDemo("Helix & Quaternion")
    }

    // MARK: - End-to-End stress demos

    func testEndToEndDemos() {
        expandGroup("OCCT 8 Features")
        expandGroup("I/O & Assembly")
        tapDemo("Mounting Bracket")
        tapDemo("Involute Gear")
        tapDemo("Bottle Profile")
        tapDemo("Fluent Chain")
        tapDemo("Assembly Interference")
        tapDemo("CAM Pocket & Slicing")
        tapDemo("CAM Holes & Contouring")
        tapDemo("Draft & Thickness")
        tapDemo("Boolean Stress & OBB")
        tapDemo("Scallop Curvature")
        tapDemo("UV Surface & Geodesic")
    }

    // MARK: - OCCT 8 Demos (Part 6: v0.117–v0.135)

    func testOCCT8DemosPart6() {
        expandGroup("OCCT 8 Features")
        expandGroup("I/O & Assembly")
        tapDemo("v0.117 Curvature & Solvers")
        tapDemo("v0.118 BBox & Validation")
        tapDemo("v0.119 BREP & Bezier")
        tapDemo("v0.120 Continuity & Vectors")
        tapDemo("v0.121 Fillet & Chamfer Builders")
        tapDemo("v0.122 Wire Fix & Repair")
        tapDemo("v0.123 Builders & Section Ops")
        tapDemo("v0.124 WireAnalyzer & Queries")
        tapDemo("v0.125-126 BSpline & XDE")
        tapDemo("v0.130 GeomEval & PointSet")
        tapDemo("v0.131 Approx & Surfaces")
        tapDemo("v0.132 Topology Graph")
        tapDemo("v0.133 Graph Geometry")
        tapDemo("v0.134 Assembly & Refs")
        tapDemo("v0.135 Graph Builder")
    }

    // MARK: - OCCT 8 Demos (Part 7: v0.137–v0.155)

    func testOCCT8DemosPart7() {
        expandGroup("OCCT 8 Features")
        expandGroup("I/O & Assembly")
        tapDemo("v0.137 Revolution Axes")
        tapDemo("v0.137 Drawing Dimensions")
        tapDemo("v0.137 Auto Centrelines")
        tapDemo("v0.138 Thread Features")
        tapDemo("v0.138 DXF Export")
        tapDemo("v0.139 Thread Form v2")
        tapDemo("v0.140 GD&T Write")
        tapDemo("v0.141 Topology Refs")
        tapDemo("v0.142 Construction Geometry")
        tapDemo("v0.142 Sketch + Reconstructor")
        tapDemo("v0.143 Measurements")
        tapDemo("v0.143 Deferrals Cleared")
        tapDemo("v0.144 Section + Hatch")
        tapDemo("v0.145 Sheet Layout")
        tapDemo("v0.146 Annotations")
        tapDemo("v0.147 Consumer Polish")
        tapDemo("v0.148 Drawing.append")
        tapDemo("v0.149 Automation + Tolerance")
        tapDemo("v0.150 PDF/SVG/BOM")
        tapDemo("v0.151 SheetMetal Compose")
        tapDemo("v0.152 inputBody Chain")
        tapDemo("v0.152.1 JSON Boolean")
        tapDemo("v0.153 Step-Aware Bends")
        tapDemo("v0.154 Face/Edge Inits")
        tapDemo("v0.155 Convex Bends")
    }

    // MARK: - OCCT 8 Demos (Part 8: v0.155.1+ — OCCT 8.0.0 beta1)

    func testOCCT8DemosPart8() {
        expandGroup("OCCT 8 Features")
        expandGroup("I/O & Assembly")
        tapDemo("v0.155.1 Wire(Shape)")
        tapDemo("v0.156.1 Document.node(at:)")
        tapDemo("v0.156.2 Mesh from arrays")
        tapDemo("v0.158 MeshView Read")
        tapDemo("v0.160 Triangulation+Cache Write")
        tapDemo("v0.163 ProductOps Assembly")
        tapDemo("v0.164 Cache Inspection")
        tapDemo("v0.168 Import Progress")
        tapDemo("v0.169 Mesh Progress")
        tapDemo("v0.169 Export Progress")
        tapDemo("v1.0 RootNodes & EdgeRegularity")
    }

    // MARK: - Helpers

    /// Expands a disclosure group by tapping its label button, scrolling to find it if needed.
    private func expandGroup(_ label: String) {
        let toggle = app.buttons[label].firstMatch

        if toggle.waitForExistence(timeout: 2) && toggle.isHittable {
            toggle.tap()
            Thread.sleep(forTimeInterval: 0.3)
            return
        }

        // Scroll to find the disclosure group
        for _ in 0..<50 {
            scrollSidebar()
            if toggle.waitForExistence(timeout: 0.5) && toggle.isHittable {
                toggle.tap()
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
        }

        XCTFail("Disclosure group '\(label)' not found after scrolling")
    }

    /// Scrolls the sidebar to find a button, taps it, and verifies the app stays alive.
    private func tapDemo(_ label: String) {
        let button = app.buttons[label].firstMatch

        // If the button is already visible and tappable, use it directly
        if button.waitForExistence(timeout: 2) && button.isHittable {
            button.tap()
            verifyAppAlive(after: label)
            return
        }

        // Scroll down incrementally to find the button
        var found = false
        for _ in 0..<50 {
            scrollSidebar()

            if button.waitForExistence(timeout: 0.5) && button.isHittable {
                found = true
                break
            }
        }

        guard found else {
            XCTFail("Button '\(label)' not found or not hittable after scrolling")
            return
        }

        button.tap()
        verifyAppAlive(after: label)
    }

    private func scrollSidebar() {
        #if os(macOS)
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -100)
        #else
        let sv = sidebarScrollable
        let start = sv.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = sv.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        #endif
    }

    /// Waits briefly for geometry generation / Metal rendering then checks for crash.
    private func verifyAppAlive(after label: String) {
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "App crashed after tapping '\(label)'"
        )
    }

    /// The scrollable container holding the sidebar list.
    private var sidebarScrollable: XCUIElement {
        #if os(macOS)
        // NavigationSplitView sidebar — SwiftUI List renders as an outline view
        return app.outlines.firstMatch
        #else
        return app.collectionViews.firstMatch
        #endif
    }
}
