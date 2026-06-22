// LocalizationTools+Translation.swift
//
// WHY: Batch translation workflow — next_batch hands out keys, submit_batch writes results.
// BATCH STATE: stored in /tmp/chappie_loc_batch_state.json to survive between tool calls.
// BATCH SIZE: 100 / number of target languages — never more than 100 translations per call.

import Foundation

extension LocalizationTools {

    // MARK: - loc_next_batch

    /// Returns the next batch of keys needing translation.
    func nextBatch(relativePath: String) -> ToolResult {
        let fullPath = resolveFullPath(relativePath)

        guard let xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        let sourceLanguage = xcstrings.sourceLanguage

        var allLanguages = Set<String>()
        for (_, entry) in xcstrings.strings {
            for lang in (entry.localizations ?? [:]).keys {
                allLanguages.insert(lang)
            }
        }
        let targetLanguages = allLanguages.subtracting([sourceLanguage]).sorted()

        if targetLanguages.isEmpty {
            return .success("No target languages found. Use loc_add_language to add languages.")
        }

        let state = loadBatchState()
        let handedOut = state.handedOutKeys[relativePath] ?? []

        var needsTranslation: [(key: String, missingLangs: [String])] = []

        for key in xcstrings.strings.keys.sorted() {
            if handedOut.contains(key) { continue }

            let entry = xcstrings.strings[key]!
            let locs = entry.localizations ?? [:]

            let missing = targetLanguages.filter { lang in
                guard let loc = locs[lang],
                      let unit = loc.stringUnit else { return true }
                return unit.value.isEmpty || unit.state != "translated"
            }

            if !missing.isEmpty {
                needsTranslation.append((key: key, missingLangs: missing))
            }
        }

        if needsTranslation.isEmpty {
            // All done — reset state for next round
            var newState = state
            newState.handedOutKeys[relativePath] = []
            saveBatchState(newState)
            return .success("🎉 All keys are translated in \(relativePath)!\nBatch state reset — you can start a new round.")
        }

        let batchSize = max(1, 100 / targetLanguages.count)
        let batch = Array(needsTranslation.prefix(batchSize))

        var newState = state
        var newHandedOut = handedOut
        for item in batch { newHandedOut.append(item.key) }
        newState.handedOutKeys[relativePath] = newHandedOut
        saveBatchState(newState)

        var report = "📋 Next batch: \(batch.count) keys × \(targetLanguages.count) languages = up to \(batch.count * targetLanguages.count) translations\n"
        report += "File: \(relativePath)\n"
        report += "Target languages: \(targetLanguages.joined(separator: ", "))\n\n"
        report += "Keys to translate:\n\n"

        for item in batch {
            let sourceValue = xcstrings.strings[item.key]?.localizations?[sourceLanguage]?.stringUnit?.value ?? item.key
            report += "KEY: \"\(item.key)\"\n"
            report += "  EN: \"\(sourceValue)\"\n"
            report += "  Missing: \(item.missingLangs.joined(separator: ", "))\n\n"
        }

        report += "---\n"
        report += "Remaining after this batch: \(needsTranslation.count - batch.count) keys\n"
        report += "Use loc_submit_batch to submit translations for these keys."

        return .success(report)
    }

    // MARK: - loc_submit_batch

    /// Accepts translations and writes them to the xcstrings file without duplicates.
    /// translations format: {"key": {"ru": "Translation", "de": "Übersetzung"}}
    func submitBatch(relativePath: String, translationsJSON: String) -> ToolResult {
        let fullPath = resolveFullPath(relativePath)

        guard var xcstrings = loadXCStrings(at: fullPath) else {
            return .failure("Failed to load: \(relativePath)")
        }

        guard let data = translationsJSON.data(using: .utf8),
              let translations = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return .failure("""
            Failed to parse translations JSON.
            Expected format:
            {
              "key1": {"ru": "Translation", "de": "Übersetzung"},
              "key2": {"ru": "Another", "de": "Anderer"}
            }
            """)
        }

        var added = 0
        var updated = 0
        var skipped = 0
        var notFound: [String] = []

        for (key, langValues) in translations {
            guard xcstrings.strings[key] != nil else {
                notFound.append(key)
                continue
            }

            if xcstrings.strings[key]?.localizations == nil {
                xcstrings.strings[key]?.localizations = [:]
            }

            for (lang, value) in langValues {
                let existing = xcstrings.strings[key]?.localizations?[lang]?.stringUnit?.value
                if existing == value {
                    skipped += 1
                    continue
                }

                let wasEmpty = existing == nil || existing!.isEmpty
                xcstrings.strings[key]?.localizations?[lang] = XCLocalization(
                    stringUnit: XCStringUnit(state: "translated", value: value)
                )
                if wasEmpty { added += 1 } else { updated += 1 }
            }
        }

        guard saveXCStrings(xcstrings, to: fullPath) else {
            return .failure("Failed to save \(relativePath)")
        }

        var report = "✅ Batch submitted to \(relativePath)\n"
        report += "   Added:   \(added)\n"
        report += "   Updated: \(updated)\n"
        report += "   Skipped (same value): \(skipped)\n"
        if !notFound.isEmpty {
            report += "   ⚠️ Keys not found (ignored): \(notFound.joined(separator: ", "))\n"
        }

        return .success(report)
    }

    // MARK: - Batch State

    struct BatchState: Codable {
        var handedOutKeys: [String: [String]] = [:]
    }

    func loadBatchState() -> BatchState {
        guard let data = FileManager.default.contents(atPath: batchStatePath),
              let state = try? JSONDecoder().decode(BatchState.self, from: data) else {
            return BatchState()
        }
        return state
    }

    func saveBatchState(_ state: BatchState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: batchStatePath))
    }
}
