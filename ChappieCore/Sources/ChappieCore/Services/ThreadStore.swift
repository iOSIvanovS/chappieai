// ThreadStore.swift
// ChappieCore
//
// Actor for CRUD operations on threads via SwiftData.
//
// WHY ACTOR, NOT CLASS:
// ThreadStore works with ModelContext — an object that is NOT Sendable
// and must be used strictly on one thread. An Actor in Swift 6 guarantees
// sequential access to its state — ideal for a thread-safe wrapper over SwiftData.
//
// WHY BACKGROUND CONTEXT:
// mainContext is isolated on @MainActor — it cannot be used from our actor
// without violating Swift 6 Concurrency rules. Instead we create a background context
// via ModelContext(modelContainer) — not bound to a specific thread,
// safe to use inside an actor.
//
// INTERACTION ARCHITECTURE:
// UI layer (ChappieViewModel) → ThreadStore (actor) → SwiftData (ModelContext)
//
// GENERIC APPROACH FOR MESSAGES:
// ChatMessage is defined in Chappie (UI target). ChappieCore must not depend on it.
// saveMessages/loadMessages use Generic <T: Codable> — same as ChatHistoryManager.
// UI layer passes the concrete type; ChappieCore just serializes.
//
// FULL HISTORY STORAGE:
// saveMessages() stores the complete message history without any trimming.
// Users manage their thread history via the Memory Management screen in Settings.

import Foundation
import SwiftData

// MARK: - ThreadStore

