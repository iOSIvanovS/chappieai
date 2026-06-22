// BuildTools+Helpers.swift
//
// WHY THIS FILE:
// Xcode/Java/Kotlin project discovery helpers, log saving, and output parsing.

import Foundation

// MARK: - Xcode helpers

extension BuildTools {

    /// Finds the first .xcodeproj in the given project directory.
    ///
    /// WHY `in path` instead of self.defaultProjectPath:
    /// Each project lives in its own directory. Without the correct path,
    /// this would always find Chappie.xcodeproj regardless of which project was requested.
    func xcodeProjectName(in projectDir: String) -> String {
        if let items = try? FileManager.default.contentsOfDirectory(atPath: projectDir),
           let proj = items.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return proj
        }
        return URL(fileURLWithPath: projectDir).lastPathComponent + ".xcodeproj"
    }

    /// Derives the main app scheme name from the project file name.
    func xcodeAppScheme(in projectDir: String) -> String {
        xcodeProjectName(in: projectDir).replacingOccurrences(of: ".xcodeproj", with: "")
    }

    /// Derives the test scheme: AppName + "CoreTests" (e.g. "ChappieCoreTests").
    func xcodeTestScheme(in projectDir: String) -> String {
        xcodeAppScheme(in: projectDir) + "CoreTests"
    }

    /// Detects the correct xcodebuild -destination for build_project.
    ///
    /// WHY generic/platform=: universal "Any Device" syntax — no specific simulator required.
    /// Works regardless of which simulators are installed on the machine.
    func xcodeDestination(in projectDir: String) -> String {
        xcodeDestinationString(in: projectDir, forTests: false)
    }

    /// Detects the correct xcodebuild -destination for run_tests.
    ///
    /// WHY separate: macOS tests cannot run on "generic/platform=macOS" —
    /// xcodebuild requires a concrete device for test execution (not just build).
    /// Simulator platforms use the same generic destination for both build and test.
    func xcodeTestDestination(in projectDir: String) -> String {
        xcodeDestinationString(in: projectDir, forTests: true)
    }

    /// Core platform detection — shared by xcodeDestination and xcodeTestDestination.
    private func xcodeDestinationString(in projectDir: String, forTests: Bool) -> String {
        let projName = xcodeProjectName(in: projectDir)
        let pbxPath = projectDir + "/" + projName + "/project.pbxproj"

        guard let content = try? String(contentsOfFile: pbxPath, encoding: .utf8) else {
            return forTests ? "platform=macOS,arch=arm64" : "generic/platform=macOS"
        }

        let lower = content.lowercased()

        if lower.contains("sdkroot = iphoneos") || lower.contains("supported_platforms = iphoneos") {
            return "generic/platform=iOS Simulator"
        }
        if lower.contains("sdkroot = watchos") || lower.contains("supported_platforms = watchos") {
            return "generic/platform=watchOS Simulator"
        }
        if lower.contains("sdkroot = appletvos") || lower.contains("supported_platforms = appletvos") {
            return "generic/platform=tvOS Simulator"
        }
        if lower.contains("sdkroot = xros") || lower.contains("supported_platforms = xros") {
            return "generic/platform=visionOS Simulator"
        }
        // WHY different destinations:
        // build: generic/platform=macOS — "Any Mac", no arch required
        // tests: platform=macOS — equivalent to "My Mac" in Xcode, Xcode picks arch automatically
        //        (see BuildTools+Process.swift DESTINATION HISTORY for rejected alternatives)
        return forTests ? "platform=macOS" : "generic/platform=macOS"
    }
}

// MARK: - Java/Kotlin helpers

extension BuildTools {

    func mavenOrGradle(maven: String, gradle: String, in projectDir: String) -> String {
        let hasPom = FileManager.default.fileExists(atPath: projectDir + "/pom.xml")
        return hasPom ? maven : gradle
    }

    func gradleWrapper(_ task: String, in projectDir: String) -> String {
        let wrapper = projectDir + "/gradlew"
        let exe = FileManager.default.fileExists(atPath: wrapper) ? "./gradlew" : "gradle"
        return "\(exe) \(task)"
    }
}

// MARK: - Log helpers

extension BuildTools {

    func saveLog(_ output: String, label: String, command: String, env: DevEnvironment) {
        let header = """
        === ChappieMCP Build Log ===
        Tool:    \(label)
        Env:     \(env.rawValue)
        Command: \(command)
        Time:    \(Date())
        ============================

        """
        try? (header + output).write(toFile: buildLogPath, atomically: true, encoding: .utf8)
    }

    func extractSummary(from output: String) -> String {
        let keywords = ["BUILD SUCCEEDED", "BUILD FAILED", "TEST SUCCEEDED", "TEST FAILED",
                        "warning:", "Executed", "PASSED", "FAILED", "passed", "failed"]
        let lines = output.components(separatedBy: "\n")
            .filter { line in keywords.contains { line.contains($0) } }
        return lines.isEmpty ? "Completed without warnings." : lines.prefix(20).joined(separator: "\n")
    }

    /// Extracts error lines from build output for a concise failure report.
    ///
    /// WHY: full xcodebuild/compiler output can be 1000+ lines.
    /// AI only needs the errors — not the noise.
    func extractErrors(from output: String) -> String {
        let keywords = ["error:", "Error:", "BUILD FAILED", "FAILED", "warning:"]
        let lines = output.components(separatedBy: "\n")
            .filter { line in keywords.contains { line.contains($0) } }
        if lines.isEmpty {
            return "Error details:\n" + output.components(separatedBy: "\n").suffix(30).joined(separator: "\n")
        }
        return lines.prefix(50).joined(separator: "\n")
    }
}
