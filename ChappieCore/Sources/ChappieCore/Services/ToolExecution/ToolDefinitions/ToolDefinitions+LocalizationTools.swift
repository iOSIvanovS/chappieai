// ToolDefinitions+LocalizationTools.swift
// ChappieCore
//
// Localization tool definitions. Injected only when at least one Xcode project is attached.

import Foundation

extension ToolExecutionService {

    func localizationTools() -> [AITool] {
        let pathArg = AIToolProperty(type: "string", description: "Relative path to the .xcstrings file (e.g. 'Chappie/Localizable.xcstrings')")
        let keyArg  = AIToolProperty(type: "string", description: "Localization key string")

        return [
            AITool(function: AIFunctionDefinition(
                name: "loc_info",
                description: "Returns a map of all .xcstrings files in the project with per-language coverage stats.\nUse at the start of any localization session to understand current state.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_create",
                description: "Create a new .xcstrings localization file at the given path. Standard path: 'Chappie/Localizable.xcstrings'.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Relative path for the new file (e.g. 'Chappie/Localizable.xcstrings')"),
                        "sourceLanguage": AIToolProperty(type: "string", description: "Source language code (default: 'en')")
                    ],
                    required: ["path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_rename",
                description: "Rename (move) a .xcstrings file. Remember to update the file reference in Xcode project navigator.",
                parameters: AIToolParameters(
                    properties: [
                        "from": AIToolProperty(type: "string", description: "Current relative path"),
                        "to": AIToolProperty(type: "string", description: "New relative path")
                    ],
                    required: ["from", "to"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_delete",
                description: "Delete a .xcstrings file. Remember to remove the reference from Xcode project navigator.",
                parameters: AIToolParameters(properties: ["path": pathArg], required: ["path"])
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_add_language",
                description: "Add a target language to a .xcstrings file (or all files if path is omitted). All existing keys will be marked for translation.",
                parameters: AIToolParameters(
                    properties: [
                        "language": AIToolProperty(type: "string", description: "Language code to add (e.g. 'ru', 'de', 'zh-Hans', 'ja')"),
                        "path": AIToolProperty(type: "string", description: "Relative path to specific .xcstrings file. Omit to apply to all files.")
                    ],
                    required: ["language"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_remove_language",
                description: "Remove a target language from a .xcstrings file (or all files if path is omitted). Cannot remove source language.",
                parameters: AIToolParameters(
                    properties: [
                        "language": AIToolProperty(type: "string", description: "Language code to remove"),
                        "path": AIToolProperty(type: "string", description: "Relative path to specific .xcstrings file. Omit to apply to all files.")
                    ],
                    required: ["language"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_key_check",
                description: "Check translation status for a specific key across all languages. Shows value and state per language.",
                parameters: AIToolParameters(
                    properties: ["key": keyArg, "path": pathArg],
                    required: ["key", "path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_next_batch",
                description: "Returns the next batch of keys needing translation.\nBatch size = 100 / number of target languages — never more than 100 translations per call.\nTracks state in /tmp so repeated calls return new keys, not the same ones.\nCall this before translating to know exactly what to translate next.",
                parameters: AIToolParameters(properties: ["path": pathArg], required: ["path"])
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_submit_batch",
                description: "Submit a batch of translations to the .xcstrings file.\nWrites translations without duplicates. Always sets state: \"translated\".\ntranslations format: JSON object {\"key\": {\"ru\": \"Перевод\", \"de\": \"Übersetzung\"}}",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "translations": AIToolProperty(type: "string", description: "JSON string: {\"key\": {\"lang\": \"value\", ...}, ...}")
                    ],
                    required: ["path", "translations"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_dead_keys",
                description: "Scans all .swift files in the project and reports which keys in the .xcstrings file\nare not referenced anywhere in code. Use to clean up unused translations.",
                parameters: AIToolParameters(properties: ["path": pathArg], required: ["path"])
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_add_key",
                description: "Add a new localization key with its English value. Use before submitting translations for new UI strings.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "key": keyArg,
                        "value": AIToolProperty(type: "string", description: "English text for this key"),
                        "comment": AIToolProperty(type: "string", description: "Optional context comment for translators")
                    ],
                    required: ["path", "key", "value"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_remove_key",
                description: "Remove a localization key and all its translations from the .xcstrings file.",
                parameters: AIToolParameters(
                    properties: ["path": pathArg, "key": keyArg],
                    required: ["path", "key"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_rename_key",
                description: "Rename a localization key, preserving all existing translations.\nUse to fix raw string keys (e.g. Russian literals) to proper dot-notation keys\nwithout losing any translations already submitted for that key.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "old_key": AIToolProperty(type: "string", description: "Current key name to rename"),
                        "new_key": AIToolProperty(type: "string", description: "New dot-notation key name (e.g. 'sidebar.title')")
                    ],
                    required: ["path", "old_key", "new_key"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_rename_keys",
                description: "Rename multiple localization keys in a single operation, preserving all translations.\nPREFER THIS over calling loc_rename_key repeatedly — the file is loaded once and saved once.\nUse to batch-fix raw string keys (Russian literals etc.) to proper dot-notation keys.\nrenames format: JSON array [{\"old_key\": \"...\", \"new_key\": \"sidebar.title\"}, ...]\nUp to 100 renames per call.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "renames": AIToolProperty(type: "string", description: "JSON array: [{\"old_key\": \"...\", \"new_key\": \"...\"}, ...]")
                    ],
                    required: ["path", "renames"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "loc_list_keys",
                description: "List all keys in a .xcstrings file with their English values.\nKeys that look like raw strings (non dot-notation) are marked with ⚠️.\nUse filter to narrow results by substring (e.g. filter: 'sidebar').\nEssential for auditing before batch rename operations.",
                parameters: AIToolParameters(
                    properties: [
                        "path": pathArg,
                        "filter": AIToolProperty(type: "string", description: "Optional substring filter — only keys containing this string are returned")
                    ],
                    required: ["path"]
                )
            ))
        ]
    }
}