public actor ThreadStore {

    private let modelContainer: ModelContainer
    private var cachedThreads: [ThreadMetadata]? = nil

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Cache Management

    private func refreshCache() throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        cachedThreads = try context.fetch(descriptor).map { ThreadMetadata(from: $0) }
    }

    // MARK: - Create

    public func createThread(
        title: String,
        settings: ThreadSettings = ThreadSettings()
    ) throws -> UUID {
        let context = makeContext()
        let thread = ThreadEntity(title: title, settings: settings)
        context.insert(thread)
        try context.save()
        try refreshCache()
        print("[ThreadStore] ✅ Created thread '\(title)' (id: \(thread.id))")
        return thread.id
    }

    // MARK: - Load

    public func loadThreads() throws -> [ThreadMetadata] {
        if let cached = cachedThreads { return cached }
        try refreshCache()
        return cachedThreads ?? []
    }

    // MARK: - Save/Load Messages (Generic)

    /// Saves the complete thread message history without any trimming.
    /// Full history is always preserved — users manage storage via Settings > Memory.
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            print("[ThreadStore] ⚠️ Thread \(threadId) not found when saving messages")
            return
        }

        thread.messagesJSON = try JSONEncoder().encode(messages)
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
    }

    public func loadMessages<T: Codable>(fromThreadId threadId: UUID, as type: T.Type) throws -> [T] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return [] }
        guard !thread.messagesJSON.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([T].self, from: thread.messagesJSON)
        } catch {
            print("[ThreadStore] ⚠️ Failed to deserialize messages for thread \(threadId): \(error)")
            return []
        }
    }

    // MARK: - Settings

    public func updateSettings(_ settings: ThreadSettings, forThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }
        thread.settingsJSON = (try? JSONEncoder().encode(settings)) ?? thread.settingsJSON
        try context.save()
        try refreshCache()
    }

    public func loadSettings(forThreadId threadId: UUID) throws -> ThreadSettings {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first,
              !thread.settingsJSON.isEmpty,
              let settings = try? JSONDecoder().decode(ThreadSettings.self, from: thread.settingsJSON)
        else { return ThreadSettings() }
        return settings
    }

    // MARK: - Message Count & Size (for Memory Management UI)

    /// Returns message count and raw JSON size in bytes for a thread.
    public func messageStats(forThreadId threadId: UUID) throws -> (count: Int, bytes: Int) {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return (0, 0) }
        let bytes = thread.messagesJSON.count
        // Count messages by decoding as raw JSON array — avoids dependency on ChatMessage type.
        let count = (try? JSONDecoder().decode([AnyDecodable].self, from: thread.messagesJSON))?.count ?? 0
        return (count, bytes)
    }

    /// Deletes the oldest N messages from a thread.
    public func deleteOldestMessages(count: Int, fromThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first,
              !thread.messagesJSON.isEmpty else { return }

        guard var rawArray = try? JSONDecoder().decode([AnyDecodable].self, from: thread.messagesJSON),
              rawArray.count > count else {
            // If count >= total messages — clear all
            thread.messagesJSON = "[]".data(using: .utf8) ?? Data()
            thread.updatedAt = Date()
            try context.save()
            try refreshCache()
            return
        }

        rawArray.removeFirst(count)
        thread.messagesJSON = (try? JSONEncoder().encode(rawArray)) ?? thread.messagesJSON
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
        print("[ThreadStore] 🗑 Deleted \(count) oldest messages from thread \(threadId)")
    }

    // MARK: - Project Bindings

    public func loadProjectIds(forThreadId threadId: UUID) throws -> [UUID] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first,
              !thread.projectBindingsJSON.isEmpty,
              let ids = try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)
        else { return [] }
        return ids
    }

    public func updateProjectBindings(_ projectIds: [UUID], forThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            print("[ThreadStore] ⚠️ Thread \(threadId) not found when updating project bindings")
            return
        }
        thread.projectBindingsJSON = (try? JSONEncoder().encode(projectIds)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
        print("[ThreadStore] ✅ Updated project bindings for thread '\(thread.title)': \(projectIds.count) projects")
    }

    public func addProject(id projectId: UUID, toThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        var ids: [UUID] = []
        if !thread.projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)) ?? []
        }

        guard !ids.contains(projectId) else {
            print("[ThreadStore] ℹ️ Project \(projectId) already in thread '\(thread.title)'")
            return
        }

        ids.append(projectId)
        thread.projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) added to thread '\(thread.title)'")
    }

    public func removeProject(id projectId: UUID, fromThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        var ids: [UUID] = []
        if !thread.projectBindingsJSON.isEmpty {
            ids = (try? JSONDecoder().decode([UUID].self, from: thread.projectBindingsJSON)) ?? []
        }

        let countBefore = ids.count
        ids.removeAll { $0 == projectId }

        guard ids.count < countBefore else {
            print("[ThreadStore] ℹ️ Project \(projectId) not found in thread '\(thread.title)'")
            return
        }

        thread.projectBindingsJSON = (try? JSONEncoder().encode(ids)) ?? thread.projectBindingsJSON
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) removed from thread '\(thread.title)'")
    }

    // MARK: - Rename

    public func renameThread(id threadId: UUID, title: String) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }
        thread.title = title
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()
    }

    // MARK: - Delete

    public func deleteThread(id threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }
        let title = thread.title
        context.delete(thread)
        try context.save()
        try refreshCache()
        print("[ThreadStore] 🗑 Thread '\(title)' deleted")
    }

    public func loadDefaultProvider() throws -> AIProvider? { return nil }
}

// MARK: - AnyDecodable (internal helper for raw JSON array operations)

/// Minimal Codable wrapper for working with JSON arrays without knowing the element type.
/// Used by messageStats() and deleteOldestMessages() to count/trim messages
/// without depending on the ChatMessage type (which lives in the UI target).
private struct AnyDecodable: Codable {
    private let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else {
            value = "unknown"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: AnyCodable] {
            try container.encode(dict)
        } else {
            try container.encode("unknown")
        }
    }
}

private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) { value = str }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let bool = try? container.decode(Bool.self) { value = bool }
        else if let double = try? container.decode(Double.self) { value = double }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String { try container.encode(str) }
        else if let int = value as? Int { try container.encode(int) }
        else if let bool = value as? Bool { try container.encode(bool) }
        else if let double = value as? Double { try container.encode(double) }
        else { try container.encode("") }
    }
}
