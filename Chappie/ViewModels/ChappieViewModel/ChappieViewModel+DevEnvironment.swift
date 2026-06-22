// ChappieViewModel+DevEnvironment.swift
// Chappie
//
// Dev environment detection: local rule-based first, AI fallback for exotic stacks.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Dev Environment Auto-Detection

    /// Detects the dev environment for a specific project by scanning its files.
    ///
    /// absolutePath is read directly from ProjectMetadata — no bookmark resolution needed.
    /// Local detection runs first; AI fallback fires only for exotic stacks.
    func detectDevEnvironment(
        for project: ProjectMetadata,
        completion: @escaping @MainActor (DevEnvironment) -> Void
    ) {
        guard let absolutePath = project.absolutePath, !absolutePath.isEmpty else {
            Task { @MainActor in completion(.unknown) }
            return
        }

        Task {
            let projectURL = URL(fileURLWithPath: absolutePath)
            let projectFS  = FileSystemManager(workspaceURL: projectURL)

            let files = (try? await projectFS.listFiles()) ?? []
            print("[detectEnv] '\(project.displayName)': \(files.count) files scanned at \(absolutePath)")

            guard !files.isEmpty else {
                print("[detectEnv] empty file list for '\(project.displayName)' → .unknown")
                await MainActor.run { completion(.unknown) }
                return
            }

            // Local rule-based detection — fast, free, covers all common stacks.
            if let local = detectEnvironmentLocally(from: files, projectName: project.displayName) {
                print("[detectEnv] local match → \(local.displayName) for '\(project.displayName)'")
                await MainActor.run { completion(local) }
                return
            }

            // AI fallback — only for exotic stacks not covered by local rules.
            guard let client = aiClient else {
                print("[detectEnv] no AI client, local rules found no match → .unknown for '\(project.displayName)'")
                await MainActor.run { completion(.unknown) }
                return
            }

            let fileList = files.prefix(200).joined(separator: "\n")

            let hints = DevEnvironment.allCases
                .filter { $0 != .unknown }
                .map { env in "\(env.rawValue): \(env.detectionHints.joined(separator: ", "))" }
                .joined(separator: "\n")

            let systemPrompt = """
            You are a dev environment detector. Respond with EXACTLY one raw value from this list:
            unknown, xcode, nodejs, python, go, rust, java, kotlin, flutter, react_typescript, dotnet, html

            Detection hints (env: marker files):
            \(hints)

            Rules:
            - If you see .xcodeproj, .xcworkspace, or .swift files → xcode
            - If you see package.json → nodejs
            - If you see pubspec.yaml → flutter
            - If you see tsconfig.json or .tsx files → react_typescript
            - If you see index.html or .html files without any framework marker → html
            - If the stack is not in the list above → unknown
            - Respond with the single raw value only. No explanation, no punctuation.
            """

            let userMessage = AIMessage(
                role: "user",
                content: "Project file list:\n\(fileList)\n\nWhat is the dev environment?"
            )

            do {
                let result = try await client.sendRequest(
                    systemPrompt: systemPrompt,
                    chatHistory: [userMessage],
                    tools: []
                )

                let raw = (result.message.contentString ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                let detected = DevEnvironment(rawValue: raw) ?? .unknown
                print("[detectEnv] AI → '\(raw)' → \(detected.displayName) for '\(project.displayName)'")
                await MainActor.run { completion(detected) }
            } catch {
                print("[detectEnv] AI call failed: \(error.localizedDescription) → .unknown for '\(project.displayName)'")
                await MainActor.run { completion(.unknown) }
            }
        }
    }

    /// Fast local detection by scanning file names and extensions against known marker files.
    /// Returns nil only if no rule matches — caller falls back to AI for exotic stacks.
    ///
    /// WHY html is last: it's the most generic stack (any folder can have .html).
    /// We only assign it when no more specific framework marker is found.
    private func detectEnvironmentLocally(from files: [String], projectName: String = "") -> DevEnvironment? {
        let fileNames = Set(files.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        let extensions = Set(files.compactMap {
            let ext = URL(fileURLWithPath: $0).pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        })

        print("[detectEnv] '\(projectName)' fileNames sample: \(Array(fileNames.prefix(10)))")
        print("[detectEnv] '\(projectName)' extensions: \(extensions)")

        // Ordered by specificity — most specific markers first.
        let candidates: [(DevEnvironment, Bool)] = [
            (.xcode,           fileNames.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) || extensions.contains("swift")),
            (.flutter,         fileNames.contains("pubspec.yaml")),
            (.reacttypescript,  fileNames.contains("tsconfig.json") || fileNames.contains("vite.config.ts") || fileNames.contains("next.config.ts") || extensions.contains("tsx")),
            (.nodejs,           fileNames.contains("package.json")),
            (.python,           fileNames.contains("requirements.txt") || fileNames.contains("pyproject.toml") || fileNames.contains("setup.py") || fileNames.contains("main.py") || fileNames.contains("manage.py") || extensions.contains("py")),
            (.rust,             fileNames.contains("cargo.toml")),
            (.go,               fileNames.contains("go.mod")),
            (.kotlin,           fileNames.contains("androidmanifest.xml") || fileNames.contains("build.gradle.kts")),
            (.java,             fileNames.contains("pom.xml") || (fileNames.contains("build.gradle") && !fileNames.contains("androidmanifest.xml"))),
            (.dotnet,           extensions.contains("csproj") || extensions.contains("sln") || extensions.contains("cs")),
            // HTML/CSS/JS: static site — checked last, most generic.
            (.html,             fileNames.contains("index.html") || extensions.contains("html")),
        ]

        return candidates.first(where: { $0.1 })?.0
    }
}
