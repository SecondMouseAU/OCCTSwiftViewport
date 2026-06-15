// swift-tools-version: 6.0
import PackageDescription

// Standalone package for the interactive Metal demo.
//
// This lives outside the root OCCTSwiftViewport package on purpose: the demo
// uses both the kernel (OCCTSwift) and the bridge layer (OCCTSwiftTools), and
// OCCTSwiftTools depends back on OCCTSwiftViewport. If the demo target were
// declared in the root manifest, that manifest would gain an upward dependency
// on Tools and form a Viewport -> Tools -> Viewport package cycle.
//
// The Viewport dependency is taken via `path: "../.."`, so SwiftPM resolves
// the demo against this working copy of Viewport and uses it to satisfy Tools'
// own versioned dependency on OCCTSwiftViewport (local path overrides win by
// package identity). No cycle, no stale tagged copy of Viewport pulled in.
let package = Package(
    name: "OCCTSwiftMetalDemo",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/gsdali/OCCTSwift.git", from: "1.5.0"),
        .package(url: "https://github.com/gsdali/OCCTSwiftTools.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "OCCTSwiftMetalDemo",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/OCCTSwiftMetalDemo",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
