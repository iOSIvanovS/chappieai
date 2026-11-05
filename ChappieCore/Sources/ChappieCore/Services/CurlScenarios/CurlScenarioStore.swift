// CurlScenarioStore.swift
// ChappieCore
//
// Reads, writes and deletes scenario files in ONE folder of ONE project. The folder comes from the
// model, so every path goes through PathGuard (no "..", no absolute path, no symlink out of the
// project) and the folder itself may not be inside .git or another hidden directory.
//
// Files are `<name>.json`, pretty-printed with sorted keys: stable text means clean git diffs.

import Foundation

struct CurlScenarioStore {

    struct Failure: Error { let message: String }

    let root: URL
    let folder: String

    init(root: URL, folder: String) throws {
        let cleaned = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw Failure(message: "Give 'folder': the scenarios folder inside the project, relative to its root (for example \"Scenarios\"). Agree on it with the user first.")
        }
        // split() would drop a leading "/" and quietly turn "/tmp" into "tmp"; refuse it instead.
        guard !cleaned.hasPrefix("/") else {
            throw Failure(message: "Folder '\(folder)' is an absolute path. Give it relative to the project root, for example \"Scenarios\".")
        }
        let parts = cleaned.split(separator: "/").map(String.init).filter { $0 != "." }
        if let hidden = parts.first(where: { $0.hasPrefix(".") && $0 != ".chappie" }) {
            throw Failure(message: "Folder '\(folder)' passes through '\(hidden)'. Hidden folders (.git and similar) are not allowed; \".chappie/scenarios\" is the only dotted path accepted.")
        }
        if parts.contains(where: { $0.lowercased().hasSuffix(".xcodeproj") || $0.lowercased().hasSuffix(".xcworkspace") }) {
            throw Failure(message: "Folder '\(folder)' is inside an Xcode project bundle. Use a plain folder in the project root.")
        }
        self.root = root
        self.folder = parts.joined(separator: "/")
        guard !self.folder.isEmpty else {
            throw Failure(message: "Folder '\(folder)' is the project root itself; use a subfolder such as \"Scenarios\".")
        }
        _ = try resolveFolder()
    }

    // MARK: - Paths

    private func resolveFolder() throws -> URL {
        do { return try PathGuard.resolve(folder, inRoot: root) }
        catch let violation as PathGuard.Violation { throw Failure(message: "Path blocked: \(violation.message)") }
    }

    func fileURL(for name: String) throws -> URL {
        guard CurlScenarioRules.isValidIdentifier(name) else {
            throw Failure(message: "Scenario name '\(name)' must be letters, digits, '_' or '-'.")
        }
        do { return try PathGuard.resolve("\(folder)/\(name).json", inRoot: root) }
        catch let violation as PathGuard.Violation { throw Failure(message: "Path blocked: \(violation.message)") }
    }

    // MARK: - Listing and loading

    /// File names (without .json) in the folder; a missing folder is simply "no scenarios yet".
    func names() throws -> [String] {
        let url = try resolveFolder()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return entries.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter(CurlScenarioRules.isValidIdentifier)
            .sorted()
    }

    func exists(_ name: String) -> Bool {
        guard let url = try? fileURL(for: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// nil = no such file. A file that exists but cannot be read or decoded is reported by `loadResult`.
    func load(_ name: String) -> CurlScenario? {
        if case .success(let scenario) = loadResult(name) { return scenario }
        return nil
    }

    func loadResult(_ name: String) -> Result<CurlScenario, CurlScenarioIssues> {
        guard let url = try? fileURL(for: name), let data = try? Data(contentsOf: url) else {
            return .failure(CurlScenarioIssues(["Scenario '\(name)' does not exist in '\(folder)'."]))
        }
        guard data.count <= CurlScenarioRules.maxFileBytes else {
            return .failure(CurlScenarioIssues(["Scenario file '\(name).json' is larger than \(CurlScenarioRules.maxFileBytes / 1000) KB."]))
        }
        switch CurlScenarioDecoder.decode(data) {
        case .failure(let issues): return .failure(issues)
        case .success(let scenario):
            guard scenario.name == name else {
                return .failure(CurlScenarioIssues(["The file is called '\(name).json' but its name is '\(scenario.name)'; they must match."]))
            }
            return .success(scenario)
        }
    }

    // MARK: - Writing

    /// Writes already-validated JSON. Returns true when an existing file was replaced.
    func write(name: String, json: Data) throws -> Bool {
        let url = try fileURL(for: name)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Could not write '\(name).json': \(error.localizedDescription)")
        }
        return existed
    }

    func delete(_ name: String) throws {
        let url = try fileURL(for: name)
        do { try FileManager.default.removeItem(at: url) }
        catch { throw Failure(message: "Could not delete '\(name).json': \(error.localizedDescription)") }
    }

    /// Pretty, key-sorted JSON from the text the model sent; nil when it is not a JSON object.
    static func canonicalJSON(from text: String) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: - Reverse references

    /// Scenarios of this folder that call `name` (for delete protection and for info).
    func callers(of name: String) -> [String] {
        ((try? names()) ?? []).filter { other in
            other != name && (load(other)?.calledScenarios.contains(name) ?? false)
        }
    }
}
