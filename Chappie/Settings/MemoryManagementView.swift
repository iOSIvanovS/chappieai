// MemoryManagementView.swift
// Chappie
//
// Memory management screen — shows all threads with message count and size,
// lets user delete oldest N messages from any thread via a slider + confirmation alert.

import SwiftUI
import ChappieCore

// MARK: - ThreadMemoryInfo

private struct ThreadMemoryInfo: Identifiable {
    let id: UUID
    let title: String
    let messageCount: Int
    let bytes: Int

    var megabytes: Double { Double(bytes) / (1024 * 1024) }
    var sizeLabel: String {
        if bytes < 1024 { return "\(bytes) Б" }
        if bytes < 1024 * 1024 { return String(format: "%.1f КБ", Double(bytes) / 1024) }
        return String(format: "%.2f МБ", megabytes)
    }
}

// MARK: - MemoryManagementView

struct MemoryManagementView: View {

    var viewModel: ChappieViewModel

    @State private var threads: [ThreadMemoryInfo] = []
    @State private var isLoading = true

    // Deletion state
    @State private var deletionTarget: ThreadMemoryInfo? = nil
    @State private var deleteCount: Double = 0
    @State private var showDeleteAlert = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if isLoading {
                loadingView
            } else if threads.isEmpty {
                emptyView
            } else {
                threadListView
            }
        }
        .frame(width: 560, height: 500)
        .onAppear { loadStats() }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Управление памятью")
                    .font(.headline)
                Text("История сообщений хранится полностью. Удаляйте старые сообщения вручную.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView("Загрузка…")
            Spacer()
        }
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("Нет тредов")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Thread List

    private var threadListView: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(threads) { thread in
                    threadRow(thread)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func threadRow(_ thread: ThreadMemoryInfo) -> some View {
        HStack(spacing: 12) {
            // Thread info
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title.isEmpty ? "Без названия" : thread.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Label("\(thread.messageCount) сообщ.", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(thread.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Delete button — only shown if there are messages to delete
            if thread.messageCount > 0 {
                Button {
                    deletionTarget = thread
                    // Default slider: half of messages, min 1
                    deleteCount = max(1, Double(thread.messageCount / 2))
                    showDeleteAlert = true
                } label: {
                    Label("Очистить", systemImage: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            } else {
                Text("Пусто")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .sheet(item: $deletionTarget) { target in
            deletionSheet(for: target)
        }
    }

    // MARK: - Deletion Sheet

    @ViewBuilder
    private func deletionSheet(for thread: ThreadMemoryInfo) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "trash.fill")
                    .foregroundStyle(.red)
                Text("Удалить старые сообщения")
                    .font(.headline)
                Spacer()
                Button {
                    deletionTarget = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Thread name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Тред:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(thread.title.isEmpty ? "Без названия" : thread.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(2)
                }

                // Slider
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Удалить старых сообщений:")
                            .font(.callout)
                        Spacer()
                        Text("\(Int(deleteCount))")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.red)
                            .frame(minWidth: 44, alignment: .trailing)
                    }

                    Slider(
                        value: $deleteCount,
                        in: 1...Double(max(1, thread.messageCount)),
                        step: 1
                    )
                    .tint(.red)

                    HStack {
                        Text("1")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(thread.messageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Info box
                VStack(alignment: .leading, spacing: 6) {
                    let remaining = thread.messageCount - Int(deleteCount)
                    infoRow(
                        icon: "trash",
                        color: .red,
                        text: "Будет удалено: \(Int(deleteCount)) старых сообщений"
                    )
                    infoRow(
                        icon: "checkmark.circle",
                        color: .green,
                        text: "Останется: \(remaining) сообщений"
                    )
                    infoRow(
                        icon: "exclamationmark.triangle",
                        color: .orange,
                        text: "Удаление необратимо. Восстановить сообщения невозможно."
                    )
                }
                .padding(12)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Button("Отмена") {
                    deletionTarget = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    showDeleteAlert = true
                } label: {
                    Label("Удалить \(Int(deleteCount)) сообщений", systemImage: "trash.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(deleteCount < 1)
            }
            .padding(16)
        }
        .frame(width: 420)
        .alert("Удалить сообщения?", isPresented: $showDeleteAlert) {
            Button("Удалить", role: .destructive) {
                performDeletion(threadId: thread.id, count: Int(deleteCount))
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будет удалено \(Int(deleteCount)) старых сообщений из треда «\(thread.title.isEmpty ? "Без названия" : thread.title)». Это действие необратимо.")
        }
    }

    // MARK: - Helpers

    private func infoRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func loadStats() {
        Task {
            let result = await viewModel.loadThreadMemoryStats()
            await MainActor.run {
                threads = result.map {
                    ThreadMemoryInfo(
                        id: $0.id,
                        title: $0.title,
                        messageCount: $0.messageCount,
                        bytes: $0.bytes
                    )
                }
                isLoading = false
            }
        }
    }

    private func performDeletion(threadId: UUID, count: Int) {
        Task {
            await viewModel.deleteOldestMessages(count: count, fromThreadId: threadId)
            deletionTarget = nil
            // Reload stats after deletion
            isLoading = true
            loadStats()
        }
    }
}
