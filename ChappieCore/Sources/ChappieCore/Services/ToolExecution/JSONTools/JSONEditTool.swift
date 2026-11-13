// JSONEditTool.swift
// ChappieCore
//
// Executor of json_edit. Read the file, let the pure engine plan and prove the edit on a worker task,
// then write only if the file is still byte-identical to what was read.

import Foundation

extension ToolExecutionService {

    /// - Parameters:
    ///   - argsData: canonical flat arguments (project name already resolved).
    ///   - rawArgsData: the call exactly as the model sent it; the `edits` text is taken from it so
    ///     the order of keys inside new objects survives.
    func executeJSONEdit(argsData: Data, rawArgsData: Data) async -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
              let path = args["path"], !path.isEmpty else {
            return "Error: Argument 'path' is required for json_edit"
        }
        guard let editsText = JSONEditArguments.editsText(raw: rawArgsData, fallback: args["edits"]),
              !editsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: Argument 'edits' is required for json_edit. \(JSONEditParser.formatHint)"
        }
        let original: Data
        do {
            original = try await fileSystem.readData(at: path, projectName: args["project"], limit: JSONToolEngine.maxFileBytes)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let fileName = (path as NSString).lastPathComponent
        let dryRun = JSONToolArgs(values: args).bool("dry_run")
        let maxChars = JSONToolArgs(values: args).maxChars
        let outcome = await Task.detached(priority: .userInitiated) {
            JSONEditEngine.run(data: original, fileName: fileName, editsText: editsText, dryRun: dryRun, maxChars: maxChars)
        }.value

        guard let newData = outcome.newData else { return outcome.text }
        do {
            try await fileSystem.replaceData(at: path, projectName: args["project"], original: original, with: newData)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        return outcome.text
    }
}
