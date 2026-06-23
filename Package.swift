// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "VolumeMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VolumeMonitor",
            dependencies: []
        ),
    ],
    swiftLanguageModes: [.v6]
)
