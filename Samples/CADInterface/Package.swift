// swift-tools-version: 6.0
import PackageDescription

// Compile harness for the CAD interface sample (CADSampleView.swift).
//
// The sample is a SwiftUI view, not an app: drop `CADSampleView()` into a
// `WindowGroup` to run it. This package exists so the sample builds against the
// working copy of the viewport and CI catches API drift
// (`swift build --package-path Samples/CADInterface`, see tests.yml).
// Depends only on the viewport, so it needs no OCCT binary.
let package = Package(
    name: "CADInterfaceSample",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [
        // `name:` keeps the product reference below independent of the checkout's
        // directory name, so this builds from worktrees and renamed clones too.
        .package(name: "OCCTSwiftViewport", path: "../.."),
    ],
    targets: [
        .target(
            name: "CADInterfaceSample",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ],
            path: ".",
            exclude: ["Package.swift"],
            sources: ["CADSampleView.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
