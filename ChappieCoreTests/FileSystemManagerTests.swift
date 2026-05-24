// FileSystemManagerTests.swift
// ChappieCoreTests
//
// Юнит-тесты для FileSystemManager — "рук" ИИ-агента в файловой системе.
//
// ПРИОРИТЕТ ТЕСТИРОВАНИЯ:
// Самое важное здесь — безопасность. Path Traversal (CWE-22) — это критическая
// уязвимость: если защита сломается, ИИ сможет читать/писать системные файлы.
// Тесты безопасности помечены явно и должны проходить при любом рефакторинге.
//
// ИЗОЛЯЦИЯ:
// Каждый тест работает во временной директории — реальные файлы проекта не трогаются.
//
// ВАЖНО ПРО listFiles():
// FileSystemManager.listFiles() — синхронный метод (throws, не async throws).
// Тесты вызывают его напрямую без await. Также метод возвращает пути
// через replacingOccurrences, но на некоторых системах workspaceURL.path
// может иметь префикс /private (симлинк /tmp → /private/tmp).
// Поэтому сравниваем через hasSuffix, а не точное совпадение.

import Testing
import Foundation
@testable import ChappieCore

@Suite("FileSystemManager Tests")
struct FileSystemManagerTests {

    // MARK: - Вспомогательные методы

    /// Создаёт временную директорию и возвращает готовый FileSystemManager.
    /// Используем UUID чтобы тесты были изолированы даже при параллельном запуске.
    private func makeManager() throws -> (FileSystemManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FSMTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = FileSystemManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Тесты чтения

    /// Базовый сценарий: файл существует → читаем содержимое.
    @Test("Чтение существующего файла")
    func readExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Создаём файл напрямую через FileManager (минуя FileSystemManager)
        let fileURL = workspace.appendingPathComponent("test.txt")
        try "Hello, Chappie!".write(to: fileURL, atomically: true, encoding: .utf8)

        // Читаем через FileSystemManager — метод синхронный, вызываем через actor
        let content = try await manager.readFile(at: "test.txt")
        #expect(content == "Hello, Chappie!")
    }

    /// Чтение несуществующего файла должно бросать ChappieError.fileSystemError.
    @Test("Чтение несуществующего файла бросает ошибку")
    func readMissingFileThrows() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Ожидаем ошибку — файла нет
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "nonexistent_file_xyz.txt")
        }
    }

    // MARK: - Тесты записи

    /// Запись нового файла → файл создаётся с правильным содержимым.
    @Test("Запись нового файла")
    func writeNewFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "new_file.swift", content: "import Foundation")

        // Проверяем через прямое чтение (не через FileSystemManager)
        let fileURL = workspace.appendingPathComponent("new_file.swift")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(content == "import Foundation")
    }

    /// Запись в поддиректорию — директория создаётся автоматически.
    @Test("Запись в поддиректорию создаёт промежуточные папки")
    func writeToSubdirectoryCreatesDirectories() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Путь с несуществующей поддиректорией
        try await manager.writeFile(at: "Views/Chat/ChatView.swift", content: "// ChatView")

        let fileURL = workspace.appendingPathComponent("Views/Chat/ChatView.swift")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Перезапись существующего файла — содержимое обновляется.
    @Test("Перезапись существующего файла")
    func overwriteExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "file.txt", content: "old content")
        try await manager.writeFile(at: "file.txt", content: "new content")

        let content = try await manager.readFile(at: "file.txt")
        #expect(content == "new content")
    }

    // MARK: - Тесты удаления

    /// Удаление существующего файла — файл исчезает.
    @Test("Удаление существующего файла")
    func deleteExistingFile() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        try await manager.writeFile(at: "to_delete.txt", content: "bye")

        let fileURL = workspace.appendingPathComponent("to_delete.txt")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try await manager.deleteFile(at: "to_delete.txt")
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Удаление несуществующего файла бросает ошибку (не молчит).
    @Test("Удаление несуществующего файла бросает ошибку")
    func deleteMissingFileThrows() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.deleteFile(at: "ghost_file.txt")
        }
    }

    // MARK: - Тесты списка файлов

    /// listFiles возвращает все файлы в директории.
    ///
    /// ПОЧЕМУ hasSuffix а не точное совпадение:
    /// На macOS /tmp является симлинком на /private/tmp. FileSystemManager использует
    /// workspaceURL.path для вычисления относительных путей через replacingOccurrences.
    /// Но enumerator может вернуть пути через /private/tmp, тогда как workspaceURL
    /// указывает на /tmp — replacingOccurrences не сработает и путь останется абсолютным.
    /// hasSuffix устойчив к этой разнице и проверяет только значимую часть пути.
    @Test("listFiles возвращает все файлы")
    func listFilesReturnsAllFiles() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Создаём несколько файлов через FileSystemManager
        try await manager.writeFile(at: "a.swift", content: "")
        try await manager.writeFile(at: "b.swift", content: "")
        try await manager.writeFile(at: "sub/c.swift", content: "")

        // listFiles — синхронный метод, но вызываем через actor (await нужен для входа в actor)
        let files = try await manager.listFiles()

        // Проверяем через hasSuffix — устойчиво к /private/tmp vs /tmp
        #expect(files.contains(where: { $0.hasSuffix("a.swift") }), "Файл a.swift должен быть в списке")
        #expect(files.contains(where: { $0.hasSuffix("b.swift") }), "Файл b.swift должен быть в списке")
        #expect(files.contains(where: { $0.hasSuffix("c.swift") }), "Файл sub/c.swift должен быть в списке")
    }

    // MARK: - ТЕСТЫ БЕЗОПАСНОСТИ (Path Traversal)

    /// КРИТИЧЕСКИЙ ТЕСТ: попытка выйти за пределы workspace через "../" должна быть отклонена.
    @Test("🔒 Path Traversal через ../ отклоняется")
    func pathTraversalUpDirectoryBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Классическая атака Path Traversal — выход на уровень выше workspace
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "../../etc/passwd")
        }
    }

    /// КРИТИЧЕСКИЙ ТЕСТ: абсолютный путь должен быть отклонён.
    @Test("🔒 Абсолютный путь отклоняется")
    func absolutePathBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Попытка использовать абсолютный путь к системному файлу
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "/etc/hosts")
        }
    }

    /// КРИТИЧЕСКИЙ ТЕСТ: попытка записи за пределы workspace отклоняется.
    @Test("🔒 Запись за пределы workspace отклоняется")
    func writeOutsideWorkspaceBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        // Попытка записи в родительскую директорию через Path Traversal
        await #expect(throws: (any Error).self) {
            try await manager.writeFile(at: "../evil_file.txt", content: "hacked")
        }
    }

    /// КРИТИЧЕСКИЙ ТЕСТ: удаление за пределами workspace отклоняется.
    @Test("🔒 Удаление за пределами workspace отклоняется")
    func deleteOutsideWorkspaceBlocked() async throws {
        let (manager, workspace) = try makeManager()
        defer { cleanup(workspace) }

        await #expect(throws: (any Error).self) {
            try await manager.deleteFile(at: "../../important_file.txt")
        }
    }
}
