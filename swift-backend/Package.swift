// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "swift-backend",
    platforms: [
       .macOS(.v13)
    ],
    dependencies: [
        // 💧 A server-side Swift web framework.
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        // 🗄 An ORM for Swift.
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        // 🪶 SQLite driver for Fluent.
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor")
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor")
            ]
        )
    ]
)
