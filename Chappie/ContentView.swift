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
// SIDEBAR BEHAVIOR:
// The sidebar slides in from the left OVER the chat content — it does not push it.
// Triggered by the "list.bullet" toolbar button.
// Dismissed by clicking the dimmed area to the right of the sidebar.
// Animation: spring, consistent with macOS feel.
//
// FLOATING PANELS:
//   Top panel: ModelPickerRow + ProjectChipsView — each is an independent floating
//   rounded pill with ultraThinMaterial. The outer VStack is transparent.
//   Bottom panel: InputMorphView — ultraThinMaterial.
//   Both panels report their heights so ChatScrollView can add matching spacers.
//
// TOOLBAR (IT-12 / IT-13):
//   ultraThinMaterial background — frosted glass matching the panels.
//   Contains: sidebar toggle (list.bullet), settings gear.
//   Both buttons disabled while isThinking (IT-13).
//   Thread title is NOT in the toolbar — it lives in ProjectChipsView gear chip.
//   Balance is NOT in the toolbar — it lives in ModelPickerRow as a right-side pill.
//
// THREAD NAME IN CHIPS (IT-12):
//   ProjectChipsView receives threadName = viewModel.activeThread?.title.
//   The right-side chip shows "⚙ <thread name>" — user always sees which thread is active.
//   Tapping the chip opens ThreadSettingsSheet.
//
// HEADER HEIGHT:
//   headerHeight = topPanelHeight + safeAreaTop.
//   safeAreaTop is read via .background(GeometryReader) on ChatScrollView.
//   WHY .background: GeometryReader in .background does NOT participate in layout —
//   it is measured AFTER the parent has already determined its own size.
//   A GeometryReader placed directly in the layout tree (even with .frame(height:0))
//   is still greedy in the horizontal axis and prevents the window from being resized
//   narrower than its initial width. Using .background avoids this entirely.
//
// BALANCE PILL:
//   Lives inside ModelPickerRow (right side). Receives viewModel.currentBalance.
//   Updates live during streaming via onBalanceUpdate callback in AIOrchestrator.
//
// DRAFT PER THREAD (UX-DRAFT):
//   prompt is synced with viewModel.threadDrafts on every thread switch.
//   onChange(of: viewModel.activeThread?.id) saves old draft, restores new one.
//   onChange(of: prompt) writes the current text into the draft for the active thread.
//   On send: draft is cleared via viewModel.clearDraft().
//   This ensures each thread remembers its own unsent text across switches.
//
// THREAD SETTINGS SHEET (IT-11 / IT-12):
//   selectedThreadForSettings: ThreadMetadata? — opened from two places:
//   1. Context menu in ThreadRowView (sidebar) — gear removed from row hover buttons.
//   2. Thread name + gear chip in ProjectChipsView.
//   Both set selectedThreadForSettings → .sheet(item:) shows ThreadSettingsSheet.
//   onSave → viewModel.updateThreadSettings() → title + settings persisted.
//
// LAST ACTIVE THREAD (UX-RESTORE):
//   ViewModel saves lastActiveThreadId on every selectThread() call.
//   On startup, loadThreadsAndSelectActive() restores it.
//   No ContentView changes needed — all logic in ViewModel.
//
// NEW THREAD SHEET (IT-12):
//   NewThreadProviderSheet now returns (providerId, modelName, title, ThreadSettings).
//   confirmNewThread() accepts all four and saves title + settings immediately.
//
// SOFT LOCK (isThinking) — IT-13:
//   isThinking is forwarded to ChappieToolbarContent, SidebarView, ModelPickerRow,
//   and ProjectChipsView. While true: toolbar buttons, thread switching/deletion/rename/
//   settings, model picker, project attach/detach, and thread settings gear are all disabled.
//   This prevents race conditions when AI is writing a response.
//
// AUTO-CLOSE SETTINGS (IT-13 / TASK-5):
//   onChange(of: viewModel.isThinking): when isThinking becomes true and showSettings
//   is open — the sheet is dismissed automatically (showSettings = false).
//   This handles the edge case where the user opened Settings and then a response
//   arrived (e.g. triggered from another thread or via a background event).
//
// PAGINATION (UX-PAGINATION):
//   ChatScrollView receives displayedMessages (paginated slice) instead of visibleMessages.
//   hasMoreMessages and onLoadMore are forwarded so the "Load earlier" button works.
//   visibleMessages is still used for network context — not for UI rendering.
//
// SCROLL TRIGGER FIX (UX-SCROLL-TRIGGER):
//   ChatScrollView receives scrollToBottomTrigger instead of threadId.
//   ViewModel increments this value at the END of resetPagination() — after
//   displayedMessages is fully populated. This prevents "bad range" crashes
//   that occurred when scrollTo fired before VStack had the new thread's content.
//
// LOADING HISTORY INDICATOR (UX-LOADING):
//   ChatScrollView receives isLoadingHistory = viewModel.isLoadingThread.
//   While true: a centered ProgressView is shown instead of messages or welcome screen.
//   This prevents the "flash of welcome message" on app launch.
//
// APP READY FLAG (UX-APP-READY):
//   ContentView shows a ProgressView until viewModel.isAppReady == true.
//   isAppReady is set by ViewModel at the end of the FIRST selectThread() call.
//   This replaces the old isReady + 300ms timer approach that caused a welcome-screen
//   flash: the timer could expire while isLoadingThread was already false but messages
//   were still empty — producing one rendered frame with the welcome message visible.
//   With isAppReady, the app becomes "visible" only after history is fully loaded.
//
// MULTIMODAL (MULTIMODAL-STEP2):
//   InputMorphView.onSend now carries [AttachedFile].
//   sendMessage(attachments:) forwards them to viewModel.send(prompt:attachments:).
//   Attachments are cleared inside InputMorphView after triggerSend fires.
//
// DRAG & DROP (DND-GLOBAL):
//   attachments state lives in ContentView and is passed to InputMorphView via @Binding.
//   The drop target is mainChatArea (the full app content area), NOT InputMorphView.
//   This lets the user drop files anywhere in the window — not just on the input panel.
//
//   WHY DropController (@Observable class) instead of ChappieDropDelegate (value type):
//   ChappieDropDelegate was a struct (value type). Every time dropState changed, SwiftUI
//   re-rendered ContentView and created a NEW delegate instance with fresh closures.
//   Any DispatchWorkItem or @Binding captured by the old delegate became stale —
//   writes from pending async blocks went to dead copies, so the overlay never cleared.
//   DropController is a reference type (@Observable). It lives as @State in ContentView
//   and is never recreated on re-renders. Its dropState property drives the overlay.
//   The delegate is stored inside DropController as a regular property — not recreated.
//
//   KEY DESIGN: DropController owns:
//     - dropState: DropState  (read by ContentView overlay)
//     - delegate: DropControllerDelegate  (passed to .onDrop once, stable reference)
//     - pendingWork: DispatchWorkItem?  (debounce / post-drop reset)
//   All state mutations happen inside DropController methods — no closures, no captures.
//
//   resolveDroppedFiles() runs URL resolution on a background Task, appends on @MainActor.
//   Folders are silently skipped (isDirectory check inside resolveDroppedFiles).
//
// IT-09: Added project settings sheet.
// IT-10: Universal AI Provider (two-level: provider → model).
// IT-11: Thread settings sheet, last-thread restore.
// IT-12: Thread name in ProjectChipsView chip, gear removed from ThreadRowView hover,
//        NewThreadProviderSheet extended with name + context settings.
// IT-13: Soft lock — toolbar, sidebar, model picker, project chips disabled while isThinking.
//        Auto-close SettingsView when isThinking becomes true (TASK-5).

