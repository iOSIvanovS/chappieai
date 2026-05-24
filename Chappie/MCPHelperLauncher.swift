// MCPHelperLauncher.swift
// Chappie
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Управляет жизненным циклом дочернего процесса ChappieMCP.
//
// АРХИТЕКТУРА ПЕРЕДАЧИ ПУТИ К СОКЕТУ:
// Сокет кладётся в /tmp/ — это стандартный путь, доступный всем процессам
// без sandbox-ограничений (sandbox удалён из проекта).
// Путь вычисляется один раз в init() и хранится в константе.
//
// ПОЧЕМУ ПЕРЕДАЁМ ПУТЬ ЧЕРЕЗ АРГУМЕНТ, А НЕ ХАРДКОДИМ В ХЕЛПЕРЕ:
// Родитель (Chappie.app) является единственным источником истины о пути сокета.
// Хелпер не должен самостоятельно принимать решение о пути — это упрощает
// диагностику и позволяет менять путь централизованно.
//
// LIFECYCLE:
// 1. ChappieApp.onAppear → MCPHelperLauncher.shared.launch(workspacePath:)
// 2. Лаунчер берёт socketPath (вычислен в init)
// 3. Запускает Process с аргументами: [workspacePath, socketPath]
// 4. MCPToolBridge использует тот же socketPath для подключения
// 5. При завершении Chappie.app → terminateHelper() убивает дочерний процесс
//
// ПОЧЕМУ @Observable, А НЕ ObservableObject:
// В Swift 6 / macOS 26 предпочтительна макро-система @Observable из Observation.
// Она не требует Combine и работает нативно с @MainActor без предупреждений.
//
// ВАЖНО — lazy vs init():
// @Observable макрос генерирует обёртки для каждого хранимого свойства.
// Ключевое слово lazy несовместимо с этой генерацией — компилятор падает
// с ошибкой "init accessor cannot refer to property '_socketPath'".
// Поэтому socketPath вычисляется в init() и хранится как обычное var.

import Foundation
import AppKit
import Observation

/// Синглтон для управления дочерним процессом ChappieMCP.
///
/// Зачем @MainActor: все операции с Process и состоянием лаунчера
/// должны происходить на главном потоке, чтобы избежать гонок данных.
@MainActor
@Observable
final class MCPHelperLauncher {

    // MARK: - Singleton

    static let shared = MCPHelperLauncher()

    // MARK: - Состояние

    /// Текущий статус хелпера — для отображения в UI.
    var status: HelperStatus = .notStarted

    /// Путь к Unix Domain Socket.
    ///
    /// ПОЧЕМУ НЕ lazy: @Observable макрос несовместим с lazy — он генерирует
    /// init accessor, который не может обращаться к backing storage (_socketPath).
    /// Вычисляем путь в init() и сохраняем как обычное свойство.
    ///
    /// ПУТЬ /tmp/: sandbox удалён из проекта, поэтому /tmp/ доступен.
    private(set) var socketPath: String = ""

    /// Дочерний процесс ChappieMCP.
    private var helperProcess: Process?

    /// Путь к воркспейсу, с которым был запущен хелпер.
    private var currentWorkspacePath: String?

    // MARK: - Инициализация

    private init() {
        // Вычисляем путь к сокету один раз при инициализации синглтона.
        // Используем /tmp/ — стандартное место для Unix Domain Sockets на macOS.
        // Имя файла включает bundle identifier для уникальности.
        socketPath = "/tmp/com.chappie.mcp.sock"
    }

    // MARK: - Публичный интерфейс

    /// Запускает хелпер ChappieMCP с указанным путём воркспейса.
    ///
    /// БЕЗОПАСНОСТЬ ОТ ДВОЙНОГО ЗАПУСКА:
    /// Если хелпер уже запущен с тем же путём — ничего не делаем.
    /// Если путь изменился — перезапускаем.
    ///
    /// - Parameter workspacePath: Путь к папке проекта. Передаётся хелперу
    ///   как argv[1] — он использует его как рабочий каталог для git/build команд.
    func launch(workspacePath: String? = nil) {
        let path = workspacePath ?? FileManager.default.currentDirectoryPath

        // Если хелпер уже запущен с тем же путём — не трогаем
        if let process = helperProcess, process.isRunning, currentWorkspacePath == path {
            print("[MCPHelperLauncher] ℹ️ Хелпер уже запущен для: \(path)")
            return
        }

        // Если запущен с другим путём — останавливаем и перезапускаем
        if let process = helperProcess, process.isRunning {
            print("[MCPHelperLauncher] 🔄 Перезапуск хелпера для нового воркспейса: \(path)")
            process.terminate()
            helperProcess = nil
        }

        startHelper(workspacePath: path)
    }

