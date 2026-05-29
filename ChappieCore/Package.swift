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
        // SwiftData and @Observable are both available since macOS 14.
        // swift-tools-version 6.0 supports macOS 14 as deployment target.
        .macOS(.v14)
    ],
    products: [
        // Library exported as dynamic/static (Xcode decides)
        .library(
            name: "ChappieCore",
            targets: ["ChappieCore"]
        ),
    ],
    targets: [
        // Main target with source code
        .target(
            name: "ChappieCore"
        ),
        // TEST TARGET INTENTIONALLY REMOVED.
        // All tests live in ChappieCoreTests/ and are managed via Xcode Test Plan.
        // See ChappieCoreTests.xctestplan in the project root.
    ],
    swiftLanguageModes: [.v6]
)
