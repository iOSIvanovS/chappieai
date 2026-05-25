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
// СТРУКТУРА ПАМЯТИ (ФИНАЛЬНЫЙ ФОРМАТ — без папки AI_Docs):
//
// ├── ~/Documents/Chappie/semantic.json  — глобальная семантическая память (кросс-проектная)
// └── <WorkspaceRoot>/
//     ├── architecture.md                — архитектура всего проекта (корень воркспейса)
//     ├── Chappie/
//     │   ├── architecture.md            — архитектура таргета
//     │   └── semantic.json              — семантическая память таргета
//     ├── ChappieCore/
//     │   ├── architecture.md
//     │   └── semantic.json
//     └── ...
//
// ПОЧЕМУ УБРАЛИ AI_Docs/:
// Папка AI_Docs/ была промежуточным решением при рефакторинге. Теперь оба файла
// (architecture.md и semantic.json) лежат прямо в корне таргета — проще, чище,
// нет лишнего уровня вложенности. semantic.json — это данные памяти ИИ, а не
// "документация", поэтому его место рядом с architecture.md, в корне таргета.

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
/// .project — память конкретного проекта/таргета.
/// .global  — глобальная память ассистента, не привязанная к проекту.
public enum MemoryScope: String, Codable, Sendable {
    case project
    case global
}

// MARK: - Описание таргета

/// Тип таргета в воркспейсе.
/// Различаем App-таргет (содержит *App.swift) и библиотечные таргеты.
/// Это важно, потому что запись по умолчанию идёт в App-таргет.
public enum TargetKind: Sendable {
    case appTarget   // Основной таргет приложения
    case library     // Библиотека или модуль
}

/// Описание одного таргета воркспейса.
///
/// ФИНАЛЬНЫЙ ФОРМАТ (без AI_Docs/):
/// - architectureFileURL → <target>/architecture.md
/// - semanticFileURL     → <target>/semantic.json
///
/// Оба файла лежат прямо в корне таргета — нет лишнего уровня вложенности.
/// Структура намеренно сделана Sendable для безопасной передачи между акторами в Swift 6.
public struct WorkspaceTarget: Sendable {
    public let name: String
    public let directoryURL: URL

    /// Путь к файлу семантической памяти таргета: <target>/semantic.json.
    /// ФИНАЛЬНОЕ МЕСТО: корень таргета (не AI_Docs/).
    public let semanticFileURL: URL

    /// Путь к единому файлу архитектуры таргета: <target>/architecture.md.
    /// Лежит рядом с semantic.json в корне таргета.
    public let architectureFileURL: URL

    public let kind: TargetKind

    init(name: String, directoryURL: URL, kind: TargetKind) {
        self.name = name
        self.directoryURL = directoryURL
        self.kind = kind

        // Оба файла памяти лежат прямо в корне таргета — без подпапок.
        // Это финальный формат после отказа от папки AI_Docs/.
        self.semanticFileURL = directoryURL.appendingPathComponent("semantic.json")
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
/// - Глобальная память: ~/Documents/Chappie/semantic.json
/// - Память таргетов: <Workspace>/<TargetName>/semantic.json
/// - Документация: <Workspace>/<TargetName>/architecture.md
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
    /// Используется для ленивой авто-инициализации при первом обращении к памяти,
    /// если ChappieViewModel не вызвал initializeWorkspaceMemory() явно.
    private var isInitialized: Bool = false

    /// URL глобального файла памяти: ~/Documents/Chappie/semantic.json.
    /// Вычисляется один раз — файловая система не меняется в процессе работы.
    private var globalFileURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Chappie/semantic.json")
    }

    // MARK: - Инициализация

    /// Создаёт менеджер памяти для указанного воркспейса.
    /// Инициализация файловой структуры вынесена в initializeWorkspaceMemory(),
    /// потому что actor init не может вызывать async-методы напрямую.
    /// ChappieViewModel должен явно вызвать initializeWorkspaceMemory() сразу после создания.
    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Публичный метод инициализации

