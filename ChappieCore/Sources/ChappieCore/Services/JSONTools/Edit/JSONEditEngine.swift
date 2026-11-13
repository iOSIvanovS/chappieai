// JSONEditEngine.swift
// ChappieCore
//
// Pure core of json_edit: bytes + the `edits` text in, the new bytes + a report out. No file system.
// The order of work is the safety net:
//   1. parse the file, read the operations, plan splices over the original bytes (all problems at once);
//   2. build the result by copying the original between the splices;
//   3. prove it: every byte outside the splices is the original, the result parses as JSON, every edited
//      place holds exactly what was asked for, no duplicate key appeared;
//   4. only then hand the bytes to the caller. Any failed proof means "nothing was written".

import Foundation

enum JSONEditEngine {

    struct Outcome {
        let text: String
        /// Set only when the file must be written (never on a dry run, a no-op or a failure).
        let newData: Data?
    }

    static let toolName = "json_edit"

    static func run(data: Data, fileName: String, editsText: String, dryRun: Bool, maxChars: Int) -> Outcome {
        do {
            if let problem = JSONToolEngine.encodingProblem(data) { return failure(problem) }
            let doc: JSONDocument
            do {
                doc = try JSONDocument.parse(data)
            } catch let error as JSONParseError {
                return failure("\(fileName) is not valid JSON, so it cannot be edited safely. \(error.errorDescription ?? error.message)")
            }
            let ops = try JSONEditParser.parse(editsText)

            var planner = JSONEditPlanner(doc: doc, style: JSONStyle.detect(doc))
            planner.plan(ops)
            if !planner.problems.isEmpty {
                let list = planner.problems.map { "- \($0)" }.joined(separator: "\n")
                return failure("nothing was changed, \(JSONText.plural(planner.problems.count, "problem", "problems")):\n\(list)", maxChars: maxChars)
            }
            if planner.splices.isEmpty {
                let why = planner.notes.map { "- \($0)" }.joined(separator: "\n")
                return Outcome(text: "No change: \(fileName) already holds everything the edits ask for. Nothing was written.\n\(why)", newData: nil)
            }

            let (result, ordered) = try JSONSplicer.apply(planner.splices, to: doc.bytes)
            if let reason = verify(original: doc, result: result, ordered: ordered, checks: planner.checks) {
                return failure("the result did not pass the safety check, so NOTHING was written. \(reason)")
            }
            let report = JSONEditReport.make(
                fileName: fileName, original: doc, result: result, ordered: ordered,
                notes: planner.notes, opCount: ops.count, dryRun: dryRun, maxChars: maxChars
            )
            return Outcome(text: report, newData: dryRun ? nil : Data(result))
        } catch {
            return failure(error.localizedDescription, maxChars: maxChars)
        }
    }

    private static func failure(_ message: String, maxChars: Int = JSONOutput.defaultChars) -> Outcome {
        Outcome(text: JSONOutput.fit("Error: \(message)", maxChars: maxChars, hint: "Fix the first problems and call again."), newData: nil)
    }

    // MARK: Proof

    /// nil when the result is sound, otherwise what is wrong.
    static func verify(original: JSONDocument, result: [UInt8], ordered: [JSONSplice], checks: [JSONEditCheck]) -> String? {
        if !outsideUntouched(original: original.bytes, result: result, ordered: ordered) {
            return "A byte outside the edited places differs from the original."
        }
        let after: JSONDocument
        do {
            after = try JSONDocument.parse(Data(result))
        } catch {
            return "The result is not valid JSON: \((error as? JSONParseError)?.errorDescription ?? error.localizedDescription)"
        }
        if after.facts.hasDuplicateKeys && !original.facts.hasDuplicateKeys {
            return "The edit would create a duplicate key."
        }
        let written = Set(checks.compactMap { check -> String? in
            if case .value(let path, _, _) = check { return JSONPathSegment.render(path) }
            return nil
        })
        for check in checks {
            switch check {
            case .value(let path, let expected, let op):
                let hits = after.resolve(path)
                guard hits.count == 1, JSONValueEquality.equal(after, hits[0], expected.doc, expected.node) else {
                    return "After edit \(op), \(JSONPathSegment.render(path)) does not hold the requested value."
                }
            case .absent(let path, let op):
                // Another operation may legitimately put a value at the very same path (rename a, insert a).
                if written.contains(JSONPathSegment.render(path)) { continue }
                if !after.resolve(path).isEmpty {
                    return "After edit \(op), \(JSONPathSegment.render(path)) is still there."
                }
            }
        }
        return nil
    }

    /// Copies of the original between the splices must be identical in the result.
    static func outsideUntouched(original: [UInt8], result: [UInt8], ordered: [JSONSplice]) -> Bool {
        var from = 0, into = 0
        for splice in ordered {
            let length = splice.start - from
            guard length >= 0, into + length <= result.count,
                  original[from..<splice.start] == result[into..<(into + length)] else { return false }
            into += length + splice.text.count
            from = splice.end
        }
        guard into <= result.count else { return false }
        return original[from...] == result[into...]
    }
}

// MARK: - Arguments

enum JSONEditArguments {

    /// The `edits` text exactly as the model wrote it. The flat argument map re-encodes arrays with
    /// sorted keys, which would reorder the keys of every new object; the raw call text does not.
    static func editsText(raw: Data, fallback: String?) -> String? {
        var root = try? JSONDocument.parse(raw)
        // Some models encode the whole argument object twice: unwrap it once.
        if let doc = root, doc.rootNode.kind == .string, let inner = doc.stringValue(of: doc.root) {
            root = try? JSONDocument.parse(inner)
        }
        if let doc = root, doc.rootNode.kind == .object, let node = doc.member("edits", of: doc.root) {
            switch doc.nodes[node].kind {
            case .array, .object: return doc.rawText(of: node)
            case .string: return doc.stringValue(of: node)
            default: break
            }
        }
        return fallback
    }
}
