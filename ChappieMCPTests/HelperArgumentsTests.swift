// HelperArgumentsTests.swift
//
// The helper's command line is the contract with MCPHelperLauncher in the app. A regression here
// shows up as "no tools at all" or as a helper that trusts "/" as a project root.

import Testing
import Foundation
@testable import ChappieMCPCore

struct HelperArgumentsTests {

    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-args-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func socketPathIsMandatory() {
        #expect(HelperArguments.parse(["bin"]) == nil)
        #expect(HelperArguments.parse(["bin", "/work"]) == nil)
        #expect(HelperArguments.parse(["bin", "/work", ""]) == nil)
    }

    @Test func parsesMinimalArguments() throws {
        let parsed = try #require(HelperArguments.parse(["bin", "", "/tmp/x.sock"]))
        #expect(parsed.socketPath == "/tmp/x.sock")
        #expect(parsed.projectPath == "")
        #expect(parsed.projectEnvMap.isEmpty)
        #expect(parsed.projectPathMap.isEmpty)
    }

    @Test func rootAndEmptyWorkspaceAreDropped() throws {
        // Xcode launches the app with "/" as working directory: it must never become a project root.
        #expect(try #require(HelperArguments.parse(["bin", "/", "/tmp/x.sock"])).projectPath == "")
        #expect(try #require(HelperArguments.parse(["bin", "", "/tmp/x.sock"])).projectPath == "")
        #expect(try #require(HelperArguments.parse(["bin", "relative/dir", "/tmp/x.sock"])).projectPath == "")
        #expect(try #require(HelperArguments.parse(["bin", "/definitely/not/here", "/tmp/x.sock"])).projectPath == "")
    }

    @Test func usableWorkspaceIsKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let parsed = try #require(HelperArguments.parse(["bin", dir, "/tmp/x.sock"]))
        #expect(parsed.projectPath == dir)
    }

    @Test func decodesProjectMaps() throws {
        let parsed = try #require(HelperArguments.parse([
            "bin", "", "/tmp/x.sock",
            #"{"Chappie":"xcode","Bot":"python"}"#,
            #"{"Chappie":"/a","Bot":"/b"}"#
        ]))
        #expect(parsed.projectEnvMap == ["Chappie": "xcode", "Bot": "python"])
        #expect(parsed.projectPathMap == ["Chappie": "/a", "Bot": "/b"])
    }

    @Test func malformedMapsBecomeEmpty() throws {
        let parsed = try #require(HelperArguments.parse([
            "bin", "", "/tmp/x.sock", "not json", #"{"a":1}"#
        ]))
        #expect(parsed.projectEnvMap.isEmpty)
        #expect(parsed.projectPathMap.isEmpty)
    }
}
