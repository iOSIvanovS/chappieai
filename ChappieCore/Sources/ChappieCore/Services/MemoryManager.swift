// MemoryManager.swift
// ChappieCore
//
// Central memory manager for the three-level memory system (IT-08).
//
// STORAGE BACKEND:
// - DataStore (via MemoryStore) — primary backend for all memory operations.
// - ~/Documents/Chappie/semantic.json — legacy file (migration/fallback only).
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

// MARK: - Legacy models (file backend only)

/// Memory record for legacy JSON file backend.
public struct MemoryRecord: Codable, Sendable {
    public let type: String
    public let timestamp: Date
    public let data: String

    public init(type: String, timestamp: Date = Date(), data: String) {
        self.type = type
        self.timestamp = timestamp
        self.data = data
    }
}

/// Legacy scope enum — used only in old public API.
public enum MemoryScope: String, Codable, Sendable {
    case project
    case global
}

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
/// Uses `actor` for safe concurrent access (Swift 6): all file system operations
/// are serialized, preventing data races from parallel tool calls.
public actor MemoryManager {

    // MARK: - Public properties

    public let workspaceURL: URL

    // MARK: - Private properties

    private let fileManager = FileManager.default
    private var targets: [WorkspaceTarget] = []
    private var isInitialized: Bool = false
    private var memoryStore: MemoryStore?

    private var globalFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Chappie/semantic.json")
    }

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

    /// Sets up file structure for the workspace memory.
    /// NOTE: architecture.md files are NOT created automatically — only by explicit user agreement.
    public func initializeWorkspaceMemory() async {
        guard !isInitialized else { return }

        print("[MemoryManager] Initializing workspace memory structure...")

        setupGlobalMemory()

        let discovered = discoverTargets()
        self.targets = discovered

        cleanupLegacyFiles()

        isInitialized = true
        print("[MemoryManager] Initialization complete. Targets: \(targets.count). Memory: ~/Documents/Chappie/semantic.json")
    }

    // MARK: - System prompt assembly (IT-08, IT-09)

    /// Builds the full system prompt with injected memory and project settings.
    ///
    /// Block order (IT-09): Project Settings → Global Memory → Project Memory → Thread Context.
    /// Project Settings is first so the agent knows its rights before reading memory.
    ///
    /// Falls back to base prompt only if MemoryStore is not connected.
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

        // Global memory: merge DataStore + legacy file (DataStore wins on key conflict).
        let globalDataStoreEntries = entriesByScope["global"] ?? []
        let legacyEntries = loadLegacyMemoryForPrompt()
        let globalBlock = buildMemoryBlock(
            title: "Global Memory",
            primaryEntries: globalDataStoreEntries,
            legacyEntries: legacyEntries
        )
        if let block = globalBlock {
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

    // MARK: - Three-level memory CRUD (IT-08, primary path)

    public func saveMemoryEntry(key: String, type: String, jsonString: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
            print("[MemoryManager] MemoryStore unavailable, saved to legacy file")
            return nil
        }

        do {
            try await store.saveEntry(key: key, type: type, jsonString: jsonString, scope: scope)
            return nil
        } catch {
            return "Memory save error: \(error.localizedDescription)"
        }
    }

    public func readMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            let storage = readStorage(at: globalFileURL)
            return storage[key]?.data
        }

        do {
            return try await store.readEntry(key: key, scope: scope)
        } catch {
            print("[MemoryManager] Error reading from MemoryStore: \(error)")
            return nil
        }
    }

    public func searchMemoryEntries(type: String, scope: String) async -> [String: String] {
        guard let store = memoryStore else {
            let storage = readStorage(at: globalFileURL)
            var results: [String: String] = [:]
            for (k, v) in storage where v.type == type {
                results[k] = v.data
            }
            return results
        }

        do {
            return try await store.searchEntries(type: type, scope: scope)
        } catch {
            print("[MemoryManager] Error searching MemoryStore: \(error)")
            return [:]
        }
    }

    public func deleteMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            var storage = readStorage(at: globalFileURL)
            storage.removeValue(forKey: key)
            writeStorage(storage, to: globalFileURL)
            return nil
        }

        do {
            try await store.deleteEntry(key: key, scope: scope)
            return nil
        } catch {
            return "Memory delete error: \(error.localizedDescription)"
        }
    }

    // MARK: - Legacy public API (file backend)

    public func saveMemory(key: String, type: String, jsonString: String, scope: MemoryScope = .project, targetName: String? = nil) async {
        await ensureInitialized()
        writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
    }

    public func readMemory(key: String, targetName: String? = nil) async -> String? {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        return storage[key]?.data
    }

    public func searchMemory(type: String, targetName: String? = nil) async -> [String: String] {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        var results: [String: String] = [:]
        for (k, v) in storage where v.type == type {
            results[k] = v.data
        }
        return results
    }

    public func deleteMemory(key: String, targetName: String? = nil) async {
        await ensureInitialized()
        var storage = readStorage(at: globalFileURL)
        if storage.keys.contains(key) {
            storage.removeValue(forKey: key)
            writeStorage(storage, to: globalFileURL)
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

    private func setupGlobalMemory() {
        let globalDir = globalFileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: globalDir.path) {
            try? fileManager.createDirectory(at: globalDir, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: globalFileURL.path) {
            try? "{}".write(to: globalFileURL, atomically: true, encoding: .utf8)
        }
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

    private func cleanupLegacyFiles() {
        for target in targets {
            let legacyAIDocsURL = target.directoryURL.appendingPathComponent("AI_Docs")
            if fileManager.fileExists(atPath: legacyAIDocsURL.path) {
                let legacySemanticURL = legacyAIDocsURL.appendingPathComponent("semantic.json")
                if fileManager.fileExists(atPath: legacySemanticURL.path) {
                    migrateSemanticFile(from: legacySemanticURL, label: "\(target.name)/AI_Docs/semantic.json")
                }
                do {
                    try fileManager.removeItem(at: legacyAIDocsURL)
                    print("[MemoryManager] Removed legacy folder: \(target.name)/AI_Docs/")
                } catch {
                    print("[MemoryManager] Failed to remove \(target.name)/AI_Docs/: \(error)")
                }
            }

            let targetSemanticURL = target.directoryURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: targetSemanticURL.path) {
                migrateSemanticFile(from: targetSemanticURL, label: "\(target.name)/semantic.json")
                do {
                    try fileManager.removeItem(at: targetSemanticURL)
                    print("[MemoryManager] Removed legacy file: \(target.name)/semantic.json")
                } catch {
                    print("[MemoryManager] Failed to remove \(target.name)/semantic.json: \(error)")
                }
            }
        }

        let rootAIDocsURL = workspaceURL.appendingPathComponent("AI_Docs")
        if fileManager.fileExists(atPath: rootAIDocsURL.path) {
            let legacySemanticURL = rootAIDocsURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: legacySemanticURL.path) {
                migrateSemanticFile(from: legacySemanticURL, label: "root/AI_Docs/semantic.json")
            }
            let chatHistoryURL = rootAIDocsURL.appendingPathComponent("chat_history.json")
            if !fileManager.fileExists(atPath: chatHistoryURL.path) {
                do {
                    try fileManager.removeItem(at: rootAIDocsURL)
                    print("[MemoryManager] Removed root legacy folder AI_Docs/")
                } catch {
                    print("[MemoryManager] Failed to remove root AI_Docs/: \(error)")
                }
            }
        }
    }

    private func migrateSemanticFile(from sourceURL: URL, label: String) {
        let oldStorage = readStorage(at: sourceURL)
        guard !oldStorage.isEmpty else { return }

        var globalStorage = readStorage(at: globalFileURL)
        var migratedCount = 0
        for (key, record) in oldStorage where globalStorage[key] == nil {
            globalStorage[key] = record
            migratedCount += 1
        }
        if migratedCount > 0 {
            writeStorage(globalStorage, to: globalFileURL)
            print("[MemoryManager] Migrated \(migratedCount) entries from \(label)")
        }
    }

    // MARK: - Private: helpers

    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    private func loadLegacyMemoryForPrompt() -> [MemoryEntry] {
        let storage = readStorage(at: globalFileURL)
        guard !storage.isEmpty else { return [] }
        return storage.map { key, record in
            MemoryEntry(key: key, type: record.type, jsonString: record.data)
        }
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

    /// Merges DataStore and legacy entries into a formatted memory block.
    /// DataStore wins on key conflict (deduplication).
    private func buildMemoryBlock(
        title: String,
        primaryEntries: [MemoryEntry],
        legacyEntries: [MemoryEntry]
    ) -> String? {
        var mergedByKey: [String: MemoryEntry] = [:]

        for entry in legacyEntries {
            mergedByKey[entry.key] = entry
        }
        // DataStore entries overwrite legacy on conflict.
        for entry in primaryEntries {
            mergedByKey[entry.key] = entry
        }

        guard !mergedByKey.isEmpty else { return nil }

        let sorted = mergedByKey.values.sorted { $0.key < $1.key }
        return formatEntriesForPrompt(sorted, title: title)
    }

    // MARK: - Private: low-level file operations (legacy backend)

    private func readStorage(at url: URL) -> [String: MemoryRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let storage = try? decoder.decode([String: MemoryRecord].self, from: data) else {
            return [:]
        }
        return storage
    }

    private func writeStorage(_ storage: [String: MemoryRecord], to url: URL) {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(storage) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writeRecord(key: String, type: String, data: String, to url: URL) {
        var storage = readStorage(at: url)
        storage[key] = MemoryRecord(type: type, data: data)
        writeStorage(storage, to: url)
    }
}
