//
//  MemoryManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

// Менеджер памяти — центральный компонент системы контекстной памяти ИИ-ассистента.
//
// АРХИТЕКТУРНОЕ РЕШЕНИЕ: Используем actor для обеспечения безопасного конкурентного доступа
// в Swift 6. Это гарантирует, что все операции с файловой системой выполняются последовательно,
// исключая состояния гонки при параллельных запросах от нескольких чатов или агентов.
//
// ДВОЙНОЙ БЭКЕНД (IT-03):
// MemoryManager теперь работает с ДВУМЯ бэкендами одновременно:
// 1. Файловый (legacy): ~/Documents/Chappie/semantic.json — для инструментов memorize/recall
//    которые Чаппи вызывает через ToolExecutionService. Работает как раньше.
// 2. SwiftData (новый): MemoryStore — для трёхуровневой памяти в system prompt.
//    Используется в buildSystemPrompt() для автоматического подмешивания памяти.
//
// ПОЧЕМУ ДВОЙНОЙ БЭКЕНД:
// Полная миграция файлового бэкенда в SwiftData — это IT-04 (MigrationService).
// До её завершения файловый бэкенд остаётся как fallback.
// buildSystemPrompt() читает из MemoryStore (SwiftData) — это новый путь.
// memorize/recall инструменты пишут в файл — это старый путь.
// После IT-04 оба пути будут читать из одного SwiftData.
//
// ТРЁХУРОВНЕВАЯ ПАМЯТЬ В SYSTEM PROMPT (IT-03):
// buildSystemPrompt(threadId:projectIds:) собирает полный system prompt:
// 1. Базовый промпт (захардкоженные правила Чаппи)
// 2. Глобальная память (scope = "global") — факты о пользователе, стиль
// 3. Проектная память (scope = "<projectId>") — архитектура, пайплайны
// 4. Тредовая память (scope = "<threadId>") — контекст задачи
//
// ФИНАЛЬНАЯ СТРУКТУРА ПАМЯТИ:
//
//   ~/Documents/Chappie/semantic.json   — LEGACY файл семантической памяти.
//                                         Используется инструментами memorize/recall.
//                                         Будет заменён SwiftData в IT-04.
//
//   SwiftData MemoryEntity              — НОВЫЙ бэкенд трёхуровневой памяти.
//                                         scope: "global" | "<projectId>" | "<threadId>"
//
//   <WorkspaceRoot>/
//   ├── architecture.md                 — архитектура всего проекта (корень воркспейса)
//   ├── Chappie/architecture.md         — архитектура таргета
//   ├── ChappieCore/architecture.md
//   ├── ChappieCoreTests/architecture.md
//   └── ChappieMCP/architecture.md
//
// РОЛЬ architecture.md:
// Это ДОКУМЕНТАЦИЯ, а не данные. Чаппи читает и пишет его через инструменты
// read_file/write_file как обычный текстовый файл. MemoryManager его не трогает
// (только создаёт шаблон при первом обнаружении нового таргета).

import Foundation

// MARK: - Модели данных

/// Запись в памяти ИИ-ассистента.
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

/// Область видимости памяти.
/// ВАЖНО: Оба варианта теперь работают с одним файлом ~/Documents/Chappie/semantic.json.
/// Enum сохранён для обратной совместимости API (ToolExecutionService передаёт scope из инструментов).
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
/// WorkspaceTarget хранит только путь к architecture.md — единственному файлу,
/// которым управляет MemoryManager для каждого таргета.
/// semantic.json больше НЕ является частью таргета — он глобальный.
///
/// Структура намеренно сделана Sendable для безопасной передачи между акторами в Swift 6.
public struct WorkspaceTarget: Sendable {
    public let name: String
    public let directoryURL: URL

    /// Путь к единому файлу архитектуры таргета: <target>/architecture.md.
    /// Это единственный файл, которым MemoryManager управляет в директории таргета.
    public let architectureFileURL: URL

    public let kind: TargetKind

