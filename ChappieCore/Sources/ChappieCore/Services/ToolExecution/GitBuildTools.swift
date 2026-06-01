// GitBuildTools.swift
// ChappieCore
//
// WHY THIS FILE:
// Execution of all git_* and build/test tools via MCPToolBridge.
// git_diff is blocked here as a safety net (primary block is in ToolAccessControl).

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
                return "Ошибка: Аргумент 'message' обязателен для git_commit"
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
                return "Ошибка: Аргумент 'hashes' обязателен для git_revert (хэши через пробел)"
            }
            guard let message = args["message"], !message.isEmpty else {
                return "Ошибка: Аргумент 'message' обязателен для git_revert"
            }
            return await mcpBridge.execute(tool: "git_revert", args: ["hashes": hashes, "message": message])

        case "git_checkout":
            guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                  let ref = args["ref"], !ref.isEmpty else {
                return "Ошибка: Аргумент 'ref' обязателен для git_checkout (например: HEAD~1, abc123, main)"
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return "Ошибка: Аргумент 'paths' обязателен для git_checkout (пути через пробел)"
            }
            return await mcpBridge.execute(tool: "git_checkout", args: ["ref": ref, "paths": paths])

        // MARK: - Build & test tools

        case "build_project":
            return await mcpBridge.execute(tool: "build_project")

        case "run_tests":
            let args = (try? JSONDecoder().decode([String: String].self, from: argsData)) ?? [:]
            return await mcpBridge.execute(tool: "run_tests", args: args)

        case "read_build_log":
            return await mcpBridge.execute(tool: "read_build_log")

        default:
            return "Ошибка: Неизвестный git/build tool '\(name)'"
        }
    }
}
