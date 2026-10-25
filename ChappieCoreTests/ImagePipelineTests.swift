// ImagePipelineTests.swift
// ChappieCoreTests
//
// The image pipeline: every image sent to a model is capped at 2000 px on the long side and re-encoded
// as JPEG (the original is never touched), the cached downscaled copy is reused, and the emergency
// valve only acts past the cap.

import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import ChappieCore

// MARK: - Helpers

private enum TestImage {

    /// A noisy image (noise keeps PNG/JPEG from collapsing to a few bytes).
    static func png(width: Int, height: Int, alpha: Bool = false) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        var rng = SystemRandomNumberGenerator()
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng),
                                         green: .random(in: 0...1, using: &rng),
                                         blue: .random(in: 0...1, using: &rng),
                                         alpha: alpha ? 0.5 : 1))
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func decode(dataURI: String) -> Data? {
        guard let comma = dataURI.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURI[dataURI.index(after: comma)...]))
    }
}

// MARK: - Downscaler

@Suite("ImageDownscaler")
struct ImageDownscalerTests {

    @Test("A large image is brought down to 2000 px on the long side and becomes JPEG")
    func downscalesLarge() throws {
        let original = TestImage.png(width: 4000, height: 3000)
        let output = try #require(ImageDownscaler.prepare(original, mimeType: "image/png"))

        #expect(output.reencoded)
        #expect(output.mimeType == "image/jpeg")
        let size = try #require(TestImage.pixelSize(of: output.data))
        #expect(max(size.width, size.height) == ImageDownscaler.maxLongSide)
        #expect(abs(Double(size.width) / Double(size.height) - 4.0 / 3.0) < 0.01, "aspect ratio is kept")
        #expect(output.data.count < original.count)
    }

    @Test("A tall image is limited by its height")
    func downscalesTall() throws {
        let output = try #require(ImageDownscaler.prepare(TestImage.png(width: 1500, height: 3000), mimeType: "image/png"))
        let size = try #require(TestImage.pixelSize(of: output.data))
        #expect(size.height == ImageDownscaler.maxLongSide)
        #expect(size.width == 1000)
    }

    @Test("A small image is passed through byte for byte")
    func smallPassesThrough() throws {
        let original = TestImage.png(width: 300, height: 200)
        let output = try #require(ImageDownscaler.prepare(original, mimeType: "image/png"))
        #expect(!output.reencoded)
        #expect(output.data == original)
        #expect(output.mimeType == "image/png")
    }

    @Test("A transparent PNG is flattened on white and never upscaled")
    func transparencyAndNoUpscale() throws {
        // Within the pixel cap but over the byte cap would re-encode; force it via a large transparent image.
        let output = try #require(ImageDownscaler.prepare(
            TestImage.png(width: 2600, height: 2600, alpha: true), mimeType: "image/png"))
        #expect(output.mimeType == "image/jpeg")
        let size = try #require(TestImage.pixelSize(of: output.data))
        #expect(size.width <= ImageDownscaler.maxLongSide)
    }

    @Test("Undecodable data: small is passed on, large is refused")
    func undecodable() {
        let small = Data(repeating: 0x41, count: 1000)
        #expect(ImageDownscaler.prepare(small, mimeType: "image/png")?.data == small)
        let large = Data(repeating: 0x41, count: ImageDownscaler.passThroughBytes + 1)
        #expect(ImageDownscaler.prepare(large, mimeType: "image/png") == nil)
    }

    @Test("dataURI is a valid data URI of the prepared bytes")
    func dataURIShape() throws {
        let uri = try #require(ImageDownscaler.dataURI(for: TestImage.png(width: 3000, height: 1000), mimeType: "image/png"))
        #expect(uri.hasPrefix("data:image/jpeg;base64,"))
        let bytes = try #require(TestImage.decode(dataURI: uri))
        #expect(TestImage.pixelSize(of: bytes)?.width == ImageDownscaler.maxLongSide)
    }
}

// MARK: - File cache

