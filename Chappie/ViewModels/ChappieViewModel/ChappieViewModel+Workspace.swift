// ChappieViewModel+Workspace.swift
// Chappie
//
// Workspace management: setWorkspace, initializeServices, security-scoped bookmarks,
// loadWorkspaceFromStore, attachment handler registration.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Workspace

    func setWorkspace(_ url: URL) {
        workspaceURL = url
        initializeServices(for: url)
        saveWorkspaceWithSecurityScope(url)
        MCPHelperLauncher.shared.restartWithWorkspace(
            url,
            projectEnvMap: activeProjectEnvMap,
            projectPathMap: activeProjectPathMap
        )

        if messages.isEmpty {
            messages.append(.message(isUser: false, text: String(localized: "system.project_connected")))
        }
    }

    // MARK: - Service Initialization

    func initializeServices(for url: URL) {
        let fs = FileSystemManager(workspaceURL: url)
        self.fileSystem = fs

        let mm = MemoryManager(workspaceURL: url)
        self.memoryManager = mm

        Task {
            await mm.initializeWorkspaceMemory()
            if let store = self.memoryStore { await mm.setMemoryStore(store) }
        }

        let wf = WebFetchService()
        self.webFetchService = wf

        let socketPath = MCPHelperLauncher.shared.socketPath
        let ts = ToolExecutionService(fileSystem: fs, memoryManager: mm, socketPath: socketPath, webFetch: wf)
        self.toolService = ts
        Task {
            await ts.setHelperRecoveryHandler { await MCPHelperLauncher.shared.recoverForToolCall() }
        }

        if let client = aiClient {
            self.orchestrator = AIOrchestrator(aiClient: client, toolService: ts, fileSystem: fs, memoryManager: mm)
        }

        registerProjectToolHandlers(toolService: ts)
        registerAttachmentHandlers(toolService: ts)

        Task { await syncActiveMemoryContext() }
    }

    // MARK: - Attachment Handler Registration

    /// Bridges AttachmentStore (app target) into ToolExecutionService (ChappieCore target)
    /// via closures — avoids cross-target dependency.
    ///
    /// WHY local capture of AttachmentStore.shared:
    /// ChappieViewModel is @MainActor. Sendable closures passed to ToolExecutionService
    /// (an actor) cannot reference @MainActor-isolated state. We capture a local reference
    /// to AttachmentStore.shared (which is @unchecked Sendable) before entering the Task,
    /// so the closures are fully nonisolated.
    private func registerAttachmentHandlers(toolService: ToolExecutionService) {
        let store = AttachmentStore.shared
        Task {
            await toolService.registerAttachmentHandlers(
                resolve: { uuid in
                    store.resolve(uuid: uuid)
                },
                save: { data, filename in
                    let attachmentId = UUID()
                    guard let url = store.save(data: data, filename: filename, forAttachmentId: attachmentId) else {
                        return nil
                    }
                    return AttachmentSaveResult(url: url, uuid: attachmentId)
                },
                reserve: { filename, uuid in
                    store.reserveURL(filename: filename, forAttachmentId: uuid)
                }
            )
        }
    }

    // MARK: - Security-Scoped Bookmarks

    func saveWorkspaceWithSecurityScope(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            saveWorkspaceBookmark(data)
        } catch {
            if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                saveWorkspaceBookmark(data)
            }
        }
    }

    /// Loads workspace from AppSettingsStore after store is ready.
    /// Migrates legacy UserDefaults bookmark on first run, then removes it.
    func loadWorkspaceFromStore(_ store: AppSettingsStore) async {
        guard workspaceURL == nil else { return }

        var bookmarkData: Data? = try? await store.loadWorkspaceBookmark()

        // One-time migration: if store has no bookmark but UserDefaults does — migrate and clean up.
        if bookmarkData == nil, let legacyData = UserDefaults.standard.data(forKey: "workspaceBookmark") {
            bookmarkData = legacyData
            try? await store.save(workspaceBookmark: legacyData)
            UserDefaults.standard.removeObject(forKey: "workspaceBookmark")
            print("[ChappieViewModel] Workspace bookmark migrated from UserDefaults to AppSettingsStore")
        }

        guard let data = bookmarkData else { return }

        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            _ = url.startAccessingSecurityScopedResource()
            await MainActor.run {
                self.workspaceURL = url
                self.initializeServices(for: url)
            }
            if isStale { saveWorkspaceWithSecurityScope(url) }
            MCPHelperLauncher.shared.launch(
                workspacePath: url.path,
                projectEnvMap: activeProjectEnvMap,
                projectPathMap: activeProjectPathMap
            )
        } else if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            await MainActor.run {
                self.workspaceURL = url
                self.initializeServices(for: url)
            }
            MCPHelperLauncher.shared.launch(
                workspacePath: url.path,
                projectEnvMap: activeProjectEnvMap,
                projectPathMap: activeProjectPathMap
            )
        }
    }
}
