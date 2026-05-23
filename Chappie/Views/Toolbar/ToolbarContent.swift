//
//  ToolbarContent.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Контент тулбара (баланс + кнопка настроек) был вшит прямо в ContentView.
//  Вынесен в отдельный ViewModifier, чтобы:
//  1. ContentView оставался чистым и читаемым
//  2. Тулбар можно было легко расширять (добавить кнопку очистки истории и т.д.)
//  3. Логика цвета иконки шестерёнки была в одном месте
//

import SwiftUI

/// Контент тулбара главного окна Чаппи.
///
/// Содержит:
/// - Индикатор текущего баланса (если загружен)
/// - Кнопку настроек ⚙️ (оранжевая если API-ключ не задан)
struct ChappieToolbarContent: ToolbarContent {
    
    /// Текущий баланс в рублях (nil если ещё не загружен)
    let balance: Double?
    
    /// Флаг: задан ли валидный API-ключ.
    /// Если нет — шестерёнка становится оранжевой, привлекая внимание.
    let isApiKeyValid: Bool
    
    /// Коллбэк: пользователь нажал кнопку настроек
    let onOpenSettings: () -> Void
    
    var body: some ToolbarContent {
        // Баланс — показываем только если он загружен.
        // Не показываем "0 ₽" при старте — это вводит в заблуждение.
        if let balance = balance {
            ToolbarItem(placement: .primaryAction) {
                balanceView(balance: balance)
            }
        }
        
        // Кнопка настроек — всегда видна.
        // Меняет цвет в зависимости от состояния API-ключа.
        ToolbarItem(placement: .primaryAction) {
            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gear")
            }
            .help("Настройки Чаппи")
            // ВИЗУАЛЬНЫЙ СИГНАЛ: если ключ не задан — шестерёнка оранжевая.
            // Это мягкое, но заметное напоминание без агрессивных алертов.
            .foregroundStyle(
                isApiKeyValid
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(.orange)
            )
        }
    }
    
    // MARK: - Вспомогательные вью
    
    /// Таблетка с балансом в тулбаре.
    /// Оформлена как "пилюля" с иконкой кредитной карты и суммой.
    private func balanceView(balance: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "creditcard.fill")
                .foregroundColor(.green)
            Text(String(format: "%.2f ₽", balance))
                .font(.subheadline.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
    }
}
