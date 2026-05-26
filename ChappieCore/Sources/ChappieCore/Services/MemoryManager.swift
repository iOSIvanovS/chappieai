// MemoryManager.swift
// ChappieCore
//
// Менеджер памяти — центральный компонент системы контекстной памяти ИИ-ассистента.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ: Используем actor для обеспечения безопасного конкурентного доступа
// в Swift 6. Это гарантирует, что все операции с файловой системой выполняются последовательно,
// исключая состояния гонки при параллельных запросах от нескольких чатов или агентов.
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-08):
// 1. Глобальная (scope = "global")     — факты, стиль общения, кросс-проектные правила
// 2. Проектная  (scope = "<projectId>") — архитектура, пайплайны, договорённости проекта
// 3. Тредовая   (scope = "<threadId>") — контекст текущей задачи, временные заметки
//
// МАППИНГ SCOPE (IT-08):
// ToolExecutionService передаёт ActiveMemoryContext при каждом вызове инструмента памяти.
// MemoryManager.resolveScope() преобразует (scope, targetName) → строку scope для MemoryStore:
//   - scope="global"       → "global"
//   - scope="thread"       → UUID активного треда (из ActiveMemoryContext.threadId)
//   - targetName="Chappie" → UUID проекта с именем "Chappie" (из ActiveMemoryContext.projects)
//
// РАЗРЕШЕНИЕ КОНФЛИКТОВ (IT-08):
// Если инструмент указывает targetName="Chappie" но в треде нет такого проекта —
// возвращаем ошибку с подсказкой. Чаппи должен сначала добавить проект через add_project_to_thread.
//
// ДВОЙНОЙ БЭКЕНД (IT-03 → IT-08):
// MemoryManager работает с ДВУМЯ бэкендами:
// 1. Файловый (legacy): ~/Documents/Chappie/semantic.json — для обратной совместимости
// 2. SwiftData (новый): MemoryStore — для трёхуровневой памяти
//
// После IT-08 инструменты memorize/recall/search/delete пишут ТОЛЬКО в SwiftData.
// Файловый бэкенд используется только для buildSystemPrompt (legacy блок) и миграции.
//
// ФИНАЛЬНАЯ СТРУКТУРА ПАМЯТИ:
//
//   SwiftData MemoryEntity              — ОСНОВНОЙ бэкенд трёхуровневой памяти.
//                                         scope: "global" | "<projectId>" | "<threadId>"
//
//   ~/Documents/Chappie/semantic.json   — LEGACY файл (только для миграции и фолбэка).
//
// ФАЙЛЫ АРХИТЕКТУРЫ (architecture.md):
// Это ДОКУМЕНТАЦИЯ, а не данные. Чаппи читает и пишет их через инструменты
// read_file/write_file как обычные текстовые файлы.
// MemoryManager НЕ создаёт и НЕ управляет architecture.md автоматически.
// Файлы архитектуры создаются ТОЛЬКО вручную по договорённости с пользователем.
//
// БЕЗ ЭМОДЗИ В SYSTEM PROMPT (MEMORY-ENGLISH + TOKEN-EFFICIENCY):
// Все заголовки секций памяти в buildSystemPrompt() — только чистый текст без эмодзи.
// ПРИЧИНА: каждый эмодзи = 2-4 токена, ~30 эмодзи в промпте = ~90 токенов впустую.
// Плюс: кэширование промпта работает лучше на стабильном ASCII-тексте.
// Формат заголовков: "## Global Memory", "## Project Memory: Chappie", "## Thread Context".

import Foundation

// MARK: - Модели данных

/// Запись в памяти ИИ-ассистента (legacy — используется только для файлового бэкенда).
/// Хранит тип записи, временную метку и сами данные в виде JSON-строки.
/// Sendable — необходимо для безопасной передачи между акторами в Swift 6.
public struct MemoryRecord: Codable, Sendable {
    public let type: String
    public let timestamp: Date
    public let data: String

    public init(type: String, timestamp: Date = Date(), data: String) {
        self.type = type
        self.timestamp = timestamp
        self.data = data
    }
}

