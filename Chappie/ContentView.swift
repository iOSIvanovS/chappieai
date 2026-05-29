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
//   WHY ChappieDropDelegate instead of .onDrop(isTargeted:):
//   The standard isTargeted goes true for ANY dragged item including folders and blocked
//   states. We need to distinguish valid vs. invalid drops for different overlay colors.
//
//   KEY BUG FIX — validateDrop ordering:
//   On macOS, validateDrop() is called BEFORE dropEntered(). If validateDrop returns false
//   on the very first call (when dropState is still .idle), the system decides the view
//   doesn't accept drops at all and never calls dropEntered — so the overlay never appears.
//   Solution: validateDrop always returns true. The actual block/allow decision happens
//   in performDrop (after the user releases). Visual feedback is purely from dropState
//   driven by dropEntered/dropUpdated.
//
//   KEY BUG FIX — isThinking capture:
//   DropDelegate is a value type created once per render. If isThinking changes after
//   the delegate is created, the captured value is stale. Solution: pass isThinking via
//   a closure (getter) so each call reads the current value from the parent's state.
//
//   KEY BUG FIX — overlay stuck after drop (value type @Binding):
//   ChappieDropDelegate is a value type. DispatchQueue.main.async inside performDrop
//   captures a COPY of the @Binding wrapper — by the time the async block runs, SwiftUI
//   may have already recreated the delegate with a fresh copy, making the write a no-op.
//   Solution: pass resetState as a closure (like scheduleExit/cancelExit), so the block
//   always writes through the live ContentView @State reference, not a stale copy.
//
//   KEY BUG FIX — folders show blue overlay:
//   info.hasItemsConforming(to: [.fileURL]) returns true for folders too, because
//   directories also conform to .fileURL UTType. To distinguish them synchronously
//   (DropInfo has no async API), we read NSPasteboard directly and check isDirectory
//   on each URL. If ALL resolved URLs are directories → state becomes .blocked (red).
//
//   KEY BUG FIX — overlay flickers when cursor crosses child view boundaries:
//   macOS fires dropExited + dropEntered every time the cursor crosses a subview boundary
//   inside the drop zone. Without debouncing, this causes a brief .idle flash between
//   .allowed states — visible as a flicker. Solution: dropExited schedules a delayed
//   reset (exitDebounceWork) via a DispatchWorkItem stored in ContentView @State.
//   dropEntered and dropUpdated cancel the pending reset immediately, so the overlay
//   stays visible during normal in-window movement. The reset only fires if the cursor
//   truly leaves the window (no new enter/update within 80ms).
//
//   KEY BUG FIX — overlay stuck after drop (root cause):
//   macOS does NOT call dropExited after performDrop. The overlay must be reset manually.
//   Previous attempts used DispatchQueue.main.async { resetState() } — but on macOS,
//   after performDrop the drag session is still "live" for a brief moment. During that
//   window SwiftUI re-renders the delegate with a fresh copy, and the async block from
//   the old delegate may write to a stale @Binding.
//   FINAL FIX: use scheduleReset() — same DispatchWorkItem mechanism as scheduleExit(),
//   stored in ContentView @State. This guarantees the write goes to the live @State.
//   Delay is 150ms — long enough for macOS to fully tear down the drag session before
//   we clear the overlay, short enough to be imperceptible to the user.
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
private enum DropState: Equatable {
    case idle        // No drag in progress
    case allowed     // Valid files hovering, drop will succeed
    case blocked     // AI is thinking OR only incompatible items (folders, etc.)
}

// MARK: - ChappieDropDelegate

/// Custom DropDelegate for the global file-drop zone.
///
/// CRITICAL: validateDrop() is called BEFORE dropEntered() on macOS.
/// Therefore validateDrop always returns true — otherwise the system rejects the
/// drop before we ever get a chance to show the overlay. The real allow/block
/// decision is made in performDrop() after the user releases.
///
/// All state mutations go through closures (isThinkingGetter, scheduleReset,
/// scheduleExit, cancelExit) rather than captured values or @Binding writes.
/// This is required because ChappieDropDelegate is a value type: SwiftUI recreates
/// it on every render pass, so any @Binding captured by value becomes stale.
/// Closures always close over the live ContentView @State reference.
private struct ChappieDropDelegate: DropDelegate {

    /// Written by this delegate, read by the overlay to pick its color.
    @Binding var dropState: DropState
    /// Closure returning the current isThinking value — avoids stale capture.
    let isThinkingGetter: () -> Bool
    /// Called when a valid drop is performed.
    let onDrop: ([NSItemProvider]) -> Void
    /// Schedule a delayed reset of dropState to .idle — called from performDrop.
    /// Uses the same DispatchWorkItem mechanism as scheduleExit so the write always
    /// goes to the live ContentView @State, not a stale delegate copy.
    let scheduleReset: () -> Void
    /// Schedule a debounced .idle reset — called from dropExited.
    let scheduleExit: () -> Void
    /// Cancel any pending .idle reset — called from dropEntered / dropUpdated.
    let cancelExit: () -> Void

    // MARK: - DropDelegate

