// OfficeMediaTests.swift
//
// read_document returns the XML of a Word/PowerPoint/Excel file with a marker comment at every
// picture and the pictures themselves in a separate, helper-owned temp folder. These tests build
// small real OOXML archives with /usr/bin/zip and read them through DocumentTools.

import Testing
import Foundation
@testable import ChappieMCPCore

struct OfficeMediaTests {

    /// 1x1 transparent PNG.
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private struct Fixture {
        let root: URL
        func path(_ name: String) -> String { root.appendingPathComponent(name).path }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    /// Writes `files` (relative path → data) into a folder and zips it into `<root>/<name>`.
    private func makeArchive(_ name: String, files: [String: Data], in fixture: Fixture) throws {
        let staging = fixture.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        for (relative, data) in files {
            let url = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-X", fixture.path(name), "."]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        try #require(zip.terminationStatus == 0)
    }

    private func docx(body: String, relationships: String, media: [String: Data]) -> [String: Data] {
        var files: [String: Data] = [
            "word/document.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="w" xmlns:a="a" xmlns:r="r"><w:body>\(body)</w:body></w:document>
            """.utf8),
            "word/_rels/document.xml.rels": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="rels">\(relationships)</Relationships>
            """.utf8)
        ]
        for (name, data) in media { files["word/media/\(name)"] = data }
        return files
    }

    private func relationship(_ id: String, _ target: String) -> String {
        #"<Relationship Id="\#(id)" Type="image" Target="\#(target)"/>"#
    }

    private func blip(_ id: String) -> String { #"<w:p><a:blip r:embed="\#(id)"/></w:p>"# }

    // MARK: - Tests

    @Test func markersSitBeforePicturesAndFilesAreWrittenSeparately() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("two.docx", files: docx(
            body: blip("rId1") + "<w:p>text</w:p>" + blip("rId2"),
            relationships: relationship("rId1", "media/first.png") + relationship("rId2", "media/second.png"),
            media: ["first.png": Self.png, "second.png": Self.png]
        ), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "two.docx")
        let text = try #require(result.value)
        let media = try #require(result.media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }

        // The marker carries only the file name (never an archive path); the label keeps the full entry.
        let first = try #require(text.range(of: "<!-- [image 1: first.png] -->"))
        let second = try #require(text.range(of: "<!-- [image 2: second.png] -->"))
        #expect(first.lowerBound < second.lowerBound)

        #expect(media.files.count == 2)
        #expect(media.files.map(\.label) == ["image 1: word/media/first.png", "image 2: word/media/second.png"])
        for file in media.files {
            #expect(FileManager.default.fileExists(atPath: file.path))
            #expect(file.path.hasPrefix(media.directory))
        }
        // File paths must travel in the separate field, never inside the text.
        #expect(!text.contains(media.directory))
    }

    @Test func samePictureUsedTwiceGetsOneNumber() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("dup.docx", files: docx(
            body: blip("rId1") + blip("rId1"),
            relationships: relationship("rId1", "media/logo.png"),
            media: ["logo.png": Self.png]
        ), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "dup.docx")
        let media = try #require(result.media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }

        #expect(media.files.count == 1)
        #expect(try #require(result.value).components(separatedBy: "[image 1: logo.png]").count == 3)
    }

    @Test func unreferencedPictureIsStillShown() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("orphan.docx", files: docx(
            body: "<w:p>no picture here</w:p>", relationships: "", media: ["lonely.png": Self.png]
        ), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "orphan.docx")
        let media = try #require(result.media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }
        #expect(media.files.count == 1)
    }

    @Test func unsupportedFormatsAreSkippedAndReported() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("emf.docx", files: docx(
            body: blip("rId1"), relationships: relationship("rId1", "media/chart.emf"),
            media: ["chart.emf": Data([1, 2, 3])]
        ), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "emf.docx")
        #expect(result.media == nil)
        #expect(!(result.value ?? "").contains("[image 1"))
    }

    @Test func documentWithoutPicturesHasNoMarkersAndNoFolder() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("plain.docx", files: docx(body: "<w:p>hello</w:p>", relationships: "", media: [:]), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "plain.docx")
        #expect(result.media == nil)
        #expect(!(result.value ?? "").contains("[image"))
        #expect((result.value ?? "").contains("hello"))
    }

    @Test func pictureCountIsCapped() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let count = OfficeMediaCollector.maxImages + 5
        var body = "", rels = ""
        var media: [String: Data] = [:]
        for i in 1...count {
            body += blip("rId\(i)")
            rels += relationship("rId\(i)", "media/p\(i).png")
            media["p\(i).png"] = Self.png
        }
        try makeArchive("many.docx", files: docx(body: body, relationships: rels, media: media), in: fx)

        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "many.docx")
        let found = try #require(result.media)
        defer { try? FileManager.default.removeItem(atPath: found.directory) }
        #expect(found.files.count == OfficeMediaCollector.maxImages)
    }

    @Test func textWithMarkersIsStillWritableXML() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try makeArchive("rw.docx", files: docx(
            body: blip("rId1"), relationships: relationship("rId1", "media/a.png"), media: ["a.png": Self.png]
        ), in: fx)
        let tools = DocumentTools(projectPath: fx.root.path)

        let read = await tools.readDocument(relativePath: "rw.docx")
        if let media = read.media { defer { try? FileManager.default.removeItem(atPath: media.directory) } }
        let text = try #require(read.value)
        // Marker comments keep the XML well-formed, so a read-edit-write round trip must parse.
        let body = text.replacingOccurrences(of: "<!-- Entry: word/document.xml -->\n", with: "")
        let xmlStart = try #require(body.range(of: "<?xml"))
        let parser = XMLParser(data: Data(body[xmlStart.lowerBound...].utf8))
        #expect(parser.parse(), "XML with markers must stay well-formed: \(String(describing: parser.parserError))")
    }

    @Test func escapingThePathIsRefused() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let tools = DocumentTools(projectPath: fx.root.path)

        let up = await tools.readDocument(relativePath: "../outside.docx")
        #expect(up.error != nil)
        let absolute = await tools.readDocument(relativePath: "/etc/hosts.csv")
        #expect(absolute.error != nil)
    }

    @Test func unsupportedExtensionIsRefused() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        let result = await DocumentTools(projectPath: fx.root.path).readDocument(relativePath: "file.exe")
        #expect(result.error?.contains("unsupported format") == true)
    }
}
