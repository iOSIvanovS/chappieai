// MCPToolBridge.swift
// ChappieCore
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Клиент для общения с ChappieMCP сервером через Unix Domain Socket.
// Переводит вызовы инструментов ИИ в запросы к хелперу и возвращает результаты.
//
// ПОЧЕМУ Unix Domain Socket, А НЕ HTTP/TCP:
// Chappie.app работает в App Sandbox. TCP к localhost разрешён для КЛИЕНТА,
// но ChappieMCP (дочерний процесс) не может открыть TCP СЕРВЕР из-за sandbox.
//
// ПОЧЕМУ НЕ /tmp/ А SANDBOX TEMP DIRECTORY:
// App Sandbox блокирует bind() на /tmp/ для дочерних процессов.
// Правильный путь — FileManager.default.temporaryDirectory, который возвращает
// путь ВНУТРИ sandbox-контейнера (/var/folders/.../T/), где bind() разрешён.
// MCPHelperLauncher в Chappie.app вычисляет этот путь и передаёт его сюда
// через ToolExecutionService.init(socketPath:).
//
// ПРОТОКОЛ:
// Length-prefixed framing: 4 байта (UInt32 big-endian) = длина JSON, затем JSON-тело.
// Это надёжнее чем HTTP parsing — нет проблем с chunked encoding и заголовками.
//
// ПОЧЕМУ НЕТ ОТДЕЛЬНОЙ КОНСТАНТЫ kSocketPath:
// ChappieCore — публичный Swift Package. Default argument в public init
// обязан быть доступен в контексте вызывающего кода (т.е. быть public).
// Вместо того чтобы делать константу public (и засорять публичный API),
// путь вынесен прямо в default argument — это идиоматично для Swift.

import Foundation

// MARK: - MCPToolBridge

