// MCPHTTPServer.swift
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Реализует сервер на основе Unix Domain Socket (UDS).
//
// ПОЧЕМУ Unix Domain Socket, А НЕ TCP:
// ChappieMCP запускается как дочерний процесс из Chappie.app, который работает
// в App Sandbox. Дочерний процесс наследует sandbox родителя, и sandbox
// блокирует открытие серверных TCP-сокетов (POSIX error 1: Operation not permitted).
// Unix Domain Socket работает через файловую систему (файл в /tmp/),
// sandbox его разрешает без дополнительных entitlements.
//
// ДОПОЛНИТЕЛЬНЫЕ ПРЕИМУЩЕСТВА UDS:
// - Быстрее TCP (нет сетевого стека, копирование в памяти)
// - Безопаснее (доступен только локально, не виден снаружи машины)
// - Не требует свободного порта
//
// ПУТЬ СОКЕТА:
// /tmp/com.chappie.mcp.sock — фиксированный путь, известный и серверу и клиенту.
//
// ПРОТОКОЛ (length-prefixed framing):
// Запрос:  4 байта (UInt32 big-endian, длина JSON) + JSON-тело MCPRequest
// Ответ:   4 байта (UInt32 big-endian, длина JSON) + JSON-тело MCPResponse
// Это надёжнее HTTP parsing — нет проблем с заголовками и chunked encoding.

import Foundation

// MARK: - Константы

/// Путь к файлу Unix Domain Socket.
/// Зачем /tmp: стандартная директория для временных файлов процессов,
/// доступна всем пользователям, не требует специальных прав.
let kMCPSocketPath = "/tmp/com.chappie.mcp.sock"

// MARK: - Модели запроса/ответа

/// Запрос к MCP-серверу.
struct MCPRequest: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

/// Ответ MCP-сервера.
struct MCPResponse: Codable, Sendable {
    let result: String?
    let error: String?
}

// MARK: - MCPUnixServer

/// Сервер на Unix Domain Socket для MCP инструментов.
///
/// Зачем @unchecked Sendable: содержит Int32 file descriptor,
/// но мы гарантируем безопасность — fd используется только внутри acceptLoop
/// на одном потоке DispatchQueue.
final class MCPUnixServer: @unchecked Sendable {

    private let socketPath: String
    private let projectPath: String

    /// Диспетчер инструментов — маршрутизирует вызовы к нужным классам.
    private let toolDispatcher: ToolDispatcher

    init(socketPath: String = kMCPSocketPath, projectPath: String) {
        self.socketPath = socketPath
        self.projectPath = projectPath
        self.toolDispatcher = ToolDispatcher(projectPath: projectPath)
    }

    /// Запускает POSIX Unix Domain Socket сервер.
    ///
    /// Удаляет старый файл сокета (если остался от предыдущего запуска),
    /// создаёт новый, начинает принимать соединения в фоновом потоке.
    func start() throws {
        // Удаляем старый файл сокета — иначе bind упадёт с "Address already in use".
        // Это нормальная практика для Unix socket серверов при старте.
        try? FileManager.default.removeItem(atPath: socketPath)

        // Создаём Unix Domain Socket
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw MCPServerError.socketCreationFailed(String(cString: strerror(errno)))
        }

        // Разрешаем повторное использование адреса — на случай быстрого перезапуска
        var reuseAddr: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Формируем адрес Unix socket
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Копируем путь в sun_path (буфер 104 байта на macOS)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { charPtr in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(charPtr, src.baseAddress!, min(src.count, 104))
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Привязываем сокет к пути в файловой системе
        let bindResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw MCPServerError.bindFailed(String(cString: strerror(errno)))
        }

        // Начинаем слушать входящие соединения (backlog = 128)
        guard listen(serverFD, 128) == 0 else {
            throw MCPServerError.listenFailed(String(cString: strerror(errno)))
        }

        print("[ChappieMCP] 🟢 Unix socket готов: \(socketPath)")

