//
//  ChatHistoryManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Менеджер для сохранения и загрузки истории чата в локальный JSON-файл.
///
/// ## Архитектурное решение (TD-03)
/// После рефакторинга AI_Docs → architecture.md история чата переехала:
///
/// БЫЛО: `<workspaceURL>/AI_Docs/chat_history.json`
/// СТАЛО: `<workspaceURL>/chat_history.json` (прямо в корне проекта)
///
/// ПОЧЕМУ В КОРНЕ:
/// - Папка AI_Docs упразднена — теперь каждый таргет имеет только architecture.md.
/// - Хранение в корне проекта логично: история — это артефакт проекта, а не технического слоя.
/// - Проще находить, проще бэкапить, проще версионировать (если нужно).
///
/// ## Лимит сообщений (TD-03)
/// При каждом сохранении история автоматически подрезается до maxStoredMessages (100).
/// ПОЧЕМУ 100:
/// - Для контекста оркестратора используется buildContextWindow() — он берёт последние N.
/// - Хранить 1000+ сообщений бессмысленно: они никогда не попадут в контекст.
/// - 100 сообщений — это ~20-50 диалоговых пар, достаточно для долгосрочной работы.
/// - Файл остаётся компактным и не разрастается до неприличия.
///
/// ## Потокобезопасность
/// Класс помечен как `Sendable`, потому что все его свойства — константы (`let`),
/// вычисляемые один раз при инициализации. Методы чтения/записи не изменяют состояние объекта.
///
/// ## Обратная совместимость
/// Статическое свойство `shared` сохранено как дефолтный фолбэк (без воркспейса).
public final class ChatHistoryManager: Sendable {

    // MARK: - Константы

    /// Имя файла истории чата в корне воркспейса.
    /// Вынесено в константу чтобы менять в одном месте.
    private static let workspaceHistoryFileName = "chat_history.json"

    /// Имя поддиректории в глобальных Documents для фолбэк-хранилища.
    private static let globalSubdirectory = "Chappie"

    /// Имя файла глобального фолбэк-хранилища.
    private static let globalHistoryFileName = "global_chat_history.json"

    /// Максимальное количество сообщений, хранимых в файле.
    ///
    /// При превышении лимита старые сообщения отбрасываются — сохраняются только последние N.
    /// Значение 100 выбрано как баланс между полнотой истории и размером файла.
    /// Оркестратор всё равно берёт из истории только последние 12 (maxMessagesInContext),
    /// поэтому хранить больше 100 нет практического смысла.
    public static let maxStoredMessages = 100

    // MARK: - Синглтон (обратная совместимость)

    /// Дефолтный экземпляр без привязки к воркспейсу.
    /// Используется как фолбэк когда воркспейс ещё не выбран.
    public static let shared = ChatHistoryManager(workspaceURL: nil)

    // MARK: - Свойства

    /// Итоговый URL файла истории чата.
    /// Вычисляется один раз в `init` и больше не меняется — это ключевое условие `Sendable`.
    public let fileURL: URL

    // MARK: - Инициализация

    /// Создаёт менеджер истории чата.
    ///
    /// - Parameter workspaceURL: URL корневой папки воркспейса (проекта).
    ///   Если передан — история хранится в `<workspaceURL>/chat_history.json`.
    ///   Если `nil` — используется глобальный фолбэк `~/Documents/Chappie/global_chat_history.json`.
    public init(workspaceURL: URL?) {
        if let workspaceURL = workspaceURL {
            // Режим воркспейса: история лежит прямо в корне папки проекта.
            // Не нужна поддиректория AI_Docs — она упразднена в рефакторинге TD-03.
            fileURL = workspaceURL
                .appendingPathComponent(ChatHistoryManager.workspaceHistoryFileName)
        } else {
            // Режим фолбэка: воркспейс ещё не выбран.
            // Используем поддиректорию ~/Documents/Chappie/ чтобы не засорять корень Documents.
            let documentsURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
            let chappieGlobalURL = documentsURL
                .appendingPathComponent(ChatHistoryManager.globalSubdirectory, isDirectory: true)

            ChatHistoryManager.createDirectoryIfNeeded(at: chappieGlobalURL)

            fileURL = chappieGlobalURL
                .appendingPathComponent(ChatHistoryManager.globalHistoryFileName)
        }
    }

    // MARK: - Публичный API

    /// Загружает историю сообщений из файла.
    ///
    /// Использует Generic-тип `T`, чтобы менеджер в ChappieCore не зависел от
    /// конкретной модели `ChatMessage`, которая определена в UI-слое приложения.
    ///
    /// - Returns: Массив декодированных сообщений, или пустой массив при ошибке/отсутствии файла.
    public func loadMessages<T: Codable>() -> [T] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        do {
            let messages = try JSONDecoder().decode([T].self, from: data)
            return messages
        } catch {
            // Ошибка декодирования — возможно повреждение файла или изменение модели.
            // Возвращаем пустой массив чтобы не крашить приложение.
            print("[ChatHistoryManager] Не удалось декодировать историю чата: \(error)")
            return []
        }
    }

    /// Сохраняет историю сообщений в файл с автоматическим подрезанием до maxStoredMessages.
    ///
    /// ПОЧЕМУ ПОДРЕЗАНИЕ ПРИ СОХРАНЕНИИ, А НЕ ПРИ ЗАГРУЗКЕ:
    /// - Файл остаётся компактным всегда, а не только в памяти приложения.
    /// - Нет риска что при следующем запуске файл снова окажется раздутым.
    /// - Логика подрезания в одном месте, не размазана по коду.
    ///
    /// Запись атомарная (.atomic): данные пишутся во временный файл, затем переименовываются.
    /// Это защищает от повреждения файла при внезапном завершении приложения.
    ///
    /// - Parameter messages: Массив сообщений для сохранения.
    public func saveMessages<T: Codable>(_ messages: [T]) {
        // Подрезаем до лимита: берём только последние maxStoredMessages.
        // Если сообщений меньше лимита — массив не изменяется (suffix безопасен).
        let trimmedMessages = messages.count > ChatHistoryManager.maxStoredMessages
            ? Array(messages.suffix(ChatHistoryManager.maxStoredMessages))
            : messages

        if messages.count > ChatHistoryManager.maxStoredMessages {
            let dropped = messages.count - ChatHistoryManager.maxStoredMessages
            print("[ChatHistoryManager] ✂️ Подрезание: удалено \(dropped) старых сообщений, сохранено \(trimmedMessages.count)")
        }

        do {
            let data = try JSONEncoder().encode(trimmedMessages)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ChatHistoryManager] Не удалось сохранить историю чата: \(error)")
        }
    }

    /// Удаляет файл истории чата.
    ///
    /// Полезно при сбросе настроек или очистке данных проекта.
    /// Если файл не существует — операция считается успешной (нет ошибки).
    public func clearHistory() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            print("[ChatHistoryManager] Не удалось удалить файл истории: \(error)")
        }
    }

    // MARK: - Вспомогательные методы (приватные, статические)

    /// Создаёт директорию по указанному URL, если она ещё не существует.
    ///
    /// Вынесено в статический метод, потому что вызывается из `init` до полной
    /// инициализации `self`. Параметр `withIntermediateDirectories: true` позволяет
    /// создать всю цепочку директорий за один вызов (аналог `mkdir -p`).
    private static func createDirectoryIfNeeded(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            print("[ChatHistoryManager] Не удалось создать директорию \(url.path): \(error)")
        }
    }
}
