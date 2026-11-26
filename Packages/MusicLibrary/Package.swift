// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MusicLibrary",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "MusicLibrary", targets: ["MusicLibrary"])
    ],
    dependencies: [
        .package(path: "../MusicCore")
    ],
    targets: [
        .target(
            name: "MusicLibrary",
            dependencies: [.product(name: "MusicCore", package: "MusicCore")]
        ),
        .testTarget(
            name: "MusicLibraryTests",
            dependencies: [
                "MusicLibrary",
                .product(name: "MusicCore", package: "MusicCore")
            ]
        )
    ]
)
