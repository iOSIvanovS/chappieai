// ToolDefinitions+MemoryTools.swift
// ChappieCore
//
// Long-term memory tool definitions (IT-08: three-level memory system).

import Foundation

extension ToolExecutionService {

    func memoryTools() -> [AITool] {
        return [
            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: "Save important information, agreement, fact, or rule to long-term memory.\nUse scope to choose the level:\n  scope=\"global\" — global memory (cross-project rules, facts about the user).\n  scope=\"thread\" — active thread memory (current task context).\n  targetName=\"ProjectName\" — specific project memory (architecture, pipelines).\nIf neither scope nor targetName is set — saves to global memory.\nIMPORTANT: ALL fields (key, type, jsonString) MUST be in English. Cyrillic is REJECTED.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Unique key/topic for memorization (English only)"),
                        "type": AIToolProperty(type: "string", description: "Data type (e.g.: rule, fact, persona, project_map) (English only)"),
                        "jsonString": AIToolProperty(type: "string", description: "Data in JSON string format (English only)"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread (e.g., Chappie or ChappieCore) to save memory strictly in that project")
                    ],
                    required: ["key", "type", "jsonString"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "recall",
                description: "Retrieve information from long-term memory by key.\nUse scope or targetName to specify the memory level:\n  scope=\"global\" — global memory.\n  scope=\"thread\" — active thread memory.\n  targetName=\"ProjectName\" — specific project memory.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Unique key/topic to recall"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to search memory strictly in that project")
                    ],
                    required: ["key"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "search_memory",
                description: "Find all memory entries by a specific type.\nUse scope or targetName to specify the memory level:\n  scope=\"global\" — global memory.\n  scope=\"thread\" — active thread memory.\n  targetName=\"ProjectName\" — specific project memory.",
                parameters: AIToolParameters(
                    properties: [
                        "type": AIToolProperty(type: "string", description: "Data type to search for (e.g.: rule, fact)"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to search memory strictly in that project")
                    ],
                    required: ["type"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "delete_memory",
                description: "Delete a memory entry by key.\nUse scope or targetName to specify the memory level:\n  scope=\"global\" — global memory.\n  scope=\"thread\" — active thread memory.\n  targetName=\"ProjectName\" — specific project memory.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Unique key/topic to delete"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread to delete memory strictly from that project")
                    ],
                    required: ["key"]
                )
            ))
        ]
    }
}
