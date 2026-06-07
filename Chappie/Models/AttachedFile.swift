// AttachedFile.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Multimodal support requires a first-class model for file attachments.
// AttachedFile is a value type that carries everything needed to:
//   a) render a preview in the UI (thumbnail for images, icon for others)
//   b) serialize to disk (base64 in ChatMessage JSON)
//   c) build the API content block (base64 data URI for images, raw data for PDFs)
//
// DESIGN DECISION — localURL for Office documents:
// Images are stored inline as base64 (small, self-contained).
// Office documents get a localURL pointing to Application Support/Chappie/Attachments/.
// localURL enables: re-reading without re-extraction, write_document knowing where to save,
// and opening the file directly from the AI bubble without a temp-file dance.
// localURL is optional — nil for images and legacy attachments (backward compat).
//
// DESIGN DECISION — MimeType enum:
// Using a typed enum instead of a raw string prevents typos and makes
// exhaustive switch possible in the API layer (image vs document handling).

import Foundation
import AppKit

// MARK: - MimeType

/// Supported attachment MIME types.
///
/// "other" is the catch-all for anything we accept but don't know how to
/// render specially — we still send it to the API and let the model decide.
public enum AttachmentMimeType: String, Codable, Sendable, Hashable {
    case imageJpeg  = "image/jpeg"
    case imagePng   = "image/png"
    case imageGif   = "image/gif"
    case imageWebp  = "image/webp"
    case pdf        = "application/pdf"
    case plainText  = "text/plain"
    // Office document formats — extracted via read_document (ZIP+XML pipeline)
    case docx       = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    case xlsx       = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    case pptx       = "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    case rtf        = "application/rtf"
    case other

    // MARK: Convenience

    /// True for any image/* type — used to decide between inline preview vs chip.
    public var isImage: Bool {
        switch self {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp: return true
        default: return false
        }
    }

    /// True for Office document formats that require read_document extraction.
    public var isOfficeDocument: Bool {
        switch self {
        case .docx, .xlsx, .pptx, .rtf: return true
        default: return false
        }
    }

    /// SF Symbol name for non-image file chips.
    public var systemIcon: String {
        switch self {
        case .pdf:       return "doc.fill"
        case .plainText: return "doc.text.fill"
        case .docx, .rtf: return "doc.richtext.fill"
        case .xlsx:      return "tablecells.fill"
        case .pptx:      return "rectangle.on.rectangle.fill"
        default:         return "paperclip"
        }
    }

    /// Derive MIME type from a file URL by looking at its path extension.
    public static func from(url: URL) -> AttachmentMimeType {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return .imageJpeg
        case "png":         return .imagePng
        case "gif":         return .imageGif
        case "webp":        return .imageWebp
        case "pdf":         return .pdf
        case "txt", "md":   return .plainText
        case "docx":        return .docx
        case "xlsx":        return .xlsx
        case "pptx":        return .pptx
        case "rtf":         return .rtf
        default:            return .other
        }
    }
}

// MARK: - AttachedFile

/// A single file attached to a chat message.
///
/// Lifecycle:
///   1. User picks file via NSOpenPanel → AttachedFile.load(from:)
///   2. Stored in InputMorphView state as [AttachedFile] (pending)
///   3. On send → passed to ViewModel → saved in ChatMessage.message(attachments:)
///   4. On API request → AIOrchestrator builds content blocks from attachments
public struct AttachedFile: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Stored Properties

    public let id: UUID
    /// Original filename shown in chips and previews.
    public let filename: String
    /// MIME type — drives rendering and API encoding.
    public let mimeType: AttachmentMimeType
    /// Raw file bytes. For images: original data (NSImage handles all formats).
    /// For Office docs: kept for Codable round-trip; localURL is preferred for disk access.
    /// Stored as base64 in JSON via custom Codable.
    public let data: Data
    /// Permanent path in Application Support/Chappie/Attachments/{messageID}/.
    /// Set after the message is sent and the file is copied to permanent storage.
    /// nil for images (stored inline) and legacy attachments.
    public let localURL: URL?

    // MARK: - Init

    public init(id: UUID = UUID(), filename: String, mimeType: AttachmentMimeType, data: Data, localURL: URL? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.localURL = localURL
    }

    /// Returns a copy of this attachment with localURL set.
    public func withLocalURL(_ url: URL) -> AttachedFile {
        AttachedFile(id: id, filename: filename, mimeType: mimeType, data: data, localURL: url)
    }

    // MARK: - Factory

    /// Load an AttachedFile from a file URL picked by the user.
    ///
    /// Returns nil if the file cannot be read (permissions, missing, etc.).
    /// The caller should show an error in that case.
    public static func load(from url: URL) -> AttachedFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = AttachmentMimeType.from(url: url)
        return AttachedFile(filename: url.lastPathComponent, mimeType: mime, data: data)
    }

    /// Creates an AttachedFile for an AI-generated output file that already exists on disk.
    /// data is read from the file; localURL points to its permanent location.
    public static func fromOutputFile(at url: URL) -> AttachedFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = AttachmentMimeType.from(url: url)
        return AttachedFile(filename: url.lastPathComponent, mimeType: mime, data: data, localURL: url)
    }

    // MARK: - Convenience

    /// Base64 data URI string for use in OpenAI-compatible image_url content blocks.
    /// Example: "data:image/jpeg;base64,/9j/4AAQ..."
    public var dataURI: String {
        "data:\(mimeType.rawValue);base64,\(data.base64EncodedString())"
    }

    /// NSImage for image attachments. nil for non-image types.
    public var nsImage: NSImage? {
        guard mimeType.isImage else { return nil }
        return NSImage(data: data)
    }

    // MARK: - Codable (manual — Data as base64 string)

    // WHY MANUAL: Swift's default Codable encodes Data as a base64 string automatically,
    // but we want explicit control over the key names for forward compatibility.

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, dataBase64, localURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decodeIfPresent(AttachmentMimeType.self, forKey: .mimeType) ?? .other
        let b64  = try c.decode(String.self, forKey: .dataBase64)
        data     = Data(base64Encoded: b64) ?? Data()
        // localURL stored as absolute path string for portability
        if let path = try c.decodeIfPresent(String.self, forKey: .localURL) {
            localURL = URL(fileURLWithPath: path)
        } else {
            localURL = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                          forKey: .id)
        try c.encode(filename,                    forKey: .filename)
        try c.encode(mimeType,                    forKey: .mimeType)
        try c.encode(data.base64EncodedString(),  forKey: .dataBase64)
        try c.encodeIfPresent(localURL?.path,     forKey: .localURL)
    }
}
