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
        // `name:` makes the product reference below independent of the checkout's
        // directory name (SwiftPM otherwise names a path dependency after its
        // directory), so this builds from worktrees and renamed clones too.
        .package(name: "OCCTSwiftViewport", path: "../.."),
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
