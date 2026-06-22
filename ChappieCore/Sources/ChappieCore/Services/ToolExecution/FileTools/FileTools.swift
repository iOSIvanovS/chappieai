// FileTools.swift
// ChappieCore
//
// Routes all file system, search, document, attachment, and web_fetch tool calls.
// Heavy attachment logic lives in FileTools+Attachments.swift.

import Foundation

extension ToolExecutionService {

    func executeFileTool(name: String, argsData: Data) async throws -> String {
        switch name {

        case "list_files":
            let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            let projectArg = args["project"]
            let files: [String]
            if let project = projectArg, !project.isEmpty {
                files = try await fileSystem.listFiles(project: project)
            } else {
                files = try await fileSystem.listFiles()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(files)
            return String(data: data, encoding: .utf8) ?? "[]"

        case "read_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Error: Invalid arguments for read_file"
            }
            return try await fileSystem.readFile(at: path, projectName: args["project"])

        case "write_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"],
                  let content = args["content"] else {
                return "Error: Invalid arguments for write_file"
            }
            try await fileSystem.writeFile(at: path, content: content, projectName: args["project"])
            return "Success: File \(path) written."

        case "patch_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty,
                  let find = args["find"], !find.isEmpty,
                  let replace = args["replace"] else {
                return "Error: Arguments 'path', 'find', and 'replace' are required for patch_file"
            }
            return try await fileSystem.patchFile(
                at: path,
                find: find,
                replace: replace,
                projectName: args["project"]
            )

        case "delete_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Error: Invalid arguments for delete_file"
            }
            try await fileSystem.deleteFile(at: path, projectName: args["project"])
            return "Success: File \(path) deleted."

        // Read-only metadata — always allowed regardless of role.
        case "get_file_info":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty else {
                return "Error: Argument 'path' is required for get_file_info"
            }
            return try await fileSystem.getFileInfo(at: path, projectName: args["project"])

        // Executor-only mutations — role check happens in ToolAccessControl before this call.
        case "move_file", "rename_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let from = args["from"], !from.isEmpty,
                  let to = args["to"], !to.isEmpty else {
                return "Error: Arguments 'from' and 'to' are required for \(name)"
            }
            try await fileSystem.moveFile(from: from, to: to, projectName: args["project"])
            return "Success: '\(from)' → '\(to)'"

        case "search_in_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty,
                  let query = args["query"], !query.isEmpty else {
                return "Error: Arguments 'path' and 'query' are required for search_in_file"
            }
            let contextLines = Int(args["context_lines"] ?? "2") ?? 2
            return try await fileSystem.searchInFile(
                path: path,
                projectName: args["project"],
                query: query,
                contextLines: contextLines
            )

        case "search_in_project":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let query = args["query"], !query.isEmpty else {
                return "Error: Argument 'query' is required for search_in_project"
            }
            let contextLines = Int(args["context_lines"] ?? "2") ?? 2
            return try await fileSystem.searchInProject(
                query: query,
                projectName: args["project"],
                filePattern: args["file_pattern"],
                contextLines: contextLines
            )

        // Document tools — routed through MCP (ZIPFoundation lives in ChappieMCP target).
        case "read_document":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty else {
                return "Error: Argument 'path' is required for read_document"
            }
            return await mcpBridge.execute(tool: "read_document", args: ["path": path])

        case "write_document":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty,
                  let content = args["content"], !content.isEmpty else {
                return "Error: Arguments 'path' and 'content' are required for write_document"
            }
            var mcpArgs: [String: String] = ["path": path, "content": content]
            if let outputPath = args["output_path"] { mcpArgs["output_path"] = outputPath }
            if let entryName = args["entry_name"]   { mcpArgs["entry_name"] = entryName }
            return await mcpBridge.execute(tool: "write_document", args: mcpArgs)

        case "fetch_attachment":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let uuidString = args["uuid"], !uuidString.isEmpty,
                  let uuid = UUID(uuidString: uuidString) else {
                return "Error: Argument 'uuid' is required and must be a valid UUID for fetch_attachment"
            }
            return await executeFetchAttachment(uuid: uuid)

        case "send_attachment":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let filename = args["filename"], !filename.isEmpty,
                  let content = args["content"], !content.isEmpty,
                  let mimeTypeString = args["mime_type"], !mimeTypeString.isEmpty else {
                return "Error: Arguments 'filename', 'content', and 'mime_type' are required for send_attachment"
            }
            let sourceUUID = args["source_uuid"].flatMap { UUID(uuidString: $0) }
            return await executeSendAttachment(
                filename: filename,
                content: content,
                mimeTypeString: mimeTypeString,
                sourceUUID: sourceUUID
            )

        case "web_fetch":
            guard let service = webFetch else {
                return "❌ web_fetch: service not available. WebFetchService was not injected into ToolExecutionService."
            }
            // Decode via JSONSerialization — args may contain a nested headers object, not just strings.
            guard let raw = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
                  let url = raw["url"] as? String, !url.isEmpty else {
                return "❌ web_fetch: missing required argument 'url'."
            }
            let selector = raw["selector"] as? String
            let headers = raw["headers"] as? [String: String]
            return await service.fetch(urlString: url, selector: selector, headers: headers)

        default:
            return "Error: Unknown file tool '\(name)'"
        }
    }
}
