// ToolDefinitions+FileTools.swift
// ChappieCore
//
// File system, search, document, and attachment tool definitions.

import Foundation

extension ToolExecutionService {

    func fileSystemTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        var tools: [AITool] = []
        let multiProject = allInfos.count > 1
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "list_files",
            description: "Get the list of all files in the project (relative paths).",
            parameters: AIToolParameters(
                properties: ["project": AIToolProperty(type: "string", description: listFilesProjectArgDescription(for: allInfos))],
                required: multiProject ? ["project"] : []
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "read_file",
            description: """
            Read the entire contents of a file.
            Use when: you don't know what to change yet, need to understand the full file structure, \
            or plan to rewrite more than 40% of the file.
            Do NOT use if you already know where the change is — use search_in_file → patch_file instead. \
            Reading the whole file is expensive.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                    "project": projectArg
                ],
                required: multiProject ? ["path", "project"] : ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "write_file",
            description: """
            Create a new file or fully overwrite an existing one (subdirectories are created automatically).
            Use when: creating a new file, or rewriting more than 40% of an existing file after read_file.
            NEVER write partial content — always provide the complete final file.
            Do NOT use for small edits to an existing file — use patch_file instead. \
            It is much cheaper: no file content in context.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                    "content": AIToolProperty(type: "string", description: "Full code or text to write into the file"),
                    "project": projectArg
                ],
                required: multiProject ? ["path", "content", "project"] : ["path", "content"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "delete_file",
            description: "Delete a file from the project.",
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the file to delete"),
                    "project": projectArg
                ],
                required: multiProject ? ["path", "project"] : ["path"]
            )
        )))

        tools.append(AITool(function: AIFunctionDefinition(
            name: "view_image",
            description: """
            View an image file located inside a project folder (png, jpg, jpeg, gif, webp).
            Use when the user refers to a screenshot or image they created/saved in the project \
            (not attached directly to the chat) and you need to actually see its content.
            Unlike read_file, this returns the image itself for visual inspection, not text.
            Large images are downscaled automatically (long side up to 2000 px) before you see them.
            """,
            parameters: AIToolParameters(
                properties: [
                    "path": AIToolProperty(type: "string", description: "Relative path to the image file"),
                    "project": projectArg
                ],
                required: multiProject ? ["path", "project"] : ["path"]
            )
        )))

        return tools
    }

    func fileMetaAndEditTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let multiProject = allInfos.count > 1
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))

        return [
            AITool(function: AIFunctionDefinition(
                name: "get_file_info",
                description: "Get metadata for a file: size, line count, and last modification date.\nUse instead of read_file when you only need to know if a file is large or when it was changed.\nMuch cheaper than read_file — returns only metadata, not the file content.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                        "project": projectArg
                    ],
                    required: multiProject ? ["path", "project"] : ["path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "patch_file",
                description: """
                Replace an exact block of text in a file without reading the whole file.
                Use when: you already know exactly what to change (found via search_in_file), \
                the edit is localized, and you don't need to understand the full file.
                PREFER this over read_file → write_file for small edits — ~94% cheaper.
                The 'find' block must be unique in the file (3–5 lines minimum). \
                Safety policy: if 0 or 2+ matches are found — the tool refuses and returns an error. Nothing is changed.
                For multiple separate edits in one file — call patch_file once per location.
                Requires Executor role.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file"),
                        "find": AIToolProperty(type: "string", description: "Exact block of text to find (must be unique in the file — use 3–5 lines minimum for safety)"),
                        "replace": AIToolProperty(type: "string", description: "Text to replace the found block with. Can be empty string to delete the block."),
                        "project": projectArg
                    ],
                    required: multiProject ? ["path", "find", "replace", "project"] : ["path", "find", "replace"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "move_file",
                description: "Move a file to a new location within the same project.\nUse for reorganizing files or moving them between folders.\nMuch cheaper than read_file → write_file → delete_file — no file content in context.\nRequires Executor role. Fails if the destination already exists.",
                parameters: AIToolParameters(
                    properties: [
                        "from": AIToolProperty(type: "string", description: "Current relative path of the file"),
                        "to": AIToolProperty(type: "string", description: "New relative path (destination). Subdirectories are created automatically."),
                        "project": projectArg
                    ],
                    required: multiProject ? ["from", "to", "project"] : ["from", "to"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "rename_file",
                description: "Rename a file in place (same directory, new name).\nUse for renaming files during refactoring.\nSame as move_file but semantically clearer when only the name changes.\nRequires Executor role. Fails if a file with the new name already exists.",
                parameters: AIToolParameters(
                    properties: [
                        "from": AIToolProperty(type: "string", description: "Current relative path of the file"),
                        "to": AIToolProperty(type: "string", description: "New relative path with the new filename"),
                        "project": projectArg
                    ],
                    required: multiProject ? ["from", "to", "project"] : ["from", "to"]
                )
            ))
        ]
    }

    func searchTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let multiProject = allInfos.count > 1
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))

        return [
            AITool(function: AIFunctionDefinition(
                name: "search_in_file",
                description: """
                Search for a string inside a single file. Returns matching lines with surrounding context.
                Use when: you know which file to edit but don't know the exact location. \
                The context_lines parameter shows N lines around each match — use it to verify \
                the surrounding code before calling patch_file.
                After search_in_file — go directly to patch_file if the context is sufficient. \
                Do NOT call read_file in between — that wastes tokens on content you don't need.
                Much cheaper than read_file — returns only relevant lines, not the whole file.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the file to search in"),
                        "query": AIToolProperty(type: "string", description: "String to search for (case-insensitive)"),
                        "context_lines": AIToolProperty(type: "string", description: "Number of lines to show before and after each match (default: 2)"),
                        "project": projectArg
                    ],
                    required: multiProject ? ["path", "query", "project"] : ["path", "query"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "search_in_project",
                description: "Search for a string across all files in the project (like grep -r).\nReturns a list of matching files with line numbers and surrounding context.\nUse to find where a function is called, where a symbol is defined, or where a string appears.\nUse file_pattern to narrow results (e.g. '*.swift', '*.ts').",
                parameters: AIToolParameters(
                    properties: [
                        "query": AIToolProperty(type: "string", description: "String to search for (case-insensitive)"),
                        "file_pattern": AIToolProperty(type: "string", description: "Optional file extension filter (e.g. '*.swift', '*.ts'). Omit to search all text files."),
                        "context_lines": AIToolProperty(type: "string", description: "Number of lines to show before and after each match (default: 2)"),
                        "project": projectArg
                    ],
                    required: ["query"]
                )
            ))
        ]
    }

    func documentTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let multiProject = allInfos.count > 1
        let projectArg = AIToolProperty(type: "string", description: fileToolProjectArgDescription(for: allInfos))

        return [
            AITool(function: AIFunctionDefinition(
                name: "read_document",
                description: "Read an Office document (Word, Excel, PowerPoint, PDF, etc.) and return its full content as XML or text.\nUse exactly like read_file — get complete content, understand the structure, then decide what to change.\nSupported formats: .docx, .xlsx, .pptx, .odt (XML-based ZIP), .rtf, .csv (plain text), .pdf (text extraction).\nFor .docx/.pptx/.xlsx — returns word/document.xml, all slide*.xml, or for Excel workbook.xml (sheet names) + sharedStrings.xml + ALL worksheets (each as its own '<!-- Entry: ... -->' block). To write one sheet back, pass its entry name (e.g. 'xl/worksheets/sheet2.xml') as entry_name to write_document.\nXML preserves all formatting and structure. You can read, analyze, and prepare edits based on it.\nPictures inside Word/PowerPoint/Excel/ODT files are NOT in the text: each place where one sits is marked with an XML comment `<!-- [image N: name] -->`, and the pictures themselves follow in the next message as images, numbered the same way. Do not copy those comments into content you pass to write_document.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the document file (e.g. 'contract.docx', 'report.xlsx')"),
                        "project": projectArg
                    ],
                    required: multiProject ? ["path", "project"] : ["path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "write_document",
                description: "Save modified content back to an Office document.\nUse exactly like write_file — provide the full modified XML or text content.\nFor ZIP-based formats (.docx, .xlsx, .pptx, .odt): replaces only the primary XML entry,\nall other ZIP entries (styles, images, relationships) are preserved untouched.\nFor text formats (.rtf, .csv): overwrites the file directly.\nIf output_path is provided — saves as a new file, original is untouched.\nIf output_path is omitted — overwrites the original document.\nAfter saving — call send_attachment with the saved path to deliver the file to the user.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path to the original document"),
                        "content": AIToolProperty(type: "string", description: "Full modified XML (for docx/xlsx/pptx/odt) or text (for rtf/csv)"),
                        "output_path": AIToolProperty(type: "string", description: "Optional: save as a new file at this path, keeping the original untouched"),
                        "entry_name": AIToolProperty(type: "string", description: "Optional: override which ZIP entry to replace (e.g. 'ppt/slides/slide2.xml'). Defaults to the primary entry for each format."),
                        "project": projectArg
                    ],
                    required: multiProject ? ["path", "content", "project"] : ["path", "content"]
                )
            ))
        ]
    }

    func attachmentTools() -> [AITool] {
        return [
            AITool(function: AIFunctionDefinition(
                name: "fetch_attachment",
                description: "Read a file attachment from the current thread by its UUID.\nUse when the user has sent you a file and you want to read its contents.\nReturns: the image itself for images (you see it in the next message), XML for Office documents (docx/xlsx/pptx),\nextracted text for PDFs, UTF-8 string for plain text files. Other file types return only their size and type.\nThe UUID is shown in the attachment reference block: [Attachment: filename | uuid: ...]",
                parameters: AIToolParameters(
                    properties: ["uuid": AIToolProperty(type: "string", description: "UUID of the attachment to fetch (from the attachment reference block)")],
                    required: ["uuid"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "send_attachment",
                description: "Save a file and attach it to the current AI message so the user receives it as a downloadable bubble.\nUse after preparing file content (e.g. modifying a document) to deliver the result to the user.\nFor Office documents (docx/xlsx/pptx): provide source_uuid of the original file — the tool patches\nthe existing ZIP (preserving styles, images, relationships) and saves as a new file.\nFor images: provide base64-encoded content (with or without data URI prefix).\nFor text files: provide plain UTF-8 content.\nThe user will see a chip with the filename and can open or save the file.",
                parameters: AIToolParameters(
                    properties: [
                        "filename": AIToolProperty(type: "string", description: "Filename with extension (e.g. 'Plan_updated.docx', 'report.xlsx')"),
                        "content": AIToolProperty(type: "string", description: "File content: XML for Office docs, base64 for images, UTF-8 for text"),
                        "mime_type": AIToolProperty(type: "string", description: "MIME type of the file (e.g. 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'image/png', 'text/plain')"),
                        "source_uuid": AIToolProperty(type: "string", description: "Optional: UUID of the original attachment to patch (required for Office documents to preserve ZIP structure)")
                    ],
                    required: ["filename", "content", "mime_type"]
                )
            ))
        ]
    }
}
