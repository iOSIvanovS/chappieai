// New+Entities.swift
// ChappieCore
//
// V2 namespace aliases for SwiftData entities and domain models.
// These are NOT new types — they are named access points under the New namespace
// so V2 code can reference them cleanly without colliding with old names.
//
// When old code is removed, these aliases become the canonical names
// and can be dissolved: replace `New.ThreadEntity` → `ThreadEntity` everywhere.

import Foundation

public extension New {

    // MARK: - SwiftData Entities

    /// V2 alias for ThreadEntity.
    /// Points to the same SwiftData @Model — no migration needed.
    typealias ThreadEntity = ChappieCore.ThreadEntity

    /// V2 alias for ProjectEntity.
    typealias ProjectEntity = ChappieCore.ProjectEntity

    /// V2 alias for AIProviderEntity.
    typealias ProviderEntity = ChappieCore.AIProviderEntity

    /// V2 alias for MemoryEntry.
    typealias MemoryEntry = ChappieCore.MemoryEntry

    // MARK: - Domain Models

    /// V2 alias for ThreadSettings.
    typealias ThreadSettings = ChappieCore.ThreadSettings

    /// V2 alias for ThreadMetadata.
    typealias ThreadMetadata = ChappieCore.ThreadMetadata

    /// V2 alias for ProjectSettings.
    typealias ProjectSettings = ChappieCore.ProjectSettings

    /// V2 alias for AIProvider.
    typealias Provider = ChappieCore.AIProvider
}
