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
//  - Views/Chat/ChatScrollView.swift      — лента сообщений
//  - Views/Chat/MessageBubbleView.swift   — пузырь одного сообщения
//  - Views/Input/InputBarView.swift       — поле ввода
//  - Views/Toolbar/ToolbarContent.swift   — контент тулбара
//  - Settings/SettingsView.swift          — экран настроек
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Content View

struct ContentView: View {
    
    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false
    
    var body: some View {
        NavigationSplitView {
            // САЙДБАР: контекст воркспейса и предупреждения
            SidebarView(
                workspaceURL: viewModel.workspaceURL,
                isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                onSelectWorkspace: selectWorkspace,
                onOpenSettings: { showSettings = true }
            )
            
        } detail: {
            // ОСНОВНАЯ ОБЛАСТЬ: лента чата + поле ввода
            VStack(spacing: 0) {
                
                // Лента сообщений — следит за изменениями и автоскроллит
                ChatScrollView(
                    messages: viewModel.messages,
                    isThinking: viewModel.isThinking
                )
                
                // Панель ввода — сигнализирует о нажатии "Отправить"
                InputBarView(
                    prompt: $prompt,
                    isWorkspaceSelected: viewModel.workspaceURL != nil,
                    isThinking: viewModel.isThinking,
                    onSend: sendMessage
                )
            }
            .toolbar {
                // Тулбар: баланс + шестерёнка настроек
                ChappieToolbarContent(
                    balance: viewModel.currentBalance,
                    isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                    onOpenSettings: { showSettings = true }
                )
            }
        }
        // Фоновое изображение Чаппи — полупрозрачное, не мешает чтению
        .background {
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.5)
        }
        // Экран настроек — sheet поверх основного окна
        .sheet(isPresented: $showSettings) {
            SettingsView { newKey in
                viewModel.updateApiKey(newKey)
            }
        }
    }
    
    // MARK: - Приватные методы
    
    /// Открывает NSOpenPanel для выбора папки проекта.
    /// Логика выбора папки живёт здесь, а не в ViewModel, потому что
    /// NSOpenPanel — это UI-операция, а не бизнес-логика.
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
    
    /// Отправляет сообщение из поля ввода в ViewModel и очищает поле.
    /// Guard защищает от отправки пустых строк (например, при нажатии Enter в пустом поле).
    private func sendMessage() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ContentView()
}
