//
//  AppConfig.swift
//  ChappieCore
//

import Foundation

/// Глобальные настройки приложения
public struct AppConfig: Sendable {
    public static let shared = AppConfig()
    
    /// Максимальное количество сообщений в истории (контекст)
    public let maxHistoryMessages: Int
    
    /// Максимальное количество шагов оркестратора
    public let maxOrchestratorSteps: Int
    
    private init() {
        self.maxHistoryMessages = 15
        self.maxOrchestratorSteps = 20
    }
}
