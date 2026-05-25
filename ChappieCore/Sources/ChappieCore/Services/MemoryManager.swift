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
// ФИНАЛЬНАЯ СТРУКТУРА ПАМЯТИ:
//
//   ~/Documents/Chappie/semantic.json   — ЕДИНСТВЕННЫЙ файл семантической памяти.
//                                         Глобальный. scope: .project и scope: .global
//                                         оба пишут/читают сюда.
//
//   <WorkspaceRoot>/
//   ├── architecture.md                 — архитектура всего проекта (корень воркспейса)
//   ├── Chappie/architecture.md         — архитектура таргета
//   ├── ChappieCore/architecture.md
//   ├── ChappieCoreTests/architecture.md
//   └── ChappieMCP/architecture.md
//
// ПОЧЕМУ ОДИН ФАЙЛ ПАМЯТИ:
// Раньше semantic.json создавался в каждом таргете воркспейса, что порождало:
// - Дублирование данных между таргетами
// - Путаницу: в каком таргете искать нужную запись?
// - Лишние файлы в git-репозитории
// Один глобальный файл — единственный источник истины для семантической памяти.
// Параметры scope/targetName сохранены в API для обратной совместимости, но оба
// режима теперь работают с одним и тем же файлом.
//
// РОЛЬ architecture.md:
// Это ДОКУМЕНТАЦИЯ, а не данные. Чаппи читает и пишет его через инструменты
// read_file/write_file как обычный текстовый файл. MemoryManager его не трогает
// (только создаёт шаблон при первом обнаружении нового таргета).
//
// ГРУППА "📚 Docs" В XCODE — СТАТИЧЕСКАЯ:
// Группа 📚 Docs в project.pbxproj управляется ВРУЧНУЮ мной (Чаппи) через write_file.
// Программная автосинхронизация через XcodeDocsGroupManager была УДАЛЕНА (2025-07-10)
// потому что она повреждала project.pbxproj при каждом запуске приложения, вызывая
// "Failed to load container for document at url: ..." в Xcode.
// Причина: сложная текстовая манипуляция pbxproj давала нестабильный результат.
// ПРАВИЛО: при добавлении нового таргета — Чаппи вручную обновляет project.pbxproj
// через write_file, добавляя PBXFileReference и запись в children группы 📚 Docs.

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
/// - Вся семантическая память: ~/Documents/Chappie/semantic.json (ОДИН файл)
/// - Документация таргетов: <Workspace>/<TargetName>/architecture.md
/// - Навигация в Xcode: группа "📚 Docs" в project.pbxproj (управляется ВРУЧНУЮ Чаппи)
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

    /// URL единственного файла семантической памяти: ~/Documents/Chappie/semantic.json.
    /// Вычисляется один раз — файловая система не меняется в процессе работы.
    /// Используется для ВСЕХ операций чтения/записи памяти независимо от scope.
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
    /// 1. Создаёт папку ~/Documents/Chappie и файл semantic.json (если нет).
    /// 2. Сканирует директории первого уровня в workspaceURL.
    /// 3. Фильтрует служебные, скрытые папки и пакеты Xcode.
    /// 4. Определяет тип каждого таргета (App или Library).
    /// 5. Создаёт architecture.md для каждого нового таргета (если нет).
    /// 6. Очищает устаревшие папки AI_Docs/ и semantic.json в таргетах (миграция).
    ///
    /// НАМЕРЕННО НЕ ДЕЛАЕТ:
    /// - НЕ трогает project.pbxproj (группа 📚 Docs управляется вручную Чаппи через write_file).
    ///   Автоматическая запись pbxproj при каждом запуске вызывала повреждение файла проекта
    ///   и ошибку "Failed to load container" в Xcode.
    ///
    /// Метод идемпотентен — повторный вызов не затирает существующие данные.
    public func initializeWorkspaceMemory() async {
        // Защита от двойной инициализации при параллельных вызовах
        guard !isInitialized else { return }

        print("[MemoryManager] Начало инициализации структуры памяти...")

        // 1. Глобальная память — единственный файл semantic.json
        setupGlobalMemory()

        // 2. Сканирование и классификация таргетов воркспейса
        let discovered = discoverTargets()
        self.targets = discovered

        // 3. Создание architecture.md для каждого нового таргета (только если не существует)
        for target in targets {
            setupTargetFiles(for: target)
        }

        // 4. Очищаем устаревшие артефакты: AI_Docs/ и semantic.json в корнях таргетов
        cleanupLegacyFiles()

        // ПРИМЕЧАНИЕ: XcodeDocsGroupManager.sync() намеренно УБРАН отсюда.
        // Причина: автоматическая правка project.pbxproj при каждом запуске приложения
        // давала нестабильный результат и повреждала файл проекта.
        // Группа 📚 Docs теперь управляется статически — Чаппи правит pbxproj вручную
        // через write_file когда добавляется или удаляется таргет.

        isInitialized = true
        print("[MemoryManager] ✅ Инициализация завершена. Таргетов: \(targets.count). Память: ~/Documents/Chappie/semantic.json")
    }

    // MARK: - Публичные методы чтения/записи

    /// Сохраняет запись в памяти по ключу.
    ///
    /// УПРОЩЁННАЯ ЛОГИКА: scope и targetName игнорируются для определения файла.
    /// Все записи идут в ~/Documents/Chappie/semantic.json — единственный файл памяти.
    /// Параметры scope/targetName сохранены в сигнатуре для совместимости с ToolExecutionService.
    public func saveMemory(key: String, type: String, jsonString: String, scope: MemoryScope = .project, targetName: String? = nil) async {
        await ensureInitialized()
        // Пишем всегда в один глобальный файл — никаких таргет-специфичных файлов
        writeRecord(key: key, type: type, data: jsonString, to: globalFileURL)
    }

    /// Читает запись по ключу.
    ///
    /// УПРОЩЁННАЯ ЛОГИКА: targetName игнорируется для определения файла.
    /// Все записи читаются из ~/Documents/Chappie/semantic.json.
    /// Параметр targetName сохранён в сигнатуре для совместимости с ToolExecutionService.
    public func readMemory(key: String, targetName: String? = nil) async -> String? {
        await ensureInitialized()
        let storage = readStorage(at: globalFileURL)
        return storage[key]?.data
    }

    /// Ищет все записи указанного типа.
    ///
    /// УПРОЩЁННАЯ ЛОГИКА: targetName игнорируется.
    /// Поиск всегда в ~/Documents/Chappie/semantic.json.
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
    /// УПРОЩЁННАЯ ЛОГИКА: targetName игнорируется.
    /// Удаление всегда из ~/Documents/Chappie/semantic.json.
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
    private func ensureInitialized() async {
        guard !isInitialized else { return }
        await initializeWorkspaceMemory()
    }

    /// Создаёт папку ~/Documents/Chappie и файл semantic.json.
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

            // Пропускаем пакеты Xcode (.xcodeproj, .xcworkspace и т.д.)
            guard url.pathExtension.isEmpty else { continue }

            let kind = classifyTarget(at: url)
            let target = WorkspaceTarget(name: name, directoryURL: url, kind: kind)
            discovered.append(target)
        }

        // Сортируем: App-таргет первым, затем библиотеки по алфавиту
        discovered.sort { lhs, rhs in
            if lhs.kind == .appTarget && rhs.kind != .appTarget { return true }
            if lhs.kind != .appTarget && rhs.kind == .appTarget { return false }
            return lhs.name < rhs.name
        }

        return discovered
    }

    /// Определяет тип таргета: App или Library.
    /// App-таргет содержит файл с суффиксом 'App.swift' — точку входа SwiftUI (@main).
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

    /// Создаёт architecture.md для таргета если его ещё нет.
    ///
    /// ТОЛЬКО architecture.md — никакого semantic.json в таргете!
    /// Вся семантическая память хранится в ~/Documents/Chappie/semantic.json.
    private func setupTargetFiles(for target: WorkspaceTarget) {
        // Создаём architecture.md только если не существует — не затираем реальную документацию!
        if !fileManager.fileExists(atPath: target.architectureFileURL.path) {
            let template = makeArchitectureTemplate(for: target)
            try? template.write(to: target.architectureFileURL, atomically: true, encoding: .utf8)
            print("[MemoryManager] 📄 Создан шаблон: \(target.name)/architecture.md")
        }
    }

    /// Удаляет устаревшие артефакты предыдущих версий:
    /// - AI_Docs/ папки в таргетах (мигрирует данные из AI_Docs/semantic.json в глобальный файл)
    /// - semantic.json в корнях таргетов (мигрирует данные в глобальный файл)
    ///
    /// Миграция данных: перед удалением переносим все записи в ~/Documents/Chappie/semantic.json.
    /// Это гарантирует что накопленная память не потеряется при обновлении формата.
    private func cleanupLegacyFiles() {
        for target in targets {
            // 1. Мигрируем и удаляем AI_Docs/ (если осталась от очень старых версий)
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

            // 2. Мигрируем и удаляем semantic.json из корня таргета
            //    (он появился как промежуточный формат и теперь тоже устарел)
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

        // 3. Также чистим корневую AI_Docs/ воркспейса если осталась
        let rootAIDocsURL = workspaceURL.appendingPathComponent("AI_Docs")
        if fileManager.fileExists(atPath: rootAIDocsURL.path) {
            let legacySemanticURL = rootAIDocsURL.appendingPathComponent("semantic.json")
            if fileManager.fileExists(atPath: legacySemanticURL.path) {
                migrateSemanticFile(from: legacySemanticURL, label: "root/AI_Docs/semantic.json")
            }
            // Удаляем только если там нет chat_history.json — это активные данные!
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

    /// Мигрирует данные из устаревшего semantic.json в глобальный файл памяти.
    /// Переносит только те ключи, которых ещё нет в глобальном файле (не перезаписывает актуальные данные).
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

    /// Возвращает основной App-таргет (первый с kind == .appTarget).
    private func appTarget() -> WorkspaceTarget? {
        targets.first { $0.kind == .appTarget }
    }

    // MARK: - Низкоуровневые операции с файлами

    /// Читает словарь записей памяти из JSON-файла.
    /// Возвращает пустой словарь при любой ошибке — безопасный дефолт.
    private func readStorage(at url: URL) -> [String: MemoryRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let storage = try? JSONDecoder().decode([String: MemoryRecord].self, from: data) else {
            return [:]
        }
        return storage
    }

    /// Записывает словарь записей памяти в JSON-файл.
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
    private func writeRecord(key: String, type: String, data: String, to url: URL) {
        var storage = readStorage(at: url)
        storage[key] = MemoryRecord(type: type, data: data)
        writeStorage(storage, to: url)
    }

    // MARK: - Генератор шаблона architecture.md

    /// Генерирует минимальный шаблон architecture.md для нового таргета.
    ///
    /// Шаблон нужен только для новых таргетов, которые Чаппи обнаружит в будущем.
    /// Реальные таргеты Chappie уже имеют подробные architecture.md.
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
