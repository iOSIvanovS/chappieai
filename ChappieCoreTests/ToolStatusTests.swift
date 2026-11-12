// ToolStatusTests.swift
// ChappieCoreTests
//
// The availability label that opens each tool description, and the shared ToolBlock wording.

import Testing
import Foundation
@testable import ChappieCore

private func executor(
    git: GitAccessLevel = .full,
    env: DevEnvironment = .xcode,
    programming: Bool = true
) -> ProjectSettings {
    ProjectSettings(
        agentRole: .executor, isProgrammingProject: programming, devEnvironment: env,
        gitAccess: git
    )
}

private let advisor = ProjectSettings(agentRole: .advisor, isProgrammingProject: true, devEnvironment: .xcode)

private func status(
    _ tool: String,
    _ projects: [(String, ProjectSettings)],
    terminal: Bool = false,
    curl: Bool = false
) -> ToolStatus {
    ToolPolicy.status(
        of: tool,
        projects: projects.map { ToolStatusProject(name: $0.0, settings: $0.1) },
        terminalEnabled: terminal,
        curlEnabled: curl
    )
}

@Suite("ToolStatus — labels")
struct ToolStatusLabelTests {

    @Test("Always-on tools say so, with or without projects")
    func alwaysOn() {
        #expect(status("memorize", []).label == "[ALWAYS AVAILABLE]")
        #expect(status("web_fetch", [("A", advisor)]).isAvailable)
    }

    @Test("git_diff is FORBIDDEN with the reason and an alternative")
    func forbidden() {
        let s = status("git_diff", [("A", executor())], terminal: true)
        #expect(!s.isAvailable)
        #expect(s.label.hasPrefix("[FORBIDDEN"))
        #expect(s.label.contains("costs real money"))
        #expect(s.label.contains("Instead: git_status"))
    }

    @Test("Terminal: off → how to enable; on → available")
    func terminal() {
        let off = status("run_terminal", [], terminal: false)
        #expect(!off.isAvailable)
        #expect(off.label.contains("thread settings → Terminal"))
        #expect(status("run_terminal", [], terminal: true).isAvailable)
        #expect(status("run_ssh", [], terminal: true).label.contains("automatically"))
    }

    @Test("Project tool: every project listed on the side where it belongs, with its reason and fix")
    func mixedProjects() {
        let s = status("write_file", [("Chappie", executor()), ("Landing", advisor), ("Docs", advisor)])
        #expect(s.isAvailable)
        #expect(s.label.contains("AVAILABLE in: Chappie"))
        // Identical reasons are merged into one clause.
        #expect(s.label.contains("UNAVAILABLE in: Landing, Docs — the project's role is ADVISOR (read-only). To enable: project settings → role → EXECUTOR"))
    }

    @Test("Read tools are available to an ADVISOR")
    func readForAdvisor() {
        let s = status("read_file", [("A", advisor)])
        #expect(s.isAvailable)
        #expect(!s.label.contains("UNAVAILABLE"))
    }

    @Test("No project attached: unavailable, with the way to attach one")
    func noProject() {
        let s = status("read_file", [])
        #expect(!s.isAvailable)
        #expect(s.label.contains("no project is attached"))
        #expect(s.label.contains("attach a project"))
    }

    @Test("git at a low level names the level and what it allows")
    func gitLevel() {
        let s = status("git_commit", [("A", executor(git: .statusOnly))])
        #expect(!s.isAvailable)
        #expect(s.label.contains("'statusOnly'"))
        #expect(s.label.contains("git_log, git_status"))
        #expect(s.label.contains("Git → raise"))
    }

    @Test("git on a non-programming project asks for the flag")
    func gitNeedsProgramming() {
        let s = status("git_status", [("Docs", executor(programming: false))])
        #expect(!s.isAvailable)
        #expect(s.label.contains("Programming project"))
    }

    @Test("loc_*: needs Xcode; the reason says which environment the project has")
    func locNeedsXcode() {
        let s = status("loc_info", [("Py", executor(env: .python))])
        #expect(!s.isAvailable)
        #expect(s.label.contains("Python"))
        #expect(status("loc_info", [("X", advisor)]).isAvailable)
        #expect(!status("loc_create", [("X", advisor)]).isAvailable)
    }

    @Test("Curl: off switch and ADVISOR-only are both reported")
    func curlBoth() {
        let s = status("curl_request", [("A", advisor)], curl: false)
        #expect(!s.isAvailable)
        #expect(s.label.contains("Curl-Chappie is off"))
        #expect(s.label.contains("ADVISOR"))
    }

    @Test("Curl: switch on, EXECUTOR present → available")
    func curlOk() {
        let s = status("curl_scenario_run", [("A", advisor), ("B", executor())], curl: true)
        #expect(s.isAvailable)
        #expect(s.label.contains("AVAILABLE in: B"))
    }

    @Test("Unknown tool is unavailable")
    func unknown() {
        #expect(!status("nope", [("A", executor())]).isAvailable)
    }
}

@Suite("ToolBlock — one wording for refusals and statuses")
struct ToolBlockTests {

    @Test("Call-time refusal is built from the same block as the status")
    func sameWording() {
        let block = ToolPolicy.evaluate(tool: "write_file", project: advisor, terminalEnabled: false, curlEnabled: false)
        #expect(block != nil)
        let denied = ToolPolicy.decide(tool: "write_file", project: advisor, terminalEnabled: false)
        guard case .denied(let text) = denied, let block else { Issue.record("expected denial"); return }
        #expect(text == block.message(tool: "write_file"))
        #expect(text.contains("ADVISOR"))
        #expect(status("write_file", [("A", advisor)]).label.contains(block.summary))
    }

    @Test("Permanent blocks do not say 'To enable'")
    func permanent() {
        let block = ToolPolicy.evaluate(tool: "git_diff", project: nil, terminalEnabled: true, curlEnabled: true)
        #expect(block?.permanent == true)
        #expect(block?.summary.contains("To enable") == false)
    }
}
