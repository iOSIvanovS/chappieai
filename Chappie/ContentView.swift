// ContentView.swift
// Chappie
//
// ContentView is a pure "conductor". It assembles all components together
// and passes data from ViewModel to the right places.
//
// IT-09: Added project settings sheet.
// IT-10: Universal AI Provider.
//   - OnboardingView shown when no providers configured
//   - ModelPickerRow added above ProjectChipsView
//   - NewThreadProviderSheet shown when creating a new thread

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import ChappieCore

// MARK: - ContentView

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false
    @State private var isReady: Bool = false

    /// IT-09: Project whose settings are currently open.
    @State private var selectedProjectForSettings: ProjectMetadata? = nil

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if !isReady {
                // Loading state while SwiftData initializes
                ProgressView("Загрузка...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.providers.isEmpty {
                // IT-10: Onboarding — no providers configured yet
                OnboardingView(viewModel: viewModel)
            } else {
                mainContent
            }
        }
        .onAppear {
            viewModel.setModelContainer(modelContext.container)
            // Give SwiftData a moment to load providers before deciding which screen to show
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                isReady = true
            }
        }
        // React to providers being added (onboarding → main app transition)
        .onChange(of: viewModel.providers.count) { _, newCount in
            if newCount > 0 && !isReady {
                isReady = true
            }
        }
    }

    // MARK: - Main App Content

    private var mainContent: some View {
        NavigationSplitView {
            SidebarView(
                isApiKeyValid: !viewModel.providers.isEmpty,
                threads: viewModel.threads,
                selectedThreadId: viewModel.activeThread?.id,
                onOpenSettings: { showSettings = true },
                onSelectThread: { thread in
                    Task { await viewModel.selectThread(thread) }
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

                // IT-10: Model picker row
                if viewModel.activeThread != nil && !viewModel.providers.isEmpty {
                    ModelPickerRow(
                        activeProvider: viewModel.activeProvider,
                        providers: viewModel.providers,
                        onSelectProvider: { id in
                            viewModel.switchProvider(id: id)
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // IT-06, IT-09: Project chips row
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
                    isApiKeyValid: !viewModel.providers.isEmpty,
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
        // IT-10: Settings sheet shows ProvidersSettingsView
        .sheet(isPresented: $showSettings) {
            ProvidersSettingsView(viewModel: viewModel)
        }
        // IT-09: Project settings sheet
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
        // IT-10: New thread provider picker sheet
        .sheet(isPresented: $viewModel.showNewThreadProviderPicker) {
            NewThreadProviderSheet(
                providers: viewModel.providers,
                currentProvider: viewModel.activeProvider,
                onConfirm: { providerId in
                    Task { await viewModel.confirmNewThread(with: providerId) }
                },
                onCancel: {
                    viewModel.cancelNewThread()
                }
            )
        }
    }

    // MARK: - Private

    private func sendMessage() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(prompt: prompt)
        prompt = ""
    }
}

#Preview {
    ContentView()
}
