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
// Показывается только когда есть активный тред (activeThread != nil).
// Коллбэки onAddProject и onRemoveProject прокидываются из ViewModel.

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
            // MARK: Боковая панель с тредами (IT-05)
            // SidebarView получает:
            // - список тредов из ViewModel (уже отсортированы по updatedAt DESC)
            // - UUID активного треда для подсветки
            // - коллбэки для всех действий с тредами
            SidebarView(
                workspaceURL: viewModel.workspaceURL,
                isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                threads: viewModel.threads,
                selectedThreadId: viewModel.activeThread?.id,
                onSelectWorkspace: selectWorkspace,
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

                // MARK: Плашки проектов (IT-06)
                // Показываем только если есть активный тред.
                // ПОЧЕМУ УСЛОВНЫЙ РЕНДЕР:
                // До загрузки ModelContainer (первые миллисекунды) activeThread == nil.
                // Показывать пустые чипы без контекста не имеет смысла.
                // После выбора треда — ProjectChipsView появляется с анимацией.
                if viewModel.activeThread != nil {
                    ProjectChipsView(
                        projects: viewModel.activeProjects,
                        onAddProject: { url in
                            viewModel.addProject(url: url)
                        },
                        onRemoveProject: { projectId in
                            viewModel.removeProject(id: projectId)
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

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
            // Анимируем появление/исчезновение ProjectChipsView
            .animation(.easeInOut(duration: 0.2), value: viewModel.activeThread != nil)
            .toolbar {
                ChappieToolbarContent(
                    balance: viewModel.currentBalance,
                    isApiKeyValid: SettingsManager.shared.isApiKeyValid,
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
