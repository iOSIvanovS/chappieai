// MemoryManagementView.swift
// Chappie
//
// Screen for managing thread message history storage.
// Shows per-thread message count and size in MB.

import SwiftUI
import ChappieCore

// MARK: - MemoryManagementView

struct MemoryManagementView: View {

    // MARK: - Dependencies

    var viewModel: ChappieViewModel

    // MARK: - State

    @State var memoryInfos: [ThreadMemoryInfo] = []
    @State var isLoading = true
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
                    Text(ByteCountFormatter.string(fromByteCount: Int64(info.sizeBytes), countStyle: .binary))
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
}
