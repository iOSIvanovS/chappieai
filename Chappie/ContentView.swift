// ContentView.swift
// Chappie
//
// Pure "conductor" — assembles all components, passes data from ViewModel to the right places.
// Drop logic lives in DropHandler.swift.
//
// LAYOUT:
//   ZStack (ChappieApp): background image fills full NSWindow frame (below safe areas).
//   ContentView: main content (top panel + chat + bottom panel).
//   Conditional: dim overlay + floating sidebar.
//
// TOP PANEL: two floating pills — ModelPickerRow (model + thread gear) + ProjectChipsView.
// BOTTOM PANEL: InputMorphView — ultraThinMaterial.
// Top panel reports height so ChatScrollView adds a matching header spacer.
// Bottom panel height measured via onGeometryChange (CPU-22).
//
// LAUNCH SEQUENCE:
//   1. Loading spinner — while viewModel.isAppReady == false
//   2. EULAView — if AppState.shouldShowEULA (first launch only)
//   3. OnboardingView — if AppState.shouldShowOnboarding (no provider configured)
//   4. Paywall — if licenseState is .noLicense or .expired
//   5. Main app
//
// CPU-08: onGeometryChange instead of GeometryReader — pure side-effect, no layout loop.
// CPU-13: streaming state isolated to ChatScrollView + InputMorphView — not read in body.
// CPU-22: currentPanelHeight measured directly from rendered InputMorphView.
// BUG-01: loadMoreAnchorId anchors scroll position after message prepend.

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import AppKit
import ChappieCore

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false
    @State private var isSidebarVisible: Bool = false
    @State private var showLicenseActivation: Bool = false

    @State private var attachments: [AttachedFile] = []
    @State private var dropDelegate = SilentDropDelegate()

    @State private var selectedProjectForSettings: ProjectMetadata? = nil
    @State private var selectedThreadForSettings: ThreadMetadata? = nil

    @State private var topPanelHeight: CGFloat = 0
    @State private var safeAreaTop: CGFloat = 0

    // CPU-22: measured directly from rendered InputMorphView via onGeometryChange
    @State private var currentPanelHeight: CGFloat = InputLayout.minPanelHeight

    // CPU-11: cancelled on every new keystroke, fires draft save after 300ms idle
    @State private var draftDebounceTask: Task<Void, Never>? = nil

    @State private var appState = AppState.shared

    @Environment(\.modelContext) private var modelContext

    private var orphanedThreadIds: Set<UUID> { [] }
    private let sidebarWidth: CGFloat = 260

    var body: some View {
        Group {
            if !viewModel.isAppReady {
                ProgressView(String(localized: "content.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.shouldShowEULA {
                // Step 1: EULA — must be accepted before anything else
                EULAView()
            } else if appState.shouldShowOnboarding {
                // Step 2: Onboarding — configure first provider
                OnboardingView(viewModel: viewModel)
            } else if viewModel.shouldShowPaywall {
                // Step 3: Paywall — license expired or not present
                paywallContent
            } else {
                // Step 4: Main app
                mainContent
            }
        }
        .onAppear {
            viewModel.setModelContainer(modelContext.container)
            dropDelegate.isThinkingGetter = { [self] in viewModel.streaming.isThinking }
            dropDelegate.onFilesDropped   = { [self] providers in resolveDroppedFiles(providers, attachments: $attachments) }
            dropDelegate.onFoldersDropped = { [self] providers in resolveFolderDrop(providers, addProject: { viewModel.addProject(url: $0) }) }
            dropDelegate.onImageProviders = { [self] providers in resolveImageProviders(providers, attachments: $attachments) }
        }
        .onChange(of: viewModel.providers.count) { _, _ in }
    }

    // MARK: - Paywall

    /// Shown when licenseState is .noLicense or .expired.
    /// User must activate a license to proceed — no way to dismiss.
    private var paywallContent: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("license.paywall_title")
                .font(.title2.bold())
            Text("license.paywall_subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("license.paywall_activate_button") {
                showLicenseActivation = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: 400)
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showLicenseActivation) {
            LicenseActivationView(viewModel: viewModel)
        }
    }

    // MARK: - Thread for Settings

    /// Builds ThreadMetadata with CURRENT activeThreadSettings — not stale thread.settings.
    private func buildThreadForSettings(_ thread: ThreadMetadata) -> ThreadMetadata {
        ThreadMetadata(
            id: thread.id,
            title: thread.title,
            settings: viewModel.activeThreadSettings,
            projectIds: thread.projectIds,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt
        )
    }

    // MARK: - Main App Content

    private var mainContent: some View {
        navigationContent
            .sheet(isPresented: $showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $showLicenseActivation) {
                LicenseActivationView(viewModel: viewModel)
            }
            .sheet(item: $selectedProjectForSettings) { project in
                ProjectSettingsSheet(
                    project: project,
                    canExecuteTools: viewModel.canExecuteTools,
                    onSave: { newSettings in
                        viewModel.updateProjectSettings(newSettings, forProjectId: project.id)
                        selectedProjectForSettings = nil
                    },
                    onDismiss: { selectedProjectForSettings = nil },
                    // "Change Plan" dismisses the settings sheet and opens LicenseActivationView
                    onChangePlan: { showLicenseActivation = true },
                    onDetectEnvironment: { completion in
                        // WHY fresh lookup by id (not captured `project`):
                        // `project` is a value-type snapshot captured when the sheet opened.
                        // absolutePath is runtime-only — it may have been nil at capture time
                        // if syncFileSystemForActiveThread() hadn't finished yet.
                        // We look up the live copy from activeProjects so absolutePath is current.
                        let live = viewModel.activeProjects.first(where: { $0.id == project.id }) ?? project
                        viewModel.detectDevEnvironment(for: live, completion: completion)
                    }
                )
            }
            .sheet(item: $selectedThreadForSettings) { thread in
                ThreadSettingsSheet(
                    thread: thread,
                    providers: viewModel.providers,
                    onSave: { newTitle, newSettings, newProviderId, newKeyId, newModelName in
                        viewModel.updateThreadSettings(
                            newSettings,
                            newTitle: newTitle,
                            forThreadId: thread.id,
                            newProviderId: newProviderId,
                            newKeyId: newKeyId,
                            newModelName: newModelName
                        )
                        selectedThreadForSettings = nil
                    },
                    onDismiss: { selectedThreadForSettings = nil }
                )
            }
            .sheet(isPresented: $viewModel.showNewThreadProviderPicker) {
                NewThreadProviderSheet(
                    providers: viewModel.providers,
                    currentProvider: viewModel.activeProvider,
                    currentModelName: viewModel.activeModelName,
                    onConfirm: { providerId, keyId, modelName, title, settings in
                        Task {
                            await viewModel.confirmNewThread(
                                with: providerId,
                                keyId: keyId,
                                modelName: modelName,
                                title: title,
                                settings: settings
                            )
                        }
                    },
                    onCancel: { viewModel.cancelNewThread() }
                )
            }
            .alert("content.no_model_title", isPresented: $viewModel.showNoProviderAlert) {
                Button("content.no_model_open_settings") { showSettings = true }
                Button("content.no_model_cancel", role: .cancel) { }
            } message: {
                Text("content.no_model_message")
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
                    isThinking: viewModel.streaming.isThinking,
                    onOpenSettings: {
                        showSettings = true
                        isSidebarVisible = false
                    },
                    onSelectThread: { thread in
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
                    onDeleteThread: { thread in viewModel.deleteThread(thread) },
                    onRenameThread: { thread, newTitle in viewModel.renameThread(thread, newTitle: newTitle) },
                    onOpenThreadSettings: { thread in
                        if thread.id == viewModel.activeThread?.id {
                            selectedThreadForSettings = buildThreadForSettings(thread)
                        } else {
                            selectedThreadForSettings = thread
                        }
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
            prompt = newThreadId.map { viewModel.getDraft(for: $0) } ?? ""
        }
        .onChange(of: prompt) { _, newValue in
            guard let threadId = viewModel.activeThread?.id else { return }
            draftDebounceTask?.cancel()
            draftDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                viewModel.setDraft(newValue, for: threadId)
            }
        }
        .onChange(of: viewModel.streaming.isThinking) { _, thinking in
            if thinking && showSettings { showSettings = false }
        }
    }

    // MARK: - Main Chat Area

    private var mainChatArea: some View {
        ZStack(alignment: .top) {

            ChatScrollView(
                scrollToBottomTrigger: viewModel.scrollToBottomTrigger,
                messages: viewModel.displayedMessages,
                hasMoreMessages: viewModel.hasMoreMessages,
                onLoadMore: { viewModel.loadMoreMessages() },
                streaming: viewModel.streaming,
                isLoadingHistory: viewModel.isLoadingThread,
                headerHeight: topPanelHeight + safeAreaTop,
                footerHeight: currentPanelHeight,
                loadMoreAnchorId: viewModel.loadMoreAnchorId,
                onLoadMoreScrollDone: { viewModel.loadMoreAnchorId = nil }
            )
            .ignoresSafeArea(edges: .top)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeAreaTop = $0 }

            VStack(spacing: 0) {
                topPanel
                Spacer()
                bottomPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL, .folder, .data] + officeUTTypes, delegate: dropDelegate)
    }

    // MARK: - Top Floating Panel

    private var topPanel: some View {
        VStack(spacing: 6) {
            
            // Trial banner — shown only during active trial period
            if case .trial(let days) = viewModel.licenseState {
                TrialBannerView(daysRemaining: days) {
                    showLicenseActivation = true
                }
                .padding(.horizontal, 0)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            if viewModel.activeThread != nil && !viewModel.providers.isEmpty {
                ModelPickerRow(
                    activeProvider: viewModel.activeProvider,
                    activeModelName: viewModel.activeModelName,
                    activeKeyId: viewModel.activeKeyId,
                    providers: viewModel.providers,
                    isOrphaned: viewModel.isThreadOrphaned,
                    threadName: viewModel.activeThread?.title,
                    streaming: viewModel.streaming,
                    onSelectProvider: { providerId, keyId, modelName in
                        if let provider = viewModel.providers.first(where: { $0.id == providerId }),
                           let store = viewModel.providerStore {
                            Task {
                                await viewModel.switchProvider(
                                    provider,
                                    keyId: keyId,
                                    modelName: modelName,
                                    from: store
                                )
                            }
                        }
                    },
                    onOpenThreadSettings: {
                        if let thread = viewModel.activeThread {
                            selectedThreadForSettings = buildThreadForSettings(thread)
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
                    isFileSystemReady: viewModel.isFileSystemReady,
                    balance: viewModel.streaming.currentBalance,
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
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topPanelHeight = $0 }
    }

    // MARK: - Bottom Floating Panel

    private var bottomPanel: some View {
        InputMorphView(
            prompt: $prompt,
            attachments: $attachments,
            isWorkspaceSelected: viewModel.workspaceURL != nil,
            streaming: viewModel.streaming,
            onSend: { attachedFiles in sendMessage(attachments: attachedFiles) },
            onCancel: { viewModel.cancelCurrentRequest() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { currentPanelHeight = $0 }
    }

    // MARK: - Send

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
}

#Preview {
    ContentView()
}
