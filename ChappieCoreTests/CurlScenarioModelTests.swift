// CurlScenarioModelTests.swift
// ChappieCoreTests
//
// Scenario file format: strict decoding and the pure validator (contract, cycles, depth, mutates).

import Testing
import Foundation
@testable import ChappieCore

private func decode(_ json: String) -> Result<CurlScenario, CurlScenarioIssues> {
    CurlScenarioDecoder.decode(Data(json.utf8))
}

private func scenario(_ json: String) -> CurlScenario {
    guard case .success(let s) = decode(json) else { Issue.record("did not decode: \(json)"); return CurlScenario(name: "x", description: "x", steps: []) }
    return s
}

/// A scenario with one GET step; `extras` are extra top-level members.
private func readScenario(_ name: String, _ extras: String = "", path: String = "/api/x") -> String {
    """
    {"name":"\(name)","description":"d",\(extras)
     "steps":[{"id":"s1","method":"GET","path":"\(path)"}]}
    """
}

private func lookup(_ all: [CurlScenario]) -> CurlScenarioValidator.Lookup {
    let map = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    return { map[$0] }
}

@Suite("Curl scenarios - decoding")
struct CurlScenarioDecodingTests {

    @Test("A complete scenario decodes with every part")
    func fullScenario() {
        let s = scenario("""
        {"name":"flow","description":"d","mutates":true,"actors":["a"],"secrets":["c"],
         "inputs":[{"name":"n","description":"x"},{"name":"m","default":5}],
         "steps":[
          {"id":"login","as":"a","method":"post","path":"/l","form":{"u":"{{secret:a.login}}"},
           "login":{"extract":{"tok":"json:access_token"},"apply":[{"header":"Authorization","template":"Bearer {{var:tok}}"}]},
           "expect":{"status":200}},
          {"id":"make","as":"a","method":"POST","path":"/i","json":{"t":"{{input:n}}"},
           "extract":{"issueId":"json:data.id"},"expect":{"status":[200,201],"checks":[{"path":"data.id","exists":true},{"path":"data.n","equals":3}]}}],
         "returns":["issueId"],
         "cleanup":[{"id":"rm","as":"a","method":"DELETE","path":"/i/{{var:issueId}}"}]}
        """)
        #expect(s.mutates && s.actors == ["a"] && s.secrets == ["c"])
        #expect(s.inputs.map(\.isRequired) == [true, false])
        #expect(s.inputs[1].defaultValue == "5")
        #expect(s.steps[0].request?.method == "POST")
        #expect(s.steps[0].request?.login?.extract.first?.sensitive == true)
        #expect(s.steps[1].expect.statuses == [200, 201])
        #expect(s.steps[1].expect.checks.count == 2)
        #expect(s.cleanup.count == 1 && s.returns == ["issueId"])
    }

    @Test("An unknown key is an error, so a typo cannot drop a check silently")
    func unknownKeys() {
        guard case .failure(let issues) = decode(#"{"name":"a","description":"d","steps":[{"id":"x","method":"GET","path":"/","expects":{}}],"colour":1}"#) else {
            Issue.record("should fail"); return
        }
        #expect(issues.messages.contains { $0.contains("'colour'") })
        #expect(issues.messages.contains { $0.contains("'expects'") })
    }

