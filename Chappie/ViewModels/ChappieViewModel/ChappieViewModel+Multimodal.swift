// ChappieViewModel+Multimodal.swift
// Chappie
//
// Multimodal attachment encoding, Office document extraction, response cleanup.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Multimodal Encoding

    /// An Office attachment yields several parts (its text, then its pictures); everything else one.
    func multimodalParts(for attachment: AttachedFile) async -> [AIMultimodalPart] {
        switch attachment.mimeType {
        case .docx, .xlsx, .pptx, .rtf:
            return await extractOfficeDocument(attachment)
        default:
            return [await multimodalPart(for: attachment)]
        }
    }

    func multimodalPart(for attachment: AttachedFile) async -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            return imagePart(for: attachment)

        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? "[Could not decode text content]"
            return .text("File: \(attachment.filename)\n\n\(content)")

        case .pdf:
            return .text(pdfReferenceText(for: attachment))

        case .docx, .xlsx, .pptx, .rtf:
            // Callers that can take several parts use multimodalParts(for:); this keeps the text only.
            let parts = await extractOfficeDocument(attachment)
            return parts.first ?? .text(attachmentReferenceText(for: attachment))

        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    // Sync path used for history rebuilding — no async extraction possible.
    func multimodalPartSync(for attachment: AttachedFile) -> AIMultimodalPart {
        switch attachment.mimeType {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp:
            return imagePart(for: attachment)
        case .plainText:
            guard let data = try? Data(contentsOf: attachment.localURL),
                  let content = String(data: data, encoding: .utf8) else {
                return .text(attachmentReferenceText(for: attachment))
            }
            return .text("File: \(attachment.filename)\n\n\(content)")
        case .pdf:
            return .text(pdfReferenceText(for: attachment))
        case .docx, .xlsx, .pptx, .rtf:
            // Sync path: reference only. Full extraction happens in buildCurrentAIMessage (async).
            return .text(attachmentReferenceText(for: attachment))
        case .other:
            let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .text("File: \(attachment.filename) (\(attachment.mimeType.rawValue), \(size / 1024)KB)")
        }
    }

    /// The one way an attached image enters a request: downscaled (see ImageDownscaler), with the
    /// downscaled copy cached on disk so history rebuilds do not re-encode it on every request.
    /// The original file stays untouched.
    private func imagePart(for attachment: AttachedFile) -> AIMultimodalPart {
        let cache = AttachmentStore.shared.downscaledImageURL(for: attachment.id)
        guard let uri = ImageDownscaler.dataURI(
            forFileAt: attachment.localURL,
            mimeType: attachment.mimeType.rawValue,
            cacheURL: cache
        ) else {
            return .text("\(attachmentReferenceText(for: attachment)) — image could not be prepared for sending")
        }
        return .imageURL(uri)
    }

    // MARK: - Office Document Extraction

    private func extractOfficeDocument(_ attachment: AttachedFile) async -> [AIMultimodalPart] {
        guard let toolService else {
            return [.text("File: \(attachment.filename) — tool service unavailable")]
        }
        return await callReadDocument(path: attachment.localURL.path, filename: attachment.filename, toolService: toolService)
    }

    /// Text of the document first, then its pictures as real images (see ToolImageResult).
    private func callReadDocument(path: String, filename: String, toolService: ToolExecutionService) async -> [AIMultimodalPart] {
        let args = "{\"path\":\"\(path)\"}"
        let fakeCall = AIToolCall(
            id: "attachment-\(UUID().uuidString)",
            type: "function",
            function: AIToolCallFunction(name: "read_document", arguments: args)
        )
        let result = await toolService.execute(call: fakeCall)
        guard let withImages = ToolImageResult.decode(result) else {
            return [.text("File: \(filename)\n\n\(result)")]
        }
        var parts: [AIMultimodalPart] = [.text("File: \(filename)\n\n\(withImages.text)")]
        parts.append(contentsOf: withImages.multimodalParts)
        return parts
    }

    // MARK: - PDF reference

    /// A PDF is never inlined: it is read page by page with the pdf tools, which need only the uuid.
    func pdfReferenceText(for attachment: AttachedFile) -> String {
        let size = (try? attachment.localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return "File: \(attachment.filename) (PDF, \(size / 1024)KB) | uuid: \(attachment.id.uuidString). "
            + "Read it with pdf_info (pages and text volume), pdf_page_as_txt and pdf_page_as_image, passing this uuid."
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
