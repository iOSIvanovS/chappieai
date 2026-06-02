// ContentView.swift
// Chappie
//
// ContentView is a pure "conductor". It assembles all components together
// and passes data from ViewModel to the right places.
//
// LAYOUT ARCHITECTURE:
// The entire app is a ZStack assembled in ChappieApp.swift:
//   - Back layer (ChappieApp): background image fills the full NSWindow frame.
//   - Middle layer (ContentView): main content (top panel + chat + bottom panel).
//   - Front layer (conditional, ContentView): dim overlay + floating sidebar.
//
// WHY BACKGROUND IS IN ChappieApp:
// Placing the background image at WindowGroup level puts it below ALL safe areas,
// toolbar insets, and layout passes. ContentView never needs to know about it.
// This eliminates white strips at top/bottom that appeared when GeometryReader
// was inside ContentView's layout tree.
//
// FLOATING PANELS:
//   Top panel: ModelPickerRow + ProjectChipsView — each is an independent floating
//   rounded pill with ultraThinMaterial. The outer VStack is transparent.
//   Bottom panel: InputMorphView — ultraThinMaterial.
//   Both panels report their heights so ChatScrollView can add matching spacers.
//
// CPU-08: WHY onGeometryChange INSTEAD OF GeometryReader:
//   GeometryReader placed in .background participates in measurement and can cause
//   a render loop: parent changes size → GeometryReader fires → state update →
//   parent re-renders → GeometryReader fires again. This produced 35% idle CPU.
//   onGeometryChange (macOS 14+) is a pure side-effect observer — it does NOT
//   participate in layout, does NOT trigger a layout pass, and fires only when
//   the measured value actually changes. Zero render-loop risk.
//
// CPU-09: WHY NO .animation(value: activeThread?.id) ON mainChatArea:
//   Animating the entire ZStack on thread switch caused SwiftUI to re-render
//   every child view on every @Published change to activeThread — including
//   title updates, model changes, etc. Animations are now applied point-locally
//   on topPanel transitions only (transition(.opacity.combined(with:.move))).
//
// CPU-11: DRAFT DEBOUNCE:
//   onChange(of: prompt) used to call setDraft on every keystroke, publishing
//   into ViewModel on every character. Now debounced via Task + 300ms sleep.
//   Draft is still saved immediately on thread switch (direct call, no debounce).
//
// CPU-13: STREAMING ISOLATION:
//   ContentView no longer reads viewModel.isThinking, viewModel.streamingText,
//   viewModel.runningCost, or viewModel.currentToolCall directly.
//   Instead, viewModel.streaming (StreamingState) is passed as a `let` reference
//   to ChatScrollView and InputMorphView. ContentView's body does NOT subscribe
//   to StreamingState — so 30+ token updates/sec no longer invalidate topPanel,
//   bottomPanel, or any other ContentView subtree.

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import ChappieCore

// MARK: - Silent Drop Delegate

/// Minimal DropDelegate: silently accepts file drops, no visual overlay.
/// Directories are rejected; only regular files are passed to the handler.
private final class SilentDropDelegate: DropDelegate {

    var onFilesDropped: ([NSItemProvider]) -> Void = { _ in }
    var isThinkingGetter: () -> Bool = { false }

    func validateDrop(info: DropInfo) -> Bool {
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard !isThinkingGetter() else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        onFilesDropped(providers)
        return true
    }
}