/// Область видимости памяти — используется в legacy API инструментов.
///
/// ВАЖНО (IT-08): Этот enum сохранён для обратной совместимости.
/// В новом API IT-08 scope передаётся как строка "global" | "thread" | (targetName).
/// MemoryScope.project больше не используется — заменён на targetName.
public enum MemoryScope: String, Codable, Sendable {
    case project
    case global
}

// MARK: - Описание таргета

/// Тип таргета в воркспейсе.
/// Различаем App-таргет (содержит *App.swift) и библиотечные таргеты.
public enum TargetKind: Sendable {
    case appTarget   // Основной таргет приложения
    case library     // Библиотека или модуль
}

/// Описание одного таргета воркспейса.
///
/// WorkspaceTarget хранит метаданные о директории таргета.
/// Используется для сканирования структуры проекта.
///
/// Структура намеренно сделана Sendable для безопасной передачи между акторами в Swift 6.
public struct WorkspaceTarget: Sendable {
    public let name: String
    public let directoryURL: URL
    public let kind: TargetKind

    init(name: String, directoryURL: URL, kind: TargetKind) {
        self.name = name
        self.directoryURL = directoryURL
        self.kind = kind
    }
}

/// Результат сканирования файловой системы таргета.
/// Отделяем результат сканирования от логики записи, чтобы сканирование можно было тестировать изолированно.
public struct TargetScanResult: Sendable {
    public let targetName: String
    public let sourceFiles: [String]
    public let resourceFiles: [String]
    public let otherFiles: [String]

    public var totalCount: Int {
        sourceFiles.count + resourceFiles.count + otherFiles.count
    }
}

// MARK: - MemoryManager

