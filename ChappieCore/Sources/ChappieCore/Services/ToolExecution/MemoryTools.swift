// MemoryTools.swift
// ChappieCore
//
// WHY THIS FILE:
// IT-08 scope resolution and IT-08 memory tool execution cases.
// Also contains the Cyrillic barrier (MEMORY-ENGLISH) — a code-level guard
// that rejects any memory write containing Cyrillic characters.
//
// SCOPE RESOLUTION LOGIC (IT-08):
//   targetName set → look up project UUID in activeMemoryContext.projects
//   scope="global" → "global"
//   scope="thread" → active thread UUID (error if no active thread)
//   unknown scope  → "global" (safe fallback with warning)
//
// CYRILLIC BARRIER (MEMORY-ENGLISH):
// Why code, not prompt: prompts can be forgotten during history compression.
// A rule in memory disappears when sessions change. Only code is reliable.
// Detector: Unicode scalar range U+0400–U+04FF (basic Cyrillic).
// Checked fields: key, type, jsonString — all three required fields.
//
// MEMORY CHANGE CALLBACK:
// After memorize/delete_memory — calls onMemoryChanged on MainActor.
// This triggers invalidateActiveThreadSession() in ChappieViewModel,
// clearing the cached system prompt so the next message picks up fresh memory.

import Foundation

extension ToolExecutionService {

    // MARK: - Scope resolution (IT-08)

    func resolveScope(scopeParam: String?, targetName: String?) -> ScopeResolution {
        if let name = targetName, !name.isEmpty {
            if let project = activeMemoryContext.projects.first(where: { $0.name == name }) {
                return .resolved(project.id.uuidString)
            } else {
                let attached = activeMemoryContext.projectNames.isEmpty
                    ? "no attached projects"
                    : activeMemoryContext.projectNames.joined(separator: ", ")
                return .failed(
                    "Project '\(name)' not found in current thread. " +
                    "Attached projects: \(attached). " +
                    "Use add_project_to_thread to add the project first."
                )
            }
        }

        let scope = scopeParam ?? "global"
        if scope == "global" { return .resolved("global") }

        if scope == "thread" {
            if let threadId = activeMemoryContext.threadId {
                return .resolved(threadId.uuidString)
            } else {
                return .failed(
                    "No active thread. Thread memory unavailable. " +
                    "Use scope=\"global\" for global memory."
                )
            }
        }

        print("[ToolExecutionService] ⚠️ Unknown scope='\(scope)', falling back to 'global'")
        return .resolved("global")
    }

    // MARK: - Cyrillic barrier (MEMORY-ENGLISH)

    func containsCyrillic(_ string: String) -> Bool {
        return string.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Returns an error message if any required memory field contains Cyrillic, nil otherwise.
    func validateMemoryEnglish(key: String, type: String, jsonString: String) -> String? {
        var violatingFields: [String] = []
        if containsCyrillic(key) { violatingFields.append("key") }
        if containsCyrillic(type) { violatingFields.append("type") }
        if containsCyrillic(jsonString) { violatingFields.append("jsonString") }
        guard !violatingFields.isEmpty else { return nil }
        return """
        MEMORY LANGUAGE VIOLATION: Fields [\(violatingFields.joined(separator: ", "))] contain Cyrillic characters.
        RULE: ALL memory writes MUST be in English — no exceptions.
        Memory is internal thinking, not user communication. Think like an American engineer.
        ACTION REQUIRED: Rewrite the memorize call with all fields in English and try again.
        """
    }

    // MARK: - Memory tool execution (IT-08)

    func executeMemoryTool(name: String, argsData: Data) async throws -> String {
        switch name {

        case "memorize":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let key = args["key"],
                  let type = args["type"],
                  let jsonString = args["jsonString"] else {
                return "Error: Invalid arguments for memorize (required: key, type, jsonString)"
            }
            if let cyrillicError = validateMemoryEnglish(key: key, type: type, jsonString: jsonString) {
                print("[ToolExecutionService] ❌ MEMORY-ENGLISH violation blocked: key='\(key)'")
                return cyrillicError
            }
            switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
            case .failed(let msg):
                return "❌ memorize: \(msg)"
            case .resolved(let scopeString):
                if let error = await memoryManager.saveMemoryEntry(
                    key: key, type: type, jsonString: jsonString, scope: scopeString
                ) {
                    return "❌ memorize: \(error)"
                }
                // Invalidate cached system prompt so next message sees updated memory.
                notifyMemoryChanged()
                let scopeLabel: String
                if scopeString == "global" {
                    scopeLabel = "global memory"
                } else if scopeString == activeMemoryContext.threadId?.uuidString {
                    scopeLabel = "thread memory"
                } else {
                    let projectName = args["targetName"] ?? scopeString
                    scopeLabel = "project memory '\(projectName)'"
                }
                return "✅ Entry '\(key)' saved to \(scopeLabel)."
            }

        case "recall":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let key = args["key"] else {
                return "Ошибка: Неверные аргументы для recall (обязателен: key)"
            }
            switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
            case .failed(let msg):
                return "❌ recall: \(msg)"
            case .resolved(let scopeString):
                if let value = await memoryManager.readMemoryEntry(key: key, scope: scopeString) {
                    return value
                } else {
                    return "Entry for key '\(key)' not found in scope '\(scopeString)'."
                }
            }

        case "search_memory":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let type = args["type"] else {
                return "Ошибка: Неверные аргументы для search_memory (обязателен: type)"
            }
            switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
            case .failed(let msg):
                return "❌ search_memory: \(msg)"
            case .resolved(let scopeString):
                let results = await memoryManager.searchMemoryEntries(type: type, scope: scopeString)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(results)
                return String(data: data, encoding: .utf8) ?? "{}"
            }

        case "delete_memory":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let key = args["key"] else {
                return "Ошибка: Неверные аргументы для delete_memory (обязателен: key)"
            }
            switch resolveScope(scopeParam: args["scope"], targetName: args["targetName"]) {
            case .failed(let msg):
                return "❌ delete_memory: \(msg)"
            case .resolved(let scopeString):
                if let error = await memoryManager.deleteMemoryEntry(key: key, scope: scopeString) {
                    return "❌ delete_memory: \(error)"
                }
                // Invalidate cached system prompt so next message sees updated memory.
                notifyMemoryChanged()
                return "✅ Entry '\(key)' deleted from scope '\(scopeString)'."
            }

        default:
            return "Ошибка: Неизвестный memory tool '\(name)'"
        }
    }

    // MARK: - Private helper

    /// Fires the onMemoryChanged callback on MainActor.
    /// Called after any write/delete to memory so the cached system prompt is cleared immediately.
    private func notifyMemoryChanged() {
        guard let callback = onMemoryChanged else { return }
        Task { @MainActor in callback() }
    }
}
