// WelcomeService.swift
// ChappieCore
//
// Generates a live AI greeting for a newly created thread.
//
// WHY: Static welcome placeholders are impersonal and identical across all threads.
// A live greeting from the active model makes each thread feel alive from the first frame.
//
// DESIGN:
// - Single non-streaming request — short, fast, no tool loop needed.
// - Result is saved as the first assistant message in thread history.
// - appLanguage is optional — when nil, model replies in its default language.
//   TODO: wire AppSettings.appLanguage here when i18n lands.
// - On any error (network, timeout, no provider) — silently skips the greeting.
//   The thread opens cleanly; no error shown to the user.

import Foundation

public struct WelcomeService: Sendable {

    // MARK: - Public API

    /// Sends a short greeting request to the AI and returns the response text.
    ///
    /// - Parameters:
    ///   - client: The AIClient configured for the active provider + model.
    ///   - appLanguage: BCP-47 language tag (e.g. "ru", "en"). Nil = model decides.
    /// - Returns: Greeting text, or nil if the request failed or was cancelled.
    public static func generateGreeting(
        using client: AIClient,
        appLanguage: String? = nil
    ) async -> String? {
        let languageInstruction: String
        if let lang = appLanguage {
            // Explicit language instruction so the greeting matches the app locale.
            // TODO: replace "ru" hardcode with AppSettings.appLanguage when i18n lands.
            languageInstruction = " Reply in language code: \(lang). Your reply MUST be in that language."
        } else {
            languageInstruction = ""
        }

        let systemPrompt = """
        You are a friendly AI assistant starting a new conversation.
        Introduce yourself briefly and greet the user warmly.
        Keep it to 1–2 sentences. Be natural, not robotic.\(languageInstruction)
        """

        do {
            let result = try await client.sendRequest(
                systemPrompt: systemPrompt,
                chatHistory: [],
                tools: []
            )
            let text = result.message.contentString?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return nil }
            return text
        } catch {
            // Greeting is best-effort — any failure is silent.
            print("[WelcomeService] Greeting skipped: \(error.localizedDescription)")
            return nil
        }
    }
}