/// Центральный менеджер памяти ИИ-ассистента Chappie.
///
/// Архитектура хранения (IT-08):
/// - Трёхуровневая память: SwiftData через MemoryStore (основной путь)
/// - Legacy-память: ~/Documents/Chappie/semantic.json (только для миграции/фолбэка)
///
/// Почему actor: MemoryManager работает с файловой системой из нескольких мест
/// параллельно. Actor гарантирует сериализацию доступа и отсутствие гонок данных
/// в соответствии с требованиями Swift 6 Concurrency.
public actor MemoryManager {

    // MARK: - Публичные свойства

    /// URL корневой папки воркспейса (открытый проект в Xcode).
    public let workspaceURL: URL

    // MARK: - Приватные свойства

    private let fileManager = FileManager.default

    /// Список всех обнаруженных таргетов воркспейса.
    /// Заполняется в initializeWorkspaceMemory().
    private var targets: [WorkspaceTarget] = []

    /// Флаг завершения инициализации.
    private var isInitialized: Bool = false

    /// SwiftData бэкенд для трёхуровневой памяти (IT-03, IT-08).
    ///
    /// ОПЦИОНАЛЬНЫЙ: MemoryStore создаётся только если ModelContainer доступен.
    /// Это позволяет MemoryManager работать без SwiftData (например, в тестах
    /// или при первом запуске до инициализации ModelContainer).
    private var memoryStore: MemoryStore?

    /// URL единственного файла семантической памяти: ~/Documents/Chappie/semantic.json.
    /// Вычисляется один раз — файловая система не меняется в процессе работы.
    /// Используется ТОЛЬКО для legacy-операций и миграции.
    private var globalFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Chappie/semantic.json")
    }

    // MARK: - Инициализация

    /// Создаёт менеджер памяти для указанного воркспейса.
    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Подключение SwiftData бэкенда (IT-03)

    /// Подключает MemoryStore (SwiftData бэкенд) к MemoryManager.
    ///
    /// ВЫЗЫВАЕТСЯ: из ChappieViewModel.setModelContainer() после создания ModelContainer.
    /// MemoryManager не может сам создать MemoryStore — ModelContainer создаётся в App-слое.
    ///
    /// После подключения:
    /// - buildSystemPrompt() читает из MemoryStore
    /// - Инструменты memorize/recall/search/delete работают через MemoryStore
    public func setMemoryStore(_ store: MemoryStore) {
        self.memoryStore = store
        print("[MemoryManager] MemoryStore connected (SwiftData backend active)")
    }

    // MARK: - Публичный метод инициализации

    /// Инициализирует файловую структуру памяти для воркспейса.
    ///
    /// Что происходит при инициализации:
    /// 1. Создаётся глобальный файл semantic.json (legacy)
    /// 2. Сканируются таргеты воркспейса
    /// 3. Очищаются legacy-папки AI_Docs
    ///
    /// ВАЖНО: architecture.md файлы НЕ создаются автоматически.
    /// Они создаются только вручную по договорённости с пользователем.
    public func initializeWorkspaceMemory() async {
        guard !isInitialized else { return }

        print("[MemoryManager] Initializing workspace memory structure...")

        setupGlobalMemory()

        let discovered = discoverTargets()
        self.targets = discovered

        cleanupLegacyFiles()

        isInitialized = true
        print("[MemoryManager] Initialization complete. Targets: \(targets.count). Memory: ~/Documents/Chappie/semantic.json")
    }

    // MARK: - ТРЁХУРОВНЕВАЯ ПАМЯТЬ: Сборка System Prompt (IT-03, IT-08)

    /// Собирает полный system prompt с подмешанной трёхуровневой памятью.
    ///
    /// СТРУКТУРА ИТОГОВОГО ПРОМПТА (без эмодзи — token efficiency):
    /// ```
    /// [базовый промпт — захардкоженные правила Чаппи]
    ///
    /// ---
    /// ## Memory Context
    ///
    /// ## Global Memory
    /// - [fact] user_name: Alexey
    ///
    /// ## Project Memory: Chappie
    /// - [project_map] architecture: { ... }
    ///
    /// ## Thread Context
    /// - [task] current_task: Thread refactoring
    /// ```
    ///
    /// FALLBACK: если MemoryStore не подключён — возвращает только базовый промпт.
    ///
    /// - Parameters:
    ///   - basePrompt: Базовый system prompt (захардкоженные правила)
    ///   - memoryContext: Контекст треда — threadId + projectInfos (UUID + имя каждого проекта)
    /// - Returns: Полный system prompt с подмешанной памятью
    public func buildSystemPrompt(
        basePrompt: String,
        memoryContext: MemoryContext
    ) async -> String {
        guard let store = memoryStore else {
            print("[MemoryManager] MemoryStore not connected, using base prompt only")
            return basePrompt
        }

        var scopes: [String] = ["global"]

        for info in memoryContext.projectInfos {
            scopes.append(info.id.uuidString)
        }

        if let threadId = memoryContext.threadId {
            scopes.append(threadId.uuidString)
        }

        let entriesByScope: [String: [MemoryEntry]]
        do {
            entriesByScope = try await store.readEntriesForScopes(scopes)
        } catch {
            print("[MemoryManager] Error loading memory from MemoryStore: \(error)")
            return basePrompt
        }

        var memoryBlocks: [String] = []

        let globalSwiftDataEntries = entriesByScope["global"] ?? []
        let legacyEntries = loadLegacyMemoryForPrompt()
        let globalBlock = buildMemoryBlock(
            title: "Global Memory",
            swiftDataEntries: globalSwiftDataEntries,
            legacyEntries: legacyEntries
        )
        if let block = globalBlock {
            memoryBlocks.append(block)
        }

        for info in memoryContext.projectInfos {
            let projectEntries = entriesByScope[info.id.uuidString] ?? []
            guard !projectEntries.isEmpty else { continue }

            let tempEntity = MemoryEntity(scope: info.id.uuidString, entries: projectEntries)
            if let block = tempEntity.formatForPrompt(title: "Project Memory: \(info.name)") {
                memoryBlocks.append(block)
            }
        }

        if let threadId = memoryContext.threadId {
            let threadEntries = entriesByScope[threadId.uuidString] ?? []
            if !threadEntries.isEmpty {
                let tempEntity = MemoryEntity(scope: threadId.uuidString, entries: threadEntries)
                if let block = tempEntity.formatForPrompt(title: "Thread Context") {
                    memoryBlocks.append(block)
                }
            }
        }

        guard !memoryBlocks.isEmpty else {
            return basePrompt
        }

        let memorySectionHeader = "---\n## Memory Context"
        let memorySection = ([memorySectionHeader] + memoryBlocks).joined(separator: "\n\n")

        return basePrompt + "\n\n" + memorySection
    }

    // MARK: - Обратная совместимость: старая сигнатура buildSystemPrompt (IT-08 legacy)

    /// Старая сигнатура buildSystemPrompt — сохранена для обратной совместимости.
    ///
    /// ОГРАНИЧЕНИЕ: projectIds без имён — заголовки блоков будут "Project Memory: <UUID>".
    /// Используй buildSystemPrompt(basePrompt:memoryContext:) для правильных имён.
    public func buildSystemPrompt(
        basePrompt: String,
        threadId: UUID?,
        projectIds: [UUID]
    ) async -> String {
        let projectInfos = projectIds.map { id in
            MemoryContext.ProjectInfo(id: id, name: id.uuidString)
        }
        let context = MemoryContext(threadId: threadId, projectInfos: projectInfos)
        return await buildSystemPrompt(basePrompt: basePrompt, memoryContext: context)
    }

    // MARK: - UUID-based методы памяти (IT-08, основной путь)

    /// Сохраняет запись в памяти по UUID-scope.
    /// Пишет напрямую в MemoryStore (SwiftData). Фолбэк на legacy-файл если SwiftData недоступен.
    public func saveMemoryEntry(key: String, type: String, jsonString: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
            print("[MemoryManager] MemoryStore unavailable, saved to legacy file")
            return nil
        }

        do {
            try await store.saveEntry(key: key, type: type, jsonString: jsonString, scope: scope)
            return nil
        } catch {
            return "Memory save error: \(error.localizedDescription)"
        }
    }

    /// Читает одну запись по ключу из UUID-scope.
    /// Читает из MemoryStore (SwiftData). Фолбэк на legacy-файл если SwiftData недоступен.
    public func readMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            let storage = readStorage(at: globalFileURL)
            return storage[key]?.data
        }

        do {
            return try await store.readEntry(key: key, scope: scope)
        } catch {
            print("[MemoryManager] Error reading from MemoryStore: \(error)")
            return nil
        }
    }

    /// Ищет все записи указанного типа в UUID-scope.
    /// Ищет в MemoryStore (SwiftData). Фолбэк на legacy-файл если SwiftData недоступен.
    public func searchMemoryEntries(type: String, scope: String) async -> [String: String] {
        guard let store = memoryStore else {
            let storage = readStorage(at: globalFileURL)
            var results: [String: String] = [:]
            for (k, v) in storage where v.type == type {
                results[k] = v.data
            }
            return results
        }

        do {
            return try await store.searchEntries(type: type, scope: scope)
        } catch {
            print("[MemoryManager] Error searching MemoryStore: \(error)")
            return [:]
        }
    }

    /// Удаляет запись по ключу из UUID-scope.
    /// Удаляет из MemoryStore (SwiftData). Фолбэк на legacy-файл если SwiftData недоступен.
    public func deleteMemoryEntry(key: String, scope: String) async -> String? {
        guard let store = memoryStore else {
            var storage = readStorage(at: globalFileURL)
            storage.removeValue(forKey: key)
            writeStorage(storage, to: globalFileURL)
            return nil
        }

        do {
            try await store.deleteEntry(key: key, scope: scope)
            return nil
        } catch {
            return "Memory delete error: \(error.localizedDescription)"
        }
    }

    // MARK: - Публичные методы чтения/записи (legacy файловый бэкенд)
    // Сохранены для обратной совместимости с тестами и MigrationService.

    /// Сохраняет запись в памяти по ключу (legacy метод).
    /// Пишет в ~/Documents/Chappie/semantic.json.
    public func saveMemory(key: String, type: String, jsonString: String, scope: MemoryScope = .project, targetName: String? = nil) async {
        await ensureInitialized()
        writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
    }

    /// Читает запись по ключу (legacy метод).
    /// Читает из ~/Documents/Chappie/semantic.json.
    public func readMemory(key: String, targetName: String? = nil) async -> String? {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        return storage[key]?.data
    }

    /// Ищет все записи указанного типа (legacy метод).
    /// Ищет в ~/Documents/Chappie/semantic.json.
    public func searchMemory(type: String, targetName: String? = nil) async -> [String: String] {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        var results: [String: String] = [:]
        for (k, v) in storage where v.type == type {
            results[k] = v.data
        }
        return results
    }

    /// Удаляет запись по ключу из ~/Documents/Chappie/semantic.json (legacy метод).
    public func deleteMemory(key: String, targetName: String? = nil) async {
        await ensureInitialized()
        var storage = readStorage(at: globalFileURL)
        if storage.keys.contains(key) {
            storage.removeValue(forKey: key)
            writeStorage(storage, to: globalFileURL)
        }
    }

    // MARK: - Вспомогательные публичные методы

    /// Возвращает список всех обнаруженных таргетов воркспейса.
    public func allTargets() async -> [WorkspaceTarget] {
        await ensureInitialized()
        return targets
    }

    /// Возвращает основной App-таргет воркспейса (если найден).
    public func primaryAppTarget() async -> WorkspaceTarget? {
        await ensureInitialized()
        return appTarget()
    }

    // MARK: - Приватные методы инициализации

    private func ensureInitialized() async {
        guard !isInitialized else { return }
        await initializeWorkspaceMemory()
    }

    private func setupGlobalMemory() {
        let globalDir = globalFileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: globalDir.path) {
            try? fileManager.createDirectory(at: globalDir, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: globalFileURL.path) {
            try? "{}".write(to: globalFileURL, atomically: true, encoding: .utf8)
        }
    }

    private func discoverTargets() -> [WorkspaceTarget] {
        let excludedNames: Set<String> = [
            "build", "DerivedData", "Pods", "Frameworks",
            ".git", ".swiftpm"
        ]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var discovered: [WorkspaceTarget] = []

        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let name = url.lastPathComponent

            guard !excludedNames.contains(name) else { continue }
            guard !name.hasPrefix(".") else { continue }
            guard url.pathExtension.isEmpty else { continue }

            let kind = classifyTarget(at: url)
            let target = WorkspaceTarget(name: name, directoryURL: url, kind: kind)
            discovered.append(target)
        }

        discovered.sort { lhs, rhs in
            if lhs.kind == .appTarget && rhs.kind != .appTarget { return true }
            if lhs.kind != .appTarget && rhs.kind == .appTarget { return false }
            return lhs.name < rhs.name
        }

        return discovered
    }

    private func classifyTarget(at url: URL) -> TargetKind {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .library
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.hasSuffix("App.swift") {
                return .appTarget
            }
        }

        return .library
    }

    private func cleanupLegacyFiles() {
        for target in targets {
            let legacyAIDocsURL = target.directoryURL.appendingPathComponent("AI_Docs")
            if fileManager.fileExists(atPath: legacyAIDocsURL.path) {
                let legacySemanticURL = legacyAIDocsURL.appendingPathComponent("semantic.json")
                if fileManager.fileExists(atPath: legacySemanticURL.path) {
                    migrateSemanticFile(from: legacySemanticURL, label: "\(target.name)/AI_Docs/semantic.json")
                }
                do {
                    try fileManager.removeItem(at: legacyAIDocsURL)
                    print("[MemoryManager] Removed legacy folder: \(target.name)/AI_Docs/")
                } catch {
                    print("[MemoryManager] Failed to remove \(target.name)/AI_Docs/: \(error)")
                }
            }

            let targetSemanticURL = target.directoryURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: targetSemanticURL.path) {
                migrateSemanticFile(from: targetSemanticURL, label: "\(target.name)/semantic.json")
                do {
                    try fileManager.removeItem(at: targetSemanticURL)
                    print("[MemoryManager] Removed legacy file: \(target.name)/semantic.json")
                } catch {
                    print("[MemoryManager] Failed to remove \(target.name)/semantic.json: \(error)")
                }
            }
        }

        let rootAIDocsURL = workspaceURL.appendingPathComponent("AI_Docs")
        if fileManager.fileExists(atPath: rootAIDocsURL.path) {
            let legacySemanticURL = rootAIDocsURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: legacySemanticURL.path) {
                migrateSemanticFile(from: legacySemanticURL, label: "root/AI_Docs/semantic.json")
            }
            let chatHistoryURL = rootAIDocsURL.appendingPathComponent("chat_history.json")
            if !fileManager.fileExists(atPath: chatHistoryURL.path) {
                do {
                    try fileManager.removeItem(at: rootAIDocsURL)
                    print("[MemoryManager] Removed root legacy folder AI_Docs/")
                } catch {
                    print("[MemoryManager] Failed to remove root AI_Docs/: \(error)")
                }
            }
        }
    }

    private func migrateSemanticFile(from sourceURL: URL, label: String) {
        let oldStorage = readStorage(at: sourceURL)
        guard !oldStorage.isEmpty else { return }

        var globalStorage = readStorage(at: globalFileURL)
        var migratedCount = 0
        for (key, record) in oldStorage where globalStorage[key] == nil {
            globalStorage[key] = record
            migratedCount += 1
        }
        if migratedCount > 0 {
            writeStorage(globalStorage, to: globalFileURL)
            print("[MemoryManager] Migrated \(migratedCount) entries from \(label)")
        }
    }

    // MARK: - Приватные вспомогательные методы

    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    // MARK: - Форматирование памяти для промпта (приватные хелперы)

    /// Загружает записи из legacy-файла semantic.json для подмешивания в промпт.
    /// После полной миграции вернёт пустой массив.
    private func loadLegacyMemoryForPrompt() -> [MemoryEntry] {
        let storage = readStorage(at: globalFileURL)
        guard !storage.isEmpty else { return [] }

        return storage.map { key, record in
            MemoryEntry(
                key: key,
                type: record.type,
                jsonString: record.data
            )
        }
    }

    /// Строит текстовый блок памяти для промпта из SwiftData + legacy записей.
    /// SwiftData имеет приоритет при дедупликации по ключу.
    private func buildMemoryBlock(
        title: String,
        swiftDataEntries: [MemoryEntry],
        legacyEntries: [MemoryEntry]
    ) -> String? {
        var mergedByKey: [String: MemoryEntry] = [:]

        for entry in legacyEntries {
            mergedByKey[entry.key] = entry
        }

        for entry in swiftDataEntries {
            mergedByKey[entry.key] = entry
        }

        guard !mergedByKey.isEmpty else { return nil }

        let sorted = mergedByKey.values.sorted { $0.key < $1.key }

        var lines = ["## \(title)"]
        for entry in sorted {
            let displayValue: String
            if let data = entry.jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json.values.first {
                displayValue = "\(value)"
            } else {
                displayValue = entry.jsonString
            }
            lines.append("- [\(entry.type)] \(entry.key): \(displayValue)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Низкоуровневые операции с файлами (legacy)

    /// Читает словарь записей памяти из JSON-файла.
    private func readStorage(at url: URL) -> [String: MemoryRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let storage = try? decoder.decode([String: MemoryRecord].self, from: data) else {
            return [:]
        }
        return storage
    }

    /// Записывает словарь записей памяти в JSON-файл.
    private func writeStorage(_ storage: [String: MemoryRecord], to url: URL) {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(storage) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Записывает одну запись в хранилище по указанному URL.
    private func writeRecord(key: String, type: String, data: String, to url: URL) {
        var storage = readStorage(at: url)
        storage[key] = MemoryRecord(type: type, data: data)
        writeStorage(storage, to: url)
    }
}