    func dropEntered(info: DropInfo) {
        // Cancel any pending exit/reset — cursor is back inside the window
        cancelExit()
        updateState(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Cancel any pending exit/reset — cursor moved but is still inside
        cancelExit()
        updateState(info: info)
        // Show forbidden cursor when blocked — purely cosmetic, does not gate performDrop
        return dropState == .blocked
            ? DropProposal(operation: .forbidden)
            : DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        // Schedule a delayed reset instead of resetting immediately.
        // macOS fires dropExited + dropEntered when cursor crosses a subview boundary,
        // which without debouncing causes a brief .idle flash (visible flicker).
        // If a new dropEntered arrives within 80ms, cancelExit() will abort this reset.
        scheduleExit()
    }

    func validateDrop(info: DropInfo) -> Bool {
        // MUST return true unconditionally — validateDrop fires before dropEntered,
        // so dropState is still .idle on the first call. Returning false here would
        // prevent dropEntered from ever being called and the overlay would never show.
        // Real blocking happens in performDrop().
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        // Cancel any pending debounced exit — we schedule our own reset below
        cancelExit()

        // KEY FIX — overlay stuck after drop:
        // macOS does NOT call dropExited after performDrop. We must reset the overlay
        // manually. We use scheduleReset() — a DispatchWorkItem stored in ContentView
        // @State — instead of DispatchQueue.main.async { resetState() }.
        //
        // WHY scheduleReset and not plain async:
        // After performDrop, macOS keeps the drag session alive briefly while it
        // animates the drop. During this window SwiftUI may re-render, creating a
        // fresh delegate copy. A plain async block captured from the old delegate
        // holds a stale @Binding wrapper and its write becomes a no-op.
        // scheduleReset() is a closure that always closes over the live @State in
        // ContentView — it survives re-renders and writes to the correct location.
        // The 150ms delay is imperceptible but safely outlasts the drag teardown.
        scheduleReset()

        // Read current state via @Binding — block if AI is thinking or only folders
        guard dropState == .allowed else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        onDrop(providers)
        return true
    }

    // MARK: - Private

    /// Determines whether the current drag payload is droppable and updates dropState.
    ///
    /// BUG FIX — folders show blue overlay:
    /// info.hasItemsConforming(to: [.fileURL]) returns true for folders too, because
    /// directories conform to .fileURL just like regular files. To distinguish them
    /// synchronously (DropInfo has no async API), we read NSPasteboard directly and
    /// check isDirectory on each resolved URL. If only directories are present → blocked.
    private func updateState(info: DropInfo) {
        // Block while AI is responding
        guard !isThinkingGetter() else {
            dropState = .blocked
            return
        }

        // Read URLs from pasteboard synchronously to check for real files vs. directories
        let pasteboard = NSPasteboard(name: .drag)
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            dropState = .blocked
            return
        }

        // Resolve each pasteboard item to a URL and check if it's a regular file
        let hasRegularFile = items.contains { item in
            guard
                let urlString = item.string(forType: .fileURL),
                let url = URL(string: urlString)
            else { return false }

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            // Only count it as "valid" if it exists and is NOT a directory
            return exists && !isDir.boolValue
        }

        dropState = hasRegularFile ? .allowed : .blocked
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
    // Current drag state — drives overlay color (idle / allowed / blocked).
    @State private var dropState: DropState = .idle
    // Shared debounce work item used by both scheduleExit (dropExited debounce) and
    // scheduleReset (post-drop cleanup). Stored in ContentView @State — NOT in the delegate —
    // because ChappieDropDelegate is a value type and cannot own mutable state across re-renders.
    @State private var pendingResetWork: DispatchWorkItem? = nil

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
            // Color depends on dropState: .allowed → accent, .blocked → red.
            if dropState != .idle {
                dropOverlay(state: dropState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeThread?.id)
        // DND-GLOBAL: ChappieDropDelegate handles validation and color signaling.
        // All mutable state goes through closures — never captured by value — because
        // ChappieDropDelegate is a value type and @Binding captures go stale on re-render.
        .onDrop(
            of: [.fileURL],
            delegate: ChappieDropDelegate(
                dropState: $dropState,
                isThinkingGetter: { viewModel.isThinking },
                onDrop: resolveDroppedFiles,
                scheduleReset: scheduleDropReset,
                scheduleExit: scheduleDropExit,
                cancelExit: cancelPendingReset
            )
        )
    }

    // MARK: - Drop Reset / Exit Debounce

    /// Schedules a delayed reset of dropState to .idle after a successful drop.
    /// 150ms gives macOS time to fully tear down the drag session before we clear
    /// the overlay — prevents a stale @Binding write racing with drag teardown.
    private func scheduleDropReset() {
        cancelPendingReset()
        let work = DispatchWorkItem { dropState = .idle }
        pendingResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Schedules a delayed reset of dropState to .idle when the cursor leaves the window.
    /// 80ms debounce prevents flicker when cursor crosses subview boundaries inside the window —
    /// macOS fires dropExited + dropEntered for each boundary crossing (~16ms apart).
    private func scheduleDropExit() {
        cancelPendingReset()
        let work = DispatchWorkItem { dropState = .idle }
        pendingResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Cancels any pending scheduled reset (both post-drop and exit debounce share one slot).
    /// Called from dropEntered and dropUpdated — cursor is still inside, keep overlay visible.
    private func cancelPendingReset() {
        pendingResetWork?.cancel()
        pendingResetWork = nil
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
        .animation(.easeInOut(duration: 0.15), value: dropState)
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
