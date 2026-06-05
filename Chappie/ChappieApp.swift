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
// .defaultSize(width:height:) sets the initial window size on first launch (EULA screen).
// 480×600 fits all Mac screens and looks like a focused dialog, not a full app.
// After the user accepts EULA they can freely resize — macOS remembers the last size/position.
//
// BACKGROUND IMAGE:
// Image("Chappie") is placed as .background on ContentView — NOT inside a GeometryReader.
// WHY: GeometryReader inside WindowGroup is greedy in horizontal direction and prevents
// the window from being resized narrower than its initial width. Using .background()
// with .ignoresSafeArea() achieves the same full-window coverage without layout side effects.
//
// SPARKLE AUTO-UPDATE:
// SPUStandardUpdaterController is created at app level and stored in AppDelegate.
// SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks are set in Info.plist.
// Auto-check on launch is handled by Sparkle itself (SUEnableAutomaticChecks = YES).
// Manual "Check for Updates" button in SettingsView calls updaterController.updater.checkForUpdates().

import SwiftUI
import AppKit
import ChappieCore
import SwiftData
import Sparkle

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - View Model

    @State private var viewModel = ChappieViewModel()

    // MARK: - Sparkle

    // Sparkle updater controller — lives for the entire app lifetime.
    // WHY @State: ensures single instance across SwiftUI re-renders.
    private let updaterController: SPUStandardUpdaterController

    init() {
        // startingUpdater: true — Sparkle starts immediately and auto-checks on launch
        // (controlled by SUEnableAutomaticChecks in Info.plist).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

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
                .environment(viewModel)
                // Pass updater into environment so SettingsView can trigger manual checks.
                .environment(\.sparkleUpdater, updaterController.updater)
                .onAppear {
                    viewModel.setModelContainer(modelContainer)
                }
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
        // 480×600 — compact dialog size for EULA on first launch.
        // After acceptance the user freely resizes; macOS remembers the last size/position.
        .defaultSize(width: 480, height: 600)
        .defaultPosition(.center)
        .commands {
            // Standard macOS commands (Quit, Minimize, etc.)
        }

        Settings {
            EmptyView()
        }
    }
}

// MARK: - Sparkle Environment Key

// Custom EnvironmentKey to pass SPUUpdater down the view hierarchy.
// WHY: avoids passing updaterController manually through every view init.
private struct SparkleUpdaterKey: EnvironmentKey {
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    var sparkleUpdater: SPUUpdater? {
        get { self[SparkleUpdaterKey.self] }
        set { self[SparkleUpdaterKey.self] = newValue }
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
