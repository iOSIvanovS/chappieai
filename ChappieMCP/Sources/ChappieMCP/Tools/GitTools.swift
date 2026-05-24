// GitTools.swift
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Реализует инструменты работы с git-репозиторием проекта Chappie.
// Каждый инструмент запускает git как дочерний процесс через Process()
// и возвращает его вывод в виде строки.
//
// ПОЧЕМУ Process(), А НЕ libgit2 ИЛИ SwiftGit2:
// 1. Нет зависимостей — не нужно тащить C-библиотеки.
// 2. Полная совместимость с git hooks, .gitconfig, SSH-ключами пользователя.
// 3. Вывод git уже отформатирован и понятен ИИ-агенту.
//
// БЕЗОПАСНОСТЬ:
// Все аргументы передаются как отдельные элементы массива [String],
// а НЕ через shell-строку. Это исключает shell injection.

import Foundation

/// Инструменты для работы с git-репозиторием.
final class GitTools: Sendable {
    /// Путь к корню проекта (где лежит .git).
    private let projectPath: String

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Публичные инструменты

    /// git status — показывает изменённые, новые и удалённые файлы.
    func status() async -> ToolResult {
        return await runGit(["status", "--short", "--branch"])
    }

    /// git diff — показывает содержимое изменений.
    /// - Parameter staged: если true — показывает staged изменения (после git add),
    ///   если false — unstaged (рабочая директория vs индекс).
    func diff(staged: Bool) async -> ToolResult {
        var args = ["diff"]
        if staged {
            args.append("--staged")
        }
        // Ограничиваем вывод чтобы не перегружать контекст ИИ
        args.append(contentsOf: ["--stat", "-p", "--no-color"])
        return await runGit(args)
    }

    /// git add — добавляет файлы в staging area.
    /// - Parameter paths: пути через пробел, или "." для всех файлов.
    func add(paths: String) async -> ToolResult {
        // Разбиваем строку путей на отдельные аргументы
        let pathArgs = paths.components(separatedBy: " ").filter { !$0.isEmpty }
        return await runGit(["add"] + pathArgs)
    }

    /// git commit — создаёт коммит с заданным сообщением.
    /// - Parameter message: текст коммита.
    func commit(message: String) async -> ToolResult {
        return await runGit(["commit", "-m", message])
    }

    /// git log — показывает последние N коммитов.
    /// - Parameter count: количество коммитов.
    func log(count: Int) async -> ToolResult {
        // --oneline: компактный формат (hash + message)
        // --decorate: показывает теги и ветки
        // --graph: ASCII-дерево для визуализации веток
        return await runGit(["log", "--oneline", "--decorate", "--graph", "-\(count)"])
    }

    /// git reset HEAD — убирает все файлы из staging area (unstage all).
    func reset() async -> ToolResult {
        return await runGit(["reset", "HEAD"])
    }

    // MARK: - Приватный запуск процесса

    /// Запускает git с переданными аргументами в директории проекта.
    ///
    /// Зачем async: Process() — синхронный API, но мы оборачиваем в
    /// withCheckedContinuation чтобы не блокировать кооперативный поток.
    ///
    /// - Parameter args: аргументы git (без самого "git").
    /// - Returns: ToolResult с stdout или stderr при ошибке.
    private func runGit(_ args: [String]) async -> ToolResult {
        return await withCheckedContinuation { continuation in
            // Запускаем в отдельном потоке чтобы не блокировать Swift Concurrency
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/usr/bin/git",
                    args: args,
                    workingDirectory: self.projectPath
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Синхронно запускает процесс и возвращает результат.
    ///
    /// Зачем синхронная версия: Process.waitUntilExit() — блокирующий вызов,
    /// поэтому мы вызываем его из DispatchQueue, а не из async-контекста напрямую.
    private func runProcess(executable: String, args: [String], workingDirectory: String) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // Перехватываем stdout и stderr в Pipe
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Устанавливаем минимальное окружение для git
        // HOME нужен git для поиска ~/.gitconfig и ~/.ssh/
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "en_US.UTF-8"
        ]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure("Не удалось запустить git: \(error.localizedDescription)")
        }

        // Читаем вывод
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        // git возвращает код выхода 0 при успехе
        if process.terminationStatus == 0 {
            let output = stdout.isEmpty ? "(нет вывода)" : stdout
            return .success("git \(args.joined(separator: " ")):\n\(output)")
        } else {
            // При ошибке возвращаем stderr (там обычно описание проблемы)
            let errorOutput = stderr.isEmpty ? stdout : stderr
            return .failure("git \(args.joined(separator: " ")) завершился с кодом \(process.terminationStatus):\n\(errorOutput)")
        }
    }
}
