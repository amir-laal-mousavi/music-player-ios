// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusicCore",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "MusicCore", targets: ["MusicCore"])
    ],
    targets: [
        .target(name: "MusicCore"),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"])
    ]
)