    /// Инициализирует файловую структуру памяти для всего воркспейса.
    ///
    /// Что делает:
    /// 1. Создаёт глобальную папку ~/Documents/Chappie и файл semantic.json (если нет).
    /// 2. Сканирует директории первого уровня в workspaceURL.
    /// 3. Фильтрует служебные, скрытые папки и пакеты Xcode.
    /// 4. Определяет тип каждого таргета (App или Library).
    /// 5. Создаёт semantic.json и architecture.md для каждого таргета (если нет).
    /// 6. Очищает устаревшие папки AI_Docs/ (миграция со старого формата).
    ///
    /// Метод идемпотентен — повторный вызов не затирает существующие данные.
    public func initializeWorkspaceMemory() async {
        // Защита от двойной инициализации при параллельных вызовах
        guard !isInitialized else { return }

        print("[MemoryManager] Начало инициализации структуры памяти...")

        // 1. Глобальная память
        setupGlobalMemory()

        // 2. Сканирование и классификация таргетов воркспейса
        let discovered = discoverTargets()
        self.targets = discovered

        // 3. Создание semantic.json и architecture.md для каждого таргета
        for target in targets {
            setupTargetFiles(for: target)
        }

        // 4. Очищаем устаревшие папки AI_Docs/ если они остались от предыдущих версий
        cleanupLegacyAIDocs()

        isInitialized = true
        print("[MemoryManager] ✅ Инициализация структуры завершена. Зарегистрировано таргетов: \(targets.count)")
    }

    // MARK: - Публичные методы чтения/записи

    /// Сохраняет запись в памяти по ключу.
    ///
    /// - scope == .project: пишет в semantic.json основного App-таргета.
    ///   Если передан targetName — пишет строго в указанный таргет.
    ///   Если App-таргет не найден — в первый доступный таргет воркспейса.
    /// - scope == .global: пишет в ~/Documents/Chappie/semantic.json.
    ///
    /// Ленивая инициализация: если initializeWorkspaceMemory() не был вызван явно,
    /// он будет вызван автоматически при первом обращении.
    public func saveMemory(key: String, type: String, jsonString: String, scope: MemoryScope = .project, targetName: String? = nil) async {
        await ensureInitialized()

        switch scope {
        case .project:
            let target: WorkspaceTarget?
            if let targetName = targetName {
                // Если имя таргета передано явно, ищем строго его
                target = targets.first { $0.name == targetName }
            } else {
                // По умолчанию берем App-таргет или первый доступный
                target = appTarget() ?? targets.first
            }

            guard let url = target?.semanticFileURL else {
                // Нет ни одного таргета — пишем в глобальную память как запасной вариант
                writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
                return
            }
            writeRecord(key: key, type: type, data: jsonString, to: url)

        case .global:
            writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
        }
    }

    /// Читает запись по ключу.
    ///
    /// Порядок поиска:
    /// 1. Если указан targetName — ищет строго в этом таргете, затем в глобальной памяти.
    /// 2. Если targetName не указан — ищет в App-таргете воркспейса, затем в остальных таргетах воркспейса, затем в глобальной памяти.
    ///
    /// Такой порядок обеспечивает приоритет проектно-специфичных данных
    /// над глобальными, что соответствует принципу наименьшего удивления.
    public func readMemory(key: String, targetName: String? = nil) async -> String? {
        await ensureInitialized()

        if let targetName = targetName {
            // Если указан конкретный таргет, ищем строго в нем
            if let target = targets.first(where: { $0.name == targetName }) {
                let storage = readStorage(at: target.semanticFileURL)
                if let record = storage[key] {
                    return record.data
                }
            }
        } else {
            // Стандартный поиск: App-таргет → остальные таргеты
            let orderedTargets = orderedTargetsForRead()
            for target in orderedTargets {
                let storage = readStorage(at: target.semanticFileURL)
                if let record = storage[key] {
                    return record.data
                }
            }
        }

        // Глобальная память — последний рубеж
        let globalStorage = readStorage(at: globalFileURL)
        return globalStorage[key]?.data
    }

