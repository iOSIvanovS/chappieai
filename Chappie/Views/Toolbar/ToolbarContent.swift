// ToolbarContent.swift
// Chappie
//
// ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
// Контент тулбара (баланс + кнопка настроек) был вшит прямо в ContentView.
// Вынесен в отдельный ViewModifier, чтобы:
// 1. ContentView оставался чистым и читаемым
// 2. Тулбар можно было легко расширять (добавить кнопку очистки истории и т.д.)
// 3. Логика цвета иконки шестерёнки была в одном месте
//
// ИЗМЕНЕНИЯ (UI-FIX-01):
// Добавлена кнопка воркспейса (папка проекта) в тулбар.
// ПОЧЕМУ ЗДЕСЬ, А НЕ В САЙДБАРЕ:
// Воркспейс — глобальная настройка приложения (один на всё приложение).
// Сайдбар посвящён тредам (навигация). Смешивать — неправильно.
// Тулбар — правильное место для глобальных действий/состояний.
//
// ДИЗАЙН КНОПКИ ВОРКСПЕЙСА:
// Показывает имя текущей папки (или "Нет папки" если не выбрана).
// При нажатии — открывает NSOpenPanel через коллбэк onSelectWorkspace.
// Иконка папки + имя — компактно и понятно.

import SwiftUI

/// Контент тулбара главного окна Чаппи.
///
/// Содержит:
/// - Кнопку выбора воркспейса (папка проекта) — UI-FIX-01
/// - Индикатор текущего баланса (если загружен)
/// - Кнопку настроек ⚙️ (оранжевая если API-ключ не задан)
struct ChappieToolbarContent: ToolbarContent {

    /// URL текущего выбранного воркспейса (nil если не выбран)
    let workspaceURL: URL?

    /// Текущий баланс в рублях (nil если ещё не загружен)
    let balance: Double?

    /// Флаг: задан ли валидный API-ключ.
    /// Если нет — шестерёнка становится оранжевой, привлекая внимание.
    let isApiKeyValid: Bool

    /// Коллбэк: пользователь нажал кнопку выбора воркспейса
    let onSelectWorkspace: () -> Void

    /// Коллбэк: пользователь нажал кнопку настроек
    let onOpenSettings: () -> Void

    var body: some ToolbarContent {

        // MARK: Кнопка воркспейса — слева в тулбаре (ведущий край)
        // ПОЧЕМУ .navigation:
        // placement .navigation ставит элемент рядом с кнопкой навигации (сайдбар).
        // Это логично — воркспейс связан с навигацией/контекстом проекта.
        ToolbarItem(placement: .navigation) {
            workspaceButton
        }

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

    // MARK: - Кнопка воркспейса

    /// Кнопка выбора/отображения текущего воркспейса.
    ///
    /// ДИЗАЙН:
    /// - Иконка папки + имя папки (или "Выбрать папку")
    /// - Компактный вид — не занимает много места в тулбаре
    /// - Тултип с полным путём если папка выбрана
    ///
    /// ПОЧЕМУ НЕ ПРОСТО ТЕКСТ:
    /// Кнопка даёт понять что это интерактивный элемент — можно сменить папку.
    /// Просто текст выглядел бы как метка, а не как контрол.
    private var workspaceButton: some View {
        Button(action: onSelectWorkspace) {
            HStack(spacing: 5) {
                Image(systemName: workspaceURL != nil ? "folder.fill" : "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(workspaceURL != nil ? Color.accentColor : .secondary)

                Text(workspaceURL?.lastPathComponent ?? "Выбрать папку")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(workspaceURL != nil ? .primary : .secondary)
                    .lineLimit(1)
                    // Ограничиваем ширину чтобы не занимал всю строку тулбара
                    .frame(maxWidth: 160, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        // Тултип: полный путь если выбран, подсказка если нет
        .help(workspaceURL?.path ?? "Выберите папку проекта для работы с файлами")
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
