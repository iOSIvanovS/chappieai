// DevEnvironment.swift
// ChappieMCP
//
// WHY THIS FILE:
// ChappieMCP is a standalone binary — it cannot import ChappieCore.
// This file mirrors DevEnvironment from ChappieCore/Models/ProjectModels.swift.
// Keep rawValues in sync with ChappieCore — they are passed as CLI argument argv[3].
//
// SYNC CONTRACT: if DevEnvironment cases or rawValues change in ChappieCore,
// update this file to match. The two enums must stay identical in rawValues.

import Foundation

/// Development environment. Mirrors ChappieCore.DevEnvironment.
/// Controls which shell commands are used for build_project and run_tests.
enum DevEnvironment: String {
    case unknown         = "unknown"
    case xcode           = "xcode"
    case nodejs          = "nodejs"
    case python          = "python"
    case go              = "go"
    case rust            = "rust"
    case java            = "java"
    case kotlin          = "kotlin"
    case flutter         = "flutter"
    case reacttypescript = "react_typescript"
    case dotnet          = "dotnet"
}
