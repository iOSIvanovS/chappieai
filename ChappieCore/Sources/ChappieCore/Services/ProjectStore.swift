// ProjectStore.swift
// ChappieCore
//
// Minimal store kept solely for license enforcement.
// Project attachment is now thread-scoped via ThreadStore — ProjectStore has no role there.
//
// WHY STILL EXISTS:
// downgradeAllProjectsToAdvisor() is called when a Starter license is activated.
// It must iterate all threads and downgrade any Executor project to Advisor.
// This operation lives here to keep license logic out of ThreadStore.

import Foundation

// MARK: - ProjectStore

public actor ProjectStore {

    private let dataStore: ChappieDataStore
    private let threadStore: ThreadStore

    public init(dataStore: ChappieDataStore, threadStore: ThreadStore) {
        self.dataStore = dataStore
        self.threadStore = threadStore
    }

    // MARK: - Downgrade all projects to Advisor (Starter plan enforcement)

    /// Resets ALL projects across ALL threads to .advisor role, clearing all access flags.
    /// Called when a Starter license is activated — Starter plan forbids Executor mode.
    public func downgradeAllProjectsToAdvisor() async throws {
        let threads = try await threadStore.loadThreads()
        for thread in threads {
            var changed = false
            var updatedProjects = thread.projects
            for idx in updatedProjects.indices {
                if updatedProjects[idx].settings.agentRole == .executor {
                    updatedProjects[idx].settings.downgradeToAdvisor()
                    changed = true
                }
            }
            guard changed else { continue }
            for entry in updatedProjects {
                try await threadStore.updateProjectSettings(
                    entry.settings,
                    projectId: entry.id,
                    threadId: thread.id
                )
            }
        }
        print("[ProjectStore] ✅ All projects downgraded to Advisor (Starter plan)")
    }
}
