// JSONEditReport.swift
// ChappieCore
//
// The answer of json_edit: what changed, in the file's own lines, small enough to read at a glance.
// A dry run uses the same report, so the model sees exactly what a real call would do.
// The old side of an insertion is empty by definition: nothing was replaced there, and printing the
// neighbouring line as removed would read as data loss that never happened.
// Two lines are compared without their indent and without the comma that only separates them from
// their neighbours: json_edit moves those commas around, and counting them as a change would push
// the line that really changed out of the answer.

import Foundation

enum JSONEditReport {

    private static let maxPlaces = 20
    private static let maxOldLines = 4
    private static let maxNewLines = 6
    private static let maxLineChars = 140

    /// One printed place. Edits whose original lines touch are shown together: shown apart they
    /// print the same line once per edit, which looks like a second, invisible change.
    private struct Place {
        var ops: [Int]
        var old: (start: Int, end: Int)
        var new: (start: Int, end: Int)
        var added: [String]
        var hasOld: Bool
    }

    static func make(
        fileName: String, original: JSONDocument, result: [UInt8], ordered: [JSONSplice],
        notes: [String], opCount: Int, dryRun: Bool, maxChars: Int
    ) -> String {
        let lineCount = result.isEmpty ? 0 : result.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + (result.last == 0x0A ? 0 : 1)
        var out: [String] = []
        let verb = dryRun ? "DRY RUN, nothing was written. A real call would apply" : "Applied"
        out.append("\(verb) \(JSONText.plural(opCount, "edit", "edits")) to \(fileName) in \(JSONText.plural(ordered.count, "place", "places")): "
                   + "\(JSONText.size(original.bytes.count)) → \(JSONText.size(result.count)), "
                   + "\(JSONText.count(original.lineCount)) → \(JSONText.count(lineCount)) lines.")
        out.append("Every byte outside those places is identical to the original, and the result was parsed again and checked.")
        out.append("")
        out.append("Changes (line numbers are of the original file; - was, + is now):")

        let places = group(ordered, original: original, result: result)
        for (offset, place) in places.enumerated() {
            guard offset < maxPlaces else { break }

            let first = original.lineNumber(at: place.old.start)
            let last = original.lineNumber(at: max(place.old.start, place.old.end - 1))
            let span = first == last ? "L\(first)" : "L\(first)-L\(last)"

            var oldLines: [String] = []
            var newLines: [String] = []
            if place.hasOld {
                let compared = compare(
                    old: lines(original.bytes, place.old),
                    new: lines(result, place.new)
                )
                oldLines = compared.removed
                newLines = compared.added
            } else {
                newLines = place.added
            }

            out.append("  edit \(JSONSplicer.numbers(place.ops.sorted())) · \(span)")
            for line in oldLines.prefix(maxOldLines) { out.append("    - \(shorten(line))") }
            if oldLines.count > maxOldLines { out.append("    - … \(oldLines.count - maxOldLines) more lines") }
            for line in newLines.prefix(maxNewLines) { out.append("    + \(shorten(line))") }
            if newLines.count > maxNewLines { out.append("    + … \(newLines.count - maxNewLines) more lines") }
        }
        if places.count > maxPlaces { out.append("  … and \(places.count - maxPlaces) more places") }

        if !notes.isEmpty {
            out.append("")
            out.append("Notes:")
            out.append(contentsOf: notes.map { "- \($0)" })
        }
        if dryRun {
            out.append("")
            out.append("Repeat the call without dry_run to write it.")
        }
        return JSONOutput.fit(out.joined(separator: "\n"), maxChars: maxChars, hint: "Raise max_chars to see every place.")
    }

    // MARK: Places

