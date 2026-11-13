// ToolSchemaTypesTests.swift
// ChappieCoreTests
//
// Pass J4: a tool argument must be declared with the type it really is. A string-only schema for a
// number, a flag or a list of operations makes the model send "true"/"[...]" as text, and a bare
// "array" leaves it guessing what an element looks like. These tests pin the honest declarations
// and that the element shape reaches the wire.

import Testing
import Foundation
@testable import ChappieCore

private struct SchemaRig {
    let service: ToolExecutionService

    init(project: Bool = true) async {
        let dir = FileManager.default.temporaryDirectory
        service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaceURL: dir),
            memoryManager: MemoryManager(workspaceURL: dir),
            socketPath: "/tmp/chappie-schema-tests-nonexistent.sock"
        )
        let info = ActiveMemoryContext.ProjectInfo(id: UUID(), name: "P")
        let settings = ProjectSettings(agentRole: .executor, isProgrammingProject: true, devEnvironment: .xcode)
        await service.setMemoryContextAndSettings(
            context: ActiveMemoryContext(threadId: UUID(), projects: project ? [info] : [], threadTerminalEnabled: true),
            settings: project ? [info.id: settings] : [:]
        )
    }

    func tool(_ name: String) async -> AITool? {
        await service.availableTools.first { $0.function.name == name }
    }
}

@Suite("Tool schemas: arguments carry their real type")
struct ToolSchemaTypeTests {

    @Test("json_edit: edits is an array of objects, dry_run a flag, max_chars a number")
    func jsonEditTypes() async throws {
        let rig = await SchemaRig()
        let tool = try #require(await rig.tool("json_edit"))
        let props = tool.function.parameters.properties

        #expect(props["edits"]?.type == "array")
        #expect(props["edits"]?.items?.type == "object")
        #expect(props["edits"]?.items?.description?.contains("\"op\"") == true)
        #expect(props["dry_run"]?.type == "boolean")
        #expect(props["max_chars"]?.type == "integer")
        #expect(tool.function.parameters.required == ["path", "project", "edits"])
    }

    @Test("json_find: limit is a number, ignore_case a flag, everything else text")
    func jsonFindTypes() async throws {
        let rig = await SchemaRig()
        let props = try #require(await rig.tool("json_find")).function.parameters.properties

        #expect(props["limit"]?.type == "integer")
        #expect(props["ignore_case"]?.type == "boolean")
        #expect(props["match_any"]?.type == "boolean")
        for name in ["at", "key", "kind", "has", "missing", "value_at", "equals", "not_equals",
                     "contains", "not_contains", "same_as", "output", "show", "group_by"] {
            #expect(props[name]?.type == "string", "\(name)")
        }
    }

    @Test("json_find: the arguments the engine accepts are exactly the ones the model is shown")
    func jsonFindDeclaredEqualsKnown() async throws {
        let rig = await SchemaRig()
        let props = try #require(await rig.tool("json_find")).function.parameters.properties
        // A name declared but refused would fail every use of it; a name accepted but undeclared
        // would be invisible. Either drift is a bug this test catches the day it appears.
        #expect(Set(props.keys) == JSONFindQuery.knownArguments)
    }

    @Test("json_info, json_schema, json_get: accepted arguments equal the declared ones")
    func simpleToolsDeclaredEqualsKnown() async throws {
        let rig = await SchemaRig()
        for (name, known) in JSONToolEngine.knownArguments {
            let props = try #require(await rig.tool(name)).function.parameters.properties
            #expect(Set(props.keys) == known, "\(name)")
        }
    }

    @Test("json_get refuses an invented argument instead of answering another question")
    func jsonGetRefusesUnknown() {
        let data = Data(#"{"a":{"b":1}}"#.utf8)
        let out = JSONToolEngine.run(tool: "json_get", data: data, fileName: "x.json", arguments: ["at": #"["a"]"#, "max_depth": "1"])
        #expect(out.hasPrefix("Error:"))
        #expect(out.contains("'max_depth'"))
        #expect(out.contains("Nothing was read"))
    }

    @Test("json_schema and json_get take a numeric depth")
    func depthTypes() async throws {
        let rig = await SchemaRig()
        for name in ["json_schema", "json_get"] {
            let props = try #require(await rig.tool(name)).function.parameters.properties
            #expect(props["depth"]?.type == "integer", "\(name)")
            #expect(props["max_chars"]?.type == "integer", "\(name)")
        }
    }

    @Test("No tool declares an array without its element shape")
    func everyArrayHasItems() async {
        let rig = await SchemaRig()
        for tool in await rig.service.availableTools {
            for (name, prop) in tool.function.parameters.properties where prop.type == "array" {
                #expect(prop.items != nil, "\(tool.function.name).\(name) is an array without items")
            }
        }
    }

    @Test("An element shape survives encoding to JSON")
    func itemsEncode() throws {
        let property = AIToolProperty(
            type: "array",
            description: "ops",
            items: AIToolItemShape(type: "object", description: "one op",
                                   items: AIToolItemShape(type: "string", description: nil))
        )
        let data = try JSONEncoder().encode(property)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(json["items"] as? [String: Any])
        #expect(items["type"] as? String == "object")
        let nested = try #require(items["items"] as? [String: Any])
        #expect(nested["type"] as? String == "string")
    }

    @Test("The Anthropic schema carries the element shape to the wire")
    func anthropicKeepsItems() async throws {
        let rig = await SchemaRig()
        let tool = try #require(await rig.tool("json_edit"))
        let client = AnthropicClient(baseURL: "https://api.anthropic.com", apiKey: "k", modelName: "m")

        let converted = client.convertTool(tool)
        let edits = try #require(converted.inputSchema.properties["edits"])
        #expect(edits.type == "array")
        #expect(edits.items?.type == "object")
        #expect(edits.items?.description?.contains("insert") == true)

        let data = try JSONEncoder().encode(converted)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let schema = try #require(json["input_schema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let editsJSON = try #require(properties["edits"] as? [String: Any])
        #expect(editsJSON["type"] as? String == "array")
        #expect((editsJSON["items"] as? [String: Any])?["type"] as? String == "object")
        #expect((properties["dry_run"] as? [String: Any])?["type"] as? String == "boolean")
    }

    @Test("A model that sends the old shapes anyway is still understood")
    func lenientArgumentsStillWork() async throws {
        // dry_run and limits arrive as strings, edits as JSON text: the flattening reader and the
        // raw-call reader keep both working, so honest schemas never break an older habit.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("schema-lenient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{\n  \"a\" : 1\n}".write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)

        let service = ToolExecutionService(
            fileSystem: FileSystemManager(workspaces: [(name: "P", url: dir)]),
            memoryManager: MemoryManager(workspaceURL: dir),
            socketPath: "/tmp/chappie-schema-tests-nonexistent.sock"
        )
        let raw = #"{"path":"a.json","project":"P","dry_run":"true","edits":"[{\"op\":\"set\",\"at\":[\"a\"],\"value\":2}]"}"#
        let flat = try #require(ToolArguments.parse(raw).get() as [String: String]?)
        let reply = await service.executeJSONEdit(argsData: try JSONEncoder().encode(flat), rawArgsData: Data(raw.utf8))
        #expect(reply.contains("DRY RUN"))
        #expect(try String(contentsOf: dir.appendingPathComponent("a.json"), encoding: .utf8) == "{\n  \"a\" : 1\n}")
    }
}
