// GitTools.swift
//
// WHY THIS FILE:
// Implements git repository tools for the Chappie MCP server.
// Each tool runs git as a child process via Process() and returns output as a string.
//
// MULTI-PROJECT ROUTING:
// GitTools holds a projectPathMap [projectName → absolutePath].
// When a "project" arg is provided, the correct working directory is resolved from the map.
// When omitted — falls back to the single entry in the map (single-project threads).
// This mirrors BuildTools routing so git commands are always deterministic per project.
//
// WHY Process() INSTEAD OF libgit2 OR SwiftGit2:
// 1. No dependencies — no need to pull in C libraries.
// 2. Full compatibility with git hooks, .gitconfig, user's SSH keys.
// 3. git output is already formatted and readable by the AI agent.
//
// SECURITY:
// All arguments are passed as separate elements of [String] array,
// NOT through a shell string. This eliminates shell injection.
//
// CRITICAL — GIT PAGER:
// git diff, git log and other commands by default launch a pager (less),
// which waits for TTY input. In our case there is no TTY (headless subprocess),
// so the pager hangs forever and readDataToEndOfFile() never returns.
// SOLUTION: always pass GIT_PAGER=cat and GIT_TERMINAL_PROMPT=0 in environment.
//
// CRITICAL — SSH_AUTH_SOCK:
// git push over SSH (e.g. remote "internal") requires the ssh-agent socket.
// Without SSH_AUTH_SOCK forwarded into the child process environment, git cannot
// find the agent, authentication fails, and push returns an error.
// HTTPS remotes (e.g. GitHub "origin") are unaffected — they use ~/.gitconfig credentials.
// SOLUTION: forward SSH_AUTH_SOCK from the parent process environment if present.

import Foundation

// MARK: - GitPathError

/// Describes why a project path could not be resolved.
/// Used instead of String to satisfy Swift 6 Result<_, Error> constraint.
private enum GitPathError: Error {
    case projectNotFound(name: String, available: String)
    case projectNotFoundEmptyMap(name: String)
    case ambiguousProject(available: String)
    case emptyMap
}

// MARK: - GitTools

/// Git repository tools with multi-project routing support.
final class GitTools: Sendable {

    /// Default project path (workspace root). Used only when projectPathMap is empty (legacy).
    private let defaultProjectPath: String

    /// Map of project display name → absolute path on disk.
    /// Populated from argv[4] JSON: {"Chappie": "/path/to/Chappie", "Backend": "/path/to/Backend"}.
    private let projectPathMap: [String: String]

    init(projectPath: String, projectPathMap: [String: String] = [:]) {
        self.defaultProjectPath = projectPath
        self.projectPathMap = projectPathMap
    }

    // MARK: - Path Resolution

    /// Resolves the working directory for the given project name.
    ///
    /// Resolution order:
    /// 1. Exact match in projectPathMap by name.
    /// 2. Single-project fallback: if map has exactly one entry AND no name was provided — use it.
    /// 3. Error: multiple projects in map but name is missing or unknown.
    ///    Silent fallback would run git in the wrong project — explicit error is safer.
    private func resolvePath(for projectName: String?) -> Result<String, GitPathError> {
        // Exact match by name.
        if let name = projectName, !name.isEmpty {
            if let path = projectPathMap[name] {
                return .success(path)
            }
            // Name provided but not in map — tell AI exactly why.
            let available = projectPathMap.keys.sorted().joined(separator: ", ")
            if available.isEmpty {
                return .failure(.projectNotFoundEmptyMap(name: name))
            }
            return .failure(.projectNotFound(name: name, available: available))
        }

        // No name — safe only when exactly one project is attached.
        if projectPathMap.count == 1, let path = projectPathMap.values.first {
            return .success(path)
        }

        // No name + multiple projects — ambiguous, refuse to guess.
        if projectPathMap.count > 1 {
            let available = projectPathMap.keys.sorted().joined(separator: ", ")
            return .failure(.ambiguousProject(available: available))
        }

        // Map is empty — no projects resolved at all.
        return .failure(.emptyMap)
    }

    /// Converts a GitPathError into a human-readable ToolResult.failure message for the AI.
    private func pathErrorMessage(_ error: GitPathError) -> String {
        switch error {
        case .projectNotFound(let name, let available):
            return """
            Project '\(name)' not found in projectPathMap. \
            Available projects: \(available). \
            Check that '\(name)' is attached to this thread and its folder is accessible.
            """
        case .projectNotFoundEmptyMap(let name):
            return """
            Project '\(name)' not found: projectPathMap is empty. \
            The project folder bookmark may not have been resolved yet — \
            try switching threads or re-attaching the project.
            """
        case .ambiguousProject(let available):
            return """
            Parameter 'project' is required when multiple projects are attached. \
            Available projects: \(available). \
            Specify which project to run this git command in.
            """
        case .emptyMap:
            return """
            No projects found in projectPathMap. \
            Project folder bookmarks may not have been resolved yet — \
            try switching threads or re-attaching the project.
            """
        }
    }

    // MARK: - Public Tools

    func status(projectName: String?) async -> ToolResult {
        return await runGit(["status", "--short", "--branch"], projectName: projectName, cancellable: true)
    }

