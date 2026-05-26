// ProjectModels.swift
// ChappieCore
//
// НАЗНАЧЕНИЕ:
// Модели данных для проектов в системе мультитредовости (REFACTOR-THREADS IT-01).
//
// ПРИНЦИП:
// ProjectEntity хранится в SwiftData только с примитивами и Data.
// ProjectSettings — Codable struct, сериализуется в settingsJSON.
//
// ЗАЧЕМ SECURITY-SCOPED BOOKMARK:
// macOS sandbox запрещает прямой доступ к произвольным папкам.
// Security-scoped bookmark — это постоянный токен доступа, который:
// 1. Создаётся один раз при выборе папки пользователем (через NSOpenPanel)
// 2. Сохраняется в базе данных
// 3. При каждом запуске приложения "разрешается" обратно в URL с правами доступа
// Без bookmarkData приложение потеряет доступ к папке проекта после перезапуска.
//
// IT-09: ProjectSettings расширен полным набором прав агента.
// Роль по умолчанию — .advisor (безопасный дефолт).
// isProgrammingProject разблокирует расширенные настройки (git, тесты, архитектура, комментарии).

import Foundation
import SwiftData

// MARK: - ProjectEntity (SwiftData хранилище)

/// Одна запись проекта в базе данных SwiftData.
///
/// Проект = папка на диске (воркспейс) + настройки.
/// Один проект может быть привязан к нескольким тредам одновременно.
///
/// ПОЧЕМУ BOOKMARK, А НЕ ПУТЬ:
/// Абсолютный путь ненадёжен — пользователь может переименовать папку или переместить её.
/// Security-scoped bookmark отслеживает папку по inode, а не по пути.
/// Это стандартная практика для sandbox-приложений на macOS.
@Model
public final class ProjectEntity {

    // MARK: - Идентификация

    public var id: UUID
    public var displayName: String

    // MARK: - Доступ к файловой системе

    public var bookmarkData: Data

    // MARK: - Временные метки

    public var createdAt: Date

    // MARK: - JSON-сериализованные настройки

    /// Настройки проекта, сериализованные через JSONEncoder.
    /// Тип оригинала: ProjectSettings (IT-09 — расширен правами агента).
    public var settingsJSON: Data

    // MARK: - Инициализация

    public init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.createdAt = Date()
        self.settingsJSON = (try? JSONEncoder().encode(settings)) ?? Data()
    }
}

// MARK: - IT-09: Перечисления прав агента

/// Роль агента в проекте.
///
/// ДЕФОЛТ: .advisor — безопасная роль только для чтения.
/// При смене executor → advisor — все флаги доступов сбрасываются.
public enum AgentRole: String, Codable, Sendable, CaseIterable {
    case advisor  // Только чтение файлов. Советует, не изменяет.
    case executor // Полный доступ к инструментам согласно настройкам.

    public var displayName: String {
        switch self {
        case .advisor:  return "Советник"
        case .executor: return "Исполнитель"
        }
    }

    public var description: String {
        switch self {
        case .advisor:
            return "Читает файлы, даёт советы и сниппеты. Изменения вносит пользователь."
        case .executor:
            return "Самостоятельно работает с файлами, git и инструментами."
        }
    }
}

/// Уровень доступа к git-инструментам.
public enum GitAccessLevel: String, Codable, Sendable, CaseIterable {
    case none       // Git инструменты недоступны
    case statusOnly // Только git_status и git_log (чтение)
    case write      // status, log, add, commit, reset (без diff)
    case full       // Все git инструменты (включая git_log, git_reset)

    public var displayName: String {
        switch self {
        case .none:       return "Нет доступа"
        case .statusOnly: return "Только чтение (status, log)"
        case .write:      return "Запись (add, commit)"
        case .full:       return "Полный доступ"
        }
    }

    // Набор разрешённых git-инструментов для каждого уровня.
    // git_diff НИКОГДА не разрешён — железный запрет (стоит денег клиента).
    public var allowedTools: Set<String> {
        switch self {
        case .none:
            return []
        case .statusOnly:
            return ["git_status", "git_log"]
        case .write:
            return ["git_status", "git_log", "git_add", "git_commit", "git_reset"]
        case .full:
            return ["git_status", "git_log", "git_add", "git_commit", "git_reset"]
        }
    }
}

/// Уровень доступа к инструментам автотестов.
public enum TestsAccessLevel: String, Codable, Sendable, CaseIterable {
    case none      // Тесты недоступны
    case readOnly  // Только read_build_log (смотреть логи, семафорить пользователю)
    case run       // Запускать тесты (run_tests + read_build_log)
    case write     // Запускать И создавать новые тесты

