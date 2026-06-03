// ChappieApp.swift
// Chappie
//
// Application entry point.
//
// HELPER LIFECYCLE:
// - ChappieMCP helper is NOT launched here on startup.
//   Reason: at startup we don't yet know the workspace path.
//   If launched without a path — the helper gets "/" as working directory,
//   and git/build commands fail with "not a git repository".
//
// - Helper is launched in ChappieViewModel:
//   a) loadWorkspaceWithSecurityScope() — when restoring saved workspace
//   b) setWorkspace() — when user manually selects a folder
//
// - applicationWillTerminate → terminateHelper() → helper terminates cleanly.
//   Without explicit termination the helper remains as an orphan process,
//   and the next bind() on the same socket fails with "address already in use".
//
// SWIFTDATA SCHEMA:
// - ThreadEntity: threads with message history and settings
// - ProjectEntity: projects with security-scoped bookmarks
// - MemoryEntity: three-level memory (global/project/thread)
// - AIProviderEntity: AI provider configurations
// - AppSettings: global settings (balance, last active thread, workspace bookmark)
//   Previously stored as "New.AppSettings" — AppSettingsMigrationPlan handles the rename.
//
// WINDOW SIZE:
// .defaultSize(width:height:) sets the initial window size on first launch.
// .defaultPosition(.center) ensures the window appears centered on screen.
// These are hints — the system may override them if the user has resized/moved.
//
// BACKGROUND IMAGE:
// Image("Chappie") is placed as .background on ContentView — NOT inside a GeometryReader.
// WHY: GeometryReader inside WindowGroup is greedy in horizontal direction and prevents
// the window from being resized narrower than its initial width. Using .background()
// with .ignoresSafeArea() achieves the same full-window coverage without layout side effects.

import SwiftUI
import AppKit
import ChappieCore
import SwiftData

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - View Model
    // Создаем экземпляр ViewModel для всего жизненного цикла приложения
    @State private var viewModel = ChappieViewModel()

    // MARK: - SwiftData Container

    /// SwiftData container for the entire application.
    ///
    /// WHY HERE, NOT IN VIEWMODEL:
    /// ModelContainer is the application's "database". It must live at the App level,
    /// not in ViewModel, to guarantee a single instance throughout the app's lifetime.
    /// Creating multiple ModelContainers for the same schema causes conflicts and data loss.
    ///
    /// MIGRATION:
    /// AppSettings was previously stored as "New.AppSettings" (namespace wrapper).
    /// AppSettingsMigrationPlan maps the old entity name to the new one on first launch.
    ///
    /// ERROR HANDLING:
    /// If the container cannot be created — this is a critical error (corrupted DB).
    /// In this case we try to recreate from scratch. This means data loss,
    /// but it's better than a full app crash.
    let modelContainer: ModelContainer = {
        let schema = Schema(AppSettingsSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: AppSettingsMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            print("[ChappieApp] Failed to create ModelContainer with migration: \(error)")
            print("[ChappieApp] Attempting to recreate database...")

            let recoveryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            do {
                return try ModelContainer(
                    for: schema,
                    migrationPlan: AppSettingsMigrationPlan.self,
                    configurations: [recoveryConfig]
                )
            } catch {
                fatalError("[ChappieApp] Critical: cannot create ModelContainer: \(error)")
            }
        }
    }()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Передаем ViewModel в окружение текущего окна
                .environment(viewModel)
                .onAppear {
                    // Подключаем базу данных (ModelContainer) к ViewModel при загрузке окна
                    viewModel.setModelContainer(modelContainer)
                }
                // Background image via .background — does NOT participate in layout,
                // does NOT affect window minimum size, covers full window including toolbar.
                .background(
                    Image("Chappie")
                        .resizable()
                        .scaledToFill()
                        .background(.black)
                        .opacity(0.5)
                        .ignoresSafeArea()
                )
        }
        .modelContainer(modelContainer)
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .commands {
            // Standard macOS commands (Quit, Minimize, etc.)
        }

        Settings {
            // Settings scene is intentionally minimal — main settings are in the sheet
            // opened from the toolbar gear button
            EmptyView()
        }
    }
}

// MARK: - App Delegate

/// Application delegate for handling macOS system events.
final class ChappieAppDelegate: NSObject, NSApplicationDelegate {

    /// Called by the system immediately before the application terminates.
    /// We kill the ChappieMCP child process here.
    ///
    /// WHY IMPORTANT:
    /// If we don't explicitly terminate the helper — it remains in memory as an orphan process.
    /// On the next app launch, bind() on the same socket fails with "address already in use".
    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            MCPHelperLauncher.shared.terminateHelper()
        }
    }

    /// Standard macOS behavior: closing the last window terminates the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
