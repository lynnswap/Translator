// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Translator",
    platforms: [
        .iOS(.v18),.macOS(.v15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "Translator",
            targets: ["Translator"]
        ),
        .library(
            name: "TranslatorLanguageStatus",
            targets: ["TranslatorLanguageStatus"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Translator"
        ),
        .target(
            name: "TranslatorLanguageStatus",
            dependencies: ["Translator"]
        ),
        .testTarget(
            name: "TranslatorTests",
            dependencies: ["Translator"]
        ),
        .testTarget(
            name: "TranslatorLanguageStatusTests",
            dependencies: ["TranslatorLanguageStatus"]
        ),
    ]
)