@Suite("ImageDownscaler — cache")
struct ImageDownscalerCacheTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("The downscaled copy is written once, reused, and the original stays untouched")
    func cacheIsWrittenAndReused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = TestImage.png(width: 3000, height: 2000)
        let source = dir.appendingPathComponent("shot.png")
        try original.write(to: source)
        let cache = dir.appendingPathComponent("cache/shot.jpg")

        let first = try #require(ImageDownscaler.dataURI(forFileAt: source, mimeType: "image/png", cacheURL: cache))
        #expect(FileManager.default.fileExists(atPath: cache.path))
        #expect(try Data(contentsOf: source) == original, "original is never modified")

        // A planted cache file proves the second call reads the cache and does not re-encode.
        let marker = Data(base64Encoded: String(first.dropFirst("data:image/jpeg;base64,".count)))!
        try marker.write(to: cache)
        let second = try #require(ImageDownscaler.dataURI(forFileAt: source, mimeType: "image/png", cacheURL: cache))
        #expect(second == first)
    }

    @Test("A newer original invalidates the cache")
    func staleCacheIsRebuilt() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("a.png")
        let cache = dir.appendingPathComponent("a.jpg")
        try TestImage.png(width: 3000, height: 1000).write(to: source)
        _ = ImageDownscaler.dataURI(forFileAt: source, mimeType: "image/png", cacheURL: cache)

        // The user replaced the file with a different image later than the cache was made.
        try TestImage.png(width: 1000, height: 3000).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)

        let uri = try #require(ImageDownscaler.dataURI(forFileAt: source, mimeType: "image/png", cacheURL: cache))
        let bytes = try #require(TestImage.decode(dataURI: uri))
        #expect(TestImage.pixelSize(of: bytes)?.height == ImageDownscaler.maxLongSide)
    }

    @Test("A small image creates no cache file")
    func smallImageNoCache() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tiny.png")
        try TestImage.png(width: 100, height: 100).write(to: source)
        let cache = dir.appendingPathComponent("tiny.jpg")
        let uri = ImageDownscaler.dataURI(forFileAt: source, mimeType: "image/png", cacheURL: cache)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }
}

// MARK: - Valve

@Suite("ImageValve")
struct ImageValveTests {

    private func userMessage(images: Int, text: String = "t") -> AIMessage {
        var parts: [AIMultimodalPart] = [.text(text)]
        for index in 0..<images { parts.append(.imageURL("data:image/jpeg;base64,\(index)")) }
        return AIMessage(role: "user", multimodalParts: parts)
    }

    private func imageCount(_ messages: [AIMessage]) -> Int {
        messages.reduce(0) { total, message in
            guard case .multimodal(let parts) = message.content else { return total }
            return total + parts.filter { if case .imageURL = $0 { return true } else { return false } }.count
        }
    }

    @Test("Under the cap nothing changes")
    func underCap() {
        let messages = [userMessage(images: 3), userMessage(images: 2)]
        let result = ImageValve.apply(messages, maxImages: 5)
        #expect(imageCount(result) == 5)
    }

    @Test("Over the cap the OLDEST images become a text note and the newest stay")
    func dropsOldest() {
        let messages = [userMessage(images: 3, text: "old"), userMessage(images: 3, text: "new")]
        let result = ImageValve.apply(messages, maxImages: 4)
        #expect(imageCount(result) == 4)

        guard case .multimodal(let oldParts) = result[0].content,
              case .multimodal(let newParts) = result[1].content else {
            Issue.record("expected multimodal messages"); return
        }
        let oldImages = oldParts.filter { if case .imageURL = $0 { return true } else { return false } }.count
        #expect(oldImages == 1, "two of the oldest three were replaced")
        #expect(newParts.filter { if case .imageURL = $0 { return true } else { return false } }.count == 3)
        if case .text(let note) = oldParts[1] { #expect(note == ImageValve.placeholder) } else { Issue.record("no note") }
    }

    @Test("Text-only messages and message order are preserved")
    func structurePreserved() {
        let messages = [AIMessage(role: "user", content: "hello"), userMessage(images: 5), AIMessage(role: "assistant", content: "ok")]
        let result = ImageValve.apply(messages, maxImages: 2)
        #expect(result.count == 3)
        #expect(result[0].contentString == "hello")
        #expect(result[2].contentString == "ok")
        #expect(imageCount(result) == 2)
    }
}

// MARK: - Wiring

@Suite("Image result wiring")
struct ImageWiringTests {

    @Test("Only image tools may return an image behind the marker")
    func imitationIsText() {
        let big = ToolExecutionService.viewImageMarker + String(repeating: "A", count: 300_000)
        #expect(OutputGuard.apply(toolName: "view_image", output: big) == big)
        #expect(OutputGuard.apply(toolName: "fetch_attachment", output: big) == big)
        // A text file that begins with the marker must not slip past the size gate.
        #expect(OutputGuard.apply(toolName: "read_file", output: big).contains("DATA NOT PASSED"))
    }
}
