import Foundation

/// Глобальные настройки приложения (чтобы избежать "магических чисел")
public struct AppConfig: Sendable {
    public static let shared = AppConfig()
    
    /// Максимальное количество сообщений, отправляемых в контексте
    public let maxHistoryMessages: Int
    
    /// Максимальное количество шагов в цикле оркестратора (защита от бесконечного цикла)
    public let maxOrchestratorSteps: Int
    
    private init() {
        self.maxHistoryMessages = 15
        self.maxOrchestratorSteps = 20
    }
}
