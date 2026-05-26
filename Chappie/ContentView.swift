// ContentView.swift
// Chappie
//
// АРХИТЕКТУРНАЯ РОЛЬ ЭТОГО ФАЙЛА:
// ContentView — это чистый "дирижёр". Он НЕ содержит бизнес-логику и НЕ рисует
// отдельные элементы. Его единственная задача — собрать все компоненты вместе
// и "прокинуть" данные из ViewModel в нужные места.
//
// Структура разбита на файлы:
// - Views/Sidebar/SidebarView.swift      — боковая панель с тредами (IT-05)
// - Views/Sidebar/ThreadListView.swift   — список тредов (IT-05)
// - Views/Sidebar/ThreadRowView.swift    — строка треда (IT-05)
// - Views/Chat/ProjectChipsView.swift    — плашки проектов над чатом (IT-06)
// - Views/Chat/ChatScrollView.swift      — лента сообщений (макс. 30 .message)
// - Views/Chat/MessageBubbleView.swift   — пузырь одного сообщения
// - Views/Chat/StatusBarView.swift       — строка состояния текущего инструмента
// - Views/Input/InputBarView.swift       — поле ввода
// - Views/Toolbar/ToolbarContent.swift   — контент тулбара
// - Settings/SettingsView.swift          — экран настроек
//
// ИЗМЕНЕНИЕ (IT-05 — Боковая панель тредов):
// SidebarView получает список тредов и коллбэки управления тредами из ViewModel.
// ContentView прокидывает данные без собственной логики — принцип "тупого дирижёра".
//
// ИЗМЕНЕНИЕ (IT-06 — Плашки проектов):
// ProjectChipsView вставлен МЕЖДУ боковой панелью и лентой сообщений.
// Коллбэки onAddProject и onRemoveProject прокидываются из ViewModel.
//
// ИЗМЕНЕНИЕ (UI-FIX-01 — Реструктуризация UI):
// 1. Воркспейс убран из SidebarView → перенесён в ToolbarContent.
//    ПОЧЕМУ: воркспейс — глобальная настройка, не per-тред навигация.
// 2. ProjectChipsView показывается ВСЕГДА (не только когда activeThread != nil).
//    ПОЧЕМУ: activeThread устанавливается асинхронно после загрузки SwiftData.
//    Условный рендер по activeThread вызывал "мигание" и пропадание плашек.
//    Теперь плашки всегда видны — если проектов нет, показывается только кнопка "+".
//    Кнопка "+" недоступна (disabled) пока тред не выбран — защита от действий без контекста.

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
// ChappieCore нужен для доступа к типам ThreadMetadata (UUID свойство id)
// через viewModel.activeThread?.id и viewModel.threads
import ChappieCore

// MARK: - Content View

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false

    /// ModelContext из SwiftUI-окружения — предоставляется .modelContainer() в ChappieApp.
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView {
            // MARK: Боковая панель с тредами (IT-05, UI-FIX-01)
            // SidebarView получает:
            // - список тредов из ViewModel (уже отсортированы по updatedAt DESC)
            // - UUID активного треда для подсветки
            // - коллбэки для всех действий с тредами
            //
            // НЕ получает (убрано в UI-FIX-01):
            // - workspaceURL — перенесён в тулбар
            // - onSelectWorkspace — перенесён в тулбар
            SidebarView(
                isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                threads: viewModel.threads,
                selectedThreadId: viewModel.activeThread?.id,
                onOpenSettings: { showSettings = true },
                onSelectThread: { thread in
                    // Выбор треда — асинхронная операция (загрузка истории из SwiftData)
                    Task {
                        await viewModel.selectThread(thread)
                    }
                },
                onCreateThread: {
                    viewModel.createNewThread()
                },
                onDeleteThread: { thread in
                    viewModel.deleteThread(thread)
                },
                onRenameThread: { thread, newTitle in
                    viewModel.renameThread(thread, newTitle: newTitle)
                }
            )

        } detail: {
            VStack(spacing: 0) {

                // MARK: Плашки проектов (IT-06, UI-FIX-01)
                //
                // ИЗМЕНЕНИЕ UI-FIX-01:
                // Плашки показываются ВСЕГДА, а не только когда activeThread != nil.
                //
                // ПОЧЕМУ УБРАЛИ УСЛОВНЫЙ РЕНДЕР:
                // activeThread устанавливается асинхронно — сначала nil, потом значение.
                // Это вызывало "мигание": плашки появлялись с задержкой или пропадали.
                // Теперь ProjectChipsView всегда в иерархии — нет Layout Shift.
                //
                // КАК ЗАЩИЩАЕМСЯ ОТ ДЕЙСТВИЙ БЕЗ ТРЕДА:
                // ProjectChipsView.addButton disabled если activeThread == nil.
                // Это передаётся через параметр isThreadActive.
                ProjectChipsView(
                    projects: viewModel.activeProjects,
                    isThreadActive: viewModel.activeThread != nil,
                    onAddProject: { url in
                        viewModel.addProject(url: url)
                    },
                    onRemoveProject: { projectId in
                        viewModel.removeProject(id: projectId)
                    }
                )

                ChatScrollView(
                    messages: viewModel.visibleMessages,
                    isThinking: viewModel.isThinking,
                    streamingText: viewModel.streamingText,
                    runningCost: viewModel.runningCost
                )

                StatusBarView(toolCall: viewModel.currentToolCall)

                InputBarView(
                    prompt: $prompt,
                    isWorkspaceSelected: viewModel.workspaceURL != nil,
                    isThinking: viewModel.isThinking,
                    onSend: sendMessage
                )
            }
            .animation(.easeInOut(duration: 0.25), value: viewModel.currentToolCall)
            .toolbar {
                // MARK: Тулбар (UI-FIX-01)
                // Добавлены workspaceURL и onSelectWorkspace — убраны из SidebarView.
                ChappieToolbarContent(
                    workspaceURL: viewModel.workspaceURL,
                    balance: viewModel.currentBalance,
                    isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                    onSelectWorkspace: selectWorkspace,
                    onOpenSettings: { showSettings = true }
                )
            }
        }
        .background {
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.5)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView { newKey in
                viewModel.updateApiKey(newKey)
            }
        }
        // ПОДКЛЮЧЕНИЕ SWIFTDATA (IT-03 + IT-05 + IT-06):
        // При первом появлении View передаём ModelContainer в ViewModel.
        // setModelContainer() идемпотентен — повторные вызовы игнорируются.
        .onAppear {
            viewModel.setModelContainer(modelContext.container)
        }
    }

    // MARK: - Приватные методы

    private func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку проекта для Чаппи"

        if panel.runModal() == .OK, let url = panel.url {
            viewModel.setWorkspace(url)
        }
    }

    private func sendMessage() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ContentView()
}
