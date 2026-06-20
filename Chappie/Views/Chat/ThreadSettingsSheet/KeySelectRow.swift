// KeySelectRow.swift
// Chappie
//
// Checkbox row for selecting an API key in ThreadSettingsSheet.

import SwiftUI
import ChappieCore

struct KeySelectRow: View {

    let key: APIKey
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))

                Text(key.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
