// FileTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of file system tools (list_files, read_file, write_file, delete_file),
// document tools (read_document, write_document), attach_file, and web_fetch.
// All file ops delegate to FileSystemManager; document ops delegate to MCPToolBridge.
//
// web_fetch is here (not in a separate file) because it's a single case
// with the same "read external resource" semantics as file reads.
//
// read_document / write_document route through MCP (DocumentTools in ChappieMCP)
// because ZIPFoundation is only available in the ChappieMCP target.
//
// attach_file: validates the file exists at the given absolute path and returns
// a structured JSON response that AIOrchestrator picks up as an output file.
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

        // Document tools — routed through MCP (ZIPFoundation lives in ChappieMCP target).
        case "read_document":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty else {
                return "Ошибка: Аргумент 'path' обязателен для read_document"
            }
            return await mcpBridge.execute(tool: "read_document", args: ["path": path])

        case "write_document":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty,
                  let content = args["content"], !content.isEmpty else {
                return "Ошибка: Аргументы 'path' и 'content' обязательны для write_document"
            }
            var mcpArgs: [String: String] = ["path": path, "content": content]
            if let outputPath = args["output_path"] { mcpArgs["output_path"] = outputPath }
            if let entryName = args["entry_name"]   { mcpArgs["entry_name"] = entryName }
            return await mcpBridge.execute(tool: "write_document", args: mcpArgs)

        // attach_file: validates existence, returns structured JSON for AIOrchestrator to collect.
        // WHY: the model calls this explicitly after creating a file to deliver it to the user.
        // AIOrchestrator sees the JSON response and adds the path to collectedOutputFiles.
        case "attach_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty else {
                return "Ошибка: Аргумент 'path' обязателен для attach_file"
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return "Ошибка: Файл не найден по пути: \(path)"
            }
            let url = URL(fileURLWithPath: path)
            let filename = url.lastPathComponent
            // Return the same structured JSON format as write_document so AIOrchestrator
            // can use a single parseOutputFilePath() for both tools.
            let response: [String: String] = [
                "status": "ok",
                "saved_path": path,
                "filename": filename
            ]
            if let data = try? JSONSerialization.data(withJSONObject: response),
               let json = String(data: data, encoding: .utf8) {
                print("[FileTools] attach_file: \(path)")
                return json
            }
            return "Ошибка: Не удалось сформировать ответ для attach_file"

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
        let known = fileSystem.workspaceNames
        return known.contains(candidate) ? candidate : nil
    }

    /// Calls onProjectUnavailable on MainActor if a name is known.
    private func reportUnavailable(_ name: String?) async {
        guard let name, let callback = onProjectUnavailable else { return }
        await MainActor.run { callback(name) }
    }
}