    /// Ищет все записи указанного типа во всех таргетах и в глобальной памяти.
    ///
    /// Если указан targetName — ограничивает поиск этим таргетом и глобальной памятью.
    /// Результаты объединяются: если один ключ встречается в нескольких местах,
    /// побеждает последнее найденное значение (глобальная память имеет низший приоритет,
    /// она добавляется первой и может быть перезаписана таргетными данными).
    public func searchMemory(type: String, targetName: String? = nil) async -> [String: String] {
        await ensureInitialized()

        var results: [String: String] = [:]

        // Сначала глобальная (низший приоритет)
        let globalStorage = readStorage(at: globalFileURL)
        for (k, v) in globalStorage where v.type == type {
            results[k] = v.data
        }

        if let targetName = targetName {
            // Если указан конкретный таргет, ищем строго в нем (перезаписывая глобальные)
            if let target = targets.first(where: { $0.name == targetName }) {
                let storage = readStorage(at: target.semanticFileURL)
                for (k, v) in storage where v.type == type {
                    results[k] = v.data
                }
            }
        } else {
            // Иначе ищем во всех таргетах
            for target in targets {
                let storage = readStorage(at: target.semanticFileURL)
                for (k, v) in storage where v.type == type {
                    results[k] = v.data
                }
            }
        }

        return results
    }

    /// Удаляет запись по ключу из всех таргетов воркспейса (или конкретного) и из глобальной памяти.
    ///
    /// Удаление из всех мест необходимо для консистентности:
    /// если запись была скопирована или мигрирована, она должна исчезнуть везде.
    public func deleteMemory(key: String, targetName: String? = nil) async {
        await ensureInitialized()

        if let targetName = targetName {
            // Если указан конкретный таргет, удаляем строго из него
            if let target = targets.first(where: { $0.name == targetName }) {
                var storage = readStorage(at: target.semanticFileURL)
                if storage.keys.contains(key) {
                    storage.removeValue(forKey: key)
                    writeStorage(storage, to: target.semanticFileURL)
                }
            }
        } else {
            // Иначе удаляем из всех таргетов
            for target in targets {
                var storage = readStorage(at: target.semanticFileURL)
                if storage.keys.contains(key) {
                    storage.removeValue(forKey: key)
                    writeStorage(storage, to: target.semanticFileURL)
                }
            }
        }

        // Удаляем из глобальной памяти
        var globalStorage = readStorage(at: globalFileURL)
        if globalStorage.keys.contains(key) {
            globalStorage.removeValue(forKey: key)
            writeStorage(globalStorage, to: globalFileURL)
        }
    }

    // MARK: - Вспомогательные публичные методы

    /// Возвращает список всех обнаруженных таргетов воркспейса.
    /// Используется в ChappieViewModel для отображения структуры проекта.
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

    /// Ленивая авто-инициализация при первом обращении к памяти.
    /// Гарантирует, что структура файлов всегда готова перед операциями чтения/записи,
    /// даже если ChappieViewModel не вызвал initializeWorkspaceMemory() явно.
    private func ensureInitialized() async {
        guard !isInitialized else { return }
        await initializeWorkspaceMemory()
    }

