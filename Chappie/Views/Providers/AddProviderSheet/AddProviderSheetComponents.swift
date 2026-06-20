// AddProviderSheetComponents.swift
// Chappie
//
// Reusable sub-views and data models used exclusively by AddProviderSheet.

import SwiftUI
import ChappieCore

// MARK: - PendingKey

struct PendingKey: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var isVisible: Bool = false
}

// MARK: - PendingKeyRow

struct PendingKeyRow: View {
    @Binding var key: PendingKey
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("provider.key_name_label", text: $key.name)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Group {
                    if key.isVisible { TextField("sk-...", text: $key.value) }
                    else { SecureField("sk-...", text: $key.value) }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                Button { key.isVisible.toggle() } label: {
                    Image(systemName: key.isVisible ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ModelCheckRow

struct ModelCheckRow: View {
    let model: AIModel
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
