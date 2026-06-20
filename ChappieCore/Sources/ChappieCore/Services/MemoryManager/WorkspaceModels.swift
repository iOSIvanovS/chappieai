// MemoryModels.swift
// ChappieCore
//
// Value types for workspace target discovery used by MemoryManager.

import Foundation

// MARK: - Workspace target models

public enum TargetKind: Sendable {
    case appTarget
    case library
}

public struct WorkspaceTarget: Sendable {
    public let name: String
    public let directoryURL: URL
    public let kind: TargetKind

    init(name: String, directoryURL: URL, kind: TargetKind) {
        self.name = name
        self.directoryURL = directoryURL
        self.kind = kind
    }
}

public struct TargetScanResult: Sendable {
    public let targetName: String
    public let sourceFiles: [String]
    public let resourceFiles: [String]
    public let otherFiles: [String]

    public var totalCount: Int {
        sourceFiles.count + resourceFiles.count + otherFiles.count
    }
}
