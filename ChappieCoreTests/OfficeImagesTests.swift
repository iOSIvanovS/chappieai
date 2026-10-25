// OfficeImagesTests.swift
// ChappieCoreTests
//
// Pictures inside Office documents: the app only accepts files from the helper's own media folder,
// downscales them like any other image, deletes the folder, and judges only the TEXT by the size gate.

import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ChappieCore

// MARK: - Helpers

private enum Fixture {

    static func png(width: Int, height: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) {
                ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                         blue: .random(in: 0...1, using: &rng), alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pixelWidth(ofDataURI uri: String) -> Int? {
        guard let comma = uri.firstIndex(of: ","),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyPixelWidth] as? Int
    }

    /// A media root with one helper folder inside, like the helper creates it.
    static func mediaRoot() throws -> (root: URL, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mediaroot-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder)
    }
}

// MARK: - Marker

@Suite("ToolImageResult")
struct ToolImageResultTests {

    @Test("Text and pictures survive the marker round trip")
    func roundTrip() throws {
        let original = ToolImageResult(text: "doc <!-- [image 1: a.png] -->", images: [
            .init(label: "image 1: word/media/a.png", dataURI: "data:image/jpeg;base64,AAAA")
        ])
        let decoded = try #require(ToolImageResult.decode(original.encoded()))
        #expect(decoded == original)
    }

    @Test("Without pictures the result is plain text")
    func noImagesIsPlain() {
        let result = ToolImageResult(text: "just text", images: [])
        #expect(result.encoded() == "just text")
        #expect(ToolImageResult.decode("just text") == nil)
    }

    @Test("A broken or empty marker is not a result with pictures")
    func malformed() {
        #expect(ToolImageResult.decode(ToolImageResult.marker + "not json") == nil)
        #expect(ToolImageResult.decode(ToolImageResult.marker + "{\"text\":\"x\",\"images\":[]}") == nil)
        #expect(ToolImageResult.plainText(of: ToolImageResult.marker + "garbage") == ToolImageResult.marker + "garbage")
    }

    @Test("A marker result is capped at the extractor's maximum")
    func capped() throws {
        let many = (0..<30).map { ToolImageResult.Image(label: "i\($0)", dataURI: "data:image/png;base64,AA") }
        let decoded = try #require(ToolImageResult.decode(ToolImageResult(text: "t", images: many).encoded()))
        #expect(decoded.images.count == ToolImageResult.maxImages)
    }

    @Test("Parts for the model: a label before each picture")
    func parts() {
        let result = ToolImageResult(text: "t", images: [.init(label: "image 1: a", dataURI: "data:image/png;base64,AA")])
        #expect(result.multimodalParts.count == 2)
        if case .text(let label) = result.multimodalParts[0] { #expect(label == "image 1: a") } else { Issue.record("label first") }
        if case .imageURL = result.multimodalParts[1] {} else { Issue.record("picture second") }
    }
}

// MARK: - Intake

@Suite("OfficeMediaIntake")
struct OfficeMediaIntakeTests {

    @Test("Pictures are downscaled, folded into the result, and the helper folder is deleted")
    func acceptsAndCleans() throws {
        let (root, folder) = try Fixture.mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("1-image1.png")
        try Fixture.png(width: 3000, height: 1500).write(to: file)

        let result = OfficeMediaIntake.process(
            text: "<doc/>", mediaDir: folder.path,
            items: [.init(label: "image 1: word/media/image1.png", path: file.path)], root: root)

        let decoded = try #require(ToolImageResult.decode(result))
        #expect(decoded.text == "<doc/>")
        #expect(decoded.images.count == 1)
        #expect(Fixture.pixelWidth(ofDataURI: decoded.images[0].dataURI) == ImageDownscaler.maxLongSide)
        #expect(!FileManager.default.fileExists(atPath: folder.path), "temp folder is removed")
    }

    @Test("No pictures reported: the text is returned untouched")
    func noMedia() {
        #expect(OfficeMediaIntake.process(text: "t", mediaDir: nil, items: nil) == "t")
        #expect(OfficeMediaIntake.process(text: "t", mediaDir: "/tmp/x", items: []) == "t")
    }

