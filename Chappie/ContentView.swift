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
//   The drop target covers mainChatArea (the full app content area).
//   This lets the user drop files anywhere in the window — not just on the input panel.
//
//   WHY DropController (@Observable class):
//   DropDelegate is a value type. When it was a struct inside ContentView, every
//   dropState change triggered a SwiftUI re-render which recreated the delegate —
//   making all pending DispatchWorkItems and @Binding writes go to stale copies.
//
//   DropController is a reference type (@Observable). Stored in ContentView @State,
//   it is created ONCE and never recreated on re-renders.
//   DropControllerDelegate is created with a direct reference to the controller.
//   All state mutations happen inside the controller — no closures, no captures.
//
//   OVERLAY COLOR:
//     .allowed → accent blue (valid files hovering)
//     .blocked → red (AI is thinking OR only folders dragged)
//
//   FOLDER DETECTION DURING DRAG:
//   hasItemsConforming(to: [.folder]) is UNRELIABLE on macOS — it checks the drag
//   session UTI list which often does NOT include "public.folder" even for folders.
//   Instead we read NSPasteboard(name: .drag) directly and check "public.folder" UTI.
//   This is the only reliable way to detect folders during an active drag on macOS.
//
//   POST-DROP RESET (DND-RESET-FIX):
//   Root problem: macOS calls dropEntered/dropUpdated continuously while the drag
//   hovers, even AFTER performDrop returns. This means the reset Task scheduled
//   inside handleDrop is immediately cancelled by the next handleEnterOrUpdate call.
//
//   Fix: introduce a `isDropPerformed` flag inside DropController. Once set to true
//   by handleDrop, handleEnterOrUpdate becomes a no-op — it no longer cancels the
//   reset or changes dropState. The flag is cleared when the reset fires.
//   This breaks the cancel loop and guarantees the overlay disappears after drop.
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
    case blocked     // AI is thinking OR only folders dragged
}

// MARK: - DropController

/// Reference-type controller for global drag & drop.
///
/// Stored as @State in ContentView — created once, never recreated on re-renders.
/// All state mutations happen inside this class so pending Tasks always
/// write to the live object, not a stale copy.
///
/// POST-DROP RESET (DND-RESET-FIX):
/// macOS keeps firing dropEntered/dropUpdated even AFTER performDrop returns.
/// Without protection, these calls cancel the reset Task before it fires.
/// Solution: isDropPerformed flag. Once set by handleDrop, enter/update events
/// are ignored until the reset Task clears the flag and sets state to .idle.
@Observable
final class DropController {

    // MARK: Public State (read by ContentView overlay via @Observable tracking)

    var dropState: DropState = .idle

    // MARK: Callbacks (set once from ContentView.onAppear)

    /// Returns true when AI is currently processing a request.
    var isThinkingGetter: () -> Bool = { false }

    /// Called with resolved providers when a valid drop is performed.
    var onFilesDropped: ([NSItemProvider]) -> Void = { _ in }

    // MARK: Private

    /// Cancellable token for the pending reset Task.
    private var resetTask: Task<Void, Never>?

    /// Set to true by handleDrop to block further enter/update processing.
    /// Cleared when the reset Task fires and state returns to .idle.
    private var isDropPerformed: Bool = false

    // MARK: - Drag Event Handlers

    /// Called from dropEntered and dropUpdated.
    /// No-op if a drop was just performed — prevents cancelling the reset Task.
    func handleEnterOrUpdate(info: DropInfo) {
        // DND-RESET-FIX: ignore re-entry events after drop until overlay resets.
        guard !isDropPerformed else { return }
        cancelPendingReset()
        dropState = computeState(info: info)
    }

    /// Called from dropExited.
    /// Schedules a debounced reset (80ms) to prevent flicker when crossing subview boundaries.
    func handleExit() {
        // DND-RESET-FIX: if drop was performed, the reset is already scheduled — don't interfere.
        guard !isDropPerformed else { return }
        scheduleReset(delay: 0.08)
    }

