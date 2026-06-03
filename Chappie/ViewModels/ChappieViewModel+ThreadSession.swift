// ChappieViewModel+ThreadSession.swift
// Chappie
//
// ThreadSession lifecycle — assembly on thread activation, invalidation on memory change.
//
// DESIGN:
//   ProjectEntity is a SwiftData @Model — non-Sendable, cannot cross actor boundaries.
//   We use Sendable ProjectMetadata DTOs instead — all @Model data stays on MainActor.
//
// FLOW:
//   selectThread() → assembleThreadSession() → ThreadSession stored in _activeThreadSession
//   send() reads activeThreadSession?.systemPrompt() → passes as overrideSystemPrompt to orchestrator
//   memory/project changes → rebuildThreadSessionOnly() rebuilds session with fresh projectMetas
//   project add/remove → assembleThreadSession() (full rebuild including FS sync)
//
// WHY rebuildThreadSessionOnly() EXISTS:
//   ThreadSession captures projectMetas by value at init time — they are immutable in the actor.
//   invalidateCache() alone does NOT pick up new settings because the old DTOs are still in place.
//   rebuildThreadSessionOnly() creates a new ThreadSession with fresh activeProjects but skips
//   the expensive bookmark resolution (syncFileSystemForActiveThread) — safe for settings-only changes.
//
// M-09 WORKSPACE ISOLATION (B-01 FIX):
//   syncFileSystemForActiveThread() resolves bookmarks for ALL attached projects
//   and builds a multi-workspace FileSystemManager so list_files / read_file / etc.
//   can access every project, not just the first one.
//   Paths are prefixed: "ProjectName/relative/path".
//   On threads with no projects — restores the global fileSystem (from workspaceURL).
//
// FS READINESS GUARD:
//   syncFileSystemForActiveThread() sets isFileSystemReady=false on ViewModel (→ UI spinner)
//   and on ToolExecutionService (→ file tools blocked) before bookmark resolution starts.
//   Both are set true after FileSystem is wired. This prevents stale FS responses
//   during thread switch when bookmark resolution is slow (100ms–1s per project).
//
// SYNC TASK CANCELLATION:
//   _syncTask holds the current background Task launched by selectThread().
//   On every selectThread() call, the previous Task is cancelled before a new one starts.
//   This prevents a slow syncFileSystemForActiveThread() from a previous thread from
//   racing with the new thread's sync and leaving isFileSystemReady in a wrong state.
//
// STALE BOOKMARK HEALTH-CHECK:
//   Before spending time on bookmark resolution, we verify the resolved URL is:
//   (a) bookmark is not stale (isStale == false) — stale means macOS re-routed it elsewhere
//   (b) reachable — fileExists(atPath:) returns true
//   (c) not in Trash — path contains "/.Trash/" (user Trash) or "/.Trashes/" (volume Trash)
//   Stale projects are marked isUnavailable=true in activeProjects and shown with
//   an orange icon in ProjectChipsView. This gives the user a clear signal to either
//   restore the folder or remove the project from the thread.
//
// B-05 UNAVAILABILITY:
//   Projects that fail health-check are NOT removed from activeProjects — the chip stays
//   visible so the user can see what broke and decide: restore folder or remove project.
//   isUnavailable=true → orange folder icon + tooltip in ProjectChipsView.
//   On next sync (thread switch or app restart), if the folder is back → isUnavailable=false.
//
// LIVE UNAVAILABILITY (B-05 LIVE):
//   After FS is wired, we register onProjectUnavailable callback in ToolExecutionService.
//   When a file tool fails mid-conversation (folder deleted while chat is open), FileTools
//   calls the callback → markProjectUnavailable() flips the chip orange in real time.
//   No timer, no polling — event-driven only.
//
// NOTE: v2PersonaBlock lives in ChappieViewModel+PersonaBlock.swift — extracted for size.

import Foundation
import ChappieCore

extension ChappieViewModel {

    // MARK: - Computed accessor

    /// Active ThreadSession. Nil when no thread is selected.
    var activeThreadSession: ThreadSession? {
        get { _activeThreadSession }
        set { _activeThreadSession = newValue }
    }

    // MARK: - Assemble (full — includes FS sync)

    /// Builds a fresh ThreadSession + syncs FileSystem for the given thread.
    /// Called from selectThread() and when projects are added/removed.
    func assembleThreadSession(for thread: ThreadMetadata) async {
        guard let store = memoryStore else { return }

        // Check cancellation before doing any work — if a newer selectThread()
        // already cancelled this task, bail out immediately.
        guard !Task.isCancelled else { return }

        let builder = SystemPromptBuilder(personaBlock: Self.v2PersonaBlock)

        // Pass Sendable ProjectMetadata DTOs — no SwiftData @Model crosses actor boundary.
        let session = ThreadSession(
            thread: thread,
            projectMetas: activeProjects,
            memoryStore: store,
            promptBuilder: builder,
            userName: nil
        )

        self._activeThreadSession = session
        print("[ChappieViewModel] ThreadSession assembled for '\(thread.title)' (\(activeProjects.count) projects)")

        // M-09 / B-01: Sync FileSystem to cover ALL attached projects.
        await syncFileSystemForActiveThread()

        // B-05 LIVE: register callback so FileTools can flip the chip orange mid-conversation.
        registerProjectUnavailableCallback()
    }

