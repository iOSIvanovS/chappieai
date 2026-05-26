// ContentView.swift
// Chappie
//
// АРХИТЕКТУРНАЯ РОЛЬ ЭТОГО ФАЙЛА:
// ContentView — это чистый "дирижёр". Он НЕ содержит бизнес-логику и НЕ рисует
// отдельные элементы. Его единственная задача — собрать все компоненты вместе
// и "прокинуть" данные из ViewModel в нужные места.
//
// ВОРКСПЕЙС (рабочая папка для инструментов):
// Воркспейс — техническая настройка, не связанная с тредами/проектами.
// НЕ отображается в тулбаре (убрано в UI-FIX-02) — тулбар минималистичный.
//
// АРХИТЕКТУРА ПРОЕКТОВ (IT-06, UI-FIX-02):
// ProjectChipsView показывается ТОЛЬКО когда activeThread != nil.
// Это логично: без треда — некуда добавлять проекты.
// Приложение всегда автоматически выбирает тред при старте.
//
// IT-09: Добавлен sheet настроек проекта.
// Тап на чип → onOpenSettings(UUID) → selectedProjectForSettings = project →
// .sheet показывает ProjectSettingsSheet → onSave → viewModel.updateProjectSettings().

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import ChappieCore

// MARK: - Content View

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false

    /// IT-09: Проект, настройки которого сейчас открыты.
    /// nil = sheet закрыт.
    @State private var selectedProjectForSettings: ProjectMetadata? = nil

    /// ModelContext из SwiftUI-окружения — предоставляется .modelContainer() в ChappieApp.
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView {
            // MARK: Боковая панель с тредами (IT-05)
            SidebarView(
                isApiKeyValid: SettingsManager.shared.isApiKeyValid,
                threads: viewModel.threads,
                selectedThreadId: viewModel.activeThread?.id,
                onOpenSettings: { showSettings = true },
                onSelectThread: { thread in
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

                // MARK: Плашки проектов (IT-06, IT-09)
                //
                // Показываем строку проектов ТОЛЬКО когда тред активен.
                // IT-09: onOpenSettings передаёт UUID проекта для открытия настроек.
                if viewModel.activeThread != nil {
                    ProjectChipsView(
                        projects: viewModel.activeProjects,
                        onAddProject: { url in
                            viewModel.addProject(url: url)
                        },
                        onRemoveProject: { projectId in
                            viewModel.removeProject(id: projectId)
                        },
                        onOpenSettings: { projectId in
                            // Находим ProjectMetadata по ID и открываем sheet
                            if let project = viewModel.activeProjects.first(where: { $0.id == projectId }) {
                                selectedProjectForSettings = project
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            .animation(.easeInOut(duration: 0.2), value: viewModel.activeThread?.id)
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
        // Sheet настроек приложения
        .sheet(isPresented: $showSettings) {
            SettingsView { newKey in
                viewModel.updateApiKey(newKey)
            }
        }
        // IT-09: Sheet настроек проекта — открывается по тапу на чип
        .sheet(item: $selectedProjectForSettings) { project in
            ProjectSettingsSheet(
                project: project,
                onSave: { newSettings in
                    viewModel.updateProjectSettings(newSettings, forProjectId: project.id)
                    selectedProjectForSettings = nil
                },
                onDismiss: {
                    selectedProjectForSettings = nil
                }
            )
        }
        .onAppear {
            viewModel.setModelContainer(modelContext.container)
        }
    }

    // MARK: - Приватные методы

    private func sendMessage() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ContentView()
}