    /// Called from performDrop.
    /// Sets isDropPerformed flag so subsequent enter/update events don't cancel the reset.
    /// Returns true only when the drop is allowed.
    func handleDrop(info: DropInfo) -> Bool {
        guard dropState == .allowed else {
            // Even for blocked state, schedule reset in case macOS skips dropExited.
            scheduleReset(delay: 0.25)
            return false
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else {
            scheduleReset(delay: 0.25)
            return false
        }

        // Mark drop as performed BEFORE scheduling reset.
        // This prevents handleEnterOrUpdate from cancelling the reset Task
        // when macOS fires spurious enter/update events after performDrop.
        isDropPerformed = true
        scheduleReset(delay: 0.25)

        onFilesDropped(providers)
        return true
    }

    // MARK: - Private Helpers

    /// Computes the drop state from the current drag info.
    ///
    /// FOLDER DETECTION (macOS-specific):
    /// hasItemsConforming(to: [.folder]) is unreliable during drag on macOS.
    /// We read NSPasteboard(name: .drag) directly and check for "public.folder" UTI.
    /// If the drag contains ONLY folders → .blocked (red overlay, no drop).
    /// If it contains files (possibly mixed with folders) → .allowed.
    /// If AI is thinking → .blocked regardless of content.
    private func computeState(info: DropInfo) -> DropState {
        if isThinkingGetter() { return .blocked }

        // Check NSPasteboard directly — the only reliable source during drag on macOS.
        let pb = NSPasteboard(name: .drag)
        let types = pb.types ?? []
        let hasFiles = info.hasItemsConforming(to: [.fileURL])

        // "public.folder" UTI is present when at least one dragged item is a directory.
        let hasFolderUTI = types.contains(NSPasteboard.PasteboardType("public.folder"))

        // If ONLY folders dragged (no fileURL items beyond folders) → blocked.
        // We detect "only folders" by checking if folder UTI is present AND
        // all fileURL items are also folders (no plain files).
        // Simplest reliable heuristic: if hasFolderUTI and hasFiles are both true,
        // we need to distinguish "folders only" from "mixed". We do this by checking
        // whether any non-folder file UTI is present in the pasteboard types.
        if hasFolderUTI && !hasFiles { return .blocked }
        if hasFolderUTI && hasFiles {
            // Check if there are any non-folder file types alongside the folder UTI.
            // If the only file-like UTI is "public.folder", it's folders-only.
            let nonFolderFileTypes = types.filter { type in
                let uti = type.rawValue
                return uti == "public.file-url" || uti == "com.apple.pasteboard.promised-file-url"
            }
            // If no plain file UTI found → folders only → blocked.
            if nonFolderFileTypes.isEmpty { return .blocked }
        }

        return hasFiles ? .allowed : .blocked
    }

    /// Schedules a delayed reset of dropState to .idle on MainActor.
    ///
    /// WHY Task { @MainActor in }:
    /// DropDelegate callbacks on macOS may arrive on a background thread.
    /// Task { @MainActor in } guarantees the mutation executes on the main actor —
    /// which is required for @Observable to notify SwiftUI's observation machinery.
    private func scheduleReset(delay: Double) {
        cancelPendingReset()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isDropPerformed = false
            self?.dropState = .idle
        }
    }

    /// Cancels any pending scheduled reset.
    private func cancelPendingReset() {
        resetTask?.cancel()
        resetTask = nil
    }
}

// MARK: - DropControllerDelegate

/// DropDelegate that forwards all calls to DropController.
///
/// Created once inside ContentView.onAppear and passed to .onDrop — never recreated.
/// Holds a strong reference to DropController (both live in ContentView @State).
final class DropControllerDelegate: DropDelegate {

    private let controller: DropController

    init(controller: DropController) {
        self.controller = controller
    }

    func dropEntered(info: DropInfo) {
        controller.handleEnterOrUpdate(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        controller.handleEnterOrUpdate(info: info)
        // Show forbidden cursor for blocked state — visual hint to user
        return controller.dropState == .blocked
            ? DropProposal(operation: .forbidden)
            : DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        controller.handleExit()
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Always return true — on macOS validateDrop fires BEFORE dropEntered.
        // Returning false here would prevent dropEntered from ever being called,
        // so the overlay would never appear.
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
    @State private var dropController = DropController()

    // DND-GLOBAL: delegate is created once in onAppear and stored here — never recreated.
    // Stored as optional because we need dropController to be fully initialized first.
    @State private var dropDelegate: DropControllerDelegate? = nil

    @State private var selectedProjectForSettings: ProjectMetadata? = nil
    /// Thread whose settings sheet is currently open.
    @State private var selectedThreadForSettings: ThreadMetadata? = nil

    // Heights reported by floating panels — used as transparent spacers in ChatScrollView.
    @State private var topPanelHeight: CGFloat = 0
    @State private var bottomPanelHeight: CGFloat = 0

    // Safe area top inset (= toolbar height).
    // Read via .background(GeometryReader) on ChatScrollView — NOT from a GeometryReader
    // placed in the layout tree to avoid horizontal greediness that prevents narrow windows.
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

            // Wire DropController callbacks — done once, not on every render.
            dropController.isThinkingGetter = { [self] in viewModel.isThinking }
            dropController.onFilesDropped = { [self] providers in
                resolveDroppedFiles(providers)
            }

            // Create delegate once — it holds a stable reference to the controller.
            dropDelegate = DropControllerDelegate(controller: dropController)
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
        // DND-GLOBAL: use delegate if ready, otherwise use a simple closure-based drop
        // that only accepts file URLs (fallback for the brief window before onAppear fires).
        .onDrop(of: [.fileURL], delegate: dropDelegate ?? DropControllerDelegate(controller: dropController))
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

            // Load and append files on main actor with deduplication
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
