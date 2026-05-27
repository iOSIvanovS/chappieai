// ContentView.swift
// Chappie
//
// ContentView is a pure "conductor". It assembles all components together
// and passes data from ViewModel to the right places.
//
// IT-09: Added project settings sheet.
// IT-10: Universal AI Provider (two-level: provider → model).
//   - OnboardingView shown when no providers configured
//   - ModelPickerRow shows active provider+model, supports orphaned state
//   - NewThreadProviderSheet picks provider AND model
//   - SettingsView is now general settings (name + providers shortcut)
//   - Sidebar receives orphanedThreadIds for ⚠️ indicators
//
// INPUT MORPH:
//   StatusBarView + InputBarView replaced with InputMorphView.
//   The input bar transforms in-place into a tool call status strip while Chappie thinks.
//   Cancel button triggers viewModel.cancelCurrentRequest() — real Task cancellation.
//
// SCROLL FIX:
//   InputMorphView reports its rendered height via inputBarHeight binding.
//   ChatScrollView uses this as bottomPadding so the last message is never hidden
//   under the input panel — including on launch and when the editor grows.

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

    @State private var selectedProjectForSettings: ProjectMetadata? = nil

    // Height reported by InputMorphView — used as bottom padding in ChatScrollView
    // so the last message is never hidden under the input panel.
    @State private var inputBarHeight: CGFloat = 0

    @Environment(\.modelContext) private var modelContext

    // MARK: - Computed: Orphaned Thread IDs
    //
    // NOTE: Full orphaned detection requires loading all thread settings asynchronously.
    // That's a future backlog task. For now we return an empty set — the active thread's
    // orphaned state is shown via ModelPickerRow warning instead.
    private var orphanedThreadIds: Set<UUID> { [] }

    var body: some View {
        Group {
            if !isReady {
                ProgressView("Загрузка...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.providers.isEmpty {
                OnboardingView(viewModel: viewModel)
            } else {
                mainContent
            }
        }
        .onAppear {
            viewModel.setModelContainer(modelContext.container)
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                isReady = true
            }
        }
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
                orphanedThreadIds: orphanedThreadIds,
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

                // IT-10: Model picker row (with orphaned support)
                if viewModel.activeThread != nil && !viewModel.providers.isEmpty {
                    ModelPickerRow(
                        activeProvider: viewModel.activeProvider,
                        activeModelName: viewModel.activeModelName,
                        providers: viewModel.providers,
                        isOrphaned: viewModel.isThreadOrphaned,
                        onSelectProvider: { providerId, modelName in
                            if let provider = viewModel.providers.first(where: { $0.id == providerId }),
                               let store = viewModel.providerStore {
                                Task {
                                    await viewModel.switchProvider(provider, modelName: modelName, from: store)
                                }
                            }
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

                // Chat scroll area — bottomPadding keeps the last message visible
                // above the InputMorphView regardless of its current height.
                ChatScrollView(
                    messages: viewModel.visibleMessages,
                    isThinking: viewModel.isThinking,
                    streamingText: viewModel.streamingText,
                    runningCost: viewModel.runningCost,
                    bottomPadding: inputBarHeight
                )

                // INPUT MORPH: single component that transforms between input and status modes.
                // Reports its rendered height so ChatScrollView can pad accordingly.
                InputMorphView(
                    prompt: $prompt,
                    isWorkspaceSelected: viewModel.workspaceURL != nil,
                    isThinking: viewModel.isThinking,
                    currentToolCall: viewModel.currentToolCall,
                    onSend: sendMessage,
                    onCancel: { viewModel.cancelCurrentRequest() },
                    onHeightChange: { height in
                        inputBarHeight = height
                    }
                )
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.activeThread?.id)
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
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
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
        .sheet(isPresented: $viewModel.showNewThreadProviderPicker) {
            NewThreadProviderSheet(
                providers: viewModel.providers,
                currentProvider: viewModel.activeProvider,
                currentModelName: viewModel.activeModelName,
                onConfirm: { providerId, modelName in
                    Task { await viewModel.confirmNewThread(with: providerId, modelName: modelName) }
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
