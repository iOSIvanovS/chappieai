// NewThreadProviderSheet.swift
// Chappie
//
// IT-10: Intermediate sheet shown when creating a new thread.
// Lets the user pick which AI provider to use for this thread.
//
// Shown before entering the new thread — user must confirm or cancel.
// Cancel → the pending thread is deleted.

import SwiftUI
import ChappieCore

// MARK: - NewThreadProviderSheet

struct NewThreadProviderSheet: View {

    // MARK: - Input

    let providers: [AIProvider]
    let currentProvider: AIProvider?
    let onConfirm: (UUID) -> Void
    let onCancel: () -> Void

    // MARK: - State

    @State private var selectedId: UUID?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Image(systemName: "plus.bubble")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Новый тред")
                        .font(.title2.bold())
                    Text("Выберите модель для этого треда")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Provider list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(providers) { provider in
                        ProviderSelectionRow(
                            provider: provider,
                            isSelected: selectedId == provider.id,
                            onSelect: { selectedId = provider.id }
                        )
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 300)

            Divider()

            // Footer
            HStack {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button {
                    if let id = selectedId {
                        onConfirm(id)
                    }
                } label: {
                    Text("Начать")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedId == nil)
                .keyboardShortcut(.return)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 400, height: 380)
        .onAppear {
            // Pre-select current provider, or default (first)
            selectedId = currentProvider?.id ?? providers.first?.id
        }
    }
}

// MARK: - ProviderSelectionRow

private struct ProviderSelectionRow: View {

    let provider: AIProvider
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.modelName)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(.primary)

                    Text(provider.displayHost)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.1)
                        : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview {
    NewThreadProviderSheet(
        providers: [
            AIProvider(
                id: UUID(),
                endpoint: "https://api.aitunnel.ru/v1/chat/completions",
                modelName: "claude-sonnet-4.6"
            ),
            AIProvider(
                id: UUID(),
                endpoint: "https://api.openai.com/v1/chat/completions",
                modelName: "gpt-4o"
            )
        ],
        currentProvider: nil,
        onConfirm: { _ in },
        onCancel: {}
    )
}
