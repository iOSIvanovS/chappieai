// ToolDefinitions+PDFTools.swift
// ChappieCore
//
// The three PDF tools. A PDF is read only through them (every other reader refuses it, see
// PDFGuidance). Each takes either `path` (+ `project`) or `uuid` of an attachment.

import Foundation

extension ToolExecutionService {

    func pdfTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let source: [String: AIToolProperty] = [
            "path": AIToolProperty(type: "string", description: "Relative path to the PDF inside a project. Use this OR uuid."),
            "uuid": AIToolProperty(type: "string", description: "UUID of a PDF attached to the chat (from the attachment reference block). Use this OR path."),
            "project": AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))
        ]
        func properties(_ extra: [String: AIToolProperty]) -> [String: AIToolProperty] { source.merging(extra) { current, _ in current } }

        return [
            AITool(function: AIFunctionDefinition(
                name: "pdf_info",
                description: """
                Overview of a PDF: number of pages, title/author, and for every page the amount of text on it and its size.
                Start here. Pages with 0 chars of text are pictures or scans: read them with pdf_page_as_image.
                Pass `path` (+ `project`) or the `uuid` of an attachment. Reading a PDF with read_file, read_document or \
                fetch_attachment is not possible — use the pdf_* tools.
                """,
                parameters: AIToolParameters(properties: properties([:]), required: [])
            )),
            AITool(function: AIFunctionDefinition(
                name: "pdf_page_as_txt",
                description: """
                Text of one page of a PDF, or of a range of pages (e.g. page "3" or "2-4", at most 50 pages per call). \
                Pages count from 1. The `page` argument is required — call pdf_info first to see how many pages there are \
                and how much text each has. A page without a text layer (scan, picture) returns a note: use pdf_page_as_image.
                Pass `path` (+ `project`) or the `uuid` of an attachment.
                """,
                parameters: AIToolParameters(
                    properties: properties(["page": AIToolProperty(type: "string", description: "Page number from 1 (\"3\") or a range (\"2-4\"). Required.")]),
                    required: ["page"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "pdf_page_as_image",
                description: """
                One page of a PDF drawn as a picture (long side 2000 px); you see it in the next message. \
                Use it for scans, tables, diagrams, forms and anything where layout matters. \
                The `page` argument is required and is a single page number from 1. Costs more than pdf_page_as_txt: \
                ask only for the pages you need.
                Pass `path` (+ `project`) or the `uuid` of an attachment.
                """,
                parameters: AIToolParameters(
                    properties: properties(["page": AIToolProperty(type: "string", description: "Single page number, counting from 1. Required.")]),
                    required: ["page"]
                )
            ))
        ]
    }
}
