// ChappieViewModel+Backup.swift
// Chappie
//
// Full-settings export/import for machine migration.
// Export: assemble bundle + encrypt → caller writes to disk.
// Import: decrypt + preview (let caller show a destructive-action warning) → applyImport
//         → reloadAfterImport() re-syncs all in-memory ViewModel state from the Stores,
//         since the import wipes providers/threads/memory out from under the running app.

import Foundation
import ChappieCore

enum BackupServiceError: LocalizedError {
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return String(localized: "settings.backup_export_service_unavailable")
        }
    }
}

extension ChappieViewModel {

    // MARK: - Export

    /// Assembles the full export bundle (providers + Keychain secrets, threads, messages,
    /// memory) and encrypts it with the given password. Returns ready-to-write file bytes.
    func exportBackup(password: String) async throws -> Data {
        guard let service = backupService else { throw BackupServiceError.serviceUnavailable }
        return try await service.exportEncrypted(password: password)
    }

    // MARK: - Import

    /// Decrypts and parses a backup file without applying it — lets the caller show a
    /// confirmation dialog (exportedAt date, provider/thread counts) before the destructive
    /// `importBackup(_:)` call.
    func previewBackup(data: Data, password: String) async throws -> ChappieExportBundle {
        guard let service = backupService else { throw BackupServiceError.serviceUnavailable }
        return try await service.decryptBundle(data, password: password)
    }

    /// Applies a full restore (destructive — wipes current providers, threads, messages,
    /// and memory) then re-syncs the running ViewModel's in-memory state from the Stores.
    func importBackup(_ bundle: ChappieExportBundle) async throws {
        guard let service = backupService else { throw BackupServiceError.serviceUnavailable }
        try await service.applyImport(bundle)
        await reloadAfterImport()
    }

    /// Re-syncs all in-memory ViewModel state from the Stores after a destructive import.
    /// The previously active provider/thread/key almost certainly no longer exist —
    /// tear down the active session first, then reload exactly like boot does.
    @MainActor
    func reloadAfterImport() async {
        currentRequestTask?.cancel()
        currentRequestTask = nil
        aiClient = nil
        orchestrator = nil
        activeProvider = nil
        activeKeyId = nil
        activeModelName = nil

        if let provStore = providerStore {
            await loadProvidersAndSetActive(from: provStore)
        }
        if let tStore = threadStore {
            await loadThreadsAndSelectActive(from: tStore)
        }
        if let mm = memoryManager, let ms = memoryStore {
            await mm.setMemoryStore(ms)
        }
        buildAndSyncMemoryContext()
    }
}
