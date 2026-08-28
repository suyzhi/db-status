// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMonitor",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.2.4-RELEASE"
        )
    ],
    targets: [
        .target(
            name: "VolumeMonitorAtomics",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "VolumeMonitor",
            dependencies: ["VolumeMonitorAtomics"]
        ),
        .testTarget(
            name: "VolumeMonitorTests",
            dependencies: [
                "VolumeMonitor",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
