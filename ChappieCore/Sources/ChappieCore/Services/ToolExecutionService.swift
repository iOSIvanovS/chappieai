//
//  ToolExecutionService.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Что это: Сервис для управления и выполнения инструментов (tools), доступных ИИ.
/// Зачем: Инкапсулирует логику определения доступных инструментов и их выполнения, разгружая ViewModel.
public final class ToolExecutionService: Sendable {
    
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
            )),
            AITool(type: "function", function: AIFunctionDefinition(
                name: "delete_memory",
                description: "Удалить запись из долгосрочной памяти по ключу (лоботомия).",
                parameters: AIToolParameters(type: "object", properties: [
                    "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно удалить.")
                ], required: ["key"])
            ))
        ]
    }
    
    // MARK: - Строгие модели для парсинга аргументов
    private struct ReadFileArgs: Decodable { let path: String }
    private struct WriteFileArgs: Decodable { let path: String; let content: String }
    private struct DeleteFileArgs: Decodable { let path: String }
    private struct MemorizeArgs: Decodable { let key: String; let type: String; let jsonString: String }
    private struct RecallArgs: Decodable { let key: String }
    private struct SearchMemoryArgs: Decodable { let type: String }
    private struct DeleteMemoryArgs: Decodable { let key: String }
    
    /// Выполняет конкретный инструмент (AIToolCall) и возвращает результат в виде строки
    public func execute(call: AIToolCall) async -> String {
        let data = call.function.arguments.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()
        
        do {
            switch call.function.name {
            case "read_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                let args = try decoder.decode(ReadFileArgs.self, from: data)
                return try await fs.readFile(at: args.path)
                
            case "write_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                let args = try decoder.decode(WriteFileArgs.self, from: data)
                try await fs.writeFile(at: args.path, content: args.content)
                return "Файл успешно записан/изменен."
                
            case "delete_file":
                guard let fs = fileSystem else { return "Системная ошибка: Файловый менеджер недоступен" }
                let args = try decoder.decode(DeleteFileArgs.self, from: data)
                try await fs.deleteFile(at: args.path)
                return "Файл успешно удален."
                
            case "memorize":
                let args = try decoder.decode(MemorizeArgs.self, from: data)
                await MemoryManager.shared.saveMemory(key: args.key, type: args.type, jsonString: args.jsonString)
                return "Успешно сохранено в память."
                
            case "recall":
                let args = try decoder.decode(RecallArgs.self, from: data)
                if let memory = await MemoryManager.shared.readMemory(key: args.key) {
                    return memory
                } else {
                    return "Память по ключу '\(args.key)' не найдена."
                }
                
            case "search_memory":
                let args = try decoder.decode(SearchMemoryArgs.self, from: data)
                let results = await MemoryManager.shared.searchMemory(type: args.type)
                if results.isEmpty {
                    return "Память по типу '\(args.type)' не найдена."
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: results),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    return jsonString
                }
                return "Ошибка сериализации результатов поиска."
                
            case "delete_memory":
                let args = try decoder.decode(DeleteMemoryArgs.self, from: data)
                await MemoryManager.shared.deleteMemory(key: args.key)
                return "Память по ключу '\(args.key)' успешно удалена."
                
            default:
                return "Ошибка: Неизвестная функция"
            }
        } catch let error as DecodingError {
            return "Ошибка парсинга аргументов: \(error.localizedDescription)"
        } catch let error as ChappieError {
            // Если пробросилась наша кастомная ошибка, возвращаем её описание
            return error.localizedDescription
        } catch {
            return "Ошибка выполнения функции: \(error.localizedDescription)"
        }
    }
}
