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
// DESIGN DECISION — Data stored inline:
// Attachments are small enough (images are resized before attaching) to store
// the raw bytes directly in the ChatMessage JSON. This keeps the persistence
// model simple — no separate file references that can go stale.
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
    case other

    // MARK: Convenience

    /// True for any image/* type — used to decide between inline preview vs chip.
    public var isImage: Bool {
        switch self {
        case .imageJpeg, .imagePng, .imageGif, .imageWebp: return true
        default: return false
        }
    }

    /// SF Symbol name for non-image file chips.
    public var systemIcon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .plainText: return "doc.text.fill"
        default: return "paperclip"
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
    /// Stored as base64 in JSON via custom Codable.
    public let data: Data

    // MARK: - Init

    public init(id: UUID = UUID(), filename: String, mimeType: AttachmentMimeType, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
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
        case id, filename, mimeType, dataBase64
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decodeIfPresent(AttachmentMimeType.self, forKey: .mimeType) ?? .other
        let b64  = try c.decode(String.self, forKey: .dataBase64)
        data     = Data(base64Encoded: b64) ?? Data()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                          forKey: .id)
        try c.encode(filename,                    forKey: .filename)
        try c.encode(mimeType,                    forKey: .mimeType)
        try c.encode(data.base64EncodedString(),  forKey: .dataBase64)
    }
}
