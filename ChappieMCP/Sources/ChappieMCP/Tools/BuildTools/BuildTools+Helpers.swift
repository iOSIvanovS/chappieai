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
        // WHY Process+ls instead of FileManager.contentsOfDirectory:
        // MCP runs as a child process and does NOT inherit security-scoped bookmarks
        // from the parent Chappie app. FileManager cannot read sandbox-gated folders
        // (e.g. user-attached projects like adept-tracker). Shell `ls` bypasses this
        // because it runs in the user's shell environment with normal FS access.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ls")
        process.arguments = [projectDir]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress errors
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let proj = output.components(separatedBy: "\n").first(where: { $0.hasSuffix(".xcodeproj") }) {
                return proj
            }
        }
        return URL(fileURLWithPath: projectDir).lastPathComponent + ".xcodeproj"
    }

    /// Derives the main app scheme name from the project file name.
    func xcodeAppScheme(in projectDir: String) -> String {
        xcodeProjectName(in: projectDir).replacingOccurrences(of: ".xcodeproj", with: "")
    }

    /// Finds the best test scheme for the project.
    ///
    /// WHY: Different projects use different test scheme naming conventions.
    /// Chappie uses "ChappieCoreTests", others may use "AppTests" or just the main scheme.
    /// We ask xcodebuild for the real scheme list and pick the best match:
    /// 1. Exact "<AppName>CoreTests" — Chappie convention
    /// 2. Any scheme containing "test" (case-insensitive)
    /// 3. Fallback: main app scheme (test targets included in it will still run)
    func xcodeTestScheme(in projectDir: String) -> String {
        let appScheme = xcodeAppScheme(in: projectDir)
        let projName = xcodeProjectName(in: projectDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-project", projName, "-list"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return appScheme + "CoreTests" }
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let schemes = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix(":") }

        // Prefer exact CoreTests convention
        if let exact = schemes.first(where: { $0 == appScheme + "CoreTests" }) { return exact }
        // Then any scheme with "test" in the name
        if let testScheme = schemes.first(where: { $0.lowercased().contains("test") }) { return testScheme }
        // Fallback: main scheme (test targets included in it will run)
        return appScheme
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

    /// Returns the UDID of the first available simulator for the given platform.
    ///
    /// WHY: xcodebuild test requires a concrete simulator (not generic/platform=).
    /// We query xcrun simctl for available devices and pick the first match.
    private func firstAvailableSimulatorUDID(platform: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }
        // Find the first device matching the requested platform
        for (runtime, deviceList) in devices {
            guard runtime.lowercased().contains(platform.lowercased()) else { continue }
            if let device = deviceList.first(where: { $0["isAvailable"] as? Bool == true }),
               let udid = device["udid"] as? String {
                return udid
            }
        }
        return nil
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
            // WHY: generic/platform works for build but NOT for tests —
            // xcodebuild requires a concrete simulator UDID when running tests.
            if forTests, let udid = firstAvailableSimulatorUDID(platform: "iOS") {
                return "platform=iOS Simulator,id=\(udid)"
            }
            return "generic/platform=iOS Simulator"
        }
        if lower.contains("sdkroot = watchos") || lower.contains("supported_platforms = watchos") {
            if forTests, let udid = firstAvailableSimulatorUDID(platform: "watchOS") {
                return "platform=watchOS Simulator,id=\(udid)"
            }
            return "generic/platform=watchOS Simulator"
        }
        if lower.contains("sdkroot = appletvos") || lower.contains("supported_platforms = appletvos") {
            if forTests, let udid = firstAvailableSimulatorUDID(platform: "tvOS") {
                return "platform=tvOS Simulator,id=\(udid)"
            }
            return "generic/platform=tvOS Simulator"
        }
        if lower.contains("sdkroot = xros") || lower.contains("supported_platforms = xros") {
            if forTests, let udid = firstAvailableSimulatorUDID(platform: "visionOS") {
                return "platform=visionOS Simulator,id=\(udid)"
            }
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
