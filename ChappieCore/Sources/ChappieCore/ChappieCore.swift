// ChappieCore.swift
// ChappieCore
//
// Swift Package entry point — public facade of the entire package.
//
// WHY THIS FILE:
// Central documentation of the public API — gives three advantages:
// 1. READABILITY: Any developer sees the complete public API in one place.
// 2. VERSIONING: API changes are immediately visible in git diff.
// 3. DOCUMENTATION: Serves as the package "table of contents".
//
// PACKAGE ARCHITECTURE:
// ChappieCore is Chappie's brain — intentionally separated from the SwiftUI layer
// so that logic is testable and reusable independently of any UI framework.

import Foundation

// MARK: - ChappieCore Public API

// MARK: Data Models (Models/)
//
// • AppConfig              — centralized configuration: timeouts, step limits, history size
// • ChappieError           — unified error enum for the entire system
// • AIMessage              — one chat message model (role/content/tool_calls)
// • AITool                 — tool description for function calling API
// • AIFunctionDefinition   — function schema (name, description, parameters)
// • AIToolParameters       — JSON Schema of tool parameters
// • AIToolProperty         — individual property in the parameter schema
// • AITunnelRequest        — request model for OpenAI-compatible API
// • AITunnelResponse       — response model from OpenAI-compatible API
// • AIChoice               — one model response choice
// • AIUsage                — token usage statistics and cost
// • AIToolCall             — tool call returned by the model
// • AIToolCallFunction     — name and arguments of a specific tool call
//
// REFACTOR-THREADS IT-01:
// • ThreadEntity           — SwiftData thread model
// • ThreadSettings         — Codable thread settings
// • ThreadMetadata         — Sendable DTO for thread metadata
// • ProjectEntity          — SwiftData project model
// • ProjectSettings        — Codable project settings (IT-09: full agent permissions)
// • ProjectMetadata        — Sendable DTO for project metadata
// • MemoryEntity           — SwiftData memory container model
// • MemoryEntry            — Codable single memory entry
//
// IT-10: Universal AI Provider:
// • AIProvider             — Codable struct: endpoint + modelName + availableModels
// • AIProviderEntity       — SwiftData entity storing AIProvider as JSON string
// • AIProviderStoreError   — errors from AIProviderStore

// MARK: Services (Services/)
//
// • AIClient               — universal HTTP client for any OpenAI-compatible endpoint (IT-10)
// • AnthropicClient        — native Anthropic /v1/messages client
// • AIOrchestrator         — main actor: agentic cycle "request → tool → response"
// • AIProviderStore        — actor, CRUD for AI providers + Keychain key storage (IT-10)
// • ToolExecutionService   — registry and executor of all Chappie tools
// • FileSystemManager      — safe file system access with path traversal protection
// • MemoryManager          — long-term memory: write, read, search entries
//
// REFACTOR-THREADS IT-01:
// • ThreadStore            — actor, CRUD operations on threads via SwiftData
// • ProjectStore           — actor, CRUD operations on projects via SwiftData

// MARK: - Package Version

/// Current ChappieCore version.
public let coreVersion = "3.0.0"
