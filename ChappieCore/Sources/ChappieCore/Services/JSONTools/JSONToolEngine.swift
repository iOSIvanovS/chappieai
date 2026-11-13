// JSONToolEngine.swift
// ChappieCore
//
// Pure entry point of the read-only json_* tools: bytes + arguments in, text for the model out.
// No file system, no actor: the executor reads the file and calls this on a detached task.

import Foundation

public enum JSONToolEngine {

    public static let toolNames: Set<String> = ["json_info", "json_schema", "json_get", "json_find"]

    /// Largest file the tools accept.
    public static let maxFileBytes = 64 * 1024 * 1024

    /// Answers one call. Every failure comes back as readable text starting with "Error:".
    public static func run(tool: String, data: Data, fileName: String, arguments: [String: String]) -> String {
        do {
            if let problem = unknownArgumentProblem(tool: tool, arguments: arguments) { return "Error: \(problem)" }
            if let problem = encodingProblem(data) { return "Error: \(problem)" }
            let doc = try JSONDocument.parse(data)
            let args = JSONToolArgs(values: arguments)
            switch tool {
            case "json_info":
                return JSONInfo.report(doc, fileName: fileName, maxChars: args.maxChars)
            case "json_schema":
                return try JSONSchemaTool.report(
                    doc, fileName: fileName, at: args.path("at"),
                    depth: args.int("depth", default: 6, in: 1...20), maxChars: args.maxChars
                )
            case "json_get":
                let depth = args.string("depth") == nil ? nil : try args.int("depth", default: 1, in: 1...200)
                return try JSONFragment.get(doc, fileName: fileName, at: args.path("at"), depth: depth, maxChars: args.maxChars)
            case "json_find":
                return try JSONFinder.run(doc, fileName: fileName, query: JSONFindQuery(args), maxChars: args.maxChars)
            default:
                return "Error: Unknown json tool '\(tool)'"
            }
        } catch let error as JSONParseError {
            return "Error: \(fileName) is not valid JSON. \(error.errorDescription ?? error.message)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Arguments each of the three simple tools accepts. json_find checks its own list in JSONFindQuery.
    static let knownArguments: [String: Set<String>] = [
        "json_info": ["path", "project", "max_chars"],
        "json_schema": ["path", "project", "at", "depth", "max_chars"],
        "json_get": ["path", "project", "at", "depth", "max_chars"]
    ]

    /// A near-miss argument name would be dropped silently and the tool would answer a different
    /// question than the one asked (for example a "depth" typo returns the whole file).
    static func unknownArgumentProblem(tool: String, arguments: [String: String]) -> String? {
        guard let known = knownArguments[tool] else { return nil }
        let unknown = arguments.keys.filter { !known.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }
        let names = unknown.map { "'\($0)'" }.joined(separator: ", ")
        return "\(tool) has no argument \(names). Known: \(known.sorted().joined(separator: ", ")). Nothing was read."
    }

    /// A UTF-16 or UTF-32 file would only produce a confusing "unexpected character"; say what it is.
    static func encodingProblem(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return "the file is UTF-32; only UTF-8 JSON is supported. Convert it first (iconv -f UTF-32 -t UTF-8)."
        }
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
            return "the file is UTF-16; only UTF-8 JSON is supported. Convert it first (iconv -f UTF-16 -t UTF-8)."
        }
        return nil
    }
}
