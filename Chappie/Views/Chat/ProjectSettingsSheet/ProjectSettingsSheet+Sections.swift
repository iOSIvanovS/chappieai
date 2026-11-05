// ProjectSettingsSheet+Sections.swift
// Chappie
//
// All content sections rendered inside ProjectSettingsSheet's ScrollView.

import SwiftUI
import AppKit
import ChappieCore

extension ProjectSettingsSheet {

    // MARK: - Path section

    var pathSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.path_section", systemImage: "folder.badge.gearshape")

            HStack(spacing: 8) {
                TextField("project.settings.path_placeholder", text: $pathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit {
                        onUpdatePath(pathDraft)
                    }

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = String(localized: "project.settings.path_picker_message")
                    panel.prompt = String(localized: "project.settings.path_picker_button")
                    if panel.runModal() == .OK, let url = panel.url {
                        pathDraft = url.path
                        onUpdatePath(pathDraft)
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("project.settings.path_browse_help")
            }

            if !FileManager.default.fileExists(atPath: pathDraft) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("project.settings.path_missing_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Role section

    var roleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.role_section", systemImage: "person.badge.key.fill")

            Picker("project.settings.role_picker", selection: Binding(
                get: { draft.agentRole },
                set: { newRole in
                    if draft.agentRole == .executor && newRole == .advisor {
                        // Executor → Advisor: confirm downgrade (clears all access flags)
                        pendingRoleChange = newRole
                        showingDowngradeAlert = true
                    } else if newRole == .executor && !canExecuteTools {
                        // Advisor → Executor: blocked by Starter plan
                        showingStarterAlert = true
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

    var advisorLimitsView: some View {
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

    var projectTypeSection: some View {
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

    var devEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.dev_env_section", systemImage: "laptopcomputer")

            HStack(spacing: 8) {
                Picker("project.settings.env_picker", selection: $draft.devEnvironment) {
                    ForEach(DevEnvironment.allCases, id: \.self) { env in
                        Text(env.localizedName).tag(env)
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

    var gitSection: some View {
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

    // MARK: - Build section

    var buildSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.build_section", systemImage: "hammer.circle.fill")

            Toggle(isOn: $draft.buildEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("project.settings.build_allow")
                        .font(.callout)
                    Text("project.settings.build_allow_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if !draft.buildEnabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text("project.settings.build_disabled_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Tests section

    var testsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("project.settings.tests_section", systemImage: "checkmark.shield.fill")

            Picker("project.settings.tests_picker", selection: $draft.testsAccess) {
                ForEach(TestsAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)
            .disabled(!draft.buildEnabled)

            if !draft.buildEnabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                    Text("project.settings.tests_build_disabled_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if draft.testsAccess == .readOnly {
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

    var architectureSection: some View {
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
                Picker("project.settings.arch_language_picker", selection: $draft.architectureLanguage) {
                    ForEach(ProjectLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Comments section

    var commentsSection: some View {
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
                Picker("project.settings.comments_language_picker", selection: $draft.commentsLanguage) {
                    ForEach(ProjectLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
