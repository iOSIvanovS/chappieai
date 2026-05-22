//
//  FileSystemManager.swift
//  ChappieCore
//
//  Created by Chappie.
//

import Foundation

/// Менеджер для работы с файловой системой проекта.
/// Что это: Сервис, предоставляющий ИИ-агенту возможность читать, писать, удалять и искать файлы.
/// Зачем: Это "руки" ИИ в реальном мире. Позволяют агенту модифицировать собственный исходный код.
public actor FileSystemManager {
    public let workspaceURL: URL
    private let fileManager = FileManager.default

    /// Инициализирует менеджер с указанием корневой папки проекта.
    /// - Parameter workspaceURL: URL директории, в которой ИИ разрешено работать.
    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    /// Получает список всех файлов в проекте (относительные пути).
    /// Что это: Сканирует директорию проекта и возвращает пути ко всем файлам.
    /// Зачем: ИИ должен понимать структуру проекта, чтобы знать, какие файлы можно редактировать.
    /// - Returns: Массив строк с относительными путями.
    public func listFiles() throws -> [String] {
        guard let enumerator = fileManager.enumerator(at: workspaceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw ChappieError.fileSystemError("Не удалось получить доступ к директории: \(workspaceURL.path)")
        }
        
        var filePaths: [String] = []
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: workspaceURL.path + "/", with: "")
            filePaths.append(relativePath)
        }
        return filePaths
    }

    /// Читает содержимое файла.
    /// - Parameter relativePath: Относительный путь к файлу.
    /// - Returns: Содержимое файла в виде строки.
    public func readFile(at relativePath: String) throws -> String {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Не удалось прочитать файл \(relativePath): \(error.localizedDescription)")
        }
    }

    /// Записывает текст в файл. Если файла или папок нет — создает их.
    /// - Parameters:
    ///   - relativePath: Относительный путь, куда нужно сохранить файл.
    ///   - content: Полный текст (код), который нужно записать.
    public func writeFile(at relativePath: String, content: String) throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        
        do {
            if !fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ChappieError.fileSystemError("Не удалось записать файл \(relativePath): \(error.localizedDescription)")
        }
    }

    /// Удаляет файл из проекта.
    /// - Parameter relativePath: Относительный путь к удаляемому файлу.
    public func deleteFile(at relativePath: String) throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                throw ChappieError.fileSystemError("Не удалось удалить файл \(relativePath): \(error.localizedDescription)")
            }
        } else {
            throw ChappieError.fileSystemError("Файл не найден для удаления: \(relativePath)")
        }
    }
}
