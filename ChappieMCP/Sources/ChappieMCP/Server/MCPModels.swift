// MCPModels.swift
//
// Wire models and result types shared across the MCP server layer.

import Foundation

// MARK: - Wire Models

struct MCPRequest: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

struct MCPResponse: Codable, Sendable {
    let result: String?
    let error: String?
    /// Pictures extracted from an Office document. Deliberately NOT part of `result`: the text of a
    /// document must never be able to name a file the app will open.
    let mediaDir: String?
    let media: [ToolMediaFile]?
}

/// One extracted picture: a label for the model and where the helper wrote it.
struct ToolMediaFile: Codable, Sendable {
    let label: String
    let path: String
}

/// Pictures the helper wrote into its own temp folder; the app reads and deletes the folder.
struct ToolMedia: Sendable {
    let directory: String
    let files: [ToolMediaFile]
}

// MARK: - ToolResult

struct ToolResult: Sendable {
    let value: String?
    let error: String?
    let media: ToolMedia?

    static func success(_ value: String, media: ToolMedia? = nil) -> ToolResult {
        ToolResult(value: value, error: nil, media: media)
    }
    static func failure(_ error: String) -> ToolResult { ToolResult(value: nil, error: error, media: nil) }
}

// MARK: - MCPServerError

enum MCPServerError: Error, CustomStringConvertible {
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    var description: String {
        switch self {
        case .socketCreationFailed(let msg): return "Failed to create socket: \(msg)"
        case .bindFailed(let msg):           return "bind() failed: \(msg)"
        case .listenFailed(let msg):         return "listen() failed: \(msg)"
        }
    }
}
