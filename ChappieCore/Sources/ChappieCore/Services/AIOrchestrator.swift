// AIOrchestrator.swift
// ChappieCore
//
// Главный управляющий компонент — оркестратор агентного цикла Чаппи.
//
// КЛЮЧЕВЫЕ АРХИТЕКТУРНЫЕ РЕШЕНИЯ:
//
// 1. МОНОФИЗИТНАЯ АРХИТЕКТУРА:
//    Чаппи работает один, без саб-агентов и делегирования. Вся ответственность
//    за код, архитектуру, верстку и рефакторинг лежит на одном агенте.
//    Причина: саб-агенты порождают хаос, несогласованность и дублирование контекста.
//
// 2. ЕДИНЫЙ СТРИМИНГОВЫЙ ЦИКЛ (ИСПРАВЛЕНИЕ ДВОЙНОГО ЗАПРОСА):
//    Старая стратегия "probe + stream" делала ДВА запроса для каждого финального ответа.
//    НОВАЯ СТРАТЕГИЯ: streamRequestWithTools() на каждый шаг цикла.
//    AITunnelClient накапливает tool_calls из SSE-дельт и возвращает AIStreamResult.
//    Если есть tool_calls → выполняем инструменты, продолжаем цикл.
//    Если tool_calls нет → это финальный ответ. ОДИН запрос на шаг.
//
// 3. PROMPT CACHING:
//    AITunnelClient автоматически добавляет cache_control к системному промпту
//    и последнему сообщению пользователя. Экономия: ~80-90% стоимости системного промпта.
//
// 4. SELF-SUMMARY:
//    Системный промпт содержит жёсткое правило: в конце каждого финального ответа
//    Чаппи ОБЯЗАН добавлять тег <summary>...</summary>.
//    При сборке контекстного окна длинные ответы заменяются на их summary.
//
// 5. УМНОЕ КОНТЕКСТНОЕ ОКНО (оптимизация стоимости):
//    Два уровня ограничений работают одновременно:
//    а) maxMessagesInContext — жёсткий лимит по количеству сообщений (из конфига треда).
//    б) tokenBudget — мягкий лимит по объёму токенов (вычисляется как maxMessages × 500).
//    Последние recentFullMessages (3) всегда отправляются полностью.
//    Более старые — заменяются на summary если доступен.
//
// 6. ИСПРАВЛЕНИЕ ЗАДВОЕНИЯ ПОСЛЕДНЕГО СООБЩЕНИЯ (баг):
//    buildContextWindow() принимает ИСТОРИЮ (без текущего запроса) и ОТДЕЛЬНО currentPrompt.
//    История содержит завершённые пары user/assistant. currentPrompt — новое сообщение.
//    ВАЖНО: история, переданная в buildContextWindow(), НЕ должна содержать текущий запрос.
//    Это обеспечивается в process(): мы передаём history (прошлые сообщения) и prompt (новый).
//    Задвоение возникало, когда последнее сообщение в history == prompt. Теперь исключаем
//    дубликаты: если последнее сообщение в истории совпадает с currentPrompt по тексту,
//    оно НЕ включается в контекстное окно.
//
// 7. ОЦЕНКА ТОКЕНОВ:
//    Формула estimateTokens() использует UTF-8 байты / 4 × 1.5.
//    Это даёт реалистичную оценку для смешанного русско-английского текста с кодом.
//
// 8. ОБЯЗАТЕЛЬНЫЙ ПАЙПЛАЙН ИЗМЕНЕНИЙ (железное правило):
//    Перед каждым изменением кода Чаппи ОБЯЗАН соблюдать строгий порядок:
//    1. git_status — проверить незакоммиченные изменения от прошлой сессии.
//    2. git_add + git_commit — CHECKPOINT коммит (точка отката).
//    3. write_file — внести изменения в код.
//    4. build_project — компиляция. Если упала — ЧИНИТЬ, не идти дальше.
//    5. run_tests — тесты ТОЛЬКО если сборка прошла. Если упали — ЧИНИТЬ, не идти дальше.
//    6. git_add + git_commit — RESULT коммит только если всё зелёное.
//    7. Сообщить пользователю что можно жать треугольник в Xcode.
//    ОТКАТ: если build/tests упали и быстро не чинится — предложить git reset --hard к checkpoint.
//    ЗАПРЕЩЕНО: git_diff (загружает весь проект в контекст, стоит сотни рублей).
//    ЗАПРЕЩЕНО: run_tests до build_project (двойная компиляция).
//    ЗАПРЕЩЕНО: финальный коммит если тесты или сборка не зелёные.
//
// 9. НАКОПИТЕЛЬНАЯ СТОИМОСТЬ (UX-RUNNING-COST):
//    Добавлен callback onCostUpdate — вызывается после каждого внутреннего API-запроса.
//    Передаёт накопленную стоимость нарастающим итогом (не стоимость одного шага!).
//    Это позволяет UI показывать цену в реальном времени прямо в стриминговом пузыре.
//
// 10. ДИНАМИЧЕСКИЙ КОНФИГ (IT-02, REFACTOR-THREADS):
//     process() теперь принимает config: AppConfig как параметр (с дефолтом AppConfig.shared).
//     Это позволяет разным тредам иметь разные параметры контекста.
//     ChappieViewModel создаёт AppConfig из настроек активного треда и передаёт его сюда.
//
// 11. ТРЁХУРОВНЕВАЯ ПАМЯТЬ В SYSTEM PROMPT (IT-03, IT-08, REFACTOR-THREADS):
//     process() принимает memoryContext: MemoryContext — описание треда и проектов.
//     Перед каждым запросом MemoryManager.buildSystemPrompt() собирает полный промпт
//     с подмешанной глобальной + проектной + тредовой памятью.
//     Захардкоженный systemPrompt остаётся как BASE_PROMPT — основа для buildSystemPrompt().
//
// 12. ЗАЩИТА ОТ ПЕТЕЛЬ (УМНАЯ, НЕ СЕССИОННАЯ):
//     Вместо блокировки любого повторного вызова за всю сессию — блокируем только
//     два ПОДРЯД идущих одинаковых вызова (один и тот же инструмент с теми же аргументами
//     без каких-либо других вызовов между ними).
//     ПОЧЕМУ: сессионная блокировка мешала легитимным повторам (read_file после write_file,
//     list_files после создания нового файла и т.д.). Подряд-блокировка ловит реальные петли.
//
// 13. АНГЛИЙСКИЙ СИСТЕМНЫЙ ПРОМПТ (ОПТИМИЗАЦИЯ ТОКЕНОВ):
//     baseSystemPrompt переведён на английский язык.
//     ПРИЧИНА: английский токенизируется в 1.5–2 раза эффективнее кириллицы.
//     Экономия ~3000 токенов на каждом запросе (~35% от общего промпта).
//     Правило language mirroring в конце промпта гарантирует ответы на языке пользователя.
//
// 14. UUID-BASED ПАМЯТЬ (IT-08):
//     Инструменты memorize/recall/search_memory/delete_memory работают с UUID-based scope.
//     ToolExecutionService получает ActiveMemoryContext (threadId UUID + [ProjectInfo{id,name}])
//     через setActiveMemoryContext() от ChappieViewModel.syncActiveMemoryContext().
//     resolveScope() маппирует scope="thread" → UUID треда, targetName="Name" → UUID проекта.
//     Конфликт инструкций между уровнями памяти — останавливаемся, объясняем пользователю.
//
// 15. ИМЕНА ПРОЕКТОВ В SYSTEM PROMPT (IT-08 финал):
//     MemoryContext теперь содержит projectInfos: [(id: UUID, name: String)] вместо [UUID].
//     buildSystemPrompt() показывает имя проекта в заголовке блока памяти.
//     ChappieViewModel заполняет projectInfos из activeProjects (ProjectMetadata).
//
// 16. ПАМЯТЬ ТОЛЬКО НА АНГЛИЙСКОМ (MEMORY-ENGLISH):
//     В baseSystemPrompt добавлено жёсткое правило: все записи в память (memorize)
//     ОБЯЗАНЫ быть на английском языке. Причина: память — это "мышление" Чаппи,
//     а не общение с пользователем. Как американский инженер думает по-английски,
//     но может говорить на любом языке — так и Чаппи: думает по-английски,
//     отвечает на языке пользователя.
//
// 17. БЕЗ ЭМОДЗИ В SYSTEM PROMPT (TOKEN-EFFICIENCY):
//     Все эмодзи убраны из заголовков секций памяти в buildSystemPrompt().
//     ПРИЧИНА: каждый эмодзи = 2-4 токена. При ~30 эмодзи в промпте = ~90 токенов впустую.
//     При 1000 запросов в месяц = ~90k токенов = реальные деньги.
//     Чистый текст без эмодзи — эффективнее и для кэширования промпта.

