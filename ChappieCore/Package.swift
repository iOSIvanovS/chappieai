// swift-tools-version: 6.0
// Package manifest for ChappieCore.
//
// PACKAGE STRUCTURE:
// - ChappieCore (library target) — core AI assistant business logic
//
// WHY A SEPARATE PACKAGE:
// Splitting UI (Chappie.app) and business logic (ChappieCore) allows:
// 1. Testing logic independently of UI
// 2. Reusing the core in other applications
// 3. Clear separation of layer responsibilities
//
// WHY NO TEST TARGET HERE:
// ChappieCore tests live in the root ChappieCoreTests/ target of Chappie.xcodeproj
// and are run via ChappieCoreTests.xctestplan (Xcode Test Plan).
// This is the single source of truth for tests — duplicating in Package.swift
// led to two unsynchronized test sets, causing confusion.
// Rule: tests are written in ChappieCoreTests/, run through Xcode.

import PackageDescription

let package = Package(
    name: "ChappieCore",
    platforms: [
        // macOS 14 — minimum version to cover last 3 major macOS releases.
        // GRDB 7.x requires macOS 10.13+, so macOS 14 is well within range.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ChappieCore",
            targets: ["ChappieCore"]
        ),
    ],
    dependencies: [
        // GRDB — battle-tested SQLite toolkit. Replaces SwiftData as persistent storage.
        // Chosen over raw SQLite for type-safe queries and migration support.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ChappieCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // TEST TARGET INTENTIONALLY REMOVED.
        // All tests live in ChappieCoreTests/ and are managed via Xcode Test Plan.
        // See ChappieCoreTests.xctestplan in the project root.
    ],
    swiftLanguageModes: [.v6]
)
