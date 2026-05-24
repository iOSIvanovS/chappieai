// ChappieApp.swift
// Chappie
//
// Точка входа приложения Chappie.
//
// LIFECYCLE ХЕЛПЕРА:
// - Хелпер ChappieMCP НЕ запускается здесь при старте.
//   Причина: при старте мы ещё не знаем путь к воркспейсу.
//   Если запустить без пути — хелпер получит "/" как рабочий каталог,
//   и git/build команды будут падать с "not a git repository".
//
// - Хелпер запускается в ChappieViewModel:
//   а) loadWorkspaceWithSecurityScope() — при восстановлении сохранённого воркспейса
//   б) setWorkspace() — при ручном выборе папки пользователем
//
// - applicationWillTerminate → terminateHelper() → хелпер завершается корректно.
//   Без явного завершения хелпер останется висеть как orphan-процесс,
//   и следующий bind() на тот же сокет упадёт с "address already in use".

import SwiftUI
import AppKit
import ChappieCore

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    /// AppDelegate нужен для перехвата applicationWillTerminate —
    /// SwiftUI не предоставляет нативного способа выполнить код при завершении приложения.
    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            // Стандартные команды macOS (Quit, Minimize и т.д.)
            // Кастомные команды добавляются здесь при необходимости
        }

        // Настройки приложения — открываются через Cmd+,
        Settings {
            SettingsView()
        }
    }
}

// MARK: - App Delegate

/// Делегат приложения для обработки системных событий macOS.
///
/// Зачем NSApplicationDelegateAdaptor:
/// SwiftUI App protocol не предоставляет хука на завершение приложения.
/// NSApplicationDelegate.applicationWillTerminate — единственный надёжный способ
/// выполнить cleanup (завершить дочерние процессы) перед выходом.
final class ChappieAppDelegate: NSObject, NSApplicationDelegate {

    /// Вызывается системой непосредственно перед завершением приложения.
    /// Здесь мы убиваем дочерний процесс ChappieMCP.
    ///
    /// ПОЧЕМУ ВАЖНО:
    /// Если не завершить хелпер явно — он останется в памяти как orphan-процесс.
    /// При следующем запуске приложения bind() на тот же сокет упадёт с ошибкой
    /// "address already in use". Хелпер не сможет запуститься.
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            MCPHelperLauncher.shared.terminateHelper()
        }
    }

    /// Стандартное поведение macOS: закрытие последнего окна завершает приложение.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
