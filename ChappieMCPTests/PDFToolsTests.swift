// PDFToolsTests.swift
//
// pdf_info, pdf_page_as_txt and pdf_page_as_image read a PDF through PDFKit. The PDFs here are
// generated with CoreGraphics/CoreText, so the tests need no fixture files: a page with text, a
// page that is only a coloured rectangle (a "scan"), and a page that is both.

import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
@testable import ChappieMCPCore

struct PDFToolsTests {

    private enum PageContent {
        case text(String)
        case pictureOnly
    }

    private struct Fixture {
        let root: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    /// Writes a PDF whose pages follow `pages`; every page is `size` points.
    private func writePDF(_ name: String, pages: [PageContent], size: CGSize = CGSize(width: 612, height: 792), in fx: Fixture) throws {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try #require(CGDataConsumer(data: data))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let string):
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let attributed = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                let line = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: size.height - 100)
                CTLineDraw(line, context)
            case .pictureOnly:
                context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
            }
            context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: fx.root.appendingPathComponent(name))
    }

    private func tools(_ fx: Fixture) -> DocumentTools { DocumentTools(projectPath: fx.root.path) }

    // MARK: - pdf_info

    @Test func infoReportsPagesAndTextVolumePerPage() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("Hello world and more text"), .pictureOnly, .text("Third")], in: fx)

        let result = tools(fx).pdfInfo(relativePath: "a.pdf")
        let text = try #require(result.value)
        #expect(text.contains("Pages: 3"))
        #expect(text.contains("Page 1: 21 chars"))   // whitespace is not counted
        #expect(text.contains("Page 2: 0 chars"))
        #expect(text.contains("Page 3: 5 chars"))
        #expect(text.contains("612x792 pt"))
        // Page 3 has a few characters only: below the threshold it counts as a scan too.
        #expect(text.contains("No text layer on page(s): 2, 3"))
    }

    @Test func infoOfAPDFWithTextOnEveryPageHasNoScanHint() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("t.pdf", pages: [.text("First page with enough text"), .text("Second page with enough text")], in: fx)
        let text = try #require(tools(fx).pdfInfo(relativePath: "t.pdf").value)
        #expect(!text.contains("No text layer"))
    }

    // MARK: - pdf_page_as_txt

    @Test func textOfOnePage() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("First page"), .text("Second page")], in: fx)

        let text = try #require(tools(fx).pdfPageText(relativePath: "a.pdf", page: "2").value)
        #expect(text.contains("[page 2 of 2]"))
        #expect(text.contains("Second page"))
        #expect(!text.contains("First page"))
    }

    @Test func textOfARangeKeepsPageMarkersInOrder() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("Alpha"), .text("Beta"), .text("Gamma")], in: fx)

        let text = try #require(tools(fx).pdfPageText(relativePath: "a.pdf", page: "1-3").value)
        let alpha = try #require(text.range(of: "Alpha"))
        let beta = try #require(text.range(of: "Beta"))
        let gamma = try #require(text.range(of: "Gamma"))
        #expect(alpha.lowerBound < beta.lowerBound && beta.lowerBound < gamma.lowerBound)
        #expect(text.contains("[page 1 of 3]") && text.contains("[page 3 of 3]"))
    }

    @Test func aPageWithoutTextPointsToTheImageTool() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("scan.pdf", pages: [.pictureOnly], in: fx)
        let text = try #require(tools(fx).pdfPageText(relativePath: "scan.pdf", page: "1").value)
        #expect(text.contains("pdf_page_as_image"))
    }

    // MARK: - Page argument

    @Test func pageArgumentIsMandatory() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("x")], in: fx)

        #expect(tools(fx).pdfPageText(relativePath: "a.pdf", page: nil).error?.contains("'page' is required") == true)
        #expect(tools(fx).pdfPageText(relativePath: "a.pdf", page: "  ").error != nil)
        #expect(tools(fx).pdfPageImage(relativePath: "a.pdf", page: nil).error?.contains("'page' is required") == true)
    }

    @Test func pageSpecParsing() {
        func parse(_ raw: String?, count: Int = 10, range: Bool = true) -> Result<ClosedRange<Int>, PDFToolError> {
            DocumentTools.parsePageSpec(raw, pageCount: count, allowRange: range, tool: "t")
        }
        #expect((try? parse("3").get()) == 3...3)
        #expect((try? parse(" 2-4 ").get()) == 2...4)
        #expect((try? parse("2–4").get()) == 2...4)       // en dash typed by a model or a keyboard
        #expect((try? parse("5-5").get()) == 5...5)

        #expect(parse("0").isFailure)                      // pages count from 1
        #expect(parse("-3").isFailure)
        #expect(parse("4-2").isFailure)                    // backwards
        #expect(parse("abc").isFailure)
        #expect(parse("1-2-3").isFailure)
        #expect(parse("11").isFailure)                     // beyond the last page
        #expect(parse("8-12").isFailure)
        #expect(parse("2-4", range: false).isFailure)      // image: one page per call
        #expect((try? parse("2", range: false).get()) == 2...2)
        #expect(parse("1-\(DocumentTools.pdfMaxTextPages + 1)", count: 500).isFailure)
        #expect((try? parse("1-\(DocumentTools.pdfMaxTextPages)", count: 500).get()) != nil)
    }

    @Test func aPageBeyondTheEndNamesTheRealCount() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("x"), .text("y")], in: fx)
        let error = try #require(tools(fx).pdfPageText(relativePath: "a.pdf", page: "7").error)
        #expect(error.contains("2 pages"))
    }

    // MARK: - pdf_page_as_image

    @Test func pageImageIsAJPEGWithTheLongSideAt2000() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("x"), .pictureOnly], in: fx)

        let result = tools(fx).pdfPageImage(relativePath: "a.pdf", page: "2")
        let media = try #require(result.media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }

        let file = try #require(media.files.first)
        #expect(media.files.count == 1)
        #expect(file.label.contains("page 2 of 2"))
        #expect(file.path.hasPrefix(media.directory))
        // File paths travel in the media field only, never in the text.
        #expect(!(result.value ?? "").contains(media.directory))

        let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]))     // JPEG signature
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) == 2000)
        #expect(height > width)                             // letter page stays portrait
    }

    @Test func aLandscapePageKeepsItsProportions() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("wide.pdf", pages: [.pictureOnly], size: CGSize(width: 800, height: 400), in: fx)
        let media = try #require(tools(fx).pdfPageImage(relativePath: "wide.pdf", page: "1").media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }

        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(media.files.first).path))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 2000)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 1000)
    }

    @Test func theRenderedPageShowsTheRedRectangleOnWhite() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.pictureOnly], in: fx)
        let media = try #require(tools(fx).pdfPageImage(relativePath: "a.pdf", page: "1").media)
        defer { try? FileManager.default.removeItem(atPath: media.directory) }

        let data = try Data(contentsOf: URL(fileURLWithPath: try #require(media.files.first).path))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let scale = Double(image.height) / 792
        // Rectangle spans x 100..300, y 100..300 from the BOTTOM; row 0 of the bitmap is the top.
        func pixel(x: Double, yFromBottom: Double) -> (r: Int, g: Int, b: Int) {
            var rgba = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let px = Int(x * scale), py = image.height - 1 - Int(yFromBottom * scale)
            ctx.draw(image, in: CGRect(x: -px, y: -(image.height - 1 - py), width: image.width, height: image.height))
            return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
        }
        let inside = pixel(x: 200, yFromBottom: 200)
        #expect(inside.r > 200 && inside.g < 60 && inside.b < 60)
        let outside = pixel(x: 500, yFromBottom: 600)
        #expect(outside.r > 240 && outside.g > 240 && outside.b > 240)
    }

    // MARK: - Opening

    @Test func aMissingFileAndAWrongExtensionAreRefused() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try Data("hello".utf8).write(to: fx.root.appendingPathComponent("a.txt"))

        #expect(tools(fx).pdfInfo(relativePath: "nope.pdf").error?.contains("not found") == true)
        #expect(tools(fx).pdfInfo(relativePath: "a.txt").error?.contains("not a .pdf") == true)
    }

    @Test func aDamagedPDFIsReportedNotCrashed() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try Data("%PDF-1.4 this is not really a pdf".utf8).write(to: fx.root.appendingPathComponent("bad.pdf"))
        let error = try #require(tools(fx).pdfInfo(relativePath: "bad.pdf").error)
        #expect(error.contains("cannot be opened") || error.contains("no pages") || error.contains("damaged"))
    }

    @Test func pathsLeavingTheProjectAreRefused() throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        #expect(tools(fx).pdfInfo(relativePath: "../outside.pdf").error != nil)
        #expect(tools(fx).pdfPageText(relativePath: "/etc/x.pdf", page: "1").error != nil)
        #expect(tools(fx).pdfPageImage(relativePath: "../x.pdf", page: "1").error != nil)
    }

    // MARK: - read_document no longer reads PDF

    @Test func readDocumentRefusesAPDFAndPointsToThePDFTools() async throws {
        let fx = try makeFixture()
        defer { fx.cleanup() }
        try writePDF("a.pdf", pages: [.text("secret text")], in: fx)

        let result = await tools(fx).readDocument(relativePath: "a.pdf")
        let error = try #require(result.error)
        #expect(error.contains("pdf_info") && error.contains("pdf_page_as_txt") && error.contains("pdf_page_as_image"))
        #expect(result.value == nil)
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
