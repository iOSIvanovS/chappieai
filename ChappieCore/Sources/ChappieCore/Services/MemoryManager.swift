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
// СТРУКТУРА ПАМЯТИ:
// ├── ~/Documents/Chappie/semantic.json  — глобальная семантическая память (кросс-проектная)
// └── <WorkspaceRoot>/
//     ├── Chappie/AI_Docs/               — память таргета App
//     │   ├── project_map.md             — карта файлов таргета (автогенерируется)
//     │   ├── architecture.md            — архитектурные решения
//     │   └── semantic.json              — семантическая память проекта
//     └── ChappieCore/AI_Docs/           — память таргета Library
//         ├── project_map.md
//         ├── architecture.md
//         └── semantic.json

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
/// Содержит путь к папке таргета и путь к его AI_Docs/semantic.json.
/// Структура намеренно сделана Sendable для безопасной передачи между акторами в Swift 6.
public struct WorkspaceTarget: Sendable {
    public let name: String
    public let directoryURL: URL
    public let aiDocsURL: URL
    public let semanticFileURL: URL
    public let architectureFileURL: URL
    public let projectMapFileURL: URL
    public let kind: TargetKind

    init(name: String, directoryURL: URL, kind: TargetKind) {
        self.name = name
        self.directoryURL = directoryURL
        self.kind = kind
        // AI_Docs всегда находится внутри папки таргета — это инвариант системы.
        // Такое решение изолирует память каждого таргета и предотвращает случайное смешивание контекстов.
        self.aiDocsURL = directoryURL.appendingPathComponent("AI_Docs", isDirectory: true)
        self.semanticFileURL = directoryURL.appendingPathComponent("AI_Docs/semantic.json")
        self.architectureFileURL = directoryURL.appendingPathComponent("AI_Docs/architecture.md")
        self.projectMapFileURL = directoryURL.appendingPathComponent("AI_Docs/project_map.md")
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
/// - Память таргетов: <Workspace>/<TargetName>/AI_Docs/
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
    /// 1. Очищает ошибочные папки AI_Docs внутри Xcode-пакетов (.xcodeproj, .xcworkspace, .playground).
    /// 2. Создаёт глобальную папку ~/Documents/Chappie и файл semantic.json (если нет).
    /// 3. Сканирует директории первого уровня в workspaceURL.
    /// 4. Фильтрует служебные, скрытые папки и пакеты Xcode.
    /// 5. Определяет тип каждого таргета (App или Library).
    /// 6. Создаёт AI_Docs и шаблонные файлы для каждого таргета, автоматически сканируя файлы для project_map.md.
    /// 7. Мигрирует старый корневой AI_Docs/semantic.json в App-таргет (если был).
    ///
    /// Метод идемпотентен — повторный вызов не затирает существующие данные.
    public func initializeWorkspaceMemory() async {
        // Защита от двойной инициализации при параллельных вызовах
        guard !isInitialized else { return }

        print("[MemoryManager] Начало инициализации структуры памяти...")

        // 1. Очищаем ошибочно созданные папки AI_Docs внутри служебных пакетов Xcode
        cleanupInvalidAIDocs()

        // 2. Глобальная память
        setupGlobalMemory()

        // 3. Сканирование и классификация таргетов воркспейса
        let discovered = discoverTargets()
        self.targets = discovered

        // 4. Создание AI_Docs и шаблонных файлов для каждого таргета с автозаполнением карт проектов
        for target in targets {
            await setupAIDocs(for: target)
        }

        // 5. Миграция старого корневого AI_Docs/semantic.json
        migrateOldRootAIDocs()

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

    /// Пересканирует таргет и принудительно обновляет его project_map.md актуальными файлами.
    public func refreshProjectMap(forTarget targetName: String) async {
        await ensureInitialized()
        guard let target = targets.first(where: { $0.name == targetName }) else { return }
        
        let scanResult = scanTargetDirectory(target)
        let mapTemplate = makeProjectMapTemplate(for: target, scanResult: scanResult)
        try? mapTemplate.write(to: target.projectMapFileURL, atomically: true, encoding: .utf8)
        print("[MemoryManager] 🗺 Карта проекта принудительно обновлена для таргета '\(target.name)'")
    }

    // MARK: - Приватные методы инициализации

    /// Ленивая авто-инициализация при первом обращении к памяти.
    /// Гарантирует, что структура файлов всегда готова перед операциями чтения/записи,
    /// даже если ChappieViewModel не вызвал initializeWorkspaceMemory() явно.
    private func ensureInitialized() async {
        guard !isInitialized else { return }
        await initializeWorkspaceMemory()
    }

    /// Находит и удаляет ошибочные папки AI_Docs, созданные внутри служебных пакетов Xcode
    /// (таких как .xcodeproj, .xcworkspace, .playground).
    /// Зачем: Предыдущая версия ошибочно считала эти пакеты обычными папками-таргетами.
    private func cleanupInvalidAIDocs() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: workspaceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in contents {
            // Проверяем, что это директория
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }

            // Если папка имеет расширение (например, Chappie.xcodeproj) — это служебный пакет Xcode
            if !url.pathExtension.isEmpty {
                let invalidAIDocsURL = url.appendingPathComponent("AI_Docs")
                if fileManager.fileExists(atPath: invalidAIDocsURL.path) {
                    try? fileManager.removeItem(at: invalidAIDocsURL)
                }
            }
        }
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
    /// - 'AI_Docs' в корне — старый формат, будет мигрирован отдельно.
    /// - '.git', '.swiftpm' — служебные папки VCS и SPM.
    /// - Директории с расширением (например, .xcodeproj, .xcworkspace) — пакеты Xcode, пропускаем!
    private func discoverTargets() -> [WorkspaceTarget] {
        // Папки, которые заведомо не являются таргетами исходного кода
        let excludedNames: Set<String> = [
            "build", "DerivedData", "Pods", "Frameworks", "AI_Docs",
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

    /// Создаёт папку AI_Docs и шаблонные файлы внутри указанного таргета.
    ///
    /// Идемпотентность: если файлы уже существуют — не трогает их.
    /// Это защищает накопленные данные при повторных запусках приложения.
    private func setupAIDocs(for target: WorkspaceTarget) async {
        // Создаём папку AI_Docs если её нет
        if !fileManager.fileExists(atPath: target.aiDocsURL.path) {
            try? fileManager.createDirectory(at: target.aiDocsURL, withIntermediateDirectories: true)
        }

        // semantic.json — пустой JSON-объект как начальное состояние
        if !fileManager.fileExists(atPath: target.semanticFileURL.path) {
            try? "{}".write(to: target.semanticFileURL, atomically: true, encoding: .utf8)
        }

        // architecture.md — шаблон с Mermaid-диаграммой
        if !fileManager.fileExists(atPath: target.architectureFileURL.path) {
            let architectureTemplate = makeArchitectureTemplate(for: target)
            try? architectureTemplate.write(to: target.architectureFileURL, atomically: true, encoding: .utf8)
        }

        // project_map.md — шаблон карты проекта с РЕАЛЬНЫМИ найденными файлами!
        // ПОЧЕМУ: Это предотвращает создание пустых бесполезных шаблонов и сразу дает ИИ контекст файлов.
        if !fileManager.fileExists(atPath: target.projectMapFileURL.path) {
            let scanResult = scanTargetDirectory(target)
            let projectMapTemplate = makeProjectMapTemplate(for: target, scanResult: scanResult)
            try? projectMapTemplate.write(to: target.projectMapFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Сканирует директорию таргета и классифицирует файлы для карты проекта.
    private func scanTargetDirectory(_ target: WorkspaceTarget) -> TargetScanResult {
        var sourceFiles: [String] = []
        var resourceFiles: [String] = []
        var otherFiles: [String] = []
        
        let sourceExtensions: Set<String> = ["swift", "metal", "mlmodel", "xcdatamodeld"]
        let resourceExtensions: Set<String> = [
            "xcassets", "strings", "stringsdict", "storyboard",
            "xib", "json", "png", "jpg", "jpeg", "pdf"
        ]
        
        // Исключаем саму папку AI_Docs и другие служебные, чтобы избежать рекурсии
        let excludedDirs: Set<String> = ["AI_Docs", ".git", "DerivedData", ".build"]
        
        guard let enumerator = fileManager.enumerator(
            at: target.directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TargetScanResult(targetName: target.name, sourceFiles: [], resourceFiles: [], otherFiles: [])
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                continue
            }
            
            if resourceValues.isDirectory == true {
                if excludedDirs.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            guard resourceValues.isRegularFile == true else { continue }
            
            // Вычисляем относительный путь
            let relativePath = fileURL.path.replacingOccurrences(
                of: target.directoryURL.path + "/",
                with: ""
            )
            
            let ext = fileURL.pathExtension.lowercased()
            if sourceExtensions.contains(ext) {
                sourceFiles.append(relativePath)
            } else if resourceExtensions.contains(ext) {
                resourceFiles.append(relativePath)
            } else if !ext.isEmpty {
                otherFiles.append(relativePath)
            }
        }
        
        return TargetScanResult(
            targetName: target.name,
            sourceFiles: sourceFiles.sorted(),
            resourceFiles: resourceFiles.sorted(),
            otherFiles: otherFiles.sorted()
        )
    }

    /// Мигрирует старый корневой AI_Docs/semantic.json в App-таргет.
    ///
    /// Зачем: предыдущая версия MemoryManager хранила память в корне воркспейса.
    /// Новая архитектура хранит память внутри каждого таргета.
    /// Миграция сохраняет накопленные данные и убирает устаревшую структуру.
    private func migrateOldRootAIDocs() {
        let oldAIDocsURL = workspaceURL.appendingPathComponent("AI_Docs")
        let oldSemanticURL = oldAIDocsURL.appendingPathComponent("semantic.json")

        // Если старого файла нет — мигрировать нечего
        guard fileManager.fileExists(atPath: oldSemanticURL.path) else { return }

        // Читаем старые данные
        let oldStorage = readStorage(at: oldSemanticURL)
        guard !oldStorage.isEmpty else {
            // Старый файл пуст — просто удаляем старую папку
            try? fileManager.removeItem(at: oldAIDocsURL)
            return
        }

        // Определяем целевой таргет для миграции: App-таргет или первый доступный
        guard let primaryTarget = appTarget() ?? targets.first else { return }

        // Читаем текущее состояние целевого semantic.json
        var targetStorage = readStorage(at: primaryTarget.semanticFileURL)

        // Переносим только те ключи, которых ещё нет в целевом файле.
        // Существующие данные имеют приоритет — не затираем то, что уже есть.
        var didMigrate = false
        for (key, record) in oldStorage where targetStorage[key] == nil {
            targetStorage[key] = record
            didMigrate = true
        }

        if didMigrate {
            writeStorage(targetStorage, to: primaryTarget.semanticFileURL)
        }

        //  Удаляем старую корневую папку AI_Docs для чистоты проекта
        try? fileManager.removeItem(at: oldAIDocsURL)
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

    // MARK: - Генераторы шаблонов

    /// Генерирует красивый шаблон architecture.md с Mermaid-диаграммой для таргета.
    ///
    /// Mermaid-граф включён потому что он рендерится прямо в GitHub/GitLab и в Xcode Preview,
    /// что делает документацию живой и наглядной без дополнительных инструментов.
    private func makeArchitectureTemplate(for target: WorkspaceTarget) -> String {
        let kindLabel = target.kind == .appTarget ? "App Target" : "Library Target"
        let date = ISO8601DateFormatter().string(from: Date())

        return """
        # Architecture — \(target.name)

        > **Target type:** \(kindLabel)
        > **Created:** \(date)
        > **Managed by:** Chappie AI Assistant

        ---

        ## Overview

        _Describe the high-level purpose and responsibilities of this target here._

        ---

        ## Component Diagram

        ```mermaid
        graph TD
            A[\(target.name)] --> B[Core Logic]
            A --> C[UI Layer]
            A --> D[Data Layer]
            B --> E[Services]
            C --> F[Views]
            D --> G[Models]
        ```

        ---

        ## Key Design Decisions

        | Decision | Rationale | Date |
        |----------|-----------|------|
        | _Add decisions here_ | _Why was this chosen?_ | \(date) |

        ---

        ## Dependencies

        _List external dependencies and their purpose._

        ---

        ## Notes

        _Additional architectural notes, constraints, or future plans._
        """
    }

    /// Генерирует красивый шаблон project_map.md — карту файлов и модулей таргета с РЕАЛЬНЫМ списком файлов.
    private func makeProjectMapTemplate(for target: WorkspaceTarget, scanResult: TargetScanResult) -> String {
        let kindLabel = target.kind == .appTarget ? "App Target" : "Library Target"
        let date = ISO8601DateFormatter().string(from: Date())

        var content = """
        # Project Map — \(target.name)

        > **Target type:** \(kindLabel)
        > **Created:** \(date)
        > **Managed by:** Chappie AI Assistant
        > **Total files found:** \(scanResult.totalCount)

        ---

        ## Directory Structure

        ```
        \(target.name)/
        ├── AI_Docs/
        │   ├── semantic.json       # AI memory storage
        │   ├── architecture.md     # Architecture documentation
        │   └── project_map.md      # This file
        └── ...                     # Source files
        ```

        ---

        """

        if !scanResult.sourceFiles.isEmpty {
            content += "## 🔵 Source Files (\(scanResult.sourceFiles.count))\n\n"
            for file in scanResult.sourceFiles {
                content += "- `\(file)`\n"
            }
            content += "\n"
        }

        if !scanResult.resourceFiles.isEmpty {
            content += "## 🟡 Resource Files (\(scanResult.resourceFiles.count))\n\n"
            for file in scanResult.resourceFiles {
                content += "- `\(file)`\n"
            }
            content += "\n"
        }

        if !scanResult.otherFiles.isEmpty {
            content += "## ⚪ Other Files (\(scanResult.otherFiles.count))\n\n"
            for file in scanResult.otherFiles {
                content += "- `\(file)`\n"
            }
            content += "\n"
        }

        content += """
        ## Key Files Description

        | File | Purpose | Owner |
        |------|---------|-------|
        | _Add key files here_ | _What does it do?_ | _Team/Person_ |

        ---

        ## Public API

        _Document the public interface of this target here._

        ---

        ## Known Issues & TODOs

        - [ ] _Add known issues or planned improvements here_

        ---

        ## Changelog

        | Date | Change | Author |
        |------|--------|--------|
        | \(date) | Initial creation | Chappie AI |
        """

        return content
    }
}
