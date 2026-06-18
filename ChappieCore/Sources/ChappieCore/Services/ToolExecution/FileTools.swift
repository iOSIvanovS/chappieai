// FileTools.swift
// ChappieCore
//
// Execution of file system tools (list_files, read_file, write_file, delete_file),
// document tools (read_document, write_document), attachment tools (fetch_attachment,
// send_attachment, attach_file), and web_fetch.
//
// ATTACHMENT TOOLS:
// fetch_attachment(uuid) — resolves UUID via resolveAttachment closure, returns file content:
//   images → base64 data URI, Office docs → XML via MCP read_document,
//   text → UTF-8 string, PDF → text extraction via MCP.
// send_attachment(filename, content, mime_type, source_uuid?) — saves file via saveAttachment /
//   reserveAttachmentURL closures, returns structured JSON that AIOrchestrator picks up.
//   For Office formats: patches source ZIP (source_uuid required), preserving styles/images.
//
// WHY CLOSURES: AttachmentStore lives in the Chappie app target, not in ChappieCore.
// Closures are registered at startup via registerAttachmentHandlers() and bridge the boundary.

import Foundation

// MARK: - MIME type helpers (ChappieCore-local, mirrors AttachmentMimeType in app target)

private enum MimeCategory {
    case image(String)    // rawValue MIME string
    case officeDocument
    case pdf
    case plainText
    case other

    static func from(mimeTypeString: String, fileExtension: String) -> MimeCategory {
        switch mimeTypeString {
        case "image/jpeg", "image/png", "image/gif", "image/webp":
            return .image(mimeTypeString)
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             "application/vnd.openxmlformats-officedocument.presentationml.presentation",
             "application/rtf":
            return .officeDocument
        case "application/pdf":
            return .pdf
        case "text/plain":
            return .plainText
        default:
            // Fallback: guess from file extension
            switch fileExtension.lowercased() {
            case "jpg", "jpeg": return .image("image/jpeg")
            case "png":         return .image("image/png")
            case "gif":         return .image("image/gif")
            case "webp":        return .image("image/webp")
            case "docx":        return .officeDocument
            case "xlsx":        return .officeDocument
            case "pptx":        return .officeDocument
            case "rtf":         return .officeDocument
            case "pdf":         return .pdf
            case "txt", "md":   return .plainText
            default:            return .other
            }
        }
    }

