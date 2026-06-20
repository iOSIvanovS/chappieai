// ModelSelectRow.swift
// Chappie
//
// Single row in the model selection list — checkbox, name, "already added" badge.

import SwiftUI
import ChappieCore

struct ModelSelectRow: View {

    let model: AIModel
    let isSelected: Bool
    let isExisting: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                checkboxIcon
                Text(model.displayName)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isExisting ? .secondary : .primary)
                    .lineLimit(1)
                if isExisting { addedBadge }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .disabled(isExisting)
        .onHover { isHovered = $0 }
    }

    // MARK: - Subviews

    private var checkboxIcon: some View {
        Group {
            if isExisting {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.secondary.opacity(0.35))
            } else {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
        }
        .font(.system(size: 16))
    }

    private var addedBadge: some View {
        Text("provider.models_added_badge")
            .font(.system(size: 10))
            .foregroundStyle(.secondary.opacity(0.6))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isExisting
                  ? Color.clear
                  : (isSelected
                     ? Color.accentColor.opacity(0.07)
                     : (isHovered ? Color.primary.opacity(0.04) : Color.clear)))
    }
}
