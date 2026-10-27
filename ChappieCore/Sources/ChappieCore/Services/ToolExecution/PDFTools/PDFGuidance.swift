// PDFGuidance.swift
// ChappieCore
//
// PDF has its own tool set (pdf_info, pdf_page_as_txt, pdf_page_as_image). Every other reader
// (read_file, read_document, fetch_attachment, search) refuses a PDF with this one message, so the
// model is told where to go instead of getting garbage or a vague failure.

import Foundation

public enum PDFGuidance {

    public static let toolNames: Set<String> = ["pdf_info", "pdf_page_as_txt", "pdf_page_as_image"]

    /// True for a path that names a PDF file.
    public static func isPDF(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "pdf"
    }

    /// `uuid` is given for an attachment, so the model can copy it into the pdf tool call.
    public static func refusal(tool: String, attachmentUUID: String? = nil) -> String {
        let how = attachmentUUID.map { "Pass uuid \"\($0)\" to each of them." } ?? "Pass the file's path (and project) to each of them."
        return """
        `\(tool)` does not read PDF files. Use the PDF tools instead:
        • pdf_info — page count and the amount of text on every page (start here);
        • pdf_page_as_txt — text of one page or a range, e.g. page "3" or "2-4" (the page argument is required);
        • pdf_page_as_image — one page as a picture (required argument `page`): use it for scans, tables, diagrams and layout.
        \(how)
        """
    }
}
