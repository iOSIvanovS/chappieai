// MemoryManagementView.swift
// Chappie
//
// Screen for managing thread message history storage.
// Shows per-thread message count and size in MB.
// User picks how many oldest messages to delete via a slider, then confirms.

import SwiftUI
import ChappieCore

// MARK: - MemoryManagementView

struct MemoryManagementView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State private var memoryInfos: [ThreadMemoryInfo] = []
    @State private var isLoading = true
    @State private var selectedThread: ThreadMemoryInfo? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("settings.memory_manage")
                    .font(.title2.bold())
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            if isLoading {
                Spacer()
                HStack { Spacer(); ProgressView(); Spacer() }
                Spacer()
            } else if memoryInfos.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary.opacity(0.4))
                        Text("sidebar.no_threads")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                threadList
            }

            Divider()

            HStack {
                let totalMessages = memoryInfos.reduce(0) { $0 + $1.messageCount }
                let totalMB = memoryInfos.reduce(0.0) { $0 + $1.sizeMB }
                Text(String(format: String(localized: "memory.total_size"), totalMessages, String(format: "%.2f", totalMB)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("settings.close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 480)
        .sheet(item: $selectedThread) { info in
            DeleteMessagesSheet(
                threadInfo: info,
                onDelete: { count in
                    deleteMessages(count: count, from: info)
                }
            )
        }
        .onAppear { loadMemoryInfo() }
    }

    // MARK: - Thread List

    private var threadList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(memoryInfos) { info in
                    threadRow(info)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func threadRow(_ info: ThreadMemoryInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(String(format: String(localized: "format.messages_count"), info.messageCount), systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("common.separator_dot")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(String(format: "%.2f МБ", info.sizeMB))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                selectedThread = info
            } label: {
                HStack(spacing: 4) {
                    Text("memory.details")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(info.messageCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private func loadMemoryInfo() {
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

    private func deleteMessages(count: Int, from info: ThreadMemoryInfo) {
        Task {
            guard let store = viewModel.threadStore else { return }
            try? await store.deleteOldMessages(
                count: count,
                fromThreadId: info.threadId,
                as: ChatMessage.self
            )
            // Reload active thread messages if it's the one being cleaned
            if viewModel.activeThread?.id == info.threadId {
                if let loaded = try? await store.loadMessages(fromThreadId: info.threadId, as: ChatMessage.self) {
                    viewModel.messages = loaded
                    viewModel.resetPagination(fireScrollTrigger: true)
                }
            }
            loadMemoryInfo()
        }
    }
}

// MARK: - DeleteMessagesSheet

/// Sheet with a slider to pick how many oldest messages to delete.
private struct DeleteMessagesSheet: View {

    let threadInfo: ThreadMemoryInfo
    let onDelete: (Int) -> Void

    @State private var sliderValue: Double = 0
    @State private var showConfirm = false
    @Environment(\.dismiss) private var dismiss

    private var deleteCount: Int { Int(sliderValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("memory.clear_history")
                        .font(.headline)
                    Text(threadInfo.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 20) {

                // Stats
                HStack(spacing: 24) {
                    statBox(value: "\(threadInfo.messageCount)", label: String(localized: "memory.stat_total"))
                    statBox(value: String(format: "%.2f МБ", threadInfo.sizeMB), label: String(localized: "memory.stat_size"))
                }

                // Slider
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("memory.delete_label")
                            .font(.callout)
                        Spacer()
                        Text(deleteCount == 0 ? String(localized: "memory.keep_all") : "\(deleteCount)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(deleteCount > 0 ? .red : .secondary)
                            .frame(minWidth: 80, alignment: .trailing)
                    }

                    Slider(
                        value: $sliderValue,
                        in: 0...Double(threadInfo.messageCount),
                        step: 1
                    )
                    .accentColor(.red)

                    HStack {
                        Text("0")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "\(threadInfo.messageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Warning — shown only when slider is moved
                if deleteCount > 0 {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 13))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("memory.irreversible_warning")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(String(format: String(localized: "memory.delete_warning"), deleteCount, threadInfo.title))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(String(format: String(localized: "memory.delete_count"), deleteCount)) {
                    showConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(deleteCount == 0)
            }
            .padding(20)
        }
        .frame(width: 460)
        .alert(String(format: String(localized: "memory.delete_confirm_title"), deleteCount), isPresented: $showConfirm) {
            Button("common.delete", role: .destructive) {
                onDelete(deleteCount)
                dismiss()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "memory.delete_confirm_message"), deleteCount, threadInfo.title))
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
