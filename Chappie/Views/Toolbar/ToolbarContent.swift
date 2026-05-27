// ToolbarContent.swift
// Chappie
//
// Toolbar content for the main window.
// Contains: sidebar toggle button, balance indicator, settings button.
//
// SIDEBAR BUTTON:
// Custom button with "list.bullet" icon — replaces the system NavigationSplitView
// toggle. Placed on the leading edge to match standard macOS sidebar button position.
//
// BALANCE PILL:
// Shown only when balance is loaded — avoids showing "0 ₽" on startup.
//
// SETTINGS BUTTON:
// Always visible. Turns orange when no AI provider is configured.

import SwiftUI

/// Toolbar content for the main Chappie window.
struct ChappieToolbarContent: ToolbarContent {

    /// Current balance in rubles (nil if not yet loaded)
    let balance: Double?
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

        // Balance pill — shown only when loaded
        if let balance = balance {
            ToolbarItem(placement: .primaryAction) {
                balanceView(balance: balance)
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

    // MARK: - Private

    /// Balance pill with card icon and amount.
    private func balanceView(balance: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "creditcard.fill")
                .foregroundColor(.green)
            Text(String(format: "%.2f ₽", balance))
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }
}
