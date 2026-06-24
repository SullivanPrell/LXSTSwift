// swift-tools-version: 5.9
import PackageDescription
import Foundation

// ReticulumSwift dependency.
//
// Consumers get the published release from GitHub. For developing the whole
// stack from sibling checkouts (ReticulumSwift next to this repo), set
// RETICULUM_LOCAL_DEPS=1 to use the local path instead:
//
//   RETICULUM_LOCAL_DEPS=1 swift test
//
let useLocalDeps = ProcessInfo.processInfo.environment["RETICULUM_LOCAL_DEPS"] != nil
let reticulumDependency: Package.Dependency = useLocalDeps
    ? .package(path: "../ReticulumSwift")
    : .package(url: "https://github.com/SullivanPrell/ReticulumSwift.git", from: "1.0.0")

let package = Package(
    name: "LXSTSwift",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LXST", targets: ["LXST"]),
    ],
    dependencies: [
        reticulumDependency,
    ],
    targets: [
        // Pre-built codec2 XCFramework (arm64-iOS + arm64/x86_64-macOS), committed directly.
        // Built from https://github.com/drowe67/codec2 (LGPL-2.1).
        .binaryTarget(
            name: "CCodec2",
            url: "https://github.com/SullivanPrell/LXSTSwift/releases/download/codec2-1.2.0/codec2.xcframework.zip",
            checksum: "549523cbc4d735221ecdb3fdd00a0af4dbe98c82e7b51ee416bb8e22e3fd73f8"
        ),

        // Pre-built libopus XCFramework (arm64-iOS + arm64/x86_64-macOS), committed directly.
        // Built from https://gitlab.xiph.org/xiph/opus (BSD-3-Clause).
        .binaryTarget(
            name: "COpus",
            url: "https://github.com/SullivanPrell/LXSTSwift/releases/download/opus-v1.6.1/opus.xcframework.zip",
            checksum: "d59291ff428d8aa47cbd2b78b2698b7b91646f91745e39369fbab2e4e3e01086"
        ),

        .target(
            name: "LXST",
            dependencies: [
                .product(name: "ReticulumSwift", package: "ReticulumSwift"),
                "CCodec2",
                "COpus",
            ],
            path: "Sources/LXST"
        ),

        .testTarget(
            name: "LXSTTests",
            dependencies: ["LXST"],
            path: "Tests/LXSTTests"
        ),
    ]
)
