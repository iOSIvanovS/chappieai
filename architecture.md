# Chappie — Overall Project Architecture

## 1. Project Structure

```
/Volumes/Storage/Work/Chappie/
├── architecture.md                          # This file (root architecture)
├── Chappie.xcodeproj/
├── Chappie/                                 # UI target → see Chappie/architecture.md
├── ChappieCore/                             # Business logic → see ChappieCore/architecture.md
├── ChappieCoreTests/                        # Tests → see ChappieCoreTests/architecture.md
├── ChappieMCP/                              # Helper process → see ChappieMCP/architecture.md
└── Scripts/                                 # Internal maintenance scripts (not part of build)
    ├── providers_1_clear.sh                 # Initializes providers.json
    ├── providers_2_append.sh                # Appends a batch of providers/models (≤100)
    └── providers_3_push.sh                  # Pushes providers.json to GitHub via API
```

---

## 2. Targets

| Target | Type | Purpose |
|---|---|---|
| `Chappie` | SwiftUI App | UI shell, @MainActor, @Observable ViewModel |
| `ChappieCore` | Swift Package Library | All business logic: AI, tools, memory |
| `ChappieCoreTests` | Unit Test Bundle | Tests for ChappieCore |
| `ChappieMCP` | Command Line Tool | Child process: git + xcodebuild |

---

## 3. Architecture Diagram

```mermaid
graph TD
    subgraph App["Chappie.app (macOS 26+)"]
        UI["Chappie — SwiftUI UI\nsee Chappie/architecture.md"]
        Core["ChappieCore — Business Logic\nsee ChappieCore/architecture.md"]
        UI -->|depends on| Core
    end

    subgraph Tests["Test Target"]
        T["ChappieCoreTests\nsee ChappieCoreTests/architecture.md"]
        T -->|tests| Core
    end

    subgraph Helper["Child Process"]
        MCP["ChappieMCP — git + xcodebuild\nsee ChappieMCP/architecture.md"]
    end

    Core -->|Unix Domain Socket IPC| MCP
    App -->|embeds in Contents/Helpers/| MCP

    subgraph Storage["Persistence"]
        SD["SwiftData\n(ThreadEntity, ProjectEntity, MemoryEntity\nAIProviderEntity, AppSettings)"]
        KC["Keychain\n(API keys by apiKey.id.uuidString)"]
    end

    subgraph Remote["Remote"]
        GH["GitHub\nproviders.json (public)"]
    end

    Core --> SD
    Core --> KC
    Core -->|HTTP GET on launch| GH
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
    └── standalone (no ChappieCore dependency)
```

---

## 5. Key Technologies

| Technology | Usage |
|---|---|
| Swift 6 (Full Concurrency) | Entire project |
| SwiftUI macOS 26+ | UI layer |
| SwiftData macOS 26+ | Thread, project, memory, and settings persistence |
| @Observable | ViewModel |
| Actors | ChappieCore services |
| OpenAI-compatible API | Default wire protocol (AIClient) |
| Anthropic native API | /v1/messages (AnthropicClient) |
| AIClientFactory | Picks correct client by model.providerProtocol |
| Unix Domain Sockets | IPC with ChappieMCP |
| Keychain | API key storage (per APIKey.id) |
| GitHub (public repo) | providers.json catalog hosting |

---

## 6. Storage Map

| What | Where | Key/Format |
|---|---|---|
| Threads, messages, settings | SwiftData `ThreadEntity` | JSON-in-Data fields |
| Projects (folder registry) | SwiftData `ProjectEntity` | bookmarkData + path |
| Memory (3 levels) | SwiftData `MemoryEntity` | scope + targetId |
| AI providers | SwiftData `AIProviderEntity` | JSON blob (AIProvider struct) |
| API keys | Keychain | `apiKey.id.uuidString` |
| Provider balances | SwiftData `AppSettings.balancesJSON` | `{ "<uuid>": Double }` |
| Last active thread | SwiftData `AppSettings.lastActiveThreadIdString` | UUID string |
| Workspace bookmark | SwiftData `AppSettings.workspaceBookmark` | Data |
| One-time migration flags | UserDefaults | `migrationIT04Completed` |

**UserDefaults is used only for one-time migration flags. All domain data lives in SwiftData or Keychain.**

---

## 7. Memory Structure — Three Levels

