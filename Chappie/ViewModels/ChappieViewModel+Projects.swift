// ChappieViewModel+Projects.swift
// Chappie
//
// Project management: add/remove via UI or AI tool, settings update, reload after change.
// detectDevEnvironment: local rule-based detection first, AI fallback for exotic stacks.

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
                // Always create a fresh bookmark from the URL the user actually picked.
                // WHY: if a project with the same name was previously added from a different
                // location (e.g. Downloads), the old bookmark points to the wrong folder.
                // We must update it — not silently skip — to avoid stale path resolution.
                let bookmarkData: Data
                do {
                    bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch {
                    bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }

                let displayName = url.lastPathComponent

                // Search ALL projects in store — not just activeProjects (current thread only).
                // WHY: AI tool add_project_to_thread creates a project with empty bookmarkData.
                // When the user later picks the folder via UI, we must update that project's
                // bookmark regardless of which thread it belongs to. Without this, the project
                // stays with an empty bookmark → unavailable → git/file tools fail.
                let allProjects = (try? await pStore.loadProjects()) ?? []
                if let existing = allProjects.first(where: { $0.displayName == displayName }) {
                    try await pStore.updateBookmark(bookmarkData, forProjectId: existing.id)
                    print("[ChappieViewModel] Project '\(displayName)' bookmark updated (global search) → \(url.path)")

                    // If this project is not yet in the current thread — add it.
                    if !thread.projectIds.contains(existing.id) {
                        var updatedIds = thread.projectIds
                        updatedIds.append(existing.id)
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
                    } else {
                        await loadProjectsForThread(thread)
                        buildAndSyncMemoryContext()
                        await syncActiveMemoryContext()
                        await syncFileSystemForActiveThread()
                        restartMCPIfNeeded()
                    }
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
                print("[ChappieViewModel] Project '\(displayName)' added to thread '\(thread.title)' → \(url.path)")
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
    ///
    /// WHY BOTH MAPS:
    /// projectEnvMap routes build_project/run_tests to the correct dev environment.
    /// projectPathMap routes git_* tools to the correct working directory per project.
    func restartMCPIfNeeded() {
        MCPHelperLauncher.shared.launch(
            workspacePath: workspaceURL?.path,
            projectEnvMap: activeProjectEnvMap,
            projectPathMap: activeProjectPathMap
        )
    }

    // MARK: - Dev Environment Auto-Detection

    /// Detects the dev environment for a specific project by scanning its own files.
    ///
    /// WHY we resolve the bookmark directly here instead of using project.absolutePath:
    /// absolutePath is populated asynchronously by syncFileSystemForActiveThread(), and
    /// that method has a PRE-RESET step that clears absolutePath on ALL projects before
    /// the resolution loop. If the user taps "Detect" while a sync is in progress (e.g.
    /// triggered by saving settings), absolutePath may be nil even for healthy projects.
    /// Resolving the bookmark ourselves makes detection independent of sync timing.
    ///
    /// Local detection runs first — covers all common stacks without an AI call.
    /// AI fallback fires only for exotic stacks not covered by local rules.
    func detectDevEnvironment(
        for project: ProjectMetadata,
        completion: @escaping @MainActor (DevEnvironment) -> Void
    ) {
        guard let pStore = projectStore else {
            Task { @MainActor in completion(.unknown) }
            return
        }

        Task {
            // Resolve bookmark directly — do NOT rely on project.absolutePath.
            // WHY: see method-level comment above.
            let resolvedURL = await resolveBookmarkURL(for: project.id, using: pStore)

            guard let projectURL = resolvedURL else {
                print("[detectEnv] Could not resolve bookmark for '\(project.displayName)' → .unknown")
                await MainActor.run { completion(.unknown) }
                return
            }

            let absolutePath = projectURL.path
            let projectFS = FileSystemManager(workspaceURL: projectURL)

            let files = (try? await projectFS.listFiles()) ?? []
            print("[detectEnv] '\(project.displayName)': \(files.count) files scanned at \(absolutePath)")

            guard !files.isEmpty else {
                print("[detectEnv] empty file list for '\(project.displayName)' → .unknown")
                await MainActor.run { completion(.unknown) }
                return
            }

            // Local rule-based detection — fast, free, covers all common stacks.
            if let local = detectEnvironmentLocally(from: files, projectName: project.displayName) {
                print("[detectEnv] local match → \(local.displayName) for '\(project.displayName)'")
                await MainActor.run { completion(local) }
                return
            }

            // AI fallback — only for exotic stacks not covered by local rules.
            guard let client = aiClient else {
                print("[detectEnv] no AI client, local rules found no match → .unknown for '\(project.displayName)'")
                await MainActor.run { completion(.unknown) }
                return
            }

            let fileList = files.prefix(200).joined(separator: "\n")

            let hints = DevEnvironment.allCases
                .filter { $0 != .unknown }
                .map { env in "\(env.rawValue): \(env.detectionHints.joined(separator: ", "))" }
                .joined(separator: "\n")

            let systemPrompt = """
            You are a dev environment detector. Respond with EXACTLY one raw value from this list:
            unknown, xcode, nodejs, python, go, rust, java, kotlin, flutter, react_typescript, dotnet, html

            Detection hints (env: marker files):
            \(hints)

            Rules:
            - If you see .xcodeproj, .xcworkspace, or .swift files → xcode
            - If you see package.json → nodejs
            - If you see pubspec.yaml → flutter
            - If you see tsconfig.json or .tsx files → react_typescript
            - If you see index.html or .html files without any framework marker → html
            - If the stack is not in the list above → unknown
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
                print("[detectEnv] AI → '\(raw)' → \(detected.displayName) for '\(project.displayName)'")
                await MainActor.run { completion(detected) }
            } catch {
                print("[detectEnv] AI call failed: \(error.localizedDescription) → .unknown for '\(project.displayName)'")
                await MainActor.run { completion(.unknown) }
            }
        }
    }

    /// Resolves security-scoped bookmark for a project directly from ProjectStore.
    /// Returns nil if bookmark is missing, stale, or the folder doesn't exist.
    private func resolveBookmarkURL(for projectId: UUID, using pStore: ProjectStore) async -> URL? {
        guard let bookmarkData = try? await pStore.loadBookmark(forProjectId: projectId),
              !bookmarkData.isEmpty else { return nil }

        var isStale = false
        let url: URL?

        if let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            _ = resolved.startAccessingSecurityScopedResource()
            await Task.yield()
            url = resolved
        } else {
            url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }

        guard let resolvedURL = url, !isStale else { return nil }
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return nil }
        return resolvedURL
    }

    /// Fast local detection by scanning file names and extensions against known marker files.
    /// Returns nil only if no rule matches — caller falls back to AI for exotic stacks.
    ///
    /// WHY html is last: it's the most generic stack (any folder can have .html).
    /// We only assign it when no more specific framework marker is found.
    private func detectEnvironmentLocally(from files: [String], projectName: String = "") -> DevEnvironment? {
        let fileNames = Set(files.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        let extensions = Set(files.compactMap {
            let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        })

        print("[detectEnv] '\(projectName)' fileNames sample: \(Array(fileNames.prefix(10)))")
        print("[detectEnv] '\(projectName)' extensions: \(extensions)")

        // Ordered by specificity — most specific markers first.
        let candidates: [(DevEnvironment, Bool)] = [
            (.xcode,           fileNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) || extensions.contains("swift")),
            (.flutter,         fileNames.contains("pubspec.yaml")),
            (.reacttypescript,  fileNames.contains("tsconfig.json") || fileNames.contains("vite.config.ts") || fileNames.contains("next.config.ts") || extensions.contains("tsx")),
            (.nodejs,           fileNames.contains("package.json")),
            (.python,           fileNames.contains("requirements.txt") || fileNames.contains("pyproject.toml") || fileNames.contains("setup.py") || fileNames.contains("main.py") || fileNames.contains("manage.py") || extensions.contains("py")),
            (.rust,             fileNames.contains("cargo.toml")),
            (.go,               fileNames.contains("go.mod")),
            (.kotlin,           fileNames.contains("androidmanifest.xml") || fileNames.contains("build.gradle.kts")),
            (.java,             fileNames.contains("pom.xml") || (fileNames.contains("build.gradle") && !fileNames.contains("androidmanifest.xml"))),
            (.dotnet,           extensions.contains("csproj") || extensions.contains("sln") || extensions.contains("cs")),
            // HTML/CSS/JS: static site — checked last, most generic.
            (.html,             fileNames.contains("index.html") || extensions.contains("html")),
        ]

        return candidates.first(where: { $0.1 })?.0
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
                // Reuse existing project (may already have a valid bookmark from a previous UI pick).
                // WHY: creating a duplicate with empty bookmarkData would shadow the real one,
                // causing git/file tools to fail with "projectPathMap is empty" until the user
                // manually re-picks the folder.
                projectId = existing.id
            } else {
                // New project — bookmark is empty until the user picks the folder via UI.
                // This is expected: AI can attach a project by name, user provides the path later.
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
