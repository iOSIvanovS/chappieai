// PDFTools.swift
// ChappieCore
//
// Executes pdf_info / pdf_page_as_txt / pdf_page_as_image: works out WHICH file is meant (an
// attachment by uuid, or a project path) and hands the call to the ChappieMCP helper, which reads
// the PDF with PDFKit. A page picture comes back like an Office picture (ToolImageResult).
//
// These tools are classified `alwaysOn` because a PDF may be an attachment in a thread that has no
// project at all; for a project path the project is resolved here, never guessed.

import Foundation

extension ToolExecutionService {

    func executePDFTool(name: String, argsData: Data) async -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData) else {
            return "Error: Invalid arguments for \(name)"
        }

        var mcpArgs: [String: String] = [:]
        if let page = args["page"] { mcpArgs["page"] = page }

        // The mandatory page is checked by the helper too, but failing here saves a round trip.
        if name != "pdf_info", (args["page"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return "Error: Argument 'page' is required for \(name): a page number counting from 1"
                + (name == "pdf_page_as_txt" ? " or a range like 2-4." : ".") + " Call pdf_info to see the page count."
        }

        if let uuidText = args["uuid"], !uuidText.isEmpty {
            guard let uuid = UUID(uuidString: uuidText) else { return "Error: 'uuid' must be a valid UUID." }
            guard let resolve = resolveAttachment else { return "Error: Attachment handler not available. Please restart the app." }
            guard let url = resolve(uuid) else { return "Error: No attachment found for uuid: \(uuidText)" }
            guard PDFGuidance.isPDF(path: url.path) else { return "Error: Attachment \(url.lastPathComponent) is not a PDF." }
            mcpArgs["path"] = url.path
        } else if let path = args["path"], !path.isEmpty {
            guard PDFGuidance.isPDF(path: path) else { return "Error: '\(path)' is not a .pdf file." }
            switch projectForPDF(path: path, requested: args["project"]) {
            case .failure(let message): return message
            case .success(let project): if let project { mcpArgs["project"] = project }
            }
            mcpArgs["path"] = path
        } else {
            return "Error: Pass 'path' (with 'project') or the 'uuid' of an attachment."
        }

        return await mcpBridge.execute(tool: name, args: mcpArgs)
    }

    // MARK: - Project of a path

    private enum PDFProject {
        case success(String?)
        case failure(String)
    }

    /// The canonical project name for a relative path. An absolute path (the attachments folder)
    /// needs no project; several projects without a name is an error, not a guess.
    private func projectForPDF(path: String, requested: String?) -> PDFProject {
        if path.hasPrefix("/") { return .success(nil) }
        let projects = activeMemoryContext.projects
        let names = projects.map { "'\($0.name)'" }.joined(separator: ", ")

        if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            if let exact = projects.first(where: { $0.name == requested }) { return .success(exact.name) }
            let folded = projects.filter { $0.name.lowercased() == requested.lowercased() }
            if folded.count == 1 { return .success(folded[0].name) }
            return .failure("❌ Project '\(requested)' is not attached to this thread. Attached: \(names.isEmpty ? "(none)" : names).")
        }
        if projects.count == 1 { return .success(projects[0].name) }
        if projects.isEmpty {
            return .failure("❌ No project is attached, so a path cannot be resolved. Use the 'uuid' of an attached PDF, or attach the project.")
        }
        if let byPrefix = projects.first(where: { path.hasPrefix($0.name + "/") }) { return .success(byPrefix.name) }
        return .failure("❌ Several projects are attached, so you must say which one. Pass the 'project' argument — one of: \(names).")
    }
}
