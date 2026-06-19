// ToolDefinitions+GitTools.swift
// ChappieCore
//
// Git tool definitions. Injected only when at least one programming project is attached.
// git_diff is intentionally absent — it dumps the entire project into AI context.

import Foundation

extension ToolExecutionService {

    func gitTools(progInfos: [ActiveMemoryContext.ProjectInfo]) -> [AITool] {
        let multiProg = progInfos.count > 1
        let projectArg = AIToolProperty(type: "string", description: gitProjectArgDescription(for: progInfos))

        return [
            AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Show the current git repository status: modified, new, and deleted files.",
                parameters: AIToolParameters(
                    properties: ["project": projectArg],
                    required: multiProg ? ["project"] : []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Add files to the staging area (prepare for commit).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Space-separated paths, or '.' for all files (default '.')"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["project"] : []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Create a git commit with the given message.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Commit message"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["message", "project"] : ["message"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_push",
                description: "Push committed changes to the remote repository.\nTriggers CI/CD if configured (e.g. auto-deploy to VPS on push to main).\nUse after git_commit when the work is accepted and ready to deploy.",
                parameters: AIToolParameters(
                    properties: [
                        "remote": AIToolProperty(type: "string", description: "Remote name (default: 'origin')"),
                        "branch": AIToolProperty(type: "string", description: "Branch name (default: 'main')"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["project"] : []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Show the history of recent commits.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Number of commits to show (default 10)"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["project"] : []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Remove all files from the staging area (git reset HEAD).",
                parameters: AIToolParameters(
                    properties: ["project": projectArg],
                    required: multiProg ? ["project"] : []
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_revert",
                description: "Revert one or more commits via git revert.\nAll changes are collected into a single clean commit with the given message.\nUse when you need to undo specific commits without removing them from history.",
                parameters: AIToolParameters(
                    properties: [
                        "hashes": AIToolProperty(type: "string", description: "Space-separated commit hashes to revert (e.g.: 'abc123 def456')"),
                        "message": AIToolProperty(type: "string", description: "Message for the resulting revert commit"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["hashes", "message", "project"] : ["hashes", "message"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "git_checkout",
                description: "Restore specific files from a given commit or branch.\nUse for surgical rollback of individual files without touching the rest of the code.\nExamples of ref: HEAD~1, abc123, main",
                parameters: AIToolParameters(
                    properties: [
                        "ref": AIToolProperty(type: "string", description: "Commit, branch, or relative ref (e.g.: HEAD~1, abc123, main)"),
                        "paths": AIToolProperty(type: "string", description: "Space-separated file paths to restore"),
                        "project": projectArg
                    ],
                    required: multiProg ? ["ref", "paths", "project"] : ["ref", "paths"]
                )
            ))
        ]
    }
}