    /// Walks the splices in their applied order and merges the ones whose original lines overlap.
    /// An insertion always stands alone: it has no old side, so joining it to a neighbouring change
    /// would hand that change's lines to a place that replaced nothing.
    private static func group(_ ordered: [JSONSplice], original: JSONDocument, result: [UInt8]) -> [Place] {
        var places: [Place] = []
        var delta = 0
        for splice in ordered {
            let newStart = splice.start + delta
            delta += splice.text.count - (splice.end - splice.start)
            let oldRange = lineBounds(original.bytes, from: splice.start, to: splice.end)
            let newRange = lineBounds(result, from: newStart, to: newStart + splice.text.count)

            if splice.isInsertion {
                places.append(Place(
                    ops: splice.ops, old: oldRange, new: newRange,
                    added: addedLines(splice.text), hasOld: false
                ))
                continue
            }

            if let lastIndex = places.indices.last, places[lastIndex].hasOld, oldRange.start < places[lastIndex].old.end {
                places[lastIndex].ops += splice.ops
                places[lastIndex].old.end = max(places[lastIndex].old.end, oldRange.end)
                places[lastIndex].new.start = min(places[lastIndex].new.start, newRange.start)
                places[lastIndex].new.end = max(places[lastIndex].new.end, newRange.end)
            } else {
                places.append(Place(ops: splice.ops, old: oldRange, new: newRange, added: [], hasOld: true))
            }
        }
        return places
    }

    /// The lines an insertion brings in, without the separators and indentation that glue them to
    /// the lines already there: those bytes belong to the neighbourhood, not to the new content.
    /// A separator can stand on a line of its own or be glued to the end of the last line, so both
    /// are handled — showing "}," would suggest the comma is part of what was added.
    private static func addedLines(_ text: [UInt8]) -> [String] {
        var parts = String(decoding: text, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { part -> String in
                part.hasSuffix("\r") ? String(part.dropLast()) : String(part)
            }
        if let first = parts.first, first.allSatisfy({ $0 == "," || $0 == " " || $0 == "\t" }) {
            parts.removeFirst()
        } else if let first = parts.first, first.hasPrefix(",") {
            parts[0] = String(first.dropFirst())
        }
        if let last = parts.last, last.allSatisfy({ $0 == "," || $0 == " " || $0 == "\t" }) {
            parts.removeLast()
        }
        if let last = parts.last, last.hasSuffix(",") {
            parts[parts.count - 1] = String(last.dropLast())
        }
        return parts
    }

    /// Drops the lines that read the same before and after, so a change inside an unchanged
    /// neighbourhood does not look like it rewrote that neighbourhood.
    private static func compare(old: [String], new: [String]) -> (removed: [String], added: [String]) {
        var head = 0
        while head < old.count, head < new.count, sameContent(old[head], new[head]) { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              sameContent(old[old.count - 1 - tail], new[new.count - 1 - tail]) { tail += 1 }
        guard head > 0 || tail > 0 else { return (old, new) }
        let removed = Array(old[head..<(old.count - tail)])
        let added = Array(new[head..<(new.count - tail)])
        // Everything trimmed away would mean the change is invisible in these lines; show them as
        // they are rather than print an empty place.
        guard !(removed.isEmpty && added.isEmpty) else { return (old, new) }
        return (removed, added)
    }

    /// Two lines with the same content, ignoring what belongs to the neighbourhood: the indentation,
    /// and the comma that only separates this member from the next one.
    private static func sameContent(_ left: String, _ right: String) -> Bool {
        func normalized(_ line: String) -> String {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(",") { text.removeLast() }
            return text.trimmingCharacters(in: .whitespaces)
        }
        return normalized(left) == normalized(right)
    }

    // MARK: Lines

    /// The byte range of the whole lines that contain [from, to).
    private static func lineBounds(_ bytes: [UInt8], from: Int, to: Int) -> (start: Int, end: Int) {
        var start = min(from, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = max(min(to, bytes.count), start)
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        return (start, end)
    }

    private static func lines(_ bytes: [UInt8], _ range: (start: Int, end: Int)) -> [String] {
        guard range.end > range.start else { return [] }
        return bytes[range.start..<range.end]
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { slice -> String in
                var line = slice
                if line.last == 0x0D { line = line.dropLast() }
                return String(decoding: line, as: UTF8.self)
            }
    }

    private static func shorten(_ line: String) -> String {
        let text = line.trimmingCharacters(in: .whitespaces)
        return JSONText.shorten(text.isEmpty ? "(blank line)" : text, limit: maxLineChars)
    }
}
