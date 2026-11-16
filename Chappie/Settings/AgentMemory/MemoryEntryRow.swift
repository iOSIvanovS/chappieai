// MemoryEntryRow.swift
// Chappie
//
// One row of the memory editor: type, key, the text the agent reads, and a trash button.
//
// The text is exactly MemoryEntry.promptDisplayValue — what actually reaches the system prompt.
// When the stored record has more fields than that, the full JSON is available on demand so the
// user never deletes a record while seeing less than what is stored.

import SwiftUI
import ChappieCore

// MARK: - MemoryEntryRow

struct MemoryEntryRow: View {

    let entry: MemoryEntry
    let onDelete: () -> Void

    @State private var showAllFields = false

    private var hiddenFieldsJSON: String? {
        MemoryEntryPresentation.hiddenFieldsJSON(for: entry)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Text(verbatim: entry.promptDisplayValue)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                fullFieldsSection
            }

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(Text("common.delete"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: entry.type)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)

            Text(verbatim: entry.key)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Full fields

    @ViewBuilder
    private var fullFieldsSection: some View {
        if let json = hiddenFieldsJSON {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showAllFields.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showAllFields ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(showAllFields ? "agent_memory.hide_fields" : "agent_memory.show_fields")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)

            if showAllFields {
                Text(verbatim: json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
