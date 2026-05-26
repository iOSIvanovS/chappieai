//
//  ContentView.swift
//  Chappie
//
//  АРХИТЕКТУРНАЯ РОЛЬ ЭТОГО ФАЙЛА:
//  ContentView — это чистый "дирижёр". Он НЕ содержит бизнес-логику и НЕ рисует
//  отдельные элементы. Его единственная задача — собрать все компоненты вместе
//  и "прокинуть" данные из ViewModel в нужные места.
//
//  Структура разбита на файлы:
//  - Views/Sidebar/SidebarView.swift      — боковая панель
//  - Views/Chat/ChatScrollView.swift      — лента сообщений (макс. 30 .message)
//  - Views/Chat/MessageBubbleView.swift   — пузырь одного сообщения
//  - Views/Chat/StatusBarView.swift       — строка состояния текущего инструмента
//  - Views/Input/InputBarView.swift       — поле ввода
//  - Views/Toolbar/ToolbarContent.swift   — контент тулбара
//  - Settings/SettingsView.swift          — экран настроек
//
//  ИЗМЕНЕНИЕ (IT-03 — Трёхуровневая память):
//  ContentView получает ModelContainer из SwiftUI-окружения (.modelContainer в ChappieApp)
//  и передаёт его в ChappieViewModel через setModelContainer().
//  Это связывает SwiftData с MemoryManager для автоматического подмешивания памяти
//  в system prompt перед каждым запросом к ИИ.
//
//  ПОЧЕМУ ЧЕРЕЗ onAppear, А НЕ ЧЕРЕЗ INIT:
//  @Environment(\.modelContext) недоступен в init — SwiftUI инжектирует его только
//  в body. onAppear — первый момент когда View "вмонтирована" в иерархию и
//  окружение доступно. Используем modelContext.container для передачи в ViewModel.

import SwiftUI
import UniformTypeIdentifiers
import SwiftData

// MARK: - Content View

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false

    /// ModelContext из SwiftUI-окружения — предоставляется .modelContainer() в ChappieApp.
    ///
    /// ЗАЧЕМ НУЖЕН:
    /// Через modelContext.container получаем ModelContainer и передаём его в ViewModel.
    /// Это единственный способ связать SwiftData с ViewModel без нарушения
    /// архитектурных границ (App → View → ViewModel).
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView {
            SidebarView(
                workspaceURL: viewModel.workspaceURL,
                isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                onSelectWorkspace: selectWorkspace,
                onOpenSettings: { showSettings = true }
            )

        } detail: {
            VStack(spacing: 0) {

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
        // ПОДКЛЮЧЕНИЕ SWIFTDATA (IT-03):
        // При первом появлении View передаём ModelContainer в ViewModel.
        // modelContext.container — это тот же контейнер что создан в ChappieApp.
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
