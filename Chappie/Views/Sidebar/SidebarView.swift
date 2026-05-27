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
//
// TRANSPARENT SIDEBAR:
// macOS NavigationSplitView renders sidebar with a system NSVisualEffectView background.
// We walk the NSView hierarchy upward to find the NSSplitViewItem container,
// then locate its direct NSVisualEffectView child and make it transparent —
// so the app's background image shows through the sidebar column.

import SwiftUI
import AppKit
import ChappieCore

// MARK: - Transparent Sidebar Background

/// Zero-size NSView that, once placed in the hierarchy, walks upward to find
/// the NSSplitViewItem's background NSVisualEffectView and clears it.
private struct TransparentSidebarBackground: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let marker = NSView()
        marker.frame = .zero
        DispatchQueue.main.async {
            Self.clearSidebarEffectView(startingFrom: marker)
        }
        return marker
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Walks up the view tree. When we reach a NSSplitView we know we've
    /// crossed the sidebar boundary. We then look for the first
    /// NSVisualEffectView that is a *direct* child of the NSSplitView —
    /// that is the sidebar background panel — and make it transparent.
    private static func clearSidebarEffectView(startingFrom view: NSView) {
        var current: NSView? = view.superview
        while let v = current {
            if v is NSSplitView {
                // The sidebar background is the first NSVisualEffectView
                // that is a direct subview of NSSplitView
                for sub in v.subviews {
                    if let effect = sub as? NSVisualEffectView {
                        effect.material = .underWindowBackground
                        effect.blendingMode = .behindWindow
                        effect.alphaValue = 0
                        break
                    }
                }
                return
            }
            current = v.superview
        }
    }
}

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

            Divider()

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
            .background(Color.primary.opacity(0.03))
        }
        .navigationTitle("Чаппи")
        // Inject transparent background helper — clears the sidebar NSVisualEffectView
        .background(TransparentSidebarBackground())
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
