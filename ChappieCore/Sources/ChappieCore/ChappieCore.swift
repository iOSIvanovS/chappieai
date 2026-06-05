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

// MARK: DataStore (DataStore/)
//
// • ChappieDataStore       — the ONLY actor that knows about SwiftData. Single point of persistence.
// • StoredRecord           — the ONLY @Model in the entire app. relation(String) + payload(Data).

// MARK: Data Models (Models/)
//
// • AppConfig              — centralized configuration: timeouts, step limits, history size
// • ChappieError           — unified error enum for the entire system
// • AppSettingsPayload     — Codable struct for global app settings (workspace, lastThread, balances)
// • ThreadPayload          — Codable struct for thread persistence
// • ThreadSettings         — Codable per-thread settings (context size, provider, model)
// • ThreadMetadata         — Sendable DTO for passing thread data across actor boundaries
// • ProjectPayload         — Codable struct for project persistence
// • ProjectSettings        — Codable project settings (agent role, git/tests/terminal access)
// • ProjectMetadata        — Sendable DTO for passing project data across actor boundaries
// • MemoryStorage          — root Codable container for all memory scopes
// • MemoryEntry            — Codable single memory record (key/type/jsonString)
// • ActiveMemoryContext    — Sendable context for ToolExecutionService (threadId + projects)
// • AIProvider             — Codable struct: endpoint + keys + models + isDefault
// • AIModel                — Codable model descriptor (id, name, endpoint, protocol)
// • APIKey                 — Codable named API key with stable UUID
//
// AI Tunnel Models:
// • AIMessage              — one chat message model (role/content/tool_calls)
// • AITool                 — tool description for function calling API
// • AITunnelRequest        — request model for OpenAI-compatible API
// • AITunnelResponse       — response model from OpenAI-compatible API

// MARK: Services (Services/)
//
// • AIClient               — universal HTTP client for any OpenAI-compatible endpoint
// • AnthropicClient        — native Anthropic /v1/messages client
// • AIOrchestrator         — main actor: agentic cycle "request → tool → response"
// • AIProviderStore        — actor, CRUD for AI providers + Keychain key storage
// • ToolExecutionService   — registry and executor of all Chappie tools
// • FileSystemManager      — safe file system access with path traversal protection
// • MemoryManager          — long-term memory: write, read, search entries
// • ThreadStore            — actor, CRUD for threads via ChappieDataStore
// • ProjectStore           — actor, CRUD for projects via ChappieDataStore
// • AppSettingsStore       — actor, CRUD for app settings via ChappieDataStore

// MARK: - Package Version

/// Current ChappieCore version.
public let coreVersion = "4.1.0"
