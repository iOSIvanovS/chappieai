// AppState.swift
// Chappie
//
// Single source of truth for app-level launch flags.
//
// ONBOARDING TRIGGER LOGIC:
// showOnboarding = true when:
//   a) onboardingCompleted == false (first launch or key was reset)
//   b) debugForceOnboarding == true (in-memory override, survives only current session)
//
// WHY UserDefaults, NOT SwiftData:
//   This flag must be readable before ModelContainer is ready (cold start).
//   SwiftData is async — onboarding decision must be synchronous.
//
// WHY STORED PROPERTY + DIDSET, NOT COMPUTED PROPERTY:
//   @Observable tracks stored properties via _$observationRegistrar.
//   Computed properties that read UserDefaults are invisible to the observation system —
//   SwiftUI will not re-render when UserDefaults changes.
//   Solution: store the value as a regular Bool, sync to UserDefaults in didSet.
//   init() reads UserDefaults once to populate the initial value.
//
// DEBUG USAGE (in code):
//   AppState.shared.debugForceOnboarding = true   → forces onboarding on next render
//   AppState.shared.resetOnboarding()              → clears the key + forces onboarding
//
// SAFE RE-RUN:
//   Onboarding never deletes existing data. It only merges:
//   providers, keys, models. See merge rules in OnboardingView.

import Foundation
import Observation

@Observable
final class AppState {

    // MARK: - Singleton

    static let shared = AppState()

    // MARK: - Keys

    private enum Keys {
        static let onboardingCompleted = "onboardingCompleted"
    }

    // MARK: - Observable State

    /// True once the user has completed onboarding at least once.
    /// Backed by UserDefaults — synced in didSet so @Observable can track changes.
    var onboardingCompleted: Bool {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    /// In-memory flag — not persisted, resets on app relaunch.
    /// Set to true to force onboarding regardless of onboardingCompleted.
    var debugForceOnboarding: Bool = false

    // MARK: - Computed

    /// True when onboarding screen should be shown.
    var shouldShowOnboarding: Bool {
        debugForceOnboarding || !onboardingCompleted
    }

    // MARK: - Actions

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
        // Read persisted value once on startup
        self.onboardingCompleted = UserDefaults.standard.bool(forKey: Keys.onboardingCompleted)
    }
}