    init(name: String, directoryURL: URL, kind: TargetKind) {
        self.name = name
        self.directoryURL = directoryURL
        self.kind = kind

        // architecture.md лежит прямо в корне таргета — без подпапок.
        self.architectureFileURL = directoryURL.appendingPathComponent("architecture.md")
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
/// Архитектура хранения:
/// - Вся семантическая память (legacy): ~/Documents/Chappie/semantic.json (ОДИН файл)
/// - Трёхуровневая память (новая): SwiftData через MemoryStore
/// - Документация таргетов: <Workspace>/<TargetName>/architecture.md
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

    /// Новый SwiftData бэкенд для трёхуровневой памяти.
    ///
    /// ОПЦИОНАЛЬНЫЙ: MemoryStore создаётся только если ModelContainer доступен.
    /// Это позволяет MemoryManager работать без SwiftData (например, в тестах
    /// или при первом запуске до инициализации ModelContainer).
    ///
    /// ПОЧЕМУ ОПЦИОНАЛЬНЫЙ, А НЕ ОБЯЗАТЕЛЬНЫЙ:
    /// MemoryManager инициализируется в initializeServices() синхронно.
    /// ModelContainer создаётся в ChappieApp асинхронно. Чтобы не создавать
    /// жёсткую зависимость — передаём MemoryStore опционально через setMemoryStore().
    private var memoryStore: MemoryStore?

    /// URL единственного файла семантической памяти: ~/Documents/Chappie/semantic.json.
    /// Вычисляется один раз — файловая система не меняется в процессе работы.
    /// Используется для ВСЕХ операций чтения/записи legacy-памяти.
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
    /// ВЫЗЫВАЕТСЯ: из ChappieViewModel.initializeServices() после создания ModelContainer.
    /// MemoryManager не может сам создать MemoryStore — ModelContainer создаётся в App-слое.
    ///
    /// После подключения:
    /// - buildSystemPrompt() читает из MemoryStore
    /// - Инструменты memorize/recall продолжают писать в файл (до IT-04)
    public func setMemoryStore(_ store: MemoryStore) {
        self.memoryStore = store
        print("[MemoryManager] ✅ MemoryStore подключён (SwiftData бэкенд активен)")
    }

    // MARK: - Публичный метод инициализации

    /// Инициализирует файловую структуру памяти для всего воркспейса.
    public func initializeWorkspaceMemory() async {
        guard !isInitialized else { return }

        print("[MemoryManager] Начало инициализации структуры памяти...")

        setupGlobalMemory()

        let discovered = discoverTargets()
        self.targets = discovered

        for target in targets {
            setupTargetFiles(for: target)
        }

        cleanupLegacyFiles()

        isInitialized = true
        print("[MemoryManager] ✅ Инициализация завершена. Таргетов: \(targets.count). Память: ~/Documents/Chappie/semantic.json")
    }

    // MARK: - ТРЁХУРОВНЕВАЯ ПАМЯТЬ: Сборка System Prompt (IT-03)

    /// Собирает полный system prompt с подмешанной трёхуровневой памятью.
    ///
    /// СТРУКТУРА ИТОГОВОГО ПРОМПТА:
    /// ```
    /// [базовый промпт — захардкоженные правила Чаппи]
    ///
    /// ---
    /// ## 🧠 Глобальная память
    /// - [fact] user_name: Алексей
    /// - [rule] pipeline_rules: { ... }
    ///
    /// ## 📁 Память проекта: Chappie
    /// - [project_map] architecture: { ... }
    ///
    /// ## 💬 Контекст треда
    /// - [task] current_task: Рефакторинг тредов
    /// ```
    ///
    /// ПОЧЕМУ ПОДМЕШИВАЕМ В ПРОМПТ, А НЕ ЧИТАЕМ ПО ТРЕБОВАНИЮ:
    /// Чаппи не может "вспомнить" то, о чём не знает. Если память не подмешана
    /// в промпт — она недоступна модели без явного вызова инструмента recall.
    /// Автоматическое подмешивание гарантирует что модель ВСЕГДА видит контекст.
    ///
    /// FALLBACK:
    /// Если MemoryStore не подключён (SwiftData недоступен) — возвращает только
    /// базовый промпт. Это гарантирует работу системы даже без SwiftData.
    ///
    /// - Parameters:
    ///   - basePrompt: Базовый system prompt (захардкоженные правила)
    ///   - threadId: UUID активного треда (для тредовой памяти), nil = без тредовой памяти
    ///   - projectIds: UUID проектов в треде (для проектной памяти)
    /// - Returns: Полный system prompt с подмешанной памятью
    public func buildSystemPrompt(
        basePrompt: String,
        threadId: UUID?,
        projectIds: [UUID]
    ) async -> String {
        // Если SwiftData бэкенд не подключён — возвращаем базовый промпт как есть.
        // Это нормальная ситуация при первом запуске или в тестах.
        guard let store = memoryStore else {
            print("[MemoryManager] ℹ️ MemoryStore не подключён, используем базовый промпт")
            return basePrompt
        }

        // Собираем список scope для загрузки
        var scopes: [String] = ["global"]

        // Добавляем scope каждого проекта
        for projectId in projectIds {
            scopes.append(projectId.uuidString)
        }

        // Добавляем scope треда если задан
        if let threadId = threadId {
            scopes.append(threadId.uuidString)
        }

        // Загружаем все записи одним запросом к SwiftData
        let entriesByScope: [String: [MemoryEntry]]
        do {
            entriesByScope = try await store.readEntriesForScopes(scopes)
        } catch {
            print("[MemoryManager] ⚠️ Ошибка загрузки памяти из MemoryStore: \(error)")
            return basePrompt
        }

        // Также загружаем legacy-память из файла (для совместимости до IT-04)
        let legacyEntries = loadLegacyMemoryForPrompt()

        // Собираем блоки памяти для промпта
        var memoryBlocks: [String] = []

        // --- БЛОК 1: Глобальная память ---
        // Объединяем SwiftData записи и legacy-записи из файла
        let globalSwiftDataEntries = entriesByScope["global"] ?? []
        let globalBlock = buildMemoryBlock(
            title: "🧠 Глобальная память",
            swiftDataEntries: globalSwiftDataEntries,
            legacyEntries: legacyEntries
        )
        if let block = globalBlock {
            memoryBlocks.append(block)
        }

        // --- БЛОК 2: Проектная память ---
        // Для каждого проекта — отдельный блок
        for projectId in projectIds {
            let projectEntries = entriesByScope[projectId.uuidString] ?? []
            guard !projectEntries.isEmpty else { continue }

            // Форматируем блок через MemoryEntity helper
            let tempEntity = MemoryEntity(scope: projectId.uuidString, entries: projectEntries)
            if let block = tempEntity.formatForPrompt(title: "📁 Память проекта") {
                memoryBlocks.append(block)
            }
        }

        // --- БЛОК 3: Тредовая память ---
        if let threadId = threadId {
            let threadEntries = entriesByScope[threadId.uuidString] ?? []
            if !threadEntries.isEmpty {
                let tempEntity = MemoryEntity(scope: threadId.uuidString, entries: threadEntries)
                if let block = tempEntity.formatForPrompt(title: "💬 Контекст треда") {
                    memoryBlocks.append(block)
                }
            }
        }

        // Если нет ни одного блока памяти — возвращаем базовый промпт без изменений
        guard !memoryBlocks.isEmpty else {
            return basePrompt
        }

        // Собираем финальный промпт: базовый + разделитель + блоки памяти
        let memorySectionHeader = "---\n## 📚 Контекст и память"
        let memorySection = ([memorySectionHeader] + memoryBlocks).joined(separator: "\n\n")

        return basePrompt + "\n\n" + memorySection
    }

    // MARK: - Публичные методы чтения/записи (legacy файловый бэкенд)

    /// Сохраняет запись в памяти по ключу.
    ///
    /// LEGACY МЕТОД: пишет в ~/Documents/Chappie/semantic.json.
    /// После IT-04 (MigrationService) будет переключён на MemoryStore.
    public func saveMemory(key: String, type: String, jsonString: String, scope: MemoryScope = .project, targetName: String? = nil) async {
        await ensureInitialized()
        writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
    }

    /// Читает запись по ключу.
    ///
    /// LEGACY МЕТОД: читает из ~/Documents/Chappie/semantic.json.
    public func readMemory(key: String, targetName: String? = nil) async -> String? {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        return storage[key]?.data
    }

    /// Ищет все записи указанного типа.
    ///
    /// LEGACY МЕТОД: ищет в ~/Documents/Chappie/semantic.json.
    public func searchMemory(type: String, targetName: String? = nil) async -> [String: String] {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        var results: [String: String] = [:]
        for (k, v) in storage where v.type == type {
            results[k] = v.data
        }
        return results
    }

    /// Удаляет запись по ключу из ~/Documents/Chappie/semantic.json.
    ///
    /// LEGACY МЕТОД.
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

    private func setupTargetFiles(for target: WorkspaceTarget) {
        if !fileManager.fileExists(atPath: target.architectureFileURL.path) {
            let template = makeArchitectureTemplate(for: target)
            try? template.write(to: target.architectureFileURL, atomically: true, encoding: .utf8)
            print("[MemoryManager] 📄 Создан шаблон: \(target.name)/architecture.md")
        }
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
                    print("[MemoryManager] 🗑️ Удалена устаревшая папка: \(target.name)/AI_Docs/")
                } catch {
                    print("[MemoryManager] ⚠️ Не удалось удалить \(target.name)/AI_Docs/: \(error)")
                }
            }