    /// Перезапускает хелпер с новым путём воркспейса.
    /// Вызывается из ChappieViewModel.setWorkspace() при смене проекта.
    func restartWithWorkspace(_ url: URL) {
        launch(workspacePath: url.path)
    }

    /// Завершает дочерний процесс.
    /// Вызывается из ChappieApp при завершении приложения.
    func terminateHelper() {
        guard let process = helperProcess, process.isRunning else { return }
        print("[MCPHelperLauncher] 🛑 Завершение хелпера ChappieMCP")
        process.terminate()
        helperProcess = nil
        status = .stopped

        // Удаляем файл сокета при завершении — чистим за собой
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - Приватная логика запуска

    /// Находит бинарник в bundle и запускает его как дочерний процесс.
    private func startHelper(workspacePath: String) {
        // Ищем бинарник ChappieMCP в стандартной папке Helpers внутри .app bundle.
        // forAuxiliaryExecutable ищет в Contents/MacOS/ и Contents/Helpers/.
        guard let helperURL = Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP") else {
            // Fallback: ищем вручную в Contents/Helpers/
            let fallbackURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents")
                .appendingPathComponent("Helpers")
                .appendingPathComponent("ChappieMCP")

            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                startProcess(at: fallbackURL, workspacePath: workspacePath)
            } else {
                print("[MCPHelperLauncher] ❌ Бинарник ChappieMCP не найден в bundle!")
                print("[MCPHelperLauncher] ℹ️ Ожидаемый путь: \(fallbackURL.path)")
                print("[MCPHelperLauncher] ℹ️ Добавьте ChappieMCP в Copy Files Build Phase → Helpers")
                status = .failed("Бинарник не найден в bundle")
            }
            return
        }

        startProcess(at: helperURL, workspacePath: workspacePath)
    }

    /// Создаёт и запускает Process для хелпера.
    private func startProcess(at url: URL, workspacePath: String) {
        let process = Process()
        process.executableURL = url

        // Передаём два аргумента:
        // argv[1] = путь к воркспейсу (рабочий каталог для git/build)
        // argv[2] = путь к Unix Domain Socket
        //
        // Зачем передавать socketPath через аргумент:
        // Родитель является единственным источником истины о пути сокета.
        // Хелпер не принимает самостоятельных решений о расположении файлов.
        process.arguments = [workspacePath, socketPath]

        // Пробрасываем стандартные потоки вывода — логи хелпера видны в консоли Xcode.
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        // Обработчик завершения процесса.
        // Зачем Task { @MainActor in }: terminationHandler вызывается на фоновом потоке,
        // но мы обновляем свойства @Observable — нужен главный поток.
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = terminatedProcess.terminationStatus
                print("[MCPHelperLauncher] ⚠️ Хелпер завершился с кодом: \(code)")

                // Код 15 = SIGTERM — мы сами завершили процесс, это нормально.
                if code != 15 {
                    self.status = .crashed(code: Int(code))
                    self.helperProcess = nil
                }
            }
        }

        do {
            try process.run()
            helperProcess = process
            currentWorkspacePath = workspacePath
            status = .running
            print("[MCPHelperLauncher] ✅ Хелпер ChappieMCP запущен (PID: \(process.processIdentifier))")
            print("[MCPHelperLauncher] 📁 Воркспейс: \(workspacePath)")
            print("[MCPHelperLauncher] 🔌 Сокет: \(socketPath)")
        } catch {
            print("[MCPHelperLauncher] ❌ Не удалось запустить хелпер: \(error)")
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - HelperStatus

/// Статус жизненного цикла хелпера.
///
/// Зачем enum вместо Bool: позволяет передавать детали ошибки в UI
/// без дополнительных свойств.
enum HelperStatus: Equatable {
    case notStarted
    case running
    case stopped
    case failed(String)
    case crashed(code: Int)

    var description: String {
        switch self {
        case .notStarted:        return "Не запущен"
        case .running:           return "Работает"
        case .stopped:           return "Остановлен"
        case .failed(let msg):   return "Ошибка: \(msg)"
        case .crashed(let code): return "Упал (код \(code))"
        }
    }
}
