// ChatMessage.swift
// Chappie
//
// WHY THIS FILE EXISTS:
// Formerly ChatMessage was a struct in ChappieViewModel.swift mixing two roles:
//   1. A regular user/AI text message (text, cost)
//   2. A technical tool-call log ("🛠 Executing: write_file -> ...")
// Mixing roles in one type is a classic code smell. MessageBubbleView could not
// render them differently; chat history was polluted with technical strings;
// filtering in ViewModel was fragile (checking string content!).
//
// SOLUTION (ТД-6):
// ChatMessage becomes an enum with two semantically clear cases.
// MessageBubbleView now knows exactly what to render — and does it beautifully.
//
// CHANGE (ТД-COST-SUMMARY — Self-Summary):
// Added field `summary: String?` to the .message case.
// This is a brief digest of Chappie's response extracted from the <summary>...</summary> tag.
// When building history for the API: if summary is present and the message is "old"
// (outside the recent window) — the summary is substituted for the full text.
// This radically reduces token count without losing context meaning.
//
// CHANGE (MULTIMODAL):
// Added field `attachments: [AttachedFile]` to the .message case.
// Attachments are stored inline (base64 in JSON) for persistence simplicity.
// The API layer (AIOrchestrator) reads attachments and builds multimodal content blocks.
// MessageBubbleView renders image thumbnails inline and file chips for other types.
//
// CHANGE (TERMINAL-CONFIRM):
// Added .terminalConfirmation case for inline run/cancel UI when terminal is in confirm mode.
// This case is NOT persisted to disk (filtered on save/load) — it's ephemeral UI state.
// When the user approves or cancels, the case is replaced with a .message result.

import Foundation

/// A single unit of chat history — either a text message, a tool-call log,
/// or an inline terminal confirmation prompt.
///
/// WHY ENUM, NOT STRUCT WITH FLAG: An enum with associated values makes it impossible
/// to create an "invalid" state. You can't accidentally create a message with
/// `isToolCall: true` and a `cost` field. The compiler enforces correctness
/// via exhaustive switch.
public enum ChatMessage: Identifiable, Hashable, Codable {

    // MARK: - Cases

    /// A regular text message — from the user or from the AI.
    ///
    /// - isUser: true = user (right, blue), false = Chappie (left, neutral)
    /// - text: Message text (supports Markdown). For Chappie responses: full text
    ///   WITHOUT the <summary> tag (already extracted and hidden).
    /// - cost: Request cost in RUB — only on final AI responses.
    /// - summary: Brief digest extracted from <summary>...</summary>.
    ///   nil for user messages and short responses without the tag.
    ///   Used when building API history instead of the full text.
    /// - attachments: Files attached by the user. Empty array for AI responses.
    ///   Stored inline as base64 for persistence.
    case message(
        id: UUID = UUID(),
        isUser: Bool,
        text: String,
        cost: Double? = nil,
        summary: String? = nil,
        attachments: [AttachedFile] = []
    )

    /// A tool-call log — a technical step in the agentic cycle.
    ///
    /// WHY KEEP IN HISTORY: The user needs to see Chappie's "thought process" —
    /// which files were read, what was written. Transparency builds trust.
    /// But these records are filtered out when preparing context for the API —
    /// the model doesn't need to know about its own past tool calls.
    ///
    /// - toolName: Tool name ("write_file", "read_file", "memorize", etc.)
    /// - targetPath: File path or memory key (empty string if none)
    case toolCall(id: UUID = UUID(), toolName: String, targetPath: String)

    /// Inline terminal confirmation prompt — shown when terminalAccess == .confirm.
    ///
    /// WHY A SEPARATE CASE: The confirmation UI is fundamentally different from a
    /// text message — it has action buttons and is ephemeral (not persisted to disk).
    /// Encoding it as a .message with special text would require fragile string parsing.
    ///
    /// - command: The shell command awaiting user approval.
    /// - threadId: The thread whose shell session will execute the command.
    ///
    /// LIFECYCLE: Inserted into messages[] when PendingTerminalCommand is detected.
    /// Replaced with a .message (result or "cancelled") when the user decides.
    /// Filtered out on save so it never pollutes persistent history.
    case terminalConfirmation(id: UUID = UUID(), command: String, threadId: UUID)

    // MARK: - Identifiable

    /// Unique identifier — needed for ForEach and ScrollViewReader.scrollTo()
    public var id: UUID {
        switch self {
        case .message(let id, _, _, _, _, _): return id
        case .toolCall(let id, _, _): return id
        case .terminalConfirmation(let id, _, _): return id
        }
    }

