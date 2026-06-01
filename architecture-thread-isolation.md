# Chappie — Thread Isolation Architecture

> **Purpose of this file:** A detailed design document for the thread isolation refactor.
> Written as a reference for the AI agent to consult at every iteration of implementation.
> The goal: eliminate cross-thread contamination of projects, AI providers, and memory.

---

## 1. The Problem

Currently the app suffers from "state leakage" between threads:
- Switching to a different thread can show projects attached to a neighboring thread
- An AI model selected in one thread bleeds into another
- Memory written in thread A can appear in thread B
- There is no clear ownership graph: who owns what, and when does that ownership end

Root cause: the data model has no strict isolation boundaries. Entities like
`AIProviderEntity`, `ProjectEntity`, and `MemoryEntity` are shared globally and
referenced loosely. There is no concept of "this provider selection belongs to THIS thread."

---

## 2. Entity Graph (Target State)

```
AppSettings
├── userName: String
├── globalMemory: [MemoryEntry]        ← cross-thread, cross-project
└── providers: [AIProvider]            ← the global registry of providers

AIProvider
├── id: UUID
├── name: String
├── keys: [APIKey]
└── models: [AIModel]

APIKey
├── id: UUID
├── name: String
└── value: String                      ← stored in Keychain, not in SwiftData

AIModel
├── id: UUID
└── name: String

Thread
├── id: UUID
├── title: String
├── createdAt: Date
├── contextDepth: Int
├── isUnlimitedContext: Bool
├── providerSnapshot: ProviderSnapshot?   ← see section 4
├── threadMemory: [MemoryEntry]           ← scoped to this thread only
├── messages: [Message]
└── attachedProjects: [ThreadProject]     ← see section 5

ThreadProject
├── id: UUID
├── projectEntityId: UUID              ← reference to ProjectEntity (the folder bookmark)
├── settings: ProjectSettings          ← role, git, tests, comments, etc.
├── memory: [MemoryEntry]              ← project memory IN THIS THREAD ONLY
└── validationState: ProjectValidationState

ProjectEntity                          ← global folder registry, no logic, no memory
├── id: UUID
├── displayName: String
└── path: String

MemoryEntry
├── id: UUID
├── key: String
├── type: String                       ← rule, fact, decision, backlog, tech_debt...
├── value: String
└── createdAt: Date
```

**Key design principle:**
- `ProjectEntity` = address book entry. It only knows WHERE the folder is.
- `ThreadProject` = live participant of a thread. It knows HOW to work with the folder in this context.
- The same folder can be attached to multiple threads as separate `ThreadProject` instances,
  each with its own `settings` and `memory`. They do not share state.

---

## 3. Memory — Three Levels, Three Locations

```
Level          │ Owner          │ Physical location          │ Tool parameter
───────────────┼────────────────┼────────────────────────────┼──────────────────────
Global         │ AppSettings    │ AppSettings.globalMemory   │ scope="global"
Thread         │ Thread         │ Thread.threadMemory        │ scope="thread"
Project        │ ThreadProject  │ ThreadProject.memory       │ targetName="ProjectName"
```

**Rules:**
- Global memory survives thread deletion, project removal, app reinstall (export/import).
- Thread memory is deleted when the thread is deleted.
- Project memory lives in `ThreadProject` — deleting the thread deletes this memory too.
  The same project in a different thread has its own independent memory.
- `targetName` resolution: `SystemPromptBuilder` resolves the project name string
  to the correct `ThreadProject` instance in the current thread by matching `displayName`.
  If multiple projects with the same name exist in one thread — the user is warned.

**Injection order in system prompt (most stable → most specific):**
```
[1] Persona + 14 rules                  ← hardcoded, always present
[2] AppSettings.userName                ← "The user's name is Sergey"
[3] AppSettings.globalMemory            ← if not empty
[4] Thread.threadMemory                 ← if not empty
[5] Per-project block (for each ThreadProject):
    ├── ProjectSettings (role, git, tests, comments...)
    └── ThreadProject.memory            ← if not empty
[6] Tool manifest                       ← only tools actually available in this thread
```

Empty sections are omitted entirely — no wasted tokens.

---

## 4. ProviderSnapshot — Protecting the Thread from Settings Changes

**The problem:** if a user deletes a provider or removes a model from settings,
threads that were using that provider silently break or fall back to unexpected defaults.

**Solution:** when the user selects a provider+key+model for a thread, a `ProviderSnapshot`
is written into the thread. It contains both a live reference and a frozen copy:

```swift
struct ProviderSnapshot {
    // Live references (used when available)
    let providerId: UUID
    let keyId: UUID
    let modelId: UUID

    // Frozen copies (fallback when live references are gone)
    let providerName: String
    let modelName: String
    // Note: key value is NOT stored here — always read from Keychain via keyId
}
```

**Validation on thread load:**
```
1. Resolve providerId → AIProvider in AppSettings.providers
   → NOT FOUND: mark as .orphaned, show warning in UI, block AI calls
   → FOUND: continue

2. Resolve keyId → APIKey in provider.keys
   → NOT FOUND: mark as .keyMissing, show warning, block AI calls
   → FOUND: continue

3. Resolve modelId → AIModel in provider.models
   → NOT FOUND: fall back to providerSnapshot.modelName (display only),
     show warning "model no longer in list", still allow calls using modelName string

4. Read key value from Keychain using keyId
   → NOT FOUND: mark as .keyValueMissing, block AI calls
```

**UI behavior:**
- `.orphaned` or `.keyMissing` → red badge on thread, "Provider unavailable" message
- `.modelNotInList` → yellow badge, "Model removed from list — using cached name"
- User can always re-select a valid provider to restore the thread

---

## 5. ThreadProject — Protecting Projects from Filesystem Changes

**The problem:** if a folder is moved, renamed, or deleted, the attached project
silently breaks. There is no feedback to the user.

**Validation states:**

```swift
enum ProjectValidationState {
    case valid                          // path exists, folder accessible
    case pathMissing(lastKnownPath: String)  // folder not found at stored path
    case orphaned                       // ProjectEntity itself was deleted
}
```

**Validation on thread load (for each ThreadProject):**
```
1. Resolve projectEntityId → ProjectEntity in global registry
   → NOT FOUND: .orphaned

2. Check if path exists on filesystem
   → NOT FOUND: .pathMissing(lastKnownPath: entity.path)

3. Both checks pass → .valid
```

**UI behavior:**
- `.orphaned` → gray chip with ⚠️, tooltip "Project folder was removed from Chappie"
- `.pathMissing` → yellow chip with ⚠️, tooltip "Folder not found at: /old/path"
- User can re-link (pick new path) or remove the broken project from the thread

**Important:** validation is read-only and non-destructive.
A broken project is never auto-removed — the user decides.

---

## 6. SystemPromptBuilder

Single object responsible for assembling the full system prompt for a thread.
It is deterministic: same input → same output.

```swift
actor SystemPromptBuilder {
    func build(thread: Thread, appSettings: AppSettings) -> String
    func availableTools(thread: Thread) -> [ToolDefinition]
}
```

**Build steps:**
1. Append persona block (hardcoded Chappie identity + 14 rules)
2. Append `"The user's name is \(appSettings.userName)"` if set
3. Append global memory block if `appSettings.globalMemory` is not empty
4. Append thread memory block if `thread.threadMemory` is not empty
5. For each valid `ThreadProject` in `thread.attachedProjects`:
   - Append project settings block (role, git, tests, comments, architecture files)
   - Append project memory block if `project.memory` is not empty
6. Append tool manifest — only tools returned by `availableTools(thread:)`

**availableTools logic:**
- Always include: `web_fetch`, all memory tools, thread project tools
- Include file tools (`list_files`, `read_file`) if any project has role ≥ ADVISOR
- Include write tools (`write_file`, `delete_file`) if any project has role = EXECUTOR
- Include git tools if any project has `gitEnabled = true`
- Include build/test tools if any project has `testsEnabled = true`

Result: the AI only sees tools it can actually use. Fewer hallucinated tool calls.

---

## 7. ToolAccessController

Sits between the AI's tool call request and `ToolExecutionService`.
It is the enforcement layer — not advisory, not suggestive. Hard gate.

```swift
actor ToolAccessController {
    func validate(
        tool: String,
        args: [String: Any],
        thread: Thread
    ) -> ToolAccessResult
}

enum ToolAccessResult {
    case allowed(resolvedProject: ThreadProject?)
    case denied(reason: DenialReason)
}

enum DenialReason {
    case noProjectAttached
    case projectInAdvisorMode(projectName: String)
    case gitDisabled(projectName: String)
    case testsDisabled(projectName: String)
    case ambiguousProject(candidates: [String])  // path matches multiple projects
    case projectPathMissing(projectName: String)
    case providerUnavailable
}
```