    // MARK: - Rebuild (settings-only — skips FS sync)

    /// Rebuilds ThreadSession with fresh projectMetas WITHOUT re-resolving bookmarks.
    /// Use when only project settings changed (role, comments, terminal access, etc.).
    func rebuildThreadSessionOnly(for thread: ThreadMetadata) async {
        guard let store = memoryStore else { return }

        let builder = SystemPromptBuilder(personaBlock: Self.v2PersonaBlock)

        let session = ThreadSession(
            thread: thread,
            projectMetas: activeProjects,
            memoryStore: store,
            promptBuilder: builder,
            userName: nil
        )

        self._activeThreadSession = session
        print("[ChappieViewModel] ThreadSession rebuilt (settings-only) for '\(thread.title)'")
    }

    // MARK: - Invalidate

    /// Clears the cached prompt inside the active session.
    /// Use only when memory entries change but projectMetas stay the same.
    func invalidateActiveThreadSession() {
        Task { await _activeThreadSession?.invalidateCache() }
    }

    // MARK: - System Prompt for send()

    /// Returns the V2 system prompt if a session is active, nil otherwise.
    func v2SystemPrompt() async -> String? {
        guard let session = _activeThreadSession else { return nil }
        return try? await session.systemPrompt()
    }

    // MARK: - M-09 / B-01: Multi-workspace isolation

    func syncFileSystemForActiveThread() async {
        guard let ts = toolService else { return }

        guard !activeProjects.isEmpty else {
            guard !Task.isCancelled else { return }
            if let globalFS = fileSystem {
                await ts.setFileSystem(globalFS)
                print("[ChappieViewModel] M-09: No projects — restored global fileSystem")
            }
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        guard let pStore = projectStore else { return }

        self.isFileSystemReady = false
        await ts.setFileSystemReady(false)

        var workspaces: [(name: String, url: URL)] = []

        for i in activeProjects.indices {
            guard !Task.isCancelled else { return }

            let project = activeProjects[i]

            guard let bookmarkData = try? await pStore.loadBookmark(forProjectId: project.id),
                  !bookmarkData.isEmpty else {
                print("[ChappieViewModel] M-09: No bookmark for '\(project.displayName)' — marked unavailable")
                activeProjects[i].isUnavailable = true
                continue
            }

            var isStale = false
            let resolvedURL: URL?

            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                resolvedURL = url
            } else {
                resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }

            guard let url = resolvedURL else {
                print("[ChappieViewModel] M-09: ❌ Could not resolve bookmark for '\(project.displayName)' — marked unavailable")
                activeProjects[i].isUnavailable = true
                continue
            }

            // CRITICAL: stale bookmark means macOS re-routed it to a DIFFERENT folder — reject.
            if isStale {
                print("[ChappieViewModel] M-09: ⚠️ Stale bookmark for '\(project.displayName)' — macOS re-routed to '\(url.path)', rejecting")
                activeProjects[i].isUnavailable = true
                continue
            }

            if isURLStale(url) {
                print("[ChappieViewModel] M-09: ⚠️ Stale path for '\(project.displayName)' — marked unavailable (\(url.path))")
                activeProjects[i].isUnavailable = true
                continue
            }

            activeProjects[i].isUnavailable = false
            workspaces.append((name: project.displayName, url: url))
            print("[ChappieViewModel] M-09: ✅ '\(project.displayName)' → \(url.path)")
        }

        guard !Task.isCancelled else { return }

        if workspaces.isEmpty {
            print("[ChappieViewModel] M-09: No workspaces resolved — all projects unavailable")
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        let fs: FileSystemManager
        if workspaces.count == 1 {
            fs = FileSystemManager(workspaceURL: workspaces[0].url)
        } else {
            fs = FileSystemManager(workspaces: workspaces)
        }

        await ts.setFileSystem(fs)

        self.isFileSystemReady = true
        await ts.setFileSystemReady(true)

        let names = workspaces.map(\.name).joined(separator: ", ")
        print("[ChappieViewModel] M-09: FileSystem → [\(names)] (\(workspaces.count) workspaces)")
    }

    // MARK: - Live unavailability callback (B-05)

    func registerProjectUnavailableCallback() {
        guard let ts = toolService else { return }
        Task {
            await ts.setOnProjectUnavailable { [weak self] projectName in
                self?.markProjectUnavailable(named: projectName)
            }
        }
    }

    func markProjectUnavailable(named name: String) {
        guard let idx = activeProjects.firstIndex(where: { $0.displayName == name }) else { return }
        guard !activeProjects[idx].isUnavailable else { return }
        activeProjects[idx].isUnavailable = true
        print("[ChappieViewModel] B-05 LIVE: '\(name)' marked unavailable after FS tool failure")
    }

    // MARK: - Stale URL detection

    private func isURLStale(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("/.Trash/") { return true }
        if path.contains("/.Trashes/") { return true }
        if !FileManager.default.fileExists(atPath: path) { return true }
        return false
    }
}
