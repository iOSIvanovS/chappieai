// ThreadStore.swift
// ChappieCore
//
// Actor for CRUD operations on threads via SwiftData (REFACTOR-THREADS IT-01).
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
// IT-06: Added updateProjectBindings() — atomic replacement of the full project UUID list.
//
// IT-11: ThreadMetadata moved to ThreadModels.swift (with settings field).
// ThreadStore.loadThreads() now deserializes settingsJSON into ThreadMetadata.settings.
//
// CACHING:
// cachedThreads holds the thread list in RAM after first load.
// loadThreads() is served from cache — no SwiftData hit on warm calls.
// loadSettings() / loadMessages() / loadProjectIds() always hit SwiftData —
// they are per-thread reads that happen only when a thread is selected, not in hot loops.
// All writes call refreshCache() to keep the thread list consistent.

import Foundation
import SwiftData

// MARK: - Thread Memory Info

/// Snapshot of a thread's memory footprint — used by MemoryManagementView.
public struct ThreadMemoryInfo: Sendable, Identifiable {
    public var id: UUID { threadId }
    public let threadId: UUID
    public let title: String
    public let messageCount: Int
    /// Total size of messagesJSON in bytes (includes attachments encoded as base64).
    public let sizeBytes: Int

    public var sizeMB: Double { Double(sizeBytes) / 1_048_576 }
}

// MARK: - ThreadStore

/// Actor for managing threads in SwiftData.
///
/// All methods are isolated in the actor — safe concurrent access is guaranteed.
/// UI layer calls methods via await.
public actor ThreadStore {

    // MARK: - Properties

    private let modelContainer: ModelContainer
    private var cachedThreads: [ThreadMetadata]? = nil

    // MARK: - Init

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Context helper

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

    /// Saves the full message history — no trimming, full fidelity always.
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
        else {
            return ThreadSettings()
        }
        return settings
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
        else {
            return []
        }
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

    // MARK: - Memory Management

    /// Returns memory footprint info for all threads — for MemoryManagementView.
    public func loadMemoryInfo() throws -> [ThreadMemoryInfo] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map { entity in
            // Decode message count without loading full objects — count only
            let count: Int
            if !entity.messagesJSON.isEmpty,
               let raw = try? JSONSerialization.jsonObject(with: entity.messagesJSON) as? [Any] {
                count = raw.count
            } else {
                count = 0
            }
            return ThreadMemoryInfo(
                threadId: entity.id,
                title: entity.title,
                messageCount: count,
                sizeBytes: entity.messagesJSON.count
            )
        }
    }

    /// Deletes the N oldest messages from a thread.
    /// Ephemeral messages (terminalConfirmation) are never stored, so no special handling needed.
    public func deleteOldMessages<T: Codable>(
        count: Int,
        fromThreadId threadId: UUID,
        as type: T.Type
    ) throws {
        guard count > 0 else { return }

        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }
        guard !thread.messagesJSON.isEmpty else { return }

        var messages = (try? JSONDecoder().decode([T].self, from: thread.messagesJSON)) ?? []
        guard messages.count > 0 else { return }

        let toDelete = min(count, messages.count)
        messages.removeFirst(toDelete)

        thread.messagesJSON = (try? JSONEncoder().encode(messages)) ?? thread.messagesJSON
        thread.updatedAt = Date()
        try context.save()
        try refreshCache()

        print("[ThreadStore] 🗑 Deleted \(toDelete) old messages from thread \(threadId)")
    }

    // MARK: - Default Provider

    public func loadDefaultProvider() throws -> AIProvider? {
        return nil
    }
}
