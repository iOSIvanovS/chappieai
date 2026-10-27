// DocumentTools+PDF.swift
// ChappieMCP
//
// WHY THIS FILE:
// PDF is read through a dedicated set of tools, not through read_document: a PDF is a set of
// pages, each of which may hold text, a picture, or both, and the model must be able to ask for
// exactly the page it needs.
//   pdf_info          — page count, text volume and size of every page
//   pdf_page_as_txt   — text of one page or a range of pages
//   pdf_page_as_image — one page drawn as a picture (scans, tables, diagrams)
//
// Only Apple's PDFKit is used: it ships with macOS, so the user installs nothing (an earlier
// version needed pdftotext from Homebrew and fell back to a raw byte scan that returned garbage
// for compressed PDFs).
//
// Pictures travel the same way as Office pictures: written into the helper's own temp folder and
// named in a separate response field, never in the text.

import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct PDFToolError: Error {
    let message: String
}

extension DocumentTools {

    /// A page is drawn this many pixels on its long side (the app downscales nothing below it).
    static let pdfImageLongSide: CGFloat = 2000
    /// One text call may cover this many pages; more must be asked for in several calls.
    static let pdfMaxTextPages = 50
    private static let pdfJPEGQuality: CGFloat = 0.88

    /// Shown by read_document and friends when someone tries to read a PDF the old way.
    static let pdfToolsHint = "PDF files are read with the pdf tools: pdf_info (page count and text volume per page), "
        + "pdf_page_as_txt (text of a page or a range like 2-4) and pdf_page_as_image (a page as a picture; use it "
        + "for scans, tables and diagrams)."

    // MARK: - pdf_info

    func pdfInfo(relativePath: String, projectName: String? = nil) -> ToolResult {
        let opened: OpenedPDF
        do { opened = try openPDF(relativePath, projectName) } catch { return .failure(Self.message(of: error, tool: "pdf_info")) }

        let document = opened.document
        let count = document.pageCount
        var lines = ["PDF: \(opened.name)", "Pages: \(count)"]
        let attributes = document.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { lines.append("Title: \(title)") }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { lines.append("Author: \(author)") }
        guard count > 0 else { return .success(lines.joined(separator: "\n") + "\nThe document has no pages.") }

        var withoutText: [Int] = []
        for index in 0..<count {
            if Task.isCancelled { return .failure("🛑 pdf_info was cancelled.") }
            guard let page = document.page(at: index) else { continue }
            let chars = Self.textVolume(of: page)
            let size = page.bounds(for: .cropBox)
            lines.append("Page \(index + 1): \(chars) chars of text, \(Int(size.width.rounded()))x\(Int(size.height.rounded())) pt")
            // Scans often carry a stray character or two of OCR noise, so "no text" is a threshold, not zero.
            if chars < Self.minMeaningfulChars { withoutText.append(index + 1) }
        }
        if !withoutText.isEmpty {
            let shown = withoutText.prefix(40).map(String.init).joined(separator: ", ")
            let more = withoutText.count > 40 ? ", …" : ""
            lines.append("No text layer on page(s): \(shown)\(more). They are pictures or scans: use pdf_page_as_image for them.")
        }
        return .success(lines.joined(separator: "\n"))
    }

    // MARK: - pdf_page_as_txt

