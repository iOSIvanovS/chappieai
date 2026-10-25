// CommandSafety.swift
// ChappieCore
//
// WHY THIS FILE:
// A safety net against a model's catastrophic MISTAKES in run_terminal / run_ssh (a wrong `rm`,
// a stray `reboot`). It replaces a substring blocklist that blocked harmless commands
// (`rm -rf /tmp/x` contains "rm -rf /") and was trivially bypassed (`rm -fr /`).
//
// HOW: the command line is lexed into real commands (CommandTokenizer); wrappers (sudo, env, ...)
// are peeled off; then rules look at the command NAME and its normalized flags/targets.
//
// HONEST LIMIT: this is NOT a security boundary. Variables, `$(...)` inside quotes, scripts written
// to disk and run later, and any other indirection get through. The real guard is
// TerminalAccessLevel (off / confirm / full). Do not extend this list to "close" bypasses.

import Foundation

public enum CommandSafety {

    /// Returns a human-readable reason when the command is a known catastrophic operation, else nil.
    public static func violation(in command: String) -> String? {
        analyze(command, depth: 0)
    }

    // MARK: - Analysis

    private static let maxDepth = 4

    private static func analyze(_ script: String, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        if script.filter({ !$0.isWhitespace }).contains(":(){:|:&};:") { return "fork bomb" }

        let body = CommandTokenizer.stripHeredocBodies(script)
        for pipeline in CommandTokenizer.pipelines(from: body) {
            if let reason = check(pipeline, depth: depth) { return reason }
        }
        return nil
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    private static let downloaders: Set<String> = ["curl", "wget", "fetch"]

    private static func check(_ pipeline: ShellPipeline, depth: Int) -> String? {
        var downloadSeen = false
        for stage in pipeline {
            if let reason = rawDiskRedirect(in: stage) { return reason }
            guard let cmd = ParsedCommand(stage) else { continue }

            if downloadSeen, shells.contains(cmd.name), readsStdin(cmd) {
                return "piping a download into a shell"
            }
            if downloaders.contains(cmd.name) { downloadSeen = true }
            if let reason = check(cmd, depth: depth) { return reason }
        }
        return nil
    }

    private static func check(_ cmd: ParsedCommand, depth: Int) -> String? {
        switch cmd.name {
        case "rm":
            if let t = recursiveTarget(cmd) { return "rm -r on '\(t)'" }
        case "chmod", "chown", "chgrp":
            if let t = recursiveTarget(cmd) { return "\(cmd.name) -R on '\(t)'" }
        case "dd":
            if cmd.args.contains(where: { isRawDeviceOutput($0.text) }) { return "dd writing to a disk device" }
        case "diskutil":
            if let reason = diskutilViolation(cmd) { return reason }
        case "shutdown", "reboot", "halt", "poweroff":
            return "\(cmd.name) command"
        case "eval":
            return analyze(cmd.args.map(\.text).joined(separator: " "), depth: depth + 1)
        default:
            if cmd.name == "mkfs" || cmd.name.hasPrefix("mkfs.") || cmd.name.hasPrefix("newfs") {
                return "\(cmd.name) (formats a filesystem)"
            }
            if shells.contains(cmd.name), let script = inlineScript(cmd) {
                return analyze(script, depth: depth + 1)
            }
        }
        return nil
    }

    // MARK: - Rules

    /// Targets that make a recursive operation catastrophic: the filesystem root, the home folder,
    /// and top-level system folders. Compared after normalizing slashes and trailing globs.
    private static let catastrophicTargets: Set<String> = [
        "", "~", "$HOME", "${HOME}",
        "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private",
        "/usr", "/etc", "/var", "/bin", "/sbin", "/opt", "/dev", "/cores",
    ]

    private static func isCatastrophic(_ raw: String) -> Bool {
        var p = raw
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        var changed = true
        while changed {
            changed = false
            for suffix in ["/*", "/.*", "/.", "/"] where p.hasSuffix(suffix) {
                p.removeLast(suffix.count)
                changed = true
                break
            }
        }
        return catastrophicTargets.contains(p) || p == NSHomeDirectory()
    }

    /// For rm/chmod/chown: the first catastrophic target when the operation is recursive.
    private static func recursiveTarget(_ cmd: ParsedCommand) -> String? {
        var recursive = false
        var targets: [String] = []
        var optionsEnded = false
        for arg in cmd.args {
            let t = arg.text
            if !optionsEnded, t == "--" { optionsEnded = true; continue }
            if !optionsEnded, t.hasPrefix("-"), t.count > 1 {
                if t == "--recursive" { recursive = true }
                else if !t.hasPrefix("--"), t.contains("r") || t.contains("R") { recursive = true }
                continue
            }
            // chmod's mode argument ("777", "u+x") is not a target; only path-like words can match.
            targets.append(t)
        }
        guard recursive else { return nil }
        return targets.first(where: isCatastrophic)
    }

    private static let safeDevices: Set<String> = ["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/tty"]

    private static func isRawDeviceOutput(_ arg: String) -> Bool {
        guard arg.hasPrefix("of=/dev/") else { return false }
        return !safeDevices.contains(String(arg.dropFirst(3)))
    }

    private static func diskutilViolation(_ cmd: ParsedCommand) -> String? {
        let words = cmd.args.map { $0.text.lowercased() }.filter { !$0.hasPrefix("-") }
        guard let sub = words.first else { return nil }
        let destructive: Set<String> = [
            "erasedisk", "erasevolume", "partitiondisk", "secureerase", "zerodisk", "randomdisk", "reformat",
        ]
        if destructive.contains(sub) { return "diskutil \(sub)" }
        if sub == "apfs", words.count > 1, words[1].hasPrefix("delete") { return "diskutil apfs \(words[1])" }
        return nil
    }

    private static let rawDiskPrefixes = ["/dev/disk", "/dev/rdisk", "/dev/sd", "/dev/nvme"]

    /// `> /dev/disk2`, `>/dev/rdisk1`, `2>/dev/sda`: a redirect onto a raw disk device.
    private static func rawDiskRedirect(in stage: [ShellToken]) -> String? {
        for (i, tok) in stage.enumerated() where !tok.quoted {
            guard let gt = tok.text.firstIndex(of: ">") else { continue }
            let prefix = tok.text[..<gt]
            guard prefix.allSatisfy({ $0.isNumber || $0 == "&" }) else { continue }
            var target = String(tok.text[tok.text.index(after: gt)...]).trimmingCharacters(in: CharacterSet(charactersIn: ">|"))
            if target.isEmpty, i + 1 < stage.count { target = stage[i + 1].text }
            if rawDiskPrefixes.contains(where: target.hasPrefix) { return "redirect onto a raw disk device" }
        }
        return nil
    }

    /// A shell with no script argument reads its program from stdin (the `curl ... | sh` case).
    private static func readsStdin(_ cmd: ParsedCommand) -> Bool {
        if cmd.args.contains(where: { $0.text == "-s" }) { return true }
        return !cmd.args.contains { !$0.text.hasPrefix("-") }
    }

    /// The script text of `bash -c '...'` / `sh -lc "..."`.
    private static func inlineScript(_ cmd: ParsedCommand) -> String? {
        guard let flag = cmd.args.firstIndex(where: {
            $0.text.hasPrefix("-") && !$0.text.hasPrefix("--") && $0.text.contains("c")
        }) else { return nil }
        let rest = cmd.args[(flag + 1)...].first(where: { !$0.text.hasPrefix("-") })
        return rest?.text
    }
}

// MARK: - ParsedCommand

/// A stage reduced to its real command: leading keywords, VAR=value assignments and wrappers
/// (sudo, env, nohup, ...) are removed so rules see `rm`, not `sudo`.
struct ParsedCommand {
    let name: String
    let args: [ShellToken]

