// FileSystemManagerTests.swift
// Тесты для FileSystemManager — работа с файловой системой воркспейса.
// Особое внимание уделено безопасности: Path Traversal атаки должны блокироваться.
// Каждый тест работает в изолированной временной директории.

import Testing
import Foundation
@testable import ChappieCore

@Suite("FileSystemManager Tests")
struct FileSystemManagerTests {

    // MARK: - Вспомогательный метод

    /// Создаём временную директорию с тестовыми файлами.
    /// Структура: a.swift, b.swift, sub/c.swift
    private func makeManager() throws -> (FileSystemManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Создаём тестовые файлы в корне
        try "content a".write(to: tempDir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "content b".write(to: tempDir.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        // Создаём поддиректорию с файлом
        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "content c".write(to: subDir.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)

        let manager = FileSystemManager(workspaceURL: tempDir)
        return (manager, tempDir)
    }

    // MARK: - Тесты базовой функциональности

    /// listFiles должен вернуть все файлы включая вложенные директории.
    /// Пути должны быть относительными (без префикса воркспейса).
    @Test("listFiles возвращает все файлы")
    func listFilesReturnsAll() async throws {
        let (manager, _) = try makeManager()
        let files = try await manager.listFiles()

        // Проверяем что все три файла присутствуют в результате
        // Используем contains с проверкой суффикса — порядок не гарантирован
        let hasA = files.contains(where: { $0.hasSuffix("a.swift") })
        let hasB = files.contains(where: { $0.hasSuffix("b.swift") })
        let hasC = files.contains(where: { $0.hasSuffix("c.swift") })

        #expect(hasA, "Файл a.swift должен быть в списке")
        #expect(hasB, "Файл b.swift должен быть в списке")
        #expect(hasC, "Файл sub/c.swift должен быть в списке")
        #expect(files.count == 3)
    }

    /// Чтение существующего файла должно вернуть его содержимое.
    @Test("readFile возвращает содержимое файла")
    func readFileReturnsContent() async throws {
        let (manager, _) = try makeManager()
        let content = try await manager.readFile(at: "a.swift")
        #expect(content == "content a")
    }

    /// Запись нового файла — файл должен появиться на диске с правильным содержимым.
    @Test("writeFile создаёт файл с содержимым")
    func writeFileCreatesFile() async throws {
        let (manager, tempDir) = try makeManager()
        try await manager.writeFile(at: "new.swift", content: "hello world")
        let content = try String(contentsOf: tempDir.appendingPathComponent("new.swift"), encoding: .utf8)
        #expect(content == "hello world")
    }

    /// Удаление файла — файл должен исчезнуть с диска.
    @Test("deleteFile удаляет файл")
    func deleteFileRemovesFile() async throws {
        let (manager, tempDir) = try makeManager()
        try await manager.deleteFile(at: "a.swift")
        let exists = FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("a.swift").path)
        #expect(!exists)
    }

    /// Запись в поддиректорию — промежуточные папки должны создаваться автоматически.
    @Test("writeFile создаёт промежуточные директории")
    func writeFileCreatesIntermediateDirectories() async throws {
        let (manager, tempDir) = try makeManager()
        try await manager.writeFile(at: "deep/nested/file.swift", content: "nested")
        let exists = FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("deep/nested/file.swift").path
        )
        #expect(exists)
    }

    // MARK: - Тесты безопасности (Path Traversal)

    /// "../" в пути должен быть заблокирован — это попытка выйти за пределы воркспейса.
    @Test("Блокировка Path Traversal через ../")
    func blockPathTraversal() async throws {
        let (manager, _) = try makeManager()
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "../secret.txt")
        }
    }

    /// Абсолютный путь должен быть заблокирован.
    @Test("Блокировка абсолютного пути")
    func blockAbsolutePath() async throws {
        let (manager, _) = try makeManager()
        await #expect(throws: (any Error).self) {
            try await manager.readFile(at: "/etc/passwd")
        }
    }

    /// Попытка записи за пределы воркспейса должна быть заблокирована.
    @Test("Блокировка записи за пределы воркспейса")
    func blockWriteOutsideWorkspace() async throws {
        let (manager, _) = try makeManager()
        await #expect(throws: (any Error).self) {
            try await manager.writeFile(at: "../../evil.swift", content: "evil")
        }
    }

    /// Попытка удаления файла за пределами воркспейса должна быть заблокирована.
    @Test("Блокировка удаления за пределами воркспейса")
    func blockDeleteOutsideWorkspace() async throws {
        let (manager, _) = try makeManager()
        await #expect(throws: (any Error).self) {
            try await manager.deleteFile(at: "../important.txt")
        }
    }
}
