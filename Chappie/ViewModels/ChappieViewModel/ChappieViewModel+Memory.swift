// ChappieViewModel+Memory.swift
// Chappie
//
// Memory context: build MemoryContext for system prompt, sync to ToolExecutionService.
//
// SETTINGS CHANGE FLOW:
//   updateProjectSettings → loadProjectsForThread → buildAndSyncMemoryContext
//   → rebuildThreadSessionOnly() — creates new ThreadSession with fresh projectMetas.
//
// WHY NOT invalidateCache():
//   ThreadSession captures projectMetas by value at init time (immutable let in actor).
//   Invalidating the cache only clears the built prompt string — old settings DTOs remain.
//   A full session rebuild is required to pick up new settings values.
//
// WHY NOT assembleThreadSession():
//   That triggers syncFileSystemForActiveThread() — expensive bookmark resolution
//   (100ms–1s per project). Unnecessary when only settings change, not project membership.
//
// MEMORY WRITE FLOW (memorize/recall tool calls during conversation):
//   ToolExecutionService.onMemoryChanged fires → invalidateActiveThreadSession()
//   clears the cached prompt immediately — no app restart needed.
//   projectMetas are unchanged, so invalidation (not full rebuild) is sufficient.
//
// PROJECT PATH MAP:
//   projectPathMap (name → absolutePath) is included in ActiveMemoryContext so
//   run_terminal can prefix commands with `cd /path && ` for deterministic execution.
//   Populated from activeProjects.absolutePath — available after bookmark resolution.
//
// TERMINAL ACCESS:
//   threadTerminalAccess is passed from activeThreadSettings to ActiveMemoryContext
//   so ToolDefinitions and ToolPolicy can read it without touching project settings.
//
// ATOMIC CONTEXT+SETTINGS UPDATE:
//   setMemoryContextAndSettings() writes both ActiveMemoryContext and projectSettingsCache
//   in a single actor hop — eliminating the race window where availableTools was computed
//   with projects present but an empty settings cache (isProg=false → git tools dropped).

import ChappieCore

extension ChappieViewModel {

    // MARK: - Build & Sync

    func buildAndSyncMemoryContext() {
        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(id: project.id, name: project.displayName, settings: project.settings)
        }
        self.activeMemoryContext = MemoryContext(threadId: activeThread?.id, projectInfos: projectInfos)

        // Rebuild ThreadSession with fresh projectMetas so new settings take effect immediately.
        // rebuildThreadSessionOnly skips bookmark resolution — safe for settings-only changes.
        if let thread = activeThread {
            Task { await rebuildThreadSessionOnly(for: thread) }
        }
    }

    func syncActiveMemoryContext() async {
        guard let ts = toolService else { return }

        let projectInfos = activeProjects.map { project in
            ActiveMemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }

        // Build projectPathMap from resolved absolutePaths — populated after FS sync.
        // WHY merge instead of uniqueKeysWithValues: if two projects share the same displayName
        // (possible after rename or duplicate add), uniqueKeysWithValues crashes with preconditionFailure.
        // merge(_:uniquingKeysWith:) is safe — last value wins, no crash.
        var pathMap: [String: String] = [:]
        for project in activeProjects {
            guard let path = project.absolutePath else { continue }
            pathMap[project.displayName] = path
        }

        let context = ActiveMemoryContext(
            threadId: activeThread?.id,
            projects: projectInfos,
            projectPathMap: pathMap,
            threadTerminalAccess: activeThreadSettings.terminalAccess
        )

        // Project settings for ToolPolicy — must arrive together with context.
        let settingsMap = Dictionary(uniqueKeysWithValues: activeProjects.map { ($0.id, $0.settings) })

        // WHY atomic: writing context then settings as two separate actor hops creates a window
        // where availableTools is computed with projects present but projectSettingsCache empty.
        // In that window isProg=false and all git/build tools (incl. git_push) vanish from the
        // tool list sent to the AI. One call = one hop = no window.
        await ts.setMemoryContextAndSettings(context: context, settings: settingsMap)

        // Register callback so memory writes immediately invalidate the cached system prompt.
        // This ensures memorize/delete_memory changes are visible in the very next message.
        await ts.setOnMemoryChanged { [weak self] in
            self?.invalidateActiveThreadSession()
        }
    }
}
