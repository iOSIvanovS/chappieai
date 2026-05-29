// ToolbarContent.swift
// Chappie
//
// Toolbar content for the main window.
// Contains: sidebar toggle and settings button.
//
// THREAD TITLE (IT-12):
// Thread name is NO LONGER shown in the toolbar.
// It is now displayed inside the ProjectChipsView gear chip (right side),
// as "⚙ <thread name>" — visible, compact, and directly actionable.
// This avoids toolbar overflow on narrow windows and update glitches.
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
//
// SOFT LOCK (IT-13):
// When isThinking == true — both toolbar buttons are locked via shakeOnTap().
// Tapping them triggers a spring-shake animation ("I don't want to be pressed!")
// instead of the old opacity(0.5) dimming — buttons stay fully visible.
// shakeOnTap() uses allowsHitTesting(false) internally — NOT .disabled() —
// to avoid SwiftUI's automatic opacity(0.5) side effect.

import SwiftUI

/// Toolbar content for the main Chappie window.
struct ChappieToolbarContent: ToolbarContent {

    /// True if at least one provider is configured
    let isApiKeyValid: Bool
    /// Sidebar visibility binding — toggled by the leading button
    @Binding var isSidebarVisible: Bool
    /// When true — both toolbar buttons are locked (AI is responding)
    let isThinking: Bool
    /// Callback: user tapped the settings button
    let onOpenSettings: () -> Void

    var body: some ToolbarContent {

        // Sidebar toggle — leading edge, matches standard macOS sidebar button position.
        // Locked while AI is responding — shake on tap instead of dimming (IT-13).
        // Uses shakeOnTap (allowsHitTesting) instead of .disabled() to keep full opacity.
        ToolbarItem(placement: .navigation) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .shakeOnTap(isLocked: isThinking)
            .help(isThinking ? "Нельзя открыть сайдбар пока Чаппи думает" : "Показать / скрыть треды")
        }

        // Settings button — always visible, orange if no provider configured.
        // Locked while AI is responding — shake on tap instead of dimming (IT-13).
        // Uses shakeOnTap (allowsHitTesting) instead of .disabled() to keep full opacity.
        ToolbarItem(placement: .primaryAction) {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gear")
            }
            .shakeOnTap(isLocked: isThinking)
            .help(isThinking ? "Нельзя открыть настройки пока Чаппи думает" : "Настройки Чаппи")
            // VISUAL SIGNAL: orange gear = no provider configured
            .foregroundStyle(
                isApiKeyValid
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(.orange)
            )
        }
    }
}
