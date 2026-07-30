// swift-tools-version: 6.3

import PackageDescription

private let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .strictMemorySafety(),
]

let package = Package(
    name: "Translator",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "Translator",
            targets: ["Translator"]
        ),
    ],
    targets: [
        .target(
            name: "Translator",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "TranslatorTests",
            dependencies: ["Translator"],
            swiftSettings: strictSwiftSettings
        ),
    ]
)
