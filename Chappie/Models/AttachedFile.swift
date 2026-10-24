// AttachedFile.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Multimodal support requires a first-class model for file attachments.
// AttachedFile is a lightweight value type that carries identity and metadata only.
// Actual file bytes are NEVER stored here — they live on disk at localURL.
//
// DESIGN DECISION — no data:Data:
// Previously AttachedFile stored raw bytes inline, which caused them to be
// serialized into ChatMessage JSON and sent to the API on every request (P0-2).
// Now only localURL is stored. Bytes are read from disk on demand.
//
// DESIGN DECISION — folder structure:
// Files are stored at: Application Support/Chappie/Attachments/{attachedFile.id}/{filename}
// This allows AttachmentStore.resolve(uuid:) to find any file by UUID alone,
// without needing the messageId.
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
public nonisolated enum AttachmentMimeType: String, Codable, Sendable, Hashable {
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
        case .pdf:        return "doc.fill"
        case .plainText:  return "doc.text.fill"
        case .docx, .rtf: return "doc.richtext.fill"
        case .xlsx:       return "tablecells.fill"
        case .pptx:       return "rectangle.on.rectangle.fill"
        default:          return "paperclip"
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
/// Lightweight metadata only — no bytes stored.
/// All file I/O goes through localURL → AttachmentStore.
///
/// Lifecycle:
///   1. User picks file → AttachedFile.load(from:) saves to disk, returns metadata
///   2. Stored in InputMorphView state as [AttachedFile] (pending)
///   3. On send → passed to ViewModel → saved in ChatMessage.message(attachments:)
///   4. On API request → AIOrchestrator builds text reference block [Attachment: name | uuid]
///   5. AI reads file on demand via fetch_attachment(uuid)
public nonisolated struct AttachedFile: Identifiable, Codable, Hashable, Sendable {

    // MARK: - Stored Properties

    public let id: UUID
    /// Original filename shown in chips and previews.
    public let filename: String
    /// MIME type — drives rendering and API encoding.
    public let mimeType: AttachmentMimeType
    /// Permanent path in Application Support/Chappie/Attachments/{id}/{filename}.
    /// Always set — there is no valid AttachedFile without a file on disk.
    public let localURL: URL

    // MARK: - Init

    public init(id: UUID = UUID(), filename: String, mimeType: AttachmentMimeType, localURL: URL) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.localURL = localURL
    }

    // MARK: - Factory

    /// Load an AttachedFile from a file URL picked by the user.
    /// Saves the file to AttachmentStore under a new UUID folder.
    /// Returns nil if the file cannot be read or saved.
    // WHY @MainActor: AttachmentStore.shared is main-actor isolated (default isolation),
    // while the struct itself is nonisolated so its Codable conformance is usable off-main.
    @MainActor
    public static func load(from url: URL) -> AttachedFile? {
        let id = UUID()
        let mime = AttachmentMimeType.from(url: url)
        guard let destURL = AttachmentStore.shared.save(fileAt: url, forAttachmentId: id) else { return nil }
        return AttachedFile(id: id, filename: url.lastPathComponent, mimeType: mime, localURL: destURL)
    }

    /// Creates an AttachedFile for an AI-generated output file that already exists on disk.
    /// Moves the file into AttachmentStore under a new UUID folder.
    @MainActor
    public static func fromOutputFile(at url: URL) -> AttachedFile? {
        let id = UUID()
        let mime = AttachmentMimeType.from(url: url)
        guard let destURL = AttachmentStore.shared.save(fileAt: url, forAttachmentId: id) else { return nil }
        return AttachedFile(id: id, filename: url.lastPathComponent, mimeType: mime, localURL: destURL)
    }

    // MARK: - Convenience

    /// NSImage for image attachments. Reads from disk. nil for non-image types or read errors.
    public var nsImage: NSImage? {
        guard mimeType.isImage else { return nil }
        return NSImage(contentsOf: localURL)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, filename, mimeType, localURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        filename = try c.decode(String.self, forKey: .filename)
        mimeType = try c.decodeIfPresent(AttachmentMimeType.self, forKey: .mimeType) ?? .other
        let path = try c.decode(String.self, forKey: .localURL)
        localURL = URL(fileURLWithPath: path)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,              forKey: .id)
        try c.encode(filename,        forKey: .filename)
        try c.encode(mimeType,        forKey: .mimeType)
        try c.encode(localURL.path,   forKey: .localURL)
    }
}
