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

import SwiftUI
import ChappieCore

// MARK: - ProjectSettingsSheet

struct ProjectSettingsSheet: View {

    let project: ProjectMetadata
    let onSave: (ProjectSettings) -> Void
    let onDismiss: () -> Void

    @State private var draft: ProjectSettings
    @State private var showingDowngradeAlert = false
    @State private var pendingRoleChange: AgentRole? = nil

    init(project: ProjectMetadata, onSave: @escaping (ProjectSettings) -> Void, onDismiss: @escaping () -> Void) {
        self.project = project
        self.onSave = onSave
        self.onDismiss = onDismiss
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
        .alert("Смена роли", isPresented: $showingDowngradeAlert) {
            Button("Отмена", role: .cancel) {
                pendingRoleChange = nil
            }
            Button("Сменить на советника", role: .destructive) {
                draft.downgradeToAdvisor()
                pendingRoleChange = nil
            }
        } message: {
            Text("При смене роли на «Советник» все права доступа (git, тесты, архитектура, комментарии, терминал) будут сброшены. Продолжить?")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Настройки проекта")
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
            sectionHeader("Роль агента", systemImage: "person.badge.key.fill")

            Picker("Роль", selection: Binding(
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

            Text("В роли советника доступны только **read_file** и **list_files**. Все инструменты записи, git, тесты и терминал заблокированы.")
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
            sectionHeader("Тип проекта", systemImage: "hammer.fill")

            Toggle(isOn: $draft.isProgrammingProject) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Программистский проект")
                        .font(.callout)
                    Text("Разблокирует настройки git, тестов, архитектуры, комментариев и терминала")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }

    // MARK: - Git section

    private var gitSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Git", systemImage: "arrow.triangle.branch")

            Picker("Доступ к git", selection: $draft.gitAccess) {
                ForEach(GitAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)

            if draft.gitAccess != .none {
                let tools = draft.gitAccess.allowedTools.sorted().joined(separator: ", ")
                Text("Доступные инструменты: \(tools)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "xmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                Text("git_diff всегда заблокирован — загружает весь проект в контекст")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tests section

    private var testsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Автотесты", systemImage: "checkmark.shield.fill")

            Picker("Доступ к тестам", selection: $draft.testsAccess) {
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
                    Text("Агент может читать логи и сигнализировать о проблемах, но не запускать тесты")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Architecture section

    private var architectureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Архитектурные файлы", systemImage: "doc.text.fill")

            Toggle(isOn: $draft.architectureEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Разрешить создание и редактирование")
                        .font(.callout)
                    Text("Агент сможет создавать architecture.md файлы. Пути обсуждаются с вами.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if draft.architectureEnabled {
                HStack {
                    Text("Язык файлов:")
                        .font(.callout)
                    Spacer()
                    Picker("Язык архитектуры", selection: $draft.architectureLanguage) {
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
            sectionHeader("Комментарии в коде", systemImage: "text.bubble.fill")

            Toggle(isOn: $draft.commentsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Добавлять комментарии в код")
                        .font(.callout)
                    Text("Агент будет комментировать написанный код")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if draft.commentsEnabled {
                HStack {
                    Text("Язык комментариев:")
                        .font(.callout)
                    Spacer()
                    Picker("Язык комментариев", selection: $draft.commentsLanguage) {
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
            sectionHeader("Терминал", systemImage: "terminal.fill")

            Picker("Доступ к терминалу", selection: $draft.terminalAccess) {
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
                    Text("Деструктивные команды (rm -rf /, sudo rm, mkfs и др.) заблокированы безусловно.")
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

            Text("Агент будет выполнять команды **без подтверждения**. Убедись, что доверяешь текущей модели и провайдеру.")
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
            Button("Отмена") {
                onDismiss()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Сохранить") {
                onSave(draft)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Preview

#Preview("Советник") {
    ProjectSettingsSheet(
        project: ProjectMetadata(
            id: UUID(),
            displayName: "Chappie",
            settings: ProjectSettings(agentRole: .advisor)
        ),
        onSave: { settings in print("Сохранено: \(settings)") },
        onDismiss: {}
    )
}

#Preview("Исполнитель — программистский") {
    ProjectSettingsSheet(
        project: ProjectMetadata(
            id: UUID(),
            displayName: "Chappie",
            settings: ProjectSettings(
                agentRole: .executor,
                isProgrammingProject: true,
                gitAccess: .write,
                testsAccess: .write,
                architectureEnabled: true,
                architectureLanguage: .english,
                commentsEnabled: true,
                commentsLanguage: .english,
                terminalAccess: .confirm
            )
        ),
        onSave: { settings in print("Сохранено: \(settings)") },
        onDismiss: {}
    )
}

#Preview("Терминал — авто") {
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
        onSave: { settings in print("Сохранено: \(settings)") },
        onDismiss: {}
    )
}