import SwiftUI
import UniformTypeIdentifiers
import SwiftData
import ChappieCore

// MARK: - Drop State

/// Describes the current drag-over state for the global drop target.
/// Drives overlay color: .allowed → accent blue, .blocked → red.
enum DropState: Equatable {
    case idle        // No drag in progress
    case allowed     // Valid files hovering, drop will succeed
    case blocked     // AI is thinking OR only incompatible items (folders, etc.)
}

// MARK: - DropController

/// Reference-type controller for global drag & drop.
///
/// WHY A CLASS:
/// DropDelegate is a value type. When it was a struct inside ContentView, every
/// dropState change triggered a SwiftUI re-render which recreated the delegate —
/// making all pending DispatchWorkItems and @Binding writes go to stale copies.
///
/// As an @Observable class stored in ContentView @State:
///   - It is created ONCE and never recreated on re-renders.
///   - dropState is a stored property — mutations are always live.
///   - pendingWork is a stored property — cancel/schedule always hits the real item.
///   - The inner DropControllerDelegate holds an unowned ref to the controller.
@Observable
final class DropController {

    // MARK: - Public State (read by ContentView overlay)

    var dropState: DropState = .idle

    // MARK: - Internal Delegate

    /// Stored as a regular property (not lazy) — @Observable does not support lazy var.
    /// Created in init() after self is fully initialized.
    let delegate: DropControllerDelegate

    // MARK: - Private

