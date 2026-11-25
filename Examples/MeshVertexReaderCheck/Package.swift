// swift-tools-version: 6.0
import PackageDescription

// Tests for the OCCT-free helpers of the Metal demo (`MeshVertexReader`, `GeometryUtils`).
//
// The demo package (Examples/MetalDemo) has no test target and needs the OCCT kernel to build, so
// its pure-viewport helpers are compiled here instead: the two source files are symlinks to the
// demo's own, so the tests run against the code the demo ships. Run `swift test` in this directory.
//
// As with Examples/MetalDemo, the checkout directory must be named `OCCTSwiftViewport` for the
// `path: "../.."` dependency to resolve by package identity.
let package = Package(
    name: "MeshVertexReaderCheck",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    dependencies: [
        .package(name: "OCCTSwiftViewport", path: "../..")
    ],
    targets: [
        .target(
            name: "MeshVertexReaderCheck",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MeshVertexReaderCheckTests",
            dependencies: [
                "MeshVertexReaderCheck",
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ]
        ),
    ]
)
