// ChappieViewModel+Memory.swift
// Chappie
//
// Memory context: build MemoryContext for system prompt, sync to ToolExecutionService.

import ChappieCore

extension ChappieViewModel {

    // MARK: - Build & Sync

    func buildAndSyncMemoryContext() {
        let projectInfos = activeProjects.map { project in
            MemoryContext.ProjectInfo(id: project.id, name: project.displayName, settings: project.settings)
        }
        self.activeMemoryContext = MemoryContext(threadId: activeThread?.id, projectInfos: projectInfos)
    }

    func syncActiveMemoryContext() async {
        guard let ts = toolService else { return }

        let projectInfos = activeProjects.map { project in
            ActiveMemoryContext.ProjectInfo(id: project.id, name: project.displayName)
        }
        let context = ActiveMemoryContext(threadId: activeThread?.id, projects: projectInfos)
        await ts.setActiveMemoryContext(context)

        // Also push project settings so ToolExecutionService can enforce permissions
        let settingsMap = Dictionary(uniqueKeysWithValues: activeProjects.map { ($0.id, $0.settings) })
        await ts.setProjectSettings(settingsMap)
    }
}
