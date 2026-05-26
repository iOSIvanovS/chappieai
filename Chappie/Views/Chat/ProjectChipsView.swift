// ProjectChipsView.swift
// Chappie
//
// НАЗНАЧЕНИЕ (IT-06 — REFACTOR-THREADS):
// Горизонтальный ряд чипов-тегов с именами проектов, привязанных к текущему треду.
// Отображается в верхней части чата, прямо над лентой сообщений.
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
// ИЗМЕНЕНИЯ (UI-FIX-01):
// Добавлен параметр isThreadActive: Bool.
// ПОЧЕМУ:
// Раньше ProjectChipsView показывался только когда activeThread != nil (условный рендер).
// Это вызывало Layout Shift — плашки появлялись с задержкой после асинхронной загрузки треда.
// Теперь компонент ВСЕГДА присутствует в иерархии View.
// isThreadActive = false → кнопка "+" заблокирована (нельзя добавить проект без треда).
// isThreadActive = true → кнопка "+" активна.
// Чипы существующих проектов показываются всегда когда projects не пустой.
//
// ПОВЕДЕНИЕ КНОПКИ "+":
// Открывает NSOpenPanel → пользователь выбирает папку.
// ViewModel создаёт/находит ProjectEntity, добавляет UUID в тред.

import SwiftUI
import ChappieCore

// MARK: - ProjectChipsView

/// Горизонтальный ряд чипов проектов для текущего треда.
///
/// Показывает список проектов, привязанных к треду.
/// Кнопка "+" добавляет новый проект через NSOpenPanel.
/// Кнопка "×" на каждом чипе удаляет проект из треда.
struct ProjectChipsView: View {

    // MARK: - Входные данные

    /// Список проектов, привязанных к текущему треду.
    /// Пустой массив — показываем только кнопку "+".
    let projects: [ProjectMetadata]

    /// Флаг: выбран ли активный тред.
    ///
    /// ПОЧЕМУ НУЖЕН ЭТОТ ПАРАМЕТР (UI-FIX-01):
    /// Компонент теперь ВСЕГДА присутствует в иерархии (не скрывается).
    /// Если тред не выбран — кнопка "+" заблокирована, чтобы не добавить проект
    /// в никуда (без контекста треда).
    /// Как только тред загружается (асинхронно) — кнопка активируется.
    let isThreadActive: Bool

    // MARK: - Коллбэки

    /// Вызывается когда пользователь нажимает "+" и выбирает папку.
    /// Параметр — URL выбранной папки.
    let onAddProject: (URL) -> Void

    /// Вызывается когда пользователь нажимает "×" на чипе.
    /// Параметр — UUID проекта для удаления из треда.
    let onRemoveProject: (UUID) -> Void

    // MARK: - Локальное состояние

    /// Hover-состояние для чипа — ключ это UUID проекта.
    /// Нужно чтобы кнопка "×" появлялась только при наведении на конкретный чип.
    @State private var hoveredProjectId: UUID? = nil

    // MARK: - Body

    var body: some View {
        HStack(spacing: 6) {

            // Заголовок секции — маленький, не мешает
            Text("Проекты:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            // Горизонтальный скролл — на случай если проектов много
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {

                    // Чипы существующих проектов
                    ForEach(projects) { project in
                        projectChip(for: project)
                    }

                    // Кнопка добавления нового проекта
                    // disabled если тред не выбран — нельзя добавить проект без контекста
                    addButton
                        .disabled(!isThreadActive)
                        .opacity(isThreadActive ? 1.0 : 0.4)
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            // Тонкий разделитель снизу — визуально отделяет чипы от ленты сообщений
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
    /// Это стандартный паттерн macOS для деструктивных действий:
    /// не показывать их постоянно, но делать доступными по hover.
    ///
    /// ПОЧЕМУ onHover + @State:
    /// SwiftUI не имеет нативного hover-состояния для конкретного элемента в ForEach.
    /// Используем .onHover(perform:) + @State с UUID как ключом.
    private func projectChip(for project: ProjectMetadata) -> some View {
        HStack(spacing: 4) {
            // Иконка папки
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            // Имя проекта — обрезаем если очень длинное
            Text(project.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)

            // Кнопка удаления — появляется только при hover
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
            // Фон чипа — лёгкий акцентный цвет
            Capsule()
                .fill(Color.accentColor.opacity(hoveredProjectId == project.id ? 0.15 : 0.1))
        )
        .overlay(
            // Тонкая рамка
            Capsule()
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5)
        )
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredProjectId = isHovered ? project.id : nil
            }
        }
        // Тултип с полным именем проекта
        .help("Проект: \(project.displayName)\nНажмите × чтобы убрать из треда")
    }

    // MARK: - Кнопка добавления

    /// Кнопка "+" для добавления нового проекта.
    ///
    /// ПОЧЕМУ NSOpenPanel НАПРЯМУЮ:
    /// Кнопка сама открывает NSOpenPanel — это стандартный паттерн macOS.
    /// Результат (URL) передаётся в коллбэк onAddProject.
    /// ViewModel создаёт ProjectEntity и добавляет UUID в тред.
    ///
    /// ПОЧЕМУ НЕ .fileImporter:
    /// .fileImporter в SwiftUI имеет ограничения — не позволяет выбрать только папки
    /// с нужными настройками (canChooseFiles: false, canChooseDirectories: true).
    /// NSOpenPanel даёт полный контроль.
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
        .help(isThreadActive
              ? "Добавить папку проекта к этому треду"
              : "Выберите тред чтобы добавить проект")
    }

    // MARK: - Приватные методы

    /// Открывает NSOpenPanel для выбора папки проекта.
    ///
    /// Вызывается по нажатию кнопки "+".
    /// После выбора — вызывает коллбэк onAddProject(url).
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
                createdAt: Date()
            ),
            ProjectMetadata(
                id: UUID(),
                displayName: "MyAwesomeApp",
                createdAt: Date()
            )
        ],
        isThreadActive: true,
        onAddProject: { url in
            print("Добавить проект: \(url.lastPathComponent)")
        },
        onRemoveProject: { id in
            print("Удалить проект: \(id)")
        }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Пустой список") {
    ProjectChipsView(
        projects: [],
        isThreadActive: true,
        onAddProject: { _ in },
        onRemoveProject: { _ in }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}

#Preview("Тред не выбран") {
    ProjectChipsView(
        projects: [],
        isThreadActive: false,
        onAddProject: { _ in },
        onRemoveProject: { _ in }
    )
    .frame(width: 600)
    .background(Color(NSColor.windowBackgroundColor))
}
