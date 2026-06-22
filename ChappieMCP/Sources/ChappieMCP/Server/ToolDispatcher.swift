// ToolDispatcher.swift
//
// Routes tool calls to the appropriate handler classes.
//
// Both git_* and build_project/run_tests use projectPathMap to resolve per-project paths.
// build_project/run_tests additionally use projectEnvMap to pick the correct build tool.

import Foundation

final class ToolDispatcher: Sendable {
    private let gitTools: GitTools
    private let buildTools: BuildTools
    private let locTools: LocalizationTools
    private let docTools: DocumentTools

    init(projectPath: String, projectEnvMap: [String: String], projectPathMap: [String: String] = [:]) {
        self.gitTools   = GitTools(projectPath: projectPath, projectPathMap: projectPathMap)
        // WHY projectPathMap here: BuildTools must run xcodebuild in the correct project directory.
        // Without it, xcodeProjectName() scans defaultProjectPath and finds the wrong .xcodeproj.
        self.buildTools = BuildTools(projectPath: projectPath, projectEnvMap: projectEnvMap, projectPathMap: projectPathMap)
        self.locTools   = LocalizationTools(projectPath: projectPath, projectPathMap: projectPathMap)
        self.docTools   = DocumentTools(projectPath: projectPath, projectPathMap: projectPathMap)
    }

    func execute(tool: String, args: [String: String]) async -> ToolResult {
        switch tool {

        // MARK: - Git tools
        // "project" arg resolves the correct working directory via projectPathMap.

        case "git_status":
            return await gitTools.status(projectName: args["project"])

        case "git_add":
            let paths = args["paths"] ?? "."
            return await gitTools.add(paths: paths, projectName: args["project"])

        case "git_commit":
            guard let message = args["message"], !message.isEmpty else {
                return .failure("Argument 'message' is required for git_commit")
            }
            return await gitTools.commit(message: message, projectName: args["project"])

        case "git_push":
            let remote = args["remote"] ?? "origin"
            let branch = args["branch"] ?? "main"
            return await gitTools.push(remote: remote, branch: branch, projectName: args["project"])

        case "git_log":
            let count = Int(args["count"] ?? "10") ?? 10
            return await gitTools.log(count: count, projectName: args["project"])

        case "git_reset":
            return await gitTools.reset(projectName: args["project"])

        case "git_revert":
            guard let hashes = args["hashes"], !hashes.isEmpty else {
                return .failure("Argument 'hashes' is required (space-separated commit hashes)")
            }
            let message = args["message"] ?? "revert: roll back commits \(args["hashes"] ?? "")"
            return await gitTools.revert(hashes: hashes, message: message, projectName: args["project"])

        case "git_checkout":
            guard let ref = args["ref"], !ref.isEmpty else {
                return .failure("Argument 'ref' is required (e.g. HEAD~1, abc123, main)")
            }
            guard let paths = args["paths"], !paths.isEmpty else {
                return .failure("Argument 'paths' is required (space-separated file paths)")
            }
            return await gitTools.checkout(ref: ref, paths: paths, projectName: args["project"])

        // MARK: - Build tools
        // "project" arg routes to the correct env (projectEnvMap) and path (projectPathMap).

        case "build_project":
            return await buildTools.build(projectName: args["project"])

        case "run_tests":
            return await buildTools.runTests(projectName: args["project"], target: args["target"])

        case "read_build_log":
            return await buildTools.readLastLog()

        // MARK: - Document tools

        case "read_document":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'contract.docx')")
            }
            return docTools.readDocument(relativePath: path, projectName: args["project"])

        case "write_document":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required")
            }
            guard let content = args["content"], !content.isEmpty else {
                return .failure("Argument 'content' is required (full XML or text content)")
            }
            return docTools.writeDocument(
                relativePath: path,
                xmlContent: content,
                outputPath: args["output_path"],
                entryName: args["entry_name"],
                projectName: args["project"]
            )

        // MARK: - Localization tools

        case "loc_info":
            return locTools.info()

        case "loc_create":
            guard let path = args["path"], !path.isEmpty else {
                return .failure("Argument 'path' is required (e.g. 'Chappie/Localizable.xcstrings')")
            }
            return locTools.create(relativePath: path, sourceLanguage: args["sourceLanguage"] ?? "en")

        case "loc_rename":
            guard let from = args["from"], !from.isEmpty else { return .failure("Argument 'from' is required") }
            guard let to = args["to"], !to.isEmpty else { return .failure("Argument 'to' is required") }
            return locTools.rename(fromRelativePath: from, toRelativePath: to)

        case "loc_delete":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.delete(relativePath: path)

        case "loc_add_language":
            guard let language = args["language"], !language.isEmpty else {
                return .failure("Argument 'language' is required (e.g. 'ru', 'de', 'zh-Hans')")
            }
            return locTools.addLanguage(language: language, relativePath: args["path"])

        case "loc_remove_language":
            guard let language = args["language"], !language.isEmpty else {
                return .failure("Argument 'language' is required")
            }
            return locTools.removeLanguage(language: language, relativePath: args["path"])

        case "loc_key_check":
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.keyCheck(key: key, relativePath: path)

        case "loc_next_batch":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.nextBatch(relativePath: path)

        case "loc_submit_batch":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let translations = args["translations"], !translations.isEmpty else {
                return .failure("Argument 'translations' is required (JSON: {\"key\": {\"ru\": \"...\", \"de\": \"...\"}})")
            }
            return locTools.submitBatch(relativePath: path, translationsJSON: translations)

        case "loc_dead_keys":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.deadKeys(relativePath: path)

        case "loc_add_key":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            guard let value = args["value"], !value.isEmpty else { return .failure("Argument 'value' is required (English text)") }
            return locTools.addKey(relativePath: path, key: key, englishValue: value, comment: args["comment"])

        case "loc_remove_key":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let key = args["key"], !key.isEmpty else { return .failure("Argument 'key' is required") }
            return locTools.removeKey(relativePath: path, key: key)

        case "loc_rename_key":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let oldKey = args["old_key"], !oldKey.isEmpty else { return .failure("Argument 'old_key' is required") }
            guard let newKey = args["new_key"], !newKey.isEmpty else { return .failure("Argument 'new_key' is required") }
            return locTools.renameKey(relativePath: path, oldKey: oldKey, newKey: newKey)

        case "loc_rename_keys":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            guard let renames = args["renames"], !renames.isEmpty else {
                return .failure("Argument 'renames' is required (JSON array: [{\"old_key\": \"...\", \"new_key\": \"...\"}])")
            }
            return locTools.renameKeys(relativePath: path, renamesJSON: renames)

        case "loc_list_keys":
            guard let path = args["path"], !path.isEmpty else { return .failure("Argument 'path' is required") }
            return locTools.listKeys(relativePath: path, filter: args["filter"])

        default:
            return .failure("Unknown tool: \(tool).")
        }
    }
}
