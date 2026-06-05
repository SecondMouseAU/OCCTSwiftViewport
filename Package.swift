// swift-tools-version: 6.0
import PackageDescription

// NOTE: OCCTSwiftViewport is a leaf layer. Its library and test targets depend
// on NO other OCCTSwift package — it renders plain `ViewportBody` arrays and
// knows nothing about the kernel. The interactive demo, which DOES use the
// kernel and OCCTSwiftTools, lives in its own package at Examples/MetalDemo so
// that this published manifest never declares an upward dependency on Tools
// (which depends back on Viewport — a package cycle). See Examples/MetalDemo.
let package = Package(
    name: "OCCTSwiftViewport",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "OCCTSwiftViewport",
            targets: ["OCCTSwiftViewport"]
        ),
    ],
    targets: [
        .target(
            name: "OCCTSwiftViewport",
            path: "Sources/OCCTSwiftViewport",
            resources: [
                .process("Renderer/Shaders.metal")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "OCCTSwiftViewportTests",
            dependencies: ["OCCTSwiftViewport"],
            path: "Tests/OCCTSwiftViewportTests"
        ),
    ]
)
