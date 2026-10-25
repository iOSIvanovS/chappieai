// OfficeMediaIntake.swift
// ChappieCore
//
// The app's side of "pictures from an Office document". The helper (ChappieMCP) writes the
// pictures into its own temp folder and names them in a separate response field. Here they are
// validated, downscaled like every other image, and the folder is deleted.
//
// The helper is a separate process and the paths come over a socket, so nothing is trusted:
// the folder must be a direct child of the shared media root, and every file a plain (non-link)
// file directly inside that folder. Anything else is ignored and nothing outside is touched.

import Foundation

public enum OfficeMediaIntake {

    /// One picture as the helper reports it.
    public struct Item: Sendable {
        public let label: String
        public let path: String

        public init(label: String, path: String) {
            self.label = label
            self.path = path
        }
    }

    /// Must match OfficeMediaCollector.directoryName in ChappieMCP.
    public static let directoryName = "chappie-mcp-media"
    static let maxImageBytes = 30 * 1024 * 1024

    /// The helper is our child process and inherits the temp directory, so both sides agree on it.
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The tool result: `text` as is when there is nothing to show, otherwise the marker form that
    /// carries the pictures. The helper's folder is deleted either way once it has been accepted.
    public static func process(
        text: String,
        mediaDir: String?,
        items: [Item]?,
        root: URL = defaultRoot
    ) -> String {
        guard let mediaDir, let items, !items.isEmpty else { return text }
        guard let directory = acceptedDirectory(mediaDir, root: root) else {
            return text + "\n<!-- Images of this document could not be passed on (unexpected location). -->"
        }
        defer { try? FileManager.default.removeItem(atPath: directory) }

        var images: [ToolImageResult.Image] = []
        var failed = 0
        for item in items.prefix(ToolImageResult.maxImages) {
            guard let data = readPlainFile(item.path, insideRealDirectory: directory),
                  let uri = ImageDownscaler.dataURI(for: data, mimeType: mimeType(forFileAt: item.path)) else {
                failed += 1
                continue
            }
            images.append(ToolImageResult.Image(label: item.label, dataURI: uri))
        }

        var fullText = text
        if failed > 0 {
            fullText += "\n<!-- \(failed) image(s) of this document could not be prepared and are not shown. -->"
        }
        return ToolImageResult(text: fullText, images: images).encoded()
    }

    // MARK: - Validation

    /// Real path of `path` when it is a folder that sits directly inside the media root.
    static func acceptedDirectory(_ path: String, root: URL) -> String? {
        guard let realDirectory = realPath(path), let realRoot = realPath(root.path),
              (realDirectory as NSString).deletingLastPathComponent == realRoot else { return nil }
        var info = stat()
        guard lstat(realDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return realDirectory
    }

    /// File bytes when `path` is a regular file (not a link) directly inside `directory`.
    static func readPlainFile(_ path: String, insideRealDirectory directory: String) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, Int(info.st_size) <= maxImageBytes,
              let real = realPath(path),
              (real as NSString).deletingLastPathComponent == directory else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: real))
    }

    static func mimeType(forFileAt path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
