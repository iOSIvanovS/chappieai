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
// MCP RESTART:
//   restartMCPIfNeeded() is called ONCE from assembleThreadSession(), after FS paths are resolved.
//   It is NOT called inside syncFileSystemForActiveThread() — that would cause a double restart
//   when selectThread() calls assembleThreadSession() (which calls syncFileSystemForActiveThread()).
//
// MEMORY SYNC:
//   syncActiveMemoryContext() is called ONCE from selectThread()._syncTask before assembleThreadSession().
//   It is NOT called inside syncFileSystemForActiveThread() — that would cause a double sync.
//   For project add/remove (addProject/removeProject in +Projects.swift), callers are responsible
//   for calling syncActiveMemoryContext() before invoking syncFileSystemForActiveThread().
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

    // MARK: - Assemble (full — includes FS sync + MCP restart)

    /// Builds a fresh ThreadSession + syncs FileSystem + restarts MCP for the given thread.
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

        // Single MCP restart after FS paths are resolved — not inside syncFileSystemForActiveThread().
        restartMCPIfNeeded()
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

    /// Resolves absolutePaths for all active projects and wires them into ToolExecutionService.
    /// Projects with missing paths are silently skipped — no UI indication, no orange chips.
    ///
    /// IMPORTANT: does NOT call restartMCPIfNeeded() or syncActiveMemoryContext() —
    /// those are called exactly once by the caller (assembleThreadSession / addProject / removeProject).
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

        var workspaces: [(name: String, url: URL)] = []

        for project in activeProjects {
            guard !Task.isCancelled else { break }

            guard let path = project.absolutePath, !path.isEmpty else {
                // Path not set — project was added without a valid URL, skip silently.
                print("[ChappieViewModel] M-09: No absolutePath for '\(project.displayName)' — skipped")
                continue
            }

            // Skip folders in Trash — they are intentionally deleted by the user.
            guard !path.contains("/.Trash/"), !path.contains("/.Trashes/") else {
                print("[ChappieViewModel] M-09: '\(project.displayName)' is in Trash — skipped")
                continue
            }

            let url = URL(fileURLWithPath: path)
            workspaces.append((name: project.displayName, url: url))
            print("[ChappieViewModel] M-09: ✅ '\(project.displayName)' → \(path)")
        }

        guard !Task.isCancelled else {
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        if workspaces.isEmpty {
            print("[ChappieViewModel] M-09: No workspaces resolved — all projects skipped")
            self.isFileSystemReady = true
            await ts.setFileSystemReady(true)
            return
        }

        // Always use named multi-workspace init — even for a single project.
        // WHY: single-workspace init(workspaceURL:) assigns name="" which breaks
        // project= routing when AI calls list_files(project: "Chappie") — name mismatch.
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
}
