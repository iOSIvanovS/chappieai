// ProviderRowViews.swift
// Chappie
//
// Reusable row components for ProviderDetailView:
//   KeyRow   — single API key entry with edit/delete actions on hover
//   ModelRow — single AI model entry with delete action on hover

import SwiftUI
import ChappieCore

// MARK: - KeyRow

struct KeyRow: View {

    let key: APIKey
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor.opacity(0.7))

            Text(key.name)
                .font(.system(size: 13, weight: .medium))

            Text(verbatim: "••••••••")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary.opacity(0.5))

            Spacer()

            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("providers.key_edit_help")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("providers.key_delete_help")
            }
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - ModelRow

struct ModelRow: View {

    let model: AIModel
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)

                if model.providerProtocol == .anthropic {
                    Text("anthropic")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("providers.model_delete_help")
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
