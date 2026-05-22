# Chappie Project Map

Структура основного приложения (UI слой).

- `ChappieApp.swift`: Точка входа в приложение (App).
- `ContentView.swift`: Основной UI, отображение чата и списка сообщений.
- `ChappieViewModel.swift`: ViewModel, связывающая UI с ядром (`ChappieCore`). Управляет состоянием чата, отправляет запросы в ядро и обрабатывает ответы.
- `Assets.xcassets/`: Иконки и цвета приложения.
- `AI_Docs/`:
  - `project_map.md`: Эта карта файлов.
  - `architecture.md`: Схема архитектуры приложения на Mermaid.
