// GitBuildTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of all git_* and build/test tools via MCPToolBridge.
// git_diff is blocked here as a safety net (primary block is in ToolAccessControl).
//
// build_project / run_tests pass the "project" arg through to MCP unchanged.
// MCP resolves the correct DevEnvironment from its projectEnvMap using that name.

import Foundation

extension ToolExecutionService {

    func executeGitBuildTool(name: String, argsData: Data) async throws -> String {
        switch name {

        // MARK: - Git tools

        case "git_status":
            return await mcpBridge.execute(tool: "git_status")

        case "git_diff":
            // Safety net — primary block is in checkToolAccess().
            return "❌ git_diff is permanently FORBIDDEN — it loads the entire project into AI context and costs real money."

        case "git_add":
            var args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            if args["paths"] == nil { args["paths"] = "." }
            return await mcpBridge.execute(tool: "git_add", args: args)

        case "git_commit":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let message = args["message"] else {
                return "Error: Argument 'message' is required for git_commit"
            }
            return await mcpBridge.execute(tool: "git_commit", args: ["message": message])

        case "git_log":
            let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            return await mcpBridge.execute(tool: "git_log", args: args)

        case "git_reset":
            return await mcpBridge.execute(tool: "git_reset")

        case "git_revert":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let hashes = args["hashes"], !hashes.isEmpty else {
                return "Error: Argument 'hashes' is required for git_revert (space-separated hashes)"
            }
            guard let message = args["message"], !message.isEmpty else {
                return "Error: Argument 'message' is required for git_revert"
            }
            return await mcpBridge.execute(tool: "git_revert", args: ["hashes": hashes, "message": message])

        case "git_checkout":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let ref = args["ref"], !ref.isEmpty else {
                return "Error: Argument 'ref' is required for git_checkout (e.g.: HEAD~1, abc123, main)"
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return "Error: Argument 'paths' is required for git_checkout (space-separated paths)"
            }
            return await mcpBridge.execute(tool: "git_checkout", args: ["ref": ref, "paths": paths])

        // MARK: - Build & test tools
        // "project" arg is passed through from argsData — MCP resolves env from projectEnvMap.

        case "build_project":
            let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            return await mcpBridge.execute(tool: "build_project", args: args)

        case "run_tests":
            let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            return await mcpBridge.execute(tool: "run_tests", args: args)

        case "read_build_log":
            return await mcpBridge.execute(tool: "read_build_log")

        default:
            return "Error: Unknown git/build tool '\(name)'"
        }
    }
}
