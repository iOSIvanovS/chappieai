// ToolStatus.swift
// ChappieCore
//
// The availability line that opens every tool description shown to the model, e.g.
//   [AVAILABLE in: Chappie] [UNAVAILABLE in: Landing — the project's role is ADVISOR (read-only). To enable: …]
// so the model always knows its full toolbox, WHY a tool is closed, and what to tell the user to switch on.
//
// Pure: built from the same ToolPolicy.evaluate that guards execution, so text and behaviour cannot drift.

import Foundation

/// One attached project as the status builder sees it.
public struct ToolStatusProject: Sendable {
    public let name: String
    public let settings: ProjectSettings

    public init(name: String, settings: ProjectSettings) {
        self.name = name
        self.settings = settings
    }
}

public struct ToolStatus: Sendable, Equatable {
    /// True when the tool can run for at least one call target in this thread.
    public let isAvailable: Bool
    /// "[…]" line to put in front of the description.
    public let label: String
    /// Tools with the same capability and the same label are enabled and disabled together.
    public var groupKey: String { label }
}

extension ToolPolicy {

    public static func status(
        of tool: String,
        projects: [ToolStatusProject],
        terminalEnabled: Bool,
        curlEnabled: Bool,
        computerUseEnabled: Bool = false
    ) -> ToolStatus {
        guard let capability = capability(of: tool) else {
            let block = ToolBlock(reason: "unknown tool, it is not registered in the tool policy", fix: nil, permanent: true)
            return ToolStatus(isAvailable: false, label: "[UNAVAILABLE — \(block.summary)]")
        }

        switch capability {
        case .alwaysOn:
            return ToolStatus(isAvailable: true, label: "[ALWAYS AVAILABLE]")

        case .forbidden:
            let block = threadBlock(capability, terminalEnabled: terminalEnabled, curlEnabled: curlEnabled)
            return ToolStatus(isAvailable: false, label: "[FORBIDDEN — \(block?.summary ?? "never allowed")]")

        case .terminal:
            if let block = threadBlock(capability, terminalEnabled: terminalEnabled, curlEnabled: curlEnabled, computerUseEnabled: computerUseEnabled) {
                return ToolStatus(isAvailable: false, label: "[UNAVAILABLE — \(block.summary)]")
            }
            return ToolStatus(isAvailable: true, label: "[AVAILABLE — thread terminal switch is on: commands run automatically]")

        case .computerUse:
            if let block = threadBlock(capability, terminalEnabled: terminalEnabled, curlEnabled: curlEnabled, computerUseEnabled: computerUseEnabled) {
                return ToolStatus(isAvailable: false, label: "[UNAVAILABLE — \(block.summary)]")
            }
            return ToolStatus(isAvailable: true, label: "[AVAILABLE — thread computer use switch is on: commands run automatically]")

        case .curl:
            return curlStatus(tool, capability, projects, terminalEnabled, curlEnabled)

        default:
            return projectStatus(tool, capability, projects)
        }
    }

    // MARK: Project-scoped tools

    private static func projectStatus(
        _ tool: String,
        _ capability: ToolCapability,
        _ projects: [ToolStatusProject]
    ) -> ToolStatus {
        let part = projectPart(tool, capability, projects)
        return ToolStatus(isAvailable: part.anyAvailable, label: "[\(part.text)]")
    }

    /// Curl needs the thread switch AND an EXECUTOR project; the label names whichever is missing.
    private static func curlStatus(
        _ tool: String,
        _ capability: ToolCapability,
        _ projects: [ToolStatusProject],
        _ terminal: Bool,
        _ curlEnabled: Bool
    ) -> ToolStatus {
        let part = projectPart(tool, capability, projects)
        if let thread = threadBlock(capability, terminalEnabled: terminal, curlEnabled: curlEnabled) {
            return ToolStatus(
                isAvailable: false,
                label: "[UNAVAILABLE — \(thread.summary). It also needs an EXECUTOR project; \(part.text)]"
            )
        }
        return ToolStatus(isAvailable: part.anyAvailable, label: "[\(part.text)]")
    }

    /// "AVAILABLE in: A, B. UNAVAILABLE in: C — reason. To enable: fix; D — …"
    private static func projectPart(
        _ tool: String,
        _ capability: ToolCapability,
        _ projects: [ToolStatusProject]
    ) -> (text: String, anyAvailable: Bool) {
        guard !projects.isEmpty else {
            let block = ToolBlock(
                reason: "no project is attached to this thread",
                fix: "attach a project ('+' in the projects bar, or drop a folder into the chat)"
            )
            return ("UNAVAILABLE — \(block.summary)", false)
        }

        var available: [String] = []
        var blocked: [(summary: String, names: [String])] = []   // grouped by identical summary, order kept
        for project in projects {
            if let block = projectBlock(tool: tool, capability: capability, settings: project.settings) {
                if let i = blocked.firstIndex(where: { $0.summary == block.summary }) {
                    blocked[i].names.append(project.name)
                } else {
                    blocked.append((block.summary, [project.name]))
                }
            } else {
                available.append(project.name)
            }
        }

        var sentences: [String] = []
        if !available.isEmpty { sentences.append("AVAILABLE in: \(available.joined(separator: ", "))") }
        if !blocked.isEmpty {
            let items = blocked.map { "\($0.names.joined(separator: ", ")) — \($0.summary)" }
            sentences.append("UNAVAILABLE in: \(items.joined(separator: "; "))")
        }
        return (sentences.joined(separator: ". "), !available.isEmpty)
    }
}
