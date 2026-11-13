import Foundation

// MARK: - Tool Definitions (Function Calling)

public struct AITool: Codable, Sendable {
    public let type: String
    public let function: AIFunctionDefinition

    public init(type: String = "function", function: AIFunctionDefinition) {
        self.type = type
        self.function = function
    }
}

public struct AIFunctionDefinition: Codable, Sendable {
    public let name: String
    public let description: String
    public let parameters: AIToolParameters

    public init(name: String, description: String, parameters: AIToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct AIToolParameters: Codable, Sendable {
    public var type: String = "object"
    public let properties: [String: AIToolProperty]
    public let required: [String]?

    public init(type: String = "object", properties: [String: AIToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct AIToolProperty: Codable, Sendable {
    public let type: String
    public let description: String?
    /// Shape of an array's elements. Without it an "array" property tells the model nothing about
    /// what to put inside, and a strict schema rejects an array that has no items.
    public let items: AIToolItemShape?

    public init(type: String, description: String?, items: AIToolItemShape? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

/// The element shape of an array argument, e.g. the operation objects of `json_edit`.
/// A class, not a struct: the shape may describe nested arrays, and a value type cannot hold itself.
public final class AIToolItemShape: Codable, Sendable {
    public let type: String
    public let description: String?
    public let items: AIToolItemShape?

    public init(type: String, description: String?, items: AIToolItemShape? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

// MARK: - Tool Call Models

public struct AIToolCall: Codable, Sendable {
    public var id: String
    public var type: String
    public var function: AIToolCallFunction

    public init(id: String, type: String, function: AIToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct AIToolCallFunction: Codable, Sendable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}