    func add(paths: String, projectName: String?) async -> ToolResult {
        let pathArgs = paths.components(separatedBy: " ").filter { !$0.isEmpty }
        return await runGit(["add"] + pathArgs, projectName: projectName)
    }

    func commit(message: String, projectName: String?) async -> ToolResult {
        return await runGit(["commit", "-m", message], projectName: projectName)
    }

    /// Pushes the current branch to remote.
    ///
    /// WHY SSH keys work here:
    /// HOME is passed in the environment so git finds ~/.gitconfig and ~/.ssh/id_ed25519.
    /// SSH_AUTH_SOCK is forwarded from the parent so the ssh-agent is reachable for SSH remotes.
    /// GIT_TERMINAL_PROMPT=0 prevents hanging if auth fails — returns error instead.
    func push(remote: String = "origin", branch: String = "main", projectName: String?) async -> ToolResult {
        return await runGit(["push", remote, branch], projectName: projectName)
    }

    func log(count: Int, projectName: String?) async -> ToolResult {
        return await runGit(["log", "--oneline", "--decorate", "--graph", "-\(count)"], projectName: projectName, cancellable: true)
    }

    func reset(projectName: String?) async -> ToolResult {
        return await runGit(["reset", "HEAD"], projectName: projectName)
    }

    /// Reverts one or more commits without auto-committing each one.
    ///
    /// WHY --no-commit ON EACH + SINGLE COMMIT AT THE END:
    /// Multiple --no-commit reverts are staged together, then one clean commit is made.
    /// This avoids polluting git log with one revert commit per hash.
    func revert(hashes: String, message: String, projectName: String?) async -> ToolResult {
        let hashList = hashes.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !hashList.isEmpty else {
            return .failure("Argument 'hashes' is required for git_revert")
        }

        let revertResult = await runGit(["revert", "--no-commit"] + hashList, projectName: projectName)

        // If revert failed (e.g. merge conflict) — return immediately, do NOT commit.
        if revertResult.error != nil { return revertResult }

        return await runGit(["commit", "-m", message], projectName: projectName)
    }

    /// Restores specific files from a given commit or branch.
    ///
    /// The "--" separator is critical: tells git that what follows are paths, not branch names.
    func checkout(ref: String, paths: String, projectName: String?) async -> ToolResult {
        guard !ref.isEmpty else {
            return .failure("Argument 'ref' is required for git_checkout (e.g. HEAD~1, abc123, main)")
        }
        let pathList = paths.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !pathList.isEmpty else {
            return .failure("Argument 'paths' is required for git_checkout (space-separated file paths)")
        }
        return await runGit(["checkout", ref, "--"] + pathList, projectName: projectName)
    }

    // MARK: - Private Process Runner

    /// `cancellable` is false by default: a git command that changes the repository (add, commit,
    /// push, reset, revert, checkout) must not be killed halfway, because that can leave
    /// index.lock or a half-applied state. Only read-only commands opt in.
    private func runGit(_ args: [String], projectName: String?, cancellable: Bool = false) async -> ToolResult {
        // Resolve path first — return a clear error if project is unknown or map is empty.
        let workingDir: String
        switch resolvePath(for: projectName) {
        case .failure(let error):
            return .failure(pathErrorMessage(error))
        case .success(let path):
            workingDir = path
        }

        let label = projectName.map { "[\($0)]" } ?? ""
        print("[ChappieMCP] 🔧 git\(label) \(args.joined(separator: " ")) @ \(workingDir)")

        // Build environment:
        // HOME            — git needs it to find ~/.gitconfig and ~/.ssh/id_ed25519
        // PATH            — standard tool locations
        // GIT_PAGER=cat   — disables pager (less/more); without this git log/diff hang headless
        // GIT_TERMINAL_PROMPT=0 — prevents git from blocking on TTY password prompt
        // SSH_AUTH_SOCK   — forwarded from parent so ssh-agent is reachable for SSH remotes
        //                   (e.g. remote "internal"); without this git push over SSH fails auth
        // NOTE: GIT_CONFIG_NOSYSTEM removed — it blocked SSH credential helpers on some setups
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "en_US.UTF-8",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "TERM": "dumb"
        ]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            env["SSH_AUTH_SOCK"] = sshAuthSock
        }

        // ProcessRunner reads both pipes in parallel; the old loop read stderr only after exit,
        // which deadlocks when git writes more than a pipe buffer (~64 KB) to stderr.
        let run = await ProcessRunner.run(
            executable: "/usr/bin/git",
            args: args,
            workingDirectory: workingDir,
            environment: env,
            cancellable: cancellable
        )

        if let launchError = run.launchError {
            return .failure("Failed to launch git: \(launchError)")
        }
        if run.stopReason == .cancelled {
            return .failure("🛑 git \(args.joined(separator: " ")) was cancelled.")
        }

        let stdout = run.stdoutText
        if run.exitCode == 0 {
            let output = stdout.isEmpty ? "(no output)" : stdout
            return .success("git \(args.joined(separator: " ")):\n\(output)")
        } else {
            let stderr = run.stderrText
            let errorOutput = stderr.isEmpty ? stdout : stderr
            return .failure("git \(args.joined(separator: " ")) exited with code \(run.exitCode):\n\(errorOutput)")
        }
    }
}
