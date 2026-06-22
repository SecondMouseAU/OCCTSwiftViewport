// swift-tools-version: 6.0
import PackageDescription

// Minimal windowed SwiftUI app to verify the LIVE ViewportRenderer (interactive
// MTKView draw loop) renders a `ViewportBody.directMesh(...)` body correctly —
// the one thing the headless tests can't drive. Depends ONLY on the viewport
// (no OCCT), so it builds without the OCCT.xcframework binary artifact.
//
// Run (macOS): cd Examples/DirectMeshLiveDemo && swift run DirectMeshLiveDemo
let package = Package(
    name: "DirectMeshLiveDemo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "DirectMeshLiveDemo",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
