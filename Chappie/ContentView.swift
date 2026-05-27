// ContentView.swift
// Chappie
//
// ContentView is a pure "conductor". It assembles all components together
// and passes data from ViewModel to the right places.
//
// FLOATING PANELS LAYOUT:
// The detail area uses a ZStack:
//   - Back layer: ChatScrollView fills the entire area (ignores safe area).
//   - Front layer: FloatingPanelsView — top panel (model picker + project chips)
//     and bottom panel (input / tool status) float over the scroll view.
// Both panels are transparent with a strong drop shadow.
// ChatScrollView reserves matching transparent header/footer spacers so the
// first and last messages are always fully readable.
//
// BACKGROUND IMAGE:
// Image("Chappie") is applied as .background() directly on NavigationSplitView.
// This means the image sits behind BOTH the sidebar and the detail column.
// The sidebar's NSVisualEffectView naturally composites on top of the image,
// producing the frosted-glass effect automatically — no AppKit hacks needed.
// The window is NOT made transparent (that would break layout and make the
// entire window see-through).
//
// IT-09: Added project settings sheet.
// IT-10: Universal AI Provider (two-level: provider → model).

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

    // Heights reported by floating panels — used as transparent spacers in ChatScrollView.
    @State private var topPanelHeight: CGFloat = 0
    @State private var bottomPanelHeight: CGFloat = 0

    @Environment(\.modelContext) private var modelContext

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
        navigationContent
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

    // MARK: - Navigation

    private var navigationContent: some View {
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
            // ZStack: ChatScrollView fills the full area, floating panels overlay on top.
            ZStack(alignment: .top) {

                // BACK LAYER: full-screen scroll view
                ChatScrollView(
                    messages: viewModel.visibleMessages,
                    isThinking: viewModel.isThinking,
                    streamingText: viewModel.streamingText,
                    runningCost: viewModel.runningCost,
                    headerHeight: topPanelHeight,
                    footerHeight: bottomPanelHeight
                )
                .ignoresSafeArea(edges: .top)

                // FRONT LAYER: transparent floating panels with drop shadows
                VStack(spacing: 0) {
                    topPanel
                    Spacer()
                    bottomPanel
                }
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
        // Background image sits behind BOTH sidebar and detail columns.
        // The sidebar's NSVisualEffectView composites on top automatically —
        // this gives the frosted-glass sidebar effect without any AppKit tricks.
        .background(
            Image("Chappie")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.5)
        )
    }

    // MARK: - Top Floating Panel

    /// Top panel: model picker + project chips.
    /// Transparent background, strong shadow cast downward.
    private var topPanel: some View {
        VStack(spacing: 0) {
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

            if viewModel.activeThread != nil {
                ProjectChipsView(
                    projects: viewModel.activeProjects,
                    onAddProject: { url in viewModel.addProject(url: url) },
                    onRemoveProject: { projectId in viewModel.removeProject(id: projectId) },
                    onOpenSettings: { projectId in
                        if let project = viewModel.activeProjects.first(where: { $0.id == projectId }) {
                            selectedProjectForSettings = project
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Strong shadow cast downward from the bottom edge of the panel
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
        // Report height for ChatScrollView headerHeight
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { topPanelHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in topPanelHeight = h }
            }
        )
    }

    // MARK: - Bottom Floating Panel

    /// Bottom panel: InputMorphView.
    /// Transparent background, strong shadow cast upward.
    private var bottomPanel: some View {
        InputMorphView(
            prompt: $prompt,
            isWorkspaceSelected: viewModel.workspaceURL != nil,
            isThinking: viewModel.isThinking,
            currentToolCall: viewModel.currentToolCall,
            onSend: sendMessage,
            onCancel: { viewModel.cancelCurrentRequest() }
        )
        // Strong shadow cast upward from the top edge of the panel
        .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: -8)
        // Report height for ChatScrollView footerHeight
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { bottomPanelHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in bottomPanelHeight = h }
            }
        )
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
