//
//  ToolExecutionService.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Сервис выполнения инструментов (функций) ИИ.
///
/// Что это: Сервис, который принимает вызов функции от ИИ, парсит аргументы
/// и выполняет соответствующее действие в файловой системе или памяти.
///
/// Зачем: Предоставляет "инструменты" (Tools / Function Calling) для ИИ-агента,
/// связывая его с файловой системой и менеджером памяти.
///
/// Архитектурное решение: После перехода к монофизитной архитектуре (один агент —
/// Чаппи) инструмент `delegate_task` был полностью удалён. Он был концептуально
/// мёртв: в `execute()` не было его обработки, и любой вызов падал в `default`
/// с ошибкой "Неизвестный инструмент". Теперь `apiKey` тоже не нужен —
/// никаких саб-агентов нет.
public actor ToolExecutionService {
    private let fileSystem: FileSystemManager
    private let memoryManager: MemoryManager

    /// Инициализатор сервиса.
    /// - Parameters:
    ///   - fileSystem: Менеджер файловой системы проекта.
    ///   - memoryManager: Менеджер долгосрочной памяти.
    public init(fileSystem: FileSystemManager, memoryManager: MemoryManager) {
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
    }

    /// Массив доступных ИИ-агенту инструментов.
    ///
    /// Этот массив передаётся в каждый API-запрос, чтобы модель знала,
    /// какие функции она может вызывать. Список строго соответствует
    /// монофизитной архитектуре: только файловая система и память.
    public var availableTools: [AITool] {
        return [
            // --- Инструменты файловой системы ---

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

            // --- Инструменты долгосрочной памяти ---

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
            ))
        ]
    }

    /// Выполняет указанный инструмент и возвращает строковый результат.
    ///
    /// Зачем возвращать строку: API Claude ожидает результат вызова инструмента
    /// в виде строки — она добавляется в историю чата как сообщение с ролью "tool".
    ///
    /// - Parameter call: Объект вызова инструмента с именем и JSON-аргументами.
    /// - Returns: Результат выполнения в виде строки (успех или описание ошибки).
    public func execute(call: AIToolCall) async -> String {
        let name = call.function.name
        let argsData = call.function.arguments.data(using: .utf8) ?? Data()

        do {
            switch name {

            // MARK: - Файловая система

            case "list_files":
                // Возвращаем список файлов в виде JSON-массива строк
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
                return "Успешно: Файл \(path) удалён."

            // MARK: - Долгосрочная память

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
                await memoryManager.saveMemory(
                    key: key,
                    type: type,
                    jsonString: jsonString,
                    scope: scope,
                    targetName: targetName
                )
                let location = targetName.map { "таргета \($0)" } ?? "проекта"
                return "Успешно: Запись '\(key)' сохранена в памяти \(location)."

            case "recall":
                guard let args = try? JSONDecoder().decode([String: String].self, from: argsData),
                      let key = args["key"] else {
                    return "Ошибка: Неверные аргументы для recall"
                }
                let targetName = args["targetName"]
                if let record = await memoryManager.readMemory(key: key, targetName: targetName) {
                    return record
                } else {
                    let location = targetName.map { "таргета \($0)" } ?? "проекта"
                    return "Запись по ключу '\(key)' не найдена в памяти \(location)."
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
                let location = targetName.map { "таргета \($0)" } ?? "проекта"
                return "Успешно: Запись '\(key)' удалена из памяти \(location)."

            default:
                // Сюда не должны попадать никакие известные инструменты.
                // Если попали — значит, модель вызвала что-то несуществующее.
                return "Ошибка: Неизвестный инструмент '\(name)'. Доступные инструменты: list_files, read_file, write_file, delete_file, memorize, recall, search_memory, delete_memory."
            }
        } catch {
            return "Ошибка при выполнении '\(name)': \(error.localizedDescription)"
        }
    }
}
