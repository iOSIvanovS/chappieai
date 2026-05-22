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
        // skipsHiddenFiles автоматически исключит скрытые папки вроде .git, .build, .swiftpm
        guard let enumerator = fileManager.enumerator(at: workspaceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        
        var filePaths: [String] = []
        for case let fileURL as URL in enumerator {
            // Возвращаем агенту пути без привязки к локальному диску пользователя (только относительные)
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
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Записывает текст в файл. Если файла или папок нет — создает их.
    /// - Parameters:
    ///   - relativePath: Относительный путь, куда нужно сохранить файл.
    ///   - content: Полный текст (код), который нужно записать.
    public func writeFile(at relativePath: String, content: String) throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        let directoryURL = fileURL.deletingLastPathComponent()
        
        // Автоматически создаем подпапки, если агент решил положить файл глубоко в иерархию
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Удаляет файл из проекта.
    /// - Parameter relativePath: Относительный путь к удаляемому файлу.
    public func deleteFile(at relativePath: String) throws {
        let fileURL = workspaceURL.appendingPathComponent(relativePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
