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
    var memoryStore: MemoryStore?

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

    func ensureInitialized() async {
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

    // MARK: - Private helpers

    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }
}
