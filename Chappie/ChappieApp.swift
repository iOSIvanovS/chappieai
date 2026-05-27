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
// SWIFTDATA (REFACTOR-THREADS IT-01):
// ModelContainer is created ONCE here and passed via .modelContainer()
// into the SwiftUI environment. This is standard SwiftData practice —
// a single container for the entire application.
//
// SWIFTDATA SCHEMA (IT-10 UPDATE):
// - ThreadEntity: threads with message history and settings
// - ProjectEntity: projects with security-scoped bookmarks
// - MemoryEntity: three-level memory (global/project/thread)
// - AIProviderEntity: AI provider configurations (IT-10, NEW)
//
// WINDOW SIZE:
// .defaultSize(width:height:) sets the initial window size on first launch.
// .defaultPosition(.center) ensures the window appears centered on screen.
// These are hints — the system may override them if the user has resized/moved.
//
// TRANSPARENT WINDOW:
// We make the NSWindow transparent in applicationDidFinishLaunching so that
// the background Image("Chappie") shows through BOTH the sidebar and the detail
// column — the system NSVisualEffectView backgrounds become see-through.
// window.backgroundColor = .clear + isOpaque = false is the only reliable way
// to achieve this on macOS without walking the NSView hierarchy.

import SwiftUI
import AppKit
import ChappieCore
import SwiftData

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - SwiftData Container

    /// SwiftData container for the entire application.
    ///
    /// WHY HERE, NOT IN VIEWMODEL:
    /// ModelContainer is the application's "database". It must live at the App level,
    /// not in ViewModel, to guarantee a single instance throughout the app's lifetime.
    /// Creating multiple ModelContainers for the same schema causes conflicts and data loss.
    ///
    /// ERROR HANDLING:
    /// If the container cannot be created — this is a critical error (corrupted DB).
    /// In this case we try to recreate from scratch (deleteExistingFile: true).
    /// This means data loss, but it's better than a full app crash.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            ThreadEntity.self,
            ProjectEntity.self,
            MemoryEntity.self,
            AIProviderEntity.self
        ])

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("[ChappieApp] Failed to create ModelContainer: \(error)")
            print("[ChappieApp] Attempting to recreate database...")

            let recoveryConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: true
            )

            do {
                return try ModelContainer(for: schema, configurations: [recoveryConfig])
            } catch {
                fatalError("[ChappieApp] Critical: cannot create ModelContainer: \(error)")
            }
        }
    }()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
        // Initial window size — reasonable default for the split-view layout
        .defaultSize(width: 1100, height: 720)
        // Center the window on first launch
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

    /// Make all app windows transparent so the background image shows through
    /// both the sidebar and the detail column.
    ///
    /// WHY THIS APPROACH:
    /// NavigationSplitView renders each column with a system NSVisualEffectView.
    /// Setting window.backgroundColor = .clear + isOpaque = false causes the
    /// system to composite those effect views against the transparent window
    /// background, making the SwiftUI .background() image visible beneath them.
    /// This is cleaner than walking the NSView hierarchy from SwiftUI.
    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindowsTransparent()
    }

    /// Also handle windows that open after launch (e.g. restored windows).
    func applicationDidBecomeActive(_ notification: Notification) {
        makeWindowsTransparent()
    }

    private func makeWindowsTransparent() {
        for window in NSApplication.shared.windows {
            window.backgroundColor = .clear
            window.isOpaque = false
        }
    }

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
