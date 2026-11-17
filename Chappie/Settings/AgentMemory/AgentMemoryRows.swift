// AgentMemoryRows.swift
// Chappie
//
// Small building blocks shared by the agent memory screens: a navigation row with title,
// hint and an entry counter, and the plural-aware counter text.

import SwiftUI
import ChappieCore

// MARK: - Route

/// Where a tap in the agent memory screens leads.
enum AgentMemoryRoute: Hashable {
    /// The entries editor for one scope. `title` is already localized by the caller.
    case editor(scope: MemoryScope, title: String)
    /// The screen of one thread: its own memory plus its attached projects.
    case thread(ThreadMetadata)
}

// MARK: - Counter text

enum AgentMemoryCounter {

    /// "3 entries" with the Slavic plural rule the rest of Settings uses.
    ///
    /// Every key is written out as a literal on purpose: Xcode's string extraction only sees
    /// literals passed to String(localized:), so a key assembled in a variable is reported as
    /// unused and gets deleted from the catalog on the next cleanup.
    static func text(_ count: Int) -> String {
        let label: String
        switch count {
        case 1: label = String(localized: "agent_memory.entries_one")
        case 2...4: label = String(localized: "agent_memory.entries_few")
        default: label = String(localized: "agent_memory.entries_many")
        }
        return "\(count) \(label)"
    }
}

// MARK: - AgentMemoryNavRow

/// A tappable row: title, optional hint, optional counter, and an "Open" affordance.
struct AgentMemoryNavRow: View {

    let title: String
    var hint: LocalizedStringKey?
    var count: Int?
    let route: AgentMemoryRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let count {
                        Text(verbatim: AgentMemoryCounter.text(count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("agent_memory.open")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.blue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AgentMemorySectionHeader

struct AgentMemorySectionHeader: View {

    let title: LocalizedStringKey
    let hint: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