    private var pendingWork: DispatchWorkItem?

    /// isThinking getter — set by ContentView so we always read the current value.
    var isThinkingGetter: () -> Bool = { false }
    /// Called when a valid drop is performed with the resolved providers.
    var onDrop: ([NSItemProvider]) -> Void = { _ in }

    // MARK: - Init

    init() {
        // Temporary placeholder — replaced immediately below.
        // Swift requires all stored properties to be initialized before self can be used.
        let placeholder = DropControllerDelegate.__placeholder
        delegate = placeholder
        // Now self is fully initialized — wire the real delegate.
        delegate.controller = self
    }

    // MARK: - State Mutations

    /// Called from dropEntered / dropUpdated: cancel pending reset and update state.
    func handleEnterOrUpdate(info: DropInfo) {
        cancelPending()
        updateState(info: info)
    }

    /// Called from dropExited: schedule debounced reset (80ms).
    /// macOS fires dropExited + dropEntered on every subview boundary crossing.
    /// The debounce prevents flickering — if dropEntered arrives within 80ms, the reset is cancelled.
    func handleExit() {
        schedulePending(delay: 0.08)
    }

    /// Called from performDrop: cancel pending exit, schedule post-drop reset (150ms).
    /// macOS does NOT call dropExited after performDrop — we must reset manually.
    /// 150ms safely outlasts the drag session teardown animation.
    func handleDrop(info: DropInfo) -> Bool {
        cancelPending()
        schedulePending(delay: 0.15)

        guard dropState == .allowed else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        onDrop(providers)
        return true
    }

    // MARK: - Private Helpers

    /// Updates dropState based on current drag payload and isThinking.
    private func updateState(info: DropInfo) {
        guard !isThinkingGetter() else {
            dropState = .blocked
            return
        }

        // Read URLs from pasteboard synchronously — DropInfo has no sync URL API.
        // We need to distinguish real files from directories before showing the overlay.
        let pasteboard = NSPasteboard(name: .drag)
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            dropState = .blocked
            return
        }

        let hasRegularFile = items.contains { item in
            guard
                let urlString = item.string(forType: .fileURL),
                let url = URL(string: urlString)
            else { return false }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && !isDir.boolValue
        }

        dropState = hasRegularFile ? .allowed : .blocked
    }

    /// Schedules a delayed reset of dropState to .idle.
    /// Any previously pending work is cancelled first (single slot).
    private func schedulePending(delay: Double) {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in
            self?.dropState = .idle
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cancels any pending scheduled reset.
    private func cancelPending() {
        pendingWork?.cancel()
        pendingWork = nil
    }
}

// MARK: - DropControllerDelegate

/// DropDelegate that forwards all calls to DropController.
/// Holds a strong reference to the controller — lifetime is tied to ContentView @State.
///
/// validateDrop always returns true — on macOS validateDrop fires BEFORE dropEntered.
/// Returning false here would prevent dropEntered from ever being called.
final class DropControllerDelegate: DropDelegate {

    // Strong ref — controller owns delegate, delegate refs controller back.
    // Both live inside ContentView @State so there is no retain cycle with the view.
    var controller: DropController!

    // Placeholder instance used during DropController.init() two-phase setup.
    static let __placeholder = DropControllerDelegate()

    init() {}

    func dropEntered(info: DropInfo) {
        controller.handleEnterOrUpdate(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        controller.handleEnterOrUpdate(info: info)
        return controller.dropState == .blocked
            ? DropProposal(operation: .forbidden)
            : DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        controller.handleExit()
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Must always return true — validateDrop fires before dropEntered on macOS.
        // Returning false here prevents the overlay from ever appearing.
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        return controller.handleDrop(info: info)
    }
}

// MARK: - ContentView

struct ContentView: View {

    @State private var viewModel = ChappieViewModel()
    @State private var prompt: String = ""
    @State private var showSettings: Bool = false
    @State private var isSidebarVisible: Bool = false

    // DND-GLOBAL: attachments owned here so the whole-window drop target can write to them.
    // Passed to InputMorphView via @Binding — InputMorphView reads and clears them on send.
    @State private var attachments: [AttachedFile] = []

    // DND-GLOBAL: DropController is a reference type — created once, never recreated on re-renders.
    // This is the fix for the "overlay stuck" bug: value-type delegates captured stale @Binding
    // copies on every re-render. DropController owns its state and is always the same object.
    @State private var dropController = DropController()

    @State private var selectedProjectForSettings: ProjectMetadata? = nil
    /// Thread whose settings sheet is currently open.
    /// Opened from sidebar context menu or ProjectChipsView gear chip.
    @State private var selectedThreadForSettings: ThreadMetadata? = nil

