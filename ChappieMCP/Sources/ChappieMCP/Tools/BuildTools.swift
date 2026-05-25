// BuildTools.swift
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Реализует инструменты сборки и тестирования проекта Chappie через xcodebuild.
// Результаты сборки сохраняются в лог-файл для последующего чтения.
//
// ПОЧЕМУ xcodebuild ДЛЯ ТЕСТОВ, А НЕ swift test:
// ChappieCoreTests — это Xcode Unit Test Bundle (таргет в Chappie.xcodeproj),
// а НЕ SPM testTarget в Package.swift. Поэтому swift test не знает о нём.
// Единственный правильный способ запустить эти тесты — xcodebuild test
// со схемой ChappieCoreTests и destination macOS.
//
// СХЕМЫ:
// - build_project → схема "Chappie" (собирает всё приложение)
// - run_tests     → схема "ChappieCoreTests" (запускает тесты библиотеки)
//
// DESTINATION (ВАЖНО — 2025-07-11):
// Используем "platform=macOS,name=Any Mac" — универсальный destination,
// который работает на ЛЮБОЙ архитектуре (x86_64 и arm64).
// НЕ указываем arch явно — это вызывало ошибку на Intel-машинах:
// "Unable to find a device matching platform=macOS,arch=arm64"
//
// ИСПРАВЛЕНИЕ ДЕДЛОКА PIPE (2025-07-11):
// ПРОБЛЕМА: process.waitUntilExit() + readDataToEndOfFile() ПОСЛЕ него = ДЕДЛОК.
// Pipe имеет буфер ~64KB. Если xcodebuild пишет больше — он блокируется в ожидании
// чтения из Pipe. Но мы читаем ПОСЛЕ waitUntilExit(). Оба ждут друг друга вечно.
// РЕШЕНИЕ: читаем stdout/stderr в отдельных потоках ПАРАЛЛЕЛЬНО с waitUntilExit().
//
// ИСПРАВЛЕНИЕ SWIFT 6 CONCURRENCY (2025-07-11):
// ПРОБЛЕМА: var stdoutData/stderrData захватывались в @Sendable-замыкания разных
// потоков → "Mutation of captured var in concurrently-executing code".
// РЕШЕНИЕ: Используем класс DataBox (@unchecked Sendable) с NSLock.
// Замыкания захватывают ССЫЛКУ на объект (разрешено), а не мутируют var.
//
// ТАЙМАУТ ПРОЦЕССОВ:
// xcodebuild иногда зависает (особенно на macOS 26 beta).
// Используем DispatchWorkItem + process.terminate() для принудительного
// завершения через kBuildTimeoutSeconds секунд.

import Foundation

/// Максимальное время ожидания сборки/тестов в секундах.
/// 5 минут — достаточно для любой реальной сборки. Если дольше — значит завис.
private let kBuildTimeoutSeconds: Double = 300

// MARK: - Вспомогательный потокобезопасный контейнер данных

/// Потокобезопасная обёртка для накопления Data из параллельных потоков.
///
/// ЗАЧЕМ НУЖЕН ЭТОТ КЛАСС:
/// В Swift 6 нельзя мутировать `var` переменные, захваченные в @Sendable-замыкания
/// нескольких параллельных DispatchQueue. Компилятор выдаёт ошибку:
/// "Mutation of captured var in concurrently-executing code".
///
/// Решение: используем reference type (class) с NSLock для синхронизации.
/// Замыкания захватывают ССЫЛКУ на объект (это разрешено), а не мутируют var.
/// NSLock гарантирует что только один поток в момент времени пишет в data.
private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    /// Заменяет накопленные данные новыми (вызывается из параллельного потока).
    func set(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        data = newData
    }

    /// Возвращает накопленные данные (вызывается после завершения всех потоков).
    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

// MARK: - BuildTools

/// Инструменты сборки и тестирования проекта.
final class BuildTools: Sendable {
    /// Путь к корню проекта (где лежит Chappie.xcodeproj).
    private let projectPath: String

    /// Путь к файлу последнего лога сборки.
    /// Зачем файл: ИИ может прочитать его отдельным вызовом read_build_log,
    /// не получая весь лог в ответе на build_project.
    private var buildLogPath: String {
        projectPath + "/.build_log.txt"
    }

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    // MARK: - Публичные инструменты

