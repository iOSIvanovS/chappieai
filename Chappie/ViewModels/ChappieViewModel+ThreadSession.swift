// ChappieViewModel+ThreadSession.swift
// Chappie
//
// ThreadSession lifecycle — assembly on thread activation, invalidation on memory change.
//
// DESIGN:
//   ProjectMetadata is a Sendable DTO — all data comes from ThreadProjectEntry stored in the thread.
//   absolutePath is stored at attachment time (from the URL the user picked).
//   No bookmark resolution — absolutePath is read directly from ProjectMetadata.
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
//   the expensive FS sync — safe for settings-only changes.
//
// M-09 WORKSPACE ISOLATION:
//   syncFileSystemForActiveThread() reads absolutePath from each ProjectMetadata directly.
//   No bookmarks. No global project registry. Path is always the one the user picked.
//   Paths are prefixed: "ProjectName/relative/path".
//   On threads with no projects — restores the global fileSystem (from workspaceURL).
//
// FS READINESS GUARD:
//   syncFileSystemForActiveThread() sets isFileSystemReady=false on ViewModel (→ UI spinner)
//   and on ToolExecutionService (→ file tools blocked) before path resolution starts.
//   Both are set true after FileSystem is wired. This prevents stale FS responses
//   during thread switch when path resolution is slow.
//
// SYNC TASK CANCELLATION:
//   _syncTask holds the current background Task launched by selectThread().
//   On every selectThread() call, the previous Task is cancelled before a new one starts.
//   This prevents a slow sync from a previous thread from racing with the new thread's sync.
//
// PATH HEALTH-CHECK:
//   Before using a path, we verify:
//   (a) path is not empty
//   (b) folder exists — FileManager.fileExists(atPath:) returns true
//   (c) not in Trash — path contains "/.Trash/" or "/.Trashes/"
//   Unavailable projects are marked isUnavailable=true and shown with an orange icon.
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
//
// MCP RESTART AFTER PATH RESOLUTION:
//   syncFileSystemForActiveThread() calls restartMCPIfNeeded() after resolving all paths.
//   This ensures projectPathMap in MCP always reflects the latest resolved absolutePaths.
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

        guard !Task.isCancelled else { return }

        let builder = SystemPromptBuilder(personaBlock: Self.v2PersonaBlock)

        let session = ThreadSession(
            thread: thread,
            projectMetas: activeProjects,
            memoryStore: store,
            promptBuilder: builder,
            userName: nil
        )

        self._activeThreadSession = session
        print("[ChappieViewModel] ThreadSession assembled for '\(thread.title)' (\(activeProjects.count) projects)")

        // M-09: Sync FileSystem to cover ALL attached projects.
        await syncFileSystemForActiveThread()

        // B-05 LIVE: register callback so FileTools can flip the chip orange mid-conversation.
        registerProjectUnavailableCallback()
    }

    // MARK: - Rebuild (settings-only — skips FS sync)

    /// Rebuilds ThreadSession with fresh projectMetas WITHOUT re-syncing the FileSystem.
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

    // MARK: - M-09: Multi-workspace FileSystem sync

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

        self.isFileSystemReady = false
        await ts.setFileSystemReady(false)

        // PRE-RESET: clear stale isUnavailable flags from any previously cancelled sync.
        for i in activeProjects.indices {
            activeProjects[i].isUnavailable = false
        }

        var workspaces: [(name: String, url: URL)] = []

        for i in activeProjects.indices {
            guard !Task.isCancelled else { break }

            let project = activeProjects[i]

            // absolutePath is stored at attachment time — read directly, no bookmark needed.
            guard let path = project.absolutePath, !path.isEmpty else {
                print("[ChappieViewModel] M-09: No absolutePath for '\(project.displayName)' — marked unavailable")
                activeProjects[i].isUnavailable = true
                continue
            }

            if isPathStale(path) {
                print("[ChappieViewModel] M-09: ⚠️ Stale path for '\(project.displayName)' — marked unavailable (\(path))")
                activeProjects[i].isUnavailable = true
                continue
            }

            let url = URL(fileURLWithPath: path)
            activeProjects[i].isUnavailable = false
            workspaces.append((name: project.displayName, url: url))
            print("[ChappieViewModel] M-09: ✅ '\(project.displayName)' → \(path)")
        }

        restartMCPIfNeeded()
        await syncActiveMemoryContext()

        guard !Task.isCancelled else {
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        if workspaces.isEmpty {
            print("[ChappieViewModel] M-09: No workspaces resolved — all projects unavailable")
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        // Always use named multi-workspace init — even for a single project.
        // WHY: single-workspace init(workspaceURL:) assigns name="" which breaks
        // project= routing when AI calls list_files(project: "Chappie") — name mismatch → orange chip.
        let fs = FileSystemManager(workspaces: workspaces)

        await ts.setFileSystem(fs)

        self.isFileSystemReady = true
        await ts.setFileSystemReady(true)

        // Rebuild ThreadSession so the system prompt reflects updated absolutePaths.
        if let thread = activeThread {
            await rebuildThreadSessionOnly(for: thread)
        }

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

    // MARK: - Path health-check

    private func isPathStale(_ path: String) -> Bool {
        if path.contains("/.Trash/")   { return true }
        if path.contains("/.Trashes/") { return true }
        if !FileManager.default.fileExists(atPath: path) { return true }
        return false
    }
}