    // Heights reported by floating panels — used as transparent spacers in ChatScrollView.
    @State private var topPanelHeight: CGFloat = 0
    @State private var bottomPanelHeight: CGFloat = 0

    // Safe area top inset (= toolbar height).
    // Read via .background(GeometryReader) on ChatScrollView — NOT from a GeometryReader
    // placed in the layout tree. A layout-tree GeometryReader is greedy in the horizontal
    // axis even with .frame(height: 0), which prevents the window from being resized
    // narrower than its initial width.
    @State private var safeAreaTop: CGFloat = 0

    @Environment(\.modelContext) private var modelContext

    private var orphanedThreadIds: Set<UUID> { [] }

    // Sidebar width — fixed, matches standard macOS sidebar proportions
    private let sidebarWidth: CGFloat = 260

    var body: some View {
        Group {
            if !viewModel.isAppReady {
                // UX-APP-READY: show a spinner until the first selectThread() completes.
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
            // Wire DropController callbacks — done once here, not on every render.
            dropController.isThinkingGetter = { viewModel.isThinking }
            dropController.onDrop = resolveDroppedFiles
        }
        .onChange(of: viewModel.providers.count) { _, newCount in
            _ = newCount
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
            .sheet(item: $selectedThreadForSettings) { thread in
                // IT-11/IT-12: Thread settings sheet — opened from sidebar or ProjectChipsView chip
                ThreadSettingsSheet(
                    thread: thread,
                    onSave: { newTitle, newSettings in
                        viewModel.updateThreadSettings(
                            newSettings,
                            newTitle: newTitle,
                            forThreadId: thread.id
                        )
                        selectedThreadForSettings = nil
                    },
                    onDismiss: {
                        selectedThreadForSettings = nil
                    }
                )
            }
            .sheet(isPresented: $viewModel.showNewThreadProviderPicker) {
                // IT-12: extended sheet — also returns thread title and ThreadSettings
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

            // MIDDLE LAYER: main app content — chat + floating panels
            mainChatArea
                .toolbar {
                    // IT-13: isThinking forwarded — disables toolbar buttons while AI responds
                    ChappieToolbarContent(
                        isApiKeyValid: !viewModel.providers.isEmpty,
                        isSidebarVisible: $isSidebarVisible,
                        isThinking: viewModel.isThinking,
                        onOpenSettings: { showSettings = true }
                    )
                }

            // FRONT LAYER: dim overlay + sidebar (only when visible)
            if isSidebarVisible {
                // Dim overlay — tapping it closes the sidebar
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSidebarVisible = false
                        }
                    }
                    .transition(.opacity)

                // Floating sidebar panel
                // IT-13: isThinking forwarded — disables thread switching/deletion while AI responds
                SidebarView(
                    isApiKeyValid: !viewModel.providers.isEmpty,
                    threads: viewModel.threads,
                    selectedThreadId: viewModel.activeThread?.id,
                    orphanedThreadIds: orphanedThreadIds,
                    isThinking: viewModel.isThinking,
                    onOpenSettings: {
                        showSettings = true
                        isSidebarVisible = false
                    },
                    onSelectThread: { thread in
                        if let currentId = viewModel.activeThread?.id {
                            viewModel.setDraft(prompt, for: currentId)
                        }
                        Task { await viewModel.selectThread(thread) }
                    },
                    onCreateThread: {
                        if let currentId = viewModel.activeThread?.id {
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
            if let threadId = viewModel.activeThread?.id {
                viewModel.setDraft(newValue, for: threadId)
            }
        }
        // TASK-5 (IT-13): auto-close SettingsView when AI starts responding.
        .onChange(of: viewModel.isThinking) { _, thinking in
            if thinking && showSettings {
                showSettings = false
            }
        }
    }

    // MARK: - Main Chat Area

    /// Chat content: scroll view + floating top and bottom panels + global drop target.
    private var mainChatArea: some View {
        ZStack(alignment: .top) {

            // BACK: full-screen scroll view.
            ChatScrollView(
                scrollToBottomTrigger: viewModel.scrollToBottomTrigger,
                messages: viewModel.displayedMessages,
                hasMoreMessages: viewModel.hasMoreMessages,
                onLoadMore: { viewModel.loadMoreMessages() },
                isThinking: viewModel.isThinking,
                isLoadingHistory: viewModel.isLoadingThread,
                streamingText: viewModel.streamingText,
                runningCost: viewModel.runningCost,
                headerHeight: topPanelHeight + safeAreaTop,
                footerHeight: bottomPanelHeight
            )
            .ignoresSafeArea(edges: .top)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { safeAreaTop = geo.safeAreaInsets.top }
                        .onChange(of: geo.safeAreaInsets.top) { _, v in safeAreaTop = v }
                }
            )

            // FRONT: floating panels — transparent container, each pill floats independently
            VStack(spacing: 0) {
                topPanel
                Spacer()
                bottomPanel
            }

            // DND-GLOBAL: full-window drop overlay — shown only while drag is hovering.
            // dropController.dropState is @Observable — reads here are tracked automatically.
            if dropController.dropState != .idle {
                dropOverlay(state: dropController.dropState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeThread?.id)
        // DND-GLOBAL: delegate is stored inside DropController — not recreated on re-renders.
        .onDrop(of: [.fileURL], delegate: dropController.delegate)
    }

    // MARK: - Drop Overlay

    /// Full-window overlay shown while a drag hovers over the app.
    /// Color reflects whether the drop is allowed (accent) or blocked (red).
    @ViewBuilder
    private func dropOverlay(state: DropState) -> some View {
        let isBlocked = state == .blocked
        let color: Color = isBlocked ? .red : .accentColor

        ZStack {
            // Semi-transparent tint
            color.opacity(0.08)
                .ignoresSafeArea()

            // Dashed border around the whole window
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    color.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2.5, dash: [10, 6])
                )
                .padding(12)

            // Central hint — message changes based on state
            VStack(spacing: 12) {
                Image(systemName: isBlocked ? "nosign" : "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(color)
                Text(isBlocked
                     ? (viewModel.isThinking ? "Подожди — я думаю…" : "Папки не поддерживаются")
                     : "Отпусти для прикрепления")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .allowsHitTesting(false) // Overlay is visual-only — drop events pass through
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .animation(.easeInOut(duration: 0.15), value: dropController.dropState)
    }

    // MARK: - Top Floating Panel

    /// Top panel: transparent container holding floating pill rows.
    private var topPanel: some View {
        VStack(spacing: 6) {
            if viewModel.activeThread != nil && !viewModel.providers.isEmpty {
                ModelPickerRow(
                    activeProvider: viewModel.activeProvider,
                    activeModelName: viewModel.activeModelName,
                    providers: viewModel.providers,
                    isOrphaned: viewModel.isThreadOrphaned,
                    balance: viewModel.currentBalance,
                    isThinking: viewModel.isThinking,
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
                    isThinking: viewModel.isThinking,
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
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { topPanelHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in topPanelHeight = h }
            }
        )
    }

    // MARK: - Bottom Floating Panel

    /// Bottom panel: InputMorphView — ultraThinMaterial frosted glass.
    /// attachments are owned by ContentView and shared via @Binding so the
    /// whole-window drop target (mainChatArea) can append files directly.
    private var bottomPanel: some View {
        InputMorphView(
            prompt: $prompt,
            attachments: $attachments,
            isWorkspaceSelected: viewModel.workspaceURL != nil,
            isThinking: viewModel.isThinking,
            currentToolCall: viewModel.currentToolCall,
            onSend: { attachedFiles in
                sendMessage(attachments: attachedFiles)
            },
            onCancel: { viewModel.cancelCurrentRequest() }
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { bottomPanelHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in bottomPanelHeight = h }
            }
        )
    }

    // MARK: - Private Helpers

    /// Sends the current prompt + attachments to the ViewModel.
    /// Clears the prompt and draft immediately on send.
    private func sendMessage(attachments: [AttachedFile]) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else { return }
        if let threadId = viewModel.activeThread?.id {
            viewModel.clearDraft(for: threadId)
        }
        viewModel.send(prompt: prompt, attachments: attachments)
        prompt = ""
    }

    /// Resolves NSItemProvider array from a drop event into AttachedFile objects.
    ///
    /// URL resolution runs inside a Task (background-safe). AttachedFile.load() is @MainActor,
    /// so the actual file loading and appending happen on the main actor via MainActor.run.
    /// Directories are explicitly skipped — only regular files are accepted.
    private func resolveDroppedFiles(_ providers: [NSItemProvider]) {
        Task {
            // Collect raw URLs from all providers first (background-safe)
            var urls: [URL] = []
            for provider in providers {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                    continue
                }
                // loadItem callback is not async — bridge via withCheckedContinuation
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

            // Filter out directories — only regular files are supported
            let fileURLs = urls.filter { url in
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return exists && !isDir.boolValue
            }

            // AttachedFile.load() is @MainActor — run on main actor with deduplication
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
