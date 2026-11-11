// ToolCatalog.swift
// ChappieCore
//
// Turns "every tool definition + its status" into the list the model actually receives. Pure.
//
//   1. Everything is always offered, so the model knows its whole toolbox and why a tool is closed.
//   2. Available tools first, then unavailable ones; each list goes from harmless to dangerous.
//   3. An available tool keeps its full definition, with the status line in front of the description.
//   4. Unavailable tools are compressed: no parameters (they cannot be called usefully anyway) and a
//      short text. Tools of one group that are closed for the same reason share one group description,
//      carried by the first member; the others point to it. Full definitions return the moment the
//      settings open the tool.

import Foundation

public enum ToolCatalog {

    public typealias Entry = (tool: AITool, status: ToolStatus)

    public static func compose(_ entries: [Entry]) -> [AITool] {
        let sorted = entries.enumerated()
            .sorted { lhs, rhs in
                let l = ToolPolicy.dangerRank(of: lhs.element.tool.function.name)
                let r = ToolPolicy.dangerRank(of: rhs.element.tool.function.name)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map(\.element)

        let open = sorted.filter { $0.status.isAvailable }
        let closed = sorted.filter { !$0.status.isAvailable }

        var members: [String: [String]] = [:]
        for entry in closed {
            members[groupKey(entry), default: []].append(entry.tool.function.name)
        }

        let opened = open.map { entry -> AITool in
            let f = entry.tool.function
            return AITool(type: entry.tool.type, function: AIFunctionDefinition(
                name: f.name, description: "\(entry.status.label)\n\(f.description)", parameters: f.parameters
            ))
        }
        let compressed = closed.map { entry -> AITool in
            let name = entry.tool.function.name
            let group = members[groupKey(entry)] ?? [name]
            return compressedTool(entry, group: group)
        }
        return opened + compressed
    }

    // MARK: Compressed form

    private static func groupKey(_ entry: Entry) -> String {
        "\(ToolPolicy.groupTitle(of: entry.tool.function.name))|\(entry.status.label)"
    }

    private static func compressedTool(_ entry: Entry, group: [String]) -> AITool {
        let f = entry.tool.function
        let gist = firstSentence(of: f.description)
        let text: String
        if group.count == 1 {
            text = "\(entry.status.label)\n\(gist)"
        } else if group.first == f.name {
            let title = ToolPolicy.groupTitle(of: f.name)
            text = "\(entry.status.label)\nGroup «\(title)», closed together: \(group.joined(separator: ", ")).\n\(gist)"
        } else {
            text = "[UNAVAILABLE — same reason and fix as \(group[0]), see its description]\n\(gist)"
        }
        return AITool(type: entry.tool.type, function: AIFunctionDefinition(
            name: f.name, description: text, parameters: AIToolParameters(properties: [:], required: [])
        ))
    }

    /// First sentence of the first line, capped; enough to say what the tool is for.
    static func firstSentence(of text: String) -> String {
        let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
        if let end = line.range(of: ". ") {
            return String(line[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        return String(line.prefix(200)).trimmingCharacters(in: .whitespaces)
    }
}
