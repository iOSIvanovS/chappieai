// BuildTools.swift
//
// WHY THIS FILE:
// Implements build_project, run_tests, read_build_log tools for all supported dev environments.
// Routes each command to the correct shell tool based on the DevEnvironment of the target project.
//
// MULTI-PROJECT ROUTING:
// Each tool call carries a "project" argument (project display name).
// BuildTools looks up the project's devEnvironment from projectEnvMap and its absolute path
// from projectPathMap — both passed at init from CLI argv[3] and argv[4].

import Foundation

// MARK: - BuildTools

/// Build and test tools router. Delegates to env-specific shell commands.
/// Resolves the target project's DevEnvironment and absolute path from maps passed at init.
final class BuildTools: Sendable {

    /// Fallback path — used only when projectPathMap is empty (single-project legacy mode).
    let defaultProjectPath: String

    /// Map of project display name → DevEnvironment rawValue.
    let projectEnvMap: [String: String]

    /// Map of project display name → absolute path on disk.
    let projectPathMap: [String: String]

    /// Shared log file path — written by build/test, read by read_build_log.
    var buildLogPath: String {
        defaultProjectPath + "/.build_log.txt"
    }

    init(projectPath: String, projectEnvMap: [String: String], projectPathMap: [String: String] = [:]) {
        self.defaultProjectPath = projectPath
        self.projectEnvMap = projectEnvMap
        self.projectPathMap = projectPathMap
    }

    // MARK: - Path & Env Resolution

    /// Resolves DevEnvironment for the given project name.
    func environment(for projectName: String?) -> DevEnvironment {
        guard let name = projectName, !name.isEmpty,
              let rawValue = projectEnvMap[name] else {
            if projectEnvMap.count == 1, let rawValue = projectEnvMap.values.first {
                return DevEnvironment(rawValue: rawValue) ?? .unknown
            }
            return .unknown
        }
        return DevEnvironment(rawValue: rawValue) ?? .unknown
    }

    /// Resolves the absolute working directory for the given project name.
    ///
    /// WHY this matters: xcodeProjectName() scans the working directory for .xcodeproj.
    /// Without the correct path, it finds the wrong project (e.g. Chappie instead of adminPanel).
    func resolvePath(for projectName: String?) -> String {
        if let name = projectName, !name.isEmpty, let path = projectPathMap[name] {
            return path
        }
        if projectPathMap.count == 1, let path = projectPathMap.values.first {
            return path
        }
        return defaultProjectPath
    }

    // MARK: - Public tools

    func build(projectName: String?) async -> ToolResult {
        let env = environment(for: projectName)
        let path = resolvePath(for: projectName)
        let label = "build_project[\(projectName ?? "?")]"

        switch env {
        case .xcode:
            return await runXcodebuild(
                args: ["-project", xcodeProjectName(in: path), "-scheme", xcodeAppScheme(in: path),
                       "-configuration", "Debug", "-destination", xcodeDestination(in: path), "build"],
                label: label,
                workingDirectory: path,
                env: env
            )
        case .nodejs:
            return await runShell("npm run build", label: label, workingDirectory: path, env: env)
        case .go:
            return await runShell("go build ./...", label: label, workingDirectory: path, env: env)
        case .rust:
            return await runShell("cargo build", label: label, workingDirectory: path, env: env)
        case .java:
            return await runShell(mavenOrGradle(maven: "mvn compile", gradle: "gradle build", in: path), label: label, workingDirectory: path, env: env)
        case .kotlin:
            return await runShell(gradleWrapper("build", in: path), label: label, workingDirectory: path, env: env)
        case .flutter:
            return await runShell("flutter build", label: label, workingDirectory: path, env: env)
        case .dotnet:
            return await runShell("dotnet build", label: label, workingDirectory: path, env: env)
        case .python, .reacttypescript, .html:
            return .failure("build_project is not available for \(env.rawValue) — no compile step.")
        case .unknown:
            let available = projectEnvMap.keys.sorted().joined(separator: ", ")
            let hint = available.isEmpty
                ? "No projects are configured."
                : "Available projects: \(available). Pass 'project' argument with one of these names."
            return .failure("build_project: cannot resolve dev environment for project '\(projectName ?? "(none)")'. \(hint)")
        }
    }

    func runTests(projectName: String?, target: String?) async -> ToolResult {
        let env = environment(for: projectName)
        let path = resolvePath(for: projectName)
        let label = "run_tests[\(projectName ?? "?")]"

        switch env {
        case .xcode:
            var args = ["-project", xcodeProjectName(in: path), "-scheme", xcodeTestScheme(in: path),
                        "-destination", xcodeTestDestination(in: path), "test"]
            if let target, !target.isEmpty {
                args.append(contentsOf: ["-only-testing", target])
            }
            return await runXcodebuild(args: args, label: label, workingDirectory: path, env: env)
        case .nodejs:
            let pattern = target.map { " -- \($0)" } ?? ""
            return await runShell("npm test\(pattern)", label: label, workingDirectory: path, env: env)
        case .python:
            let pattern = target ?? ""
            let cmd = pattern.isEmpty ? "python -m pytest" : "python -m pytest \(pattern)"
            return await runShell(cmd, label: label, workingDirectory: path, env: env)
        case .go:
            let pkg = target ?? "./..."
            return await runShell("go test \(pkg)", label: label, workingDirectory: path, env: env)
        case .rust:
            let filter = target.map { " \($0)" } ?? ""
            return await runShell("cargo test\(filter)", label: label, workingDirectory: path, env: env)
        case .java:
            let cls = target.map { " -Dtest=\($0)" } ?? ""
            return await runShell(mavenOrGradle(maven: "mvn test\(cls)", gradle: "gradle test\(cls)", in: path), label: label, workingDirectory: path, env: env)
        case .kotlin:
            let cls = target.map { " --tests \($0)" } ?? ""
            return await runShell(gradleWrapper("test\(cls)", in: path), label: label, workingDirectory: path, env: env)
        case .flutter:
            let file = target.map { " \($0)" } ?? ""
            return await runShell("flutter test\(file)", label: label, workingDirectory: path, env: env)
        case .reacttypescript:
            let pattern = target.map { " \($0)" } ?? ""
            return await runShell("npm test\(pattern)", label: label, workingDirectory: path, env: env)
        case .dotnet:
            let proj = target.map { " \($0)" } ?? ""
            return await runShell("dotnet test\(proj)", label: label, workingDirectory: path, env: env)
        case .html:
            return .failure("run_tests is not available for HTML/CSS/JS projects — no test runner configured.")
        case .unknown:
            let available = projectEnvMap.keys.sorted().joined(separator: ", ")
            let hint = available.isEmpty
                ? "No projects are configured."
                : "Available projects: \(available). Pass 'project' argument with one of these names."
            return .failure("run_tests: cannot resolve dev environment for project '\(projectName ?? "(none)")'. \(hint)")
        }
    }

    func readLastLog() async -> ToolResult {
        let logURL = URL(fileURLWithPath: buildLogPath)
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return .failure("Build log not found. Run build_project or run_tests first.")
        }
        return .success(content)
    }
}