**Project resolution from tool args:**
```
1. Extract path from args (e.g., write_file.path, git_commit, etc.)
2. Find ThreadProject whose entity.path is a prefix of the given path
3. If exactly one match → use it
4. If zero matches → noProjectAttached
5. If multiple matches → ambiguousProject (ask user to clarify)
6. If tool has no path (e.g., git_log, build_project) → use the single attached project,
   or ambiguousProject if multiple
```

**Denial response to AI (structured, not a crash):**
```json
{
  "error": "access_denied",
  "tool": "write_file",
  "project": "MyApp",
  "reason": "Project is in ADVISOR mode. Write access is not allowed.",
  "suggestion": "You can use read_file or list_files to inspect the project."
}
```

The AI receives this as a tool result, processes it, and explains the situation
to the user naturally. No crashes, no silent failures, no confused behavior.

---

## 8. ThreadSession — Runtime Container

`ThreadSession` is the runtime object that ties everything together for an active thread.
It is NOT persisted — it is assembled from SwiftData on thread activation.

```swift
@Observable
class ThreadSession {
    let thread: Thread                              // the persisted model
    let appSettings: AppSettings                    // global settings reference

    // Assembled once on activation, rebuilt on thread switch
    var validatedProjects: [ValidatedThreadProject] // project + validation state
    var providerState: ProviderValidationState      // snapshot validation result

    // Services (injected)
    let promptBuilder: SystemPromptBuilder
    let accessController: ToolAccessController
    let executionService: ToolExecutionService
}
```

**Lifecycle:**
```
User selects thread
    → ThreadSession.activate(thread, appSettings)
        → validate ProviderSnapshot
        → validate each ThreadProject
        → build initial system prompt
        → ready for AI calls

User switches thread
    → old ThreadSession is discarded
    → new ThreadSession is activated
    → NO state leaks between sessions
```

---

## 9. Data Storage Map

### Storage layers

| Layer      | What lives there                        | Why                                      |
|------------|-----------------------------------------|------------------------------------------|
| SwiftData  | All domain entities (JSON-in-Data)      | Structured, queryable, crash-safe        |
| Keychain   | API key values only                     | Secrets — encrypted, process-isolated    |
| UserDefaults | One-time migration flags only         | Tiny booleans, not secrets, not domain data |
| Filesystem | Nothing intentional                     | chat_history.json is dead legacy — remove |

### JSON-in-SwiftData pattern

All complex domain objects are stored as JSON inside SwiftData primitive fields (`Data` or `String`).
SwiftData `@Model` classes contain only: `UUID`, `Date`, `Bool`, `Int`, `String`, `Data`.

```swift
// ✅ Correct: store the struct as JSON blob
@Model final class ThreadEntity {
    var id: UUID
    var settingsJSON: Data   // encoded ThreadSettings
    var messagesJSON: Data   // encoded [ChatMessage]
}

// ❌ Wrong: embed complex types directly in @Model
@Model final class ThreadEntity {
    var settings: ThreadSettings  // causes SwiftData migration pain
}
```

**Why this pattern:**
- SwiftData schema migrations are painful and error-prone
- JSON-in-Data means the schema never changes — only the Codable struct evolves
- Full freedom to add/remove/rename fields in domain structs without touching SwiftData

### ⚠️ CRITICAL RULE — JSON field renaming

**Renaming a `Codable` property breaks existing stored data silently.**
Old JSON has `"maxMessagesInContext"` — if you rename it to `"contextLimit"`, the decoder
returns `nil` / default value, and the user's setting is silently lost.

**Rules:**
1. Never rename a `Codable` property that is stored in SwiftData without a migration plan.
2. If a rename is needed — add `CodingKeys` with the old JSON key mapped to the new property name.
3. Mark every persisted `Codable` struct with a comment:

```swift
// STORAGE: serialized to JSON in SwiftData.
// ⚠️ Do NOT rename properties without updating CodingKeys.
// Renaming breaks existing stored data silently.
struct ThreadSettings: Codable {
    var maxMessagesInContext: Int  // JSON key: "maxMessagesInContext" — do not rename
    var isUnlimitedContext: Bool   // JSON key: "isUnlimitedContext" — do not rename
    var activeProviderId: UUID?    // JSON key: "activeProviderId" — do not rename
    var activeModelName: String?   // JSON key: "activeModelName" — do not rename
}
```

4. When adding a new field — always provide a default value in `init` so old JSON decodes cleanly.

### Structs that are persisted as JSON (must follow the rename rule)