    /// Собирает Chappie.xcodeproj схему Chappie.
    /// Возвращает краткий отчёт: успех или список ошибок.
    func build() async -> ToolResult {
        print("[ChappieMCP] 🔨 Запуск сборки проекта...")

        let args = [
            "-project", "Chappie.xcodeproj",
            "-scheme", "Chappie",
            "-configuration", "Debug",
            // "Any Mac" — универсальный destination, работает на x86_64 и arm64.
            // Явное указание arch=arm64 ломается на Intel-машинах.
            "-destination", "platform=macOS,name=Any Mac",
            "build"
        ]

        return await runXcodebuild(args: args, label: "build_project")
    }

    /// Запускает тесты через xcodebuild с правильной схемой.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (2025-07-10):
    /// ChappieCoreTests — это Xcode Unit Test Bundle, НЕ SPM testTarget.
    /// Поэтому для запуска тестов используем схему "ChappieCoreTests" в xcodebuild.
    ///
    /// DESTINATION (2025-07-11):
    /// "platform=macOS,name=Any Mac" — универсальный destination без явного arch.
    /// Работает на x86_64 и arm64. Явное arch=arm64 ломается на Intel-машинах.
    ///
    /// - Parameter target: имя тест-таргета (например "ChappieCoreTests").
    ///   nil = запускает все тесты через схему ChappieCoreTests.
    func runTests(target: String?) async -> ToolResult {
        print("[ChappieMCP] 🧪 Запуск тестов через xcodebuild схему ChappieCoreTests...")

        var args = [
            "-project", "Chappie.xcodeproj",
            "-scheme", "ChappieCoreTests",
            // Универсальный destination — не зависит от архитектуры машины
            "-destination", "platform=macOS,name=Any Mac",
            "test"
        ]

        // Если передан конкретный таргет — ограничиваем тесты только им.
        if let target, !target.isEmpty {
            args.append(contentsOf: ["-only-testing", target])
        }

        return await runXcodebuild(args: args, label: "run_tests")
    }