    public var displayName: String {
        switch self {
        case .none:     return "Нет доступа"
        case .readOnly: return "Только чтение логов"
        case .run:      return "Запуск тестов"
        case .write:    return "Запуск + создание тестов"
        }
    }

    public var canRun: Bool { self == .run || self == .write }
    public var canWrite: Bool { self == .write }
    public var canReadLog: Bool { self != .none }
}

/// Язык для комментариев в коде и архитектурных файлов.
public enum ProjectLanguage: String, Codable, Sendable, CaseIterable {
    case english // Английский
    case native  // Родной язык пользователя (определяется из системных настроек)

    public var displayName: String {
        switch self {
        case .english: return "Английский"
        case .native:  return "Родной язык пользователя"
        }
    }
}

// MARK: - ProjectSettings (Codable настройки проекта) — IT-09

/// Настройки одного проекта — сериализуются в JSON и хранятся в ProjectEntity.settingsJSON.
///
/// АРХИТЕКТУРА IT-09:
/// ProjectSettings = права и конфигурация агента.
/// ProjectMemory (MemoryEntity) = знания и контекст проекта.
/// Два независимых источника → два блока в system prompt.
///
/// БЕЗОПАСНЫЕ ДЕФОЛТЫ:
/// - agentRole = .advisor (только чтение)
/// - isProgrammingProject = false (расширенные настройки заблокированы)
/// - Все флаги доступов = минимальные значения
///
/// ПОЧЕМУ STRUCT:
/// Настройки — value type. Codable + Hashable даёт бесплатную сериализацию.
public struct ProjectSettings: Codable, Sendable, Equatable, Hashable {

    // MARK: - Основные настройки (доступны всегда)

    /// Роль агента в проекте.
    /// ДЕФОЛТ: .advisor — безопасная роль только для чтения.
    public var agentRole: AgentRole

    /// Предпочтительный язык для общения в контексте этого проекта.
    /// nil = использовать язык пользователя из системных настроек.
    public var preferredLanguage: String?

    // MARK: - Флаг программистского проекта (IT-09)

    /// Является ли проект программистским.
    ///
    /// ЗАЧЕМ ЭТОТ ФЛАГ:
    /// Разблокирует расширенные настройки: git, тесты, архитектура, комментарии.
    /// Для документов, юридических текстов и т.д. эти настройки не нужны и не показываются.
    /// Пользователь явно указывает что это программистский проект — тогда появляются доп. опции.
    public var isProgrammingProject: Bool

    // MARK: - Расширенные настройки (только для isProgrammingProject = true)

    /// Уровень доступа к git-инструментам.
    /// Активен только если isProgrammingProject = true И agentRole = .executor.
    /// git_diff НИКОГДА не разрешён — железный запрет в ToolExecutionService.
    public var gitAccess: GitAccessLevel

    /// Уровень доступа к инструментам автотестов.
    /// Активен только если isProgrammingProject = true И agentRole = .executor.
    public var testsAccess: TestsAccessLevel

    // MARK: - Настройки архитектурных файлов

    /// Разрешено ли агенту создавать и редактировать архитектурные файлы.
    ///
    /// false = агент может ЧИТАТЬ существующие architecture.md, но не создавать новые.
    /// true  = агент может создавать, редактировать и актуализировать архитектурные файлы.
    ///
    /// ВАЖНО: пути к файлам обсуждаются с пользователем и сохраняются в ProjectMemory.
    /// Агент не создаёт файлы без явного согласования.
    public var architectureEnabled: Bool

    /// Язык архитектурных файлов.
    /// Активен только если architectureEnabled = true.
    public var architectureLanguage: ProjectLanguage

    // MARK: - Настройки комментариев в коде

    /// Разрешено ли добавлять комментарии в код.
    /// Активен только если isProgrammingProject = true.
    public var commentsEnabled: Bool

    /// Язык комментариев в коде.
    /// Активен только если commentsEnabled = true.
    public var commentsLanguage: ProjectLanguage

    // MARK: - Инициализация с безопасными дефолтами

    public init(
        agentRole: AgentRole = .advisor,
        preferredLanguage: String? = nil,
        isProgrammingProject: Bool = false,
        gitAccess: GitAccessLevel = .none,
        testsAccess: TestsAccessLevel = .none,
        architectureEnabled: Bool = false,
        architectureLanguage: ProjectLanguage = .english,
        commentsEnabled: Bool = false,
        commentsLanguage: ProjectLanguage = .english
    ) {
        self.agentRole = agentRole
        self.preferredLanguage = preferredLanguage
        self.isProgrammingProject = isProgrammingProject
        self.gitAccess = gitAccess
        self.testsAccess = testsAccess
        self.architectureEnabled = architectureEnabled
        self.architectureLanguage = architectureLanguage
        self.commentsEnabled = commentsEnabled
        self.commentsLanguage = commentsLanguage
    }

