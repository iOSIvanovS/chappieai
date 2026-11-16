// MemoryEntryPresentation.swift
// ChappieCore
//
// What the memory editor shows for one entry, beyond the text the agent reads.
//
// WHY THIS EXISTS:
// The system prompt carries only MemoryEntry.promptDisplayValue — one field of a multi-field
// record. The editor shows exactly that text (what influences the agent), and offers the full
// JSON only when fields are actually hidden. Otherwise the user could delete a record while
// seeing less than the stored data, or be shown a raw JSON wrapper that adds nothing.

import Foundation

// MARK: - MemoryEntryPresentation

public enum MemoryEntryPresentation {

    /// Pretty-printed full JSON of the entry, or nil when nothing is hidden behind the displayed text.
    ///
    /// Fields are hidden only when the payload is a JSON object with more than one key:
    /// a plain string, a non-object value or a single-key object is already shown in full.
    public static func hiddenFieldsJSON(for entry: MemoryEntry) -> String? {
        guard let data = entry.jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count > 1
        else {
            return nil
        }

        // sortedKeys keeps the layout identical on every opening; slashes stay readable.
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let pretty = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }
}
