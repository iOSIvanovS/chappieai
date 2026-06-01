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

## 9. Migration Plan (from current state)

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
| M-10 | Delete old dead code |

**Rule: each step is one commit. No bundling.**

---

## 10. What This Fixes

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
