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
}

// MARK: - ToolResult

struct ToolResult: Sendable {
    let value: String?
    let error: String?

    static func success(_ value: String) -> ToolResult { ToolResult(value: value, error: nil) }
    static func failure(_ error: String) -> ToolResult { ToolResult(value: nil, error: error) }
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
