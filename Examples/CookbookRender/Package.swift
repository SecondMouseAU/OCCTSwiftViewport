// swift-tools-version: 6.0
import PackageDescription

// Headless renderer for the OCCTSwift cookbook figures (OCCTSwift #210).
//
// Like MetalDemo, this lives outside the root Viewport manifest to avoid a
// Viewport -> Tools -> Viewport package cycle. It depends on the kernel
// (OCCTSwift), the bridge (OCCTSwiftTools), and Viewport — all via local sibling
// paths so figures render against the working copies. It writes PNGs (via the
// Viewport OffscreenRenderer) into a directory passed as argv[1].
//
// Needs a sibling layout: this checkout named `OCCTSwiftViewport`, next to
// `OCCTSwift` and `OCCTSwiftTools`. The sibling paths are relative to the checkout,
// and SwiftPM keys the Viewport override of Tools' own Viewport dependency on the
// directory name (`name:` does not change that), so it won't resolve from a
// worktree or renamed clone. See Examples/MetalDemo/Package.swift.
let package = Package(
    name: "CookbookRender",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(name: "OCCTSwiftViewport", path: "../.."),
        .package(path: "../../../OCCTSwift"),
        .package(path: "../../../OCCTSwiftTools"),
    ],
    targets: [
        .executableTarget(
            name: "CookbookRender",
            dependencies: [
                .product(name: "OCCTSwiftViewport", package: "OCCTSwiftViewport"),
                .product(name: "OCCTSwiftTools", package: "OCCTSwiftTools"),
                .product(name: "OCCTSwift", package: "OCCTSwift"),
            ],
            path: "Sources/CookbookRender",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
