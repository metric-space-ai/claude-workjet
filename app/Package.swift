// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workjet",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WorkjetCore", linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(
            name: "WorkjetApp",
            dependencies: ["WorkjetCore"]
        ),
        .testTarget(
            name: "WorkjetCoreTests",
            dependencies: ["WorkjetCore"]
        )
    ]
)
