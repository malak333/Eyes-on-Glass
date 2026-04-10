// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EyesOnGlass",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "EyesOnGlass"
        ),
        .testTarget(
            name: "EyesOnGlassTests",
            dependencies: ["EyesOnGlass"]
        ),
    ]
)