    @Test("A folder outside the media root is refused and nothing there is read or deleted")
    func foreignFolder() throws {
        let (root, _) = try Fixture.mediaRoot()
        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: foreign) }
        let secret = foreign.appendingPathComponent("secret.png")
        try Fixture.png(width: 100, height: 100).write(to: secret)

        let result = OfficeMediaIntake.process(
            text: "t", mediaDir: foreign.path, items: [.init(label: "x", path: secret.path)], root: root)

        #expect(ToolImageResult.decode(result) == nil)
        #expect(result.contains("unexpected location"))
        #expect(FileManager.default.fileExists(atPath: secret.path), "a foreign folder is never deleted")
    }

    @Test("A file named in the response but living outside the folder is skipped")
    func fileOutsideFolder() throws {
        let (root, folder) = try Fixture.mediaRoot()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).png")
        try Fixture.png(width: 100, height: 100).write(to: outside)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let inside = folder.appendingPathComponent("1-ok.png")
        try Fixture.png(width: 100, height: 100).write(to: inside)

        let result = OfficeMediaIntake.process(text: "t", mediaDir: folder.path, items: [
            .init(label: "evil", path: outside.path),
            .init(label: "ok", path: inside.path)
        ], root: root)

        let decoded = try #require(ToolImageResult.decode(result))
        #expect(decoded.images.map(\.label) == ["ok"])
        #expect(decoded.text.contains("1 image(s)"))
        #expect(FileManager.default.fileExists(atPath: outside.path), "the outside file is untouched")
    }

    @Test("A symlink inside the folder pointing outside is skipped")
    func symlinkSkipped() throws {
        let (root, folder) = try Fixture.mediaRoot()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("target-\(UUID().uuidString).png")
        try Fixture.png(width: 100, height: 100).write(to: target)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: target) }
        let link = folder.appendingPathComponent("1-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = OfficeMediaIntake.process(
            text: "t", mediaDir: folder.path, items: [.init(label: "link", path: link.path)], root: root)

        #expect(ToolImageResult.decode(result) == nil)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test("A folder that is not a direct child of the root is refused")
    func nestedFolder() throws {
        let (root, folder) = try Fixture.mediaRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = folder.appendingPathComponent("deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(OfficeMediaIntake.acceptedDirectory(nested.path, root: root) == nil)
        #expect(OfficeMediaIntake.acceptedDirectory(folder.path, root: root) != nil)
    }
}

// MARK: - Gate

@Suite("OutputGuard — documents with pictures")
struct OutputGuardDocumentImagesTests {

    private func result(textBytes: Int) -> String {
        ToolImageResult(text: String(repeating: "a", count: textBytes),
                        images: [.init(label: "image 1: a", dataURI: "data:image/jpeg;base64,\(String(repeating: "A", count: 500_000))")])
            .encoded()
    }

    @Test("The pictures do not count against the text limit")
    func picturesAreFree() {
        let output = result(textBytes: 1_000)
        #expect(OutputGuard.apply(toolName: "read_document", output: output) == output)
    }

    @Test("Text over the limit is refused even when pictures come with it")
    func bigTextRefused() {
        let output = result(textBytes: OutputGuard.readLimit + 1)
        #expect(OutputGuard.apply(toolName: "read_document", output: output).contains("DATA NOT PASSED"))
    }

    @Test("Only document tools may return pictures behind the marker")
    func otherToolsAreText() {
        let output = result(textBytes: 1_000)
        #expect(OutputGuard.apply(toolName: "read_file", output: output).contains("DATA NOT PASSED"))
    }

    @Test("An absurdly large imitation is refused outright")
    func imitationCapped() {
        let huge = ToolImageResult.marker + String(repeating: "x", count: OutputGuard.documentImagesCap + 1)
        #expect(OutputGuard.apply(toolName: "read_document", output: huge).contains("DATA NOT PASSED"))
    }
}
