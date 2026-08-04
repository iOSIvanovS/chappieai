// ToolDefinitions+BuildTools.swift
// ChappieCore
//
// Build, test, terminal, and project management tool definitions.

import Foundation

extension ToolExecutionService {

    func buildTools(
        progInfos: [ActiveMemoryContext.ProjectInfo],
        allInfos: [ActiveMemoryContext.ProjectInfo]
    ) -> [AITool] {
        var tools: [AITool] = []

        // Compilation gate: projects with buildEnabled = false are excluded from
        // build_project/run_tests/read_build_log entirely — too slow to compile,
        // user builds and tests manually and reports results back in chat.
        let buildGatedInfos = progInfos.filter {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).buildEnabled
        }
        let projectArgDesc = buildProjectArgDescription(for: buildGatedInfos)

        let buildableInfos = buildGatedInfos.filter {
            (projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment.specificTools.contains("build_project")
        }
        if !buildableInfos.isEmpty {
            tools.append(AITool(function: AIFunctionDefinition(
                name: "build_project",
                description: buildProjectDescription(for: buildableInfos),
                parameters: AIToolParameters(
                    properties: ["project": AIToolProperty(type: "string", description: projectArgDesc)],
                    required: buildableInfos.count > 1 ? ["project"] : []
                )
            )))
        }

        if !buildGatedInfos.isEmpty {
            tools.append(AITool(function: AIFunctionDefinition(
                name: "run_tests",
                description: runTestsDescription(for: buildGatedInfos),
                parameters: AIToolParameters(
                    properties: [
                        "project": AIToolProperty(type: "string", description: projectArgDesc),
                        "target": AIToolProperty(type: "string", description: "Test target name or file/pattern. Empty = all tests.")
                    ],
                    required: buildGatedInfos.count > 1 ? ["project"] : []
                )
            )))

            tools.append(AITool(function: AIFunctionDefinition(
                name: "read_build_log",
                description: "Read the full log of the last build or test run.",
                parameters: AIToolParameters(
                    properties: ["project": AIToolProperty(type: "string", description: projectArgDesc)],
                    required: []
                )
            )))
        }

        return tools
    }

    func terminalTools(progInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let terminalProjectArgDesc = terminalProjectArgDescription(for: progInfos)

        return [
            AITool(function: AIFunctionDefinition(
                name: "run_terminal",
                description: "Execute a command in the terminal in the project's working directory.\nThe session is persistent — cd commands are remembered between calls.\nONLY WHEN NO SPECIALIZED TOOL EXISTS: use list_files/read_file for file navigation; git_* for version control; build_project/run_tests for builds.\nUse run_terminal for: running scripts, installing dependencies, CLI utilities, and operations with no dedicated tool.\nIMPORTANT: if mode is 'With confirmation' — FIRST ask the user with the exact command and reason, then call the tool.\nDangerous commands (rm -rf /, sudo rm, mkfs, etc.) are unconditionally blocked.\nSAFETY CAP: any command containing 'find' is automatically capped at 60s timeout by the tool itself, regardless of requested timeout — prevents unscoped 'find /' from hanging for hours scanning the whole filesystem. Prefer 'mdfind -name \"pattern\"' (Spotlight) for filename searches — instant results, no cap needed.",
                parameters: AIToolParameters(
                    properties: [
                        "command": AIToolProperty(type: "string", description: "Shell command to execute."),
                        "timeout": AIToolProperty(type: "string", description: "Timeout in seconds (default 300). Increase for long operations (build, npm install)."),
                        "project": AIToolProperty(type: "string", description: terminalProjectArgDesc)
                    ],
                    required: ["command"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "run_ssh",
                description: "Execute a command on a remote server via SSH.\nUse for remote server commands only. One command = one connection. No interactive input.\nIMPORTANT: stateless — do NOT rely on previous call state. Each call is a fresh connection.\nUse for: VPS diagnostics, reading logs, restarting services, checking server status.\nDangerous commands (rm -rf /, shutdown, etc.) are unconditionally blocked.\nIMPORTANT: uses key-only auth (BatchMode). If the target host requires a non-default private key (not id_rsa/id_ed25519 and not loaded in ssh-agent, no Host alias in ~/.ssh/config), you MUST pass identity_file pointing to it.\nSAFETY CAP: any command containing 'find' is automatically capped at 60s timeout by the tool itself, regardless of requested timeout.",
                parameters: AIToolParameters(
                    properties: [
                        "host": AIToolProperty(type: "string", description: "Remote host IP or domain (e.g. '185.23.34.97' or 'myserver.com')"),
                        "command": AIToolProperty(type: "string", description: "Shell command to execute on the remote host."),
                        "user": AIToolProperty(type: "string", description: "SSH username (default: current user). E.g. 'root'."),
                        "port": AIToolProperty(type: "string", description: "SSH port (default: 22)."),
                        "identity_file": AIToolProperty(type: "string", description: "Path to the SSH private key file (e.g. '~/.ssh/algotrading_server'). Required whenever the key is not a default identity and not registered in ssh-agent or ~/.ssh/config."),
                        "timeout": AIToolProperty(type: "string", description: "Connection timeout in seconds (default: 30).")
                    ],
                    required: ["host", "command"]
                )
            ))
        ]
    }

    func projectManagementTools() -> [AITool] {
        return [
            AITool(function: AIFunctionDefinition(
                name: "list_thread_projects",
                description: "Show the list of projects attached to the current thread. Use to check which projects are already added before add/remove operations.",
                parameters: AIToolParameters(properties: [:], required: [])
            ))
        ]
    }

    // MARK: - Dynamic description helpers

    func buildProjectDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Build the project via \(buildCommand(for: env)). Returns success or a list of compilation errors."
        }
        let lines = infos.map { "  • \($0.name): \(buildCommand(for: (projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment))" }.joined(separator: "\n")
        return "Build a project. Routes to the correct build tool per project:\n\(lines)\nReturns success or a list of compilation errors."
    }

    func runTestsDescription(for infos: [ActiveMemoryContext.ProjectInfo]) -> String {
        if infos.count == 1 {
            let env = (projectSettingsCache[infos[0].id] ?? ProjectSettings()).devEnvironment
            return "Run automated tests via \(testCommand(for: env)). Specify target/pattern or leave empty for all tests."
        }
        let lines = infos.map { "  • \($0.name): \(testCommand(for: (projectSettingsCache[$0.id] ?? ProjectSettings()).devEnvironment))" }.joined(separator: "\n")
        return "Run automated tests. Routes to the correct test runner per project:\n\(lines)\nSpecify target/pattern or leave empty for all tests."
    }

    private func buildCommand(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:   return "xcodebuild"
        case .nodejs:  return "npm run build"
        case .go:      return "go build ./..."
        case .rust:    return "cargo build"
        case .java:    return "mvn compile / gradle build"
        case .kotlin:  return "gradle build"
        case .flutter: return "flutter build"
        case .dotnet:  return "dotnet build"
        default:       return "the project's build tool"
        }
    }

    private func testCommand(for env: DevEnvironment) -> String {
        switch env {
        case .xcode:           return "xcodebuild test"
        case .nodejs:          return "npm test"
        case .python:          return "pytest"
        case .go:              return "go test"
        case .rust:            return "cargo test"
        case .java:            return "mvn test / gradle test"
        case .kotlin:          return "gradle test"
        case .flutter:         return "flutter test"
        case .reacttypescript: return "npm test / vitest"
        case .dotnet:          return "dotnet test"
        default:               return "the project's test runner"
        }
    }
}
