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
        let context = ActiveMemoryContext(threadId: activeThread?.id, projects: projectInfos)
        await ts.setActiveMemoryContext(context)

        // Push project settings so ToolExecutionService can enforce permissions.
        let settingsMap = Dictionary(uniqueKeysWithValues: activeProjects.map { ($0.id, $0.settings) })
        await ts.setProjectSettings(settingsMap)

        // Register callback so memory writes immediately invalidate the cached system prompt.
        // This ensures memorize/delete_memory changes are visible in the very next message.
        await ts.setOnMemoryChanged { [weak self] in
            self?.invalidateActiveThreadSession()
        }
    }
}
