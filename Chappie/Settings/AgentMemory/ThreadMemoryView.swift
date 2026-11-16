// ThreadMemoryView.swift
// Chappie
//
// One thread inside the agent memory flow: the thread's own memory, then the projects attached
// to it. Each project memory is separate per attachment (the same folder in two threads is two
// memories), which is why projects are listed under the thread and not globally.

import SwiftUI
import ChappieCore

// MARK: - ThreadMemoryView

struct ThreadMemoryView: View {

    var viewModel: ChappieViewModel
    let thread: ThreadMetadata

    @State private var threadCount: Int?
    @State private var projectCounts: [UUID: Int] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                threadSection
                projectsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(Text(verbatim: threadTitle))
        .task { await loadCounts() }
    }

    private var threadTitle: String {
        String(format: String(localized: "agent_memory.thread_title"), thread.title)
    }

    // MARK: - Sections

    private var threadSection: some View {
        AgentMemoryNavRow(
            title: threadTitle,
            hint: "agent_memory.thread_hint",
            count: threadCount,
            route: .editor(scope: .thread(thread.id), title: threadTitle)
        )
    }

    @ViewBuilder
    private var projectsSection: some View {
        if !thread.projects.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AgentMemorySectionHeader(
                    title: "agent_memory.projects_title",
                    hint: "agent_memory.projects_hint"
                )
                ForEach(thread.projects) { project in
                    AgentMemoryNavRow(
                        title: project.displayName,
                        count: projectCounts[project.id],
                        route: .editor(scope: .project(project.id), title: project.displayName)
                    )
                }
            }
        }
    }

    // MARK: - Counts

    private func loadCounts() async {
        threadCount = await viewModel.loadMemoryEntries(scope: .thread(thread.id)).count
        for project in thread.projects {
            projectCounts[project.id] = await viewModel.loadMemoryEntries(scope: .project(project.id)).count
        }
    }
}
