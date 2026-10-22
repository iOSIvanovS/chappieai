// ChappieViewModel+Projects.swift
// Chappie
//
// Project management: add/remove via UI only (picker or drag & drop).
// Projects are thread-scoped — stored as ThreadProjectEntry inside the thread.
// No global project registry. No bookmarks. No AI add/remove tools.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Load Projects for Thread

    func loadProjectsForThread(_ thread: ThreadMetadata) async {
        // Projects are now embedded in ThreadMetadata directly — no ProjectStore call needed.
        let entries = thread.projects
        self.activeProjects = entries.map { entry in
            ProjectMetadata(
                id: entry.id,
                displayName: entry.displayName,
                createdAt: entry.createdAt,
                settings: entry.settings,
                absolutePath: entry.absolutePath
            )
        }
        print("[ChappieViewModel] Loaded \(activeProjects.count) projects for thread '\(thread.title)'")
    }

    // MARK: - Add via UI (picker or drag & drop)

    func addProject(url: URL) {
        guard let tStore = threadStore, let thread = activeThread else { return }

        Task {
            // Acquire security-scoped access to read the path.
            // WHY: on macOS, URLs from NSOpenPanel/drop carry a security scope.
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }

            let absolutePath = url.path
            let displayName  = url.lastPathComponent

            // Deduplicate: same absolute path must not appear twice in one thread.
            if thread.projects.contains(where: { $0.absolutePath == absolutePath }) {
                print("[ChappieViewModel] Project '\(displayName)' already in thread (same path) — skipped")
                return
            }

            let entry = ThreadProjectEntry(
                displayName: displayName,
                absolutePath: absolutePath
            )

            do {
                try await tStore.addProject(entry, toThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                    await syncFileSystemForActiveThread()
                    restartMCPIfNeeded()
                }
                print("[ChappieViewModel] Project '\(displayName)' added to thread '\(thread.title)' → \(absolutePath)")
            } catch {
                print("[ChappieViewModel] Error adding project: \(error)")
            }
        }
    }

    // MARK: - Remove via UI

    func removeProject(id projectId: UUID) {
        guard let tStore = threadStore, let thread = activeThread else { return }

        Task {
            do {
                try await tStore.removeProject(id: projectId, fromThreadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                    await syncFileSystemForActiveThread()
                    restartMCPIfNeeded()
                }
                print("[ChappieViewModel] Project removed from thread '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] Error removing project from thread: \(error)")
            }
        }
    }

    // MARK: - Update Project Settings

    func updateProjectSettings(_ settings: ProjectSettings, forProjectId projectId: UUID) {
        guard let tStore = threadStore, let thread = activeThread else { return }

        Task {
            do {
                try await tStore.updateProjectSettings(settings, projectId: projectId, threadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                    restartMCPIfNeeded()
                }
                print("[ChappieViewModel] Project settings updated (id: \(projectId))")
            } catch {
                print("[ChappieViewModel] Error updating project settings: \(error)")
            }
        }
    }

    // MARK: - Update Project Path

    /// Manual path repair — e.g. after migrating to a new machine or moving a folder on disk.
    /// Separate from updateProjectSettings since absolutePath lives in ThreadProjectEntry, not ProjectSettings.
    func updateProjectPath(_ newPath: String, forProjectId projectId: UUID) {
        guard let tStore = threadStore, let thread = activeThread else { return }

        Task {
            do {
                try await tStore.updateProjectPath(newPath, projectId: projectId, threadId: thread.id)

                let refreshed = try await tStore.loadThreads()
                self.threads = refreshed

                if let updatedThread = refreshed.first(where: { $0.id == thread.id }) {
                    self.activeThread = updatedThread
                    await loadProjectsForThread(updatedThread)
                    buildAndSyncMemoryContext()
                    await syncActiveMemoryContext()
                    await syncFileSystemForActiveThread()
                    restartMCPIfNeeded()
                }
                print("[ChappieViewModel] Project path updated (id: \(projectId)) -> \(newPath)")
            } catch {
                print("[ChappieViewModel] Error updating project path: \(error)")
            }
        }
    }

    // MARK: - MCP Restart

    /// Restarts MCP helper with the current workspace, env map, and path map.
    func restartMCPIfNeeded() {
        MCPHelperLauncher.shared.launch(
            workspacePath: workspaceURL?.path,
            projectEnvMap: activeProjectEnvMap,
            projectPathMap: activeProjectPathMap
        )
    }

    // MARK: - Register AI Tool Handlers (list only — add/remove removed)

    func registerProjectToolHandlers(
        toolService ts: ToolExecutionService
    ) {
        Task {
            await ts.registerProjectHandlers(
                listProjects: { [weak self] in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else { continuation.resume(returning: "Error: ViewModel released."); return }
                            let names = self.activeProjects.map { $0.displayName }
                            if names.isEmpty {
                                continuation.resume(returning: "No projects in current thread.")
                            } else {
                                let list = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                                continuation.resume(returning: "Projects in current thread:\n\(list)")
                            }
                        }
                    }
                }
            )
            print("[ChappieViewModel] Project tool handlers registered")
        }
    }

    // MARK: - Reload After Change

    func reloadAfterProjectChange(updatedThread: ThreadMetadata) async {
        do {
            guard let tStore = threadStore else { return }
            let refreshed = try await tStore.loadThreads()
            self.threads = refreshed

            if activeThread?.id == updatedThread.id {
                self.activeThread = updatedThread
                await loadProjectsForThread(updatedThread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()
                await syncFileSystemForActiveThread()
                restartMCPIfNeeded()
            }
        } catch {
            print("[ChappieViewModel] Error reloading after project change: \(error)")
        }
    }
}
