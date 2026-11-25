// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TelegramClient",
    platforms: [
        .iOS("26.0"),
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "TelegramClient", targets: ["TelegramClient"])
    ],
    dependencies: [
        .package(name: "MusicCore", path: "../MusicCore"),
        .package(
            url: "https://github.com/Swiftgram/TDLibFramework",
            exact: "1.8.70-61f1d106"
        )
    ],
    targets: [
        .target(
            name: "TelegramClient",
            dependencies: [
                .product(name: "MusicCore", package: "MusicCore"),
                .product(name: "TDLibFramework", package: "TDLibFramework")
            ]
        ),
        .testTarget(
            name: "TelegramClientTests",
            dependencies: ["TelegramClient", "MusicCore"]
        )
    ]
)