import Foundation

// MARK: - MemoryContext (контекст треда для подмешивания памяти)

/// Описание контекста треда — передаётся в process() для сборки system prompt с памятью.
///
/// ЗАЧЕМ ОТДЕЛЬНАЯ СТРУКТУРА:
/// process() уже принимает prompt, history, config. Добавлять ещё несколько параметров
/// (threadId, projectIds, projectNames) делает сигнатуру громоздкой.
/// MemoryContext — чистый value type, инкапсулирующий всё что нужно для сборки промпта.
///
/// ПОЧЕМУ projectInfos, А НЕ ПРОСТО projectIds (IT-08 финал):
/// buildSystemPrompt() должен знать имена проектов чтобы показывать их в заголовках блоков.
/// UUID нужен для поиска в SwiftData, имя — для отображения в промпте.
///
/// ОПЦИОНАЛЬНОСТЬ:
/// Если memoryContext не передан (nil) — используется только захардкоженный базовый промпт.
/// Это обратная совместимость: старый код без тредов продолжает работать.
public struct MemoryContext: Sendable {

    /// Информация об одном проекте в контексте памяти: UUID + отображаемое имя.
    ///
    /// ПОЧЕМУ UUID + ИМЯ:
    /// UUID нужен для поиска MemoryEntity в SwiftData.
    /// Имя нужно для заголовка блока памяти в system prompt.
    public struct ProjectInfo: Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// UUID активного треда (для тредовой памяти).
    /// nil = нет активного треда, тредовая память не подмешивается.
    public let threadId: UUID?