    @Test("All problems are reported together")
    func collectsEverything() {
        guard case .failure(let issues) = decode(#"{"steps":[{"id":"x"}]}"#) else { Issue.record("should fail"); return }
        #expect(issues.messages.count >= 3)
    }

    @Test("A call step cannot carry request fields and a request step cannot carry call fields")
    func stepKinds() {
        guard case .failure(let a) = decode(#"{"name":"a","description":"d","steps":[{"id":"c","call":"b","path":"/x"}]}"#) else { Issue.record("a"); return }
        #expect(a.messages.contains { $0.contains("cannot have 'path'") })
        guard case .failure(let b) = decode(#"{"name":"a","description":"d","steps":[{"id":"c","method":"GET","path":"/","with":{}}]}"#) else { Issue.record("b"); return }
        #expect(b.messages.contains { $0.contains("belongs to a 'call' step") })
    }

    @Test("Only one body, and a JSON body may be an object or text")
    func bodies() {
        guard case .failure(let two) = decode(#"{"name":"a","description":"d","steps":[{"id":"c","method":"POST","path":"/","json":{},"text":"x"}]}"#) else { Issue.record("two"); return }
        #expect(two.messages.contains { $0.contains("only one body") })
        let text = scenario(#"{"name":"a","description":"d","steps":[{"id":"c","method":"POST","path":"/","json":"{\"k\":1}"}]}"#)
        #expect(text.steps[0].request?.body == .json(#"{"k":1}"#))
    }

    @Test("Not a JSON object")
    func notAnObject() {
        guard case .failure = decode("[1,2]") else { Issue.record("should fail"); return }
        guard case .failure = decode("nope") else { Issue.record("should fail"); return }
    }

    @Test("as may be a name or an object for a call")
    func callActors() {
        let s = scenario(#"{"name":"a","description":"d","actors":["x","y"],"steps":[{"id":"c","call":"b","as":{"p":"x","q":"y"}}]}"#)
        #expect(s.steps[0].call?.actorMap == ["p": "x", "q": "y"])
    }
}

@Suite("Curl scenarios - validation")
struct CurlScenarioValidationTests {

    private func check(_ s: CurlScenario, others: [CurlScenario] = []) -> CurlScenarioValidation {
        CurlScenarioValidator.validate(s, lookup: lookup([s] + others))
    }

    @Test("A read-only scenario is valid and has depth 1")
    func simpleValid() {
        let v = check(scenario(readScenario("flow")))
        #expect(v.isValid, "\(v.errors)")
        #expect(v.depth == 1 && !v.writesData)
    }

    @Test("A write step needs mutates: true; a login step does not count as a write")
    func mutatesRule() {
        let write = scenario(#"{"name":"w","description":"d","steps":[{"id":"s","method":"POST","path":"/x"}]}"#)
        #expect(check(write).errors.contains { $0.contains("mutates") })
        let login = scenario("""
        {"name":"l","description":"d","actors":["a"],"steps":[{"id":"s","as":"a","method":"POST","path":"/login",
         "login":{"extract":{"t":"json:t"}}}]}
        """)
        #expect(check(login).isValid, "\(check(login).errors)")
    }

    @Test("Placeholders must refer to declared actors, secrets, inputs and earlier variables")
    func references() {
        let bad = scenario("""
        {"name":"r","description":"d","actors":["a"],"steps":[
         {"id":"s1","method":"GET","path":"/x/{{var:later}}","headers":{"X":"{{secret:ghost.value}}","Y":"{{input:nope}}"}},
         {"id":"s2","as":"a","method":"GET","path":"/y","extract":{"later":"json:id"}}]}
        """)
        let errors = check(bad).errors.joined(separator: "\n")
        #expect(errors.contains("{{var:later}}"))
        #expect(errors.contains("ghost"))
        #expect(errors.contains("{{input:nope}}"))
    }

    @Test("A variable set by an earlier step is visible later; an actor is login/password only")
    func referenceOrder() {
        let ok = scenario("""
        {"name":"r","description":"d","actors":["a"],"steps":[
         {"id":"s1","as":"a","method":"GET","path":"/x","extract":{"id":"json:id"}},
         {"id":"s2","as":"a","method":"GET","path":"/y/{{var:id}}","headers":{"P":"{{secret:a.password}}"}}]}
        """)
        #expect(check(ok).isValid, "\(check(ok).errors)")
        let wrongField = scenario(#"{"name":"r","description":"d","actors":["a"],"steps":[{"id":"s","as":"a","method":"GET","path":"/","headers":{"H":"{{secret:a.value}}"}}]}"#)
        #expect(check(wrongField).errors.contains { $0.contains("login+password") })
    }

    @Test("A step's actor must be declared; names are checked")
    func actors() {
        let s = scenario(#"{"name":"bad name","description":"d","actors":["a b"],"steps":[{"id":"s","as":"z","method":"GET","path":"/"}]}"#)
        let errors = check(s).errors.joined(separator: "\n")
        #expect(errors.contains("name 'bad name'"))
        #expect(errors.contains("'a b'"))
        #expect(errors.contains("'z'"))
    }

    @Test("Path must start with / and carry no host")
    func paths() {
        #expect(check(scenario(readScenario("p", path: "api/x"))).errors.contains { $0.contains("must start with '/'") })
        #expect(check(scenario(readScenario("p", path: "/https://evil"))).errors.contains { $0.contains("no host") })
    }

    @Test("A call checks existence, inputs, returns, actors and secret slots")
    func callContract() {
        let callee = scenario("""
        {"name":"make","description":"d","mutates":true,"actors":["u"],"secrets":["cl"],
         "inputs":[{"name":"title"},{"name":"prio","default":"1"}],
         "steps":[{"id":"c","as":"u","method":"POST","path":"/i","headers":{"C":"{{secret:cl.value}}"},"extract":{"issueId":"json:id"}}],
         "returns":["issueId"]}
        """)
        let good = scenario("""
        {"name":"top","description":"d","mutates":true,"actors":["me"],"secrets":["cl"],
         "steps":[{"id":"m","call":"make","as":"me","with":{"title":"t"},"returns":["issueId"]},
                  {"id":"g","as":"me","method":"GET","path":"/i/{{var:m.issueId}}"}]}
        """)
        #expect(check(good, others: [callee]).isValid, "\(check(good, others: [callee]).errors)")

        let bad = scenario("""
        {"name":"top","description":"d","mutates":true,"actors":["me"],
         "steps":[{"id":"m","call":"make","with":{"oops":"1"},"returns":["nothing"]},
                  {"id":"n","call":"missing"}]}
        """)
        let errors = check(bad, others: [callee]).errors.joined(separator: "\n")
        #expect(errors.contains("no input 'oops'"))
        #expect(errors.contains("required input 'title'"))
        #expect(errors.contains("does not return 'nothing'"))
        #expect(errors.contains("secret slot 'cl'"))
        #expect(errors.contains("acts as 'u'"))
        #expect(errors.contains("'missing' does not exist"))
    }

    @Test("A callee that writes makes its caller need mutates")
    func mutatesPropagates() {
        let callee = scenario(#"{"name":"w","description":"d","mutates":true,"steps":[{"id":"s","method":"POST","path":"/x"}]}"#)
        let caller = scenario(#"{"name":"c","description":"d","steps":[{"id":"k","call":"w"}]}"#)
        #expect(check(caller, others: [callee]).errors.contains { $0.contains("mutates") })
    }

    @Test("Cycles are refused, also indirect ones")
    func cycles() {
        let a = scenario(#"{"name":"a","description":"d","steps":[{"id":"k","call":"b"}]}"#)
        let b = scenario(#"{"name":"b","description":"d","steps":[{"id":"k","call":"c"}]}"#)
        let c = scenario(#"{"name":"c","description":"d","steps":[{"id":"k","call":"a"}]}"#)
        #expect(check(a, others: [b, c]).errors.contains { $0.contains("cycle") })
        let selfCall = scenario(#"{"name":"s","description":"d","steps":[{"id":"k","call":"s"}]}"#)
        #expect(check(selfCall).errors.contains { $0.contains("cycle") })
    }

    @Test("Depth: five scenarios in a chain pass, six do not")
    func depth() {
        func chain(_ n: Int) -> [CurlScenario] {
            (1...n).map { i in
                i == n ? scenario(readScenario("s\(i)"))
                       : scenario(#"{"name":"s\#(i)","description":"d","steps":[{"id":"k","call":"s\#(i + 1)"}]}"#)
            }
        }
        let five = chain(5)
        #expect(check(five[0], others: Array(five.dropFirst())).isValid)
        #expect(check(five[0], others: Array(five.dropFirst())).depth == 5)
        let six = chain(6)
        #expect(check(six[0], others: Array(six.dropFirst())).errors.contains { $0.contains("deep") })
    }

    @Test("returns must name something a step produces")
    func returnsContract() {
        let s = scenario(#"{"name":"r","description":"d","returns":["ghost"],"steps":[{"id":"s","method":"GET","path":"/"}]}"#)
        #expect(check(s).errors.contains { $0.contains("'ghost'") })
    }

    @Test("Step ids are unique across steps and cleanup")
    func duplicateIds() {
        let s = scenario(#"{"name":"d","description":"d","steps":[{"id":"a","method":"GET","path":"/"}],"cleanup":[{"id":"a","method":"GET","path":"/"}]}"#)
        #expect(check(s).errors.contains { $0.contains("used twice") })
    }

    @Test("A stray {{ is reported")
    func malformedPlaceholder() {
        let s = scenario(readScenario("m", path: "/x/{{oops}}"))
        #expect(check(s).errors.contains { $0.contains("'{{'") })
    }
}
