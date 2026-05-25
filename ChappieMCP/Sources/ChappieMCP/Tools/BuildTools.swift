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
// ТАЙМАУТ ПРОЦЕССОВ:
// xcodebuild иногда зависает (особенно на macOS 26 beta).
// Используем DispatchWorkItem + process.terminate() для принудительного
// завершения через kBuildTimeoutSeconds секунд.
// Это гарантирует что build_project/run_tests ВСЕГДА вернут результат.
//
// ФОРМАТ ВЫВОДА:
// xcodebuild генерирует очень многословный вывод. Мы фильтруем его через
// xcpretty (если установлен) или выбираем только строки с ошибками/предупреждениями.

import Foundation

/// Максимальное время ожидания сборки/тестов в секундах.
/// 5 минут — достаточно для любой реальной сборки. Если дольше — значит завис.
private let kBuildTimeoutSeconds: Double = 300

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
            // Явно указываем destination чтобы xcodebuild не спрашивал и не зависал
            "-destination", "platform=macOS,arch=arm64",
            "build"
        ]

        return await runXcodebuild(args: args, label: "build_project")
    }

    /// Запускает тесты через xcodebuild с правильной схемой.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (2025-07-10):
    /// ChappieCoreTests — это Xcode Unit Test Bundle, НЕ SPM testTarget.
    /// Поэтому для запуска тестов используем схему "ChappieCoreTests" в xcodebuild.
    /// Старый подход (swift test --package-path ChappieCore) был ошибочным —
    /// он искал testTarget в Package.swift, которого там нет.
    ///
    /// DESTINATION (2025-07-11):
    /// "platform=macOS,arch=arm64" — явный destination без симулятора.
    /// Без явного arch xcodebuild на macOS 26 beta может зависнуть на выборе устройства.
    ///
    /// - Parameter target: имя тест-таргета (например "ChappieCoreTests").
    ///   nil = запускает все тесты через схему ChappieCoreTests.
    func runTests(target: String?) async -> ToolResult {
        print("[ChappieMCP] 🧪 Запуск тестов через xcodebuild схему ChappieCoreTests...")

        // Всегда используем схему ChappieCoreTests — она единственная тестовая схема.
        // Если в будущем появятся другие тестовые таргеты, добавить маппинг здесь.
        var args = [
            "-project", "Chappie.xcodeproj",
            "-scheme", "ChappieCoreTests",
            // Явный destination — критично для macOS 26 beta, иначе xcodebuild зависает
            // выбирая между устройствами. arm64 = нативный Mac без симулятора.
            "-destination", "platform=macOS,arch=arm64",
            "test"
        ]

        // Если передан конкретный таргет — ограничиваем тесты только им.
        // Формат: "ChappieCoreTests/ClassName/methodName" или просто "ChappieCoreTests"
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
    ///
    /// Зачем label: для понятного сообщения при таймауте.
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
    /// ТАЙМАУТ: Используем DispatchWorkItem для принудительного terminate() процесса.
    /// Это решает проблему зависания xcodebuild на macOS 26 beta.
    /// Без таймаута process.waitUntilExit() ждёт вечно — ИИ-агент зависает.
    ///
    /// Зачем сохранять полный лог в файл:
    /// xcodebuild может выводить тысячи строк. В ответе на инструмент
    /// возвращаем только краткое резюме (ошибки/предупреждения),
    /// а полный лог доступен через read_build_log.
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
            // Отключаем интерактивный вывод xcodebuild
            "NSUnbufferedIO": "YES"
        ]

        let startTime = Date()

        // --- ЗАЩИТА ОТ ЗАВИСАНИЯ ---
        // Создаём DispatchWorkItem который убьёт процесс по таймауту.
        // Это единственный надёжный способ: process.waitUntilExit() сам по себе
        // не имеет таймаута и блокирует поток навсегда при зависании xcodebuild.
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

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            killWorkItem.cancel()
            return .failure("Не удалось запустить \(executable): \(error.localizedDescription)")
        }

        // Отменяем таймер если процесс завершился сам
        killWorkItem.cancel()

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

        // Если сработал таймаут — возвращаем понятное сообщение
        if timedOut {
            let msg = "⏱️ \(label) завис и был принудительно остановлен через \(Int(kBuildTimeoutSeconds)) секунд.\n" +
                      "Попробуй ещё раз или проверь Xcode вручную."
            saveLog(msg, args: args)
            return .failure(msg)
        }

        // Читаем полный вывод
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let fullOutput = stdout + (stderr.isEmpty ? "" : "\n--- STDERR ---\n" + stderr)

        // Сохраняем полный лог в файл
        saveLog(fullOutput, args: args)

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            // Успех — возвращаем краткое резюме
            let summary = extractSummary(from: fullOutput, success: true)
            return .success("✅ Успех (\(elapsed)с)\n\(summary)\n\nПолный лог: read_build_log")
        } else {
            // Ошибка — возвращаем только строки с ошибками
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

    /// Извлекает краткое резюме из вывода xcodebuild (последние строки со статистикой).
    private func extractSummary(from output: String, success: Bool) -> String {
        let lines = output.components(separatedBy: "\n")

        // Ищем строки с ** BUILD SUCCEEDED ** или статистикой тестов
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

        // Возвращаем не более 20 строк чтобы не перегружать контекст
        return summaryLines.prefix(20).joined(separator: "\n")
    }

    /// Извлекает строки с ошибками из вывода xcodebuild.
    ///
    /// Зачем фильтровать: полный вывод xcodebuild может быть 1000+ строк,
    /// большинство из которых — информационные. ИИ нужны только ошибки.
    private func extractErrors(from output: String) -> String {
        let lines = output.components(separatedBy: "\n")

        // Фильтруем строки содержащие ключевые слова ошибок
        let errorLines = lines.filter { line in
            line.contains("error:") ||
            line.contains("Error:") ||
            line.contains("BUILD FAILED") ||
            line.contains("FAILED") ||
            line.contains("warning:") ||
            // Строки вида "file.swift:42:13: error: ..."
            (line.contains(".swift:") && line.contains(": error:"))
        }

        if errorLines.isEmpty {
            // Если фильтр ничего не нашёл — возвращаем последние 30 строк
            let lastLines = lines.suffix(30).joined(separator: "\n")
            return "Детали ошибки:\n\(lastLines)"
        }

        // Ограничиваем до 50 строк ошибок
        return errorLines.prefix(50).joined(separator: "\n")
    }
}
