// ToolDefinitions+TerminalTools.swift
// ChappieCore
//
// Terminal and project management tool definitions.

import Foundation

extension ToolExecutionService {

    func terminalTools(allInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let terminalProjectArgDesc = terminalProjectArgDescription(for: allInfos)

        return [
            AITool(function: AIFunctionDefinition(
                name: "run_terminal",
                description: "Execute a command in the terminal in the project's working directory.\nThe session is persistent — cd commands are remembered between calls.\nONLY WHEN NO SPECIALIZED TOOL EXISTS: use list_files/read_file for file navigation; git_* for version control.\nBuilds and tests are ordinary commands: run them here (e.g. xcodebuild, npm test, pytest, cargo test) and redirect long output to a file (> /tmp/build.log 2>&1), then grep it for 'error:' and the result line.\nUse run_terminal for: running scripts, installing dependencies, CLI utilities, and operations with no dedicated tool.\nDangerous commands (rm -rf /, sudo rm, mkfs, etc.) are unconditionally blocked.\nSAFETY CAP: any command containing 'find' is automatically capped at 60s timeout by the tool itself, regardless of requested timeout — prevents unscoped 'find /' from hanging for hours scanning the whole filesystem. Prefer 'mdfind -name \"pattern\"' (Spotlight) for filename searches — instant results, no cap needed.",
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
}