| Level | Owner | Physical Location | Tool Parameter |
|---|---|---|---|
| Global | `AppSettings` | `MemoryEntity` scope=`"global"` | `scope:"global"` |
| Thread | `ThreadEntity` | `MemoryEntity` scope=`thread.id` | `scope:"thread"` |
| Project | `ThreadProject` (per thread) | `MemoryEntity` scope=`project.id` | `targetName:"Name"` |

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
| `ThreadProject` | Project in context of a specific thread; owns its own `ProjectSettings` and memory |
| `ProjectEntity` | Global folder registry only — path + displayName, no logic, no memory |
| `ThreadSession` | Runtime container assembled on thread activation, discarded on switch |
| `SystemPromptBuilder` | Deterministic prompt assembly from `PromptContext`; pure value transformer |
| `ToolAccessController` | Hard gate before every tool execution; returns structured `AccessResult` |
| `AppSettingsStore` | Actor-based CRUD for the singleton `AppSettings` SwiftData record |

**Provider/model validation on thread load:**
1. Resolve `providerId` → if not found: show orange banner, block AI calls
2. Resolve `keyId` → if not found: show orange banner, block AI calls
3. Resolve `modelId` → if not found: show warning, allow calls using cached `modelName`
4. Read key value from Keychain → if not found: block AI calls

**Rule: NEVER auto-substitute provider or model on loss.** User must explicitly re-select.

---

## 9. JSON-in-SwiftData Pattern

All complex domain objects are stored as JSON inside SwiftData primitive fields.
SwiftData `@Model` classes contain only: `UUID`, `Date`, `Bool`, `Int`, `String`, `Data`.

**Why:** SwiftData schema migrations are painful. JSON-in-Data means the schema never
changes — only the `Codable` struct evolves freely.

**⚠️ CRITICAL: Never rename a `Codable` property stored in SwiftData without adding `CodingKeys`.**

Persisted structs (must follow the rename rule):

| Struct | Stored in |
|---|---|
| `ThreadSettings` | `ThreadEntity.settingsJSON` |
| `ProjectSettings` | `ProjectEntity.settingsJSON` |
| `AIProvider` | `AIProviderEntity.json` |
| `[ChatMessage]` | `ThreadEntity.messagesJSON` |

---

## 10. Provider Catalog Pipeline

`providers.json` is hosted publicly at:
`https://raw.githubusercontent.com/iOSIvanovS/chappieai/main/docs/providers.json`

**Monthly update pipeline (run manually by maintainer):**
1. `Scripts/providers_1_clear.sh` — initializes empty JSON structure
2. `Scripts/providers_2_append.sh <json>` — appends batch of ≤100 models (run multiple times)
3. `Scripts/providers_3_push.sh` — pushes final file to GitHub via API (requires `$GITHUB_TOKEN`)

**JSON structure:**
```json
{
  "meta": { "version": "1.0", "updated_at": "...", "providers_count": 10, "models_count": 209 },
  "providers": [
    {
      "id": "openai",
      "name": "OpenAI",
      "base_url": "https://api.openai.com",
      "models": [
        { "id": "gpt-4o", "name": "GPT-4o", "endpoint": "/v1/chat/completions", "protocol": "openai" }
      ]
    }
  ]
}
```

Supported providers (10): OpenAI, Anthropic, Google Gemini, DeepSeek, Groq, Mistral, xAI (Grok), OpenRouter, AITunnel, Ollama.

---

## 11. 📚 Docs Group in Xcode Navigator

`📚 Docs` group in `project.pbxproj` — navigation only, not included in build.
Contains root `architecture.md` + references to 4 target architecture files.
**Manage manually** via `write_file` in `project.pbxproj`.

---

## 12. Work Pipeline

1. `git_status` — check for uncommitted changes
2. `git_commit` — checkpoint before changes
3. Implement (one task per pass)
4. Add unit tests if needed (business logic, not trivial UI)
5. `build_project`
6. `run_tests` (only after green build)
7. Fix until green
8. `git_commit`
9. Report to user

---

## 13. Inviolable Agent Rules

**RULE-01: One task per pass** — decompose into backlog, execute one item, commit, repeat.

**RULE-02: Read architecture files first** — before any feature or refactor.

**RULE-03: git_diff is always forbidden** — loads entire project into context, costs money.

**RULE-04: Never run tests before build** — causes double compilation.

**RULE-05: No final commit if build or tests are red** — a broken commit is worse than none.

---

## 14. Tech Debt

| ID | Issue | Priority |
|----|-------|----------|
| TD-02 | `ChappieCoreTests` requires manual scheme switch in Xcode before ⌘+U | Low |
