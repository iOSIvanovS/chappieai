// FileTools+Attachments.swift
// ChappieCore
//
// Implements fetch_attachment and send_attachment tool execution.
// MimeCategory classifies file types for routing: image → downscaled image part, Office → MCP ZIP patch,
// text → plain read, PDF → refused with a pointer to the pdf_* tools, other → size and type only.
//
// WHY CLOSURES: AttachmentStore lives in the Chappie app target, not in ChappieCore.
// Closures are registered at startup via registerAttachmentHandlers() and bridge the boundary.

import Foundation

// MARK: - MIME type classifier

enum MimeCategory {
    case image(String)    // carries the MIME string for data URI construction
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
            // Fallback: infer from extension when MIME string is absent or unknown.
            switch fileExtension.lowercased() {
            case "jpg", "jpeg": return .image("image/jpeg")
            case "png":         return .image("image/png")
            case "gif":         return .image("image/gif")
            case "webp":        return .image("image/webp")
            case "docx", "xlsx", "pptx", "rtf": return .officeDocument
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

// MARK: - Attachment execution

extension ToolExecutionService {

    func executeFetchAttachment(uuid: UUID) async -> String {
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
            // Same route as view_image: downscaled, and returned behind the image marker so the
            // orchestrator shows it to the model as a real image instead of base64 text.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= FileSystemManager.maxImageBytes,
                  let data = try? Data(contentsOf: url) else {
                return "Error: Could not read image at \(url.path)"
            }
            guard let dataURI = ImageDownscaler.dataURI(for: data, mimeType: mimeString) else {
                return "Error: Image \(url.lastPathComponent) could not be decoded or prepared for sending."
            }
            return "\(ToolExecutionService.viewImageMarker)\(dataURI)"

        case .pdf:
            // A PDF is read page by page with its own tools, never as one blob.
            return PDFGuidance.refusal(tool: "fetch_attachment", attachmentUUID: uuid.uuidString)

        case .officeDocument:
            // Delegate to MCP, which has ZIPFoundation available.
            return await mcpBridge.execute(tool: "read_document", args: ["path": url.path])

        case .plainText:
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                return "Error: Could not read text file at \(url.path)"
            }
            return text

        case .other:
            // Never base64 as text: a few MB of it is millions of tokens and the model cannot use it.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "Attachment \(url.lastPathComponent): type .\(ext.isEmpty ? "unknown" : ext), "
                + "\(OutputGuard.formatSize(size)). This file type cannot be read as text; "
                + "tell the user it is not supported for reading."
        }
    }

    func executeSendAttachment(
        filename: String,
        content: String,
        mimeTypeString: String,
        sourceUUID: UUID?
    ) async -> String {
        print("[send_attachment] filename: \(filename), mimeType: \(mimeTypeString), sourceUUID: \(sourceUUID?.uuidString ?? "none")")

        let ext = URL(fileURLWithPath: filename).pathExtension
        let mimeCategory = MimeCategory.from(mimeTypeString: mimeTypeString, fileExtension: ext)
        let attachmentId = UUID()

        // Office doc with source: patch the existing ZIP via MCP, save to reserved destination URL.
        if mimeCategory.isOfficeDocument, let sourceUUID = sourceUUID {
            return await sendOfficePatch(
                filename: filename,
                content: content,
                sourceUUID: sourceUUID,
                attachmentId: attachmentId
            )
        }

        // All other types: encode and save directly via saveAttachment closure.
        return await sendRawAttachment(
            filename: filename,
            content: content,
            mimeCategory: mimeCategory,
            attachmentId: attachmentId
        )
    }

    // MARK: - Private helpers

    private func sendOfficePatch(
        filename: String,
        content: String,
        sourceUUID: UUID,
        attachmentId: UUID
    ) async -> String {
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

        guard mcpResult.contains("\"status\":\"ok\"") || mcpResult.contains("\"status\": \"ok\"") else {
            print("[send_attachment] ❌ MCP write_document failed: \(mcpResult)")
            return "Error: Failed to patch Office document: \(mcpResult)"
        }

        print("[send_attachment] ✅ Saved Office doc: \(filename) → uuid: \(attachmentId.uuidString) → \(destURL.path)")
        return buildResponse(filename: filename, uuid: attachmentId, url: destURL)
    }

    private func sendRawAttachment(
        filename: String,
        content: String,
        mimeCategory: MimeCategory,
        attachmentId: UUID
    ) async -> String {
        guard let save = saveAttachment else {
            return "Error: Attachment save handler not registered. Please restart the app."
        }

        let data: Data
        if case .image = mimeCategory {
            // Strip data URI prefix if present (data:image/png;base64,...).
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

        print("[send_attachment] ✅ Saved: \(filename) → uuid: \(result.uuid.uuidString) → \(result.url.path)")
        return buildResponse(filename: filename, uuid: result.uuid, url: result.url)
    }

    private func buildResponse(filename: String, uuid: UUID, url: URL) -> String {
        let response: [String: String] = [
            "status": "ok",
            "saved_path": url.path,
            "filename": filename,
            "uuid": uuid.uuidString
        ]
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "Error: Failed to build response for send_attachment"
    }
}
