# Chappie — Overall Project Architecture

## 1. Project Structure

```
/Volumes/Storage/Work/Chappie/
├── architecture.md                          # This file (root architecture)
├── Chappie.xcodeproj/
├── Chappie/                                 # UI target → see Chappie/architecture.md
├── ChappieCore/                             # Business logic → see ChappieCore/architecture.md
├── ChappieCoreTests/                        # Tests → see ChappieCoreTests/architecture.md
├── ChappieMCP/                              # Helper process (thin main.swift) → see ChappieMCP/architecture.md
├── ChappieMCPCore/                          # Helper logic as a local package → see ChappieMCP/architecture.md
├── ChappieMCPTests/                         # Helper tests → see ChappieMCP/architecture.md
└── Scripts/                                 # Internal maintenance scripts (not part of build)
    └── release_publish.sh                   # Publishes a release build
```

---

## 2. Targets

| Target | Type | Purpose |
|---|---|---|
| `Chappie` | SwiftUI App | UI shell, @MainActor, @Observable ViewModel |
| `ChappieCore` | Swift Package Library | All business logic: AI, tools, memory |
| `ChappieCoreTests` | Unit Test Bundle | Tests for ChappieCore |
| `ChappieMCP` | Command Line Tool | Child process entry point (only `main.swift`) |
| `ChappieMCPCore` | Swift Package Library (local) | All helper logic: git, build, localization, documents, socket server |
| `ChappieMCPTests` | Unit Test Bundle | Tests for ChappieMCPCore (in `ChappieCoreTests.xctestplan`) |

---

## 3. Architecture Diagram

```mermaid
graph TD
    subgraph App["Chappie.app (macOS 14+)"]
        UI["Chappie — SwiftUI UI\nsee Chappie/architecture.md"]
        Core["ChappieCore — Business Logic\nsee ChappieCore/architecture.md"]
        UI -->|depends on| Core
    end

    subgraph Tests["Test Target"]
        T["ChappieCoreTests\nsee ChappieCoreTests/architecture.md"]
        T -->|tests| Core
    end

    subgraph Helper["Child Process"]
        MCP["ChappieMCP — git + xcodebuild + loc\nsee ChappieMCP/architecture.md"]
    end

    Core -->|Unix Domain Socket IPC| MCP
    App -->|embeds in Contents/Helpers/| MCP

    subgraph Storage["Persistence"]
        DS["SQLiteStorage (GRDB)\nWAL mode, DatabasePool\nstored_records table"]
        KC["Keychain\n(API keys + Curl-Chappie secrets)"]
    end

    Core --> DS
    Core --> KC
```

---

## 4. Target Dependencies

```
Chappie.app
    ├── depends on → ChappieCore (Swift Package)
    └── embeds → ChappieMCP (Contents/Helpers/)

ChappieCoreTests
    └── depends on → ChappieCore

ChappieMCP
    └── depends on → ChappieMCPCore (no ChappieCore dependency)

ChappieMCPTests
    └── depends on → ChappieMCPCore
```

---

## 5. Key Technologies

| Technology | Usage |
|---|---|
| Swift 6 (Full Concurrency) | Entire project |
| SwiftUI macOS 14+ | UI layer (deployment target 14.0) |
| GRDB (SQLite) | Persistence via SQLiteStorage |
| @Observable | ViewModel |
| Actors | ChappieCore services |
| OpenAI-compatible API | Default wire protocol (AIClient) |
| Anthropic native API | /v1/messages (AnthropicClient) |
| AIClientFactory | Picks correct client by model.providerProtocol |
| Unix Domain Sockets | IPC with ChappieMCP |
| Keychain | API keys + Curl-Chappie secret values |

---

## 6. Storage Map

