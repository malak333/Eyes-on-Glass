// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EyesOnGlass",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "EyesOnGlass", targets: ["EyesOnGlass"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.19.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/adrgrondin/mlx-swift-lm", branch: "port/gemma-4-model")
    ],
    targets: [
        .executableTarget(
            name: "EyesOnGlass",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MLXVLM", package: "mlx-swift-lm")
            ]
        ),
        .testTarget(
            name: "EyesOnGlassTests",
            dependencies: ["EyesOnGlass"]
        )
    ]
)