    /// Создаёт глобальную папку ~/Documents/Chappie и файл semantic.json.
    /// Если файл уже существует — не трогает его, чтобы не затереть накопленные данные.
    private func setupGlobalMemory() {
        let globalDir = globalFileURL.deletingLastPathComponent()

        // Создаём папку ~/Documents/Chappie если её нет
        if !fileManager.fileExists(atPath: globalDir.path) {
            try? fileManager.createDirectory(at: globalDir, withIntermediateDirectories: true)
        }

        // Создаём пустой semantic.json если его нет
        if !fileManager.fileExists(atPath: globalFileURL.path) {
            try? "{}".write(to: globalFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Сканирует директории первого уровня в workspaceURL и возвращает список таргетов.
    ///
    /// Логика фильтрации:
    /// - Скрытые папки (начинаются с '.') — системные, не наши.
    /// - 'build', 'DerivedData', 'Pods', 'Frameworks' — артефакты сборки, не исходники.
    /// - '.git', '.swiftpm' — служебные папки VCS и SPM.
    /// - Директории с расширением (например, .xcodeproj, .xcworkspace) — пакеты Xcode, пропускаем!
    private func discoverTargets() -> [WorkspaceTarget] {
        // Папки, которые заведомо не являются таргетами исходного кода
        let excludedNames: Set<String> = [
            "build", "DerivedData", "Pods", "Frameworks",
            ".git", ".swiftpm"
        ]

        guard let contents = try? fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles] // Автоматически пропускает папки начинающиеся с '.'
        ) else {
            return []
        }

        var discovered: [WorkspaceTarget] = []

        for url in contents {
            // Проверяем, что это директория
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            let name = url.lastPathComponent

            // Пропускаем исключённые папки
            guard !excludedNames.contains(name) else { continue }

            // Дополнительная защита от скрытых папок (на случай если .skipsHiddenFiles не сработал)
            guard !name.hasPrefix(".") else { continue }

            // КРИТИЧЕСКАЯ ФИЛЬТРАЦИЯ ДЛЯ ДЕТЕРМИНИЗМА:
            // Пропускаем директории с расширением в имени (например, .xcodeproj, .xcworkspace, .playground).
            // Это пакеты Xcode, а не папки с исходным кодом проекта.
            guard url.pathExtension.isEmpty else {
                continue
            }

            // Определяем тип таргета
            let kind = classifyTarget(at: url)
            let target = WorkspaceTarget(name: name, directoryURL: url, kind: kind)
            discovered.append(target)
        }

        // Сортируем: App-таргет первым, затем библиотеки по алфавиту.
        // Это важно для readMemory — App-таргет должен проверяться первым.
        discovered.sort { lhs, rhs in
            if lhs.kind == .appTarget && rhs.kind != .appTarget { return true }
            if lhs.kind != .appTarget && rhs.kind == .appTarget { return false }
            return lhs.name < rhs.name
        }

        return discovered
    }

    /// Определяет тип таргета: App или Library.
    ///
    /// App-таргет содержит файл с суффиксом 'App.swift' (например, ChappieApp.swift).
    /// Такой файл является точкой входа приложения в SwiftUI (@main).
    /// Поиск рекурсивный — файл может быть в подпапке таргета.
    private func classifyTarget(at url: URL) -> TargetKind {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .library
        }

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            // Ищем файл вида *App.swift — признак @main точки входа SwiftUI приложения
            if filename.hasSuffix("App.swift") {
                return .appTarget
            }
        }

