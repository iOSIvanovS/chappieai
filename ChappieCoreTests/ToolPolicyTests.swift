// ToolPolicyTests.swift
// ChappieCoreTests
//
// The single access-control table: deny by default, per-project rights, one decision function
// for both "what the model is shown" and "what is allowed to run".

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Fixtures

private func xcodeExecutor(
    git: GitAccessLevel = .full,
    tests: TestsAccessLevel = .run,
    build: Bool = true
) -> ProjectSettings {
    ProjectSettings(
        agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode,
        gitAccess: git, testsAccess: tests, buildEnabled: build
    )
}

private let xcodeAdvisor = ProjectSettings(
    agentRole: .advisor, isProgrammingProject: true, devEnvironment: .xcode
)

private func decide(
    _ tool: String,
    _ project: ProjectSettings?,
    terminal: TerminalAccessLevel = .none
) -> ToolDecision {
    ToolPolicy.decide(tool: tool, project: project, terminalAccess: terminal)
}

private struct Rig {
    let service: ToolExecutionService
    let projects: [ActiveMemoryContext.ProjectInfo]

    /// One service wired with the given projects (name → settings) and thread terminal level.
    init(
        _ spec: [(String, ProjectSettings)],
        terminal: TerminalAccessLevel = .none,
        curl: Bool = false
    ) async {
        let dir = FileManager.default.temporaryDirectory
        service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaceURL: dir),
            memoryManager: MemoryManager(workspaceURL: dir),
            socketPath: "/tmp/chappie-policy-tests-nonexistent.sock"
        )
        projects = spec.map { ActiveMemoryContext.ProjectInfo(id: UUID(), name: $0.0) }
        var settings: [UUID: ProjectSettings] = [:]
        for (info, entry) in zip(projects, spec) { settings[info.id] = entry.1 }
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: projects, threadTerminalAccess: terminal,
                                         curlEnabled: curl,
                                         curlHosts: [CurlHost(name: "Dev", origin: "https://dev.x.ru", permission: .readOnly)]),
            settings: settings
        )
    }

    func names() async -> Set<String> {
        Set(await service.availableTools.map(\.function.name))
    }

    func authorize(_ tool: String, _ json: String) async -> ToolAuthorization {
        await service.authorize(toolName: tool, argsData: Data(json.utf8))
    }
}

private func isAllowed(_ auth: ToolAuthorization) -> Bool {
    if case .allowed = auth { return true }
    return false
}

private func denial(_ auth: ToolAuthorization) -> String {
    if case .denied(let message) = auth { return message }
    return ""
}

private func description(of tool: String, in tools: [AITool]) -> String {
    tools.first { $0.function.name == tool }?.function.description ?? "<missing \(tool)>"
}

/// A closed tool's status line starts with UNAVAILABLE or FORBIDDEN (a partly open one starts with AVAILABLE).
private func isClosed(_ tool: AITool) -> Bool {
    let d = tool.function.description
    return d.hasPrefix("[UNAVAILABLE") || d.hasPrefix("[FORBIDDEN")
}

// MARK: - Table

@Suite("ToolPolicy — deny by default")
struct ToolPolicyTableTests {

    @Test("An unknown tool is denied, whatever the rights")
    func unknownToolDenied() {
        #expect(!decide("some_future_tool", xcodeExecutor(), terminal: .auto).isAllowed)
        #expect(!decide("attach_file", xcodeExecutor()).isAllowed)
    }

    @Test("git_diff is denied everywhere")
    func gitDiffDenied() {
        guard case .denied(let why) = decide("git_diff", xcodeExecutor(), terminal: .auto) else {
            Issue.record("git_diff must be denied"); return
        }
        #expect(why.contains("FORBIDDEN"))
    }

    @Test("Always-on tools need no project")
    func alwaysOn() {
        for tool in ["web_fetch", "memorize", "recall", "search_memory", "delete_memory",
                     "list_thread_projects", "fetch_attachment", "send_attachment"] {
            #expect(decide(tool, nil).isAllowed, "\(tool)")
        }
    }

