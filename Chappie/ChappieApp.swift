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
// STORAGE ARCHITECTURE:
// SQLiteStorage (GRDB) is the sole persistence backend.
// ChappieDataStore (SwiftData) and MigrationService have been removed.
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
import Sparkle

@main
struct ChappieApp: App {

    // MARK: - App Delegate

    @NSApplicationDelegateAdaptor(ChappieAppDelegate.self) var appDelegate

    // MARK: - View Model

    @State private var viewModel = ChappieViewModel()

    // MARK: - Sparkle

    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .environment(viewModel)
                .environment(\.sparkleUpdater, updaterController.updater)
                .background(
                    Image("Chappie")
                        .resizable()
                        .scaledToFill()
                        .background(.black)
                        .opacity(0.5)
                        .ignoresSafeArea()
                )
                .background(TerminalWindowController(terminal: viewModel.terminal))
                .onAppear {
                    viewModel.bootStorage()
                }
        }
        .defaultSize(width: 480, height: 600)
        .defaultPosition(.center)

        Settings {
            EmptyView()
        }

        // Live terminal window — opened/closed via TerminalWindowController reacting
        // to TerminalLiveState.isActive. Separate NSWindow so it floats independently
        // of the main chat window and doesn't disturb its layout.
        Window("Terminal", id: "terminal-live") {
            TerminalLiveView(terminal: viewModel.terminal)
        }
        .defaultSize(width: 640, height: 380)
        .windowResizability(.contentSize)
    }
}

// MARK: - Sparkle Environment Key

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

final class ChappieAppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            MCPHelperLauncher.shared.terminateHelper()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
