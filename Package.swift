// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TriBoost",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TriBoost", targets: ["TriBoost"]),
        .library(name: "TriBoostCore", targets: ["TriBoostCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Kyome22/OpenMultitouchSupport.git", from: "4.0.0"),
    ],
    targets: [
        // Pure logic: no AppKit, no private frameworks, no I/O. Fully unit-testable.
        .target(name: "TriBoostCore"),

        // The menu bar app: wires the trackpad, Chrome and the keyboard to TriBoostCore.
        .executableTarget(
            name: "TriBoost",
            dependencies: [
                "TriBoostCore",
                .product(name: "OpenMultitouchSupport", package: "OpenMultitouchSupport"),
            ]
        ),

        .testTarget(name: "TriBoostCoreTests", dependencies: ["TriBoostCore"]),
    ]
)
