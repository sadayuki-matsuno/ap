// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ap", targets: ["ap"]),
        .library(name: "ApCore", targets: ["ApCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ApCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "ap",
            dependencies: [
                "ApCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "ApCoreTests",
            dependencies: ["ApCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
