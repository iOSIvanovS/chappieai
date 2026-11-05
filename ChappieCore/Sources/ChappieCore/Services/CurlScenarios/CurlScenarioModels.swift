// CurlScenarioModels.swift
// ChappieCore
//
// Curl-Chappie scenarios: a named, repeatable chain of HTTP steps stored as a JSON file in the project.
// A scenario knows NO host and NO concrete secret name: it declares abstract slots (actors, secrets) and
// inputs, and the run supplies the host and the mapping. That keeps one file valid for every environment
// and for every developer's own secrets.
//
// Request parts reuse the engine's value types (CurlBody, CurlPair, CurlHeader, CurlExtractRule...).

import Foundation

// MARK: - Inputs and checks

public struct CurlScenarioInput: Sendable, Equatable {
    public var name: String
    public var description: String
    /// nil = the caller must supply it.
    public var defaultValue: String?

    public init(name: String, description: String = "", defaultValue: String? = nil) {
        self.name = name
        self.description = description
        self.defaultValue = defaultValue
    }

    public var isRequired: Bool { defaultValue == nil }
}

public struct CurlScenarioCheck: Sendable, Equatable {
    public enum Operation: Sendable, Equatable {
        case equals(String)
        case contains(String)
        case exists(Bool)
    }

    /// Same path syntax as `pick` / json extraction, e.g. `data.items[*].id`.
    public var path: String
    public var operation: Operation

    public init(path: String, operation: Operation) {
        self.path = path
        self.operation = operation
    }
}

public struct CurlScenarioExpect: Sendable, Equatable {
    /// Accepted HTTP statuses; empty = no status check.
    public var statuses: [Int]
    public var checks: [CurlScenarioCheck]

    public init(statuses: [Int] = [], checks: [CurlScenarioCheck] = []) {
        self.statuses = statuses
        self.checks = checks
    }

    public var isEmpty: Bool { statuses.isEmpty && checks.isEmpty }
}

// MARK: - Steps

/// A request step that signs in: its response feeds the session of the step's actor.
public struct CurlScenarioLogin: Sendable, Equatable {
    public var extract: [CurlExtractRule]
    public var apply: [CurlApplyRule]

    public init(extract: [CurlExtractRule], apply: [CurlApplyRule] = []) {
        self.extract = extract
        self.apply = apply
    }
}

public struct CurlScenarioRequest: Sendable, Equatable {
    public var method: String
    /// Path on the run's host; starts with "/". May hold placeholders.
    public var path: String
    public var query: [CurlPair]
    public var headers: [CurlHeader]
    public var body: CurlBody?
    public var login: CurlScenarioLogin?
    /// Values saved into the scenario's variables ({{var:name}}) for later steps.
    public var extract: [CurlExtractRule]

    public init(
        method: String, path: String, query: [CurlPair] = [], headers: [CurlHeader] = [],
        body: CurlBody? = nil, login: CurlScenarioLogin? = nil, extract: [CurlExtractRule] = []
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.login = login
        self.extract = extract
    }
}

/// Runs another scenario of the same folder. Only `with` goes in and only `returns` comes out.
public struct CurlScenarioCall: Sendable, Equatable {
    public var scenario: String
    /// Callee actor -> caller actor, when `as` was written as an object (several callee actors).
    public var actorMap: [String: String]
    public var with: [CurlPair]
    /// Callee outputs, visible to the caller as {{var:<stepId>.<name>}}.
    public var returns: [String]

    public init(scenario: String, actorMap: [String: String] = [:], with: [CurlPair] = [], returns: [String] = []) {
        self.scenario = scenario
        self.actorMap = actorMap
        self.with = with
        self.returns = returns
    }
}

public struct CurlScenarioStep: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case request(CurlScenarioRequest)
        case call(CurlScenarioCall)
    }

    public var id: String
    public var note: String
    /// Actor the step acts as ("as": a single name). nil = anonymous request.
    public var actor: String?
    public var expect: CurlScenarioExpect
    public var action: Action

    public init(id: String, note: String = "", actor: String? = nil, expect: CurlScenarioExpect = CurlScenarioExpect(), action: Action) {
        self.id = id
        self.note = note
        self.actor = actor
        self.expect = expect
        self.action = action
    }

    public var request: CurlScenarioRequest? {
        if case .request(let r) = action { return r }
        return nil
    }

    public var call: CurlScenarioCall? {
        if case .call(let c) = action { return c }
        return nil
    }
}

// MARK: - Scenario

public struct CurlScenario: Sendable, Equatable {
    /// Letters/digits/_/- ; equals the file name without ".json".
    public var name: String
    public var description: String
    /// True when the run creates or changes data (any non-login write, or a call to such a scenario).
    public var mutates: Bool
    /// Abstract users that act in steps; each is mapped to a project secret with login+password at run time.
    public var actors: [String]
    /// Other secret slots used by {{secret:slot.field}} (client id, salt...).
    public var secrets: [String]
    public var inputs: [CurlScenarioInput]
    public var steps: [CurlScenarioStep]
    /// Names of extract variables handed to the caller.
    public var returns: [String]
    /// Runs after the ROOT scenario only (also after a failure). Cleanup of nested scenarios never runs.
    public var cleanup: [CurlScenarioStep]

    public init(
        name: String, description: String, mutates: Bool = false,
        actors: [String] = [], secrets: [String] = [], inputs: [CurlScenarioInput] = [],
        steps: [CurlScenarioStep], returns: [String] = [], cleanup: [CurlScenarioStep] = []
    ) {
        self.name = name
        self.description = description
        self.mutates = mutates
        self.actors = actors
        self.secrets = secrets
        self.inputs = inputs
        self.steps = steps
        self.returns = returns
        self.cleanup = cleanup
    }

    public var allSteps: [CurlScenarioStep] { steps + cleanup }

    /// Distinct names of directly called scenarios, in first-use order.
    public var calledScenarios: [String] {
        var seen = Set<String>()
        return allSteps.compactMap { $0.call?.scenario }.filter { seen.insert($0).inserted }
    }

    /// Slots a {{secret:slot.field}} reference may name.
    public var secretSlots: Set<String> { Set(actors).union(secrets) }
}
