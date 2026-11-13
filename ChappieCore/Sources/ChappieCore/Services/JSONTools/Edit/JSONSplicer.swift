// JSONSplicer.swift
// ChappieCore
//
// The heart of json_edit's safety: every change is a splice "replace bytes start..<end of the ORIGINAL
// file with this text". The result is built by copying the original between the splices, so every byte
// outside them is identical by construction, not by comparison.

import Foundation

struct JSONSplice {
    let start: Int
    let end: Int
    let text: [UInt8]
    /// Numbers of the edits that produced it (a run of deletions comes from several).
    let ops: [Int]

    var isInsertion: Bool { start == end }
}

enum JSONSplicer {

    /// Orders the splices and applies them. Two edits that touch the same place are refused:
    /// guessing which one wins would be a silent change the model never asked for.
    static func apply(_ input: [JSONSplice], to bytes: [UInt8]) throws -> (bytes: [UInt8], ordered: [JSONSplice]) {
        let sorted = input.sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            if left.end != right.end { return left.end < right.end }
            return (left.ops.first ?? 0) < (right.ops.first ?? 0)
        }
        var previous: JSONSplice?
        for splice in sorted {
            if let before = previous,
               splice.start < before.end || (splice.isInsertion && before.isInsertion && splice.start == before.start) {
                throw JSONToolError(
                    "edits \(numbers(before.ops)) and \(numbers(splice.ops)) change the same place, so the order would matter. "
                    + "Apply them in two separate calls."
                )
            }
            previous = splice
        }

        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + sorted.reduce(0) { $0 + $1.text.count })
        var cursor = 0
        for splice in sorted {
            out.append(contentsOf: bytes[cursor..<splice.start])
            out.append(contentsOf: splice.text)
            cursor = splice.end
        }
        out.append(contentsOf: bytes[cursor...])
        return (out, sorted)
    }

    static func numbers(_ ops: [Int]) -> String {
        ops.map(String.init).joined(separator: ",")
    }
}
