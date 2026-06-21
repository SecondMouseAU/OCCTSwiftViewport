// swift-tools-version: 6.0
import PackageDescription

// Headless figure renderer for the OCCTSwiftViewport cookbook docs.
//
// Standalone package (like Examples/MetalDemo) so the docs figures are generated
// by the viewport's own OffscreenRenderer — the same path a host app uses for
// thumbnails / exports. Depends ONLY on OCCTSwiftViewport (via path), using the
// built-in ViewportBody primitives, so no kernel/Tools dependency is needed.
//
// Usage:  cd Examples/DocFigures && swift run DocFigures ../../docs/guides/cookbook/images
let package = Package(
    name: "DocFigures",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "DocFigures",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