    // MARK: - Convenience Computed Properties

    /// Whether this is a user message (for filtering when building the API context).
    public var isUser: Bool {
        switch self {
        case .message(_, let isUser, _, _, _, _): return isUser
        case .toolCall: return false
        case .terminalConfirmation: return false
        }
    }

    /// Message text — only for .message case, nil otherwise.
    public var text: String? {
        switch self {
        case .message(_, _, let text, _, _, _): return text
        case .toolCall: return nil
        case .terminalConfirmation: return nil
        }
    }

    /// Request cost — only for final AI responses.
    public var cost: Double? {
        switch self {
        case .message(_, _, _, let cost, _, _): return cost
        case .toolCall: return nil
        case .terminalConfirmation: return nil
        }
    }

    /// Brief response digest for substitution in API history.
    ///
    /// Present only on Chappie responses (isUser == false) where the model
    /// added a <summary> tag at the end of the response.
    public var summary: String? {
        switch self {
        case .message(_, _, _, _, let summary, _): return summary
        case .toolCall: return nil
        case .terminalConfirmation: return nil
        }
    }

    /// Files attached to this message. Empty for AI responses and tool calls.
    public var attachments: [AttachedFile] {
        switch self {
        case .message(_, _, _, _, _, let attachments): return attachments
        case .toolCall: return []
        case .terminalConfirmation: return []
        }
    }

    /// Whether this is a tool-call log entry.
    public var isToolCall: Bool {
        if case .toolCall = self { return true }
        return false
    }

    /// Whether this is an ephemeral terminal confirmation prompt.
    public var isTerminalConfirmation: Bool {
        if case .terminalConfirmation = self { return true }
        return false
    }

    // MARK: - Codable (manual — enum with associated values)

    // WHY MANUAL: Swift cannot auto-synthesize Codable for enums with associated values
    // if a specific JSON format is required. We want a readable, forward-compatible format.

    private enum CodingKeys: String, CodingKey {
        case type, id, isUser, text, cost, summary, attachments, toolName, targetPath
        case command, threadId
    }

    private enum MessageType: String, Codable {
        case message, toolCall, terminalConfirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(MessageType.self, forKey: .type) ?? .message
        let id   = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        switch type {
        case .message:
            let isUser      = try container.decode(Bool.self, forKey: .isUser)
            let text        = try container.decode(String.self, forKey: .text)
            let cost        = try container.decodeIfPresent(Double.self, forKey: .cost)
            let summary     = try container.decodeIfPresent(String.self, forKey: .summary)
            let attachments = try container.decodeIfPresent([AttachedFile].self, forKey: .attachments) ?? []
            self = .message(id: id, isUser: isUser, text: text, cost: cost, summary: summary, attachments: attachments)

        case .toolCall:
            let toolName   = try container.decode(String.self, forKey: .toolName)
            let targetPath = try container.decodeIfPresent(String.self, forKey: .targetPath) ?? ""
            self = .toolCall(id: id, toolName: toolName, targetPath: targetPath)

        case .terminalConfirmation:
            // Ephemeral — should never be decoded from disk, but handle gracefully.
            let command  = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
            let threadId = try container.decodeIfPresent(UUID.self, forKey: .threadId) ?? UUID()
            self = .terminalConfirmation(id: id, command: command, threadId: threadId)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .message(let id, let isUser, let text, let cost, let summary, let attachments):
            try container.encode(MessageType.message, forKey: .type)
            try container.encode(id,     forKey: .id)
            try container.encode(isUser, forKey: .isUser)
            try container.encode(text,   forKey: .text)
            try container.encodeIfPresent(cost,    forKey: .cost)
            try container.encodeIfPresent(summary, forKey: .summary)
            if !attachments.isEmpty {
                try container.encode(attachments, forKey: .attachments)
            }

        case .toolCall(let id, let toolName, let targetPath):
            try container.encode(MessageType.toolCall, forKey: .type)
            try container.encode(id,         forKey: .id)
            try container.encode(toolName,   forKey: .toolName)
            try container.encode(targetPath, forKey: .targetPath)

        case .terminalConfirmation(let id, let command, let threadId):
            // Ephemeral — encode as a placeholder so it round-trips if needed,
            // but ViewModel filters these out before saving to disk.
            try container.encode(MessageType.terminalConfirmation, forKey: .type)
            try container.encode(id,       forKey: .id)
            try container.encode(command,  forKey: .command)
            try container.encode(threadId, forKey: .threadId)
        }
    }
}
