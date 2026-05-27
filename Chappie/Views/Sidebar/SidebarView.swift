// SidebarView.swift
// Chappie
//
// Sidebar — thread navigation (IT-05).
//
// IT-10 (providers refactor): receives orphanedThreadIds to show ⚠️ on affected threads.
//
// PRINCIPLE "DUMB COMPONENT":
// SidebarView doesn't know about ThreadStore or SwiftData.
// All data comes via parameters, all actions via callbacks.
// Business logic lives in ChappieViewModel.

import SwiftUI
import ChappieCore

// MARK: - SidebarView

/// Sidebar of the Chappie app.
///
/// Shows:
/// - list of threads (IT-05) — main content
/// - warning if no providers configured
/// - "New Thread" button at the bottom
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

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

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
                            onSelect: onSelectThread,
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
            // Hide scrollbar — consistent with chat scroll view
            .scrollIndicators(.never)

            Button(action: onCreateThread) {
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
        // ultraThinMaterial matches toolbar and input panel — unified glass aesthetic
        .background(.ultraThinMaterial)
        .navigationTitle("Чаппи")
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

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView(
            isApiKeyValid: true,
            threads: [
                ThreadMetadata(
                    id: UUID(),
                    title: "Рефакторинг тредов",
                    createdAt: Date().addingTimeInterval(-3600),
                    updatedAt: Date().addingTimeInterval(-600),
                    projectIds: []
                ),
                ThreadMetadata(
                    id: UUID(),
                    title: "Исправление багов SwiftData",
                    createdAt: Date().addingTimeInterval(-7200),
                    updatedAt: Date().addingTimeInterval(-3600),
                    projectIds: []
                )
            ],
            selectedThreadId: nil,
            orphanedThreadIds: [],
            onOpenSettings: {},
            onSelectThread: { _ in },
            onCreateThread: {},
            onDeleteThread: { _ in },
            onRenameThread: { _, _ in }
        )
    } detail: {
        Text("Detail")
    }
}