    @Test("Project tools are denied when no project could be selected")
    func projectToolWithoutProject() {
        #expect(!decide("read_file", nil).isAllowed)
        #expect(!decide("write_file", nil).isAllowed)
        #expect(!decide("loc_info", nil).isAllowed)
    }

    @Test("Every classified tool except git_diff and the terminal pair needs a known capability")
    func tableIsClosed() {
        for tool in ToolPolicy.knownTools {
            #expect(ToolPolicy.capability(of: tool) != nil)
        }
        #expect(ToolPolicy.localizationTools.count == 15)
    }
}

// MARK: - Roles

@Suite("ToolPolicy — roles")
struct ToolPolicyRoleTests {

    private let reads = ["list_files", "read_file", "get_file_info", "view_image",
                         "read_document", "search_in_file", "search_in_project"]
    private let writes = ["write_file", "patch_file", "delete_file", "move_file", "rename_file", "write_document"]
    private let locReads = ["loc_info", "loc_key_check", "loc_list_keys", "loc_next_batch", "loc_dead_keys"]
    private let locWrites = ["loc_create", "loc_rename", "loc_delete", "loc_add_language", "loc_remove_language",
                             "loc_submit_batch", "loc_add_key", "loc_remove_key", "loc_rename_key", "loc_rename_keys"]

