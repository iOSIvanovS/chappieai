// ChappieViewModel+ThreadGreeting.swift
// Chappie
//
// Static welcome greeting: insert on new thread creation, localized per device language.

import SwiftUI
import ChappieCore

extension ChappieViewModel {

    // MARK: - Welcome Greeting

    /// Inserts a static localized greeting as the first assistant message.
    ///
    /// WHY STATIC: AI-generated greetings cause 5–10 s delays on slow models (Gemini
    /// spends time "thinking" even on a trivial prompt). A static string is instant,
    /// deterministic, and fully localized — no network round-trip needed.
    ///
    /// WHY CALLED FROM _syncTask: must run after loadMessages() sets self.messages = loaded,
    /// otherwise the loaded empty array would overwrite the greeting.
    func insertStaticWelcomeGreeting(for thread: ThreadMetadata) async {
        guard let store = threadStore else { return }
        guard activeThread?.id == thread.id, messages.isEmpty else { return }

        let greeting = Self.localizedWelcomeGreeting()
        let greetingMessage = ChatMessage.message(isUser: false, text: greeting)

        messages.append(greetingMessage)
        appendToDisplayed(greetingMessage)

        try? await store.saveMessages(messages, toThreadId: thread.id)
        print("[ChappieViewModel] Static welcome greeting inserted for thread '\(thread.title)'")
    }

    /// Returns a greeting string for the current device language.
    /// Falls back to English for any unsupported language code.
    static func localizedWelcomeGreeting() -> String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let greetings: [String: String] = [
            "en": "Hi! I'm your AI assistant. How can I help you today?",
            "ru": "Привет! Я ваш AI-ассистент. Чем могу помочь?",
            "de": "Hallo! Ich bin Ihr KI-Assistent. Wie kann ich Ihnen helfen?",
            "fr": "Bonjour ! Je suis votre assistant IA. Comment puis-je vous aider ?",
            "es": "¡Hola! Soy tu asistente de IA. ¿En qué puedo ayudarte?",
            "pt": "Olá! Sou seu assistente de IA. Como posso ajudar?",
            "ar": "مرحباً! أنا مساعدك الذكي. كيف يمكنني مساعدتك؟",
            "zh": "你好！我是你的 AI 助手。有什么我可以帮你的吗？",
            "ja": "こんにちは！AIアシスタントです。何かお手伝いできますか？",
            "hi": "नमस्ते! मैं आपका AI सहायक हूँ। मैं आपकी कैसे मदद कर सकता हूँ?"
        ]
        return greetings[lang] ?? greetings["en"]!
    }
}