        // Принимаем соединения в фоновом потоке, не блокируя main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.acceptLoop(serverFD: serverFD)
        }
    }

    // MARK: - Accept Loop

    /// Основной цикл принятия входящих соединений.
    /// Работает бесконечно на фоновом потоке DispatchQueue.
    private func acceptLoop(serverFD: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            // accept() блокирует поток до появления нового соединения
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                print("[ChappieMCP] ⚠️ accept() ошибка: \(String(cString: strerror(errno)))")
                continue
            }

            // Каждое соединение обрабатываем в отдельной Task Swift Concurrency,
            // чтобы не блокировать accept loop при долгих операциях (xcodebuild).
            Task { [weak self] in
                guard let self else { return }
                await self.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handler

    /// Обрабатывает одно клиентское соединение.
    ///
    /// Протокол (length-prefixed framing):
    /// - Читаем 4 байта (UInt32 big-endian) = длина JSON запроса
    /// - Читаем N байт JSON
    /// - Выполняем инструмент
    /// - Отправляем 4 байта длины + JSON ответа
    private func handleClient(fd: Int32) async {
        defer { close(fd) } // Закрываем соединение в любом случае

        // Читаем 4 байта длины запроса
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let bytesRead = recv(fd, &lengthBytes, 4, MSG_WAITALL)
        guard bytesRead == 4 else {
            print("[ChappieMCP] ⚠️ Не удалось прочитать длину сообщения (прочитано: \(bytesRead))")
            return
        }

        // Декодируем длину (big-endian UInt32)
        let length = UInt32(lengthBytes[0]) << 24
                   | UInt32(lengthBytes[1]) << 16
                   | UInt32(lengthBytes[2]) << 8
                   | UInt32(lengthBytes[3])

        // Защита от слишком больших или нулевых запросов
        guard length > 0, length < 10_000_000 else {
            print("[ChappieMCP] ⚠️ Неверная длина сообщения: \(length)")
            return
        }

        // Читаем JSON-тело запроса
        var jsonBytes = [UInt8](repeating: 0, count: Int(length))
        let jsonRead = recv(fd, &jsonBytes, Int(length), MSG_WAITALL)
        guard jsonRead == Int(length) else {
            print("[ChappieMCP] ⚠️ Неполное чтение JSON (ожидалось \(length), прочитано \(jsonRead))")
            return
        }

        // Обрабатываем запрос и получаем ответ
        let requestData = Data(jsonBytes)
        let responseData = await processRequest(data: requestData)

        // Отправляем ответ: 4 байта длины (big-endian) + JSON тело
        let responseLength = UInt32(responseData.count)
        var responseHeader = [UInt8](repeating: 0, count: 4)
        responseHeader[0] = UInt8((responseLength >> 24) & 0xFF)
        responseHeader[1] = UInt8((responseLength >> 16) & 0xFF)
        responseHeader[2] = UInt8((responseLength >> 8) & 0xFF)
        responseHeader[3] = UInt8(responseLength & 0xFF)

        _ = responseHeader.withUnsafeBytes { send(fd, $0.baseAddress!, 4, 0) }
        _ = responseData.withUnsafeBytes { send(fd, $0.baseAddress!, responseData.count, 0) }
    }

    // MARK: - Request Processing

    /// Декодирует JSON-запрос и выполняет инструмент через ToolDispatcher.
    private func processRequest(data: Data) async -> Data {
        guard let request = try? JSONDecoder().decode(MCPRequest.self, from: data) else {
            let response = MCPResponse(result: nil, error: "Неверный JSON запрос")
            return (try? JSONEncoder().encode(response)) ?? Data()
        }

        print("[ChappieMCP] 🔧 Инструмент: \(request.tool) | Аргументы: \(request.args)")

        let toolResult = await toolDispatcher.execute(tool: request.tool, args: request.args)
        let response = MCPResponse(result: toolResult.value, error: toolResult.error)
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
}

// MARK: - MCPServerError

/// Ошибки запуска Unix Domain Socket сервера.
enum MCPServerError: Error, CustomStringConvertible {
    case socketCreationFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    var description: String {
        switch self {
        case .socketCreationFailed(let msg): return "Не удалось создать сокет: \(msg)"
        case .bindFailed(let msg):           return "bind() упал: \(msg)"
        case .listenFailed(let msg):         return "listen() упал: \(msg)"
        }
    }
}

// MARK: - ToolResult

/// Результат выполнения инструмента.
/// Зачем отдельная структура: чисто разделяет успех и ошибку
/// без throws через async-границы диспетчера.
struct ToolResult: Sendable {
    let value: String?
    let error: String?

    static func success(_ value: String) -> ToolResult {
        ToolResult(value: value, error: nil)
    }

    static func failure(_ error: String) -> ToolResult {
        ToolResult(value: nil, error: error)
    }
}

// MARK: - ToolDispatcher

/// Диспетчер инструментов — маршрутизирует вызовы к нужным классам.
///
/// Зачем отдельный класс: изолирует логику роутинга от сервера.
/// Добавление нового инструмента = один case в switch.
final class ToolDispatcher: Sendable {
    private let gitTools: GitTools
    private let buildTools: BuildTools

    init(projectPath: String) {
        self.gitTools = GitTools(projectPath: projectPath)
        self.buildTools = BuildTools(projectPath: projectPath)
    }

    func execute(tool: String, args: [String: String]) async -> ToolResult {
        switch tool {
        // Git инструменты
        case "git_status":
            return await gitTools.status()
        case "git_diff":
            let staged = args["staged"] == "true"
            return await gitTools.diff(staged: staged)
        case "git_add":
            let paths = args["paths"] ?? "."
            return await gitTools.add(paths: paths)
        case "git_commit":
            guard let message = args["message"], !message.isEmpty else {
                return .failure("Аргумент 'message' обязателен для git_commit")
            }
            return await gitTools.commit(message: message)
        case "git_log":
            let count = Int(args["count"] ?? "10") ?? 10
            return await gitTools.log(count: count)
        case "git_reset":
            return await gitTools.reset()

        // Build инструменты
        case "build_project":
            return await buildTools.build()
        case "run_tests":
            let testTarget = args["target"]
            return await buildTools.runTests(target: testTarget)
        case "read_build_log":
            return await buildTools.readLastLog()

        default:
            return .failure("Неизвестный инструмент: \(tool). Доступные: git_status, git_diff, git_add, git_commit, git_log, git_reset, build_project, run_tests, read_build_log")
        }
    }
}
