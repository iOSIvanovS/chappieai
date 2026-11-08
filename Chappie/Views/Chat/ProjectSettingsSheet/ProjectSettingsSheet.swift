// ProjectSettingsSheet.swift
// Chappie
//
// Sheet with project settings — opened by tapping a project chip in ProjectChipsView.
// Local @State draft: ProjectSettings — edits a copy, not the original.
// On "Save" — calls onSave with final settings.
//
// UNLOCK LOGIC:
// 1. Role .advisor — show only basic settings + explanation.
// 2. Role .executor + isProgrammingProject = false — show role only.
// 3. Role .executor + isProgrammingProject = true — show all advanced settings.
//
// ENV DETECTION:
// "Detect" button calls onDetectEnvironment — async AI call in ViewModel.
// isDetecting=true shows spinner inside the button while waiting.
// The callback from ViewModel arrives on any thread; we hop to MainActor before
// mutating @State (draft.devEnvironment, isDetecting).
//
// TERMINAL:
// Terminal settings have moved to ThreadSettingsSheet (thread-level).
// ProjectSettings.terminalAccess is kept for Codable compatibility but not shown here.

import SwiftUI
import ChappieCore

// MARK: - ProjectSettingsSheet

struct ProjectSettingsSheet: View {

    let project: ProjectMetadata
    let onSave: (ProjectSettings) -> Void
    let onDismiss: () -> Void
    /// Called when user taps "Detect". Receives a @Sendable callback to invoke with the result.
    let onDetectEnvironment: (@Sendable @escaping (DevEnvironment) -> Void) -> Void
    /// Called when user updates the project path (manual edit or Browse picker).
    /// Separate from onSave — path lives in ThreadProjectEntry, not ProjectSettings.
    let onUpdatePath: (String) -> Void
    /// Hosts of the current thread — the allow-list that secrets are bound to.
    let curlHosts: [CurlHost]
    /// Receives the secret list, typed values and removed secrets on Save, before `onSave`.
    /// Values go to the Keychain; they never travel through ProjectSettings.
    let onCommitCurlSecrets: ([CurlSecret], [UUID: [CurlSecretField: String]], [CurlSecret]) -> Void

    @State var draft: ProjectSettings
    @State var curlValues: [UUID: [CurlSecretField: String]] = [:]
    @State var curlSavedFields: Set<String>
    @State var pathDraft: String
    @State var showingDowngradeAlert = false
    @State var pendingRoleChange: AgentRole? = nil
    @State var isDetecting = false

    init(
        project: ProjectMetadata,
        onSave: @escaping (ProjectSettings) -> Void,
        onDismiss: @escaping () -> Void,
        onDetectEnvironment: @escaping (@Sendable @escaping (DevEnvironment) -> Void) -> Void = { _ in },
        onUpdatePath: @escaping (String) -> Void = { _ in },
        curlHosts: [CurlHost] = [],
        curlSavedFields: Set<String> = [],
        onCommitCurlSecrets: @escaping ([CurlSecret], [UUID: [CurlSecretField: String]], [CurlSecret]) -> Void = { _, _, _ in }
    ) {
        self.project = project
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onDetectEnvironment = onDetectEnvironment
        self.onUpdatePath = onUpdatePath
        self.curlHosts = curlHosts
        self.onCommitCurlSecrets = onCommitCurlSecrets
        self._curlSavedFields = State(initialValue: curlSavedFields)
        self._draft = State(initialValue: project.settings)
        self._pathDraft = State(initialValue: project.absolutePath ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pathSection

                    Divider().padding(.vertical, 4)

                    roleSection

                    if draft.agentRole == .executor {
                        Divider().padding(.vertical, 4)
                        projectTypeSection

                        Divider().padding(.vertical, 4)
                        CurlSecretsEditor(
                            secrets: $draft.curlSecrets,
                            values: $curlValues,
                            hosts: curlHosts,
                            savedFields: curlSavedFields
                        )

                        if draft.isProgrammingProject {
                            Divider().padding(.vertical, 4)
                            devEnvironmentSection
                            Divider().padding(.vertical, 4)
                            gitSection
                            buildSection
                            testsSection
                            architectureSection
                            commentsSection
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            footerView
        }
        .frame(width: 460)
        .frame(minHeight: 400)
        // Downgrade advisor alert — shown when switching Executor → Advisor
        .alert("project.settings.downgrade_alert_title", isPresented: $showingDowngradeAlert) {
            Button("project.settings.downgrade_cancel", role: .cancel) {
                pendingRoleChange = nil
            }
            Button("project.settings.downgrade_confirm", role: .destructive) {
                draft.downgradeToAdvisor()
                pendingRoleChange = nil
            }
        } message: {
            Text("project.settings.downgrade_alert_message")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("project.settings.title")
                    .font(.headline)
                Text(project.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Footer

    var footerView: some View {
        HStack {
            Button("project.settings.cancel") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("project.settings.save") {
                var final = draft
                final.curlSecrets = CurlValidation.normalized(CurlValidation.droppingBlank(draft.curlSecrets))
                let keptIds = Set(final.curlSecrets.map(\.id))
                let removed = project.settings.curlSecrets.filter { !keptIds.contains($0.id) }
                onCommitCurlSecrets(final.curlSecrets, curlValues, removed)
                onSave(final)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isDetecting || !draft.curlSecretsAreSaveable)
        }
        .padding(16)
    }

    // MARK: - Helpers

    func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Preview

#Preview("Advisor") {
    ProjectSettingsSheet(
        project: ProjectMetadata(
            id: UUID(),
            displayName: "Chappie",
            settings: ProjectSettings(agentRole: .advisor)
        ),
        onSave: { settings in print("Saved: \(settings)") },
        onDismiss: {}
    )
}

#Preview("Executor — programming") {
    ProjectSettingsSheet(
        project: ProjectMetadata(
            id: UUID(),
            displayName: "Chappie",
            settings: ProjectSettings(
                agentRole: .executor,
                isProgrammingProject: true,
                devEnvironment: .xcode,
                gitAccess: .write,
                testsAccess: .write,
                architectureEnabled: true,
                architectureLanguage: .english,
                commentsEnabled: true,
                commentsLanguage: .english
            )
        ),
        onSave: { settings in print("Saved: \(settings)") },
        onDismiss: {}
    )
}
