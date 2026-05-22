# ChappieCore Project Map

Структура локального SPM-пакета (ядра приложения).

- `Package.swift`: Манифест пакета, определяет зависимости и платформы (macOS 13+).
- `Sources/ChappieCore/`:
  - `ChappieCore.swift`: Точка входа/экспорта библиотеки.
  - `Models/`:
    - `AITunnelModels.swift`: DTO и структуры данных для работы с API (сообщения, тулзы).
    - `AppConfig.swift`: Глобальные настройки ядра (лимиты истории, шагов оркестратора).
    - `ChappieError.swift`: Глобальный обработчик ошибок (кастомные ошибки приложения).
  - `Services/`:
    - `AITunnelClient.swift`: Сетевой клиент для общения с LLM API.
    - `AIOrchestrator.swift`: Оркестратор ИИ-агента (управляет циклом общения, вызывает инструменты).
    - `ChatHistoryManager.swift`: Менеджер для локального хранения и миграции истории чата в формате JSON.
    - `FileSystemManager.swift`: Инструменты для чтения, записи и удаления файлов.
    - `MemoryManager.swift`: Инструменты для работы с долгосрочной памятью (сохранение, поиск).
    - `ToolExecutionService.swift`: Реестр доступных инструментов и логика их выполнения (роутинг команд от LLM к менеджерам).
- `AI_Docs/`:
  - `project_map.md`: Эта карта файлов.
  - `architecture.md`: Схема архитектуры ядра на Mermaid.