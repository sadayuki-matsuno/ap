// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ap", targets: ["ap"]),
        .executable(name: "ApApp", targets: ["ApApp"]),
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
        // NSPasteboard writes shared by the CLI and the app (ApCore stays AppKit-free)
        .target(name: "ApClipboard", dependencies: ["ApCore"]),
        .executableTarget(
            name: "ap",
            dependencies: [
                "ApCore",
                "ApClipboard",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The menu bar app, bundled into build/Ap.app by `make app`
        .executableTarget(
            name: "ApApp",
            dependencies: ["ApCore", "ApClipboard", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "ApCoreTests",
            dependencies: ["ApCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
