// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "G8r",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "G8rCore", targets: ["G8rCore"]),
        .library(name: "G8rSymbols", targets: ["G8rSymbols"]),
        .executable(name: "g8r-hook", targets: ["g8r-hook"])
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.9.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "G8rCore",
            path: "Sources/G8rCore"
        ),
        .executableTarget(
            name: "g8r-hook",
            dependencies: ["G8rCore"],
            path: "Sources/g8r-hook"
        ),
        .testTarget(
            name: "G8rCoreTests",
            dependencies: ["G8rCore"],
            path: "Tests/G8rCoreTests"
        ),
        // tree-sitter symbol engine. Separate from G8rCore so the core
        // stays dependency-free.
        .target(
            name: "G8rSymbols",
            dependencies: [
                "G8rCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
            ],
            path: "Sources/G8rSymbols"
        ),
        .testTarget(
            name: "G8rSymbolsTests",
            dependencies: ["G8rSymbols"],
            path: "Tests/G8rSymbolsTests"
        )
    ]
)

// The terminal and app are macOS-only: they need libghostty-vt (built by
// scripts/build-ghostty.sh) and AppKit. Keeping them out of the Linux graph
// lets G8rCore build and test on Linux.
#if os(macOS)
package.products += [
    .executable(name: "G8r", targets: ["G8r"])
]
package.targets += [
    .binaryTarget(
        name: "GhosttyVT",
        path: "Vendor/ghostty/GhosttyVT.xcframework"
    ),
    .target(
        name: "G8rPTY",
        path: "Sources/G8rPTY"
    ),
    .target(
        name: "G8rTerminal",
        dependencies: ["GhosttyVT", "G8rPTY"],
        path: "Sources/G8rTerminal"
    ),
    .executableTarget(
        name: "G8r",
        dependencies: ["G8rCore", "G8rTerminal"],
        path: "App"
    ),
    .testTarget(
        name: "G8rTerminalTests",
        dependencies: ["G8rTerminal"],
        path: "Tests/G8rTerminalTests"
    )
]
#endif
