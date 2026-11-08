// CurlScenarioRunnerTests.swift
// ChappieCoreTests
//
// Scenario RUNS against a stateful stub server (nothing touches the network): the Stroykontrol chain
// (Authorization -> Remark_create -> Remark_with_comment), root-only cleanup, preflight refusals,
// failed steps, shared-session reuse, several actors, and the injection guard.

import Testing
import Foundation
@testable import ChappieCore

// MARK: - Test doubles

private final class Server: CurlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var logStore: [String] = []
    private var remarkStore: [Int: String] = [:]      // id -> comment
    var log: [String] { lock.lock(); defer { lock.unlock() }; return logStore }
    var remarks: [Int: String] { lock.lock(); defer { lock.unlock() }; return remarkStore }
    private var nextId = 23458
    var failCreate = false
    var dropComment = false

    func send(_ request: URLRequest) async throws -> CurlRawResponse {
        handle(request)
    }

    /// Synchronous on purpose: NSLock cannot be held across a suspension point.
    private func handle(_ request: URLRequest) -> CurlRawResponse {
        lock.lock(); defer { lock.unlock() }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        logStore.append("\(method) \(path)")
        func json(_ text: String, _ status: Int = 200) -> CurlRawResponse {
            CurlRawResponse(status: status, headers: [CurlHeader("Content-Type", "application/json")], body: Data(text.utf8))
        }
        if path == "/api/login/token" {
            let user = String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("login=oleg") ? "oleg" : "ivan"
            // The long pad pushes refresh_token past the display limit, so the display cut lands inside its value.
            let pad = String(repeating: "x", count: 1420)
            let refresh = "refresh-secret-\(user)-" + String(repeating: "r", count: 200)
            return json(#"{"token_type":"Bearer","access_token":"tok-secret-\#(user)","pad":"\#(pad)","refresh_token":"\#(refresh)","user_id":\#(user == "oleg" ? 46 : 45)}"#)
        }
        guard (request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer tok-secret-") else {
            return json(#"{"title":"unauthorized"}"#, 401)
        }
        if method == "GET", path == "/api/construction-objects/constructions-registry/tier" {
            return json(#"{"data":{"constructions":[{"id":52,"fullName":"Other"},{"id":53,"fullName":"Полное наименование Стройки Мобилки 2"}]}}"#)
        }
        if method == "POST", path == "/api/objects/53/remarks" {
            if failCreate { return json(#"{"message":"boom"}"#, 500) }
            let id = nextId; nextId += 1
            remarkStore[id] = ""
            return json(#"{"id":\#(id)}"#, 201)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 5, parts[1] == "objects", parts[3] == "remarks", let id = Int(parts[4]) {
            switch method {
            case "PUT":
                guard remarkStore[id] != nil else { return json("{}", 404) }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                if !dropComment { remarkStore[id] = body?["comment"] as? String ?? "" }
                return json(#"{"comment":"\#(remarkStore[id] ?? "")"}"#)
            case "GET":
                guard let comment = remarkStore[id] else { return json("{}", 404) }
                return json(#"{"remark":{"id":\#(id),"comment":"\#(comment)"}}"#)
            case "DELETE":
                guard remarkStore.removeValue(forKey: id) != nil else { return json("{}", 404) }
                return CurlRawResponse(status: 204)
            default: break
            }
        }
        return json("{}", 404)
    }

    func count(_ line: String) -> Int { lock.lock(); defer { lock.unlock() }; return logStore.filter { $0 == line }.count }
    var total: Int { lock.lock(); defer { lock.unlock() }; return logStore.count }
}

private struct MapValues: CurlSecretValueProvider {
    let map: [String: String]
    func value(secretId: UUID, field: CurlSecretField) -> String? { map["\(secretId.uuidString).\(field.rawValue)"] }
}

private let origin = "https://sk.test"

private struct World {
    var context: CurlContext
    var root: URL
    var store: CurlScenarioStore

    init(permission: CurlHostPermission = .full, omitValues: Bool = false) throws {
        let tester = CurlSecret(name: "tester", kind: .loginPassword, hostOrigin: origin)
        let oleg = CurlSecret(name: "oleg", kind: .loginPassword, hostOrigin: origin)
        let clientId = CurlSecret(name: "clientId", kind: .plain, hostOrigin: origin)
        let clientSecret = CurlSecret(name: "clientSecret", kind: .plain, hostOrigin: origin)
        var values: [String: String] = [
            "\(tester.id.uuidString).login": "ivan", "\(tester.id.uuidString).password": "pass-ivan-1",
            "\(oleg.id.uuidString).login": "oleg", "\(oleg.id.uuidString).password": "pass-oleg-2",
            "\(clientId.id.uuidString).value": "3", "\(clientSecret.id.uuidString).value": "client-secret-9"
        ]
        if omitValues { values.removeValue(forKey: "\(clientSecret.id.uuidString).value") }
        context = CurlContext(
            hosts: [CurlHost(name: "Release", origin: origin, permission: permission, loginPath: "/api/login/token")],
            secrets: [tester, oleg, clientId, clientSecret], values: MapValues(map: values))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try CurlScenarioStore(root: root, folder: "Scenarios")
        for (name, text) in scenarios { _ = try store.write(name: name, json: CurlScenarioStore.canonicalJSON(from: text) ?? Data()) }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func run(_ name: String, server: Server, engine: CurlEngine? = nil, actors: [String: String] = ["user": "tester"],
             inputs: [String: String] = [:], verbose: Bool = false, dryRun: Bool = false) async throws -> CurlScenarioRunReport {
        let request = CurlScenarioRunRequest(scenario: name, host: "Release", actors: actors, inputs: inputs, verbose: verbose, dryRun: dryRun)
        return try await CurlScenarioRunner.run(request, store: store, context: context, engine: engine ?? CurlEngine(transport: server))
    }
}

// MARK: - Scenario files (the Stroykontrol chain)

private let scenarios: [String: String] = [
    "Authorization": #"""
    {"name":"Authorization","description":"Base login.","actors":["user"],"secrets":["clientId","clientSecret"],"returns":["userId"],
     "steps":[{"id":"login","as":"user","method":"POST","path":"/api/login/token",
       "form":{"clientId":"{{secret:clientId.value}}","clientSecret":"{{secret:clientSecret.value}}","login":"{{secret:user.login}}","password":"{{secret:user.password}}"},
       "login":{"extract":{"access_token":"json:access_token","token_type":{"from":"json:token_type","sensitive":false}},
                "apply":[{"header":"Authorization","template":"{{var:token_type}} {{var:access_token}}"}]},
       "extract":{"userId":"json:user_id"},
       "expect":{"status":200,"checks":[{"path":"access_token","exists":true}]}}]}
    """#,
    "Remark_create": #"""
    {"name":"Remark_create","description":"Create a remark.","mutates":true,"actors":["user"],"secrets":["clientId","clientSecret"],
     "inputs":[{"name":"objectId","default":"53"},{"name":"companyId","default":"18"}],"returns":["remarkId"],
     "steps":[
      {"id":"auth","call":"Authorization","as":"user","returns":["userId"]},
      {"id":"find","as":"user","method":"GET","path":"/api/construction-objects/constructions-registry/tier","query":{"companyId":"{{input:companyId}}"},
       "expect":{"status":200,"checks":[{"path":"data.constructions[*].fullName","contains":"Полное наименование Стройки Мобилки 2"}]}},
      {"id":"create","as":"user","method":"POST","path":"/api/objects/{{input:objectId}}/remarks","json":{"user_id":"{{var:auth.userId}}"},
       "extract":{"remarkId":"json:id"},"expect":{"status":[200,201],"checks":[{"path":"id","exists":true}]}},
      {"id":"read","as":"user","method":"GET","path":"/api/objects/{{input:objectId}}/remarks/{{var:remarkId}}",
       "expect":{"status":200,"checks":[{"path":"remark.id","equals":"{{var:remarkId}}"}]}}],
     "cleanup":[{"id":"remove","as":"user","method":"DELETE","path":"/api/objects/{{input:objectId}}/remarks/{{var:remarkId}}","expect":{"status":204}}]}
    """#,
    "Remark_with_comment": #"""
    {"name":"Remark_with_comment","description":"Create, comment, verify.","mutates":true,"actors":["user"],"secrets":["clientId","clientSecret"],
     "inputs":[{"name":"objectId","default":"53"},{"name":"commentText","default":"Chappie test comment"}],"returns":["create.remarkId"],
     "steps":[
      {"id":"create","call":"Remark_create","as":"user","returns":["remarkId"],"with":{"objectId":"{{input:objectId}}"}},
      {"id":"set_comment","as":"user","method":"PUT","path":"/api/objects/{{input:objectId}}/remarks/{{var:create.remarkId}}",
       "json":{"comment":"{{input:commentText}}"},"expect":{"status":200,"checks":[{"path":"comment","equals":"{{input:commentText}}"}]}},
      {"id":"read_back","as":"user","method":"GET","path":"/api/objects/{{input:objectId}}/remarks/{{var:create.remarkId}}",
       "expect":{"status":200,"checks":[{"path":"remark.comment","equals":"{{input:commentText}}"}]}}],
     "cleanup":[{"id":"remove","as":"user","method":"DELETE","path":"/api/objects/{{input:objectId}}/remarks/{{var:create.remarkId}}","expect":{"status":204}}]}
    """#,
    "Two_users": #"""
    {"name":"Two_users","description":"Two actors on one host.","actors":["author","other"],"secrets":["clientId","clientSecret"],
     "steps":[
      {"id":"auth_a","call":"Authorization","as":"author"},
      {"id":"auth_b","call":"Authorization","as":"other"},
      {"id":"find_a","as":"author","method":"GET","path":"/api/construction-objects/constructions-registry/tier"},
      {"id":"find_b","as":"other","method":"GET","path":"/api/construction-objects/constructions-registry/tier"}]}
    """#
]

// MARK: - Tests

@Suite("Curl scenarios - runner")
struct CurlScenarioRunnerTests {

    @Test("A nested scenario runs, the root cleanup deletes the remark and nothing is left behind")
    func chainAndRootCleanup() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Remark_with_comment", server: server)

        #expect(report.passed && !report.refused, "\(report.text)")
        #expect(report.text.contains("PASSED"))
        #expect(report.text.contains("WRITES DATA"))
        #expect(server.count("POST /api/objects/53/remarks") == 1)
        #expect(server.count("DELETE /api/objects/53/remarks/23458") == 1, "root cleanup deletes the created remark")
        #expect(server.remarks.isEmpty)
        #expect(server.count("POST /api/login/token") == 1, "the callee's login happens once")
        #expect(report.text.contains("↳ create — call Remark_create"))
    }

    @Test("Called Remark_create keeps its remark: its own cleanup does not run when it is nested")
    func nestedCleanupDoesNotRun() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        server.dropComment = true      // makes the parent fail after the child created the remark
        let report = try await world.run("Remark_with_comment", server: server)
        #expect(!report.passed)
        // The failing parent stops, then ITS cleanup removes the remark created by the nested call.
        #expect(server.count("DELETE /api/objects/53/remarks/23458") == 1)
        #expect(server.remarks.isEmpty)
        #expect(report.text.contains("FAILED"))
    }

    @Test("As ROOT, Remark_create runs its own cleanup")
    func rootCleanup() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Remark_create", server: server)
        #expect(report.passed, "\(report.text)")
        #expect(server.count("DELETE /api/objects/53/remarks/23458") == 1)
        #expect(report.text.contains("Cleanup ran."))
    }

    @Test("A failed create skips the cleanup that has nothing to delete, and reports it")
    func cleanupSkippedWithoutValue() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        server.failCreate = true
        let report = try await world.run("Remark_create", server: server)
        #expect(!report.passed)
        #expect(server.count("DELETE /api/objects/53/remarks/23458") == 0)
        #expect(report.text.contains("skipped, no value for var:remarkId"), "\(report.text)")
        #expect(report.text.contains("expected status 200 or 201, got 500"))
        #expect(report.text.contains("boom"), "the failed step shows its body")
    }

    @Test("A failed check still runs the cleanup")
    func cleanupAfterFailedCheck() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        server.dropComment = true
        let report = try await world.run("Remark_with_comment", server: server, inputs: ["commentText": "hello"])
        #expect(!report.passed)
        #expect(report.text.contains("is '', expected 'hello'"), "\(report.text)")
        #expect(server.remarks.isEmpty)
    }

    // MARK: - Preflight

    @Test("A host that forbids the writes refuses the run before any request is sent")
    func preflightRefusesWrites() async throws {
        let world = try World(permission: .readAndLogin); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Remark_with_comment", server: server)
        #expect(report.refused && server.total == 0)
        #expect(report.text.contains("read") && report.text.contains("Remark_create/create"), "\(report.text)")
    }

    @Test("The ROOT cleanup is part of the preflight: a forbidden DELETE stops a run whose main steps only read")
    func preflightChecksCleanup() async throws {
        let world = try World(permission: .readAndLogin); defer { world.cleanUp() }
        let text = #"""
        {"name":"Read_then_delete","description":"Reads, then deletes in cleanup.","mutates":true,"actors":["user"],"secrets":["clientId","clientSecret"],
         "steps":[{"id":"auth","call":"Authorization","as":"user"},
                  {"id":"find","as":"user","method":"GET","path":"/api/construction-objects/constructions-registry/tier"}],
         "cleanup":[{"id":"remove","as":"user","method":"DELETE","path":"/api/objects/53/remarks/1"}]}
        """#
        _ = try world.store.write(name: "Read_then_delete", json: CurlScenarioStore.canonicalJSON(from: text) ?? Data())
        let server = Server()
        let report = try await world.run("Read_then_delete", server: server)
        #expect(report.refused && server.total == 0, "\(report.text)")
        #expect(report.text.contains("Read_then_delete/remove") && report.text.contains("DELETE"), "\(report.text)")
    }

    @Test("Cleanup of a CALLED scenario is not checked by the preflight (it never runs)")
    func preflightIgnoresNestedCleanup() async throws {
        let world = try World(permission: .readAndLogin); defer { world.cleanUp() }
        let child = #"""
        {"name":"Child","description":"Reads; its cleanup would be forbidden but never runs when nested.","mutates":true,"actors":["user"],"secrets":["clientId","clientSecret"],
         "steps":[{"id":"find","as":"user","method":"GET","path":"/api/construction-objects/constructions-registry/tier"}],
         "cleanup":[{"id":"remove","as":"user","method":"DELETE","path":"/api/objects/53/remarks/1"}]}
        """#
        let parent = #"""
        {"name":"Parent","description":"Calls Child.","mutates":true,"actors":["user"],"secrets":["clientId","clientSecret"],
         "steps":[{"id":"auth","call":"Authorization","as":"user"},{"id":"c","call":"Child","as":"user"}]}
        """#
        _ = try world.store.write(name: "Child", json: CurlScenarioStore.canonicalJSON(from: child) ?? Data())
        _ = try world.store.write(name: "Parent", json: CurlScenarioStore.canonicalJSON(from: parent) ?? Data())
        let server = Server()
        let report = try await world.run("Parent", server: server)
        #expect(report.passed && !report.refused, "\(report.text)")
        #expect(server.count("DELETE /api/objects/53/remarks/1") == 0)
    }

    @Test("Dry run checks everything and sends nothing")
    func dryRun() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Remark_with_comment", server: server, dryRun: true)
        #expect(report.passed && server.total == 0)
        #expect(report.text.contains("Dry run: preflight passed"))
    }

    @Test("Unmapped secrets, unknown slots, unknown inputs and missing values are all listed before any request")
    func preflightArguments() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()

        let wrongActor = try await world.run("Authorization", server: server, actors: ["user": "ghost"])
        #expect(wrongActor.refused && wrongActor.text.contains("no secret named 'ghost'"), "\(wrongActor.text)")

        let wrongSlot = try await world.run("Authorization", server: server, actors: ["nobody": "tester"])
        #expect(wrongSlot.refused && wrongSlot.text.contains("'nobody' is not a slot"), "\(wrongSlot.text)")

        let wrongInput = try await world.run("Remark_create", server: server, inputs: ["nope": "1"])
        #expect(wrongInput.refused && wrongInput.text.contains("'nope' is not an input"), "\(wrongInput.text)")

        let noValues = try World(omitValues: true); defer { noValues.cleanUp() }
        let missing = try await noValues.run("Authorization", server: server)
        #expect(missing.refused && missing.text.contains("no stored value for value"), "\(missing.text)")
        #expect(server.total == 0)
    }

    // MARK: - Sessions, actors, secrets

    @Test("A second run reuses the live session: no new login, and the returned values still arrive")
    func sessionReuse() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let engine = CurlEngine(transport: server)
        _ = try await world.run("Remark_create", server: server, engine: engine)
        #expect(server.count("POST /api/login/token") == 1)

        let second = try await world.run("Remark_create", server: server, engine: engine)
        #expect(second.passed, "\(second.text)")
        #expect(server.count("POST /api/login/token") == 1, "the shared session is reused")
        #expect(second.text.contains("session reused"))
    }

    @Test("Two actors on one host get their own sessions and tokens")
    func twoActors() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Two_users", server: server, actors: ["author": "tester", "other": "oleg"])
        #expect(report.passed, "\(report.text)")
        #expect(server.count("POST /api/login/token") == 2)
        #expect(report.text.contains("author=tester") && report.text.contains("other=oleg"), "\(report.text)")
    }

    @Test("No token, password or client secret ever appears in the report, even verbose")
    func reportIsRedacted() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let report = try await world.run("Remark_with_comment", server: server, verbose: true)
        // "refresh-secret" sits behind the 1500-character display cut: it must be masked BEFORE the body is cut.
        for secret in ["tok-secret-ivan", "pass-ivan-1", "client-secret-9", "refresh-secret", "rrrrrrrrrr"] {
            #expect(!report.text.contains(secret), "\(secret) leaked:\n\(report.text)")
        }
        #expect(report.text.contains("access_token (hidden)") || report.text.contains("session reused") || report.text.contains("extracted"))
    }

    @Test("An unknown host and an unknown scenario are refused with guidance")
    func unknowns() async throws {
        let world = try World(); defer { world.cleanUp() }
        let server = Server()
        let badHost = CurlScenarioRunRequest(scenario: "Authorization", host: "Nope")
        let one = try await CurlScenarioRunner.run(badHost, store: world.store, context: world.context, engine: CurlEngine(transport: server))
        #expect(one.refused && one.text.contains("Unknown host"))
        let missing = try await world.run("Ghost", server: server)
        #expect(missing.refused && missing.text.contains("does not exist"))
    }

    // MARK: - Substitution and checks

    @Test("A variable value that looks like a secret reference is refused, not expanded")
    func injectionGuard() {
        var scope = CurlScenarioScope(
            scenario: CurlScenario(name: "x", description: "d", steps: []), actors: [:], secrets: [:], inputs: [:])
        scope.vars["bad"] = CurlScenarioValue(text: "{{secret:tester.password}}", sensitive: false)
        scope.vars["edge"] = CurlScenarioValue(text: "abc{", sensitive: false)
        scope.vars["good"] = CurlScenarioValue(text: "a b/c", sensitive: false)

        let bad = CurlScenarioSubstitution.apply("/x/{{var:bad}}", mode: .url, scope: scope)
        #expect(!bad.isClean && bad.problems.first?.contains("refusing") == true)
        #expect(!CurlScenarioSubstitution.apply("{{var:edge}}", mode: .raw, scope: scope).isClean)
        #expect(CurlScenarioSubstitution.apply("/x/{{var:good}}", mode: .url, scope: scope).text == "/x/a%20b%2Fc")
        #expect(CurlScenarioSubstitution.apply("{{var:missing}}", mode: .raw, scope: scope).missing == ["var:missing"])
    }

    @Test("An unquoted placeholder in a JSON body becomes a bare number; a quoted one stays a string")
    func bareJSONLiterals() {
        var scope = CurlScenarioScope(
            scenario: CurlScenario(name: "x", description: "d", steps: []), actors: [:], secrets: [:], inputs: ["type": "49"])
        scope.vars["uid"] = CurlScenarioValue(text: "45", sensitive: false)
        scope.vars["word"] = CurlScenarioValue(text: "abc", sensitive: false)
        scope.vars["flag"] = CurlScenarioValue(text: "true", sensitive: false)

        let body = #"{"user_id":{{var:uid}},"type":{{input:type}},"s":"{{var:uid}}","on":{{var:flag}}}"#
        let ok = CurlScenarioSubstitution.apply(body, mode: .json, scope: scope)
        #expect(ok.isClean && ok.text == #"{"user_id":45,"type":49,"s":"45","on":true}"#, "\(ok.text) \(ok.problems)")

        let bad = CurlScenarioSubstitution.apply(#"{"x":{{var:word}}}"#, mode: .json, scope: scope)
        #expect(!bad.isClean && bad.problems.first?.contains("must be a number") == true)

        // Outside a JSON body nothing changes: URLs and forms always get the escaped text.
        #expect(CurlScenarioSubstitution.apply("/u/{{var:uid}}", mode: .url, scope: scope).text == "/u/45")
    }

    @Test("A body with an unquoted placeholder is accepted by the scenario decoder")
    func decoderAcceptsUnquotedPlaceholder() {
        let text = #"""
        {"name":"S","description":"d","mutates":true,"inputs":[{"name":"t","default":"1"}],
         "steps":[{"id":"c","method":"POST","path":"/x","json":"{\"type\":{{input:t}},\"n\":\"{{input:t}}\"}"}]}
        """#
        let result = CurlScenarioDecoder.decode(Data(text.utf8))
        if case .failure(let issues) = result { Issue.record("\(issues.messages)") }
    }

    @Test("Checks: status default, equals, contains on arrays and strings, exists")
    func checks() {
        let body = Data(#"{"a":{"n":5,"s":"hello world","ok":true},"list":[{"id":1},{"id":2}],"nothing":null}"#.utf8)
        func fails(_ checks: [CurlScenarioCheck], statuses: [Int] = [], status: Int = 200) -> [String] {
            CurlScenarioChecks.failures(statuses: statuses, checks: checks, status: status, body: body)
        }
        #expect(fails([]).isEmpty)
        #expect(fails([], status: 500).first?.contains("expected a 2xx") == true)
        #expect(fails([], statuses: [201], status: 200).first?.contains("expected status 201") == true)
        #expect(fails([CurlScenarioCheck(path: "a.n", operation: .equals("5"))]).isEmpty)
        #expect(fails([CurlScenarioCheck(path: "a.ok", operation: .equals("true"))]).isEmpty)
        #expect(!fails([CurlScenarioCheck(path: "a.n", operation: .equals("6"))]).isEmpty)
        #expect(fails([CurlScenarioCheck(path: "list[*].id", operation: .contains("2"))]).isEmpty)
        #expect(!fails([CurlScenarioCheck(path: "list[*].id", operation: .contains("3"))]).isEmpty)
        #expect(fails([CurlScenarioCheck(path: "a.s", operation: .contains("lo wo"))]).isEmpty)
        #expect(fails([CurlScenarioCheck(path: "a.n", operation: .exists(true))]).isEmpty)
        #expect(!fails([CurlScenarioCheck(path: "nothing", operation: .exists(true))]).isEmpty)
        #expect(fails([CurlScenarioCheck(path: "nothing", operation: .exists(false))]).isEmpty)
        #expect(!fails([CurlScenarioCheck(path: "missing.path", operation: .equals("x"))]).isEmpty)
    }
}
