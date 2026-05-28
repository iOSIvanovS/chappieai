// ToolbarContent.swift
// Chappie
//
// Toolbar content for the main window.
// Contains: sidebar toggle, thread title, settings button.
//
// THREAD TITLE:
// Displayed in the center of the toolbar as "Chappie — <thread name>".
// Uses ToolbarItem(placement: .principal) — standard macOS center placement.
// Hidden when no thread is active (e.g. onboarding state).
//
// SIDEBAR BUTTON:
// Custom button with "list.bullet" icon — replaces the system NavigationSplitView
// toggle. Placed on the leading edge to match standard macOS sidebar button position.
//
// BALANCE:
// Balance is displayed as a floating pill inside ModelPickerRow (top panel),
// tied to the active provider. It updates live during streaming.
//
// SETTINGS BUTTON:
// Always visible. Turns orange when no AI provider is configured.

import SwiftUI

/// Toolbar content for the main Chappie window.
struct ChappieToolbarContent: ToolbarContent {

    /// True if at least one provider is configured
    let isApiKeyValid: Bool
    /// Sidebar visibility binding — toggled by the leading button
    @Binding var isSidebarVisible: Bool
    /// Active thread title — shown next to "Chappie" in the toolbar center.
    /// nil = no thread active (onboarding), title is hidden.
    let activeThreadTitle: String?
    /// Callback: user tapped the settings button
    let onOpenSettings: () -> Void

    var body: some ToolbarContent {

        // Sidebar toggle — leading edge, matches standard macOS sidebar button position
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .help("Показать / скрыть треды")
        }

        // Thread title — center of toolbar.
        // Shows "Chappie — <thread name>" so the user always knows which thread is active.
        if let title = activeThreadTitle {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("Chappie")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("—")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 300)
                }
            }
        }

        // Settings button — always visible, orange if no provider configured
        ToolbarItem(placement: .primaryAction) {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gear")
            }
            .help("Настройки Чаппи")
            // VISUAL SIGNAL: orange gear = no provider configured
            .foregroundStyle(
                isApiKeyValid
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(.orange)
            )
        }
    }
}