| Struct              | Stored in                          |
|---------------------|------------------------------------|
| `ThreadSettings`    | `ThreadEntity.settingsJSON`        |
| `ProjectSettings`   | `ProjectEntity.settingsJSON`       |
| `AIProvider`        | `AIProviderEntity.json`            |
| `ProviderSnapshot`  | `ThreadEntity.providerSnapshotJSON` (planned) |
| `ThreadProject`     | `ThreadEntity.attachedProjectsJSON` (planned) |
| `MemoryEntry`       | `MemoryEntity.entriesJSON`         |
| `[ChatMessage]`     | `ThreadEntity.messagesJSON`        |
| `AppSettings`       | `AppSettingsEntity.json` (planned) |

### Keychain key scheme

API key values are stored in Keychain, never in SwiftData.
Key format: `provider.id.uuidString` → API key string value.

```
Keychain entry:
  service = Bundle.main.bundleIdentifier  ("ru.chappie")
  account = provider.id.uuidString        ("550e8400-e29b-41d4-a716-446655440000")
  value   = "sk-aitunnel-..."
```

When `APIKey` gets its own `id: UUID` (per new entity graph), the Keychain key becomes `apiKey.id.uuidString`.

### Legacy to remove

| Item                          | Status   | Action                                    |
|-------------------------------|----------|-------------------------------------------|
| `SettingsManager.swift`       | Legacy   | Remove after providers refactor is complete |
| `KeychainManager.swift`       | Legacy   | Inline into `AIProviderStore` or keep as utility |
| `UserDefaults.keychainMigrationDone` | Legacy | Remove with `SettingsManager`        |
| `chat_history.json` (root)    | Dead file | Delete — ChatHistoryManager is gone      |

---

## 10. Migration Plan (from current state)

The current SwiftData schema has:
- `ThreadEntity` with loose references to providers via string/UUID fields
- `ProjectEntity` as a global shared entity
- `MemoryEntity` with a `scope` string field

Target migration steps (to be executed one per commit):

| Step | Task |
|------|------|
| M-01 | Design new SwiftData models (Thread, ThreadProject, ProviderSnapshot, MemoryEntry) |
| M-02 | Write MigrationService logic: map old entities → new entities |
| M-03 | Implement SystemPromptBuilder (replace current ad-hoc prompt assembly) |
| M-04 | Implement ToolAccessController (replace current ToolAccessControl.swift) |
| M-05 | Implement ThreadSession runtime container |
| M-06 | Wire ThreadSession into ChappieViewModel (replace current loose state) |
| M-07 | Update UI: validation badges on projects and provider chips |
| M-08 | Update UI: ProviderSnapshot picker in thread settings |
| M-09 | End-to-end test: switch threads, verify zero state leakage |
| M-10 | Delete old dead code (SettingsManager, KeychainManager legacy, chat_history.json) |

**Rule: each step is one commit. No bundling.**

---

## 11. What This Fixes

| Bug / Problem | Fix |
|---------------|-----|
| Project from thread A appears in thread B | ThreadProject is owned by Thread, not shared globally |
| AI model bleeds between threads | ProviderSnapshot is per-thread, validated on load |
| Memory from one project leaks into another | Memory lives in ThreadProject, not in global MemoryEntity |
| Deleting a provider breaks threads silently | ProviderSnapshot validation shows warning in UI |
| Moving a folder breaks project silently | PathMissing validation shows warning in UI |
| AI calls tools it shouldn't have access to | ToolAccessController hard-gates every call |
| AI gets confused by unavailable tools | Tool manifest in prompt only shows available tools |
| AI crashes on denied tool call | Structured denial response — AI explains to user gracefully |
| Renaming a Codable field silently corrupts data | CodingKeys rule + mandatory comments on all persisted structs |

---

## 12. Build Strategy — Feature Flag + `enum New` Namespace

### The core problem

We are rebuilding a live, working system. The old code works today.
We cannot afford to break it mid-refactor — especially after the incident where
a bad tool-feeding change made Chappie unable to do anything except chat.

**Rule: the old Chappie must be recoverable at any moment by flipping one switch.**

### Feature flag

A single file `FeatureFlags.swift` controls the switch:

```swift
// FeatureFlags.swift
enum FeatureFlags {
    /// When true: new entity graph, ThreadSession, SystemPromptBuilder, ToolAccessController.
    /// When false: old code path, exactly as before.
    /// Flip to false at any time to get the old Chappie back instantly.
    static let useThreadIsolationV2 = false
}
```

