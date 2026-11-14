// ToolDispatcher.swift
//
// Routes tool calls to the appropriate handler classes.
//
// git_* and document tools use projectPathMap to resolve per-project paths. The app always sends a
// project name; the fallbacks inside those classes serve direct helper calls (tests, manual runs).

import Foundation

final class ToolDispatcher: Sendable {
    private let gitTools: GitTools
    private let docTools: DocumentTools

    init(projectPath: String, projectPathMap: [String: String] = [:]) {
        self.gitTools   = GitTools(projectPath: projectPath, projectPathMap: projectPathMap)
        self.docTools   = DocumentTools(projectPath: projectPath, projectPathMap: projectPathMap)
    }

    func execute(tool: String, args: [String: String]) async -> ToolResult {
        switch tool {

        // MARK: - Git tools
        // "project" arg resolves the correct working directory via projectPathMap.

        case "git_status":
            return await gitTools.status(projectName: args["project"])

        case "git_add":
            let paths = args["paths"] ?? "."
            return await gitTools.add(paths: paths, projectName: args["project"])

        case "git_commit":
            guard let message = args["message"], !message.isEmpty else {
                return .failure("Argument 'message' is required for git_commit")
            }
            return await gitTools.commit(message: message, projectName: args["project"])

        case "git_push":
            let remote = args["remote"] ?? "origin"
            let branch = args["branch"] ?? "main"
            return await gitTools.push(remote: remote, branch: branch, projectName: args["project"])

        case "git_log":
            let count = Int(args["count"] ?? "10") ?? 10
            return await gitTools.log(count: count, projectName: args["project"])

        case "git_reset":
            return await gitTools.reset(projectName: args["project"])

        case "git_revert":
            guard let hashes = args["hashes"], !hashes.isEmpty else {
                return .failure("Argument 'hashes' is required (space-separated commit hashes)")
            }
            let message = args["message"] ?? "revert: roll back commits \(args["hashes"] ?? "")"
            return await gitTools.revert(hashes: hashes, message: message, projectName: args["project"])

        case "git_checkout":
            guard let ref = args["ref"], !ref.isEmpty else {
                return .failure("Argument 'ref' is required (e.g. HEAD~1, abc123, main)")
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return .failure("Argument 'paths' is required (space-separated file paths)")
            }
            return await gitTools.checkout(ref: ref, paths: paths, projectName: args["project"])

        // MARK: - Document tools

        case "read_document":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'contract.docx')")
            }
            return await docTools.readDocument(relativePath: path, projectName: args["project"])

        // MARK: - PDF tools (the only way a PDF is read)

        case "pdf_info":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'report.pdf')")
            }
            return docTools.pdfInfo(relativePath: path, projectName: args["project"])

        case "pdf_page_as_txt":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'report.pdf')")
            }
            return docTools.pdfPageText(relativePath: path, projectName: args["project"], page: args["page"])

        case "pdf_page_as_image":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'report.pdf')")
            }
            return docTools.pdfPageImage(relativePath: path, projectName: args["project"], page: args["page"])

        case "write_document":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required")
            }
            guard let content = args["content"], !content.isEmpty else {
                return .failure("Argument 'content' is required (full XML or text content)")
            }
            return docTools.writeDocument(
                relativePath: path,
                xmlContent: content,
                outputPath: args["output_path"],
                entryName: args["entry_name"],
                projectName: args["project"]
            )

        default:
            return .failure("Unknown tool: \(tool).")
        }
    }
}
