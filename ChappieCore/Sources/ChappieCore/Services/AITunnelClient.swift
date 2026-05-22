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
public struct AITunnelClient {
    private let endpointURL = URL(string: "https://api.aitunnel.ru/v1/chat/completions")!
    private let apiKey = "REMOVED_API_KEY"
    private let modelName = "gemini-3.1-pro-preview-customtools"
    
    /// Инициализатор по умолчанию.
    public init() {}
    
    /// Отправляет запрос к нейросети и получает ответ.
    /// - Parameters:
    ///   - systemPrompt: Базовые инструкции для нейросети (её роль, правила).
    ///   - chatHistory: Массив предыдущих сообщений для поддержания контекста беседы.
    ///   - tools: Массив доступных инструментов (функций), которые нейросеть может решить вызвать.
    /// - Returns: Кортеж, содержащий ответное сообщение (которое может быть текстом или вызовом инструмента),
    ///            потраченную сумму (если провайдер отдает) и остаток баланса.
    public func sendRequest(systemPrompt: String, chatHistory: [AIMessage], tools: [AITool]) async throws -> (message: AIMessage, cost: Double?, balance: Double?) {
        
        // Формируем полный массив сообщений: сначала системный промпт, затем история чата
        var messages = [AIMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: chatHistory)
        
        // Создаем тело запроса. Если массив инструментов пуст, передаем nil, чтобы не смущать API.
        let requestBody = AITunnelRequest(
            model: modelName,
            messages: messages,
            temperature: 0.7,
            tools: tools.isEmpty ? nil : tools
        )
        
        // Настраиваем HTTP-запрос
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Кодируем тело запроса в JSON
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        
        // Выполняем сетевой запрос
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Проверяем статус-код ответа
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка сервера"
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ошибка HTTP: \(errorMessage)"])
        }
        
        // Декодируем успешный ответ
        let decoder = JSONDecoder()
        let result = try decoder.decode(AITunnelResponse.self, from: data)
        
        // Извлекаем первый вариант ответа (обычно он один)
        guard let choice = result.choices.first else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "Пустой ответ от модели"])
        }
        
        // Возвращаем само сообщение и финансовую статистику
        return (choice.message, result.usage?.cost_rub, result.usage?.balance)
    }
}
