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

// MARK: - ThreadStore

/// Actor for managing threads in SwiftData.
///
/// All methods are isolated in the actor — safe concurrent access is guaranteed.
/// UI layer calls methods via await.
public actor ThreadStore {

    // MARK: - Properties

    /// SwiftData model container — stored for creating contexts.
    ///
    /// WHY CONTAINER, NOT CONTEXT:
    /// ModelContext is not Sendable and cannot be passed between actors.
    /// ModelContainer is Sendable — safe to store in an actor.
    /// Context is created inside the actor per operation via ModelContext(container).
    private let modelContainer: ModelContainer

    // In-memory cache of the thread list — populated on first loadThreads(), invalidated on writes.
    // loadSettings/loadMessages/loadProjectIds are NOT cached: they are per-thread,
    // called only on thread selection, and their data changes frequently (messages).
    private var cachedThreads: [ThreadMetadata]? = nil

    // MARK: - Init

    /// Creates a ThreadStore with the given ModelContainer.
    ///
    /// - Parameter modelContainer: SwiftData container (created in ChappieApp.swift)
    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Context helper

    /// Creates a new ModelContext for operations inside the actor.
    ///
    /// WHY CREATE EACH TIME:
    /// ModelContext is not Sendable — cannot be stored as an actor property
    /// and passed between tasks. Creating a new context per operation
    /// is standard practice for background SwiftData work.
    /// ModelContainer manages synchronization between contexts automatically.
    private func makeContext() -> ModelContext {
        ModelContext(modelContainer)
    }

    // MARK: - Cache Management

    /// Reloads the thread list from SwiftData into cachedThreads.
    private func refreshCache() throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        cachedThreads = try context.fetch(descriptor).map { ThreadMetadata(from: $0) }
    }

    // MARK: - Create

    /// Creates a new thread and saves it to the database.
    ///
    /// - Parameters:
    ///   - title: Thread title (usually the first words of the first message)
    ///   - settings: Thread settings (defaults if not provided)
    /// - Returns: UUID of the created thread
    /// - Throws: SwiftData error if save failed
    ///
    /// WHY RETURN UUID, NOT ThreadEntity:
    /// ThreadEntity is a SwiftData @Model object bound to a specific ModelContext.
    /// Passing it outside the actor is unsafe in Swift 6. Return UUID instead —
    /// caller can load thread metadata via loadThreads().
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

    /// Loads metadata for all threads, sorted by last update time (newest first).
    /// Served from in-memory cache — no SwiftData hit on warm calls.
    ///
    /// RETURNS VALUE TYPE:
    /// Returns ThreadMetadata (struct) — safe Sendable type.
    /// Passing @Model objects outside the actor is unsafe in Swift 6.
    ///
    /// IT-11: ThreadMetadata now includes settings field.
    /// Settings are deserialized from settingsJSON here — no extra call needed in UI.
    ///
    /// - Returns: Array of thread metadata sorted by updatedAt DESC
    /// - Throws: SwiftData error if fetch failed
    public func loadThreads() throws -> [ThreadMetadata] {
        if let cached = cachedThreads { return cached }
        try refreshCache()
        return cachedThreads ?? []
    }

    // MARK: - Save/Load Messages (Generic)

    /// Saves the thread message history.
    ///
    /// GENERIC T: Codable — same as ChatHistoryManager.saveMessages<T: Codable>().
    /// ChappieCore doesn't know about ChatMessage (UI type), so accepts any Codable.
    /// UI layer passes [ChatMessage]; ChappieCore just serializes.
    ///
    /// LIMIT: Saves the last 100 messages (same as old ChatHistoryManager).
    ///
    /// - Parameters:
    ///   - messages: Array of messages to save (any Codable type)
    ///   - threadId: UUID of the thread to save to
    /// - Throws: SwiftData or JSONEncoder error if save failed
    public func saveMessages<T: Codable>(_ messages: [T], toThreadId threadId: UUID) throws {
        let context = makeContext()

        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            print("[ThreadStore] ⚠️ Thread \(threadId) not found when saving messages")
            return
        }

        // Trim to 100 messages — UI stores no more
        let maxStored = 100
        let trimmed = messages.count > maxStored
            ? Array(messages.suffix(maxStored))
            : messages

        if messages.count > maxStored {
            print("[ThreadStore] ✂️ Trimmed: \(messages.count - maxStored) old messages removed")
        }

        thread.messagesJSON = try JSONEncoder().encode(trimmed)
        thread.updatedAt = Date()
        try context.save()

        // Invalidate thread list cache — updatedAt changed, sort order may shift
        try refreshCache()
    }

    /// Loads message history from a thread.
    /// Always hits SwiftData — messages change on every send, caching would be stale.
    ///
    /// GENERIC T: Codable — UI layer specifies the concrete type ([ChatMessage]).
    ///
    /// - Parameters:
    ///   - threadId: Thread UUID
    ///   - type: Type for decoding (e.g. ChatMessage.self)
    /// - Returns: Array of messages (empty if thread not found or history is empty)
    /// - Throws: SwiftData error if fetch failed
    public func loadMessages<T: Codable>(fromThreadId threadId: UUID, as type: T.Type) throws -> [T] {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else {
            return []
        }

        guard !thread.messagesJSON.isEmpty else { return [] }

        do {
            return try JSONDecoder().decode([T].self, from: thread.messagesJSON)
        } catch {
            print("[ThreadStore] ⚠️ Failed to deserialize messages for thread \(threadId): \(error)")
            return []
        }
    }

    // MARK: - Settings

    /// Updates thread settings.
    ///
    /// - Parameters:
    ///   - settings: New settings
    ///   - threadId: UUID of the thread to update
    /// - Throws: SwiftData error if save failed
    public func updateSettings(_ settings: ThreadSettings, forThreadId threadId: UUID) throws {
        let context = makeContext()
        let descriptor = FetchDescriptor<ThreadEntity>(
            predicate: #Predicate { $0.id == threadId }
        )
        guard let thread = try context.fetch(descriptor).first else { return }

        thread.settingsJSON = (try? JSONEncoder().encode(settings)) ?? thread.settingsJSON
        try context.save()

        // Invalidate thread list cache — settings are embedded in ThreadMetadata
        try refreshCache()
    }

    /// Loads thread settings. Always hits SwiftData — not cached.
    ///
    /// - Parameter threadId: Thread UUID
    /// - Returns: ThreadSettings (defaults if thread not found or data is corrupt)
    /// - Throws: SwiftData error if fetch failed
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

    /// Loads the list of project UUIDs bound to a thread.
    ///
    /// - Parameter threadId: Thread UUID
    /// - Returns: Array of project UUIDs
    /// - Throws: SwiftData error if fetch failed
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

    /// Atomically replaces the entire project UUID list for a thread.
    ///
    /// WHY ATOMIC REPLACE, NOT ADD/REMOVE:
    /// ChappieViewModel holds the current projectIds in activeThread.
    /// On add/remove, ViewModel computes the new array and passes it here whole.
    /// This guarantees consistency — no risk of desync between ViewModel and DB.
    ///
    /// ANALOGY: saveMessages() — also a full replace, not append.
    ///
    /// - Parameters:
    ///   - projectIds: New complete list of project UUIDs (may be empty)
    ///   - threadId: UUID of the thread to update
    /// - Throws: SwiftData error if save failed
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

    /// Adds a project to a thread (idempotent — duplicates are ignored).
    ///
    /// - Parameters:
    ///   - projectId: UUID of the project to add
    ///   - threadId: Thread UUID
    /// - Throws: SwiftData error if save failed
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

    /// Removes a project from a thread.
    ///
    /// - Parameters:
    ///   - projectId: UUID of the project to remove
    ///   - threadId: Thread UUID
    /// - Throws: SwiftData error if save failed
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

    /// Renames a thread.
    ///
    /// - Parameters:
    ///   - threadId: Thread UUID
    ///   - title: New title
    /// - Throws: SwiftData error if save failed
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

    /// Deletes a thread from the database.
    ///
    /// WARNING: Deletion is irreversible. All thread message history is lost.
    /// UI should show a confirmation before calling this method.
    ///
    /// - Parameter threadId: UUID of the thread to delete
    /// - Throws: SwiftData error if deletion failed
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

    // MARK: - Default Provider

    /// Loads the default AI provider (first in the list).
    ///
    /// Used by selectThread() as fallback when a thread has no saved provider.
    ///
    /// - Returns: First AIProvider, or nil if none configured
    /// - Throws: SwiftData error if fetch failed
    public func loadDefaultProvider() throws -> AIProvider? {
        // This method exists for convenience — actual provider loading is in AIProviderStore.
        // ThreadStore delegates to AIProviderStore via ChappieViewModel.
        return nil
    }
}
