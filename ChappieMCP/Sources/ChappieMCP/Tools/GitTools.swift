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
//
// КРИТИЧЕСКИ ВАЖНО — GIT PAGER:
// git diff, git log и другие команды по умолчанию запускают pager (less),
// который ждёт ввода с TTY. В нашем случае TTY нет (headless subprocess),
// поэтому pager зависает навсегда, а readDataToEndOfFile() никогда не возвращается.
// РЕШЕНИЕ: всегда передаём GIT_PAGER=cat и GIT_TERMINAL_PROMPT=0 в окружении.
// GIT_PAGER=cat — отключает pager, вывод идёт напрямую в stdout.
// GIT_TERMINAL_PROMPT=0 — запрещает git запрашивать пароль через TTY.

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
    ///
    /// ВАЖНО: git diff без --no-pager или GIT_PAGER=cat зависает навсегда
    /// в headless-процессе, т.к. запускает less и ждёт TTY.
    /// Мы решаем это через переменную окружения GIT_PAGER=cat в runProcess.
    ///
    /// - Parameter staged: если true — показывает staged изменения (после git add),
    ///   если false — unstaged (рабочая директория vs индекс).
    func diff(staged: Bool) async -> ToolResult {
        var args = ["diff"]
        if staged {
            args.append("--staged")
        }
        // --stat: сводка изменённых файлов
        // -p: полный патч (построчные изменения)
        // --no-color: без ANSI-кодов цвета (они не нужны ИИ и засоряют вывод)
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
    ///
    /// КЛЮЧЕВОЕ РЕШЕНИЕ — чтение stdout через availableData в цикле:
    /// readDataToEndOfFile() блокируется до закрытия pipe, что может не произойти
    /// если git запустил дочерний процесс (pager). Несмотря на GIT_PAGER=cat,
    /// мы читаем данные через цикл availableData для надёжности.
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

        // КРИТИЧЕСКИ ВАЖНО: окружение для git в headless-режиме.
        //
        // GIT_PAGER=cat — отключает pager (less/more/delta).
        //   Без этого git diff/log зависают навсегда ожидая TTY.
        //
        // GIT_TERMINAL_PROMPT=0 — запрещает git запрашивать пароль через TTY.
        //   Без этого git clone/fetch могут зависнуть ожидая ввода credentials.
        //
        // GIT_CONFIG_NOSYSTEM=1 — игнорирует /etc/gitconfig.
        //   Предотвращает неожиданные настройки из системного конфига.
        //
        // HOME — нужен git для поиска ~/.gitconfig и ~/.ssh/
        //
        // TERM=dumb — сообщает программам что терминал "тупой" (нет цветов, нет TTY).
        //   Дополнительная защита от попыток использовать escape-коды.
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin",
            "LANG": "en_US.UTF-8",
            "GIT_PAGER": "cat",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "TERM": "dumb"
        ]

        do {
            try process.run()
        } catch {
            return .failure("Не удалось запустить git: \(error.localizedDescription)")
        }

        // Читаем stdout и stderr асинхронно через availableData в цикле.
        //
        // ПОЧЕМУ НЕ readDataToEndOfFile():
        // readDataToEndOfFile() блокируется до получения EOF на pipe.
        // Если git по какой-то причине не закрывает pipe (баг, pager-процесс),
        // мы зависаем навсегда. Чтение через availableData + waitUntilExit надёжнее.
        //
        // ПОЧЕМУ availableData В ЦИКЛЕ:
        // availableData возвращает всё что есть прямо сейчас в буфере pipe.
        // Мы собираем данные в цикле пока процесс не завершится.
        var stdoutData = Data()
        var stderrData = Data()

        // Читаем данные в цикле пока процесс работает
        while process.isRunning {
            let chunk = stdoutPipe.fileHandleForReading.availableData
            if !chunk.isEmpty {
                stdoutData.append(chunk)
            }
            // Небольшая пауза чтобы не спиннить CPU в tight loop
            Thread.sleep(forTimeInterval: 0.05)
        }

        // Читаем остатки после завершения процесса
        // (данные могли накопиться в буфере pipe после последней итерации цикла)
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutData.append(remainingStdout)
        stderrData.append(remainingStderr)

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
