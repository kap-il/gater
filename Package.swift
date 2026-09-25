// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Gater",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "GaterCore", targets: ["GaterCore"]),
        .library(name: "GaterSymbols", targets: ["GaterSymbols"]),
        .executable(name: "gater-hook", targets: ["gater-hook"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
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
        ),
        // tree-sitter symbol engine (spec §4.6). Separate from GaterCore so
        // the core stays dependency-free.
        .target(
            name: "GaterSymbols",
            dependencies: [
                "GaterCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            ],
            path: "Sources/GaterSymbols"
        ),
        .testTarget(
            name: "GaterSymbolsTests",
            dependencies: ["GaterSymbols"],
            path: "Tests/GaterSymbolsTests"
        )
    ]
)

// The terminal and app are macOS-only: they need libghostty-vt (built by
// scripts/build-ghostty.sh) and AppKit. Keeping them out of the Linux graph
// preserves the spec's "GaterCore builds and tests on Linux" split.
#if os(macOS)
package.products += [
    .executable(name: "Gater", targets: ["Gater"])
]
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
    .executableTarget(
        name: "Gater",
        dependencies: ["GaterCore", "GaterTerminal", "GaterSymbols"],
        path: "App"
    ),
    .testTarget(
        name: "GaterTerminalTests",
        dependencies: ["GaterTerminal"],
        path: "Tests/GaterTerminalTests"
    )
]
#endif
