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
// THREAD SWITCH OVERLAY (UX-SWITCH):
//   While isLoadingMessages == true: a full-window dim overlay with spinner blocks input.
//   The toolbar (sidebar button + settings) is NOT blocked — it sits above the overlay in ZStack.
//   Overlay fades in/out with .easeInOut(0.15).
//
// CPU-08: onGeometryChange instead of GeometryReader — pure side-effect, no layout loop.
// CPU-13: streaming state isolated to ChatScrollView + InputMorphView — not read in body.
// CPU-22: currentPanelHeight measured directly from rendered InputMorphView.
// BUG-01: loadMoreAnchorId anchors scroll position after message prepend.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import ChappieCore

struct ContentView: View {

    // WHY @Bindable + init:
    // @Environment(ChappieViewModel.self) does not support $ (Binding) syntax.
    // Solution: receive the value via init from environment, store as @Bindable.
    // This is the standard Apple-recommended pattern for @Observable + Bindings in SwiftUI.
    @Bindable var viewModel: ChappieViewModel

    init(viewModel: ChappieViewModel) {
        self.viewModel = viewModel
    }

    @State var prompt: String = ""
    @State var showSettings: Bool = false
    @State var isSidebarVisible: Bool = false
    @State var showLicenseActivation: Bool = false

    @State var attachments: [AttachedFile] = []
    @State var dropDelegate = SilentDropDelegate()

    @State var selectedProjectForSettings: ProjectMetadata? = nil
    @State var selectedThreadForSettings: ThreadMetadata? = nil

    @State var topPanelHeight: CGFloat = 0
    @State var safeAreaTop: CGFloat = 0

    // CPU-22: measured directly from rendered InputMorphView via onGeometryChange
    @State var currentPanelHeight: CGFloat = InputLayout.minPanelHeight

    // CPU-11: cancelled on every new keystroke, fires draft save after 300ms idle
    @State var draftDebounceTask: Task<Void, Never>? = nil

    @State var appState = AppState.shared

    var orphanedThreadIds: Set<UUID> { [] }
    let sidebarWidth: CGFloat = 260

    var body: some View {
        Group {
            if !viewModel.isAppReady {
                ProgressView(String(localized: "content.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.shouldShowEULA {
                EULAView()
            } else if appState.shouldShowOnboarding {
                OnboardingView(viewModel: viewModel)
            } else if viewModel.shouldShowPaywall {
                paywallContent
            } else {
                mainContent
            }
        }
        // Attached to the root, not to mainContent: a write can fail during boot, before the main
        // screen exists, and the save queue would then wait for a decision nobody can make.
        .overlay(alignment: .top) {
            if viewModel.storageIssue != nil {
                StorageIssueBanner(text: viewModel.storageIssueText) { viewModel.dismissStorageIssue() }
                    .padding(.top, safeAreaTop)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.storageIssue)
        .alert("save_error.title", isPresented: saveErrorBinding) {
            Button("save_error.retry") { viewModel.retryFailedSave() }
            Button("save_error.skip", role: .cancel) { viewModel.skipFailedSave() }
        } message: {
            Text(viewModel.saveFailureMessage)
        }
        .onAppear {
            dropDelegate.isThinkingGetter = { [self] in viewModel.streaming.isThinking }
            dropDelegate.onFilesDropped   = { [self] providers in resolveDroppedFiles(providers, attachments: $attachments) }
            dropDelegate.onFoldersDropped = { [self] providers in resolveFolderDrop(providers, addProject: { viewModel.addProject(url: $0) }) }
            dropDelegate.onImageProviders = { [self] providers in resolveImageProviders(providers, attachments: $attachments) }
        }
        .onChange(of: viewModel.providers.count) { _, _ in }
    }

    /// Only the two alert buttons resolve the failure (the queue clears it itself), so the
    /// setter is a deliberate no-op.
    private var saveErrorBinding: Binding<Bool> {
        Binding(get: { viewModel.saveFailure != nil }, set: { _ in })
    }

    // MARK: - Thread for Settings

    func buildThreadForSettings(_ thread: ThreadMetadata) -> ThreadMetadata {
        ThreadMetadata(
            id: thread.id,
            title: thread.title,
            settings: viewModel.activeThreadSettings,
            projects: thread.projects,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt
        )
    }

    // MARK: - Send

    func sendMessage(attachments: [AttachedFile]) {
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
    ContentView(viewModel: ChappieViewModel())
}
