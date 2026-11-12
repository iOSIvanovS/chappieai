// JSONTools.swift
// ChappieCore
//
// Executor of json_info / json_schema / json_get / json_find. The tools run in the app, not in the
// helper: the file is read through FileSystemManager (the same path guard as read_file) and the
// parsing happens on a detached task so a big file does not hold the actor.

import Foundation

extension ToolExecutionService {

    func executeJSONTool(name: String, argsData: Data) async -> String {
        guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
              let path = args["path"], !path.isEmpty else {
            return "Error: Argument 'path' is required for \(name)"
        }
        let data: Data
        do {
            data = try await fileSystem.readData(at: path, projectName: args["project"], limit: JSONToolEngine.maxFileBytes)
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let fileName = (path as NSString).lastPathComponent
        return await Task.detached(priority: .userInitiated) {
            JSONToolEngine.run(tool: name, data: data, fileName: fileName, arguments: args)
        }.value
    }
}
