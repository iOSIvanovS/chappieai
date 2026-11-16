// AgentMemoryView.swift
// Chappie
//
// Root of the "Agent memory management" flow, shown as a sheet from Settings.
// ONE NavigationStack serves the whole drill-down (root -> thread -> project -> editor), so
// "Back" always returns one level instead of closing everything.
//
//   root:   global memory row + list of threads
//   thread: that thread's memory row + list of its attached projects
//   editor: MemoryEntriesEditorView for the chosen scope

import SwiftUI
import ChappieCore

// MARK: - AgentMemoryView

struct AgentMemoryView: View {

    var viewModel: ChappieViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var globalCount: Int?
    @State private var threadCounts: [UUID: Int] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    globalSection
                    threadsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle(Text("agent_memory.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("settings.close") { dismiss() }
                        .keyboardShortcut(.escape)
                }
            }
            .navigationDestination(for: AgentMemoryRoute.self) { route in
                destination(for: route)
            }
        }
        .frame(width: 540, height: 520)
        .task { await loadCounts() }
    }

    // MARK: - Sections

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentMemoryNavRow(
                title: String(localized: "agent_memory.global_title"),
                hint: "agent_memory.global_hint",
                count: globalCount,
                route: .editor(scope: .global, title: String(localized: "agent_memory.global_title"))
            )
        }
    }

    private var threadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentMemorySectionHeader(
                title: "agent_memory.threads_title",
                hint: "agent_memory.threads_hint"
            )
            if viewModel.threads.isEmpty {
                Text("sidebar.no_threads")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(viewModel.threads) { thread in
                    AgentMemoryNavRow(
                        title: thread.title,
                        count: threadCounts[thread.id],
                        route: .thread(thread)
                    )
                }
            }
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func destination(for route: AgentMemoryRoute) -> some View {
        switch route {
        case .editor(let scope, let title):
            MemoryEntriesEditorView(viewModel: viewModel, scope: scope)
                .navigationTitle(Text(verbatim: title))
        case .thread(let thread):
            ThreadMemoryView(viewModel: viewModel, thread: thread)
        }
    }

    // MARK: - Counts

    private func loadCounts() async {
        globalCount = await viewModel.loadMemoryEntries(scope: .global).count
        for thread in viewModel.threads {
            threadCounts[thread.id] = await viewModel.loadMemoryEntries(scope: .thread(thread.id)).count
        }
    }
}
