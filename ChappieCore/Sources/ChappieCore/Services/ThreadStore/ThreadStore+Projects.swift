// ThreadStore+Projects.swift
// ChappieCore
//
// Thread-scoped project CRUD.
// Projects live inside ThreadPayload.projectsJSON — no global registry.
// Duplicate check: same absolutePath → silently ignored.

import Foundation

extension ThreadStore {

    public func loadProjects(forThreadId threadId: UUID) async throws -> [ThreadProjectEntry] {
        let payloads = try await loadPayloads()
        guard let payload = payloads.first(where: { $0.id == threadId }),
              !payload.projectsJSON.isEmpty,
              let projects = try? JSONDecoder().decode([ThreadProjectEntry].self, from: payload.projectsJSON)
        else { return [] }
        return projects
    }

    public func addProject(_ entry: ThreadProjectEntry, toThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[idx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[idx].projectsJSON)) ?? []
        }

        // Deduplicate by absolute path
        guard !projects.contains(where: { $0.absolutePath == entry.absolutePath }) else {
            print("[ThreadStore] ℹ️ Project '\(entry.displayName)' already in thread (same path)")
            return
        }

        projects.append(entry)
        payloads[idx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[idx].projectsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project '\(entry.displayName)' added to thread \(threadId)")
    }

    public func removeProject(id projectId: UUID, fromThreadId threadId: UUID) async throws {
        var payloads = try await loadPayloads()
        guard let idx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[idx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[idx].projectsJSON)) ?? []
        }

        let before = projects.count
        // Secret values live in the Keychain, outside the payload — drop them with the project
        // so no orphaned credentials stay behind.
        let removedSecrets = projects.filter { $0.id == projectId }.flatMap { $0.settings.curlSecrets }
        projects.removeAll { $0.id == projectId }
        guard projects.count < before else { return }
        CurlSecretKeychain().deleteAll(removedSecrets)

        payloads[idx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[idx].projectsJSON
        payloads[idx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Project \(projectId) removed from thread \(threadId)")
    }

    public func updateProjectSettings(
        _ settings: ProjectSettings,
        projectId: UUID,
        threadId: UUID
    ) async throws {
        var payloads = try await loadPayloads()
        guard let tIdx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[tIdx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[tIdx].projectsJSON)) ?? []
        }

        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[pIdx].settings = settings
        payloads[tIdx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[tIdx].projectsJSON
        payloads[tIdx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Settings updated for project \(projectId) in thread \(threadId)")
    }

    /// Updates absolutePath for a project — used for manual repair (e.g. after migrating
    /// to a new machine, or when a folder moved on disk) via a text field in settings.
    /// displayName is updated too only if the caller passes a non-nil value.
    public func updateProjectPath(
        _ absolutePath: String,
        displayName: String? = nil,
        projectId: UUID,
        threadId: UUID
    ) async throws {
        var payloads = try await loadPayloads()
        guard let tIdx = payloads.firstIndex(where: { $0.id == threadId }) else { return }

        var projects: [ThreadProjectEntry] = []
        if !payloads[tIdx].projectsJSON.isEmpty {
            projects = (try? JSONDecoder().decode([ThreadProjectEntry].self, from: payloads[tIdx].projectsJSON)) ?? []
        }

        guard let pIdx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[pIdx].absolutePath = absolutePath
        if let displayName { projects[pIdx].displayName = displayName }
        payloads[tIdx].projectsJSON = (try? JSONEncoder().encode(projects)) ?? payloads[tIdx].projectsJSON
        payloads[tIdx].updatedAt = Date()
        try await savePayloads(payloads)
        try await refreshCache()
        print("[ThreadStore] ✅ Path updated for project \(projectId) in thread \(threadId)")
    }
}