            let targetSemanticURL = target.directoryURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: targetSemanticURL.path) {
                migrateSemanticFile(from: targetSemanticURL, label: "\(target.name)/semantic.json")
                do {
                    try fileManager.removeItem(at: targetSemanticURL)
                    print("[MemoryManager] 🗑️ Удалён устаревший файл: \(target.name)/semantic.json")
                } catch {
                    print("[MemoryManager] ⚠️ Не удалось удалить \(target.name)/semantic.json: \(error)")
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
                    print("[MemoryManager] 🗑️ Удалена корневая устаревшая папка AI_Docs/")
                } catch {
                    print("[MemoryManager] ⚠️ Не удалось удалить корневую AI_Docs/: \(error)")
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
            print("[MemoryManager] 📦 Мигрировано \(migratedCount) записей из \(label)")
        }
    }

    // MARK: - Приватные вспомогательные методы

    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    // MARK: - Форматирование памяти для промпта (приватные хелперы)

    /// Загружает записи из legacy-файла semantic.json для подмешивания в промпт.
    ///
    /// ЗАЧЕМ LEGACY В ПРОМПТЕ:
    /// До IT-04 инструменты memorize/recall пишут в файл, а не в SwiftData.
    /// Чтобы эти записи тоже попадали в промпт — читаем файл и включаем в глобальный блок.
    ///
    /// После IT-04 (миграция) этот метод вернёт пустой массив — файл будет пустым.
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
    ///
    /// ДЕДУПЛИКАЦИЯ:
    /// Если ключ есть и в SwiftData и в legacy — приоритет у SwiftData (новее).
    ///
    /// - Parameters:
    ///   - title: Заголовок блока
    ///   - swiftDataEntries: Записи из SwiftData MemoryStore
    ///   - legacyEntries: Записи из legacy semantic.json файла
    /// - Returns: Отформатированный блок или nil если нет записей
    private func buildMemoryBlock(
        title: String,
        swiftDataEntries: [MemoryEntry],
        legacyEntries: [MemoryEntry]
    ) -> String? {
        // Объединяем: SwiftData имеет приоритет (перезаписывает legacy по ключу)
        var mergedByKey: [String: MemoryEntry] = [:]

        // Сначала добавляем legacy
        for entry in legacyEntries {
            mergedByKey[entry.key] = entry
        }

        // Потом SwiftData — перезаписывает legacy при совпадении ключей
        for entry in swiftDataEntries {
            mergedByKey[entry.key] = entry
        }

        guard !mergedByKey.isEmpty else { return nil }

        // Сортируем по ключу для стабильного порядка
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

    // MARK: - Генератор шаблона architecture.md

    private func makeArchitectureTemplate(for target: WorkspaceTarget) -> String {
        let kindLabel = target.kind == .appTarget ? "App Target" : "Library Target"
        let date = ISO8601DateFormatter().string(from: Date())

        return """
        <!--
          \(target.name)/architecture.md

          ДОКУМЕНТ АРХИТЕКТУРЫ — \(target.name.uppercased())

          Этот файл — единственный источник архитектурной документации для таргета.
          Обновляй при каждом значимом архитектурном изменении.
          Создан: \(date)
        -->

        # \(target.name) — Архитектура

        > **Target type:** \(kindLabel)
        > **Created:** \(date)
        > **Managed by:** Chappie AI Assistant

        ---

        ## 1. Назначение

        _Опиши цель и ответственность этого таргета._

        ---

        ## 2. Структура файлов

        ```
        \(target.name)/
        ├── architecture.md     # Этот файл
        └── ...                 # Исходные файлы
        ```

        ---

        ## 3. Ключевые архитектурные решения

        | Решение | Причина | Дата |
        |---------|---------|------|
        | _Добавь решения здесь_ | _Почему так?_ | \(date) |

        ---

        ## 📚 Changelog

        | Date | Change | Author |
        |------|--------|--------|
        | \(date) | Initial creation | Chappie AI |
        """
    }
}
