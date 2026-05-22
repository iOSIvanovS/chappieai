//
//  AITunnelModels.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

// MARK: - Request Models

/// Модель запроса к API AI-провайдера.
/// Что это: Структура данных, описывающая параметры запроса (какую модель используем, сообщения, инструменты).
/// Зачем: Используется для сериализации в JSON при отправке POST-запроса на сервер.
public struct AITunnelRequest: Encodable {
    public let model: String
    public let messages: [AIMessage]
    public let temperature: Double?
    public let tools: [AITool]?
    
    public init(model: String, messages: [AIMessage], temperature: Double? = nil, tools: [AITool]? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
    }
}

/// Модель единичного сообщения в чате.
/// Что это: Сообщение, которое может исходить от пользователя, ассистента, системы или инструмента.
/// Зачем: Формирует контекст для нейросети.
public struct AIMessage: Codable {
    public var role: String
    public var content: String?
    public var tool_calls: [AIToolCall]?
    public var tool_call_id: String?
    public var name: String?
    
    public init(role: String, content: String? = nil, tool_calls: [AIToolCall]? = nil, tool_call_id: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.tool_calls = tool_calls
        self.tool_call_id = tool_call_id
        self.name = name
    }
}

// MARK: - Functions and Schemas (Function Calling)

/// Модель инструмента (Tool), доступного нейросети.
/// Что это: Обертка над функцией, которую ИИ может вызвать.
/// Зачем: API требует передавать инструменты в массиве с указанием типа (обычно "function").
public struct AITool: Codable {
    public let type: String
    public let function: AIFunctionDefinition
    
    public init(type: String = "function", function: AIFunctionDefinition) {
        self.type = type
        self.function = function
    }
}

/// Описание самой функции для инструмента.
/// Что это: Имя, описание и параметры функции.
/// Зачем: Нейросеть читает описание и решает, когда и с какими аргументами вызывать функцию.
public struct AIFunctionDefinition: Codable {
    public let name: String
    public let description: String
    public let parameters: AIToolParameters
    
    public init(name: String, description: String, parameters: AIToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Параметры функции в формате JSON Schema.
/// Что это: Описание входных аргументов (какие поля есть, их типы, какие обязательны).
/// Зачем: Позволяет строго типизировать аргументы, которые генерирует нейросеть.
public struct AIToolParameters: Codable {
    public let type: String
    public let properties: [String: AIToolProperty]
    public let required: [String]?
    
    public init(type: String = "object", properties: [String: AIToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

/// Описание отдельного свойства (аргумента) функции.
/// Что это: Тип данных (например, "string") и его описание для нейросети.
/// Зачем: Помогает ИИ правильно заполнить конкретное поле аргумента.
public struct AIToolProperty: Codable {
    public let type: String
    public let description: String?
    
    public init(type: String, description: String?) {
        self.type = type
        self.description = description
    }
}

// MARK: - Response Models

/// Модель ответа от API AI-провайдера.
/// Что это: Структура данных, возвращаемая сервером после успешного запроса.
/// Зачем: Для десериализации JSON-ответа и получения сгенерированного сообщения или вызова инструмента.
public struct AITunnelResponse: Decodable {
    public let id: String?
    public let choices: [AIChoice]
    public let usage: AIUsage?
}

/// Вариант ответа (Choice), сгенерированный нейросетью.
/// Что это: Содержит само сообщение и причину завершения генерации.
/// Зачем: Обычно берется первый элемент из массива `choices`.
public struct AIChoice: Decodable {
    public let message: AIMessage
    public let finish_reason: String?
}

/// Статистика использования токенов.
/// Что это: Информация о потраченных токенах и балансе (если поддерживается провайдером).
/// Зачем: Для аналитики и контроля расходов.
public struct AIUsage: Decodable {
    public let prompt_tokens: Int?
    public let completion_tokens: Int?
    public let total_tokens: Int?
    public let cost_rub: Double?
    public let balance: Double?
}

// MARK: - Tool Call Models

/// Вызов инструмента, инициированный нейросетью.
/// Что это: Идентификатор вызова, тип и сама функция с аргументами.
/// Зачем: Нейросеть возвращает этот объект, когда хочет выполнить действие на нашей стороне.
public struct AIToolCall: Codable {
    public let id: String
    public let type: String
    public let function: AIToolCallFunction
}

/// Функция в рамках вызова инструмента.
/// Что это: Имя вызванной функции и её аргументы в виде JSON-строки.
/// Зачем: Мы парсим `arguments` и выполняем соответствующую логику в приложении.
public struct AIToolCallFunction: Codable {
    public let name: String
    public let arguments: String
}
