// CommandTokenizer.swift
// ChappieCore
//
// WHY THIS FILE:
// CommandSafety needs to look at the real commands inside a shell line, not at substrings.
// This is a small lexer for the subset of shell syntax that matters for that: quotes, escapes,
// comments, separators (; && || & newline, subshell parentheses, backticks), pipes and heredocs.
// It is NOT a full shell parser; unknown constructs degrade to "ordinary words".

import Foundation

/// One word of a command line. `quoted` is true when any part of it was quoted, which matters for
/// operators: a quoted ">" is text, not a redirect.
struct ShellToken: Equatable {
    let text: String
    let quoted: Bool
}

/// Stages of a pipeline (split by a single `|`); each stage is the list of its words.
typealias ShellPipeline = [[ShellToken]]

enum CommandTokenizer {

    /// Splits a script into pipelines. Separators other than `|` start a new pipeline.
    static func pipelines(from script: String) -> [ShellPipeline] {
        let chars = Array(script)
        var pipelines: [ShellPipeline] = []
        var stages: [[ShellToken]] = []
        var words: [ShellToken] = []
        var current = ""
        var inWord = false
        var wordQuoted = false
        var quote: Character?

        func endWord() {
            guard inWord else { return }
            words.append(ShellToken(text: current, quoted: wordQuoted))
            current = ""
            inWord = false
            wordQuoted = false
        }
        func endStage() {
            endWord()
            if !words.isEmpty { stages.append(words); words = [] }
        }
        func endPipeline() {
            endStage()
            if !stages.isEmpty { pipelines.append(stages); stages = [] }
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if let q = quote {
                if c == q {
                    quote = nil
                } else if q == "\"", c == "\\", let n = next, "\"\\$`".contains(n) {
                    current.append(n)
                    i += 1
                } else {
                    current.append(c)
                }
                i += 1
                continue
            }

            switch c {
            case "'", "\"":
                quote = c
                inWord = true
                wordQuoted = true
            case "\\":
                if let n = next {
                    // Backslash-newline is a line continuation and produces nothing.
                    if n != "\n" { current.append(n); inWord = true }
                    i += 1
                }
            case " ", "\t":
                endWord()
            case "\n", ";", "(", ")", "`":
                endPipeline()
            case "|":
                endStage()
                if next == "|" { i += 1; endPipeline() }
            case "&":
                // "2>&1" and "&>" are redirections, not a background operator.
                if i > 0, chars[i - 1] == ">" || chars[i - 1] == "<" || next == ">" {
                    current.append(c)
                    inWord = true
                } else {
                    endPipeline()
                    if next == "&" { i += 1 }
                }
            case "#":
                if inWord {
                    current.append(c)
                } else {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
            default:
                current.append(c)
                inWord = true
            }
            i += 1
        }
        endPipeline()
        return pipelines
    }

    // MARK: - Heredocs

    private static let heredocRegex = try? NSRegularExpression(
        pattern: #"(?<!<)<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1"#
    )
    private static let shellWordRegex = try? NSRegularExpression(pattern: #"\b(ba|z|da|k)?sh\b"#)

    /// Removes heredoc bodies: they are data (a commit message, a file being written), and treating
    /// their lines as commands would flag `cat <<EOF` text. Exception: when the heredoc feeds a
    /// shell (`bash <<EOF`), the body IS executed, so it stays.
    static func stripHeredocBodies(_ script: String) -> String {
        guard let heredoc = heredocRegex else { return script }
        var out: [String] = []
        var terminator: String?
        var keepBody = false

        for sub in script.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sub)
            if let end = terminator {
                if line.trimmingCharacters(in: .whitespaces) == end {
                    terminator = nil
                } else if keepBody {
                    out.append(line)
                }
                continue
            }
            out.append(line)
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            guard let m = heredoc.firstMatch(in: line, range: full) else { continue }
            terminator = ns.substring(with: m.range(at: 2))
            let head = ns.substring(to: m.range.location)
            keepBody = shellWordRegex?.firstMatch(
                in: head, range: NSRange(location: 0, length: (head as NSString).length)
            ) != nil
        }
        return out.joined(separator: "\n")
    }
}
