//
//  ChatHistoryManager.swift
//  ChappieCore
//

import Foundation

/// Saves and loads chat history as a JSON file in the workspace root (or global fallback).
///
/// Generic T: Codable — ChappieCore doesn't depend on ChatMessage (UI target).
/// History is trimmed to maxStoredMessages on every save to keep the file compact.
/// All stored properties are constants → Sendable-safe.
public final class ChatHistoryManager: Sendable {

    // MARK: - Constants

    private static let workspaceHistoryFileName = "chat_history.json"
    private static let globalSubdirectory       = "Chappie"
    private static let globalHistoryFileName    = "global_chat_history.json"

    /// Max messages kept on disk. Orchestrator uses only the last ~12 anyway,
    /// so storing more than 100 provides no practical benefit.
    public static let maxStoredMessages = 100

    // MARK: - Singleton (backward compatibility)

    /// Default instance without a workspace — used before workspace is selected.
    public static let shared = ChatHistoryManager(workspaceURL: nil)

    // MARK: - Properties

    /// Resolved file URL — computed once in init, never changes (required for Sendable).
    public let fileURL: URL

    // MARK: - Init

    /// - Parameter workspaceURL: Workspace root → stores `<root>/chat_history.json`.
    ///   If nil → falls back to `~/Documents/Chappie/global_chat_history.json`.
    public init(workspaceURL: URL?) {
        if let workspaceURL = workspaceURL {
            fileURL = workspaceURL.appendingPathComponent(ChatHistoryManager.workspaceHistoryFileName)
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let chappieGlobalURL = documentsURL.appendingPathComponent(
                ChatHistoryManager.globalSubdirectory, isDirectory: true
            )
            ChatHistoryManager.createDirectoryIfNeeded(at: chappieGlobalURL)
            fileURL = chappieGlobalURL.appendingPathComponent(ChatHistoryManager.globalHistoryFileName)
        }
    }

    // MARK: - Public API

    /// Loads messages from disk. Returns empty array on missing file or decode error.
    public func loadMessages<T: Codable>() -> [T] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            // Corrupt file or model change — return empty rather than crash.
            print("[ChatHistoryManager] Failed to decode chat history: \(error)")
            return []
        }
    }

    /// Saves messages to disk, trimming to maxStoredMessages.
    /// Write is atomic (.atomic) to protect against corruption on unexpected termination.
    public func saveMessages<T: Codable>(_ messages: [T]) {
        let trimmed = messages.count > ChatHistoryManager.maxStoredMessages
            ? Array(messages.suffix(ChatHistoryManager.maxStoredMessages))
            : messages

        if messages.count > ChatHistoryManager.maxStoredMessages {
            print("[ChatHistoryManager] ✂️ Trimmed \(messages.count - trimmed.count) old messages, kept \(trimmed.count)")
        }

        do {
            let data = try JSONEncoder().encode(trimmed)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ChatHistoryManager] Failed to save chat history: \(error)")
        }
    }

    /// Deletes the history file. No-op if file doesn't exist.
    public func clearHistory() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("[ChatHistoryManager] Failed to delete history file: \(error)")
        }
    }

    // MARK: - Private

    /// Called from init before self is fully initialized — must be static.
    private static func createDirectoryIfNeeded(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: nil
            )
        } catch {
            print("[ChatHistoryManager] Failed to create directory \(url.path): \(error)")
        }
    }
}
