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
            checksum: "d140123600b34d160fa0fb54b37b99afaa5a6c5ca020580f8df3fd9a7e53d4ca"
        ),

        // Pre-built libopus XCFramework (arm64-iOS + arm64/x86_64-macOS), committed directly.
        // Built from https://gitlab.xiph.org/xiph/opus (BSD-3-Clause).
        .binaryTarget(
            name: "COpus",
            url: "https://github.com/SullivanPrell/LXSTSwift/releases/download/opus-v1.6.1/opus.xcframework.zip",
            checksum: "7028d8c194f07430f406bcb3495965efd641432501c47c8b3aa94697e6b69b9d"
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
