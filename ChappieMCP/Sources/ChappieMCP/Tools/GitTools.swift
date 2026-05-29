// GitTools.swift
//
// WHY THIS FILE:
// Implements git repository tools for the Chappie project.
// Each tool runs git as a child process via Process()
// and returns its output as a string.
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
// GIT_PAGER=cat — disables pager, output goes directly to stdout.
// GIT_TERMINAL_PROMPT=0 — prevents git from requesting password via TTY.

import Foundation

/// Git repository tools.
final class GitTools: Sendable {
    /// Path to project root (where .git lives).
    private let projectPath: String

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Public Tools

    /// git status — shows modified, new and deleted files.
    func status() async -> ToolResult {
        return await runGit(["status", "--short", "--branch"])
    }

    /// git diff — shows content of changes.
    ///
    /// IMPORTANT: git diff without GIT_PAGER=cat hangs forever
    /// in headless process because it launches less and waits for TTY.
    /// We solve this via GIT_PAGER=cat environment variable in runProcess.
    ///
    /// - Parameter staged: if true — shows staged changes (after git add),
    ///   if false — unstaged (working directory vs index).
    func diff(staged: Bool) async -> ToolResult {
        var args = ["diff"]
        if staged {
            args.append("--staged")
        }
        // --stat: summary of changed files
        // -p: full patch (line-by-line changes)
        // --no-color: no ANSI color codes (not needed by AI, pollutes output)
        args.append(contentsOf: ["--stat", "-p", "--no-color"])
        return await runGit(args)
    }

    /// git add — adds files to staging area.
    /// - Parameter paths: space-separated paths, or "." for all files.
    func add(paths: String) async -> ToolResult {
        // Split paths string into separate arguments
        let pathArgs = paths.components(separatedBy: " ").filter { !$0.isEmpty }
        return await runGit(["add"] + pathArgs)
    }

    /// git commit — creates a commit with the given message.
    /// - Parameter message: commit message text.
    func commit(message: String) async -> ToolResult {
        return await runGit(["commit", "-m", message])
    }

    /// git log — shows last N commits.
    /// - Parameter count: number of commits.
    func log(count: Int) async -> ToolResult {
        // --oneline: compact format (hash + message)
        // --decorate: shows tags and branches
        // --graph: ASCII tree for branch visualization
        return await runGit(["log", "--oneline", "--decorate", "--graph", "-\(count)"])
    }

    /// git reset HEAD — removes all files from staging area (unstage all).
    func reset() async -> ToolResult {
        return await runGit(["reset", "HEAD"])
    }

    /// git revert — reverts one or more commits without auto-committing each one.
    ///
    /// WHY --no-commit ON EACH + SINGLE COMMIT AT THE END:
    /// `git revert <hash1> <hash2>` without --no-commit creates a separate revert commit
    /// for each hash, polluting git log. With --no-commit all reverts are staged together
    /// and we make one clean commit with a descriptive message.
    ///
    /// - Parameters:
    ///   - hashes: space-separated commit hashes to revert (e.g. "abc123 def456").
    ///   - message: commit message for the combined revert commit.
    func revert(hashes: String, message: String) async -> ToolResult {
        let hashList = hashes.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !hashList.isEmpty else {
            return .failure("Argument 'hashes' is required for git_revert")
        }

        // Step 1: revert all hashes without auto-committing
        // This stages the inverse of each commit into the index
        let revertArgs = ["revert", "--no-commit"] + hashList
        let revertResult = await runGit(revertArgs)

        // If revert failed (e.g. merge conflict) — return error immediately,
        // do NOT commit. User must resolve conflicts manually.
        if revertResult.error != nil {
            return revertResult
        }

        // Step 2: commit all staged reverts as a single clean commit
        return await runGit(["commit", "-m", message])
    }

