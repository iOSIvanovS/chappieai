//
//  AITunnelClient.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Сетевой клиент для работы с API AI-провайдера (AITunnel).
/// Что это: Структура, инкапсулирующая логику создания и отправки HTTP-запросов к нейросети.
/// Зачем: Изолирует сетевой слой от бизнес-логики приложения. Позволяет легко мокать запросы для тестов
/// или менять провайдера в будущем без переписывания ViewModel.
public struct AITunnelClient: Sendable {
    private let endpointURL = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!
    private let apiKey: String
    private let modelName: String
    
    /// Инициализатор
    /// - Parameters:
    ///   - apiKey: API ключ для доступа к сервису
    ///   - modelName: Имя модели (по умолчанию gemini-3.1-pro-preview-customtools)
    public init(apiKey: String, modelName: String = "gemini-3.1-pro-preview-customtools") {
        self.apiKey = apiKey
        self.modelName = modelName
    }
    
    /// Отправляет запрос к нейросети и получает ответ.
    /// - Parameters:
    ///   - systemPrompt: Базовые инструкции для нейросети (её роль, правила).
    ///   - chatHistory: Массив предыдущих сообщений для поддержания контекста беседы.
    ///   - tools: Массив доступных инструментов (функций), которые нейросеть может решить вызвать.
    /// - Returns: Кортеж, содержащий ответное сообщение (которое может быть текстом или вызовом инструмента),
    ///            потраченную сумму (если провайдер отдает) и остаток баланса.
    public func sendRequest(systemPrompt: String, chatHistory: [AIMessage], tools: [AITool]) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {
        
        var messages = [AIMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: chatHistory)
        
        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools
        )
        
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let encoder = JSONEncoder()
        do {
            request.httpBody = try encoder.encode(requestBody)
        } catch {
            throw ChappieError.parsingError("Не удалось закодировать запрос: \(error.localizedDescription)")
        }
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ChappieError.networkError(error.localizedDescription)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChappieError.networkError("Неверный тип ответа от сервера")
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка сервера"
            
            // Если слишком большой контекст, обычно возвращается 400 или 413, но лучше проверить текст ошибки
            if httpResponse.statusCode == 413 || errorMessage.lowercased().contains("context") || errorMessage.lowercased().contains("limit") {
                throw ChappieError.aiContextLimitExceeded
            }
            throw ChappieError.networkError("Код \(httpResponse.statusCode): \(errorMessage)")
        }
        
        let decoder = JSONDecoder()
        let result: AITunnelResponse
        do {
            result = try decoder.decode(AITunnelResponse.self, from: data)
        } catch {
            throw ChappieError.parsingError("Не удалось декодировать ответ от нейросети: \(error.localizedDescription)")
        }
        
        guard let choice = result.choices.first else {
            throw ChappieError.parsingError("Пустой ответ от модели")
        }
        
        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }
}