| What | Where | Key/Format |
|---|---|---|
| Thread list + metadata | `stored_records` → key `"threads"` | `[ThreadPayload]` JSON |
| Thread messages | `stored_records` → key `"thread_messages_chunk.<UUID>.<index>"` | `[ChatMessage]` JSON chunks (500 msgs each) |
| Memory (3 levels) | `stored_records` → key `"memory"` | `[MemoryScope]` JSON |
| AI providers | `stored_records` → key `"providers"` | `[AIProvider]` JSON |
| App settings | `stored_records` → key `"app_settings"` | `AppSettingsPayload` JSON |
| API keys | Keychain | `apiKey.id.uuidString` |
| Curl-Chappie secret values | Keychain | one entry per secret part, metadata only in project settings |

**Rule: SQLiteStorage (GRDB) is the ONLY persistence backend. No SwiftData anywhere.**
**Secret values live in Keychain ONLY — never in SQLite.**

> **Projects are stored inside ThreadPayload** — no separate global project registry.
> Each thread owns its own `[ThreadProjectEntry]` with `id`, `displayName`, `absolutePath`.

---

## 7. Memory Structure — Three Levels

| Level | Owner | Physical Location | Tool Parameter |
|---|---|---|---|
| Global | `AppSettings` | `MemoryScope` scope=`"global"` | `scope:"global"` |
| Thread | `ThreadEntity` | `MemoryScope` scope=`thread.id` | `scope:"thread"` |
| Project | `ThreadProject` (per thread) | `MemoryScope` scope=`project.id` | `targetName:"Name"` |

Project memory is **per thread** — the same project in two threads has independent memory.

**System prompt injection order:**
```
[1] Persona + rules (from ChappieViewModel+PersonaBlock.swift)
[2] userName (from AppSettings)
[3] Global memory (if not empty)
[4] Thread memory (if not empty)
[5] Per-project: ProjectSettings + project memory (one block per valid project)
[6] Tool manifest (only tools available in this thread)
```

Empty sections are omitted entirely — no wasted tokens.

---

## 8. Thread Isolation Architecture

| Entity | Role |
|---|---|
| `ThreadProjectEntry` | Project in context of a specific thread; owns `absolutePath`, `ProjectSettings`, memory |
| `ThreadSession` | Runtime container assembled on thread activation, discarded on switch |
| `SystemPromptBuilder` | Deterministic prompt assembly from `PromptContext`; pure value transformer |
| `ToolPolicy` | Single access table (deny by default); `ToolAuthorization` applies it per call and per exposed tool |
| `AppSettingsStore` | Actor-based CRUD for the singleton AppSettings record |

**Project attachment rules:**
- Only the user can add/remove projects (via `+` button or drag & drop). AI cannot.
- `absolutePath` is set at attachment time and stored directly in `ThreadPayload`.
- Duplicate check: same `absolutePath` → silently ignored, no duplicate added.
- `list_thread_projects` tool is available to AI (read-only).

**Provider/model validation on thread load:**
1. Resolve `providerId` → if not found: show orange banner, block AI calls
2. Resolve `keyId` → if not found: show orange banner, block AI calls
3. Resolve `modelId` → if not found: show warning, allow calls using cached `modelName`
4. Read key value from Keychain → if not found: block AI calls

**Rule: NEVER auto-substitute provider or model on loss.** User must explicitly re-select.

---

## 9. DataStore Pattern — Deterministic Data Flow

```
Write:  DomainStruct (Codable) → JSONEncoder → Data → stored_records.payload → SQLite
Read:   SQLite → stored_records.payload → Data → JSONDecoder → DomainStruct (Codable)
```

**Why this works:**
- SQLite schema is frozen at one table (`stored_records`). No migrations ever.
- Domain structs evolve freely as `Codable` — no schema involvement.
- Decode failure is non-fatal. Callers receive `nil`/`[]` and recover gracefully.
- The entire persistence layer is replaceable without touching domain logic.

**Codable Compatibility Rules (CRITICAL — violation = silent data corruption):**

1. **Never rename a stored property without `CodingKeys`.**
2. **Never remove a stored property** — mark `optional` with a default.
3. **Always give new properties a default value.**

