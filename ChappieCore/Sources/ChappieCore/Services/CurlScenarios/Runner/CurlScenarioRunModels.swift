// CurlScenarioRunModels.swift
// ChappieCore
//
// Value types of a scenario RUN: what the caller asks for, the scope a scenario executes in, and how
// the actors/secret slots of a callee are bound to the caller's real secrets.
//
// A scenario knows only abstract slots (`user`, `clientId`); the run maps each slot to the NAME of a
// project secret bound to the chosen host. Values never pass through here: the engine resolves them.

import Foundation

public struct CurlScenarioRunRequest: Sendable, Equatable {
    public var scenario: String
    /// Host name from the thread table, or its origin.
    public var host: String
    /// Actor slot -> secret name (login+password). A slot without an entry falls back to a secret of the same name.
    public var actors: [String: String]
    /// Other slot -> secret name, same fallback.
    public var secrets: [String: String]
    public var inputs: [String: String]
    /// Show the response body of passing steps too.
    public var verbose: Bool
    /// Check everything that can be checked without sending a request, then stop.
    public var dryRun: Bool

    public init(
        scenario: String, host: String, actors: [String: String] = [:], secrets: [String: String] = [:],
        inputs: [String: String] = [:], verbose: Bool = false, dryRun: Bool = false
    ) {
        self.scenario = scenario
        self.host = host
        self.actors = actors
        self.secrets = secrets
        self.inputs = inputs
        self.verbose = verbose
        self.dryRun = dryRun
    }
}

public struct CurlScenarioRunReport: Sendable, Equatable {
    public var text: String
    /// True when nothing was sent because the preflight (or the arguments) refused the run.
    public var refused: Bool
    /// All main steps passed. False for a refused run.
    public var passed: Bool
    public var requestsSent: Int
}

/// A scenario variable. Sensitive ones are masked in every report line.
struct CurlScenarioValue: Sendable, Equatable {
    var text: String
    var sensitive: Bool
}

/// One scenario being executed: its own slots, inputs and variables. A callee gets a fresh scope.
struct CurlScenarioScope {
    var scenario: CurlScenario
    /// Actor slot -> real secret name.
    var actors: [String: String]
    /// Secret slot -> real secret name.
    var secrets: [String: String]
    var inputs: [String: String]
    var vars: [String: CurlScenarioValue] = [:]

    /// Every slot a {{secret:slot.field}} reference may name.
    var slots: [String: String] { actors.merging(secrets) { first, _ in first } }
}

enum CurlScenarioBindings {

    struct Child {
        var actors: [String: String]
        var secrets: [String: String]
    }

    /// Maps the callee's actor and secret slots onto the caller's real secrets, following the call's `as`.
    static func child(
        call: CurlScenarioCall, step: CurlScenarioStep, callee: CurlScenario,
        parentActors: [String: String], parentSecrets: [String: String]
    ) -> Result<Child, BindingError> {
        var actors: [String: String] = [:]
        if callee.actors.count == 1, let only = callee.actors.first {
            guard let callerActor = step.actor ?? call.actorMap[only] else {
                return .failure(BindingError("'\(call.scenario)' acts as '\(only)'; the call has no \"as\"."))
            }
            guard let real = parentActors[callerActor] else {
                return .failure(BindingError("actor '\(callerActor)' is not mapped to a secret, so '\(call.scenario)' cannot act as it."))
            }
            actors[only] = real
        } else {
            for actor in callee.actors {
                guard let callerActor = call.actorMap[actor], let real = parentActors[callerActor] else {
                    return .failure(BindingError("callee actor '\(actor)' of '\(call.scenario)' is not mapped to an actor of the caller."))
                }
                actors[actor] = real
            }
        }
        var secrets: [String: String] = [:]
        for slot in callee.secrets {
            guard let real = parentSecrets[slot] else {
                return .failure(BindingError("secret slot '\(slot)' needed by '\(call.scenario)' is not mapped."))
            }
            secrets[slot] = real
        }
        return .success(Child(actors: actors, secrets: secrets))
    }

    struct BindingError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

extension CurlScenarioStep {
    /// Every text of the step that may hold a {{...}} placeholder (login.apply templates are the engine's own).
    var templateTexts: [String] {
        var texts: [String] = []
        for check in expect.checks {
            switch check.operation {
            case .equals(let value), .contains(let value): texts.append(value)
            case .exists: break
            }
        }
        switch action {
        case .request(let r):
            texts += [r.path] + r.query.map(\.value) + r.headers.map(\.value)
            switch r.body {
            case .json(let text), .text(let text, _): texts.append(text)
            case .form(let pairs): texts += pairs.map(\.value)
            case nil: break
            }
        case .call(let c):
            texts += c.with.map(\.value)
        }
        return texts
    }
}
