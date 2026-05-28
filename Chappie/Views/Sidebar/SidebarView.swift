// SidebarView.swift
// Chappie
//
// Custom overlay sidebar — floats over chat content instead of pushing it.
// Implemented as a standalone VStack with ultraThinMaterial + cornerRadius.
// No NavigationSplitView dependency — full control over appearance and behavior.
//
// LAYOUT (top to bottom):
// 1. Header: "Треды" title + "Новый" button (right side) — pinned to top.
// 2. Thread list — scrollable, fills remaining space.
// 3. API key warning section — shown only when no providers configured.
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
    /// Opens ThreadSettingsSheet for the given thread (handled in ContentView).
    let onOpenThreadSettings: (ThreadMetadata) -> Void
    /// Called when user taps outside the sidebar to dismiss it
    let onDismiss: () -> Void

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // HEADER: title + new thread button — always visible at the top
            sidebarHeader

            Divider()
                .opacity(0.5)

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
                            onRename: onRenameThread,
                            onOpenSettings: { thread in
                                // Don't dismiss sidebar — sheet opens on top
                                onOpenThreadSettings(thread)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                if !isApiKeyValid {
                    apiKeyWarningSection
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)
            .scrollIndicators(.never)
        }
        // ultraThinMaterial — frosted glass, consistent with toolbar and input panel
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Header

    /// Top bar with "Треды" label and "Новый" button for creating a new thread.
    /// Placed above the list so it's always accessible without scrolling.
    private var sidebarHeader: some View {
        HStack {
            Text("Треды")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            // New thread button — top right, labelled for clarity
            Button(action: {
                onCreateThread()
                onDismiss()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                    Text("Новый")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("Новый тред")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
