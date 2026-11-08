// ContentView+Panels.swift
// Chappie
//
// mainChatArea, topPanel, bottomPanel, threadSwitchOverlay.

import SwiftUI
import UniformTypeIdentifiers
import ChappieCore

extension ContentView {

    // MARK: - Thread Switch Overlay

    var threadSwitchOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.1)
                    .tint(.white)

                Text("chat.loading")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
        }
        .allowsHitTesting(true)
        .ignoresSafeArea()
    }

    // MARK: - Main Chat Area

    var mainChatArea: some View {
        ZStack(alignment: .top) {

            ChatScrollView(
                scrollToBottomTrigger: viewModel.scrollToBottomTrigger,
                messages: viewModel.displayedMessages,
                hasMoreMessages: viewModel.hasMoreMessages,
                onLoadMore: { viewModel.loadMoreMessages() },
                streaming: viewModel.streaming,
                isLoadingHistory: viewModel.isLoadingMessages,
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
        .background(WindowDragArea())
        .onDrop(of: [.fileURL, .folder, .data] + officeUTTypes, delegate: dropDelegate)
    }

    // MARK: - Top Floating Panel

    var topPanel: some View {
        VStack(spacing: 6) {

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

    var bottomPanel: some View {
        InputMorphView(
            prompt: $prompt,
            attachments: $attachments,
            isWorkspaceSelected: true,
            streaming: viewModel.streaming,
            onSend: { attachedFiles in sendMessage(attachments: attachedFiles) },
            onCancel: { viewModel.cancelCurrentRequest() }
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { currentPanelHeight = $0 }
    }
}
