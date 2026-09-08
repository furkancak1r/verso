// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Verso",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VersoCore", targets: ["VersoCore"]),
        .executable(name: "Verso", targets: ["Verso"])
    ],
    targets: [
        .target(
            name: "VersoCore",
            path: "Sources/VersoCore",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "Verso",
            dependencies: ["VersoCore"],
            path: "Sources/Verso",
            swiftSettings: [
                .define("SWIFT_PACKAGE")
            ]
        ),
        .testTarget(
            name: "VersoCoreTests",
            dependencies: ["VersoCore", "Verso"],
            path: "Tests/VersoCoreTests"
        )
    ]
)