        return .library
    }

    /// Создаёт файлы памяти и документации для указанного таргета.
    ///
    /// ФИНАЛЬНЫЙ ФОРМАТ (без AI_Docs/):
    /// - semantic.json   — данные памяти, прямо в корне таргета
    /// - architecture.md — документация архитектуры, прямо в корне таргета
    ///
    /// Идемпотентность: если файлы уже существуют — не трогает их.
    /// Это защищает накопленные данные при повторных запусках приложения.
    private func setupTargetFiles(for target: WorkspaceTarget) {
        // semantic.json — пустой JSON-объект как начальное состояние.
        // Лежит прямо в корне таргета, рядом с architecture.md.
        if !fileManager.fileExists(atPath: target.semanticFileURL.path) {
            try? "{}".write(to: target.semanticFileURL, atomically: true, encoding: .utf8)
        }

        // architecture.md — единый документ архитектуры таргета.
        // Создаём только если не существует — не затираем реальную документацию!
        if !fileManager.fileExists(atPath: target.architectureFileURL.path) {
            let architectureTemplate = makeArchitectureTemplate(for: target)
            try? architectureTemplate.write(to: target.architectureFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Удаляет устаревшие папки AI_Docs/ из всех таргетов воркспейса.
    ///
    /// Зачем: предыдущая версия MemoryManager хранила semantic.json в AI_Docs/.
    /// Новая архитектура хранит его прямо в корне таргета.
    /// При каждом запуске проверяем и удаляем AI_Docs/ если они ещё есть.
    ///
    /// ВАЖНО: Перед удалением мигрируем данные из AI_Docs/semantic.json в корневой semantic.json,
    /// чтобы не потерять накопленные данные памяти.
    private func cleanupLegacyAIDocs() {
        for target in targets {
            let legacyAIDocsURL = target.directoryURL.appendingPathComponent("AI_Docs")

            // Если папки AI_Docs нет — всё чисто, идём дальше
            guard fileManager.fileExists(atPath: legacyAIDocsURL.path) else { continue }

            // Пробуем мигрировать данные из старого semantic.json
            let legacySemanticURL = legacyAIDocsURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: legacySemanticURL.path) {
                let oldStorage = readStorage(at: legacySemanticURL)
                if !oldStorage.isEmpty {
                    // Мигрируем только те ключи, которых ещё нет в новом файле
                    var newStorage = readStorage(at: target.semanticFileURL)
                    var didMigrate = false
                    for (key, record) in oldStorage where newStorage[key] == nil {
                        newStorage[key] = record
                        didMigrate = true
                    }
                    if didMigrate {
                        writeStorage(newStorage, to: target.semanticFileURL)
                        print("[MemoryManager] 📦 Мигрированы данные из \(target.name)/AI_Docs/semantic.json")
                    }
                }
            }

            // Удаляем всю папку AI_Docs/ — она больше не нужна
            do {
                try fileManager.removeItem(at: legacyAIDocsURL)
                print("[MemoryManager] 🗑️ Удалена устаревшая папка: \(target.name)/AI_Docs/")
            } catch {
                print("[MemoryManager] ⚠️ Не удалось удалить \(target.name)/AI_Docs/: \(error)")
            }
        }

        // Также удаляем корневую AI_Docs/ воркспейса (если осталась от старых версий)
        // ИСКЛЮЧЕНИЕ: НЕ удаляем если там есть chat_history.json — это активные данные!
        let rootAIDocsURL = workspaceURL.appendingPathComponent("AI_Docs")
        guard fileManager.fileExists(atPath: rootAIDocsURL.path) else { return }

        let chatHistoryURL = rootAIDocsURL.appendingPathComponent("chat_history.json")
        if fileManager.fileExists(atPath: chatHistoryURL.path) {
            // chat_history.json всё ещё в старом месте — не трогаем папку
            print("[MemoryManager] ⚠️ Корневая AI_Docs/ содержит chat_history.json — не удаляем")
            return
        }

        // Папка пустая или содержит только semantic.json — можно удалить
        do {
            try fileManager.removeItem(at: rootAIDocsURL)
            print("[MemoryManager] 🗑️ Удалена корневая устаревшая папка AI_Docs/")
        } catch {
            print("[MemoryManager] ⚠️ Не удалось удалить корневую AI_Docs/: \(error)")
        }
    }

    // MARK: - Приватные вспомогательные методы

    /// Возвращает основной App-таргет (первый с kind == .appTarget).
    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    /// Возвращает таргеты в порядке приоритета для чтения:
    /// App-таргет первым, затем остальные.
    /// Порядок уже задан при сортировке в discoverTargets(), но метод явно выражает намерение.
    private func orderedTargetsForRead() -> [WorkspaceTarget] {
        // targets уже отсортированы: App-таргет первый
        return targets
    }

    // MARK: - Низкоуровневые операции с файлами

    /// Читает словарь записей памяти из JSON-файла по указанному URL.
    /// Возвращает пустой словарь при любой ошибке — это безопасный дефолт,
    /// не ломающий работу при отсутствии или повреждении файла.
    private func readStorage(at url: URL) -> [String: MemoryRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let storage = try? JSONDecoder().decode([String: MemoryRecord].self, from: data) else {
            return [:]
        }
        return storage
    }

    /// Записывает словарь записей памяти в JSON-файл по указанному URL.
    /// Создаёт промежуточные директории при необходимости.
    /// Использует .atomic для защиты от повреждения файла при сбое записи.
    private func writeStorage(_ storage: [String: MemoryRecord], to url: URL) {
        let dir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(storage) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Записывает одну запись в хранилище по указанному URL.
    /// Выделено в отдельный метод для переиспользования в saveMemory.
    private func writeRecord(key: String, type: String, data: String, to url: URL) {
        var storage = readStorage(at: url)
        storage[key] = MemoryRecord(type: type, data: data)
        writeStorage(storage, to: url)
    }

    // MARK: - Генератор шаблона architecture.md

    /// Генерирует минимальный шаблон architecture.md для нового таргета.
    ///
    /// ПОЧЕМУ МИНИМАЛЬНЫЙ:
    /// Реальные таргеты Chappie (Chappie, ChappieCore, ChappieMCP, ChappieCoreTests)
    /// уже имеют подробные architecture.md созданные вручную/ИИ.
    /// Этот шаблон нужен только для новых таргетов, которые Чаппи обнаружит в будущем.
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
        ├── semantic.json       # Память ИИ (создаётся автоматически)
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
