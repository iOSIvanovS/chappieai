// FileTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of file system tools (list_files, read_file, write_file, delete_file)
// and web_fetch. All delegate to FileSystemManager or WebFetchService.
//
// web_fetch is here (not in a separate file) because it's a single case
// with the same "read external resource" semantics as file reads.
//
// LIVE UNAVAILABILITY (B-05):
// When a FS tool throws — we extract the project name from the path prefix
// and call onProjectUnavailable(projectName). ViewModel marks the chip orange
// without requiring a thread re-entry or a background timer.

import Foundation

extension ToolExecutionService {

    func executeFileTool(name: String, argsData: Data) async throws -> String {
        switch name {

        case "list_files":
            do {
                let files = try await fileSystem.listFiles()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(files)
                return String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                // list_files has no path argument — report all workspace names as affected.
                let names = await fileSystem.workspaceNames
                for projectName in names {
                    await reportUnavailable(projectName)
                }
                throw error
            }

        case "read_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Ошибка: Неверные аргументы для read_file"
            }
            do {
                return try await fileSystem.readFile(at: path)
            } catch {
                await reportUnavailable(projectName(from: path))
                throw error
            }

        case "write_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"],
                  let content = args["content"] else {
                return "Ошибка: Неверные аргументы для write_file"
            }
            do {
                try await fileSystem.writeFile(at: path, content: content)
                return "Успешно: Файл \(path) записан."
            } catch {
                await reportUnavailable(projectName(from: path))
                throw error
            }

        case "delete_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Ошибка: Неверные аргументы для delete_file"
            }
            do {
                try await fileSystem.deleteFile(at: path)
                return "Успешно: Файл \(path) удален."
            } catch {
                await reportUnavailable(projectName(from: path))
                throw error
            }

        case "web_fetch":
            guard let service = webFetch else {
                return "❌ web_fetch: service not available. WebFetchService was not injected into ToolExecutionService."
            }
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let url = args["url"], !url.isEmpty else {
                return "❌ web_fetch: missing required argument 'url'."
            }
            return await service.fetch(urlString: url, selector: args["selector"])

        default:
            return "Ошибка: Неизвестный file tool '\(name)'"
        }
    }

    // MARK: - Helpers

    /// Extracts project name from a prefixed path ("ProjectName/relative/path" → "ProjectName").
    /// For single-workspace paths (no prefix) — returns nil, nothing to report.
    private func projectName(from path: String) -> String? {
        let parts = path.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let candidate = String(parts[0])
        // Verify it's actually a known workspace name, not just a top-level folder.
        let known = fileSystem.workspaceNames
        return known.contains(candidate) ? candidate : nil
    }

    /// Calls onProjectUnavailable on MainActor if a name is known.
    private func reportUnavailable(_ name: String?) async {
        guard let name, let callback = onProjectUnavailable else { return }
        await MainActor.run { callback(name) }
    }
}
