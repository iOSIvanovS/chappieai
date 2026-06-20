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
// STARTER PLAN GUARD:
// If canExecuteTools == false (Starter license), switching to Executor shows an alert
// explaining the restriction and offering "Change Plan" → opens LicenseActivationView.
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
    /// True when the current license plan forbids Executor mode (e.g. Starter).
    let canExecuteTools: Bool
    /// Called when user taps "Change Plan" in the Starter restriction alert.
    let onChangePlan: () -> Void

    @State var draft: ProjectSettings
    @State var showingDowngradeAlert = false
    @State var pendingRoleChange: AgentRole? = nil
    @State var isDetecting = false
    @State var showingStarterAlert = false

    init(
        project: ProjectMetadata,
        canExecuteTools: Bool = true,
        onSave: @escaping (ProjectSettings) -> Void,
        onDismiss: @escaping () -> Void,
        onChangePlan: @escaping () -> Void = {},
        onDetectEnvironment: @escaping (@Sendable @escaping (DevEnvironment) -> Void) -> Void = { _ in }
    ) {
        self.project = project
        self.canExecuteTools = canExecuteTools
        self.onSave = onSave
        self.onDismiss = onDismiss
        self.onChangePlan = onChangePlan
        self.onDetectEnvironment = onDetectEnvironment
        self._draft = State(initialValue: project.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    roleSection

                    if draft.agentRole == .executor {
                        Divider().padding(.vertical, 4)
                        projectTypeSection

                        if draft.isProgrammingProject {
                            Divider().padding(.vertical, 4)
                            devEnvironmentSection
                            Divider().padding(.vertical, 4)
                            gitSection
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
        // Starter plan restriction alert — shown when trying to enable Executor on Starter
        .alert("project.settings.starter_executor_alert_title", isPresented: $showingStarterAlert) {
            Button("project.settings.starter_executor_alert_cancel", role: .cancel) {}
            Button("project.settings.starter_executor_alert_change_plan") {
                onDismiss()
                onChangePlan()
            }
        } message: {
            Text("project.settings.starter_executor_alert_message")
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
                onSave(draft)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isDetecting)
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
