// ChappieViewModel+Projects.swift
// Chappie
//
// Project management: add/remove via UI or AI tool, settings update, reload after change.
// detectDevEnvironment: sends file list to AI and parses the detected DevEnvironment.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Load Projects for Thread

    func loadProjectsForThread(_ thread: ThreadMetadata) async {
        guard let pStore = projectStore, !thread.projectIds.isEmpty else {
            self.activeProjects = []
            return
        }
        do {
            let projects = try await pStore.loadProjects(ids: thread.projectIds)
            self.activeProjects = projects
            print("[ChappieViewModel] Loaded \(projects.count) projects for thread '\(thread.title)'")
        } catch {
            print("[ChappieViewModel] Error loading thread projects: \(error)")
            self.activeProjects = []
        }
    }

    // MARK: - Add / Remove via UI

    func addProject(url: URL) {
        guard let pStore = projectStore, let tStore = threadStore, let thread = activeThread else { return }

        Task {
            do {
                let bookmarkData: Data
                do {
                    bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch {
                    bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }

                let displayName = url.lastPathComponent
                guard !activeProjects.contains(where: { $0.displayName == displayName }) else {
                    print("[ChappieViewModel] Project '\(displayName)' already added")
                    return
                }

                let projectId = try await pStore.addProject(displayName: displayName, bookmarkData: bookmarkData)
                var updatedIds = thread.projectIds
                updatedIds.append(projectId)
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

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
                print("[ChappieViewModel] Project '\(displayName)' added to thread '\(thread.title)'")
            } catch {
                print("[ChappieViewModel] Error adding project: \(error)")
            }
        }
    }

    func removeProject(id projectId: UUID) {
        guard let tStore = threadStore, let thread = activeThread else { return }

        Task {
            do {
                var updatedIds = thread.projectIds
                updatedIds.removeAll { $0 == projectId }
                try await tStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

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
        guard let pStore = projectStore, let thread = activeThread else { return }

        Task {
            do {
                try await pStore.updateSettings(settings, forProjectId: projectId)
                await loadProjectsForThread(thread)
                buildAndSyncMemoryContext()
                await syncActiveMemoryContext()

                // Restart MCP helper — devEnvironment or project list may have changed.
                restartMCPIfNeeded()

                print("[ChappieViewModel] Project settings updated (id: \(projectId))")
            } catch {
                print("[ChappieViewModel] Error updating project settings: \(error)")
            }
        }
    }

    // MARK: - MCP Restart

    /// Restarts MCP helper with the current workspace, env map, and path map.
    /// Call after any change that may affect which environments or paths are active.
    ///
    /// WHY BOTH MAPS:
    /// projectEnvMap routes build_project/run_tests to the correct dev environment.
    /// projectPathMap routes git_* tools to the correct working directory per project.
    func restartMCPIfNeeded() {
        guard let workspaceURL else { return }
        MCPHelperLauncher.shared.restartWithWorkspace(
            workspaceURL,
            projectEnvMap: activeProjectEnvMap,
            projectPathMap: activeProjectPathMap
        )
    }

    // MARK: - Dev Environment Auto-Detection

    /// Sends the project file list to the active AI model and asks it to identify
    /// the dev environment. Calls completion on MainActor with the detected value.
    /// Falls back to .unknown on any error or if no AI client is available.
    func detectDevEnvironment(
        for project: ProjectMetadata,
        completion: @escaping @MainActor (DevEnvironment) -> Void
    ) {
        guard let client = aiClient else {
            print("[ChappieViewModel] detectDevEnvironment: no AI client")
            Task { @MainActor in completion(.unknown) }
            return
        }

        Task {
            let fileList: String
            if let fs = fileSystem {
                let files = (try? await fs.listFiles()) ?? []
                fileList = files.prefix(200).joined(separator: "\n")
            } else {
                fileList = "(file list unavailable)"
            }

            let hints = DevEnvironment.allCases
                .filter { $0 != .unknown }
                .map { env in "\(env.rawValue): \(env.detectionHints.joined(separator: ", "))" }
                .joined(separator: "\n")

            let systemPrompt = """
            You are a dev environment detector. Respond with EXACTLY one raw value from this list:
            unknown, xcode, nodejs, python, go, rust, java, kotlin, flutter, react_typescript, dotnet

            Detection hints (env: marker files):
            \(hints)

            Rules:
            - If you see .xcodeproj, .xcworkspace, or .swift files → xcode
            - If you see package.json → nodejs
            - If you see pubspec.yaml → flutter
            - If you see tsconfig.json or .tsx files → react_typescript
            - Respond with the single raw value only. No explanation, no punctuation.
            """

            let userMessage = AIMessage(
                role: "user",
                content: "Project file list:\n\(fileList)\n\nWhat is the dev environment?"
            )

            do {
                let result = try await client.sendRequest(
                    systemPrompt: systemPrompt,
                    chatHistory: [userMessage],
                    tools: []
                )

                let raw = (result.message.contentString ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                let detected = DevEnvironment(rawValue: raw) ?? .unknown
                print("[ChappieViewModel] detectDevEnvironment → '\(raw)' → \(detected.displayName)")
                await MainActor.run { completion(detected) }
            } catch {
                print("[ChappieViewModel] detectDevEnvironment failed: \(error.localizedDescription)")
                await MainActor.run { completion(.unknown) }
            }
        }
    }

    // MARK: - Register AI Tool Handlers

    func registerProjectToolHandlers(
        toolService ts: ToolExecutionService,
        projectStore pStore: ProjectStore,
        threadStore tStore: ThreadStore
    ) {
        Task {
            await ts.registerProjectHandlers(
                addProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else { continuation.resume(returning: "Error: ViewModel released."); return }
                            let result = await ChappieViewModel.performAddProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: self.activeThread,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(updatedThread: updatedThread, projectStore: pStore, threadStore: tStore)
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

                removeProject: { [weak self] displayName in
                    return await withCheckedContinuation { continuation in
                        Task { @MainActor [weak self] in
                            guard let self else { continuation.resume(returning: "Error: ViewModel released."); return }
                            let result = await ChappieViewModel.performRemoveProjectByName(
                                displayName: displayName,
                                projectStore: pStore,
                                threadStore: tStore,
                                activeThread: self.activeThread,
                                activeProjects: self.activeProjects,
                                onUpdate: { [weak self] updatedThread in
                                    Task { @MainActor [weak self] in
                                        await self?.reloadAfterProjectChange(updatedThread: updatedThread, projectStore: pStore, threadStore: tStore)
                                    }
                                }
                            )
                            continuation.resume(returning: result)
                        }
                    }
                },

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

    // MARK: - Static Helpers (tool-safe, no self capture)

    static func performAddProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else { return "Error: No active thread." }

        do {
            let allProjects = try await projectStore.loadProjects()
            let threadProjects = try await projectStore.loadProjects(ids: thread.projectIds)

            if threadProjects.contains(where: { $0.displayName == displayName }) {
                return "Project '\(displayName)' is already added to the current thread."
            }

            let projectId: UUID
            if let existing = allProjects.first(where: { $0.displayName == displayName }) {
                projectId = existing.id
            } else {
                projectId = try await projectStore.addProject(displayName: displayName, bookmarkData: Data())
            }

            var updatedIds = thread.projectIds
            updatedIds.append(projectId)
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) { onUpdate(updatedThread) }

            return "Project '\(displayName)' added to the current thread."
        } catch {
            return "Error adding project '\(displayName)': \(error.localizedDescription)"
        }
    }

    static func performRemoveProjectByName(
        displayName: String,
        projectStore: ProjectStore,
        threadStore: ThreadStore,
        activeThread: ThreadMetadata?,
        activeProjects: [ProjectMetadata],
        onUpdate: @escaping @Sendable (ThreadMetadata) -> Void
    ) async -> String {
        guard let thread = activeThread else { return "Error: No active thread." }
        guard let project = activeProjects.first(where: { $0.displayName == displayName }) else {
            return "Project '\(displayName)' not found in current thread."
        }

        do {
            var updatedIds = thread.projectIds
            updatedIds.removeAll { $0 == project.id }
            try await threadStore.updateProjectBindings(updatedIds, forThreadId: thread.id)

            let refreshed = try await threadStore.loadThreads()
            if let updatedThread = refreshed.first(where: { $0.id == thread.id }) { onUpdate(updatedThread) }

            return "Project '\(displayName)' removed from current thread."
        } catch {
            return "Error removing project '\(displayName)': \(error.localizedDescription)"
        }
    }

    // MARK: - Reload After Change

    func reloadAfterProjectChange(
        updatedThread: ThreadMetadata,
        projectStore: ProjectStore,
        threadStore: ThreadStore
    ) async {
        do {
            let refreshed = try await threadStore.loadThreads()
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
