// MemoryManager.swift
// ChappieCore
//
// Central memory manager for the three-level memory system (IT-08).
//
// STORAGE BACKEND: DataStore (via MemoryStore) — single source of truth.
//
// SCOPE RESOLUTION (IT-08):
// ToolExecutionService passes ActiveMemoryContext on each memory tool call.
// resolveScope() maps (scope, targetName) → storage scope string:
//   scope="global"       → "global"
//   scope="thread"       → active thread UUID
//   targetName="Chappie" → project UUID (must be attached to thread)
//
// SYSTEM PROMPT STRUCTURE (IT-09):
// 1. Project Settings (agent rights — injected first)
// 2. Global Memory
// 3. Project Memory (one block per project)
// 4. Thread Context

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

// MARK: - MemoryManager

/// Central memory manager for Chappie.
///
/// Uses `actor` for safe concurrent access (Swift 6): all operations
/// are serialized, preventing data races from parallel tool calls.
public actor MemoryManager {

    // MARK: - Public properties

    public let workspaceURL: URL

    // MARK: - Private properties

    private let fileManager = FileManager.default
    private var targets: [WorkspaceTarget] = []
    private var isInitialized: Bool = false
    private var memoryStore: MemoryStore?

    // MARK: - Init

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - DataStore backend setup

    public func setMemoryStore(_ store: MemoryStore) {
        self.memoryStore = store
        print("[MemoryManager] MemoryStore connected (DataStore backend active)")
    }

    // MARK: - Workspace initialization

    /// Sets up workspace target discovery.
    /// NOTE: architecture.md files are NOT created automatically — only by explicit user agreement.
    public func initializeWorkspaceMemory() async {
        guard !isInitialized else { return }

        print("[MemoryManager] Initializing workspace memory structure...")

        let discovered = discoverTargets()
        self.targets = discovered

        isInitialized = true
        print("[MemoryManager] Initialization complete. Targets: \(targets.count).")
    }

    // MARK: - System prompt assembly (IT-08, IT-09)

    /// Builds the full system prompt with injected memory and project settings.
    ///
    /// Block order (IT-09): Project Settings → Global Memory → Project Memory → Thread Context.
    /// Project Settings is first so the agent knows its rights before reading memory.
    public func buildSystemPrompt(
        basePrompt: String,
        memoryContext: MemoryContext
    ) async -> String {
        guard let store = memoryStore else {
            print("[MemoryManager] MemoryStore not connected, using base prompt only")
            return basePrompt
        }

        var scopes: [String] = ["global"]

        for info in memoryContext.projectInfos {
            scopes.append(info.id.uuidString)
        }

        if let threadId = memoryContext.threadId {
            scopes.append(threadId.uuidString)
        }

        let entriesByScope: [String: [MemoryEntry]]
        do {
            entriesByScope = try await store.readEntriesForScopes(scopes)
        } catch {
            print("[MemoryManager] Error loading memory from MemoryStore: \(error)")
            return basePrompt
        }

        var memoryBlocks: [String] = []

        // Project Settings first — agent must know its rights before seeing memory.
        for info in memoryContext.projectInfos {
            if let settings = info.settings {
                let settingsBlock = settings.formatForSystemPrompt(projectName: info.name)
                memoryBlocks.append(settingsBlock)
            }
        }

        // Global memory block.
        let globalEntries = entriesByScope["global"] ?? []
        if let block = formatEntriesForPrompt(globalEntries, title: "Global Memory") {
            memoryBlocks.append(block)
        }

        // One block per project.
        for info in memoryContext.projectInfos {
            let projectEntries = entriesByScope[info.id.uuidString] ?? []
            guard !projectEntries.isEmpty else { continue }
            if let block = formatEntriesForPrompt(projectEntries, title: "Project Memory: \(info.name)") {
                memoryBlocks.append(block)
            }
        }

        // Thread context.
        if let threadId = memoryContext.threadId {
            let threadEntries = entriesByScope[threadId.uuidString] ?? []
            if !threadEntries.isEmpty {
                if let block = formatEntriesForPrompt(threadEntries, title: "Thread Context") {
                    memoryBlocks.append(block)
                }
            }
        }

        guard !memoryBlocks.isEmpty else {
            return basePrompt
        }

        let memorySectionHeader = "---\n## Memory Context"
        let memorySection = ([memorySectionHeader] + memoryBlocks).joined(separator: "\n\n")

        return basePrompt + "\n\n" + memorySection
    }

    // MARK: - Legacy buildSystemPrompt overload (IT-08 compat)

    public func buildSystemPrompt(
        basePrompt: String,
        threadId: UUID?,
        projectIds: [UUID]
    ) async -> String {
        let projectInfos = projectIds.map { id in
            MemoryContext.ProjectInfo(id: id, name: id.uuidString)
        }
        let context = MemoryContext(threadId: threadId, projectInfos: projectInfos)
        return await buildSystemPrompt(basePrompt: basePrompt, memoryContext: context)
    }

    // MARK: - Three-level memory CRUD (IT-08)

    public func saveMemoryEntry(key: String, type: String, jsonString: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            return "Memory save error: MemoryStore not connected"
        }
        do {
            try await store.saveEntry(key: key, type: type, jsonString: jsonString, scope: scope)
            return nil
        } catch {
            return "Memory save error: \(error.localizedDescription)"
        }
    }

    public func readMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else { return nil }
        do {
            return try await store.readEntry(key: key, scope: scope)
        } catch {
            print("[MemoryManager] Error reading from MemoryStore: \(error)")
            return nil
        }
    }

    public func searchMemoryEntries(type: String, scope: String) async -> [String: String] {
        guard let store = memoryStore else { return [:] }
        do {
            return try await store.searchEntries(type: type, scope: scope)
        } catch {
            print("[MemoryManager] Error searching MemoryStore: \(error)")
            return [:]
        }
    }

    public func deleteMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            return "Memory delete error: MemoryStore not connected"
        }
        do {
            try await store.deleteEntry(key: key, scope: scope)
            return nil
        } catch {
            return "Memory delete error: \(error.localizedDescription)"
        }
    }

    // MARK: - Public helpers

    public func allTargets() async -> [WorkspaceTarget] {
        await ensureInitialized()
        return targets
    }

    public func primaryAppTarget() async -> WorkspaceTarget? {
        await ensureInitialized()
        return appTarget()
    }

    // MARK: - Private: initialization

    private func ensureInitialized() async {
        guard !isInitialized else { return }
        await initializeWorkspaceMemory()
    }

    private func discoverTargets() -> [WorkspaceTarget] {
        let excludedNames: Set<String> = [
            "build", "DerivedData", "Pods", "Frameworks",
            ".git", ".swiftpm"
        ]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discovered: [WorkspaceTarget] = []

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let name = url.lastPathComponent

            guard !excludedNames.contains(name) else { continue }
            guard !name.hasPrefix(".") else { continue }
            guard url.pathExtension.isEmpty else { continue }

            let kind = classifyTarget(at: url)
            let target = WorkspaceTarget(name: name, directoryURL: url, kind: kind)
            discovered.append(target)
        }

        discovered.sort { lhs, rhs in
            if lhs.kind == .appTarget && rhs.kind != .appTarget { return true }
            if lhs.kind != .appTarget && rhs.kind == .appTarget { return false }
            return lhs.name < rhs.name
        }

        return discovered
    }

    private func classifyTarget(at url: URL) -> TargetKind {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .library
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasSuffix("App.swift") {
                return .appTarget
            }
        }

        return .library
    }

    // MARK: - Private: helpers

    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    /// Formats a list of entries into a titled memory block for the system prompt.
    private func formatEntriesForPrompt(_ entries: [MemoryEntry], title: String) -> String? {
        guard !entries.isEmpty else { return nil }

        var lines = ["## \(title)"]
        for entry in entries {
            let displayValue: String
            if let data = entry.jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json.values.first {
                displayValue = "\(value)"
            } else {
                displayValue = entry.jsonString
            }
            lines.append("- [\(entry.type)] \(entry.key): \(displayValue)")
        }

        return lines.joined(separator: "\n")
    }
}
