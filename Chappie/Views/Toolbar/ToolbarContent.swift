// ToolbarContent.swift
// Chappie
//
// Toolbar content for the main window.
// Contains: sidebar toggle button, settings button.
//
// SIDEBAR BUTTON:
// Custom button with "list.bullet" icon — replaces the system NavigationSplitView
// toggle. Placed on the leading edge to match standard macOS sidebar button position.
//
// BALANCE:
// Balance is now displayed as a floating pill inside ModelPickerRow (top panel),
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