// MARK: - ContentView

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false
    @State private var isSidebarVisible: Bool = false

    @State private var attachments: [AttachedFile] = []
    @State private var dropDelegate = SilentDropDelegate()

    @State private var selectedProjectForSettings: ProjectMetadata? = nil
    @State private var selectedThreadForSettings: ThreadMetadata? = nil

    @State private var topPanelHeight: CGFloat = 0
    @State private var bottomPanelHeight: CGFloat = 0
    @State private var safeAreaTop: CGFloat = 0

    // CPU-11: debounce task reference — cancelled on every new keystroke
    @State private var draftDebounceTask: Task<Void, Never>? = nil

    @Environment(\.modelContext) private var modelContext

    private var orphanedThreadIds: Set<UUID> { [] }

    private let sidebarWidth: CGFloat = 260

    var body: some View {
        Group {
            if !viewModel.isAppReady {
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

            // CPU-13: isThinkingGetter reads from StreamingState directly,
            // not from ViewModel — avoids creating a ViewModel subscription here.
            dropDelegate.isThinkingGetter = { [self] in viewModel.streaming.isThinking }
            dropDelegate.onFilesDropped = { [self] providers in
                resolveDroppedFiles(providers)
            }
        }
        .onChange(of: viewModel.providers.count) { _, _ in }
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
            .sheet(item: $selectedThreadForSettings) { thread in
                // M-08: pass providers so user can change provider/model per-thread
                ThreadSettingsSheet(
                    thread: thread,
                    providers: viewModel.providers,
                    onSave: { newTitle, newSettings, newProviderId, newModelName in
                        viewModel.updateThreadSettings(
                            newSettings,
                            newTitle: newTitle,
                            forThreadId: thread.id,
                            newProviderId: newProviderId,
                            newModelName: newModelName
                        )
                        selectedThreadForSettings = nil
                    },
                    onDismiss: {
                        selectedThreadForSettings = nil
                    }
                )
            }
            .sheet(isPresented: $viewModel.showNewThreadProviderPicker) {
                NewThreadProviderSheet(
                    providers: viewModel.providers,
                    currentProvider: viewModel.activeProvider,
                    currentModelName: viewModel.activeModelName,
                    onConfirm: { providerId, modelName, title, settings in
                        Task {
                            await viewModel.confirmNewThread(
                                with: providerId,
                                modelName: modelName,
                                title: title,
                                settings: settings
                            )
                        }
                    },
                    onCancel: {
                        viewModel.cancelNewThread()
                    }
                )
            }
    }

    // MARK: - Navigation

    private var navigationContent: some View {
        ZStack(alignment: .topLeading) {

            mainChatArea
                .toolbar {
                    ChappieToolbarContent(
                        isApiKeyValid: !viewModel.providers.isEmpty,
                        isSidebarVisible: $isSidebarVisible,
                        // CPU-13: read isThinking from StreamingState, not ViewModel.
                        // This toolbar modifier is evaluated by ContentView's body —
                        // reading from ViewModel here would subscribe ContentView to
                        // every token update. StreamingState is read only at call-site
                        // inside ChappieToolbarContent which owns its own subscription.
                        isThinking: viewModel.streaming.isThinking,
                        onOpenSettings: { showSettings = true }
                    )
                }

            if isSidebarVisible {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSidebarVisible = false
                        }
                    }
                    .transition(.opacity)

                SidebarView(
                    isApiKeyValid: !viewModel.providers.isEmpty,
                    threads: viewModel.threads,
                    selectedThreadId: viewModel.activeThread?.id,
                    orphanedThreadIds: orphanedThreadIds,
                    // CPU-13: same pattern — StreamingState read, not ViewModel.
                    isThinking: viewModel.streaming.isThinking,
                    onOpenSettings: {
                        showSettings = true
                        isSidebarVisible = false
                    },
                    onSelectThread: { thread in
                        // Save draft immediately (no debounce) before switching
                        if let currentId = viewModel.activeThread?.id {
                            draftDebounceTask?.cancel()
                            viewModel.setDraft(prompt, for: currentId)
                        }
                        Task { await viewModel.selectThread(thread) }
                    },
                    onCreateThread: {
                        if let currentId = viewModel.activeThread?.id {
                            draftDebounceTask?.cancel()
                            viewModel.setDraft(prompt, for: currentId)
                        }
                        viewModel.createNewThread()
                    },
                    onDeleteThread: { thread in
                        viewModel.deleteThread(thread)
                    },
                    onRenameThread: { thread, newTitle in
                        viewModel.renameThread(thread, newTitle: newTitle)
                    },
                    onOpenThreadSettings: { thread in
                        selectedThreadForSettings = thread
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSidebarVisible = false
                        }
                    }
                )
                .frame(width: sidebarWidth)
                .padding(.top, 52)
                .padding(.bottom, 16)
                .padding(.leading, 12)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
        .onChange(of: viewModel.activeThread?.id) { _, newThreadId in
            if let id = newThreadId {
                prompt = viewModel.getDraft(for: id)
            } else {
                prompt = ""
            }
        }
        .onChange(of: prompt) { _, newValue in
            // CPU-11: debounce draft writes — fire only after 300ms of no typing.
            // This prevents ViewModel @Published from firing on every keystroke.
            guard let threadId = viewModel.activeThread?.id else { return }
            draftDebounceTask?.cancel()
            draftDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                viewModel.setDraft(newValue, for: threadId)
            }
        }
        // CPU-13: observe isThinking via StreamingState, not ViewModel.
        // NOTE: this onChange DOES subscribe ContentView to StreamingState.isThinking,
        // but isThinking changes only twice per request (true/false) — not 30x/sec.
        // Cost: 2 re-renders per request vs 30+ without isolation. Acceptable.
        .onChange(of: viewModel.streaming.isThinking) { _, thinking in
            if thinking && showSettings {
                showSettings = false
            }
        }
    }

    // MARK: - Main Chat Area

    private var mainChatArea: some View {
        ZStack(alignment: .top) {

            // CPU-13: ChatScrollView receives streaming as a whole object reference.
            // ChatScrollView reads streaming.streamingText and streaming.runningCost
            // directly — it subscribes to StreamingState, not to ViewModel.
            // ContentView does NOT read any StreamingState property here.
            ChatScrollView(
                scrollToBottomTrigger: viewModel.scrollToBottomTrigger,
                messages: viewModel.displayedMessages,
                hasMoreMessages: viewModel.hasMoreMessages,
                onLoadMore: { viewModel.loadMoreMessages() },
                streaming: viewModel.streaming,
                isLoadingHistory: viewModel.isLoadingThread,
                headerHeight: topPanelHeight + safeAreaTop,
                footerHeight: bottomPanelHeight
            )
            .ignoresSafeArea(edges: .top)
            // CPU-08: onGeometryChange does NOT participate in layout — no render loop risk.
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.safeAreaInsets.top
            } action: { newValue in
                safeAreaTop = newValue
            }

            VStack(spacing: 0) {
                topPanel
                Spacer()
                bottomPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], delegate: dropDelegate)
    }

    // MARK: - Top Floating Panel
    // CPU-13: topPanel reads ONLY from viewModel (provider, model, balance, thread).
    // None of these change during streaming — so topPanel is NOT re-rendered on tokens.

    private var topPanel: some View {
        VStack(spacing: 6) {
            if viewModel.activeThread != nil && !viewModel.providers.isEmpty {
                ModelPickerRow(
                    activeProvider: viewModel.activeProvider,
                    activeModelName: viewModel.activeModelName,
                    providers: viewModel.providers,
                    isOrphaned: viewModel.isThreadOrphaned,
                    balance: viewModel.currentBalance,
                    isThinking: viewModel.streaming.isThinking,
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
                    threadName: viewModel.activeThread?.title,
                    isThinking: viewModel.streaming.isThinking,
                    onAddProject: { url in viewModel.addProject(url: url) },
                    onRemoveProject: { projectId in viewModel.removeProject(id: projectId) },
                    onOpenSettings: { projectId in
                        if let project = viewModel.activeProjects.first(where: { $0.id == projectId }) {
                            selectedProjectForSettings = project
                        }
                    },
                    onOpenThreadSettings: {
                        if let thread = viewModel.activeThread {
                            let fresh = viewModel.threads.first(where: { $0.id == thread.id }) ?? thread
                            selectedThreadForSettings = fresh
                        }
                    }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // CPU-08: onGeometryChange instead of GeometryReader in .background.
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.height
        } action: { newValue in
            topPanelHeight = newValue
        }
    }

    // MARK: - Bottom Floating Panel
    // CPU-13: bottomPanel passes streaming object to InputMorphView.
    // InputMorphView reads streaming.isThinking and streaming.currentToolCall directly.
    // ContentView does NOT read those properties here.

    private var bottomPanel: some View {
        InputMorphView(
            prompt: $prompt,
            attachments: $attachments,
            isWorkspaceSelected: viewModel.workspaceURL != nil,
            streaming: viewModel.streaming,
            onSend: { attachedFiles in
                sendMessage(attachments: attachedFiles)
            },
            onCancel: { viewModel.cancelCurrentRequest() },
            // CPU-08: height is now reported via callback, not GeometryReader inside InputMorphView.
            onHeightChange: { newHeight in
                bottomPanelHeight = newHeight
            }
        )
    }

    // MARK: - Private Helpers

    private func sendMessage(attachments: [AttachedFile]) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else { return }
        if let threadId = viewModel.activeThread?.id {
            draftDebounceTask?.cancel()
            viewModel.clearDraft(for: threadId)
        }
        viewModel.send(prompt: prompt, attachments: attachments)
        prompt = ""
    }

    private func resolveDroppedFiles(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                    continue
                }
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(
                        forTypeIdentifier: UTType.fileURL.identifier,
                        options: nil
                    ) { item, _ in
                        if let data = item as? Data,
                           let resolved = URL(dataRepresentation: data, relativeTo: nil) {
                            continuation.resume(returning: resolved)
                        } else if let resolved = item as? URL {
                            continuation.resume(returning: resolved)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url { urls.append(url) }
            }

            let fileURLs = urls.filter { url in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return exists && !isDir.boolValue
            }

            await MainActor.run {
                let existingNames = Set(attachments.map(\.filename))
                let newFiles = fileURLs
                    .compactMap { AttachedFile.load(from: $0) }
                    .filter { !existingNames.contains($0.filename) }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    attachments.append(contentsOf: newFiles)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
