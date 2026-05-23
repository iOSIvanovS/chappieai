//
//  ChatHistoryManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Менеджер для сохранения и загрузки истории чата в локальный JSON-файл.
///
/// ## Архитектурное решение (TD-02)
/// Ранее менеджер был синглтоном с фиксированным глобальным путём, что не позволяло
/// изолировать историю чата по проектам (воркспейсам). Теперь каждый экземпляр
/// инициализируется с опциональным `workspaceURL`, что даёт следующее поведение:
///
/// - **С воркспейсом**: история хранится в `<workspaceURL>/AI_Docs/chat_history.json`,
///   то есть прямо внутри папки проекта. Это позволяет переносить проект вместе с историей.
/// - **Без воркспейса (фолбэк)**: история хранится в `~/Documents/Chappie/global_chat_history.json`.
///   Это нужно для случаев, когда пользователь ещё не выбрал рабочую папку.
///
/// ## Потокобезопасность
/// Класс помечен как `Sendable`, потому что все его свойства — константы (`let`),
/// вычисляемые один раз при инициализации. Методы чтения/записи не изменяют состояние объекта.
///
/// ## Обратная совместимость
/// Статическое свойство `shared` сохранено как дефолтный фолбэк (без воркспейса),
/// чтобы не ломать существующий код, который ещё не передаёт URL воркспейса.
public final class ChatHistoryManager: Sendable {

    // MARK: - Пути к файлам

    /// Имя поддиректории внутри воркспейса, где хранятся AI-артефакты.
    /// Вынесено в константу, чтобы легко менять в одном месте.
    private static let aiDocsSubdirectory = "AI_Docs"

    /// Имя файла истории чата внутри воркспейса.
    private static let workspaceHistoryFileName = "chat_history.json"

    /// Имя поддиректории в глобальных Documents для фолбэк-хранилища.
    private static let globalSubdirectory = "Chappie"

    /// Имя файла глобального фолбэк-хранилища.
    private static let globalHistoryFileName = "global_chat_history.json"

    /// Имя старого глобального файла (до рефакторинга TD-02).
    /// Используется ТОЛЬКО для автоматической миграции данных.
    private static let legacyHistoryFileName = "chappie_chat_history.json"

    // MARK: - Синглтон (обратная совместимость)

    /// Дефолтный экземпляр без привязки к воркспейсу.
    /// Оставлен для обратной совместимости: код, который ещё не знает о воркспейсах,
    /// может продолжать использовать `ChatHistoryManager.shared`.
    /// При переходе на полноценную поддержку проектов следует создавать
    /// экземпляр через `ChatHistoryManager(workspaceURL: url)`.
    public static let shared = ChatHistoryManager(workspaceURL: nil)

    // MARK: - Свойства

    /// Итоговый URL файла, в который будет производиться чтение и запись.
    /// Вычисляется один раз в `init` и больше не меняется — это ключевое условие `Sendable`.
    public let fileURL: URL

    // MARK: - Инициализация

    /// Создаёт менеджер истории чата.
    ///
    /// - Parameter workspaceURL: URL корневой папки воркспейса (проекта).
    ///   Если передан, история будет храниться внутри проекта.
    ///   Если `nil`, используется глобальный фолбэк в папке Documents.
    ///
    /// При первом использовании с воркспейсом автоматически выполняется
    /// попытка миграции данных из устаревшего глобального файла.
    public init(workspaceURL: URL?) {
        if let workspaceURL = workspaceURL {
            // Режим воркспейса: история хранится внутри папки проекта.
            // Это позволяет переносить, архивировать и версионировать историю вместе с проектом.
            let aiDocsURL = workspaceURL
                .appendingPathComponent(ChatHistoryManager.aiDocsSubdirectory, isDirectory: true)
            let targetURL = aiDocsURL
                .appendingPathComponent(ChatHistoryManager.workspaceHistoryFileName)

            // Создаём директорию AI_Docs, если она ещё не существует.
            // Без этого попытка записи файла упадёт с ошибкой "No such file or directory".
            ChatHistoryManager.createDirectoryIfNeeded(at: aiDocsURL)

            fileURL = targetURL

            // Выполняем миграцию: если файл истории в воркспейсе ещё не создан,
            // но существует старый глобальный файл — копируем данные, чтобы
            // пользователь не потерял историю диалогов при переходе на новую архитектуру.
            ChatHistoryManager.migrateIfNeeded(to: targetURL)
        } else {
            // Режим фолбэка: воркспейс ещё не выбран.
            // Используем поддиректорию ~/Documents/Chappie/, чтобы не засорять
            // корень Documents и логически группировать файлы приложения.
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
    /// Вызывающий код сам указывает нужный тип через аннотацию или вывод типов.
    ///
    /// - Returns: Массив декодированных сообщений, или пустой массив при ошибке/отсутствии файла.
    public func loadMessages<T: Codable>() -> [T] {
        // Если файл ещё не создан — это нормальная ситуация при первом запуске.
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        do {
            let messages = try JSONDecoder().decode([T].self, from: data)
            return messages
        } catch {
            // Ошибка декодирования может означать повреждение файла или изменение модели.
            // Возвращаем пустой массив, чтобы не крашить приложение.
            print("[ChatHistoryManager] Не удалось декодировать историю чата: \(error)")
            return []
        }
    }

    /// Сохраняет историю сообщений в файл.
    ///
    /// Использует опцию `.atomic`, чтобы запись была атомарной:
    /// данные сначала пишутся во временный файл, а затем переименовываются.
    /// Это защищает от повреждения файла при внезапном завершении приложения.
    ///
    /// - Parameter messages: Массив сообщений для сохранения.
    public func saveMessages<T: Codable>(_ messages: [T]) {
        do {
            let data = try JSONEncoder().encode(messages)
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

    /// Выполняет однократную миграцию данных из устаревшего глобального файла.
    ///
    /// ## Логика миграции
    /// 1. Если целевой файл уже существует — миграция не нужна (данные уже на месте).
    /// 2. Если старый файл `~/Documents/chappie_chat_history.json` существует —
    ///    копируем его в новое место.
    /// 3. Если старого файла нет — это новый пользователь, миграция не требуется.
    ///
    /// Старый файл не удаляется намеренно: это даёт пользователю возможность
    /// восстановить данные вручную, если что-то пойдёт не так.
    ///
    /// - Parameter targetURL: URL нового файла истории в воркспейсе.
    private static func migrateIfNeeded(to targetURL: URL) {
        // Если новый файл уже существует — история уже была мигрирована ранее или
        // создана заново. Повторная миграция перезатёрла бы актуальные данные.
        guard !FileManager.default.fileExists(atPath: targetURL.path) else { return }

        // Формируем путь к старому глобальному файлу (формат до TD-02).
        let documentsURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let legacyFileURL = documentsURL
            .appendingPathComponent(legacyHistoryFileName)

        // Если старого файла нет — пользователь новый, миграция не требуется.
        guard FileManager.default.fileExists(atPath: legacyFileURL.path) else { return }

        do {
            // Копируем (не перемещаем!) старый файл в новое место.
            // Копирование безопаснее: если что-то пойдёт не так, исходные данные сохранятся.
            try FileManager.default.copyItem(at: legacyFileURL, to: targetURL)
            print("[ChatHistoryManager] Миграция успешна: данные скопированы из \(legacyFileURL.lastPathComponent) в воркспейс.")
        } catch {
            print("[ChatHistoryManager] Ошибка миграции: \(error). Старый файл сохранён по пути: \(legacyFileURL.path)")
        }
    }
}