    var isOfficeDocument: Bool {
        if case .officeDocument = self { return true }
        return false
    }
}

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

        case "delete_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"] else {
                return "Error: Invalid arguments for delete_file"
            }
            try await fileSystem.deleteFile(at: path, projectName: args["project"])
            return "Success: File \(path) deleted."

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

        // MARK: - fetch_attachment

        case "fetch_attachment":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let uuidString = args["uuid"], !uuidString.isEmpty,
                  let uuid = UUID(uuidString: uuidString) else {
                return "Error: Argument 'uuid' is required and must be a valid UUID for fetch_attachment"
            }
            return await executeFetchAttachment(uuid: uuid)

        // MARK: - send_attachment

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

        // MARK: - attach_file (legacy — kept for backward compat)

        case "attach_file":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let path = args["path"], !path.isEmpty else {
                return "Error: Argument 'path' is required for attach_file"
            }
            guard FileManager.default.fileExists(atPath: path) else {
                return "Error: File not found at path: \(path)"
            }
            let url = URL(fileURLWithPath: path)
            let filename = url.lastPathComponent
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
            return "Error: Failed to build response for attach_file"

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
            return "Error: Unknown file tool '\(name)'"
        }
    }

    // MARK: - fetch_attachment implementation

    private func executeFetchAttachment(uuid: UUID) async -> String {
        print("[fetch_attachment] Resolving uuid: \(uuid.uuidString)")

        guard let resolve = resolveAttachment else {
            print("[fetch_attachment] ❌ resolveAttachment handler not registered")
            return "Error: Attachment handler not available. Please restart the app."
        }

        guard let url = resolve(uuid) else {
            print("[fetch_attachment] ❌ Not found: \(uuid.uuidString)")
            return "Error: No attachment found for uuid: \(uuid.uuidString)"
        }

        print("[fetch_attachment] ✅ Found: \(url.path)")

        let ext = url.pathExtension.lowercased()
        let mimeCategory = MimeCategory.from(mimeTypeString: "", fileExtension: ext)

        switch mimeCategory {
        case .image(let mimeString):
            guard let data = try? Data(contentsOf: url) else {
                return "Error: Could not read image at \(url.path)"
            }
            return "data:\(mimeString);base64,\(data.base64EncodedString())"

        case .officeDocument, .pdf:
            // Extract primary XML / text via MCP read_document.
            return await mcpBridge.execute(tool: "read_document", args: ["path": url.path])

        case .plainText:
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return "Error: Could not read text file at \(url.path)"
            }
            return text

        case .other:
            guard let data = try? Data(contentsOf: url) else {
                return "Error: Could not read file at \(url.path)"
            }
            // Return as base64 for unknown types — let the model decide what to do.
            return "data:application/octet-stream;base64,\(data.base64EncodedString())"
        }
    }

    // MARK: - send_attachment implementation

    private func executeSendAttachment(
        filename: String,
        content: String,
        mimeTypeString: String,
        sourceUUID: UUID?
    ) async -> String {
        print("[send_attachment] filename: \(filename), mimeType: \(mimeTypeString), sourceUUID: \(sourceUUID?.uuidString ?? "none")")

        let ext = URL(fileURLWithPath: filename).pathExtension
        let mimeCategory = MimeCategory.from(mimeTypeString: mimeTypeString, fileExtension: ext)
        let attachmentId = UUID()

        let savedURL: URL?

        if mimeCategory.isOfficeDocument, let sourceUUID = sourceUUID {
            // Office doc patch: resolve source ZIP, patch via MCP write_document into reserved dest URL.
            guard let resolve = resolveAttachment,
                  let reserve = reserveAttachmentURL else {
                return "Error: Attachment handlers not registered. Please restart the app."
            }

            guard let sourceURL = resolve(sourceUUID) else {
                print("[send_attachment] ❌ source_uuid not found: \(sourceUUID.uuidString)")
                return "Error: Source attachment not found for uuid: \(sourceUUID.uuidString)"
            }

            let destURL = reserve(filename, attachmentId)
            let mcpArgs: [String: String] = [
                "path": sourceURL.path,
                "content": content,
                "output_path": destURL.path
            ]
            let mcpResult = await mcpBridge.execute(tool: "write_document", args: mcpArgs)

            if mcpResult.contains("\"status\":\"ok\"") || mcpResult.contains("\"status\": \"ok\"") {
                savedURL = destURL
            } else {
                print("[send_attachment] ❌ MCP write_document failed: \(mcpResult)")
                return "Error: Failed to patch Office document: \(mcpResult)"
            }

        } else {
            guard let save = saveAttachment else {
                return "Error: Attachment save handler not registered. Please restart the app."
            }

            let data: Data
            if case .image = mimeCategory {
                // Strip data URI prefix if present (data:image/png;base64,...)
                let base64 = content.contains(",")
                    ? String(content.split(separator: ",", maxSplits: 1).last ?? Substring(content))
                    : content
                guard let decoded = Data(base64Encoded: base64) else {
                    return "Error: Invalid base64 content for image attachment"
                }
                data = decoded
            } else {
                guard let utf8 = content.data(using: .utf8) else {
                    return "Error: Could not encode content as UTF-8 for \(filename)"
                }
                data = utf8
            }

            guard let result = save(data, filename) else {
                print("[send_attachment] ❌ Failed to save: \(filename)")
                return "Error: Failed to save attachment \(filename)"
            }

            savedURL = result.url
            // Use the UUID returned by saveAttachment (it generated it internally).
            let response: [String: String] = [
                "status": "ok",
                "saved_path": result.url.path,
                "filename": filename,
                "uuid": result.uuid.uuidString
            ]
            print("[send_attachment] ✅ Saved: \(filename) → uuid: \(result.uuid.uuidString) → \(result.url.path)")
            if let responseData = try? JSONSerialization.data(withJSONObject: response),
               let json = String(data: responseData, encoding: .utf8) {
                return json
            }
            return "Error: Failed to build response for send_attachment"
        }

        guard let url = savedURL else {
            print("[send_attachment] ❌ Failed to save Office doc: \(filename)")
            return "Error: Failed to save attachment \(filename)"
        }

        print("[send_attachment] ✅ Saved Office doc: \(filename) → uuid: \(attachmentId.uuidString) → \(url.path)")

        let response: [String: String] = [
            "status": "ok",
            "saved_path": url.path,
            "filename": filename,
            "uuid": attachmentId.uuidString
        ]
        if let responseData = try? JSONSerialization.data(withJSONObject: response),
           let json = String(data: responseData, encoding: .utf8) {
            return json
        }
        return "Error: Failed to build response for send_attachment"
    }
}
