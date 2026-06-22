// ChappieViewModel+Multimodal.swift
// Chappie
//
// Multimodal attachment encoding, Office document extraction, response cleanup.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Multimodal Encoding

    func multimodalPart(for attachment: AttachedFile) async -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            // Images are sent inline as base64 — small enough to be worth it.
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let dataURI = "data:\(attachment.mimeType.rawValue);base64,\(data.base64EncodedString())"
            return .imageURL(dataURI)

        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")

        case .pdf:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return .text("File: \(attachment.filename)\n\n\(text)")
            }
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (PDF, \(size / 1024)KB) — binary content, cannot extract text inline.")

        case .docx, .xlsx, .pptx, .rtf:
            return await extractOfficeDocument(attachment)

        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    // Sync path used for history rebuilding — no async extraction possible.
    func multimodalPartSync(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let dataURI = "data:\(attachment.mimeType.rawValue);base64,\(data.base64EncodedString())"
            return .imageURL(dataURI)
        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL),
                  let content = String(data: data, encoding: .utf8) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            return .text("File: \(attachment.filename)\n\n\(content)")
        case .pdf:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (PDF, \(size / 1024)KB)")
        case .docx, .xlsx, .pptx, .rtf:
            // Sync path: reference only. Full extraction happens in buildCurrentAIMessage (async).
            return .text(attachmentReferenceText(for: attachment))
        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    // MARK: - Office Document Extraction

    private func extractOfficeDocument(_ attachment: AttachedFile) async -> AIMultimodalPart {
        guard let toolService else {
            return .text("File: \(attachment.filename) — tool service unavailable")
        }
        return await callReadDocument(path: attachment.localURL.path, filename: attachment.filename, toolService: toolService)
    }

    private func callReadDocument(path: String, filename: String, toolService: ToolExecutionService) async -> AIMultimodalPart {
        let args = "{\"path\":\"\(path)\"}"
        let fakeCall = AIToolCall(
            id: "attachment-\(UUID().uuidString)",
            type: "function",
            function: AIToolCallFunction(name: "read_document", arguments: args)
        )
        let result = await toolService.execute(call: fakeCall)
        return .text("File: \(filename)\n\n\(result)")
    }

    // MARK: - Attachment Reference

    /// Text reference block for an attachment in AI history.
    /// Format: "Attachment: Plan.docx | uuid: 550e8400-..."
    func attachmentReferenceText(for attachment: AttachedFile) -> String {
        "Attachment: \(attachment.filename) | uuid: \(attachment.id.uuidString)"
    }

    // MARK: - Response Cleanup

    func cleanAIResponse(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: "94>thought.*?needed\\.\\n*", options: [.dotMatchesLineSeparators]) {
            result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.utf16.count), withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
