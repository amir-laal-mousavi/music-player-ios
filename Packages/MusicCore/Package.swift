// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusicCore",
    products: [
        .library(name: "MusicCore", targets: ["MusicCore"])
    ],
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    targets: [
        .target(name: "MusicCore"),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"])
    ]
)
