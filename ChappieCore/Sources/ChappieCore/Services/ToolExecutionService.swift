//
//  ToolExecutionService.swift
//  ChappieCore
//
//  Created by Chappie on 21.05.2026.
//

import Foundation

/// Что это: Сервис для управления и выполнения инструментов (tools), доступных ИИ.
/// Зачем: Инкапсулирует логику определения доступных инструментов и их выполнения, разгружая ViewModel.
public final class ToolExecutionService {
    
    private let fileSystem: FileSystemManager?
    
    public init(fileSystem: FileSystemManager?) {
        self.fileSystem = fileSystem
    }
    
    /// Список доступных ИИ инструментов
    public var availableTools: [AITool] {
        return [
            AITool(type: "function", function: AIFunctionDefinition(
                name: "read_file",
                description: "Прочитать содержимое файла в проекте",
                parameters: AIToolParameters(type: "object", properties: ["path": AIToolProperty(type: "string", description: "Относительный путь к файлу")], required: ["path"])
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "write_file",
                description: "Создать новый или полностью перезаписать существующий файл (подпапки создадутся автоматически)",
                parameters: AIToolParameters(type: "object", properties: [
                    "path": AIToolProperty(type: "string", description: "Относительный путь"),
                    "content": AIToolProperty(type: "string", description: "Полный код или текст для записи в файл")
                ], required: ["path", "content"])
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "delete_file",
                description: "Удалить файл из проекта",
                parameters: AIToolParameters(type: "object", properties: ["path": AIToolProperty(type: "string", description: "Относительный путь к удаляемому файлу")], required: ["path"])
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "memorize",
                description: "Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.",
                parameters: AIToolParameters(type: "object", properties: [
                    "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для запоминания (например: 'architecture_rules', 'user_persona')"),
                    "type": AIToolProperty(type: "string", description: "Тип данных (например: 'rule', 'fact', 'persona', 'project_map')"),
                    "jsonString": AIToolProperty(type: "string", description: "Сами данные в формате JSON строки. Сериализуй сложные структуры здесь.")
                ], required: ["key", "type", "jsonString"])
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "recall",
                description: "Вспомнить информацию из долгосрочной памяти по ключу.",
                parameters: AIToolParameters(type: "object", properties: [
                    "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно вспомнить.")
                ], required: ["key"])
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "search_memory",
                description: "Найти все записи в памяти по определенному типу.",
                parameters: AIToolParameters(type: "object", properties: [
                    "type": AIToolProperty(type: "string", description: "Тип данных для поиска (например: 'rule', 'fact').")
                ], required: ["type"])
            ))
        ]
    }
    
    /// Выполняет конкретный инструмент (AIToolCall) и возвращает результат в виде строки
    public func execute(call: AIToolCall) async -> String {
        do {
            let data = call.function.arguments.data(using: .utf8) ?? Data()
            let args = try JSONSerialization.jsonObject(with: data) as? [String: String] ?? [:]
            
            switch call.function.name {
            case "read_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                guard let path = args["path"] else { return "Ошибка: не указан path" }
                return try await fs.readFile(at: path)
                
            case "write_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                guard let path = args["path"], let content = args["content"] else { return "Ошибка: не указан path или content" }
                try await fs.writeFile(at: path, content: content)
                return "Файл успешно записан/изменен."
                
            case "delete_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                guard let path = args["path"] else { return "Ошибка: не указан path" }
                try await fs.deleteFile(at: path)
                return "Файл успешно удален."
                
            case "memorize":
                guard let key = args["key"], let type = args["type"], let jsonString = args["jsonString"] else {
                    return "Ошибка: не указаны key, type или jsonString"
                }
                await MemoryManager.shared.saveMemory(key: key, type: type, jsonString: jsonString)
                return "Успешно сохранено в память."
                
            case "recall":
                guard let key = args["key"] else { return "Ошибка: не указан key" }
                if let memory = await MemoryManager.shared.readMemory(key: key) {
                    return memory
                } else {
                    return "Память по ключу '\(key)' не найдена."
                }
                
            case "search_memory":
                guard let type = args["type"] else { return "Ошибка: не указан type" }
                let results = await MemoryManager.shared.searchMemory(type: type)
                if results.isEmpty {
                    return "Память по типу '\(type)' не найдена."
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: results),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    return jsonString
                }
                return "Ошибка сериализации результатов поиска."
                
            default:
                return "Ошибка: Неизвестная функция"
            }
        } catch {
            return "Ошибка выполнения функции: \(error.localizedDescription)"
        }
    }
}