    // MARK: - Мутирующий метод: сброс при смене роли на advisor

    /// Сбрасывает все флаги доступов при переключении на роль .advisor.
    ///
    /// ЗАЧЕМ:
    /// При смене executor → advisor пользователь должен видеть алерт и подтверждение.
    /// После подтверждения — все расширенные права сбрасываются до минимума.
    /// Это гарантирует что советник действительно не может изменять файлы.
    public mutating func downgradeToAdvisor() {
        agentRole = .advisor
        gitAccess = .none
        testsAccess = .none
        architectureEnabled = false
        commentsEnabled = false
    }
}

// MARK: - ProjectSettings: Форматирование для system prompt (IT-09)

extension ProjectSettings {

    /// Формирует блок настроек проекта для вставки в system prompt.
    ///
    /// СТРУКТУРА БЛОКА:
    /// ```
    /// ## Project Settings: Chappie
    /// - Role: EXECUTOR
    /// - Programming project: yes
    /// - Git access: write (add, commit, status, log, reset) [git_diff: FORBIDDEN]
    /// - Tests: run + write
    /// - Architecture files: enabled (English)
    /// - Code comments: enabled (English)
    /// ```
    ///
    /// ПОЧЕМУ В ПРОМПТЕ:
    /// Агент должен знать свои права ДО начала работы, а не узнавать о них при блокировке.
    /// Это позволяет агенту заранее выбирать правильный подход и подсказывать пользователю
    /// куда идти в настройках если нужно расширить права.
    public func formatForSystemPrompt(projectName: String) -> String {
        var lines: [String] = ["## Project Settings: \(projectName)"]

        lines.append("- Role: \(agentRole.rawValue.uppercased())")

        if agentRole == .advisor {
            lines.append("- Access: read-only (list_files, read_file). All write/git/test tools are BLOCKED.")
            lines.append("- To unlock tools: go to project settings → change role to Executor.")
            return lines.joined(separator: "\n")
        }

        // Executor — показываем детальные права
        lines.append("- Programming project: \(isProgrammingProject ? "yes" : "no")")

        if isProgrammingProject {
            // Git
            if gitAccess == .none {
                lines.append("- Git: BLOCKED (enable in project settings)")
            } else {
                let toolsList = gitAccess.allowedTools.sorted().joined(separator: ", ")
                lines.append("- Git: \(gitAccess.rawValue) [\(toolsList)] [git_diff: ALWAYS FORBIDDEN]")
            }

            // Tests
            switch testsAccess {
            case .none:
                lines.append("- Tests: BLOCKED (enable in project settings)")
            case .readOnly:
                lines.append("- Tests: read logs only (read_build_log). run_tests is BLOCKED.")
            case .run:
                lines.append("- Tests: run allowed (build_project, run_tests, read_build_log). Creating new tests: BLOCKED.")
            case .write:
                lines.append("- Tests: run + create allowed (build_project, run_tests, read_build_log, write test files).")
            }

            // Architecture
            if architectureEnabled {
                lines.append("- Architecture files: enabled (\(architectureLanguage.rawValue)). Discuss file paths with user before creating.")
            } else {
                lines.append("- Architecture files: read-only (enable write in project settings)")
            }

            // Comments
            if commentsEnabled {
                lines.append("- Code comments: enabled (\(commentsLanguage.rawValue))")
            } else {
                lines.append("- Code comments: DISABLED (enable in project settings)")
            }
        } else {
            lines.append("- Advanced settings (git, tests, architecture, comments): locked. Enable 'Programming project' in settings.")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - ProjectEntity вспомогательные методы

extension ProjectEntity {

    /// Десериализует настройки проекта из settingsJSON.
    /// Возвращает безопасные дефолты при ошибке.
    public var settings: ProjectSettings {
        guard !settingsJSON.isEmpty,
              let decoded = try? JSONDecoder().decode(ProjectSettings.self, from: settingsJSON)
        else {
            return ProjectSettings()
        }
        return decoded
    }

    /// Разрешает bookmark и возвращает URL воркспейса.
    ///
    /// ВАЖНО: Вызывающий код ОБЯЗАН вызвать url.stopAccessingSecurityScopedResource()
    /// после завершения работы с файлами!
    public func resolveWorkspaceURL() -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            print("[ProjectModels] ⚠️ Не удалось разрешить bookmark для проекта '\(displayName)'")
            return nil
        }

        if isStale {
            print("[ProjectModels] ⚠️ Bookmark устарел для проекта '\(displayName)'. Требуется переавторизация.")
        }

        return url
    }
}
