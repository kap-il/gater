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