    /// Читает последний сохранённый лог сборки.
    func readLastLog() async -> ToolResult {
        let logURL = URL(fileURLWithPath: buildLogPath)
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return .failure("Лог сборки не найден. Сначала запустите build_project или run_tests.")
        }
        return .success(content)
    }

    // MARK: - Приватные методы

    /// Запускает xcodebuild с переданными аргументами.
    private func runXcodebuild(args: [String], label: String) async -> ToolResult {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(
                    executable: "/usr/bin/xcodebuild",
                    args: args,
                    workingDirectory: self.projectPath,
                    label: label
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Синхронно запускает процесс с таймаутом, сохраняет лог и возвращает краткий результат.
    ///
    /// КЛЮЧЕВОЕ РЕШЕНИЕ — ЧТЕНИЕ PIPE В ПАРАЛЛЕЛЬНЫХ ПОТОКАХ:
    /// Нельзя вызывать readDataToEndOfFile() ПОСЛЕ waitUntilExit().
    /// Если процесс пишет в Pipe больше ~64KB, он блокируется в ожидании чтения.
    /// waitUntilExit() ждёт завершения процесса. Оба ждут друг друга — дедлок.
    ///
    /// Правильный паттерн:
    /// 1. Создаём DataBox (потокобезопасный контейнер) для stdout и stderr
    /// 2. Запускаем чтение в отдельных DispatchQueue через DataBox.set()
    /// 3. Вызываем waitUntilExit() — он ждёт завершения
    /// 4. Ждём завершения чтения через DispatchGroup
    /// 5. Читаем результат через DataBox.get()
    ///
    /// ТАЙМАУТ: DispatchWorkItem с process.terminate() через kBuildTimeoutSeconds.
    private func runProcess(
        executable: String,
        args: [String],
        workingDirectory: String,
        label: String
    ) -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin/swift",
            "LANG": "en_US.UTF-8",
            "NSUnbufferedIO": "YES"
        ]

        let startTime = Date()

        // --- ЗАЩИТА ОТ ЗАВИСАНИЯ ---
        // DispatchWorkItem убьёт процесс по таймауту если xcodebuild завис.
        var timedOut = false
        let killWorkItem = DispatchWorkItem {
            if process.isRunning {
                print("[ChappieMCP] ⏱️ Таймаут \(label) (\(Int(kBuildTimeoutSeconds))с) — завершаем процесс")
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + kBuildTimeoutSeconds,
            execute: killWorkItem
        )
        // --- КОНЕЦ ЗАЩИТЫ ОТ ЗАВИСАНИЯ ---

        // --- ПАРАЛЛЕЛЬНОЕ ЧТЕНИЕ PIPE (ИСПРАВЛЕНИЕ ДЕДЛОКА) ---
        // DataBox — reference type с NSLock, безопасен для захвата в @Sendable-замыкания.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        // --- КОНЕЦ ПАРАЛЛЕЛЬНОГО ЧТЕНИЯ ---

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            killWorkItem.cancel()
            return .failure("Не удалось запустить \(executable): \(error.localizedDescription)")
        }

        // Отменяем таймер если процесс завершился сам
        killWorkItem.cancel()

        // Ждём завершения чтения из Pipe (обычно уже завершено к этому моменту)
        readGroup.wait()

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

        if timedOut {
            let msg = "⏱️ \(label) завис и был принудительно остановлен через \(Int(kBuildTimeoutSeconds)) секунд.\n" +
                      "Попробуй ещё раз или проверь Xcode вручную."
            saveLog(msg, args: args)
            return .failure(msg)
        }

        let stdout = String(data: stdoutBox.get(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.get(), encoding: .utf8) ?? ""
        let fullOutput = stdout + (stderr.isEmpty ? "" : "\n--- STDERR ---\n" + stderr)

        saveLog(fullOutput, args: args)

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            let summary = extractSummary(from: fullOutput, success: true)
            return .success("✅ Успех (\(elapsed)с)\n\(summary)\n\nПолный лог: read_build_log")
        } else {
            let errors = extractErrors(from: fullOutput)
            return .failure("❌ Сборка упала (код \(exitCode), \(elapsed)с)\n\n\(errors)\n\nПолный лог: read_build_log")
        }
    }

    /// Сохраняет полный вывод в лог-файл.
    private func saveLog(_ output: String, args: [String]) {
        let header = """
        === ChappieMCP Build Log ===
        Команда: \(args.joined(separator: " "))
        Время: \(Date())
        ============================

        """
        let content = header + output
        try? content.write(toFile: buildLogPath, atomically: true, encoding: .utf8)
    }

    /// Извлекает краткое резюме из вывода xcodebuild (строки со статистикой).
    private func extractSummary(from output: String, success: Bool) -> String {
        let lines = output.components(separatedBy: "\n")

        let summaryLines = lines.filter { line in
            line.contains("BUILD SUCCEEDED") ||
            line.contains("BUILD FAILED") ||
            line.contains("TEST SUCCEEDED") ||
            line.contains("TEST FAILED") ||
            line.contains("warning:") ||
            line.contains("Executed") // статистика тестов: "Executed 5 tests"
        }

        if summaryLines.isEmpty {
            return success ? "Сборка завершена без предупреждений" : "Нет деталей"
        }

        return summaryLines.prefix(20).joined(separator: "\n")
    }

    /// Извлекает строки с ошибками из вывода xcodebuild.
    ///
    /// Зачем фильтровать: полный вывод xcodebuild может быть 1000+ строк,
    /// большинство из которых — информационные. ИИ нужны только ошибки.
    private func extractErrors(from output: String) -> String {
        let lines = output.components(separatedBy: "\n")

        let errorLines = lines.filter { line in
            line.contains("error:") ||
            line.contains("Error:") ||
            line.contains("BUILD FAILED") ||
            line.contains("FAILED") ||
            line.contains("warning:") ||
            (line.contains(".swift:") && line.contains(": error:"))
        }

        if errorLines.isEmpty {
            let lastLines = lines.suffix(30).joined(separator: "\n")
            return "Детали ошибки:\n\(lastLines)"
        }

        return errorLines.prefix(50).joined(separator: "\n")
    }
}
