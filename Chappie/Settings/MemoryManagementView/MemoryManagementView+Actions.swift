// MemoryManagementView+Actions.swift
// Chappie
//
// Async actions: load memory stats, delete old messages.

import ChappieCore

extension MemoryManagementView {

    func loadMemoryInfo() {
        isLoading = true
        Task {
            guard let store = viewModel.threadStore else {
                isLoading = false
                return
            }
            let infos = (try? await store.loadMemoryInfo()) ?? []
            self.memoryInfos = infos
            self.isLoading = false
        }
    }

    func deleteMessages(count: Int, from info: ThreadMemoryInfo) {
        Task {
            guard let store = viewModel.threadStore else { return }
            try? await store.deleteOldMessages(
                count: count,
                fromThreadId: info.threadId,
                as: ChatMessage.self
            )
            // Reload active thread messages if it's the one being cleaned.
            // Use loadAllMessages — we need the full set to rebuild the in-memory state.
            if viewModel.activeThread?.id == info.threadId {
                if let loaded = try? await store.loadAllMessages(fromThreadId: info.threadId, as: ChatMessage.self) {
                    viewModel.messages = loaded
                    viewModel.hasMoreChunks = false
                    viewModel.oldestLoadedChunkIndex = nil
                    viewModel.resetPagination(fireScrollTrigger: true)
                }
            }
            loadMemoryInfo()
        }
    }
}
