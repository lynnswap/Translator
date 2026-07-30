// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "TranslatorConsumerFixture",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "TranslatorConsumerFixture",
            dependencies: [
                .product(name: "Translator", package: "translator"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(nil),
                .strictMemorySafety(),
            ]
        ),
    ]
)