    /// Информация о проектах в треде: UUID + имя каждого.
    ///
    /// МИГРАЦИЯ С projectIds:
    /// Старый API принимал projectIds: [UUID] без имён.
    /// Новый API принимает projectInfos: [ProjectInfo] — с именами для промпта.
    /// Вычисляемое свойство projectIds обеспечивает обратную совместимость.
    public let projectInfos: [ProjectInfo]

    /// UUID всех проектов — для обратной совместимости с кодом использующим [UUID].
    public var projectIds: [UUID] { projectInfos.map { $0.id } }

    public init(threadId: UUID? = nil, projectInfos: [ProjectInfo] = []) {
        self.threadId = threadId
        self.projectInfos = projectInfos
    }

    /// Дефолтный контекст — без треда и проектов.
    /// Используется как фолбэк до IT-05 (UI тредов).
    public static let empty = MemoryContext(threadId: nil, projectInfos: [])
}

// MARK: - AIOrchestratorResult

/// Результат работы оркестратора за одну сессию.
public struct AIOrchestratorResult: Sendable {
    public let finalResponse: String
    public let totalCost: Double?
    public let newBalance: Double?

    public init(finalResponse: String, totalCost: Double?, newBalance: Double?) {
        self.finalResponse = finalResponse
        self.totalCost = totalCost
        self.newBalance = newBalance
    }
}

// MARK: - AIOrchestrator

