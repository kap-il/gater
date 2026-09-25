// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Gater",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "GaterCore", targets: ["GaterCore"]),
        .executable(name: "gater-hook", targets: ["gater-hook"])
    ],
    targets: [
        .target(
            name: "GaterCore",
            path: "Sources/GaterCore"
        ),
        .executableTarget(
            name: "gater-hook",
            dependencies: ["GaterCore"],
            path: "Sources/gater-hook"
        ),
        .testTarget(
            name: "GaterCoreTests",
            dependencies: ["GaterCore"],
            path: "Tests/GaterCoreTests"
        )
    ]
)

// The terminal is macOS-only: it needs libghostty-vt (built by
// scripts/build-ghostty.sh). Keeping them out of the Linux graph
// preserves the spec's "GaterCore builds and tests on Linux" split.
#if os(macOS)
package.targets += [
    .binaryTarget(
        name: "GhosttyVT",
        path: "Vendor/ghostty/GhosttyVT.xcframework"
    ),
    .target(
        name: "GaterPTY",
        path: "Sources/GaterPTY"
    ),
    .target(
        name: "GaterTerminal",
        dependencies: ["GhosttyVT", "GaterPTY"],
        path: "Sources/GaterTerminal"
    ),
    .testTarget(
        name: "GaterTerminalTests",
        dependencies: ["GaterTerminal"],
        path: "Tests/GaterTerminalTests"
    )
]
#endif
