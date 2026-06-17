// ProjectStore.swift
// ChappieCore
//
// Minimal store kept solely for license enforcement.
// Project attachment is thread-scoped via ThreadStore — ProjectStore has no role there.
//
// WHY STILL EXISTS:
// downgradeAllProjectsToAdvisor() is called when a Starter license is activated.
// It iterates all threads and downgrades any Executor project to Advisor.

import Foundation

// MARK: - ProjectStore

public actor ProjectStore {

    private let dataStore: any ChappieStorage
    private let threadStore: ThreadStore

    public init(dataStore: any ChappieStorage, threadStore: ThreadStore) {
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
