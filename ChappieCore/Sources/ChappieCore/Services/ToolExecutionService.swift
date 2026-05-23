//
//  ToolExecutionService.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Сервис выполнения инструментов (функций) ИИ.
/// Что это: Сервис, который принимает вызов функции от ИИ, парсит аргументы и выполняет соответствующее действие.
/// Зачем: Предоставляет "инструменты" (Tools / Function Calling) для ИИ-агента, связывая его с файловой системой, памятью и другими агентами.
public actor ToolExecutionService {
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager
    private let apiKey: String
    
    /// Инициализатор сервиса.
    /// - Parameters:
    ///   - fileSystem: Менеджер файловой системы проекта.
    ///   - memoryManager: Менеджер долгосрочной памяти.
    ///   - apiKey: API ключ для доступа к AITunnel (необходим для работы саб-агентов).
    public init(fileSystem: FileSystemManager, memoryManager: MemoryManager, apiKey: String) {
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        self.apiKey = apiKey
    }
    
    /// Массив доступных ИИ-агенту инструментов.
    /// Этот массив передается в API запросы, чтобы модель знала, какие функции она может вызывать.
    public var availableTools: [AITool] {
        return [
            AITool(function: AIFunctionDefinition(
                name: "list_files",
                description: "Получить список всех файлов в проекте (относительные пути).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),
            AITool(function: AIFunctionDefinition(
                name: "read_file",
                description: "Прочитать содержимое файла в проекте.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу")
                    ],
                    required: ["path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "write_file",
                description: "Создать новый или полностью перезаписать существующий файл (подпапки создадутся автоматически).",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу"),
                        "content": AIToolProperty(type: "string", description: "Полный код или текст для записи в файл")
                    ],
                    required: ["path", "content"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "delete_file",
                description: "Удалить файл из проекта.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к удаляемому файлу")
                    ],
                    required: ["path"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: "Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для запоминания"),
                        "type": AIToolProperty(type: "string", description: "Тип данных (например: rule, fact, persona, project_map)"),
                        "jsonString": AIToolProperty(type: "string", description: "Данные в формате JSON строки"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: project (по умолчанию) или global"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для сохранения памяти строго в этом таргете")
                    ],
                    required: ["key", "type", "jsonString"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "recall",
                description: "Вспомнить информацию из долгосрочной памяти по ключу.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно вспомнить"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для поиска памяти строго в этом таргете")
                    ],
                    required: ["key"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "search_memory",
                description: "Найти все записи в памяти по определенному типу.",
                parameters: AIToolParameters(
                    properties: [
                        "type": AIToolProperty(type: "string", description: "Тип данных для поиска (например: rule, fact)"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для поиска памяти строго в этом таргете")
                    ],
                    required: ["type"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "delete_memory",
                description: "Удалить запись из долгосрочной памяти по ключу.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для удаления"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного таргета (например, Chappie или ChappieCore) для удаления памяти строго из этого таргета")
                    ],
                    required: ["key"]
                )
            )),
            AITool(function: AIFunctionDefinition(
                name: "delegate_task",
                description: "Делегировать выполнение узкой задачи саб-агенту (Senior, Middle, Junior). Возвращает готовый код или результат работы.",
                parameters: AIToolParameters(
                    properties: [
                        "role": AIToolProperty(type: "string", description: "Уровень саб-агента: senior (сложная архитектура), middle (рутина, UI, CRUD), junior (комментарии, рефакторинг)"),
                        "task": AIToolProperty(type: "string", description: "Четкое ТЗ для саб-агента, что именно нужно сделать"),
                        "context": AIToolProperty(type: "string", description: "Узкий контекст: только те файлы или куски кода, которые нужны для выполнения задачи"),
                        "guidelines": AIToolProperty(type: "string", description: "Дополнительные правила (опционально)")
                    ],
                    required: ["role", "task", "context"]
                )
            ))
        ]
    }
    
    /// Выполняет указанный инструмент и возвращает строковый результат.
    /// - Parameter call: Объект вызова инструмента с именем и JSON-аргументами.
    /// - Returns: Результат выполнения в виде строки (успех или описание ошибки).
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()
        
        do {
            switch name {
            case "list_files":
                let files = try await fileSystem.listFiles()
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(files)
                return String(data: data, encoding: .utf8) ?? "[]"
                
            case "read_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"] else {
                    return "Ошибка: Неверные аргументы для read_file"
                }
                return try await fileSystem.readFile(at: path)
                
            case "write_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"],
                      let content = args["content"] else {
                    return "Ошибка: Неверные аргументы для write_file"
                }
                try await fileSystem.writeFile(at: path, content: content)
                return "Успешно: Файл \(path) записан."
                
            case "delete_file":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let path = args["path"] else {
                    return "Ошибка: Неверные аргументы для delete_file"
                }
                try await fileSystem.deleteFile(at: path)
                return "Успешно: Файл \(path) удален."
                
            case "memorize":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"],
                      let type = args["type"],
                      let jsonString = args["jsonString"] else {
                    return "Ошибка: Неверные аргументы для memorize"
                }
                let scopeString = args["scope"] ?? "project"
                let scope = MemoryScope(rawValue: scopeString) ?? .project
                let targetName = args["targetName"]
                await memoryManager.saveMemory(key: key, type: type, jsonString: jsonString, scope: scope, targetName: targetName)
                return "Успешно: Запись \(key) сохранена в памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."
                
            case "recall":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для recall"
                }
                let targetName = args["targetName"]
                if let record = await memoryManager.readMemory(key: key, targetName: targetName) {
                    return record
                } else {
                    return "Запись по ключу \(key) не найдена в памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."
                }
                
            case "search_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let type = args["type"] else {
                    return "Ошибка: Неверные аргументы для search_memory"
                }
                let targetName = args["targetName"]
                let results = await memoryManager.searchMemory(type: type, targetName: targetName)
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(results)
                return String(data: data, encoding: .utf8) ?? "{}"
                
            case "delete_memory":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для delete_memory"
                }
                let targetName = args["targetName"]
                await memoryManager.deleteMemory(key: key, targetName: targetName)
                return "Успешно: Запись \(key) удалена из памяти \(targetName != nil ? "таргета \(targetName!)" : "проекта")."
                
            case "delegate_task":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let role = args["role"],
                      let task = args["task"],
                      let context = args["context"] else {
                    return "Ошибка: Неверные аргументы для delegate_task"
                }
                let guidelines = args["guidelines"] ?? ""
                return try await delegateToSubAgent(role: role, task: task, context: context, guidelines: guidelines)
                
            default:
                return "Ошибка: Неизвестный инструмент \(name)"
            }
        } catch {
            return "Ошибка при выполнении \(name): \(error.localizedDescription)"
        }
    }
    
    /// Вспомогательный метод для делегирования задачи саб-агенту через AITunnel.
    /// - Parameters:
    ///   - role: Роль исполнителя (senior, middle, junior).
    ///   - task: Текст технического задания.
    ///   - context: Исходный код или файлы, необходимые для выполнения.
    ///   - guidelines: Дополнительные инструкции и правила.
    /// - Returns: Код или текстовый ответ от саб-агента.
    private func delegateToSubAgent(role: String, task: String, context: String, guidelines: String) async throws -> String {
        // Определяем модель в зависимости от назначенной роли
        let model: String
        let roleDescription: String
        switch role.lowercased() {
        case "senior":
            model = "claude-sonnet-4.6" // Claude Sonnet 4.6 — лучший выбор для сложного рефакторинга и архитектуры
            roleDescription = "Senior macOS/iOS Developer (Claude Sonnet 4.6)"
        case "middle":
            model = "gpt-5.4-mini" // GPT 5.4 Mini — быстрая и надежная модель для стандартной верстки и CRUD
            roleDescription = "Middle macOS/iOS Developer (GPT 5.4 Mini)"
        case "junior":
            model = "gemini-3.1-flash-lite" // Gemini 3.1 Flash Lite — идеальный выбор для мелких правок и форматирования
            roleDescription = "Junior macOS/iOS Developer (Gemini 3.1 Flash Lite)"
        default:
            model = "gpt-5.4-mini"
            roleDescription = "Middle macOS/iOS Developer (GPT 5.4 Mini)"
        }
        
        let client = AITunnelClient(apiKey: apiKey, modelName: model)
        
        let systemPrompt = """
        Ты — \(roleDescription) в виртуальной команде разработки под macOS/iOS (SwiftUI, Swift 6).
        Твоя задача — выполнить конкретное ТЗ, используя предоставленный контекст.
        
        CRITICAL RULE (ПРИНЦИП ОТЧУЖДАЕМОСТИ КОДА):
        Весь создаваемый тобой код должен быть плотно обложен понятными и подробными комментариями на грамотном русском языке.
        Комментарии должны объяснять ПОЧЕМУ написан этот код, а не только ЧТО он делает. Любой сторонний разработчик должен мгновенно разобраться в кодовой базе.
        Пиши только чистый, рабочий и компилируемый Swift-код. Не пиши никаких лишних рассуждений до или после кода. Возвращай только код в тройных обратных кавычках.
        """
        
        let userPrompt = """
        ЗАДАЧА:
        \(task)
        
        КОНТЕКСТ (КОД И ФАЙЛЫ):
        \(context)
        
        \(guidelines.isEmpty ? "" : "ДОПОЛНИТЕЛЬНЫЕ ПРАВИЛА:\n\(guidelines)")
        """
        
        let (message, _, _) = try await client.sendRequest(
            systemPrompt: systemPrompt,
            chatHistory: [AIMessage(role: "user", content: userPrompt)],
            tools: []
        )
        
        return message.content ?? "Ошибка: Пустой ответ от саб-агента."
    }
}
