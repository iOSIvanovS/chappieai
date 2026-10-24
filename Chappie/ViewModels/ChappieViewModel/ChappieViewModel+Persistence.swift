// ChappieViewModel+Persistence.swift
// Chappie
//
// Write helpers on top of SaveQueue (ordered writes, errors shown to the user) and
// the storage-damage banner. Replaces scattered `Task { try? await store.save... }`.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Messages

    /// Queues a save of the in-memory message window. Snapshots are full and the latest wins,
    /// so a pending older snapshot of the same thread is dropped instead of written.
    func persistMessages(
        _ snapshot: [ChatMessage],
        threadId: UUID,
        refreshThreadList: Bool = false
    ) {
        guard let store = threadStore else { return }
        let fromChunk = loadedWindowStartChunk

        var afterSuccess: SaveQueue.Completion?
        if refreshThreadList {
            afterSuccess = { [weak self] in
                if let refreshed = try? await store.loadThreads() { self?.threads = refreshed }
            }
        }

        saveQueue.enqueue(
            label: "save messages",
            coalesceKey: "messages.\(threadId)",
            afterSuccess: afterSuccess
        ) {
            try await store.saveLoadedMessages(snapshot, toThreadId: threadId, fromChunk: fromChunk)
        }
    }

    // MARK: - Thread list changes

    /// Persists thread settings and waits until the write succeeded or the user skipped it.
    func persistThreadSettings(_ settings: ThreadSettings, threadId: UUID) async {
        guard let store = threadStore else { return }
        await saveQueue.submit(label: "save thread settings") {
            try await store.updateSettings(settings, forThreadId: threadId)
        }
    }

    func persistThreadTitle(_ title: String, threadId: UUID) async {
        guard let store = threadStore else { return }
        await saveQueue.submit(label: "rename thread") {
            try await store.renameThread(id: threadId, title: title)
        }
    }

    // MARK: - Save-error alert

    var saveFailureMessage: String {
        let reason = saveFailure?.reason ?? ""
        return String(format: String(localized: "save_error.message"), reason)
    }

    func retryFailedSave() { saveQueue.retry() }
    func skipFailedSave() { saveQueue.skip() }

    // MARK: - Storage damage banner

    /// Pulls damage reports collected by ThreadStore and shows the first one.
    func collectStorageIssues() async {
        guard let store = threadStore else { return }
        let issues = await store.takeIntegrityIssues()
        if storageIssue == nil { storageIssue = issues.first }
    }

    var storageIssueText: String {
        guard let issue = storageIssue else { return "" }
        var text: String
        switch issue.kind {
        case .threadListUnreadable:
            text = String(localized: "storage_issue.thread_list_unreadable")
        case .threadListPartial(let lost):
            text = String(format: String(localized: "storage_issue.thread_list_partial"), lost)
        }
        if issue.recoveredCount > 0 {
            text += " " + String(format: String(localized: "storage_issue.recovered_suffix"), issue.recoveredCount)
        }
        return text
    }

    func dismissStorageIssue() { storageIssue = nil }
}
