// main.swift — точка входа ChappieMCP
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Запускает Unix Domain Socket сервер и держит процесс живым.
//
// КЛЮЧЕВОЕ АРХИТЕКТУРНОЕ РЕШЕНИЕ — ПУТЬ СОКЕТА:
// App Sandbox блокирует bind() на /tmp/ для дочерних процессов.
// Родительский процесс (Chappie.app) вычисляет путь к сокету внутри
// своего sandbox-контейнера через FileManager.default.temporaryDirectory
// и передаёт его сюда как argv[2].
//
// Это единственный надёжный способ: дочерний процесс наследует sandbox
// родителя, но FileManager в дочернем процессе может вернуть другой путь.
// Явная передача через аргументы — детерминированное решение.
//
// АРГУМЕНТЫ КОМАНДНОЙ СТРОКИ:
// argv[0] = путь к бинарнику (автоматически)
// argv[1] = путь к воркспейсу (рабочий каталог для git/build)
// argv[2] = путь к Unix Domain Socket файлу
//
// ЗАПУСК ВРУЧНУЮ (для отладки):
//   .build/debug/ChappieMCP /путь/к/проекту /tmp/com.chappie.mcp.sock

import Foundation

// MARK: - Разбор аргументов командной строки

/// Путь к проекту — рабочий каталог для git и xcodebuild команд.
let projectPath: String = {
    let args = CommandLine.arguments
    if args.count > 1 {
        return args[1]
    }
    return FileManager.default.currentDirectoryPath
}()

/// Путь к Unix Domain Socket файлу.
///
/// Зачем читаем из argv[2]:
/// Родительский процесс (Chappie.app) работает в App Sandbox и знает путь
/// к своей временной директории. Он передаёт его сюда явно, чтобы
/// дочерний процесс создал сокет именно там — где sandbox разрешает bind().
let socketPath: String = {
    let args = CommandLine.arguments
    if args.count > 2 {
        return args[2]
    }
    // Fallback для ручного запуска вне sandbox: используем /tmp/
    return "/tmp/com.chappie.mcp.sock"
}()

// MARK: - Запуск сервера

print("[ChappieMCP] 🚀 Запуск сервера (Unix Domain Socket)")
print("[ChappieMCP] 📁 Рабочий каталог: \(projectPath)")
print("[ChappieMCP] 🔌 Сокет: \(socketPath)")

// Создаём и запускаем Unix socket сервер с путём, полученным от родителя
let server = MCPUnixServer(socketPath: socketPath, projectPath: projectPath)

do {
    try server.start()
    print("[ChappieMCP] ✅ Сервер запущен. Жду запросов...")
} catch {
    print("[ChappieMCP] ❌ Не удалось запустить сервер: \(error)")
    exit(1)
}

// Держим процесс живым — сервер работает в фоновом потоке через DispatchQueue.
// RunLoop.main.run() блокирует главный поток навсегда,
// пока процесс не получит SIGTERM (от MCPHelperLauncher.terminateHelper).
RunLoop.main.run()
