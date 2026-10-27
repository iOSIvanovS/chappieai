// DocumentTools+Media.swift
// ChappieMCP
//
// WHY THIS FILE:
// An Office document is more than its text: pictures inside it matter to whoever reads it.
// The collector finds the pictures a document actually uses, leaves a comment marker in the XML
// where each one sits, and writes the picture files into a private temp folder. The app picks them
// up from there and shows them to the model as real images.
//
// The marker is an XML comment: it keeps the document valid, so the XML can still be edited and
// written back with write_document. File paths travel in a separate response field, never in the
// text, so the text of a document cannot make the app open a file.

import Foundation
import ZIPFoundation

final class OfficeMediaCollector {

    static let directoryName = "chappie-mcp-media"
    /// Pictures beyond this are reported but not extracted (a request has a provider-side image cap).
    static let maxImages = 20
    static let maxImageBytes: UInt64 = 30 * 1024 * 1024
    static let maxTotalBytes: UInt64 = 120 * 1024 * 1024
    /// Folders left behind by a crashed run are removed after this long.
    static let staleAfter: TimeInterval = 3600
    /// Raster formats every provider accepts. EMF/WMF/SVG/BMP/TIFF are skipped.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    struct Output {
        /// A comment for the top of the document text, empty when the document has no pictures.
        let note: String
        let media: ToolMedia?
    }

    private let archive: Archive
    private let folders: [String]
    private var numbers: [String: Int] = [:]
    private var order: [String] = []
    private var relationshipCache: [String: [String: String]] = [:]

    init(archive: Archive, mediaFolders: [String]) {
        self.archive = archive
        self.folders = mediaFolders
    }

    private var isEnabled: Bool { !folders.isEmpty }

    // MARK: - Markers in the XML

    /// Inserts `<!-- [image N: name] -->` before every picture reference of `xml` (a part of the
    /// archive at `partPath`). Numbers follow the order of first appearance in the document.
    func annotate(_ xml: String, partPath: String) -> String {
        guard isEnabled else { return xml }
        let text = xml as NSString
        let rels = relationships(forPart: partPath)
        var hits: [(location: Int, entry: String)] = []

        func collect(_ pattern: String, resolve: (String) -> String?) {
            for match in matches(pattern, in: xml) where match.numberOfRanges > 1 {
                let key = text.substring(with: match.range(at: 1))
                if let entry = resolve(key), isImageEntry(entry) {
                    hits.append((match.range.location, entry))
                }
            }
        }
        // DrawingML (docx, pptx, xlsx), legacy VML, and OpenDocument.
        collect(#"<a:blip\b[^>]*?\br:embed="([^"]+)""#) { rels[$0] }
        collect(#"<v:imagedata\b[^>]*?\br:id="([^"]+)""#) { rels[$0] }
        collect(#"<draw:image\b[^>]*?\bxlink:href="([^"]+)""#) { Self.decoded($0) }
        guard !hits.isEmpty else { return xml }

        hits.sort { $0.location < $1.location }
        var out = ""
        var cursor = 0
        for hit in hits {
            out += text.substring(with: NSRange(location: cursor, length: hit.location - cursor))
            out += "<!-- [image \(number(for: hit.entry)): \(Self.safeName(hit.entry))] -->"
            cursor = hit.location
        }
        out += text.substring(from: cursor)
        return out
    }

    // MARK: - Extraction

    /// Writes the pictures (referenced ones first, in document order, then any others in the media
    /// folders) into a fresh temp folder.
    func finish() -> Output {
        guard isEnabled else { return Output(note: "", media: nil) }

        // Pictures nobody references from a part we read (e.g. a spreadsheet's drawings).
        var skipped = 0
        var extra: [String] = []
        for entry in archive where folders.contains(where: { entry.path.hasPrefix($0) }) && entry.type == .file {
            if numbers[entry.path] != nil { continue }
            if isImageEntry(entry.path) { extra.append(entry.path) } else { skipped += 1 }
        }
        for path in extra.sorted() { _ = number(for: path) }
        guard !order.isEmpty else {
            return Output(note: skipped > 0 ? Self.skippedOnlyNote(skipped) : "", media: nil)
        }

        guard let directory = Self.makeDirectory() else {
            return Output(note: "<!-- Images: this document has \(order.count), but they could not be prepared. -->\n", media: nil)
        }

        var files: [ToolMediaFile] = []
        var totalBytes: UInt64 = 0
        for (offset, path) in order.enumerated() {
            let n = offset + 1
            guard n <= Self.maxImages,
                  let entry = archive[path],
                  entry.uncompressedSize > 0,
                  entry.uncompressedSize <= Self.maxImageBytes,
                  totalBytes + entry.uncompressedSize <= Self.maxTotalBytes,
                  let data = extract(entry) else {
                skipped += 1
                continue
            }
            // Only the last path component, prefixed by the number: an entry name can never steer
            // the file outside the temp folder (zip-slip).
            let fileURL = directory.appendingPathComponent("\(n)-\(Self.fileSafe(path))")
            guard (try? data.write(to: fileURL, options: .atomic)) != nil else { skipped += 1; continue }
            totalBytes += UInt64(data.count)
            files.append(ToolMediaFile(label: "image \(n): \(path)", path: fileURL.path))
        }

        guard !files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            return Output(note: "<!-- Images: this document has \(order.count), none could be extracted. -->\n", media: nil)
        }
        var note = "<!-- Images: \(files.count) shown to you separately as images (numbered as in the [image N] markers)."
        if skipped > 0 {
            note += " \(skipped) not shown (unsupported format, too large, or over the limit of \(Self.maxImages))."
        }
        note += " Markers are informational; leave them out of content passed to write_document. -->\n"
        return Output(note: note, media: ToolMedia(directory: directory.path, files: files))
    }

    // MARK: - Internals

    private func number(for entry: String) -> Int {
        if let existing = numbers[entry] { return existing }
        order.append(entry)
        numbers[entry] = order.count
        return order.count
    }

    private func isImageEntry(_ path: String) -> Bool {
        guard folders.contains(where: { path.hasPrefix($0) }),
              Self.imageExtensions.contains((path as NSString).pathExtension.lowercased()) else { return false }
        return archive[path] != nil
    }

    private func extract(_ entry: Entry) -> Data? {
        var data = Data()
        do { _ = try archive.extract(entry, consumer: { data.append($0) }) } catch { return nil }
        return data
    }

    /// `rId5 → word/media/image3.png` for one part, read from its `_rels` file.
    private func relationships(forPart partPath: String) -> [String: String] {
        if let cached = relationshipCache[partPath] { return cached }
        let ns = partPath as NSString
        let dir = ns.deletingLastPathComponent
        let relsPath = (dir.isEmpty ? "" : dir + "/") + "_rels/" + ns.lastPathComponent + ".rels"
        var map: [String: String] = [:]
        if let entry = archive[relsPath], let data = extract(entry), let xml = String(data: data, encoding: .utf8) {
            let text = xml as NSString
            for match in matches(#"<Relationship\b[^>]*>"#, in: xml) {
                let tag = text.substring(with: match.range)
                guard !tag.contains("TargetMode=\"External\""),
                      let id = Self.attribute("Id", in: tag),
                      let target = Self.attribute("Target", in: tag) else { continue }
                map[id] = Self.resolve(Self.decoded(target), baseDir: dir)
            }
        }
        relationshipCache[partPath] = map
        return map
    }

    private func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\""),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
              match.numberOfRanges > 1 else { return nil }
        return (tag as NSString).substring(with: match.range(at: 1))
    }

    private static func decoded(_ value: String) -> String { value.removingPercentEncoding ?? value }

    /// Package-relative target → archive path ("../media/a.png" from "ppt/slides" → "ppt/media/a.png").
    static func resolve(_ target: String, baseDir: String) -> String {
        var parts: [String] = target.hasPrefix("/") ? [] : baseDir.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/") {
            switch piece {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }

    /// Name shown inside an XML comment, which must not contain "--".
    private static func safeName(_ entry: String) -> String {
        (entry as NSString).lastPathComponent.replacingOccurrences(of: "--", with: "-")
    }

    private static func fileSafe(_ entry: String) -> String {
        let name = (entry as NSString).lastPathComponent
        return String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func skippedOnlyNote(_ count: Int) -> String {
        "<!-- Images: \(count) in this document are in a format that cannot be shown (not PNG/JPEG/GIF/WebP). -->\n"
    }

    // MARK: - Temp folder

    /// Root that the app also knows: it only deletes a folder whose parent has this name.
    static var rootDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Also used by the PDF page renderer: same folder, same cleanup, same app-side validation.
    static func makeDirectory() -> URL? {
        let fm = FileManager.default
        let root = rootDirectory
        do { try fm.createDirectory(at: root, withIntermediateDirectories: true) } catch { return nil }
        pruneStale(in: root)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: false) } catch { return nil }
        return directory
    }

    /// The app deletes a folder after reading it; this catches the ones a crash left behind.
    private static func pruneStale(in root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > staleAfter {
                try? fm.removeItem(at: item)
            }
        }
    }
}