    @Test("ADVISOR reads files and localization, and nothing else")
    func advisor() {
        for tool in reads + locReads { #expect(decide(tool, xcodeAdvisor).isAllowed, "\(tool)") }
        for tool in writes + locWrites { #expect(!decide(tool, xcodeAdvisor).isAllowed, "\(tool)") }
        for tool in ["git_status", "git_log", "git_commit", "build_project", "run_tests", "read_build_log"] {
            #expect(!decide(tool, xcodeAdvisor).isAllowed, "\(tool)")
        }
    }

    @Test("EXECUTOR on an Xcode project may use all of them")
    func executor() {
        let settings = xcodeExecutor()
        for tool in reads + writes + locReads + locWrites { #expect(decide(tool, settings).isAllowed, "\(tool)") }
    }

    @Test("loc_* mutations are denied by the role even when the project is Xcode")
    func locMutationsNeedExecutor() {
        for tool in locWrites { #expect(!decide(tool, xcodeAdvisor).isAllowed, "\(tool)") }
    }

    @Test("loc_* need an Xcode project, not any programming project")
    func locNeedsXcode() {
        let python = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .python)
        #expect(!decide("loc_info", python).isAllowed)
        #expect(!decide("loc_create", python).isAllowed)
        #expect(decide("read_file", python).isAllowed)
    }
}

// MARK: - Git, build, terminal

@Suite("ToolPolicy — git, build, terminal")
struct ToolPolicyGitBuildTests {

    @Test("git_log is available at the read-only git level")
    func gitLogAtStatusOnly() {
        let settings = xcodeExecutor(git: .statusOnly)
        #expect(decide("git_status", settings).isAllowed)
        #expect(decide("git_log", settings).isAllowed)
        #expect(!decide("git_commit", settings).isAllowed)
    }

    @Test("Git levels gate write and full tools")
    func gitLevels() {
        #expect(!decide("git_status", xcodeExecutor(git: .none)).isAllowed)
        #expect(decide("git_commit", xcodeExecutor(git: .write)).isAllowed)
        #expect(!decide("git_revert", xcodeExecutor(git: .write)).isAllowed)
        #expect(decide("git_revert", xcodeExecutor(git: .full)).isAllowed)
        #expect(decide("git_checkout", xcodeExecutor(git: .full)).isAllowed)
    }

    @Test("git needs a programming project")
    func gitNeedsProgramming() {
        let docs = ProjectSettings(agentRole: .executor, isProgrammingProject: false, gitAccess: .full)
        #expect(!decide("git_status", docs).isAllowed)
    }

    @Test("build_project needs only the build switch; run_tests also needs test access")
    func buildVersusTests() {
        let noTests = xcodeExecutor(tests: .none)
        #expect(decide("build_project", noTests).isAllowed)
        #expect(!decide("run_tests", noTests).isAllowed)
        #expect(!decide("run_tests", xcodeExecutor(tests: .readOnly)).isAllowed)
        #expect(decide("run_tests", xcodeExecutor(tests: .run)).isAllowed)
    }

    @Test("buildEnabled = false disables build, tests and the build log")
    func buildSwitchOff() {
        let off = xcodeExecutor(tests: .write, build: false)
        for tool in ["build_project", "run_tests", "read_build_log"] { #expect(!decide(tool, off).isAllowed, "\(tool)") }
    }

    @Test("read_build_log needs log access")
    func buildLog() {
        #expect(!decide("read_build_log", xcodeExecutor(tests: .none)).isAllowed)
        #expect(decide("read_build_log", xcodeExecutor(tests: .readOnly)).isAllowed)
    }

    @Test("Terminal is a thread switch, independent of the project role")
    func terminal() {
        #expect(!decide("run_terminal", nil, terminal: .none).isAllowed)
        #expect(decide("run_terminal", nil, terminal: .confirm).isAllowed)
        #expect(decide("run_ssh", xcodeAdvisor, terminal: .auto).isAllowed)
    }
}

// MARK: - Per-project resolution

@Suite("ToolAuthorization — the call's own project decides")
struct ToolAuthorizationTests {

    @Test("Executor + advisor: the advisor project cannot be written to")
    func rightsDoNotLeakBetweenProjects() async {
        let rig = await Rig([("Writable", xcodeExecutor()), ("ReadOnly", xcodeAdvisor)])
        #expect(isAllowed(await rig.authorize("write_file", #"{"path":"a.txt","content":"x","project":"Writable"}"#)))
        let denied = await rig.authorize("write_file", #"{"path":"a.txt","content":"x","project":"ReadOnly"}"#)
        #expect(!isAllowed(denied))
        #expect(denial(denied).contains("ADVISOR"))
        #expect(!isAllowed(await rig.authorize("loc_delete", #"{"path":"A.xcstrings","project":"ReadOnly"}"#)))
    }

    @Test("Several projects and no project named: refused with the list, never 'the first one'")
    func ambiguousProjectIsRefused() async {
        let rig = await Rig([("One", xcodeExecutor()), ("Two", xcodeExecutor())])
        let result = await rig.authorize("run_tests", "{}")
        #expect(!isAllowed(result))
        #expect(denial(result).contains("'One'") && denial(result).contains("'Two'"))
    }

    @Test("A single attached project is used when none is named, and the name is written back")
    func singleProjectDefault() async {
        let rig = await Rig([("Solo", xcodeExecutor())])
        guard case .allowed(let data, let args) = await rig.authorize("read_file", #"{"path":"a.txt"}"#) else {
            Issue.record("must be allowed"); return
        }
        #expect(args["project"] == "Solo")
        #expect((try? JSONDecoder().decode([String: String].self, from: data))?["project"] == "Solo")
    }

    @Test("Project name matching is forgiving about case but the executor receives the exact name")
    func caseInsensitiveCanonicalName() async {
        let rig = await Rig([("MyApp", xcodeExecutor()), ("Other", xcodeAdvisor)])
        guard case .allowed(_, let args) = await rig.authorize("read_file", #"{"path":"a.txt","project":"myapp"}"#) else {
            Issue.record("must be allowed"); return
        }
        #expect(args["project"] == "MyApp")
    }

    @Test("An unknown project name is refused and the attached ones are listed")
    func unknownProject() async {
        let rig = await Rig([("MyApp", xcodeExecutor())])
        let result = await rig.authorize("read_file", #"{"path":"a.txt","project":"Nope"}"#)
        #expect(!isAllowed(result))
        #expect(denial(result).contains("'MyApp'"))
    }

    @Test("A path prefix picks the project for file tools when none is named")
    func prefixRouting() async {
        let rig = await Rig([("Writable", xcodeExecutor()), ("ReadOnly", xcodeAdvisor)])
        #expect(isAllowed(await rig.authorize("write_file", #"{"path":"Writable/a.txt","content":"x"}"#)))
        #expect(!isAllowed(await rig.authorize("write_file", #"{"path":"ReadOnly/a.txt","content":"x"}"#)))
    }

    @Test("list_files and search_in_project may span projects when none is named")
    func fanOutReads() async {
        let rig = await Rig([("One", xcodeExecutor()), ("Two", xcodeAdvisor)])
        #expect(isAllowed(await rig.authorize("list_files", "{}")))
        #expect(isAllowed(await rig.authorize("search_in_project", #"{"query":"x"}"#)))
    }

    @Test("Numbers and booleans no longer lose the project: they become strings")
    func nonStringArguments() async {
        let rig = await Rig([("One", xcodeExecutor()), ("Two", xcodeExecutor())])
        let result = await rig.authorize("run_tests", #"{"project":"One","timeout":30,"verbose":true}"#)
        guard case .allowed(_, let args) = result else { Issue.record("expected allowed"); return }
        #expect(args["project"] == "One")
        #expect(args["timeout"] == "30")
        #expect(args["verbose"] == "true")
    }

    @Test("Arguments that are not a JSON object are refused with an explanation")
    func unreadableArguments() async {
        let rig = await Rig([("One", xcodeExecutor())])
        #expect(denial(await rig.authorize("read_file", "[1,2]")).contains("JSON object"))
        #expect(denial(await rig.authorize("read_file", "{broken")).contains("not valid JSON"))
    }

    @Test("Tools without a project ignore the argument shape (web_fetch carries nested headers)")
    func alwaysOnIgnoresShape() async {
        let rig = await Rig([("One", xcodeExecutor())])
        #expect(isAllowed(await rig.authorize("web_fetch", #"{"url":"https://a.b","headers":{"X":"1"}}"#)))
    }

    @Test("Unknown tools and git_diff are denied by the live gate too")
    func liveGateDeniesUnknown() async {
        let rig = await Rig([("One", xcodeExecutor())], terminal: .auto)
        #expect(!isAllowed(await rig.authorize("not_a_tool", "{}")))
        #expect(!isAllowed(await rig.authorize("git_diff", #"{"project":"One"}"#)))
    }
}

// MARK: - Exposure

@Suite("ToolPolicy — what the model is shown")
struct ToolExposureTests {

    @Test("Every classified tool is offered at any rights level, git_diff included")
    func everyClassifiedToolIsOffered() async {
        let setups: [[(String, ProjectSettings)]] = [
            [], [("A", xcodeAdvisor)], [("A", xcodeExecutor())], [("A", xcodeAdvisor), ("B", xcodeExecutor())]
        ]
        for setup in setups {
            let rig = await Rig(setup, terminal: .none)
            #expect(await rig.names() == ToolPolicy.knownTools)
            let maxRig = await Rig(setup, terminal: .auto, curl: true)
            #expect(await maxRig.names() == ToolPolicy.knownTools)
        }
    }

    @Test("dangerOrder lists every classified tool exactly once")
    func dangerOrderIsComplete() {
        #expect(Set(ToolPolicy.dangerOrder) == ToolPolicy.knownTools)
        #expect(ToolPolicy.dangerOrder.count == ToolPolicy.knownTools.count)
    }

    @Test("Every description opens with a status line")
    func everyDescriptionHasStatus() async {
        let tools = await Rig([("A", xcodeAdvisor)]).service.availableTools
        for tool in tools {
            #expect(tool.function.description.hasPrefix("["), "\(tool.function.name)")
        }
    }

    @Test("Curl-Chappie: closed without the thread switch or without an EXECUTOR project, open with both")
    func curlExposure() async {
        let curlTools: Set<String> = [
            "curl_request", "curl_session", "curl_extract",
            "curl_scenario_info", "curl_scenario_save", "curl_scenario_delete", "curl_scenario_run"
        ]
        func openCurl(_ rig: Rig) async -> Set<String> {
            Set(await rig.service.availableTools
                .filter { curlTools.contains($0.function.name) && !isClosed($0) }.map(\.function.name))
        }
        #expect(await openCurl(await Rig([("A", xcodeExecutor())])).isEmpty, "switch off")
        #expect(await openCurl(await Rig([("A", xcodeAdvisor)], curl: true)).isEmpty, "advisor only")
        #expect(await openCurl(await Rig([], curl: true)).isEmpty, "no project")
        #expect(await openCurl(await Rig([("A", xcodeExecutor())], curl: true)) == curlTools)
        #expect(await openCurl(await Rig([("A", xcodeAdvisor), ("B", xcodeExecutor())], curl: true)) == curlTools, "one executor is enough")
    }

    @Test("Curl-Chappie: the call is judged by the project it names, the switch by the thread")
    func curlAuthorization() async {
        let rig = await Rig([("Exec", xcodeExecutor()), ("Adv", xcodeAdvisor)], curl: true)
        #expect(isAllowed(await rig.authorize("curl_request", #"{"project":"Exec","host":"Dev","path":"/x"}"#)))
        let denied = await rig.authorize("curl_request", #"{"project":"Adv","host":"Dev","path":"/x"}"#)
        #expect(!isAllowed(denied))
        #expect(denial(denied).contains("ADVISOR"))
        #expect(!isAllowed(await rig.authorize("curl_request", #"{"host":"Dev"}"#)), "several projects and none named")

        let off = await Rig([("Exec", xcodeExecutor())], curl: false)
        let blocked = await off.authorize("curl_session", #"{"action":"info","host":"Dev"}"#)
        #expect(!isAllowed(blocked))
        #expect(denial(blocked).contains("Curl-Chappie"))
    }

    @Test("An advisor-only thread sees mutations as closed, with the reason, and reads as open")
    func advisorThreadClosesMutations() async {
        let tools = await Rig([("A", xcodeAdvisor)]).service.availableTools
        for tool in ["write_file", "patch_file", "delete_file", "write_document", "git_status", "git_commit",
                     "build_project", "run_tests", "loc_create", "loc_submit_batch", "run_terminal"] {
            let found = description(of: tool, in: tools)
            #expect(found.hasPrefix("[UNAVAILABLE"), "\(tool) must be closed: \(found)")
        }
        #expect(description(of: "write_file", in: tools).contains("ADVISOR"))
        #expect(description(of: "run_terminal", in: tools).contains("Terminal"))
        for tool in ["read_file", "search_in_project", "loc_info", "loc_list_keys"] {
            #expect(description(of: tool, in: tools).hasPrefix("[AVAILABLE in: A"), "\(tool)")
        }
        #expect(description(of: "memorize", in: tools).hasPrefix("[ALWAYS AVAILABLE]"))
    }

    @Test("A mixed thread names the projects where a tool works and where it does not")
    func mixedThreadNamesProjects() async {
        let tools = await Rig([("Adv", xcodeAdvisor), ("Exec", xcodeExecutor())]).service.availableTools
        let text = description(of: "write_file", in: tools)
        #expect(text.hasPrefix("[AVAILABLE in: Exec. UNAVAILABLE in: Adv"), "\(text)")
        #expect(text.contains("ADVISOR"))
    }

    @Test("The terminal status shows the thread mode when open")
    func terminalExposure() async {
        let open = await Rig([("A", xcodeExecutor())], terminal: .confirm).service.availableTools
        #expect(description(of: "run_ssh", in: open).hasPrefix("[AVAILABLE"))
        #expect(description(of: "run_ssh", in: open).contains("confirmation"))
        let shut = await Rig([("A", xcodeExecutor())], terminal: .none).service.availableTools
        #expect(description(of: "run_terminal", in: shut).hasPrefix("[UNAVAILABLE"))
    }

    @Test("git_diff is offered only as FORBIDDEN")
    func gitDiffIsForbidden() async {
        let tools = await Rig([("A", xcodeExecutor())], terminal: .auto).service.availableTools
        let text = description(of: "git_diff", in: tools)
        #expect(text.hasPrefix("[FORBIDDEN"), "\(text)")
        #expect(text.contains("git_status"))
    }

    @Test("Available tools come first, closed ones after; each list goes from harmless to dangerous")
    func orderingByDanger() async {
        let tools = await Rig([("A", xcodeAdvisor), ("B", xcodeExecutor(git: .statusOnly))], curl: false).service.availableTools
        let flags = tools.map(isClosed)
        if let firstClosed = flags.firstIndex(of: true) {
            #expect(!flags[firstClosed...].contains(false), "an open tool follows a closed one")
        }
        for group in [tools.filter { !isClosed($0) }, tools.filter(isClosed)] {
            let ranks = group.map { ToolPolicy.dangerRank(of: $0.function.name) }
            #expect(ranks == ranks.sorted())
        }
        let names = tools.map(\.function.name)
        #expect(names.firstIndex(of: "write_file")! < names.firstIndex(of: "git_status")!)
        #expect(names.last == "git_diff")
    }

    @Test("Closed tools are compressed: no parameters, one group description with the shared reason")
    func closedGroupsAreCompressed() async {
        let tools = await Rig([("A", xcodeAdvisor)]).service.availableTools
        let git = tools.filter { $0.function.name.hasPrefix("git_") && $0.function.name != "git_diff" }
        #expect(git.count == 8)
        for tool in git { #expect(tool.function.parameters.properties.isEmpty, "\(tool.function.name)") }
        let heads = git.filter { $0.function.description.contains("Group «Git»") }
        #expect(heads.count == 1)
        #expect(heads[0].function.description.contains("git_status, git_log"))
        let followers = git.filter { !$0.function.description.contains("Group «Git»") }
        for tool in followers { #expect(tool.function.description.contains("same reason and fix as git_status")) }
    }

    @Test("Every project is listed in the project argument and required when several are attached")
    func projectArgumentCoversEveryProject() async {
        let docs = ProjectSettings(agentRole: .executor, isProgrammingProject: false)
        let rig = await Rig([("Code", xcodeExecutor()), ("Docs", docs)])
        let tools = await rig.service.availableTools
        for name in ["git_status", "git_commit", "build_project", "run_tests", "read_build_log"] {
            guard let tool = tools.first(where: { $0.function.name == name }) else { Issue.record("\(name) missing"); continue }
            let arg = tool.function.parameters.properties["project"]?.description ?? ""
            #expect(arg.contains("'Code'") && arg.contains("'Docs'"), "\(name): \(arg)")
            #expect(tool.function.parameters.required?.contains("project") == true, "\(name)")
        }
        #expect(description(of: "git_status", in: tools).contains("AVAILABLE in: Code"))
        #expect(description(of: "git_status", in: tools).contains("Docs"))
    }

    @Test("loc_* definitions carry a project argument, required when several projects are attached")
    func locToolsHaveProjectArgument() async {
        let rig = await Rig([("A", xcodeExecutor()), ("B", xcodeExecutor())])
        let loc = await rig.service.availableTools.filter { $0.function.name.hasPrefix("loc_") }
        #expect(loc.count == 15)
        for tool in loc {
            #expect(tool.function.parameters.properties["project"] != nil, "\(tool.function.name)")
            #expect(tool.function.parameters.required?.contains("project") == true, "\(tool.function.name)")
        }
    }
}