    /// git checkout — restores specific files from a given commit or branch.
    ///
    /// WHY THIS TOOL:
    /// Allows surgical rollback of individual files without touching the rest
    /// of the working tree. Useful when only one file was broken by a bad commit.
    ///
    /// EXAMPLES:
    ///   ref="HEAD~1", paths="Chappie/Views/Chat/MessageBubbleView.swift"
    ///   → restores that file to the state one commit ago
    ///
    ///   ref="abc123", paths="Chappie/Views/Chat/MessageBubbleView.swift Chappie/ContentView.swift"
    ///   → restores both files to the state at commit abc123
    ///
    /// - Parameters:
    ///   - ref: commit hash, branch name, or relative ref like HEAD~1.
    ///   - paths: space-separated file paths to restore.
    func checkout(ref: String, paths: String) async -> ToolResult {
        guard !ref.isEmpty else {
            return .failure("Argument 'ref' is required for git_checkout (e.g. HEAD~1, abc123, main)")
        }
        let pathList = paths.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !pathList.isEmpty else {
            return .failure("Argument 'paths' is required for git_checkout (space-separated file paths)")
        }

        // git checkout <ref> -- <path1> <path2> ...
        // The "--" separator is critical: it tells git that what follows are paths,
        // not branch names. Without it, git may misinterpret a path as a ref.
        let args = ["checkout", ref, "--"] + pathList
        return await runGit(args)
    }

    // MARK: - Private Process Runner

    /// Runs git with the given arguments in the project directory.
    ///
    /// Why async: Process() is a synchronous API, but we wrap it in
    /// withCheckedContinuation to avoid blocking the cooperative thread pool.
    ///
    /// - Parameter args: git arguments (without "git" itself).
    /// - Returns: ToolResult with stdout or stderr on error.
    private func runGit(_ args: [String]) async -> ToolResult {
        return await withCheckedContinuation { continuation in
            // Run on a separate thread to avoid blocking Swift Concurrency
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/usr/bin/git",
                    args: args,
                    workingDirectory: self.projectPath
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Synchronously runs a process and returns the result.
    ///
    /// Why synchronous: Process.waitUntilExit() is a blocking call,
    /// so we call it from DispatchQueue, not directly from async context.
    ///
    /// KEY DECISION — reading stdout via availableData loop:
    /// readDataToEndOfFile() blocks until EOF on the pipe, which may not happen
    /// if git launched a child process (pager). Despite GIT_PAGER=cat,
    /// we read data via availableData loop for reliability.
    private func runProcess(executable: String, args: [String], workingDirectory: String) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Capture stdout and stderr into Pipes
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // CRITICAL: environment for git in headless mode.
        //
        // GIT_PAGER=cat — disables pager (less/more/delta).
        //   Without this, git diff/log hang forever waiting for TTY.
        //
        // GIT_TERMINAL_PROMPT=0 — prevents git from requesting password via TTY.
        //   Without this, git clone/fetch may hang waiting for credential input.
        //
        // GIT_CONFIG_NOSYSTEM=1 — ignores /etc/gitconfig.
        //   Prevents unexpected settings from system-level git config.
        //
        // HOME — git needs it to find ~/.gitconfig and ~/.ssh/
        //
        // TERM=dumb — tells programs the terminal is "dumb" (no colors, no TTY).
        //   Extra protection against attempts to use escape codes.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "en_US.UTF-8",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "TERM": "dumb"
        ]

        do {
            try process.run()
        } catch {
            return .failure("Failed to launch git: \(error.localizedDescription)")
        }

        // Read stdout and stderr via availableData loop.
        //
        // WHY NOT readDataToEndOfFile():
        // readDataToEndOfFile() blocks until EOF on the pipe.
        // If git for some reason doesn't close the pipe (bug, pager process),
        // we hang forever. Reading via availableData + waitUntilExit is more robust.
        //
        // WHY availableData IN A LOOP:
        // availableData returns whatever is currently in the pipe buffer.
        // We collect data in a loop until the process finishes.
        var stdoutData = Data()
        var stderrData = Data()

        // Read data in a loop while the process is running
        while process.isRunning {
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if !chunk.isEmpty {
                stdoutData.append(chunk)
            }
            // Small pause to avoid spinning CPU in a tight loop
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Read remaining data after process finishes
        // (data may have accumulated in the pipe buffer after the last loop iteration)
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutData.append(remainingStdout)
        stderrData.append(remainingStderr)

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        // git returns exit code 0 on success
        if process.terminationStatus == 0 {
            let output = stdout.isEmpty ? "(no output)" : stdout
            return .success("git \(args.joined(separator: " ")):\n\(output)")
        } else {
            // On error return stderr (it usually contains the problem description)
            let errorOutput = stderr.isEmpty ? stdout : stderr
            return .failure("git \(args.joined(separator: " ")) exited with code \(process.terminationStatus):\n\(errorOutput)")
        }
    }
}
