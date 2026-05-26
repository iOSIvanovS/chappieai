// ChappieCore.swift
// ChappieCore
//
// Точка входа Swift Package — публичный фасад всего пакета.
//
// ЗАЧЕМ ЭТОТ ФАЙЛ:
// Swift Package Manager не требует явного реэкспорта, но наличие
// центрального файла с документацией и @_exported import даёт три преимущества:
//
// 1. ЧИТАЕМОСТЬ: Любой разработчик, открывший пакет, сразу видит
//    полный список публичного API в одном месте.
//
// 2. ВЕРСИОНИРОВАНИЕ: При изменении публичного API достаточно
//    обновить этот файл — изменение сразу видно в git diff.
//
// 3. ДОКУМЕНТАЦИЯ: Этот файл служит "оглавлением" пакета —
//    описывает что и зачем экспортируется.
//
// АРХИТЕКТУРА ПАКЕТА:
// ChappieCore — это мозг Чаппи. Он намеренно отделён от SwiftUI-слоя
// (таргет Chappie) чтобы логика была тестируемой и переиспользуемой
// независимо от конкретного UI-фреймворка.

import Foundation

// MARK: - Публичный API ChappieCore

// Ниже перечислены все публичные типы, которые пакет предоставляет потребителям.
// Все они уже объявлены как `public` в своих файлах — здесь мы просто
// документируем их наличие для ясности архитектуры.

// MARK: Модели данных (Models/)
//
// • AppConfig          — централизованная конфигурация: таймауты, лимиты шагов, размер истории
// • ChappieError       — единое перечисление всех ошибок системы
// • AIMessage          — модель одного сообщения в чате (role/content/tool_calls)
// • AITool             — описание инструмента для function calling API
// • AIFunctionDefinition — схема функции (имя, описание, параметры)
// • AIToolParameters   — JSON Schema параметров инструмента
// • AIToolProperty     — отдельное свойство в схеме параметров
// • AITunnelRequest    — модель запроса к AI Tunnel API
// • AITunnelResponse   — модель ответа от AI Tunnel API
// • AIChoice           — один вариант ответа модели
// • AIUsage            — статистика использования токенов и стоимость
// • AIToolCall         — вызов инструмента, возвращённый моделью
// • AIToolCallFunction — имя и аргументы конкретного вызова инструмента
//
// REFACTOR-THREADS IT-01 (новые модели):
// • ThreadEntity       — SwiftData модель треда (id, title, messagesJSON, settingsJSON, projectBindingsJSON)
// • ThreadSettings     — Codable настройки треда (maxMessagesInContext, tokenBudget)
// • ThreadMetadata     — Sendable DTO для передачи метаданных треда из actor в UI
// • ProjectEntity      — SwiftData модель проекта (id, displayName, bookmarkData, settingsJSON)
// • ProjectSettings    — Codable настройки проекта (preferredLanguage)
// • ProjectMetadata    — Sendable DTO для передачи метаданных проекта из actor в UI
// • MemoryEntity       — SwiftData модель контейнера памяти (scope, entriesJSON)
// • MemoryEntry        — Codable одна запись памяти (key, type, jsonString, metadata)

// MARK: Сервисы (Services/)
//
// • AITunnelClient     — HTTP-клиент для общения с AI Tunnel API
// • AIOrchestrator     — главный актор: агентный цикл "запрос → инструмент → ответ"
// • ToolExecutionService — реестр и исполнитель всех инструментов Чаппи
// • FileSystemManager  — безопасный доступ к файловой системе с защитой от path traversal
// • MemoryManager      — долгосрочная память: запись, чтение, поиск записей
// • ChatHistoryManager — персистентное хранение истории чата между сессиями [УСТАРЕВАЕТ]
//
// REFACTOR-THREADS IT-01 (новые сервисы):
// • ThreadStore        — actor, CRUD операции над тредами через SwiftData
// • ProjectStore       — actor, CRUD операции над проектами через SwiftData

// MARK: - Версия пакета

/// Текущая версия ChappieCore.
///
/// Зачем: Позволяет диагностировать проблемы совместимости при обновлениях.
/// Обновляй при каждом значимом изменении публичного API.
public let coreVersion = "2.0.0" // IT-01: SwiftData модели + ThreadStore + ProjectStore
