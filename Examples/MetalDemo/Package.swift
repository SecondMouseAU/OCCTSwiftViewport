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
//
// Checkout directory name: SwiftPM derives a path dependency's identity from its
// directory name, and `name:` below does NOT change that identity (it only lets
// `.product(..., package: "OCCTSwiftViewport")` resolve). So the override above
// only works when this checkout's directory is named `OCCTSwiftViewport`. In a
// worktree or renamed clone, Tools' remote OCCTSwiftViewport is pulled in as a
// second package and resolution fails with "multiple similar targets
// 'OCCTSwiftViewport'". Build the demo from a checkout named OCCTSwiftViewport
// (or a symlink of that name pointing at the worktree).
let package = Package(
    name: "OCCTSwiftMetalDemo",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    dependencies: [
        .package(name: "OCCTSwiftViewport", path: "../.."),
        .package(url: "https://github.com/SecondMouseAU/OCCTSwift.git", from: "1.7.1"),
        .package(url: "https://github.com/SecondMouseAU/OCCTSwiftTools.git", from: "1.1.0"),
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
