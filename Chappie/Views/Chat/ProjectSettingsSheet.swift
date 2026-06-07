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

import SwiftUI
import ChappieCore

// MARK: - ProjectSettingsSheet

struct ProjectSettingsSheet: View {

    let project: ProjectMetadata
    let onSave: (ProjectSettings) -> Void
    let onDismiss: () -> Void
    /// Called when user taps "Detect". Receives a @Sendable callback to invoke with the result.
    let onDetectEnvironment: (@Sendable @escaping (DevEnvironment) -> Void) -> Void

    @State private var draft: ProjectSettings
    @State private var showingDowngradeAlert = false
    @State private var pendingRoleChange: AgentRole? = nil
    @State private var isDetecting = false

    init(
        project: ProjectMetadata,
        onSave: @escaping (ProjectSettings) -> Void,
        onDismiss: @escaping () -> Void,
        onDetectEnvironment: @escaping (@Sendable @escaping (DevEnvironment) -> Void) -> Void = { _ in }
    ) {
        self.project = project
        self.onSave = onSave
        self.onDismiss = onDismiss
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
                            Divider().padding(.vertical, 4)
                            terminalSection
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

    // MARK: - Role section

    private var roleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.role_section", systemImage: "person.badge.key.fill")

            Picker("project.settings.role_picker", selection: Binding(
                get: { draft.agentRole },
                set: { newRole in
                    if draft.agentRole == .executor && newRole == .advisor {
                        pendingRoleChange = newRole
                        showingDowngradeAlert = true
                    } else {
                        draft.agentRole = newRole
                    }
                }
            )) {
                ForEach(AgentRole.allCases, id: \.self) { role in
                    Text(role.displayName).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(draft.agentRole.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.agentRole == .advisor {
                advisorLimitsView
            }
        }
    }

    private var advisorLimitsView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.blue)
                .padding(.top, 1)

            Text("project.settings.advisor_limits")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Project type section

    private var projectTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.type_section", systemImage: "hammer.fill")

            Toggle(isOn: $draft.isProgrammingProject) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("project.settings.programming_project")
                        .font(.callout)
                    Text("project.settings.programming_project_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Dev environment section

    private var devEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.dev_env_section", systemImage: "laptopcomputer")

            HStack(spacing: 8) {
                Picker("project.settings.env_picker", selection: $draft.devEnvironment) {
                    ForEach(DevEnvironment.allCases, id: \.self) { env in
                        Text(env.displayName).tag(env)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(isDetecting)

                // Detect button — triggers AI detection, shows spinner while waiting.
                // Callback arrives on any thread — hop to MainActor before mutating @State.
                Button {
                    isDetecting = true
                    onDetectEnvironment { detected in
                        Task { @MainActor in
                            draft.devEnvironment = detected
                            isDetecting = false
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isDetecting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.65)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isDetecting ? String(localized: "project.settings.detecting") : String(localized: "project.settings.detect"))
                            .font(.callout)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isDetecting)
                .help("project.settings.detect_help")
            }

            if draft.devEnvironment != .unknown {
                let tools = draft.devEnvironment.specificTools
                if !tools.isEmpty {
                    Text(String(format: String(localized: "project.settings.env_tools_hint"), tools.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("project.settings.env_unknown_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Git section

    private var gitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.git_section", systemImage: "arrow.triangle.branch")

            Picker("project.settings.git_picker", selection: $draft.gitAccess) {
                ForEach(GitAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)

            if draft.gitAccess != .none {
                let tools = draft.gitAccess.allowedTools.sorted().joined(separator: ", ")
                Text(String(format: String(localized: "project.settings.git_tools_hint"), tools))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text("project.settings.git_diff_blocked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tests section

    private var testsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.tests_section", systemImage: "checkmark.shield.fill")

            Picker("project.settings.tests_picker", selection: $draft.testsAccess) {
                ForEach(TestsAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)

            if draft.testsAccess == .readOnly {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "eye.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("project.settings.tests_readonly_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Architecture section

    private var architectureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.arch_section", systemImage: "doc.text.fill")

            Toggle(isOn: $draft.architectureEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("project.settings.arch_allow")
                        .font(.callout)
                    Text("project.settings.arch_allow_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if draft.architectureEnabled {
                HStack {
                    Text("project.settings.arch_language")
                        .font(.callout)
                    Spacer()
                    Picker("project.settings.arch_language_picker", selection: $draft.architectureLanguage) {
                        ForEach(ProjectLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: - Comments section

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.comments_section", systemImage: "text.bubble.fill")

            Toggle(isOn: $draft.commentsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("project.settings.comments_allow")
                        .font(.callout)
                    Text("project.settings.comments_allow_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if draft.commentsEnabled {
                HStack {
                    Text("project.settings.comments_language")
                        .font(.callout)
                    Spacer()
                    Picker("project.settings.comments_language_picker", selection: $draft.commentsLanguage) {
                        ForEach(ProjectLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 200)
                }
            }
        }
    }

    // MARK: - Terminal section

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.terminal_section", systemImage: "terminal.fill")

            Picker("project.settings.terminal_picker", selection: $draft.terminalAccess) {
                ForEach(TerminalAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(draft.terminalAccess.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if draft.terminalAccess == .auto {
                autoTerminalWarningView
            }

            if draft.terminalAccess != .none {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                    Text("project.settings.terminal_safe_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var autoTerminalWarningView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            Text("project.settings.terminal_auto_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footerView: some View {
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

    private func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
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
                commentsLanguage: .english,
                terminalAccess: .confirm
            )
        ),
        onSave: { settings in print("Saved: \(settings)") },
        onDismiss: {}
    )
}

#Preview("Terminal — auto") {
    ProjectSettingsSheet(
        project: ProjectMetadata(
            id: UUID(),
            displayName: "Chappie",
            settings: ProjectSettings(
                agentRole: .executor,
                isProgrammingProject: true,
                terminalAccess: .auto
            )
        ),
        onSave: { settings in print("Saved: \(settings)") },
        onDismiss: {}
    )
}
