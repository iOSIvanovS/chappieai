// swift-tools-version: 6.0
// Package manifest for ChappieMCPCore — all logic of the ChappieMCP helper process.
//
// WHY A SEPARATE PACKAGE:
// The ChappieMCP executable target is only main.swift (argument parsing, signals, parent watch).
// Everything testable (socket server, process runner, git/build/document/localization tools)
// lives here so a unit-test bundle can `@testable import ChappieMCPCore`; an executable target
// cannot be imported by tests reliably.
//
// WHY NO TEST TARGET HERE:
// Same rule as ChappieCore: tests live in the Xcode project (ChappieMCPTests) and run through
// the Xcode test plan, so there is a single set of tests.

import PackageDescription

let package = Package(
    name: "ChappieMCPCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ChappieMCPCore",
            targets: ["ChappieMCPCore"]
        ),
    ],
    dependencies: [
        // Reads/writes the OOXML/ODT archives in DocumentTools.
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    ],
    targets: [
        .target(
            name: "ChappieMCPCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
