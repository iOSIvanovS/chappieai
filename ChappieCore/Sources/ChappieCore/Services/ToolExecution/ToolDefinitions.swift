// ToolDefinitions.swift
// ChappieCore
//
// WHY THIS FILE:
// All AITool definitions exposed to the AI model.
// Separated from execution logic to keep tool metadata easy to scan and update.
//
// TOOL ORDER MATTERS: LLMs tend to reach for tools listed first.
// Specialized tools (file system, memory, git, build) are listed before run_terminal.
// run_terminal is intentionally last — it is the tool of last resort.

import Foundation

extension ToolExecutionService {

    /// Full list of tools available to the AI agent.
    public var availableTools: [AITool] {
        return [
            // MARK: - File system

            AITool(function: AIFunctionDefinition(
                name: "list_files",
                description: "Получить список всех файлов в проекте (относительные пути).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_file",
                description: "Прочитать содержимое файла в проекте.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "write_file",
                description: "Создать новый или полностью перезаписать существующий файл (подпапки создадутся автоматически).",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к файлу"),
                        "content": AIToolProperty(type: "string", description: "Полный код или текст для записи в файл")
                    ],
                    required: ["path", "content"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_file",
                description: "Удалить файл из проекта.",
                parameters: AIToolParameters(
                    properties: [
                        "path": AIToolProperty(type: "string", description: "Относительный путь к удаляемому файлу")
                    ],
                    required: ["path"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "web_fetch",
                description: """
                Загрузить веб-страницу по URL и вернуть её текстовое содержимое (без HTML-разметки).
                Используй для получения документации, статей, GitHub-страниц и любых публичных веб-ресурсов.
                Шум (nav, header, footer, рекламные блоки) автоматически удаляется — остаётся только смысловой контент.
                Лимит: 100 000 символов после очистки. Если страница больше — контент обрезается с конца с пометкой.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "url": AIToolProperty(type: "string", description: "Абсолютный URL страницы (http или https)."),
                        "selector": AIToolProperty(type: "string", description: "Опциональный CSS-селектор для извлечения конкретного блока: имя тега ('article'), '.class-name' или '#element-id'. Если не указан — обрабатывается вся страница.")
                    ],
                    required: ["url"]
                )
            )),

            // MARK: - Long-term memory (IT-08)

            AITool(function: AIFunctionDefinition(
                name: "memorize",
                description: """
                Запомнить важную информацию, договоренность, факт или правило в долгосрочную память.
                Используй scope для выбора уровня:
                  scope="global" — глобальная память (кросс-проектные правила, факты о пользователе).
                  scope="thread" — память активного треда (контекст текущей задачи).
                  targetName="ProjectName" — память конкретного проекта (архитектура, пайплайны).
                Если scope и targetName не заданы — сохраняется в глобальную память.
                IMPORTANT: ALL fields (key, type, jsonString) MUST be in English. Cyrillic is REJECTED.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Unique key/topic for memorization (English only)"),
                        "type": AIToolProperty(type: "string", description: "Data type (e.g.: rule, fact, persona, project_map) (English only)"),
                        "jsonString": AIToolProperty(type: "string", description: "Data in JSON string format (English only)"),
                        "scope": AIToolProperty(type: "string", description: "Scope: global (default) or thread"),
                        "targetName": AIToolProperty(type: "string", description: "Name of a specific project attached to the thread (e.g., Chappie or ChappieCore) to save memory strictly in that project")
                    ],
                    required: ["key", "type", "jsonString"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "recall",
                description: """
                Вспомнить информацию из долгосрочной памяти по ключу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема, который нужно вспомнить"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для поиска памяти строго в этом проекте")
                    ],
                    required: ["key"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "search_memory",
                description: """
                Найти все записи в памяти по определенному типу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "type": AIToolProperty(type: "string", description: "Тип данных для поиска (например: rule, fact)"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для поиска памяти строго в этом проекте")
                    ],
                    required: ["type"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "delete_memory",
                description: """
                Удалить запись из долгосрочной памяти по ключу.
                Используй scope или targetName чтобы указать уровень памяти:
                  scope="global" — глобальная память.
                  scope="thread" — память активного треда.
                  targetName="ProjectName" — память конкретного проекта.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Уникальный ключ/тема для удаления"),
                        "scope": AIToolProperty(type: "string", description: "Область видимости: global (по умолчанию) или thread"),
                        "targetName": AIToolProperty(type: "string", description: "Имя конкретного проекта среди прикреплённых к треду для удаления памяти строго из этого проекта")
                    ],
                    required: ["key"]
                )
            )),

            // MARK: - Git tools

            AITool(function: AIFunctionDefinition(
                name: "git_status",
                description: "Показать текущий статус git-репозитория: изменённые, новые и удалённые файлы.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_diff",
                description: "Показать содержимое изменений в коде.",
                parameters: AIToolParameters(
                    properties: [
                        "staged": AIToolProperty(type: "string", description: "true — показать staged изменения (после git add), false — unstaged (по умолчанию)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_add",
                description: "Добавить файлы в staging area (подготовить к коммиту).",
                parameters: AIToolParameters(
                    properties: [
                        "paths": AIToolProperty(type: "string", description: "Пути через пробел, или '.' для всех файлов (по умолчанию '.')")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_commit",
                description: "Создать git-коммит с заданным сообщением.",
                parameters: AIToolParameters(
                    properties: [
                        "message": AIToolProperty(type: "string", description: "Текст коммита")
                    ],
                    required: ["message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_log",
                description: "Показать историю последних коммитов.",
                parameters: AIToolParameters(
                    properties: [
                        "count": AIToolProperty(type: "string", description: "Количество коммитов (по умолчанию 10)")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_reset",
                description: "Убрать все файлы из staging area (git reset HEAD).",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_revert",
                description: """
                Откатить один или несколько коммитов через git revert.
                Все изменения собираются в один чистый коммит с заданным сообщением.
                Используй когда нужно отменить конкретные коммиты не удаляя их из истории.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "hashes": AIToolProperty(type: "string", description: "Хэши коммитов через пробел, которые нужно откатить (например: 'abc123 def456')"),
                        "message": AIToolProperty(type: "string", description: "Сообщение для результирующего коммита отката")
                    ],
                    required: ["hashes", "message"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "git_checkout",
                description: """
                Восстановить конкретные файлы из заданного коммита или ветки.
                Используй для хирургического отката отдельных файлов без затрагивания остального кода.
                Примеры ref: HEAD~1, abc123, main
                """,
                parameters: AIToolParameters(
                    properties: [
                        "ref": AIToolProperty(type: "string", description: "Коммит, ветка или относительная ссылка (например: HEAD~1, abc123, main)"),
                        "paths": AIToolProperty(type: "string", description: "Пути к файлам через пробел для восстановления")
                    ],
                    required: ["ref", "paths"]
                )
            )),

            // MARK: - Build & test tools

            AITool(function: AIFunctionDefinition(
                name: "build_project",
                description: "Собрать проект Chappie.xcodeproj через xcodebuild. Возвращает успех или список ошибок компиляции.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            AITool(function: AIFunctionDefinition(
                name: "run_tests",
                description: "Запустить автотесты. Для ChappieCore используется swift test, для Chappie.app — xcodebuild test.",
                parameters: AIToolParameters(
                    properties: [
                        "target": AIToolProperty(type: "string", description: "Имя тест-таргета (например 'ChappieCoreTests'). Пусто = все тесты.")
                    ],
                    required: []
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "read_build_log",
                description: "Прочитать полный лог последней сборки или запуска тестов.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // MARK: - Project management (IT-07)

            AITool(function: AIFunctionDefinition(
                name: "add_project_to_thread",
                description: "Добавить проект к текущему треду по имени папки. Используй когда пользователь просит привязать проект к беседе или когда задача явно относится к конкретному проекту.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Отображаемое имя проекта (имя папки). Например: 'Chappie', 'MyApp', 'Backend'. Должно совпадать с реальным именем папки проекта."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "remove_project_from_thread",
                description: "Убрать проект из текущего треда по имени. Используй когда пользователь просит убрать проект из беседы или задача больше не касается этого проекта.",
                parameters: AIToolParameters(
                    properties: [
                        "display_name": AIToolProperty(
                            type: "string",
                            description: "Отображаемое имя проекта для удаления из треда. Должно точно совпадать с именем добавленного проекта."
                        )
                    ],
                    required: ["display_name"]
                )
            )),

            AITool(function: AIFunctionDefinition(
                name: "list_thread_projects",
                description: "Показать список проектов, привязанных к текущему треду. Используй чтобы узнать какие проекты уже добавлены перед add/remove операциями.",
                parameters: AIToolParameters(properties: [:], required: [])
            )),

            // MARK: - Terminal (LAST RESORT)
            // WHY LAST: run_terminal is a universal hammer — it can do anything.
            // That's exactly why it must be the last option, not the first.
            // Always prefer specialized tools: list_files/read_file for navigation,
            // git_* for version control, build_project/run_tests for builds.
            // Use run_terminal ONLY when no specialized tool exists for the task.

            AITool(function: AIFunctionDefinition(
                name: "run_terminal",
                description: """
                Выполнить команду в терминале в рабочей директории проекта.
                Сессия персистентна — команда cd запоминается между вызовами.
                ТОЛЬКО КОГДА НЕТ СПЕЦИАЛИЗИРОВАННОГО ИНСТРУМЕНТА: для навигации по файлам используй list_files/read_file; для git — git_* инструменты; для сборки — build_project/run_tests.
                Используй run_terminal для: запуска скриптов, установки зависимостей, CLI-утилит, и операций без специального инструмента.
                ВАЖНО: если режим 'С подтверждением' — СНАЧАЛА спроси пользователя с точным описанием команды и причины, потом вызывай инструмент.
                Опасные команды (rm -rf /, sudo rm, mkfs и др.) заблокированы безусловно.
                """,
                parameters: AIToolParameters(
                    properties: [
                        "command": AIToolProperty(type: "string", description: "Shell-команда для выполнения."),
                        "timeout": AIToolProperty(type: "string", description: "Таймаут в секундах (по умолчанию 30). Увеличь для долгих операций (сборка, npm install).")
                    ],
                    required: ["command"]
                )
            ))
        ]
    }
}
