// JSONEditReport.swift
// ChappieCore
//
// The answer of json_edit: what changed, in the file's own lines, small enough to read at a glance.
// A dry run uses the same report, so the model sees exactly what a real call would do.

import Foundation

enum JSONEditReport {

    private static let maxPlaces = 20
    private static let maxOldLines = 4
    private static let maxNewLines = 6
    private static let maxLineChars = 140

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

        var delta = 0
        for (offset, splice) in ordered.enumerated() {
            let newStart = splice.start + delta
            delta += splice.text.count - (splice.end - splice.start)
            guard offset < maxPlaces else { continue }

            let oldRange = lineBounds(original.bytes, from: splice.start, to: splice.end)
            let newRange = lineBounds(result, from: newStart, to: newStart + splice.text.count)
            let first = original.lineNumber(at: oldRange.start)
            let last = original.lineNumber(at: max(oldRange.start, oldRange.end - 1))
            let oldLines = lines(original.bytes, oldRange)
            let newLines = lines(result, newRange)
            let span = first == last ? "L\(first)" : "L\(first)-L\(last)"
            out.append("  edit \(JSONSplicer.numbers(splice.ops)) · \(span)")
            for line in oldLines.prefix(maxOldLines) { out.append("    - \(shorten(line))") }
            if oldLines.count > maxOldLines { out.append("    - … \(oldLines.count - maxOldLines) more lines") }
            for line in newLines.prefix(maxNewLines) { out.append("    + \(shorten(line))") }
            if newLines.count > maxNewLines { out.append("    + … \(newLines.count - maxNewLines) more lines") }
        }
        if ordered.count > maxPlaces { out.append("  … and \(ordered.count - maxPlaces) more places") }

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