---

## 10. Message Chunking

Messages are stored in chunks of 500 per SQLite row:
- Key format: `thread_messages_chunk.<UUID>.<index>` (zero-padded for lexicographic sort)
- `loadMessages()` loads only the **last chunk** — O(1) open time regardless of history size
- `loadMoreMessages()` loads previous chunks on scroll — lazy pagination
- `deleteByPrefix()` deletes all chunks atomically in one SQL query
- Saving: ViewModel calls `saveLoadedMessages(_, toThreadId:, fromChunk: loadedWindowStartChunk)` — only chunks of the loaded window are rewritten (one transaction); older chunks stay untouched. `replaceAllMessages` is reserved for "clear memory" / delete-old-messages.
- Write path: all message/thread-settings/title writes go through `ChappieViewModel+Persistence` → `SaveQueue` (ChappieCore). A failed write shows a blocking alert (Try Again / Skip) attached to the ContentView root; damage found while loading the thread list shows a non-blocking `StorageIssueBanner` (Views/Shared). Not yet routed through the queue: Memory Management delete-old-messages, app-settings writes (balance, last thread) — tracked in backlog.

---

## 11. Built-in Providers

There is no remote catalog and no network call to discover providers or models. Ten provider presets are hardcoded in `ChappieCore/Models/BuiltInProviders.swift` (OpenAI, Anthropic, Google Gemini, DeepSeek, Groq, Mistral, xAI, OpenRouter, AITunnel, Ollama): name, base URL, protocol, icon, colour, key requirement and chat path. Presets contain **no model names**: models change too often, so the user types any model ID by hand (or loads the list from the provider's `/models`). Users can also add fully custom providers.

The chat path is stored per provider preset because it differs (Groq `/openai/v1/chat/completions`, OpenRouter `/api/v1/chat/completions`, Anthropic `/v1/messages`).

---

## 12. Distribution

The app is free and open source (GPL-3.0). There is no licensing, trial or paywall: all features are available to everyone. The first-launch screen is a Terms of Use notice (responsibility and no-warranty), not a license check.

---

## 13. 📚 Docs Group in Xcode Navigator

`📚 Docs` group in `project.pbxproj` — navigation only, not included in build.
Contains root `architecture.md` + references to 4 target architecture files.
**Manage manually** via `write_file` in `project.pbxproj`.

---

## 14. Work Pipeline

1. `git_status` — check for uncommitted changes
2. Implement (one task per pass)
3. Add unit tests if needed (business logic, not trivial UI)
4. `build_project`
5. `run_tests` (only after green build)
6. Fix until green
7. Report to user → wait for acceptance
8. `git_commit` (only after user acceptance)

---

## 15. Inviolable Agent Rules

**RULE-01: One task per pass** — decompose into backlog, execute one item, commit, repeat.

**RULE-02: Read architecture files first** — before any feature or refactor.

**RULE-03: git_diff is always forbidden** — loads entire project into context, costs money.

**RULE-04: Never run tests before build** — causes double compilation.

**RULE-05: No final commit if build or tests are red** — a broken commit is worse than none.

**RULE-06: Commit only after user acceptance** — never commit autonomously after task completion.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07 | Initial architecture |
| 2026-06 | Storage cleanup: removed DataStoreMigration, V2/V3 schema stubs |
| 2026-07 | Projects refactor: removed global ProjectPayload registry + bookmarks. Projects now live inside ThreadPayload as [ThreadProjectEntry] with absolutePath. AI tools add/remove_project_to_thread removed. |
| 2026-07 | SwiftData removal: SQLiteStorage (GRDB) is now the sole persistence backend. |
| 2026-07 | Chunk system: messages split into 500-msg chunks. Lazy loading. Legacy migration removed after all data migrated. |
| 2026-11 | Licensing removed entirely (LicenseService, PaymentService, paywall, trial banner, Starter plan mode, licensing.md). The app is free; EULA screen renamed Terms of Use. |
