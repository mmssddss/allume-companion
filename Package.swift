// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AllumeCompanion",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AllumeCompanion",
            path: "Sources/AllumeCompanion",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
