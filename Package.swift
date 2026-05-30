// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexLocalMeterApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CodexLocalMeterCore", targets: ["CodexLocalMeterCore"]),
        .executable(name: "CodexLocalMeterApp", targets: ["CodexLocalMeterApp"]),
        .executable(name: "CodexLocalMeterCoreTests", targets: ["CodexLocalMeterCoreTests"])
    ],
    targets: [
        .target(name: "CodexLocalMeterCore"),
        .executableTarget(
            name: "CodexLocalMeterApp",
            dependencies: ["CodexLocalMeterCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "CodexLocalMeterCoreTests",
            dependencies: ["CodexLocalMeterCore"]
        ),
        .testTarget(
            name: "CodexLocalMeterSwiftPMTests",
            dependencies: ["CodexLocalMeterCore"],
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        )
    ]
)
