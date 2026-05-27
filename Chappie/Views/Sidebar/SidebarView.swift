// SidebarView.swift
// Chappie
//
// Custom overlay sidebar — floats over chat content instead of pushing it.
// Implemented as a standalone VStack with ultraThinMaterial + cornerRadius.
// No NavigationSplitView dependency — full control over appearance and behavior.
//
// PRINCIPLE "DUMB COMPONENT":
// SidebarView doesn't know about ThreadStore or SwiftData.
// All data comes via parameters, all actions via callbacks.
// Business logic lives in ChappieViewModel.

import SwiftUI
import ChappieCore

// MARK: - SidebarView

/// Floating overlay sidebar for thread navigation.
///
/// Slides in from the left over the chat area.
/// Dismissed by tapping the dimmed overlay behind it.
struct SidebarView: View {

    // MARK: - Input

    let isApiKeyValid: Bool
    let threads: [ThreadMetadata]
    let selectedThreadId: UUID?
    /// Thread IDs whose provider or model was deleted — shown with ⚠️ indicator.
    let orphanedThreadIds: Set<UUID>

    // MARK: - Callbacks

    let onOpenSettings: () -> Void
    let onSelectThread: (ThreadMetadata) -> Void
    let onCreateThread: () -> Void
    let onDeleteThread: (ThreadMetadata) -> Void
    let onRenameThread: (ThreadMetadata, String) -> Void
    /// Called when user taps outside the sidebar to dismiss it
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // Thread list — scrollable
            List {
                Section {
                    if threads.isEmpty {
                        Text("Нет тредов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    } else {
                        ThreadListView(
                            threads: threads,
                            selectedThreadId: selectedThreadId,
                            orphanedThreadIds: orphanedThreadIds,
                            onSelect: { thread in
                                onSelectThread(thread)
                                onDismiss()
                            },
                            onDelete: onDeleteThread,
                            onRename: onRenameThread
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    Text("Треды")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }

                if !isApiKeyValid {
                    apiKeyWarningSection
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)
            .scrollIndicators(.never)

            // "New Thread" button pinned to the bottom
            Button(action: {
                onCreateThread()
                onDismiss()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("Новый тред")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        // ultraThinMaterial — frosted glass, consistent with toolbar and input panel
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        // Clip to the rounded shape
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - API Key Warning

    private var apiKeyWarningSection: some View {
        Section("⚠️ Внимание") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Нет настроенных провайдеров")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)

                Text("Без AI-провайдера Чаппи не сможет отвечать.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Открыть настройки") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }
}
