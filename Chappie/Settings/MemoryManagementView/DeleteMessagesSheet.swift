// DeleteMessagesSheet.swift
// Chappie
//
// Sheet with a slider to pick how many oldest messages to delete.

import SwiftUI
import ChappieCore

// MARK: - DeleteMessagesSheet

struct DeleteMessagesSheet: View {

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
                    statBox(value: ByteCountFormatter.string(fromByteCount: Int64(threadInfo.sizeBytes), countStyle: .binary), label: String(localized: "memory.stat_size"))
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

    // MARK: - Stat Box

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
