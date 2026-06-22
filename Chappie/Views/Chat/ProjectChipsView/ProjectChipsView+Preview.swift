// ProjectChipsView+Preview.swift
// Chappie

import SwiftUI
import ChappieCore

#Preview("With projects") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)),
            ProjectMetadata(id: UUID(), displayName: "MyApp",
                            settings: ProjectSettings(agentRole: .advisor)),
            ProjectMetadata(id: UUID(), displayName: "Backend API",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: false,
        isFileSystemReady: true,
        balance: 2120.09,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("No balance") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: false,
        isFileSystemReady: true,
        balance: nil,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .frame(width: 300)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Locked") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(id: UUID(), displayName: "Chappie",
                            settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true))
        ],
        threadName: "Chappie Development",
        isThinking: true,
        isFileSystemReady: true,
        balance: 82.69,
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .padding()
    .background(Color(NSColor.windowBackgroundColor))
}
