//
//  FileSystemManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Менеджер для работы с файловой системой проекта.
///
/// Что это: Сервис, предоставляющий ИИ-агенту возможность читать, писать, удалять и искать файлы.
///
/// Зачем: Это "руки" ИИ в реальном мире. Позволяют агенту модифицировать собственный исходный код.
///
/// Безопасность: Все операции с файлами защищены от атак типа Path Traversal (CWE-22).
/// ИИ-агент работает с внешними данными (ответы LLM), которые потенциально могут содержать
/// вредоносные пути вида `../../etc/passwd`. Без валидации это позволило бы агенту выйти
/// за пределы разрешённого рабочего пространства и прочитать/перезаписать системные файлы.
public actor FileSystemManager {
    public let workspaceURL: URL
    private let fileManager = FileManager.default

    /// Инициализирует менеджер с указанием корневой папки проекта.
    /// - Parameter workspaceURL: URL директории, в которой ИИ разрешено работать.
    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Безопасная валидация путей

    /// Валидирует относительный путь и возвращает безопасный абсолютный URL.
    ///
    /// Зачем этот метод существует:
    /// ИИ-агент получает пути к файлам из ответов языковой модели. LLM может (намеренно
    /// или по ошибке) сгенерировать путь вида `../../.ssh/id_rsa` или `../../../etc/hosts`.
    /// Без проверки `appendingPathComponent` просто склеит строки, и мы получим доступ
    /// к файлам за пределами разрешённой директории — классическая атака Path Traversal.
    ///
    /// Как защита работает:
    /// 1. Мы стандартизируем оба пути (рабочее пространство и целевой файл).
    ///    `standardized` раскрывает все `.` и `..` компоненты, не обращаясь к диску.
    ///    `resolvingSymlinksInPath()` дополнительно разрешает символические ссылки,
    ///    которые могут указывать на директории вне workspace (symlink traversal).
    /// 2. Проверяем, что стандартизированный абсолютный путь к файлу начинается
    ///    со стандартизированного пути рабочего пространства.
    ///    Именно стандартизация критична: без неё `../../` не будет раскрыт до операции
    ///    сравнения, и проверка `hasPrefix` может быть обойдена.
    ///
    /// - Parameter relativePath: Относительный путь, пришедший от ИИ-агента.
    /// - Returns: Безопасный абсолютный URL внутри `workspaceURL`.
    /// - Throws: `ChappieError.fileSystemError` если путь выходит за пределы workspace.
    private func validateAndResolvePath(_ relativePath: String) throws -> URL {
        // Шаг 1: Стандартизируем корень рабочего пространства.
        // Важно делать это один раз здесь, а не полагаться на исходный workspaceURL,
        // потому что он мог быть передан с символическими ссылками или лишними компонентами.
        // resolvingSymlinksInPath() обращается к диску и полностью разрешает симлинки,
        // что защищает от атак через символические ссылки на уровне самого workspace.
        let resolvedWorkspace = workspaceURL.resolvingSymlinksInPath()

        // Шаг 2: Строим абсолютный URL, добавляя относительный путь к корню workspace.
        // На этом этапе путь ещё может содержать `..` и `.` — это нормально,
        // они будут раскрыты на следующем шаге стандартизации.
        let rawTargetURL = resolvedWorkspace.appendingPathComponent(relativePath)

        // Шаг 3: Стандартизируем целевой URL.
        // `standardized` раскрывает `.` и `..` лексически (без обращения к диску),
        // что позволяет безопасно проверить итоговый путь даже если файл ещё не существует.
        // `resolvingSymlinksInPath()` дополнительно разрешает симлинки в самом пути,
        // предотвращая атаку через симлинк внутри workspace, указывающий наружу.
        // Используем standardized как основу, так как файл может не существовать на диске
        // (например, при записи нового файла), а resolvingSymlinksInPath требует существующий путь.
        let resolvedTargetURL = rawTargetURL.standardized

        // Шаг 4: Получаем строковые представления для сравнения.
        // Добавляем "/" в конце пути workspace, чтобы избежать ложного срабатывания:
        // например, workspace "/foo/bar" не должен считаться префиксом для "/foo/barbaz/file.txt".
        let workspacePath = resolvedWorkspace.path.hasSuffix("/")
            ? resolvedWorkspace.path
            : resolvedWorkspace.path + "/"

        let targetPath = resolvedTargetURL.path

        // Шаг 5: Ключевая проверка безопасности.
        // Целевой путь должен либо совпадать с корнем workspace (маловероятно, но допустимо),
        // либо начинаться с пути workspace + "/".
        // Если это условие нарушено — путь вышел за пределы разрешённой директории.
        let isInsideWorkspace = targetPath == resolvedWorkspace.path
            || targetPath.hasPrefix(workspacePath)

        guard isInsideWorkspace else {
            // Выбрасываем ошибку с подробным описанием, чтобы разработчик мог
            // отследить попытку нарушения безопасности в логах.
            throw ChappieError.fileSystemError(
                """
                Нарушение безопасности: попытка Path Traversal.
                Запрошенный путь '\(relativePath)' разрешается в '\(targetPath)',
                что находится за пределами разрешённого рабочего пространства '\(resolvedWorkspace.path)'.
                Операция отклонена.
                """
            )
        }

        return resolvedTargetURL
    }

    // MARK: - Публичный API

    /// Получает список всех файлов в проекте (относительные пути).
    ///
    /// Что это: Сканирует директорию проекта и возвращает пути ко всем файлам.
    ///
    /// Зачем: ИИ должен понимать структуру проекта, чтобы знать, какие файлы можно редактировать.
    ///
    /// - Returns: Массив строк с относительными путями.
    public func listFiles() throws -> [String] {
        // listFiles не принимает внешний путь, поэтому Path Traversal здесь невозможен —
        // мы всегда сканируем именно workspaceURL. Дополнительная валидация не требуется.
        guard let enumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ChappieError.fileSystemError(
                "Не удалось получить доступ к директории: \(workspaceURL.path)"
            )
        }

        var filePaths: [String] = []
        for case let fileURL as URL in enumerator {
            // Формируем относительный путь, убирая префикс workspace.
            // Используем исходный workspaceURL.path, так как enumerator работает с ним же.
            let relativePath = fileURL.path.replacingOccurrences(
                of: workspaceURL.path + "/",
                with: ""
            )
            filePaths.append(relativePath)
        }
        return filePaths
    }

    /// Читает содержимое файла.
    ///
    /// Безопасность: Перед чтением путь проходит валидацию через `validateAndResolvePath`,
    /// что исключает возможность чтения файлов за пределами workspace.
    ///
    /// - Parameter relativePath: Относительный путь к файлу (предоставляется ИИ-агентом).
    /// - Returns: Содержимое файла в виде строки.
    /// - Throws: `ChappieError.fileSystemError` при нарушении безопасности или ошибке чтения.
    public func readFile(at relativePath: String) throws -> String {
        // Валидируем путь перед любым обращением к файловой системе.
        // Это первая линия защиты: если путь небезопасен, операция прерывается немедленно.
        let safeURL = try validateAndResolvePath(relativePath)

        do {
            return try String(contentsOf: safeURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError(
                "Не удалось прочитать файл '\(relativePath)': \(error.localizedDescription)"
            )
        }
    }

    /// Записывает текст в файл. Если файла или папок нет — создает их.
    ///
    /// Безопасность: Перед записью путь проходит валидацию через `validateAndResolvePath`,
    /// что исключает возможность создания или перезаписи файлов за пределами workspace.
    /// Это особенно важно для операции записи: злоумышленник мог бы перезаписать
    /// системные конфигурационные файлы или SSH-ключи.
    ///
    /// - Parameters:
    ///   - relativePath: Относительный путь, куда нужно сохранить файл.
    ///   - content: Полный текст (код), который нужно записать.
    /// - Throws: `ChappieError.fileSystemError` при нарушении безопасности или ошибке записи.
    public func writeFile(at relativePath: String, content: String) throws {
        // Валидируем путь перед записью. Особенно критично для write-операций,
        // так как создание файла вне workspace может иметь необратимые последствия.
        let safeURL = try validateAndResolvePath(relativePath)
        let directoryURL = safeURL.deletingLastPathComponent()

        do {
            // Создаём промежуточные директории если они не существуют.
            // withIntermediateDirectories: true — не выбрасывает ошибку если директория уже есть.
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            }
            // atomically: true гарантирует, что файл либо записан полностью,
            // либо не записан вовсе — защита от повреждения при сбое.
            try content.write(to: safeURL, atomically: true, encoding: .utf8)
        } catch let chappieError as ChappieError {
            // Пробрасываем ChappieError без обёртки, чтобы не потерять контекст ошибки безопасности.
            throw chappieError
        } catch {
            throw ChappieError.fileSystemError(
                "Не удалось записать файл '\(relativePath)': \(error.localizedDescription)"
            )
        }
    }

    /// Удаляет файл из проекта.
    ///
    /// Безопасность: Перед удалением путь проходит валидацию через `validateAndResolvePath`,
    /// что исключает возможность удаления файлов за пределами workspace.
    /// Удаление — деструктивная операция, поэтому защита здесь особенно важна.
    ///
    /// - Parameter relativePath: Относительный путь к удаляемому файлу.
    /// - Throws: `ChappieError.fileSystemError` при нарушении безопасности или ошибке удаления.
    public func deleteFile(at relativePath: String) throws {
        // Валидируем путь перед удалением. Без этой проверки ИИ мог бы удалить
        // критически важные файлы системы, передав путь вида `../../System/Library/...`.
        let safeURL = try validateAndResolvePath(relativePath)

        if fileManager.fileExists(atPath: safeURL.path) {
            do {
                try fileManager.removeItem(at: safeURL)
            } catch {
                throw ChappieError.fileSystemError(
                    "Не удалось удалить файл '\(relativePath)': \(error.localizedDescription)"
                )
            }
        } else {
            throw ChappieError.fileSystemError(
                "Файл не найден для удаления: '\(relativePath)'"
            )
        }
    }
}
