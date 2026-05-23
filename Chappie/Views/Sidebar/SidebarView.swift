//
//  SidebarView.swift
//  Chappie
//
//  ПОЧЕМУ ЭТОТ ФАЙЛ СУЩЕСТВУЕТ:
//  Сайдбар — логически самостоятельная часть интерфейса.
//  Он отображает контекст (воркспейс, предупреждения) и предоставляет действия
//  (выбор папки, открытие настроек). Вынесен из ContentView для ясности структуры.
//

import SwiftUI

/// Боковая панель приложения Чаппи.
///
/// Показывает:
/// - текущий воркспейс (или кнопку выбора если не выбран)
/// - предупреждение если API-ключ не задан
///
/// Все действия (выбор папки, открытие настроек) передаются через коллбэки,
/// чтобы сайдбар оставался "тупым" компонентом без бизнес-логики.
struct SidebarView: View {
    
    /// URL текущего выбранного воркспейса (nil если не выбран)
    let workspaceURL: URL?
    
    /// Флаг: задан ли валидный API-ключ.
    /// Если нет — показываем предупреждение с кнопкой настроек.
    let isApiKeyValid: Bool
    
    /// Коллбэк: пользователь хочет выбрать папку проекта
    let onSelectWorkspace: () -> Void
    
    /// Коллбэк: пользователь хочет открыть настройки
    let onOpenSettings: () -> Void
    
    var body: some View {
        List {
            workspaceSection
            
            // Предупреждение показываем только если ключ не задан.
            // Не хотим раздражать пользователя когда всё в порядке.
            if !isApiKeyValid {
                apiKeyWarningSection
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Чаппи")
    }
    
    // MARK: - Секции
    
    /// Секция с информацией о текущем воркспейсе.
    /// Если воркспейс выбран — показываем имя папки и кнопку смены.
    /// Если нет — показываем кнопку выбора.
    private var workspaceSection: some View {
        Section("Контекст") {
            if let workspaceURL = workspaceURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Рабочая папка:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workspaceURL.lastPathComponent)
                        .font(.headline)
                }
                
                Button("Сменить папку...") {
                    onSelectWorkspace()
                }
                .buttonStyle(.link)
                .padding(.top, 4)
                
            } else {
                Button("Выбрать папку проекта...") {
                    onSelectWorkspace()
                }
            }
        }
    }
    
    /// Секция-предупреждение об отсутствии API-ключа.
    /// Показывается только когда ключ не задан или невалиден.
    /// Содержит прямую кнопку открытия настроек — минимум шагов для исправления.
    private var apiKeyWarningSection: some View {
        Section("⚠️ Внимание") {
            VStack(alignment: .leading, spacing: 8) {
                Text("API-ключ не задан")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                
                Text("Без ключа AITunnel Чаппи не сможет отвечать.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Button("Открыть настройки") {
                    onOpenSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView(
            workspaceURL: URL(fileURLWithPath: "/Users/sergej/Projects/Chappie"),
            isApiKeyValid: false,
            onSelectWorkspace: {},
            onOpenSettings: {}
        )
    } detail: {
        Text("Detail")
    }
}