/// Клиент для ChappieMCP сервера через Unix Domain Socket.
///
/// Зачем actor: async операции с сокетами — actor даёт правильную изоляцию в Swift 6.
public actor MCPToolBridge {

    /// Путь к Unix Domain Socket файлу.
    /// Передаётся от MCPHelperLauncher через ToolExecutionService.
    private let socketPath: String

    /// Таймаут для запросов к MCP-серверу (секунды).
    /// Сборка может занимать минуты — ставим большой таймаут.
    private let timeoutSeconds: Double

    /// Инициализатор.
    ///
    /// - Parameters:
    ///   - socketPath: Путь к UDS файлу. Должен совпадать с путём в ChappieMCP.
    ///                 Строковый литерал используется намеренно — см. комментарий в заголовке файла.
    ///   - timeoutSeconds: Таймаут ожидания ответа от хелпера.
    public init(
        socketPath: String = "/tmp/com.chappie.mcp.sock",
        timeoutSeconds: Double = 600
    ) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Публичный API

    /// Выполняет инструмент на MCP-сервере.
    ///
    /// - Parameters:
    ///   - tool: Имя инструмента (например "git_status").
    ///   - args: Словарь аргументов инструмента.
    /// - Returns: Строковый результат или описание ошибки.
    public func execute(tool: String, args: [String: String] = [:]) async -> String {
        // Проверяем доступность сокета перед отправкой.
        // Если файл сокета не существует — сервер не запущен.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return """
            ❌ ChappieMCP сервер недоступен (сокет не найден: \(socketPath)).
            
            Хелпер должен запускаться автоматически при старте Chappie.app.
            Если этого не произошло — перезапусти приложение.
            """
        }

        return await sendRequest(tool: tool, args: args)
    }

    // MARK: - Приватные методы

    /// Отправляет запрос через Unix Domain Socket и получает ответ.
    ///
    /// Использует POSIX API напрямую (connect/send/recv), т.к. Foundation
    /// не имеет встроенного клиента для Unix Domain Sockets.
    private func sendRequest(tool: String, args: [String: String]) async -> String {
        let request = MCPRequestBody(tool: tool, args: args)
        guard let requestData = try? JSONEncoder().encode(request) else {
            return "❌ Ошибка: не удалось сериализовать запрос для инструмента \(tool)"
        }

        // Выполняем в отдельном потоке через withCheckedContinuation,
        // т.к. POSIX recv() блокирующий и не должен блокировать Swift Concurrency пул.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [socketPath, timeoutSeconds] in
                let result = Self.performSocketCall(
                    socketPath: socketPath,
                    requestData: requestData,
                    tool: tool,
                    timeoutSeconds: timeoutSeconds
                )
                continuation.resume(returning: result)
            }
        }
    }

    /// Синхронная POSIX операция с сокетом — выполняется на фоновом потоке.
    ///
    /// Зачем static: нет доступа к self (actor isolation), только чистая функция.
    private static func performSocketCall(
        socketPath: String,
        requestData: Data,
        tool: String,
        timeoutSeconds: Double
    ) -> String {
        // Создаём клиентский Unix Domain Socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return "❌ Не удалось создать сокет: \(String(cString: strerror(errno)))"
        }
        defer { close(fd) }

        // Устанавливаем таймаут на чтение/запись
        var timeout = timeval(
            tv_sec: __darwin_time_t(Int(timeoutSeconds)),
            tv_usec: 0
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Формируем адрес для подключения
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { charPtr in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(charPtr, src.baseAddress!, min(src.count, 104))
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        // Подключаемся к серверу
        let connectResult = withUnsafePointer(to: addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            return "❌ Не удалось подключиться к ChappieMCP (\(socketPath)): \(String(cString: strerror(errno)))"
        }

        // Отправляем запрос: 4 байта длины (big-endian) + JSON
        let length = UInt32(requestData.count)
        var header = [UInt8](repeating: 0, count: 4)
        header[0] = UInt8((length >> 24) & 0xFF)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        let headerSent = header.withUnsafeBytes { send(fd, $0.baseAddress!, 4, 0) }
        guard headerSent == 4 else {
            return "❌ Ошибка отправки заголовка: \(String(cString: strerror(errno)))"
        }

        let bodySent = requestData.withUnsafeBytes { send(fd, $0.baseAddress!, requestData.count, 0) }
        guard bodySent == requestData.count else {
            return "❌ Ошибка отправки тела запроса: \(String(cString: strerror(errno)))"
        }

        // Читаем ответ: сначала 4 байта длины
        var responseHeader = [UInt8](repeating: 0, count: 4)
        let headerRead = recv(fd, &responseHeader, 4, MSG_WAITALL)
        guard headerRead == 4 else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return "⏱️ Таймаут: инструмент \(tool) выполнялся слишком долго (>\(Int(timeoutSeconds)) сек)"
            }
            return "❌ Ошибка чтения заголовка ответа: \(String(cString: strerror(errno)))"
        }

        // Декодируем длину ответа
        let responseLength = UInt32(responseHeader[0]) << 24
                           | UInt32(responseHeader[1]) << 16
                           | UInt32(responseHeader[2]) << 8
                           | UInt32(responseHeader[3])

        guard responseLength > 0, responseLength < 10_000_000 else {
            return "❌ Неверная длина ответа от сервера: \(responseLength)"
        }

        // Читаем JSON тело ответа
        var responseBytes = [UInt8](repeating: 0, count: Int(responseLength))
        let bodyRead = recv(fd, &responseBytes, Int(responseLength), MSG_WAITALL)
        guard bodyRead == Int(responseLength) else {
            return "❌ Неполный ответ от сервера (ожидалось \(responseLength), получено \(bodyRead))"
        }

        // Декодируем JSON ответ
        let responseData = Data(responseBytes)
        guard let response = try? JSONDecoder().decode(MCPResponseBody.self, from: responseData) else {
            let raw = String(data: responseData, encoding: .utf8) ?? "нечитаемый ответ"
            return "❌ Не удалось декодировать ответ MCP-сервера: \(raw)"
        }

        if let error = response.error {
            return "❌ Ошибка инструмента \(tool): \(error)"
        }

        return response.result ?? "(пустой результат)"
    }
}

// MARK: - Модели запроса/ответа

/// Тело JSON-запроса к MCP-серверу.
private struct MCPRequestBody: Codable, Sendable {
    let tool: String
    let args: [String: String]
}

/// Тело JSON-ответа от MCP-сервера.
private struct MCPResponseBody: Codable, Sendable {
    let result: String?
    let error: String?
}
