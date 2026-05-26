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
//
// SWIFTDATA (REFACTOR-THREADS IT-01):
// ModelContainer создаётся ОДИН РАЗ здесь и передаётся через .modelContainer()
// в SwiftUI-окружение. Это стандартная практика SwiftData — единственный контейнер
// на всё приложение. ThreadStore и ProjectStore получают его через DI в ChappieViewModel.
//
// СХЕМА SWIFTDATA:
// - ThreadEntity: треды с историей сообщений и настройками
// - ProjectEntity: проекты с security-scoped bookmarks
// - MemoryEntity: трёхуровневая память (global/project/thread)

import SwiftUI
import AppKit
import ChappieCore
import SwiftData

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    /// AppDelegate нужен для перехвата applicationWillTerminate —
    /// SwiftUI не предоставляет нативного способа выполнить код при завершении приложения.
    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - SwiftData Container

    /// Контейнер SwiftData для всего приложения.
    ///
    /// ПОЧЕМУ ЗДЕСЬ, А НЕ В VIEWMODEL:
    /// ModelContainer — это "база данных" приложения. Она должна жить на уровне App,
    /// а не ViewModel, чтобы гарантировать единственный экземпляр на всё время жизни приложения.
    /// Создание нескольких ModelContainer для одной схемы приводит к конфликтам и потере данных.
    ///
    /// ОБРАБОТКА ОШИБОК:
    /// Если контейнер не удаётся создать — это критическая ошибка (повреждена БД).
    /// В этом случае пробуем пересоздать с нуля (deleteExistingFile: true).
    /// Это потеря данных, но лучше чем полный крэш приложения.
    let modelContainer: ModelContainer = {
        // Схема включает все три SwiftData-модели из REFACTOR-THREADS IT-01
        let schema = Schema([
            ThreadEntity.self,
            ProjectEntity.self,
            MemoryEntity.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            // isStoredInMemoryOnly: false — данные сохраняются на диск (стандартное поведение)
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Первая попытка не удалась — пробуем пересоздать (удалить повреждённую БД)
            print("[ChappieApp] ⚠️ Не удалось создать ModelContainer: \(error)")
            print("[ChappieApp] 🔄 Пробуем пересоздать базу данных...")

            // ВНИМАНИЕ: deleteExistingFile = true уничтожит все данные!
            // Это последний резорт при повреждении базы данных.
            let recoveryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            do {
                return try ModelContainer(for: schema, configurations: [recoveryConfig])
            } catch {
                // Если и это не помогло — крэш неизбежен
                fatalError("[ChappieApp] ❌ Критическая ошибка: невозможно создать ModelContainer: \(error)")
            }
        }
    }()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Передаём ModelContainer в SwiftUI-окружение.
        // Все @Query и @Environment(\.modelContext) в дочерних View получат его автоматически.
        // ChappieViewModel получает его через DI (передаётся в ContentView).
        .modelContainer(modelContainer)
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
