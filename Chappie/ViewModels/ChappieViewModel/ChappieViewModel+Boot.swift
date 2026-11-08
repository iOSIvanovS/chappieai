// ChappieViewModel+Boot.swift
// Chappie
//
// App boot sequence: bootStorage, bootStores — wires SQLiteStorage and all Stores.

import Foundation
import ChappieCore

extension ChappieViewModel {

    /// Initializes SQLiteStorage and wires all Stores. Called once from ChappieApp.onAppear.
    func bootStorage() {
        guard chappieDataStore == nil else { return }

        guard let sqliteURL = try? SQLiteStorage.defaultURL,
              let sqliteStore = try? SQLiteStorage(url: sqliteURL) else {
            print("[ChappieViewModel] ❌ SQLiteStorage init failed — cannot start")
            return
        }

        bootStores(with: sqliteStore)
    }

    /// Initializes all Stores with the given backend and starts the app boot sequence.
    func bootStores(with storage: any ChappieStorage) {
        self.chappieDataStore = storage

        let store = MemoryStore(dataStore: storage)
        self.memoryStore = store

        let tStore = ThreadStore(
            dataStore: storage,
            recoveredThreadTitle: String(localized: "recovered_thread.title")
        )
        self.threadStore = tStore

        let provStore = AIProviderStore(dataStore: storage)
        self.providerStore = provStore

        let settingsStore = AppSettingsStore(dataStore: storage)
        self.appSettingsStore = settingsStore

        self.backupService = BackupService(threadStore: tStore, memoryStore: store, providerStore: provStore)

        // Initialize services immediately — even without a workspace URL.
        // WHY: orchestrator requires toolService/fileSystem/memoryManager to be non-nil.
        let placeholderURL = FileManager.default.homeDirectoryForCurrentUser
        if toolService == nil {
            initializeServices(for: placeholderURL)
        }

        if let mm = memoryManager { Task { await mm.setMemoryStore(store) } }

        print("[ChappieViewModel] Storage connected: \(type(of: storage))")

        if let ts = toolService {
            registerProjectToolHandlers(toolService: ts)
        }

        Task {
            await preloadLastActiveThreadId()
            await refreshBalanceCacheIfNeeded()

            await loadWorkspaceFromStore(settingsStore)

            await loadProvidersAndSetActive(from: provStore)
            await loadThreadsAndSelectActive(from: tStore)
        }
    }
}