This flag is checked at the top of `ChappieViewModel` and at the SwiftData container setup.
Everything else branches from there.

### `enum New` — namespace for all new types

Good names are already taken by the old code. Instead of ugly `V2` suffixes,
we use `enum New` as a pure namespace (no cases, no instances — just a container):

```swift
enum New {
    // All new domain types live here during parallel construction
    struct AppSettings: Codable { ... }
    struct AIProvider: Codable { ... }
    struct APIKey: Codable { ... }
    struct AIModel: Codable { ... }
    struct Thread: Codable { ... }
    struct ThreadProject: Codable { ... }
    struct ProviderSnapshot: Codable { ... }
    struct MemoryEntry: Codable { ... }
    struct ProjectSettings: Codable { ... }

    class SystemPromptBuilder { ... }
    class ToolAccessController { ... }
    class ThreadSession { ... }
}
```

**Usage during parallel construction:**
```swift
let session = New.ThreadSession(...)
let snapshot = New.ProviderSnapshot(providerId: ..., keyId: ..., modelId: ...)
```

**When old code is deleted (M-10):**
1. Remove the `enum New { }` wrapper.
2. All types come out into the global namespace.
3. One Find & Replace: `New.` → `` (empty string).
4. Done. No rename cascade, no type conflicts.

### Folder structure for new code

New code lives in a parallel folder tree, clearly separated from old code:

```
ChappieCore/Sources/ChappieCore/
├── Models/                         ← OLD (keep untouched until M-10)
│   ├── AIProviderModels.swift
│   ├── ThreadModels.swift
│   ├── MemoryModels.swift
│   ├── ProjectModels.swift
│   └── AppConfig.swift
│
├── V2/                             ← NEW (everything under enum New lives here)
│   ├── Models/
│   │   ├── New+AppSettings.swift
│   │   ├── New+AIProvider.swift
│   │   ├── New+Thread.swift
│   │   ├── New+ThreadProject.swift
│   │   ├── New+ProviderSnapshot.swift
│   │   └── New+MemoryEntry.swift
│   ├── Storage/
│   │   ├── New+SwiftDataEntities.swift    ← @Model classes (thin wrappers)
│   │   └── New+AppSettingsStore.swift
│   ├── Services/
│   │   ├── New+SystemPromptBuilder.swift
│   │   ├── New+ToolAccessController.swift
│   │   ├── New+ThreadSession.swift
│   │   └── New+MigrationService.swift
│   └── FeatureFlags.swift
│
├── Services/                       ← OLD services (keep untouched until wired)
│   ├── AIOrchestrator.swift
│   ├── ToolExecution/
│   └── ...
```

File naming convention: `New+TypeName.swift` — makes it trivially easy to find
all new-architecture files and to grep for them.

### SwiftData containers — two separate stores

The new schema cannot share a SwiftData container with the old schema.
Two containers run in parallel:

```swift
// Old container (unchanged)
let oldContainer = try ModelContainer(for: ThreadEntity.self, ProjectEntity.self, MemoryEntity.self)

// New container (V2, only active when FeatureFlags.useThreadIsolationV2 == true)
let newContainer = try ModelContainer(for: New.AppSettingsEntity.self, New.ThreadEntity.self)
```

The new container uses a different store filename (`chappie-v2.store`) so there
is zero risk of schema collision with the old store.

### Switching order — tools are last

The most dangerous change is tool-feeding (the incident that broke Chappie).
Tool changes are done LAST, after everything else is verified:

```
Phase 1 — Data layer:       M-01 (models) → M-02 (migration)
Phase 2 — Logic layer:      M-03 (prompt builder) → M-04 (access controller) → M-05 (session)
Phase 3 — Wire up:          M-06 (ViewModel) → M-07, M-08 (UI)
Phase 4 — Verify:           M-09 (end-to-end test, zero leakage confirmed)
Phase 5 — Tools switch:     FeatureFlags.useThreadIsolationV2 = true  ← flip here
Phase 6 — Cleanup:          M-10 (delete old code, remove enum New wrapper)
```

**The flag is flipped only after M-09 passes.** Until then, the user always has
a working Chappie one `false` away.

### Rollback procedure

If anything goes wrong after the flag is flipped:
1. Set `FeatureFlags.useThreadIsolationV2 = false`
2. Build and run → old Chappie is back
3. Investigate, fix, flip again

No git revert needed. No lost work. Just one boolean.
