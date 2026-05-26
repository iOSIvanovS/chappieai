// ProjectChipsView.swift
// Chappie
//
// НАЗНАЧЕНИЕ (IT-06 — REFACTOR-THREADS):
// Горизонтальный ряд чипов-тегов с именами проектов, привязанных к текущему треду.
// Отображается в верхней части чата, прямо над лентой сообщений.
//
// IT-09: Тап на чип открывает ProjectSettingsSheet.
// Коллбэк onOpenSettings(UUID) добавлен для передачи ID проекта в ViewModel.
//
// ПОЧЕМУ ОТДЕЛЬНЫЙ КОМПОНЕНТ:
// Логика добавления/удаления проектов достаточно сложна (NSOpenPanel, bookmark-ы,
// список существующих проектов) чтобы не смешивать её с ChatScrollView.
// Принцип единственной ответственности — каждый View-файл делает одно.
//
// АРХИТЕКТУРА ДАННЫХ (IT-01 + IT-06):
// Чипы показывают ProjectMetadata из ProjectStore.
// При добавлении нового проекта — сначала создаётся ProjectEntity в ProjectStore,
// затем его UUID добавляется в ThreadEntity.projectBindingsJSON.
// При удалении — UUID убирается из projectBindingsJSON (ProjectEntity НЕ удаляется).
//
// ПРИНЦИП "ТУПОГО КОМПОНЕНТА":
// ProjectChipsView не знает о SwiftData, ProjectStore или ThreadStore напрямую.
// Все данные — через параметры, все действия — через коллбэки.
// Логика в ChappieViewModel.
//
// ВИДИМОСТЬ (UI-FIX-02):
// Компонент показывается только когда тред активен (условие в ContentView).
// ContentView сам решает показывать или нет через `if viewModel.activeThread != nil`.
//
// ПОВЕДЕНИЕ КНОПКИ "+":
// Открывает NSOpenPanel → пользователь выбирает папку.
// ViewModel создаёт/находит ProjectEntity, добавляет UUID в тред.
//
// ПОВЕДЕНИЕ ПО ТАПУ НА ЧИП (IT-09):
// Тап на чип → вызывает onOpenSettings(project.id).
// ContentView/родительский View показывает ProjectSettingsSheet.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Горизонтальный ряд чипов проектов для текущего треда.
///
/// Показывает список проектов, привязанных к треду.
/// Кнопка "+" добавляет новый проект через NSOpenPanel.
/// Кнопка "×" на каждом чипе удаляет проект из треда.
/// Тап на чип открывает настройки проекта (IT-09).
struct ProjectChipsView: View {

    // MARK: - Входные данные

    let projects: [ProjectMetadata]

    // MARK: - Коллбэки

    /// Вызывается когда пользователь нажимает "+" и выбирает папку.
    let onAddProject: (URL) -> Void

    /// Вызывается когда пользователь нажимает "×" на чипе.
    let onRemoveProject: (UUID) -> Void

    /// Вызывается когда пользователь тапает на чип для открытия настроек (IT-09).
    let onOpenSettings: (UUID) -> Void

    // MARK: - Локальное состояние

    /// Hover-состояние для чипа — ключ это UUID проекта.
    @State private var hoveredProjectId: UUID? = nil

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {

            Text("Проекты:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {

                    ForEach(projects) { project in
                        projectChip(for: project)
                    }

                    addButton
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.primary.opacity(0.06)),
            alignment: .bottom
        )
    }

    // MARK: - Чип проекта

    /// Отдельный чип для одного проекта.
    ///
    /// HOVER-ПОВЕДЕНИЕ:
    /// При наведении — показывается кнопка "×" справа от названия.
    ///
    /// ТАП-ПОВЕДЕНИЕ (IT-09):
    /// Тап на чип → onOpenSettings(project.id) → родитель показывает ProjectSettingsSheet.
    /// Кнопка "×" при hover — удаляет проект из треда (не открывает настройки).
    private func projectChip(for project: ProjectMetadata) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Индикатор роли (IT-09) — маленькая иконка показывает текущую роль
            roleIndicator(for: project.settings.agentRole)

            if hoveredProjectId == project.id {
                Button {
                    onRemoveProject(project.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(hoveredProjectId == project.id ? 0.15 : 0.1))
        )
        .overlay(
            Capsule()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredProjectId = isHovered ? project.id : nil
            }
        }
        .onTapGesture {
            // Тап на чип → открываем настройки проекта (IT-09)
            onOpenSettings(project.id)
        }
        .help("Проект: \(project.displayName) (\(project.settings.agentRole.displayName))\nТап — настройки, × — убрать из треда")
    }

    /// Маленький индикатор роли агента рядом с именем проекта.
    ///
    /// ЗАЧЕМ:
    /// Пользователь должен сразу видеть в каком режиме работает агент с каждым проектом.
    /// Иконка замка = советник (только чтение), иконка молнии = исполнитель.
    @ViewBuilder
    private func roleIndicator(for role: AgentRole) -> some View {
        switch role {
        case .advisor:
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        case .executor:
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.accentColor.opacity(0.7))
        }
    }

    // MARK: - Кнопка добавления

    private var addButton: some View {
        Button {
            openFolderPicker()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("Добавить")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Color.accentColor)
            .background(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.05)))
            )
        }
        .buttonStyle(.plain)
        .help("Добавить папку проекта к этому треду")
    }

    // MARK: - Приватные методы

    private func openFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку проекта для добавления в тред"
        panel.prompt = "Добавить"

        if panel.runModal() == .OK, let url = panel.url {
            onAddProject(url)
        }
    }
}

// MARK: - Preview

#Preview("С проектами") {
    ProjectChipsView(
        projects: [
            ProjectMetadata(
                id: UUID(),
                displayName: "Chappie",
                settings: ProjectSettings(agentRole: .executor, isProgrammingProject: true)
            ),
            ProjectMetadata(
                id: UUID(),
                displayName: "MyApp",
                settings: ProjectSettings(agentRole: .advisor)
            )
        ],
        onAddProject: { url in
            print("Добавить: \(url.lastPathComponent)")
        },
        onRemoveProject: { id in
            print("Удалить: \(id)")
        },
        onOpenSettings: { id in
            print("Настройки: \(id)")
        }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой список") {
    ProjectChipsView(
        projects: [],
        onAddProject: { _ in },
        onRemoveProject: { _ in },
        onOpenSettings: { _ in }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}