    private static let keywords: Set<String> = ["if", "then", "else", "elif", "do", "while", "until", "!", "{", "}", "fi", "done"]

    /// Wrapper -> options that consume the following word.
    private static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-S", "-C"],
        "command": [], "builtin": [], "nohup": [], "time": [],
        "exec": ["-a"],
        "nice": ["-n"],
        "timeout": ["-s", "-k"],
        "xargs": ["-I", "-n", "-P", "-L", "-s", "-d", "-E"],
    ]

    init?(_ stage: [ShellToken]) {
        var rest = stage[...]
        while let first = rest.first {
            // `FOO="a b" rm ...` has a quoted value but is still an assignment prefix.
            if (!first.quoted && Self.keywords.contains(first.text)) || Self.isAssignment(first.text) {
                rest = rest.dropFirst()
                continue
            }
            let name = (first.text as NSString).lastPathComponent.lowercased()
            guard let valueOptions = Self.wrappers[name] else {
                self.name = name
                self.args = Array(rest.dropFirst())
                return
            }
            rest = rest.dropFirst()
            while let opt = rest.first, opt.text.hasPrefix("-") || Self.isAssignment(opt.text) {
                rest = rest.dropFirst()
                if valueOptions.contains(opt.text) { rest = rest.dropFirst() }
            }
            if name == "timeout" { rest = rest.dropFirst() }
        }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return false }
        let key = word[..<eq]
        guard let f = key.first, f.isLetter || f == "_" else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
