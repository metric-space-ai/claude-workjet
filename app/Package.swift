// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workjet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "workjet", targets: ["WorkjetCLI"])
    ],
    targets: [
        .target(name: "WorkjetCore", linkerSettings: [.linkedFramework("Security"), .linkedFramework("LocalAuthentication")]),
        .executableTarget(name: "WorkjetCLI", dependencies: ["WorkjetCore"]),
        .executableTarget(
            name: "WorkjetApp",
            dependencies: ["WorkjetCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "WorkjetCoreTests",
            dependencies: ["WorkjetCore"]
        )
    ]
)
