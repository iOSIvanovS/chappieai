// ChappieCore.swift
// ChappieCore
//
// Swift Package entry point — public facade of the entire package.
//
// WHY THIS FILE:
// Swift Package Manager doesn't require explicit re-exports, but having a central
// file with documentation gives three advantages:
//
// 1. READABILITY: Any developer opening the package immediately sees
//    the complete public API list in one place.
//
// 2. VERSIONING: When the public API changes, updating this file
//    makes the change immediately visible in git diff.
//
// 3. DOCUMENTATION: This file serves as the package "table of contents" —
//    describes what is exported and why.
//
// PACKAGE ARCHITECTURE:
// ChappieCore is Chappie's brain. It is intentionally separated from the SwiftUI layer
// (the Chappie target) so that the logic is testable and reusable
// independently of any specific UI framework.

import Foundation

// MARK: - ChappieCore Public API

// All public types the package provides to consumers are listed below.
// They are all declared as `public` in their own files — here we just
// document their presence for architectural clarity.

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
// • ThreadSettings         — Codable thread settings (IT-10: + activeProviderId)
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
// • AITunnelClient         — legacy HTTP client (deprecated, kept for migration)
// • AIOrchestrator         — main actor: agentic cycle "request → tool → response"
// • AIProviderStore        — actor, CRUD for AI providers + Keychain key storage (IT-10)
// • ToolExecutionService   — registry and executor of all Chappie tools
// • FileSystemManager      — safe file system access with path traversal protection
// • MemoryManager          — long-term memory: write, read, search entries
// • ChatHistoryManager     — persistent chat history storage between sessions [DEPRECATED]
//
// REFACTOR-THREADS IT-01:
// • ThreadStore            — actor, CRUD operations on threads via SwiftData
// • ProjectStore           — actor, CRUD operations on projects via SwiftData

// MARK: - Package Version

/// Current ChappieCore version.
public let coreVersion = "3.0.0" // IT-10: Universal AI Provider — AIClient + AIProviderStore