/// Оркестратор ИИ-агента — главный управляющий компонент ChappieCore.
///
/// Реализует агентный цикл (agentic loop): итеративный процесс
/// "запрос → вызов инструмента → ответ → следующий запрос",
/// который продолжается до тех пор, пока модель не вернёт финальный
/// текстовый ответ без вызовов инструментов.
public actor AIOrchestrator {
    private let aiClient: AITunnelClient
    private let toolService: ToolExecutionService
    private let fileSystem: FileSystemManager

    /// MemoryManager для сборки system prompt с трёхуровневой памятью.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-03):
    /// Оркестратор держит ссылку на MemoryManager, чтобы перед каждым запросом
    /// вызывать buildSystemPrompt(). Это единственное место где собирается промпт.
    private let memoryManager: MemoryManager

    /// Дефолтный конфиг — используется если process() вызван без явного конфига.
    private let defaultConfig: AppConfig

    // MARK: - Базовый системный промпт (English — token efficiency)

    /// Базовый системный промпт — захардкоженные правила Чаппи.
    ///
    /// АРХИТЕКТУРНОЕ РЕШЕНИЕ (IT-03):
    /// Это BASE_PROMPT — основа. Перед каждым запросом MemoryManager.buildSystemPrompt()
    /// расширяет его блоками памяти (глобальной, проектной, тредовой).
    ///
    /// ПОЧЕМУ ЗАХАРДКОЖЕНО:
    /// Все критически важные правила захардкожены здесь, а не передаются извне.
    /// Память (semantic.json) может не загрузиться, история чата сжимается —
    /// только хардкод является 100% надёжной гарантией соблюдения правил.
    ///
    /// ПОЧЕМУ НА АНГЛИЙСКОМ (IT-13):
    /// Английский токенизируется в 1.5–2 раза эффективнее кириллицы.
    /// Экономия ~3000 токенов на каждом запросе.
    /// Правило language mirroring в конце промпта гарантирует ответы на языке пользователя.
    private let baseSystemPrompt = """
    You are Chappie, a genius Senior macOS/iOS AI developer.
    The project is written in Swift 6 with full concurrency control, SwiftUI, and a macOS 26+ target.
    You are the unified, almighty Core of the system, powered by the first-class Claude Sonnet 4.6 model.
    You have no team — you do everything yourself from start to finish: from architecture to UI layout and final refactoring.

    YOUR INVIOLABLE RULES:

    1. ABSOLUTE AUTONOMY:
       All responsibility for the project lies with you. Use tools directly to read, analyze, and rewrite files. Your decisions are final.

    2. CODE ALIENABILITY PRINCIPLE:
       All code you create MUST be densely covered with clear and detailed comments in perfect Russian language.
       Comments must explain WHY this code was written, not just WHAT it does.

    3. SYNTAX AND COMPILATION:
       Always verify Swift 6 syntax before saving code. Code must be fully compilable and ready to run. Return only complete files via write_file — never cut lines or leave unfinished blocks!

    4. THREE-LEVEL MEMORY SYSTEM (IT-08):
       Memory is stored in SwiftData and automatically injected into your system prompt.
       THREE LEVELS — use the right level for each piece of information:
         A) Global memory (scope="global"): cross-project facts, user preferences, universal rules.
            Tools: memorize/recall/search_memory/delete_memory with scope="global"
         B) Thread memory (scope="thread"): context of the current task, temporary notes, session agreements.
            Tools: memorize/recall/search_memory/delete_memory with scope="thread"
         C) Project memory (targetName="ProjectName"): architecture decisions, pipelines, project-specific rules.
            Tools: memorize/recall/search_memory/delete_memory with targetName="Chappie" (or any attached project name)
       DEFAULT: if neither scope nor targetName is specified → saves to global memory.
       CONFLICT RESOLUTION: If instructions from different memory levels contradict each other —
         STOP, explain the conflict to the user, wait for their decision, then update memory to resolve it.
       Architecture documentation: architecture.md files at the root of each target.
       Always read the relevant target's architecture.md before complex tasks.
       Paths: Chappie/architecture.md, ChappieCore/architecture.md, ChappieMCP/architecture.md,
              ChappieCoreTests/architecture.md, architecture.md (project root).

    5. MANDATORY SELF-SUMMARY (CRITICALLY IMPORTANT — NEVER VIOLATE):
       At the very end of EACH of your final responses to the user you MUST add the tag:
       <summary>Brief summary: what you did, which files you changed, which decisions you made. Maximum 2-3 sentences, facts only.</summary>
       RULES:
       - The tag is always last in the response, after everything else.
       - Inside the tag — only the essence, no greetings or filler.
       - If the response is short (greeting, clarifying question) — summary is still mandatory.
       - Never explain to the user what this tag is — they don't see it.
       - Violating this rule destroys the token-saving system. This is unacceptable.

    6. MANDATORY RECORDING OF ARCHITECTURAL DECISIONS (CRITICALLY IMPORTANT):
       When ANY key architectural decision is made, an important nuance or implementation detail is discussed — you MUST immediately record it in the architecture.md file of the corresponding target via the write_file tool.
       WHY THIS IS CRITICAL:
       - Chat history is aggressively compressed (budget 12,000 tokens).
       - Discussion details are lost during summarization.
       - Files are the only reliable long-term memory of the system.
       - Without this rule, important decisions will be lost forever.
       WHAT TO RECORD: architectural patterns, reasons for choosing an approach, rejected alternatives, important constraints, implementation nuances, agreements with the user.

    7. MANDATORY PIPELINE BEFORE EACH CODE CHANGE (IRON RULE):
       Every time code needs to be changed — STRICTLY follow this order:

       STEP 1: git_status — check for uncommitted changes from the previous session.
               If there are any — deal with them BEFORE starting a new change.
       STEP 2: git_add + git_commit — make a CHECKPOINT commit (rollback point).
               Commit message: "checkpoint: before [description of change]"
       STEP 3: write_file — apply changes to the code.
       STEP 4: build_project — compile. If it fails — FIX IT, do not proceed.
       STEP 5: run_tests — tests ONLY if the build succeeded.
               If they fail — FIX IT, do not proceed.
       STEP 6: git_add + git_commit — RESULT commit ONLY if everything is green.
               Commit message: "feat/fix: [description of what was done]"
       STEP 7: Tell the user they can press the triangle in Xcode to restart.

       ROLLBACK: If build or tests fail and cannot be fixed quickly —
                 notify the user and offer rollback: git reset --hard to the checkpoint commit.

       IRON PROHIBITIONS (violation is unacceptable):
       🚫 git_diff — FORBIDDEN FOREVER. Loads the entire project into AI context, costs hundreds of rubles.
       🚫 run_tests before build_project — tests compile themselves, resulting in double compilation.
       🚫 Final RESULT commit if tests or build are not green.

    8. LANGUAGE MIRRORING (IMPORTANT):
       Always respond to the user in the same language they are writing to you in.
       If the user writes in Russian — respond in Russian.
       If the user writes in English — respond in English.
       If the user writes in Arabic, French, or any other language — respond in that same language.
       Your internal reasoning and tool call planning happen in English for token efficiency.
       Only the final response to the user follows their language.

    9. MEMORY LANGUAGE (CRITICAL — NEVER VIOLATE):
       ALL memory writes (memorize tool) MUST be in English — no exceptions.
       Memory is your internal thinking, not communication with the user.
       Think like an American engineer: always think in English, speak in any language.
       Keys, types, values, notes — everything stored in memory must be in English.
       This rule exists because: memory is injected into system prompt (token efficiency),
       memory persists across sessions and projects (consistency), and English compresses
       2x better than Cyrillic in LLM tokenizers (cost savings).
    """

    public init(
        aiClient: AITunnelClient,
        toolService: ToolExecutionService,
        fileSystem: FileSystemManager,
        memoryManager: MemoryManager,
        config: AppConfig = .shared
    ) {
        self.aiClient = aiClient
        self.toolService = toolService
        self.fileSystem = fileSystem
        self.memoryManager = memoryManager
        self.defaultConfig = config
    }

    // MARK: - Публичный API

    /// Запускает агентный цикл для обработки пользовательского запроса.
    ///
    /// - Parameters:
    ///   - prompt: Текст текущего сообщения пользователя (НОВОЕ сообщение, не из истории).
    ///   - history: Полная история ЗАВЕРШЁННЫХ сообщений (без текущего prompt!).
    ///   - config: Конфиг треда — определяет глубину контекста и токенный бюджет.
    ///     По умолчанию AppConfig.shared (20 сообщений, 10,000 токенов).
    ///   - memoryContext: Контекст треда для сборки system prompt с памятью.
    ///     По умолчанию MemoryContext.empty — только базовый промпт без памяти.
    ///   - onToolCall: Вызывается при каждом вызове инструмента — обновляет UI.
    ///   - onToken: Вызывается для каждого нового токена финального ответа.
    ///   - onCostUpdate: Вызывается после каждого внутреннего API-запроса с накопленной
    ///     стоимостью нарастающим итогом.
    ///
    /// - Returns: Результат сессии: финальный ответ (с тегом <summary>), стоимость и баланс.
    /// - Throws: `ChappieError.unknown` если превышен лимит шагов из AppConfig.
    public func process(
        prompt: String,
        history: [AIMessage],
        config: AppConfig = .shared,
        memoryContext: MemoryContext = .empty,
        onToolCall: @escaping @Sendable (String, String) -> Void,
        onToken: (@Sendable (String) -> Void)? = nil,
        onCostUpdate: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AIOrchestratorResult {

        // ТРЁХУРОВНЕВАЯ ПАМЯТЬ (IT-03, IT-08):
        // Перед каждым запросом собираем актуальный system prompt с подмешанной памятью.
        // buildSystemPrompt() читает из MemoryStore (SwiftData) + legacy файл.
        // Если MemoryStore не подключён — возвращает только базовый промпт (фолбэк).
        //
        // ПЕРЕДАЁМ ПОЛНЫЙ MemoryContext с именами проектов (IT-08 финал):
        // buildSystemPrompt() использует имена для заголовков блоков памяти.
        let systemPrompt = await memoryManager.buildSystemPrompt(
            basePrompt: baseSystemPrompt,
            memoryContext: memoryContext
        )

        var sessionHistory = buildContextWindow(from: history, currentPrompt: prompt, config: config)

        var totalCost: Double = 0.0
        var latestBalance: Double? = nil
        var stepCount = 0

        // ЗАЩИТА ОТ ПЕТЕЛЬ (умная, подряд-блокировка):
        // Храним сигнатуру ТОЛЬКО последнего выполненного вызова инструмента.
        // Если следующий вызов совпадает — это петля, блокируем.
        // Если между ними был другой вызов — сигнатура сброшена, повтор разрешён.
        //
        // ПОЧЕМУ НЕ СЕССИОННАЯ БЛОКИРОВКА:
        // Сессионная блокировка (Set<String> за всю сессию) мешала легитимным повторам:
        // - read_file("foo.swift") после write_file("foo.swift") — нужно прочитать изменения
        // - list_files() после создания нового файла — нужно увидеть обновлённый список
        // - git_status() дважды для проверки состояния до и после операции
        // Подряд-блокировка ловит реальные бесконечные петли (A→A→A→...)
        // и не мешает нормальным паттернам (A→B→A или A→write→A).
        var lastToolSignature: String? = nil

        let maxSteps = config.maxOrchestratorSteps

        // MARK: - Агентный цикл

        while stepCount < maxSteps {
            stepCount += 1

            let tools = await toolService.availableTools

            let streamResult = try await aiClient.streamRequestWithTools(
                systemPrompt: systemPrompt,
                chatHistory: sessionHistory,
                tools: tools,
                onToken: onToken
            )

            if let cost = streamResult.cost {
                totalCost += cost
                onCostUpdate?(totalCost)
            }
            if let balance = streamResult.balance { latestBalance = balance }

            let assistantMessage = AIMessage(
                role: "assistant",
                content: streamResult.text.isEmpty ? nil : streamResult.text,
                toolCalls: streamResult.toolCalls
            )
            sessionHistory.append(assistantMessage)

            if let toolCalls = streamResult.toolCalls, !toolCalls.isEmpty {
                try await executeToolCalls(
                    toolCalls,
                    sessionHistory: &sessionHistory,
                    lastToolSignature: &lastToolSignature,
                    onToolCall: onToolCall
                )
                continue

            } else {
                let finalResponse = streamResult.text.isEmpty
                    ? "Нет ответа от модели."
                    : streamResult.text

                return AIOrchestratorResult(
                    finalResponse: finalResponse,
                    totalCost: totalCost > 0 ? totalCost : nil,
                    newBalance: latestBalance
                )
            }
        }

        throw ChappieError.unknown(
            "Превышен лимит шагов оркестратора (maxOrchestratorSteps = \(maxSteps)). " +
            "Цикл искусственно прерван. Увеличь AppConfig.maxOrchestratorSteps если нужно."
        )
    }

    // MARK: - Умное контекстное окно

    /// Собирает оптимальное контекстное окно из полной истории чата.
    ///
    /// ДВА УРОВНЯ ОГРАНИЧЕНИЙ (работают последовательно):
    ///
    /// 1. maxMessagesInContext — жёсткий лимит по количеству сообщений (из config треда).
    ///    Применяется ПЕРВЫМ. Отбрасывает всё что старше последних N сообщений.
    ///
    /// 2. tokenBudget — мягкий лимит по объёму токенов (maxMessages × 500).
    ///    Применяется ВТОРЫМ. Обрезает длинные сообщения если даже N штук не влезают.
    private func buildContextWindow(
        from history: [AIMessage],
        currentPrompt: String,
        config: AppConfig
    ) -> [AIMessage] {
        let budget = config.tokenBudget
        let recentCount = config.recentFullMessages
        let summaryThreshold = config.summaryThreshold
        let maxMessages = config.maxMessagesInContext

        let totalTokensBefore = history.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] Historia: \(history.count) msgs, ~\(totalTokensBefore) tokens | Budget: \(budget) (\(maxMessages) msgs x 500)")

        // ШАГ 1: ДЕДУПЛИКАЦИЯ
        let deduplicatedHistory: [AIMessage]
        if let lastMessage = history.last,
           lastMessage.role == "user",
           lastMessage.contentString == currentPrompt {
            deduplicatedHistory = Array(history.dropLast())
            print("[AIOrchestrator] Dedup: removed duplicate last message")
        } else {
            deduplicatedHistory = history
        }

        // ШАГ 2: Жёсткий лимит по количеству
        let cappedHistory = deduplicatedHistory.count > maxMessages
            ? Array(deduplicatedHistory.suffix(maxMessages))
            : deduplicatedHistory

        // ШАГ 3: Разбиваем на "свежую" и "старую" зоны
        let recentMessages: [AIMessage]
        let olderMessages: [AIMessage]

        if cappedHistory.count <= recentCount {
            recentMessages = cappedHistory
            olderMessages = []
        } else {
            recentMessages = Array(cappedHistory.suffix(recentCount))
            olderMessages = Array(cappedHistory.prefix(cappedHistory.count - recentCount))
        }

        var usedTokens = recentMessages.reduce(0) { $0 + estimateTokens($1) }

        // ШАГ 4: Идём по старым сообщениям с конца (ближайшие — важнее)
        var selectedOlder: [AIMessage] = []
        for message in olderMessages.reversed() {
            let compressed = compressMessage(message, summaryThreshold: summaryThreshold)
            let tokens = estimateTokens(compressed)

            if usedTokens + tokens <= budget {
                selectedOlder.insert(compressed, at: 0)
                usedTokens += tokens
            } else {
                break
            }
        }

        var contextWindow = selectedOlder + recentMessages
        contextWindow.append(AIMessage(role: "user", content: currentPrompt))

        let totalTokensAfter = contextWindow.reduce(0) { $0 + estimateTokens($1) }
        print("[AIOrchestrator] Sending: \(contextWindow.count) msgs, ~\(totalTokensAfter) tokens (compressed from \(totalTokensBefore))")

        return contextWindow
    }

    /// Сжимает сообщение до его summary если оно достаточно длинное.
    private func compressMessage(_ message: AIMessage, summaryThreshold: Int) -> AIMessage {
        guard let fullText = message.contentString,
              estimateTokens(message) > summaryThreshold,
              let summary = extractSummary(from: fullText) else {
            return message
        }

        return AIMessage(
            role: message.role,
            content: "[СЖАТО] \(summary)",
            tool_call_id: message.tool_call_id,
            name: message.name
        )
    }

    /// Извлекает текст из тега <summary>...</summary>.
    private func extractSummary(from text: String) -> String? {
        let openTag = "<summary>"
        let closeTag = "</summary>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag),
              openRange.upperBound < closeRange.lowerBound else {
            return nil
        }

        let summary = String(text[openRange.upperBound..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return summary.isEmpty ? nil : summary
    }

    /// Оценивает количество токенов в сообщении.
    private func estimateTokens(_ message: AIMessage) -> Int {
        let text = message.contentString ?? ""
        let utf8ByteCount = text.utf8.count
        let estimated = Int(Double(utf8ByteCount) / 4.0 * 1.5)
        return max(1, estimated)
    }

    // MARK: - Приватные методы агентного цикла

    /// Выполняет список вызовов инструментов и добавляет результаты в историю.
    ///
    /// ЗАЩИТА ОТ ПЕТЕЛЬ (подряд-блокировка):
    /// Если текущий вызов совпадает с предыдущим по сигнатуре (имя + аргументы) —
    /// это петля. Возвращаем ошибку вместо реального выполнения.
    /// После каждого успешного вызова обновляем lastToolSignature.
    /// Если в пачке несколько вызовов — сигнатура последнего запоминается.
    /// Это означает: A,B → A разрешено (между A и A был B).
    /// Но A → A запрещено (подряд без ничего между ними).
    private func executeToolCalls(
        _ toolCalls: [AIToolCall],
        sessionHistory: inout [AIMessage],
        lastToolSignature: inout String?,
        onToolCall: @Sendable (String, String) -> Void
    ) async throws {
        for toolCall in toolCalls {
            let toolName = toolCall.function.name
            let arguments = toolCall.function.arguments
            let targetPath = extractTargetPath(from: arguments)
            let signature = "\(toolName)|\(arguments)"
            let resultString: String

            if lastToolSignature == signature {
                // ПЕТЛЯ ОБНАРУЖЕНА: тот же инструмент с теми же аргументами подряд.
                // Возвращаем ошибку чтобы модель поняла что нужно изменить подход.
                resultString = """
                SYSTEM ERROR: You just called `\(toolName)` with the exact same arguments right before this. \
                This is an infinite loop. DO NOT REPEAT THE SAME ACTION. USE A DIFFERENT APPROACH.
                """
                print("[AIOrchestrator] Loop detected: \(toolName) called twice in a row with same args")
            } else {
                // Нормальный вызов — выполняем и обновляем сигнатуру последнего вызова.
                lastToolSignature = signature
                onToolCall(toolName, targetPath)
                resultString = await toolService.execute(call: toolCall)
            }

            let toolResponse = AIMessage(
                role: "tool",
                content: resultString,
                tool_call_id: toolCall.id,
                name: toolName
            )
            sessionHistory.append(toolResponse)
        }
    }

    private func extractTargetPath(from arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return json["path"] as? String ?? ""
    }
}
