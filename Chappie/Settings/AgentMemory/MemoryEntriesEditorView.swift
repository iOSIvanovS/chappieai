// MemoryEntriesEditorView.swift
// Chappie
//
// The reusable memory editor: a list of entries of ONE scope with a trash button per entry.
// The same view serves global memory, thread memory and project memory — only `scope` differs.
//
// It is a content view without its own header or close button: the screens that host it
// (inside a NavigationStack) provide the title and the way back.
//
// Deletion always goes through ChappieViewModel.deleteMemoryEntry, never straight to the store,
// because the cached system prompt has to be dropped in the same moment.

import SwiftUI
import ChappieCore

// MARK: - MemoryEntriesEditorView

struct MemoryEntriesEditorView: View {

    var viewModel: ChappieViewModel
    let scope: MemoryScope

    @State private var entries: [MemoryEntry] = []
    @State private var isLoading = true
    @State private var pendingDeletion: MemoryEntry?
    @State private var errorMessage: String?

    var body: some View {
        content
            .task(id: scope) { await reload() }
            .alert(
                "agent_memory.delete_title",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { entry in
                Button("common.delete", role: .destructive) {
                    Task { await delete(entry) }
                }
                Button("common.cancel", role: .cancel) {}
            } message: { entry in
                Text(confirmationText(for: entry))
            }
            .alert(
                "agent_memory.delete_failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("settings.close", role: .cancel) {}
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            HStack { Spacer(); ProgressView(); Spacer() }
                .frame(maxHeight: .infinity)
        } else if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.4))
                Text("agent_memory.empty")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(entries) { entry in
                        MemoryEntryRow(entry: entry) { pendingDeletion = entry }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        entries = await viewModel.loadMemoryEntries(scope: scope)
        isLoading = false
    }

    private func delete(_ entry: MemoryEntry) async {
        if let error = await viewModel.deleteMemoryEntry(key: entry.key, scope: scope) {
            errorMessage = error
            return
        }
        // Reload instead of removing locally: the store may hold another record with the same
        // key (restored backup) and the list must show what is really still there.
        await reload()
    }

    private func confirmationText(for entry: MemoryEntry) -> String {
        // Each key is a separate literal so Xcode's string extraction can see both of them.
        let format: String
        if scope == .global {
            format = String(localized: "agent_memory.delete_message_global")
        } else {
            format = String(localized: "agent_memory.delete_message")
        }
        return String(format: format, entry.key)
    }
}
