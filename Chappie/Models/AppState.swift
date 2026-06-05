// AppState.swift
// Chappie
//
// Single source of truth for app-level launch flags.
//
// LAUNCH SEQUENCE:
// 1. shouldShowEULA — shown on very first launch, blocks everything until accepted.
// 2. shouldShowOnboarding — shown after EULA, until provider is configured.
// 3. Main app — shown when both flags are cleared.
//
// WHY UserDefaults, NOT SwiftData:
//   These flags must be readable before ModelContainer is ready (cold start).
//   SwiftData is async — launch decisions must be synchronous.
//
// WHY STORED PROPERTY + DIDSET, NOT COMPUTED PROPERTY:
//   @Observable tracks stored properties via _$observationRegistrar.
//   Computed properties that read UserDefaults are invisible to the observation system —
//   SwiftUI will not re-render when UserDefaults changes.
//   Solution: store the value as a regular Bool, sync to UserDefaults in didSet.
//   init() reads UserDefaults once to populate the initial value.

import Foundation
import Observation

@Observable
final class AppState {

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Keys

    private enum Keys {
        static let onboardingCompleted = "onboardingCompleted"
        static let eulaAccepted = "eulaAccepted"
    }

    // MARK: - EULA State

    /// True once the user has accepted the EULA.
    /// Shown exactly once — on the very first launch.
    var eulaAccepted: Bool {
        didSet { UserDefaults.standard.set(eulaAccepted, forKey: Keys.eulaAccepted) }
    }

    /// True when EULA screen should be shown (blocks onboarding and main app).
    var shouldShowEULA: Bool { !eulaAccepted }

    /// Called when user taps "Accept" in EULAView.
    func acceptEULA() {
        eulaAccepted = true
    }

    /// Reset EULA — forces re-show on next render (accessible from Settings for review).
    func resetEULA() {
        eulaAccepted = false
    }

    // MARK: - Onboarding State

    /// True once the user has completed onboarding at least once.
    /// Backed by UserDefaults — synced in didSet so @Observable can track changes.
    var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// In-memory flag — not persisted, resets on app relaunch.
    /// Set to true to force onboarding regardless of onboardingCompleted.
    var debugForceOnboarding: Bool = false

    /// True when onboarding screen should be shown.
    var shouldShowOnboarding: Bool {
        debugForceOnboarding || !onboardingCompleted
    }

    /// Mark onboarding as done. Called at the end of OnboardingView flow.
    func completeOnboarding() {
        debugForceOnboarding = false
        onboardingCompleted = true
    }

    /// Reset onboarding state — forces re-show on next render.
    /// Does NOT delete any providers, threads, or models.
    func resetOnboarding() {
        onboardingCompleted = false
        debugForceOnboarding = false
    }

    // MARK: - Init

    private init() {
        self.eulaAccepted = UserDefaults.standard.bool(forKey: Keys.eulaAccepted)
        self.onboardingCompleted = UserDefaults.standard.bool(forKey: Keys.onboardingCompleted)
    }
}
