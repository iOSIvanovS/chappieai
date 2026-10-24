// GitBuildTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of all git_* and build/test tools via MCPToolBridge.
// git_diff is blocked here as a safety net (primary block is in ToolPolicy).
//
// MULTI-PROJECT GIT:
// All git_* tools accept an optional "project" arg. When provided, it is forwarded
// to MCP so git runs in the correct project directory (via projectEnvMap routing).
// When omitted — MCP uses the default (single attached) project path.
//
// build_project / run_tests pass the "project" arg through to MCP unchanged.
// MCP resolves the correct DevEnvironment from its projectEnvMap using that name.

import Foundation

extension ToolExecutionService {

    func executeGitBuildTool(name: String, argsData: Data) async throws -> String {
        // Decode args once — used by most tools below
        let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]

        switch name {

        // MARK: - Git tools
        // "project" is forwarded when present so MCP can resolve the correct working directory.

        case "git_status":
            return await mcpBridge.execute(tool: "git_status", args: args)

        case "git_diff":
            // Safety net — primary block is in ToolPolicy.
            return "❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money."

        case "git_add":
            var addArgs = args
            if addArgs["paths"] == nil { addArgs["paths"] = "." }
            return await mcpBridge.execute(tool: "git_add", args: addArgs)

        case "git_commit":
            guard args["message"] != nil else {
                return "Error: Argument 'message' is required for git_commit"
            }
            return await mcpBridge.execute(tool: "git_commit", args: args)

        case "git_push":
            // remote defaults to "origin", branch defaults to "main" — handled in MCP/GitTools
            return await mcpBridge.execute(tool: "git_push", args: args)

        case "git_log":
            return await mcpBridge.execute(tool: "git_log", args: args)

        case "git_reset":
            return await mcpBridge.execute(tool: "git_reset", args: args)

        case "git_revert":
            guard let hashes = args["hashes"], !hashes.isEmpty else {
                return "Error: Argument 'hashes' is required for git_revert (space-separated hashes)"
            }
            guard let message = args["message"], !message.isEmpty else {
                return "Error: Argument 'message' is required for git_revert"
            }
            return await mcpBridge.execute(tool: "git_revert", args: args)

        case "git_checkout":
            guard let ref = args["ref"], !ref.isEmpty else {
                return "Error: Argument 'ref' is required for git_checkout (e.g.: HEAD~1, abc123, main)"
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return "Error: Argument 'paths' is required for git_checkout (space-separated paths)"
            }
            return await mcpBridge.execute(tool: "git_checkout", args: args)

        // MARK: - Build & test tools
        // "project" arg is passed through from argsData — MCP routes to the correct env per project.

        case "build_project":
            return await mcpBridge.execute(tool: "build_project", args: args)

        case "run_tests":
            return await mcpBridge.execute(tool: "run_tests", args: args)

        case "read_build_log":
            return await mcpBridge.execute(tool: "read_build_log")

        default:
            return "Error: Unknown git/build tool '\(name)'"
        }
    }
}
