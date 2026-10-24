// ContentView+MainContent.swift
// Chappie
//
// mainContent: assembles all sheets, alerts, and the navigation layer.
// navigationContent: toolbar, sidebar overlay, thread-switch overlay.

import SwiftUI
import ChappieCore

extension ContentView {

    // MARK: - Main App Content

    var mainContent: some View {
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
                    onChangePlan: { showLicenseActivation = true },
                    onDetectEnvironment: { completion in
                        let live = viewModel.activeProjects.first(where: { $0.id == project.id }) ?? project
                        viewModel.detectDevEnvironment(for: live, completion: completion)
                    },
                    onUpdatePath: { newPath in
                        viewModel.updateProjectPath(newPath, forProjectId: project.id)
                    }
                )
            }
            .sheet(item: $selectedThreadForSettings) { thread in
                ThreadSettingsSheet(
                    thread: thread,
                    providers: viewModel.providers,
                    canExecuteTools: viewModel.canExecuteTools,
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
                    onDismiss: { selectedThreadForSettings = nil },
                    onChangePlan: { showLicenseActivation = true }
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

    var navigationContent: some View {
        // Toolbar inputs are snapshotted into plain values/bindings so the toolbar closure
        // does not capture the whole ContentView struct (crashed in SwiftUI's copy on macOS 27).
        let hasProviders = !viewModel.providers.isEmpty
        let isThinking = viewModel.streaming.isThinking
        let sidebarBinding = $isSidebarVisible
        let settingsBinding = $showSettings

        return ZStack(alignment: .topLeading) {

            mainChatArea
                .toolbar {
                    ChappieToolbarContent(
                        isApiKeyValid: hasProviders,
                        isSidebarVisible: sidebarBinding,
                        isThinking: isThinking,
                        onOpenSettings: { settingsBinding.wrappedValue = true }
                    )
                }

            if viewModel.isLoadingMessages {
                threadSwitchOverlay
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: viewModel.isLoadingMessages)
                    .zIndex(10)
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
}
