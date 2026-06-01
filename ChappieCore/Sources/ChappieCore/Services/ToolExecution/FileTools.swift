// FileTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of file system tools (list_files, read_file, write_file, delete_file)
// and web_fetch. All delegate to FileSystemManager or WebFetchService.
//
// web_fetch is here (not in a separate file) because it's a single case
// with the same "read external resource" semantics as file reads.

import Foundation

extension ToolExecutionService {

    func executeFileTool(name: String, argsData: Data) async throws -> String {
        switch name {

        case "list_files":
            let files = try await fileSystem.listFiles()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(files)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "read_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Ошибка: Неверные аргументы для read_file"
            }
            return try await fileSystem.readFile(at: path)

        case "write_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"],
                  let content = args["content"] else {
                return "Ошибка: Неверные аргументы для write_file"
            }
            try await fileSystem.writeFile(at: path, content: content)
            return "Успешно: Файл \(path) записан."

        case "delete_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Ошибка: Неверные аргументы для delete_file"
            }
            try await fileSystem.deleteFile(at: path)
            return "Успешно: Файл \(path) удален."

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
}
