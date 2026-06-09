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
// MCP RESTART AFTER PATH RESOLUTION:
//   syncFileSystemForActiveThread() calls restartMCPIfNeeded() after resolving all paths.
//   This ensures projectPathMap in MCP always reflects the latest resolved absolutePaths.
//   Without this, git_* tools would use stale or empty paths on first thread load.
//
// WHY restartMCPIfNeeded() IS CALLED UNCONDITIONALLY AFTER PATH RESOLUTION:
//   The guard !Task.isCancelled before FileSystem assembly protects against wiring the wrong
//   FS to a stale thread, but paths in activeProjects are already resolved at that point.
//   MCP restart must happen regardless of cancellation — if paths were resolved, MCP needs them.
//   Skipping the restart on cancellation left MCP with a stale/empty projectPathMap, causing
//   git_status and other git_* tools to return "projectPathMap is empty" errors.
//
// TERMINAL PATH MAP SYNC:
//   After bookmark resolution, syncActiveMemoryContext() is called to push the updated
//   projectPathMap (name → absolutePath) into ActiveMemoryContext inside ToolExecutionService.
//   This makes run_terminal's "project" parameter work correctly — it reads projectPathMap
//   to prefix commands with `cd /absolute/path && ` for deterministic execution.
//
// PRE-RESET BEFORE SYNC (B-05 FIX):
//   At the start of syncFileSystemForActiveThread(), all projects are reset to
//   isUnavailable=false before the resolution loop begins.
//   WHY: if a previous sync Task was cancelled mid-loop, some projects may still carry
//   isUnavailable=true from that interrupted pass. Without pre-reset, a healthy project
//   that was never reached in the cancelled loop stays orange permanently — a false positive.
//   Pre-reset ensures every sync starts from a clean slate.
//
// SECURITY SCOPE TIMING (B-05 FIX):
//   startAccessingSecurityScopedResource() is asynchronous in effect — macOS needs a
//   brief moment to grant sandbox access before FileManager.fileExists() returns correctly.
//   Without a yield, fileExists() can return false on a healthy folder immediately after
//   startAccessingSecurityScopedResource(), causing a false isUnavailable=true.
//   We yield with Task.yield() after starting access to let the run loop process the grant.
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

        // M-09 / B-01: Sync FileSystem to cover ALL attached projects.
        // After this, absolutePaths are resolved and projectPathMap can be built.
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

        // PRE-RESET: clear stale isUnavailable flags from any previously cancelled sync.
        // Without this, a project not reached in a cancelled loop stays orange permanently.
        for i in activeProjects.indices {
            activeProjects[i].isUnavailable = false
        }

        var workspaces: [(name: String, url: URL)] = []

        for i in activeProjects.indices {
            guard !Task.isCancelled else {
                // Paths already resolved up to this point — MCP still needs them.
                // Fall through to restartMCPIfNeeded() below instead of returning early.
                break
            }

            let project = activeProjects[i]

            guard let bookmarkData = try? await pStore.loadBookmark(forProjectId: project.id),
                  !bookmarkData.isEmpty else {
                print("[ChappieViewModel] M-09: No bookmark for '\(project.displayName)' — marked unavailable")
                activeProjects[i].isUnavailable = true
                activeProjects[i].absolutePath = nil
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
                // Yield to let macOS process the sandbox access grant before fileExists() check.
                await Task.yield()
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
                activeProjects[i].absolutePath = nil
                continue
            }

            // CRITICAL: stale bookmark means macOS re-routed it to a DIFFERENT folder — reject.
            if isStale {
                print("[ChappieViewModel] M-09: ⚠️ Stale bookmark for '\(project.displayName)' — macOS re-routed to '\(url.path)', rejecting")
                activeProjects[i].isUnavailable = true
                activeProjects[i].absolutePath = nil
                continue
            }

            if isURLStale(url) {
                print("[ChappieViewModel] M-09: ⚠️ Stale path for '\(project.displayName)' — marked unavailable (\(url.path))")
                activeProjects[i].isUnavailable = true
                activeProjects[i].absolutePath = nil
                continue
            }

            activeProjects[i].isUnavailable = false
            // Store the resolved absolute path — injected into system prompt AND used for git/terminal routing.
            activeProjects[i].absolutePath = url.path
            workspaces.append((name: project.displayName, url: url))
            print("[ChappieViewModel] M-09: ✅ '\(project.displayName)' → \(url.path)")
        }

        // WHY unconditional restart here:
        // Paths are already written into activeProjects above — MCP must get them regardless
        // of whether the Task was cancelled. Cancellation only guards FS wiring (wrong thread),
        // not path propagation to MCP. Without this, git_* tools see an empty projectPathMap.
        restartMCPIfNeeded()
        await syncActiveMemoryContext()

        // Guard FS wiring against cancellation — we don't want to wire the wrong thread's FS.
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

        let fs: FileSystemManager
        if workspaces.count == 1 {
            fs = FileSystemManager(workspaceURL: workspaces[0].url)
        } else {
            fs = FileSystemManager(workspaces: workspaces)
        }

        await ts.setFileSystem(fs)

        self.isFileSystemReady = true
        await ts.setFileSystemReady(true)

        // Rebuild ThreadSession with updated absolutePath values so the system prompt reflects them.
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

    // MARK: - Stale URL detection

    private func isURLStale(_ url: URL) -> Bool {
        let path = url.path
        if path.contains("/.Trash/") { return true }
        if path.contains("/.Trashes/") { return true }
        if !FileManager.default.fileExists(atPath: path) { return true }
        return false
    }
}
