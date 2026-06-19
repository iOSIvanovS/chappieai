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
        projects.removeAll { $0.id == projectId }
        guard projects.count < before else { return }

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
}