    func pdfPageText(relativePath: String, projectName: String? = nil, page spec: String?) -> ToolResult {
        let opened: OpenedPDF
        do { opened = try openPDF(relativePath, projectName) } catch { return .failure(Self.message(of: error, tool: "pdf_page_as_txt")) }
        let range: ClosedRange<Int>
        switch Self.parsePageSpec(spec, pageCount: opened.document.pageCount, allowRange: true, tool: "pdf_page_as_txt") {
        case .failure(let error): return .failure(error.message)
        case .success(let parsed): range = parsed
        }

        var parts: [String] = []
        for number in range {
            if Task.isCancelled { return .failure("🛑 pdf_page_as_txt was cancelled.") }
            let text = (opened.document.page(at: number - 1)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text.isEmpty
                ? "(no text on this page: it is a picture or a scan; use pdf_page_as_image to see it)"
                : text
            parts.append("[page \(number) of \(opened.document.pageCount)]\n\(body)")
        }
        return .success(parts.joined(separator: "\n\n"))
    }

    // MARK: - pdf_page_as_image

    func pdfPageImage(relativePath: String, projectName: String? = nil, page spec: String?) -> ToolResult {
        let opened: OpenedPDF
        do { opened = try openPDF(relativePath, projectName) } catch { return .failure(Self.message(of: error, tool: "pdf_page_as_image")) }
        let total = opened.document.pageCount
        let number: Int
        switch Self.parsePageSpec(spec, pageCount: total, allowRange: false, tool: "pdf_page_as_image") {
        case .failure(let error): return .failure(error.message)
        case .success(let parsed): number = parsed.lowerBound
        }
        guard let page = opened.document.page(at: number - 1), let jpeg = Self.renderJPEG(page) else {
            return .failure("pdf_page_as_image: page \(number) could not be drawn.")
        }
        guard let directory = OfficeMediaCollector.makeDirectory() else {
            return .failure("pdf_page_as_image: could not prepare a folder for the picture.")
        }
        let file = directory.appendingPathComponent("page-\(number).jpg")
        guard (try? jpeg.write(to: file, options: .atomic)) != nil else {
            try? FileManager.default.removeItem(at: directory)
            return .failure("pdf_page_as_image: could not write the picture.")
        }
        let label = "page \(number) of \(total) of \(opened.name)"
        return .success(
            "Page \(number) of \(total) of \(opened.name) is shown to you separately as an image.",
            media: ToolMedia(directory: directory.path, files: [ToolMediaFile(label: label, path: file.path)])
        )
    }

    // MARK: - Page spec

    /// "3" or "2-4" (pages count from 1). A range is refused where only one page makes sense.
    static func parsePageSpec(_ raw: String?, pageCount: Int, allowRange: Bool, tool: String) -> Result<ClosedRange<Int>, PDFToolError> {
        func fail(_ text: String) -> Result<ClosedRange<Int>, PDFToolError> { .failure(PDFToolError(message: "\(tool): \(text)")) }

        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return fail("argument 'page' is required: a page number like 3\(allowRange ? " or a range like 2-4" : "") (pages count from 1).")
        }
        let normalized = raw.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let pieces = normalized.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = pieces.compactMap { Int($0) }
        guard (pieces.count == 1 || pieces.count == 2), numbers.count == pieces.count, numbers.allSatisfy({ $0 >= 1 }) else {
            return fail("'page' must be a page number like 3\(allowRange ? " or a range like 2-4" : "") (pages count from 1), got '\(raw)'.")
        }
        // Checked before the range is built: `a...b` with a > b traps.
        guard numbers[0] <= numbers[numbers.count - 1] else { return fail("the range '\(raw)' is backwards.") }
        let range = numbers[0]...numbers[numbers.count - 1]
        if range.count > 1 && !allowRange {
            return fail("only one page can be drawn per call. Ask for pages one at a time.")
        }
        guard range.upperBound <= pageCount else {
            let bad = range.upperBound
            return fail("page \(bad) does not exist: the document has \(pageCount) page\(pageCount == 1 ? "" : "s").")
        }
        guard range.count <= pdfMaxTextPages else {
            return fail("a range may cover at most \(pdfMaxTextPages) pages per call; split the request.")
        }
        return .success(range)
    }

    // MARK: - Rendering

    /// The page as a white-backed JPEG whose long side is `pdfImageLongSide` pixels.
    static func renderJPEG(_ page: PDFPage) -> Data? {
        // cropBox with the page's own rotation applied: what a viewer would show.
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = pdfImageLongSide / max(box.width, box.height)
        let width = max(1, Int((box.width * scale).rounded()))
        let height = max(1, Int((box.height * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // PDFKit lays the box (and the page's rotation) out onto a context whose origin is the
        // lower-left corner of the page.
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: pdfJPEGQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Opening

    private struct OpenedPDF {
        let document: PDFDocument
        let name: String
    }

    private func openPDF(_ relativePath: String, _ projectName: String?) throws -> OpenedPDF {
        let path: String
        do { path = try resolvePath(relativePath, projectName: projectName) }
        catch { throw PDFToolError(message: "\(error)") }
        guard FileManager.default.fileExists(atPath: path) else {
            throw PDFToolError(message: "file not found at '\(relativePath)'.")
        }
        guard (path as NSString).pathExtension.lowercased() == "pdf" else {
            throw PDFToolError(message: "'\(relativePath)' is not a .pdf file.")
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw PDFToolError(message: "'\(relativePath)' cannot be opened as a PDF (the file may be damaged).")
        }
        // An empty user password is what many "protected" files actually use.
        if document.isLocked, !document.unlock(withPassword: "") {
            throw PDFToolError(message: "'\(relativePath)' is password-protected and cannot be read. Tell the user.")
        }
        return OpenedPDF(document: document, name: (path as NSString).lastPathComponent)
    }

    private static func message(of error: Error, tool: String) -> String {
        if let failure = error as? PDFToolError { return "\(tool): \(failure.message)" }
        return "\(tool): \(error)"
    }

    /// Below this many non-whitespace characters a page is treated as a picture or scan.
    static let minMeaningfulChars = 20

    /// Characters of text on the page, not counting whitespace.
    private static func textVolume(of page: PDFPage) -> Int {
        guard let text = page.string else { return 0 }
        let blanks = CharacterSet.whitespacesAndNewlines
        return text.unicodeScalars.reduce(0) { blanks.contains($1) ? $0 : $0 + 1 }
    }
}
