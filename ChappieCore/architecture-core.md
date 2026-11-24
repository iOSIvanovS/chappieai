# ChappieCore — Business Logic Package Architecture

## 1. Purpose

All business logic of Chappie. Completely independent of SwiftUI — testable without UI.

**Dependency rule:** ChappieCore → Foundation only. No SwiftUI, AppKit, or SwiftData.

---

## 2. Package Structure

```
ChappieCore/
├── Package.swift
└── Sources/ChappieCore/
    ├── ChappieCore.swift               # Public API table of contents
    ├── DataStore/
    │   ├── ChappieStorage.swift        # Protocol + ChappieStorageRelation (typesafe keys)
    │   └── SQLiteStorage.swift         # GRDB-based backend — sole production implementor (+ corrupt-record backup)
    ├── Models/
    │   ├── AIProviderModels.swift       # AIProvider, APIKey, AIModel, ProviderProtocol
    │   ├── AITunnelModels.swift         # AIMessage, AIUsage, AIMessageContent, AITunnelRequest (no temperature field by design: o-series/gpt-5 reject non-default values with HTTP 400, provider default is used)
    │   ├── AITunnelStreamModels.swift   # AIStreamChunk, SSE parsing models
    │   ├── AITunnelContentModels.swift  # Content block types (text, tool_use, tool_result)
    │   ├── AITunnelToolModels.swift     # Tool call/result wire models
    │   ├── AITunnelCacheModels.swift    # Cache control models (Anthropic prompt caching)
    │   ├── AppConfig.swift             # Centralized config (dynamic, per-thread). Default: 100 messages.
    │   ├── ChappieError.swift          # ChappieError enum
    │   ├── MemoryModels.swift          # MemoryEntry, MemoryStorage
    │   ├── MemoryScope.swift           # MemoryScope enum (.global / .thread(uuid) / .project(uuid)) + MemoryKeys.userName; thread and project scopes are both UUIDs, the enum prevents mixing them
    │   ├── MemoryEntryOrdering.swift   # Display order: type, then key, then id (id breaks ties of duplicate type+key after a backup import)
    │   ├── MemoryEntryPresentation.swift # Decides whether an entry has fields hidden from the one-line prompt view (drives "Show all fields")
    │   ├── CurlChappie/                # Curl-Chappie data model (HTTP request tool)
    │   │   ├── CurlHost.swift          #   Thread allow-list entry (origin + permission readOnly/readAndLogin/full + loginPath); CurlOrigin = the one definition of "same host"
    │   │   ├── CurlSecret.swift        #   Project secret METADATA (name, kind, host origin); values are never stored here
    │   │   └── CurlSecretCatalog.swift #   Names/kinds/hosts/ref syntax of EXECUTOR projects' secrets, appended to the curl tool descriptions so the model knows what to pass as `session` (never values; flags parts with no stored value)
    │   ├── ProjectModels.swift         # ProjectSettings (incl. curlSecrets), ProjectMetadata, ThreadProjectEntry
    │   ├── BuiltInProviders.swift      # Hardcoded provider presets (URL, protocol, icon, chat path, supportsPromptCaching, optional BalanceEndpoint; no models). `AIProvider.catalogId` = preset id, kept for stored-data compatibility
    │   ├── StorageIntegrity.swift      # StorageIntegrityIssue (damaged data report), LossyElement
    │   └── ThreadModels.swift          # ThreadSettings (incl. curlEnabled, curlHosts; manual Codable), ThreadMetadata, ThreadPayload
    └── Services/
        ├── CurlEngine/                 # Curl-Chappie engine (pass 2), app-wide actor (CurlEngine.shared)
        │   ├── CurlEngine.swift        #   actor: send/extract/sessionInfo/reset, rate limit (60/min), 401 -> one re-login, response building
        │   ├── CurlEngine+Prepare.swift #  placeholder substitution, allow-list gate on the FINAL url, header/body/query building, session auth
        │   ├── CurlEngine+Scenario.swift #  runner entry points: sendCapturing (redacted answer + raw one that never reaches the model), session variable read/store, last stored answer, redactForDisplay
        │   ├── CurlEngine+Login.swift  #   login recipe (extract rules + apply rules), single-flight, generation counter
        │   ├── CurlGate.swift          #   method x host permission x login path decision (pure)
        │   ├── CurlTemplate.swift      #   {{secret:name.field}} / {{var:name}}, single-pass, escaping per destination; names may hold spaces and any letters
        │   ├── CurlRedactor.swift      #   known values (plain/JSON/percent), credential-looking JSON keys, credential headers
        │   ├── CurlSession.swift       #   CurlSessionKey = origin + SHA-256 fingerprint of credential VALUES; in-memory session state
        │   ├── CurlCookiesAndPaths.swift # cookie jar per session key, JSON path extraction, `pick` (paths, [*] wildcard, trailing {a,b} field projection; applied to the redacted body only, skipped on 4xx/5xx)
        │   ├── CurlUnicodeEscapes.swift  #   decodes \uXXXX above ASCII in text bodies before redaction; ASCII escapes stay so JSON structure cannot change
        │   ├── CurlHeaderNoise.swift   #   deny-list of routine response headers (CORS, cache, date, server, security) folded into a count unless show_headers=all; unknown/custom headers stay visible
        │   ├── CurlTransport.swift     #   protocol + URLSession impl (no redirects, no cookie storage/cache, 5 MB body cap)
        │   ├── CurlContext.swift       #   hosts of the thread + secret metadata + value provider (Keychain)
        │   ├── CurlRequestModels.swift #   request/recipe/result value types, CurlError
        │   └── CurlResponse.swift      #   redacted result + text rendering for the model
        ├── CurlSecretKeychain/         # Keychain values of Curl-Chappie secrets, account "<secretId>.<field>"; deleted with the project; not in backups (user re-enters after migration). `apply` commits one settings-sheet save (empty typed value = keep stored; parts of a changed kind are dropped); `savedFields` drives "saved" hints without ever reading values into the UI
        │   (Models/CurlChappie/CurlValidation.swift: pure row validation + normalization for the settings tables, save gates `ThreadSettings.curlHostsAreSaveable` / `ProjectSettings.curlSecretsAreSaveable`)
        ├── AIClient.swift              # OpenAI-compatible HTTP client (entry point)
        ├── AIClient+HTTP.swift         # HTTP request building + response parsing
        ├── AIClient+Streaming.swift    # SSE streaming parser
        ├── AIClient+Balance.swift      # Separate balance GET for presets with a BalanceEndpoint (RouterAI /credits); never throws
        ├── StreamDiagnostics.swift     # Per-stream counters (finish_reason, chunks, skipped chunks, tool calls) and the STREAM END log line; flags tool calls flattened into text
        ├── StreamDump.swift            # Bounded in-memory buffer of raw SSE lines + StreamDumpReason (why a stream deserves a file); decides, never parses text into a call
        ├── StreamDumpWriter.swift      # Writes a dump to Application Support/ChappieAI/StreamDumps, prunes by count; never throws into the answer path
        ├── AIClient+Discovery.swift    # fetchAvailableModels()
        ├── AIClientProtocol.swift      # Protocol: validateProvider, streamChat, fetchModels
        ├── AIClientFactory.swift       # Factory: picks AIClient or AnthropicClient by protocol
        ├── AnthropicClient.swift       # Anthropic native API (/v1/messages); also serves gateways that expose that path
        ├── AnthropicClient+Streaming.swift       # Native SSE parser: content_block_start/delta/stop, usage, stream dump
        ├── AnthropicClient+MessageConversion.swift  # ChatMessage/tool -> Anthropic blocks; merge keeps tool_use_id
        ├── AnthropicModels.swift       # Anthropic-specific request/response models
        ├── AIOrchestrator.swift                  # Reasoning loop: core + process()
        ├── AIOrchestrator+Retry.swift            # streamWithRetry: thin adapter over LLMRetryRunner
        ├── LLMRetry/
        │   ├── LLMRetryRunner.swift        # THE retry loop: HTTP 5xx/429, network, timeout, stall, mid-stream cut
        │   ├── LLMFailureClassifier.swift  # error -> retry(reason, Retry-After, partial text) / fatal / cancelled
        │   ├── LLMHTTP.swift               # typed ProviderHTTPError, bounded error-body read for streams, Retry-After
        │   └── RetryPolicy.swift           # 5 retries, 1/2/4/8/16 s (cap 30) + jitter; RetryStatus for the UI
        ├── AIOrchestrator+ContextWindow.swift    # buildContextWindow, estimateTokens
        ├── ContextWindowPolicy.swift             # slice(history:limit:mode:anchorSignature:), allowance modes, PromptCacheProfile, cacheIsWarm
        ├── ContextWindowStateStore.swift         # per-thread last-request mark + window anchor + sent-prefix fingerprint; UserDefaults-backed, survives relaunch
        ├── SentPrefix.swift                     # head/prefix fingerprint of the request that went out, and the kept/changed verdict
        ├── ../Debug/RequestTrace.swift           # per-request canonical fingerprints of system/tools/messages + what changed; finds cache breaks
        ├── ../Debug/LogClock.swift               # ms timestamps for logs compared across processes
        ├── AIOrchestrator+ToolExecution.swift    # executeToolCalls, parseOutputFilePath
        ├── LoopGuard.swift                       # 3rd identical call with an unchanged result is blocked, with an explanation
        ├── AIProviderStore.swift       # CRUD for AI providers + Keychain (multi-key)
        ├── AppSettingsStore.swift      # Actor-based CRUD for singleton AppSettings
        ├── FileSystemManager.swift             # Secure FS: init, routing, read/write/delete/move
        ├── FileSystemManager+Listing.swift     # listFiles(project:): paths relative to that root. listFiles() exists for tests and returns prefixed paths; no tool calls it — list_files refuses without a project
        ├── FileSystemManager+Search.swift      # searchInFile, searchInProject, grep helpers
        ├── FileSystemManager+Patch.swift       # patchFile (exactlyOne policy), getFileInfo
        ├── FileSystemManager+Image.swift       # readImageData (view_image) — raw bytes, no UTF-8 decode
        ├── FileSystemManager+Size.swift        # fileByteSize: size check BEFORE read_file loads the file
        ├── PathGuard.swift                     # Project containment: rejects "..", absolute paths, symlinks leaving the root
        ├── MCPToolBridge.swift         # Bridge to ChappieMCP via Unix socket; asks the app to restart the helper and retries once if nobody listens
        ├── MCPHelper/
        │   ├── MCPSocket.swift         # Per-app-instance socket path (PID in name), stale-socket cleanup, connect probe
        │   └── MCPRestartPolicy.swift  # Crash restart back-off (1/2/4/8 s) and give-up rule
        ├── MemoryManager.swift         # Semantic memory (read/write/search) via DataStore
        ├── MemoryStore.swift           # Persistence CRUD for memory scopes
        ├── SaveQueue.swift             # Ordered write queue; failed write pauses until Retry/Skip
        ├── ImagePipeline/
        │   ├── ImageDownscaler.swift   # THE one place an image becomes a request part: long side ≤ 2000 px, JPEG, EXIF + alpha handled, on-disk cache of the downscaled copy
        │   ├── ImageValve.swift        # Emergency valve: past 40 images per request the OLDEST become a text note (normally inactive)
        │   ├── ToolImageResult.swift   # Marker form of "document text + its pictures" (read_document / fetch_attachment of Office files)
        │   ├── ScreenFrame.swift       # The live screen of a computer-use turn: carried BESIDE the history, appended as the last message so a cache breakpoint never covers it
        │   └── OfficeMediaIntake.swift # App side of the helper's extracted pictures: validate folder + files, downscale, delete the folder
        ├── CommandSafety/
        │   ├── CommandSafety.swift     # Safety NET against catastrophic command mistakes (rm -r on /, ~, system dirs; mkfs; dd/redirect to disks; shutdown/reboot by name; download | shell; fork bomb)
        │   └── CommandTokenizer.swift  # Small shell lexer: quotes, separators, pipes, heredoc bodies (data, not commands)
        ├── ToolWatchdog/
        │   ├── ToolDeadlines.swift     # THE table of allowed run time per tool class (also read by the UI bar) + timeout message
        │   └── ToolWatchdog.swift      # Races a tool call against its deadline; on expiry cancels it and answers the model
        ├── CurlScenarios/              # Curl-Chappie scenarios (D1 files + D2 runner). A scenario = JSON file `<folder>/<name>.json` in the PROJECT; knows no host and no secret names, only abstract slots (actors = login+password pairs, secrets = other slots) and inputs
        │   ├── CurlScenarioModels.swift #   value types: steps (request | call), expect, checks, login, inputs, cleanup
        │   ├── CurlScenarioDecoder.swift #  strict JSON -> model (unknown key = error, all problems collected)
        │   ├── CurlScenarioRules.swift #   limits (depth 5, 60 steps, 256 KB), identifier rule, `{{secret:slot.field}}` / `{{input:n}}` / `{{var:n}}` scanner
        │   ├── CurlScenarioValidator.swift # pure: slots, placeholders in order, call contract (inputs/returns/actors/secret slots), cycles, depth, `mutates` must be true if anything writes (login steps excepted, callee writes propagate)
        │   └── CurlScenarioStore.swift #   one folder of one project via PathGuard (no hidden dirs, no .xcodeproj, no symlink escape); list/load/write(atomic, pretty+sorted keys)/delete; `callers(of:)` for delete protection
        │   └── Runner/                 #   D2: CurlScenarioRunModels (request, scope, slot bindings), Substitution ({{input}}/{{var}} resolved by the runner, secret SLOTS rewritten to real secret names so values only ever meet the engine; values with "{{" refused), Checks (status default = any 2xx, equals/contains/exists on the RAW body), Preflight (args, secrets+values, host gate for every step that WILL run: main steps of all scenarios + ROOT cleanup), Runner (+Steps): main steps stop at first failure, ROOT cleanup always, cleanup step with a never-produced variable is skipped and reported, compact report, body only for failed steps (or verbose)
         │   Decisions: cleanup runs for the ROOT scenario only (nested cleanup never runs; root cleans everything using `returns`); a callee sees only `with`, the caller sees only `returns` (as {{var:stepId.name}}); folder is agreed with the user per project, tools take it as a parameter
        ├── ToolExecution/CurlTools/    # Curl-Chappie tools: curl_request / curl_session / curl_extract (pass 3) + curl_scenario_info / _save / _delete (D1) / _run (D2)
        │   ├── CurlScenarioRunTool.swift #  curl_scenario_run: maps arguments (host, actors, secrets, inputs, verbose, dry_run) onto CurlScenarioRunner; 600 s watchdog class, counted as mutating
         │   ├── CurlScenarioTools.swift #   scenario file tools; save validates everything before writing and warns about callers that stop validating; delete refuses while called
        │   ├── CurlTools.swift         #   executes the three tools on CurlEngine.shared; context = thread hosts + targeted project's secrets + Keychain
        │   └── CurlToolArguments.swift #   flat string args -> engine types (headers/query/form objects, extract/apply rule arrays, body choice)
        ├── JSONTools/                  # read-only json_* engine: parse with byte positions, no values built (see section 12a3)
        │   ├── JSONDocument.swift      #   flat node array in file order, ranges, lookup, line numbers; JSONParser.swift (iterative, maxDepth 512, maxNodes 4M)
        │   ├── JSONStyle.swift         #   indent, separator, EOL, escaping, key order, empty forms (used by json_info and copied by json_edit)
        │   ├── JSONPath.swift          #   path = array of segments (key, index, glob * ?, "**"), resolve, path(of:), JSONToolError
        │   ├── JSONText.swift          #   quoting, counts, line spans, JSONOutput.fit (the size ceiling), JSONToolArgs
        │   ├── JSONInfo.swift          #   json_info report
        │   ├── JSONSchema.swift        #   JSONShape + builder: merge nodes into shapes, dictionary detection
        │   ├── JSONSchemaRenderer.swift #  json_schema text from a shape
        │   ├── JSONFragment.swift      #   json_get: raw numbered lines when they fit, otherwise a collapsed view; missing-path diagnosis
        │   ├── JSONFinder.swift        #   json_find: query parsing (known arguments are closed), subjects (at), run, output/group_by
        │   ├── JSONFinder+Conditions.swift #   json_find conditions: AND form, OR form (match_any), same_as, not_contains
        │   ├── JSONToolEngine.swift    #   pure entry point (bytes + args -> text), UTF-16/32 refusal
        │   └── Edit/                   #   json_edit (J3): JSONEditOps (operation reader, strict fields), JSONEditPlanner (+Delete, +Insert: splices over the ORIGINAL bytes), JSONSplicer (order, overlap refusal, apply), JSONValueRenderer (writes a value in the file's style) + JSONValueEquality, JSONEditEngine (plan, apply, VERIFY), JSONEditReport (changed lines old/new: one place per merged original line, an insertion always stands alone and shows only what was added, lines are compared without their indent and without the separator comma so a shifted line is never printed as removed)
        ├── ToolExecution/JSONTools/    # JSONTools.swift: executor of the four readers (FileSystemManager.readData, path guard, 64 MB cap, detached task); JSONEditTool.swift: json_edit executor (read, engine on a detached task, write via FileSystemManager.replaceData)
        ├── FileSystemManager/FileSystemManager+Replace.swift # replaceData: atomic write only if the file still equals the bytes the edit was based on; keeps permissions, follows a symlink
        ├── ToolExecution/PDFTools/
        │   ├── PDFTools.swift          # pdf_info / pdf_page_as_txt / pdf_page_as_image: picks the file (uuid or project path), calls the helper
        │   └── PDFGuidance.swift       # Refusal text every other reader returns for a PDF, pointing to the pdf_* tools
        ├── OutputGuard/
        │   ├── OutputGuard.swift       # THE size gate for every tool result (200 KB read / 100 KB command), oversize notice
        │   ├── OutputCapture.swift     # Memory-capped collector for running commands (keeps head + tail window, counts all bytes); opens an OutputSpool past 100 KB
        │   ├── OutputSpool.swift       # Disk copy of a long command output (0600 file in tmp/chappie-terminal-output, 256 MB cap, cleanup by age 24 h and folder size)
        │   └── OutputGuard+Spill.swift # Model-facing notice for a spooled output: size, beginning, end, path, grep/sed/tail hint
        ├── ProcessControl/
        │   └── ProcessTree.swift       # Stop a process + descendants (SIGTERM, SIGKILL after grace); ProcessCanceller; copy lives in ChappieMCP
        ├── ShellSession.swift          # Persistent bash session (per-thread, run_terminal)
        ├── StallWatchdog.swift         # Cancels stalled AI streams after timeout
        ├── SystemPromptBuilder.swift   # Deterministic system prompt assembler
        ├── ThreadSession.swift         # Runtime container for an active thread
        ├── ThreadStore.swift               # Core: init, create/rename/delete, payload cache
        ├── ThreadStore+Chunks.swift        # Chunked message storage: read/write/lazy-load/pagination
        ├── ThreadStore+Projects.swift      # Thread-scoped project CRUD
        ├── ThreadStore+Settings.swift      # Settings CRUD, memory footprint
        ├── ThreadStore+Backup.swift        # exportAllPayloads/exportChunks — read-only, for BackupService
        ├── ThreadStore+Recovery.swift      # Damaged list repair: rebuild threads from message chunks
        ├── BackupService/
        │   ├── BackupModels.swift          # ChappieExportBundle, ExportedProvider, ExportedChunk
        │   ├── BackupCrypto.swift          # PBKDF2 + AES-256-GCM whole-file encryption
        │   └── BackupService.swift         # Assembles bundle from Stores (incl. Keychain secrets), encrypts
        ├── WebFetchService.swift       # Fetches web pages and extracts clean text
        └── ToolExecution/
            ├── ToolPolicy.swift                     # THE access table (deny by default) + ToolBlock (reason + fix) + decide()
            ├── ToolPolicy+Rules.swift               # The rules: thread layer (terminal/curl switches, bans) and project layer; return ToolBlock, nil = allowed
            ├── ToolStatus.swift                     # `[AVAILABLE in … / UNAVAILABLE in … — reason. To enable: fix]` label for tool descriptions, built from the same rules
            ├── ToolPolicy+Order.swift               # dangerOrder (harmless → dangerous, every classified tool once) and groupTitle (tools switched by the same setting)
            ├── ToolCatalog.swift                    # Pure: status line in front of each description, open tools first, closed ones compressed and grouped
            ├── ToolAuthorization.swift              # Target-project resolution, canonical project arg
            ├── ToolArguments.swift                  # Lenient arguments parser: 30 → "30", true → "true", null dropped, nested → JSON text
            ├── ToolDefinitions.swift                # Orchestrator: collects EVERY tool definition, adds status, hands over to ToolCatalog
            ├── ToolDefinitions+FileTools.swift      # File system, search, document, attachment tool defs
            ├── ToolDefinitions+MemoryTools.swift    # Memory tool definitions (IT-08)
            ├── ToolDefinitions+GitTools.swift       # Git tool definitions
            ├── ToolDefinitions+TerminalTools.swift   # Terminal, SSH, project mgmt tool defs
            ├── ToolExecutionService.swift           # Dispatches tool calls from AIOrchestrator
            ├── FileTools.swift                      # File tool implementations
            ├── GitToolExecution.swift               # Git tool execution
            ├── ComputerUseExecution.swift           # computer_screenshot / _move_to / _move_by / _click / _scroll / _type entry points, CGEvent synthesis, Accessibility check. The model moves a REAL cursor and clicks where it is: no pending aim, no stored point
            ├── ComputerUseScreenshot.swift          # MonitorMapping (the single place picture pixels ↔ CGEvent points are converted; long side capped at 1440 because providers silently resize anything past 1568 and every pixel count would then be wrong), captureWithCursor (SCScreenshotManager, showsCursor = true, so the system draws the true cursor shape; CGDisplayCreateImage fallback has no cursor), renderPicture (downscale only), buildOverviewResult (text: monitor, count, picture size, cursor position in PICTURE pixels)
            ├── ComputerUseOverview.swift            # computer_screenshot: captures the monitor with the real cursor and answers through buildOverviewResult. No grid, no drawing
            ├── ComputerUseTypeTool.swift            # computer_type: clicks the CURRENT cursor position to focus, pastes via clipboard (Cmd+V as a real Command down / V / Command up sequence) with the user's clipboard saved and restored, optional Return
            ├── ComputerUseScrollTool.swift          # computer_scroll in fractions 0...1 of the monitor image with an explicit monitor: scrollPoint() maps fractions to a CGEvent point from CGDisplayBounds (clamped, NaN becomes the middle), wheel event at that point, clean overview afterwards
            ├── MemoryTools.swift                    # Memory tool implementations
            ├── TerminalTools.swift                  # run_terminal / run_ssh implementation (ShellSession), safety-net refusal text
            └── SSHResult.swift                      # Model-facing text of a run_ssh result: full text or spill notice, finished and stopped cases
```

---

## 3. DataStore — The Persistence Foundation

### Storage Architecture

SQLiteStorage (GRDB) is the **sole** persistence backend. No SwiftData anywhere.

### ChappieStorage Protocol

```swift
public protocol ChappieStorage: Actor {
    func load<T: Codable & Sendable>(_ relation: ChappieStorageRelation) async throws -> T?
    func loadRawData(_ relation: ChappieStorageRelation) async throws -> Data?
    func save<T: Codable & Sendable>(_ value: T, for relation: ChappieStorageRelation) async throws
    func saveRawData(_ data: Data, for relation: ChappieStorageRelation) async throws
    func delete(_ relation: ChappieStorageRelation) async throws
    func deleteByPrefix(_ prefix: String) async throws   // atomic bulk delete — used by chunk system
    func replaceIndexedRecords(prefix: String, fromIndex: Int, payloads: [Data]) async throws // delete tail + insert, ONE transaction
    func preserveCorruptedRecord(key: String, data: Data) async throws -> String // copy unreadable bytes to "<key>.corrupt.<time>"
    func exists(_ relation: ChappieStorageRelation) async throws -> Bool
    func keys(withPrefix prefix: String) async throws -> [String]
}
```

### SQLiteStorage Schema

```sql
CREATE TABLE stored_records (
    relation TEXT PRIMARY KEY,
    payload  BLOB NOT NULL
)
```

One row per relation. The payload is a JSON-encoded domain collection.

### ChappieStorageRelation Keys

```swift
enum ChappieStorageRelation {
    case threads                            // "threads"
    case projects                           // "projects"
    case memory                             // "memory"
    case providers                          // "providers"
    case appSettings                        // "app_settings"
    case threadMessages(UUID)               // "thread_messages.<uuid>"  ← legacy, migration-only
    case threadMessagesChunk(UUID, Int)     // "thread_messages_chunk.<uuid>.<index>"
}
```

### Data Flow

```
Write:  DomainStruct (Codable) → JSONEncoder → Data → SQLite BLOB
Read:   SQLite BLOB → Data → JSONDecoder → DomainStruct (Codable)
```

Decode failure is non-fatal, but never silent: `SQLiteStorage.load` copies the unreadable bytes to
`<key>.corrupt.<time>` (idempotent per identical bytes) BEFORE returning `nil`, because callers
fall back to defaults and the next save overwrites the original. Applies to memory, providers and
app settings. The thread list has its own, stricter path (see "Integrity & write queue").

### Integrity & write queue

- **Thread list** (`ThreadStore.loadPayloads`): a missing record is an empty list; an unreadable one
  is backed up first (if the backup cannot be written, the call throws — nothing gets overwritten),
  readable elements are salvaged one by one (`LossyElement`), and a `StorageIntegrityIssue` is queued.
  The app layer drains it via `takeIntegrityIssues()` and shows a non-blocking banner.
- **Recovery** (`ThreadStore+Recovery`): chunk keys carry the thread UUID, so threads missing from a
  damaged list are rebuilt with the SAME id — messages and thread memory (scope key = thread UUID)
  re-attach automatically. Title: surviving title field of the broken entry, else the first user message
  (read as raw JSON, no app type needed), else a localized fallback passed to `init`. Lost for good:
  settings, attached projects (their memory scopes stay orphaned), original timestamps (messages have
  none). Runs only when the list is damaged — a healthy list never resurrects chunks of deleted threads.
  The repaired list is written back, so the repair (and the report) happens once; concurrent callers
  share one in-flight repair.
- **`SaveQueue`** (`@MainActor`): serial queue for user-data writes, used by the ViewModel instead of
  `Task { try? await save }`. Strict order; message snapshots with the same `coalesceKey` collapse into
  the newest; a failed write pauses the queue and the UI offers Try Again / Skip. Skip is safe for
  messages because every save writes the whole loaded window — the next save covers the skipped one.
- Rebuilding lost threads from orphan message chunks is a separate step (backlog 2b).

---

## 4. Message Chunk System

### Why Chunks

A single JSON blob for a thread with 1000+ messages can reach 50–150 MB.
Loading it all at once causes UI freezes and high memory pressure.

### Strategy

Messages are split into chunks of **500** per row.

```
thread_messages_chunk.<UUID>.0   → messages   0–499
thread_messages_chunk.<UUID>.1   → messages 500–999
thread_messages_chunk.<UUID>.2   → messages 1000–1499
...
```

Integer index (not zero-padded) — sorted numerically by `chunkIndices()`.

### Lazy Loading

- **Thread open** → only the **last chunk** is loaded into memory (O(1), fast).
- **Scroll to top** → `loadMoreMessages()` loads the previous chunk on demand.
- `hasMoreChunks` / `oldestLoadedChunkIndex` track pagination state in ViewModel.
- **Model context vs. window**: the window (last chunk) can hold only a few messages right after a chunk
  rollover (512 stored → 12 in memory). Before building the request history, `ChappieViewModel.ensureModelHistoryLoaded()`
  calls `loadOlderChunks(...)`, which prepends older chunks until the window holds `maxMessagesInContext + 1`
  messages that actually reach the model (tool logs and local notices do not count). `oldestLoadedChunkIndex`
  moves with it, so `saveLoadedMessages(fromChunk:)` keeps writing at the right position. Regression: `ThreadStoreOlderChunksTests`.

### Auto-Migration

On first access to any thread, `ThreadStore` checks for a legacy single-blob key
(`thread_messages.<UUID>`). If found, it is split into chunks and the legacy key deleted.
This is **transparent** — callers see no difference.

### API

```swift
// Fast open — returns last chunk + hasMore flag
loadMessages(fromThreadId:as:) → (messages: [T], hasMore: Bool)

// Full history — for AI context building, export, deleteOldMessages
loadAllMessages(fromThreadId:as:) → [T]

// Scroll-up pagination — returns previous chunk
loadMoreMessages(fromThreadId:currentOldestChunkIndex:as:) → (messages, hasMore, newOldestChunkIndex)

// Top-up for the model context — loads older chunks until enough eligible messages
loadOlderChunks(fromThreadId:currentOldestChunkIndex:alreadyEligible:needed:as:isEligible:) → (messages, hasMore, newOldestChunkIndex)

// Normal save of the in-memory window: replaces chunks >= fromChunk in ONE transaction,
// older chunks on disk are never touched.
saveLoadedMessages(_:toThreadId:fromChunk:)

// DESTRUCTIVE: replaces the whole history (clear memory, deleteOldMessages, tests).
replaceAllMessages(_:toThreadId:)
```

### Save rule

The UI holds only a window of the history (last chunk + whatever the user scrolled in).
The window start is owned by the ViewModel (`oldestLoadedChunkIndex ?? 0`) and passed
explicitly on every save — the store cannot infer it, because `loadAllMessages` also reads
everything. `oldestLoadedChunkIndex` is reset on thread switch.

Retention: history is **unlimited by design** (the 100-message trim was removed in 2026-06).
The user cleans up manually via Memory Management.

---

## 5. Codable Compatibility Rules

**Violation = silent data corruption.**

1. **Never rename a stored property without `CodingKeys`.**
2. **Never remove a stored property** — mark `optional` with a default.
3. **Always give new properties a default value.**

Structs that must follow these rules:

| Struct | Stored under |
|---|---|
| `[ThreadPayload]` | `.threads` |
| `[MemoryScope]` | `.memory` |
| `[AIProvider]` | `.providers` |
| `AppSettingsPayload` | `.appSettings` |
| `ThreadSettings` | inside `ThreadPayload` |
| `[ThreadProjectEntry]` | inside `ThreadPayload` |
| `ProjectSettings` | inside `ThreadProjectEntry` |
| `[MemoryEntry]` | inside `MemoryScope` |
| `[ChatMessage]` | `.threadMessagesChunk(id, n)` |

---

## 6. Project Model

Projects are **thread-local** — no global registry, no bookmarks.

```swift
struct ThreadProjectEntry: Codable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var absolutePath: String       // full path set at attachment time
    var settings: ProjectSettings
}
```

**Rules:**
- Added only by user (via `+` button or drag & drop). AI cannot add/remove.
- Duplicate check: same `absolutePath` → silently ignored.
- `FileSystemManager` reads `absolutePath` directly — no bookmark resolution needed.
- `list_thread_projects` is the only AI tool that touches projects (read-only).

---

## 7. Architecture Diagram

```mermaid
graph TD
    subgraph Foundation["Persistence Foundation"]
        SQL["SQLiteStorage (actor)\nGRDB backend — sole implementor"]
        Proto["ChappieStorage protocol\nAll Stores depend on this"]
        SQL --> Proto
    end

    subgraph Stores["Domain Stores (actors)"]
        TS["ThreadStore\n(chunked messages + project CRUD)"]
        MS["MemoryStore"]
        APS["AIProviderStore"]
        ASS["AppSettingsStore"]
    end

    TS --> Proto
    MS --> Proto
    APS --> Proto
    ASS --> Proto
    PS --> TS
    BKP["BackupService\nExport bundle + encryption"] --> TS
    BKP --> MS
    BKP --> APS

    subgraph Services["Services (actors)"]
        Orch["AIOrchestrator\nReasoning loop"]
        TES["ToolExecutionService\nTool dispatcher"]
        SPB["SystemPromptBuilder\nDeterministic prompt assembly"]
        TAC["ToolPolicy\nSingle access table, deny by default"]
        TSess["ThreadSession\nRuntime thread container"]
        MemM["MemoryManager\nSemantic memory"]
        FSM["FileSystemManager\nSecure FS access (absolutePath)"]
        SSH["ShellSession\nPersistent bash (per thread)"]
        MCP["MCPToolBridge\nUnix Socket client"]
        WFS["WebFetchService\nHTTP page fetch"]
        AICF["AIClientFactory\npicks client by protocol"]
        AIC["AIClient\nOpenAI-compatible HTTP"]
        AnthC["AnthropicClient\nAnthropic native HTTP"]
    end

    APS --> KC["Keychain\n(API key secrets)"]

    Orch --> AICF
    AICF --> AIC
    AICF --> AnthC
    Orch --> TES
    Orch --> SPB
    TES --> FSM
    TES --> MemM
    TES --> MCP
    TES --> TS
    TES --> WFS
    TES --> TAC
    TES --> SSH
    TSess --> MS
    TSess --> SPB
    MemM --> MS
```

---

## 8. Key Models

### ThreadSettings (default: 30 messages)

```swift
struct ThreadSettings: Codable, Sendable {
    var maxMessagesInContext: Int   // 10...100, step 10, default 30 (a FLOOR: see ContextWindowPolicy)
    var activeProviderId: UUID?
    var activeKeyId: UUID?
    var activeModelName: String?
}
```

### AppConfig (default: 100 messages)

```swift
struct AppConfig: Codable {
    static let shared = AppConfig()            // default: 100 messages
    init(settings: ThreadSettings)             // per-thread config
    let maxMessagesInContext: Int              // 10...100
    let stallTimeoutSeconds: TimeInterval     // 300s, hardcoded
}
```

**Unlimited mode is gone (2026-11).** `isUnlimitedContext` was removed from both structs; the window is always a
finite message count and the only thing that may exceed it is the cache allowance below. Decoding is safe by
construction: JSON ignores keys nobody asks for, so a stored `"isUnlimitedContext": true` simply decodes into the
message limit — no record can fail, no settings can be lost. Threads that had it on start trimming at their limit.

**Decision: no token budget and no orchestrator step cap.** Context depth is controlled by message
count only. Reasons: (1) the old `tokenBudget = messages × 500` was never enforced, only displayed in the
settings UI as a misleading number; (2) model windows are ~1M tokens and mandatory task decomposition keeps
real sessions around 200–300K; (3) tool results are not carried between requests (only user/assistant text
and attachments), and within one run provider prompt caching absorbs the growth; (4) the 500-step cap was a
loop guard, but real runaway protection is the repeated-call guard (`LoopGuard`, below), the Stop button
and the retry policy. The agentic loop therefore ends only on a final answer, cancellation or a fatal error.
Oversized single tool results are handled by one gate, `OutputGuard` (section 12b), not by a global cap.

---

## 9. AI Client Architecture

```
AIClientProtocol
    ├── validateProvider() async throws
    ├── streamChat(messages:config:onChunk:) async throws -> AIUsage
    └── fetchAvailableModels() async -> [String]

AIClientFactory.make(for:apiKey:model:) → AIClient | AnthropicClient
```

**Which protocol a request takes is decided per model id, not per provider** (`NativeAnthropicRoute` on a preset).
A gateway can serve Claude models over its own native `/v1/messages` path while its other models stay on the
OpenAI-compatible path. RouterAI: `modelPrefix: "anthropic/"` — any `anthropic/*` id goes to `AnthropicClient`,
everything else to `AIClient`. Stored models are never rewritten, so switching the preset back and forth costs
nothing. WHY it matters: on RouterAI's OpenAI route the gateway occasionally flattened a tool call into plain text
(4 dumps in one day, `finish_reason: stop`, no `tool_calls` key anywhere in the stream — the call was synthesised by
the translator and given up on). The native route never did it.

**Prompt caching differs by route.** On the OpenAI route the cache hint is a single top-level `cache_control`. On the
native route it is two block-level breakpoints — the end of `system` and the last block of the last message —
verified live on RouterAI: top-level there writes the cache and **never reads it back** (`read: 0` on every step),
while block breakpoints give `read` 16898 -> 17018 with `created` <= 18 (cost 1.84 -> 0.16 RUB per turn). The
`anthropic-beta: extended-cache-ttl-2025-04-11` header is sent only when caching is on, and only then does
`ttl: "1h"` take effect (without it the write silently becomes 0).

**RULE: a cache is a prefix, so the history is append-only.** Anything mutable must sit *after* the last
breakpoint. Violating this is silent and expensive: measured on RouterAI, replacing the computer-use screenshot
in place inside the history gave `read: 8953 (15%)` and `created: 50727` on every step — the whole prefix after
the change is written again. The live screen is therefore not history at all: `computer_*` tool results stay
text-only, the picture is carried beside the history (`ScreenFrame`) and appended as the LAST message, marked
`isScreenFrame`, so `applyingCacheBreakpoints` puts the breakpoint on the last *prefix* block before it. On the
OpenAI route the same message is simply the last user turn, which automatic prefix caching already treats the
same way. Never "clean up" past messages to save space — one edit costs more than the bytes it removes.

**The window keeps an allowance, or the cache is worthless.** A cache read needs a prefix byte-identical
to the previous request. Sending exactly `limit` messages evicts the oldest one on every turn, so the
first message after `system` changes each time and the cached prefix ends there — the system prompt is
read, the whole conversation is written again. `ContextWindowPolicy` therefore lets the history grow
past `limit` before cutting it back to `limit`.

**How far past depends on how the route bills (three modes).** Reading a cached prefix is cheap per
token but paid on every request and grows with the history; writing one is expensive and happens on
every trim. Measured on RouterAI's native endpoint (RUB per 1M: input 213, cache read 10, cache write
266), limit 30, ~5k tokens added per turn, 3 requests per turn:
allowance 1x -> 6.89 RUB/turn, 2x -> 4.04, **3x -> 3.61 (minimum)**, 4x -> 3.64, 10x -> 4.86,
55x (1M messages) -> 17.30. The curve is flat between 2x and 4x, so the choice is forgiving; past 10x
the read cost dominates. Modes: `.triple` for a route whose cache reads are confirmed, `.slack`
(= max(4, limit/8), the earlier measured value) for a route that accepts `cache_control` but whose
reads are unverified, `.exact` for a cold cache or no cache at all.

**Which mode is used is decided per turn, not per provider.** `AIClientProtocol.promptCacheProfile`
is nil by default; `AnthropicClient` reports a one-hour TTL when `supportsCaching` is on, which covers
both the native protocol and an OpenAI-format route pinned to Anthropic. With a profile the turn gets
`.triple` while the cache is warm and `.exact` once it is not; without a profile it gets `.slack`.

**A cold cache makes the wide allowance actively harmful.** After a pause longer than the TTL the old
prefix is gone, so a long history is written in full for no benefit: 232k tokens is 61.7 RUB in one
request, while cutting to the window first costs 4.4 RUB. Warmth is tracked per thread in
`ContextWindowStateStore` (UserDefaults-backed, `markRequestSent()` before each request) against
`ttl * 0.9`.

**The allowance alone does not stabilise the prefix — the window needs an ANCHOR.** This was the
expensive lesson of 2026-11-15. The caller passes the whole loaded history, which grows by a couple of
messages per turn; cutting purely on its length gives a window that slides: 112 -> newest 30, next
turn 114 -> newest 30. The window's first message moves two places, the cached prefix dies at its first
byte, and every turn is a full write. Live log: 19:39 `Trimmed 114 -> 30 (allowance x3, cache warm)`
followed by `CACHE WRITE | created: 84010 | cost: 23.8611 RUB`. `ContextWindowPolicy.slice` therefore
takes the signature of the message the window started at last turn and starts there again; the window
then grows forward from a fixed point until it genuinely outgrows its allowance (allowance, not limit),
one write per cycle, prefix reads in between.

**Why the anchor is a content signature with a copy number, not an index.** The app prepends older
history chunks on demand (`ensureModelHistoryLoaded`), so every index shifts by an unpredictable amount
between turns. A signature survives prepends. `WindowAnchor.signatures(for:)` adds a per-copy counter
because repeated text is ordinary — an assistant saying "ok" twenty times — and a plain role+text
signature would match a different copy each turn and re-cut the window every time. The hash is FNV-1a,
not Swift's `hashValue`, which is seeded per process: an anchor written before a relaunch would never
be found after one. Appending never renumbers existing copies (the between-turns case); prepending can,
which costs one re-cut and then settles.

**A stable window is not enough — the prompt TEXT must be byte-stable too.** Independent of the anchor,
two separate defects changed the prompt between launches, and each one alone made every restart pay a
full rewrite (`RequestTrace` showed `changed: first request of process`, `read 0 | wrote 98045`):

1. *Dictionary order in the JSON body.* `JSONEncoder` emits a `Dictionary` in an order seeded per
   process, and tool schemas hang off dictionaries (`AIToolParameters.properties`). Both clients now
   encode with `.sortedKeys`. Evidence: an unchanged struct encoded four times by four runs of one
   binary gave four different byte strings (canonical, i.e. sorted, hash identical throughout).
2. *Dictionary order inside a memory entry's payload.* A multi-key record (`{incident, pattern,
   corrective_action}` — long incident notes are stored like that) went through
   `json.values.first`, so the system prompt showed a *random* field per process. `MemoryEntry
   .promptDisplayValue` now picks deterministically: `value` if present, otherwise the smallest key;
   entries are also sorted by key. Measured live: `read 0 | wrote 98045` after relaunch against
   `read 94292 (99%)` within one process.

Both are invisible in a canonical (sorted) hash by construction, so `RequestTrace` cannot be the only
guard: the tests in `MemoryDatesTests` assert the *selection rule*, not just cross-run equality, and
were verified to fail on the old code.

**Why both facts are persisted, and why in UserDefaults.** In memory alone they are lost on every
relaunch, so the first turn after a restart rewrites the whole prefix — measured on a 104-message
history: 84079 tokens, 23.64 RUB, against 2.29 RUB when the prefix is read. Restarting between turns is
normal working practice, so that turn is the common case, not an edge one. UserDefaults rather than the
SQLite store because both facts are worthless within hours and a wrong guess costs one cache write:
they do not deserve a table, a migration or a write per request. Two dictionaries under two keys
(`chappie.cacheWarmth.lastRequestAt`, `chappie.contextWindow.anchorSignature`), keyed by thread, the
mark pruned to 24 hours on write. The default store in `AIOrchestrator.init` is the persisted one, so
forgetting to pass a store does not silently bring the old cost back; tests pass
`InMemoryContextWindowStateStore`.

**The anchor is stored after EVERY turn, warm or cold.** This looks wrong and is not: a cold turn still
sends its window, and that request IS the new prefix — the provider has it. Forgetting which message
started it makes the next turn cut at a different place and pay for most of the same prefix twice.
Measured 2026-11-16: a cold turn after a relaunch wrote 78824 tokens (21.43 RUB); the turn after it
still re-wrote 47k of the same 79k instead of reading them, because the anchor had been discarded. The
rule was "a cold cache means the prefix is gone anyway", which is true of the OLD prefix and false of the
one the cold turn just wrote. A stale anchor is harmless on its own terms: `slice` ignores one that is no
longer in the history and one too close to the end to fill a window, and never lets the window shrink
below `limit`. Covered by `ContextWindowAnchorPersistenceTests`.

**THE REQUEST BODY IS ENCODED WITH `.sortedKeys`, AND THAT IS A CACHE FIX, NOT A STYLE CHOICE.**
`JSONEncoder` writes a Swift `Dictionary` in an iteration order seeded PER PROCESS — it is neither
sorted nor stable. Measured 2026-11-16: one struct with a five-key dictionary, four separate runs of
the same binary, four different byte streams (canonical content hash identical all four times).
Tool schemas hang off dictionaries (`AIToolParameters.properties`) and `tools` is the FIRST part of
the prompt, so a new process changed the first bytes and everything after them was written again.
This is the real explanation of the relaunch behaviour chased through the whole of 2026-11-16:
within one process the first request read 98% of the prefix (`read: 85547, created: 1063`); the
first request after a relaunch read 0% and wrote all 85479 tokens. Every earlier theory — a sliding
window, a discarded anchor, an unstable system prompt — was a symptom of this one line.
Both clients set `outputFormatting = [.sortedKeys]`. It is pinned by
`RequestBodyDeterminismTests.toolKeysAreSorted`, which fails the moment the flag is removed —
verified by removing it and watching BOTH tests in that suite go red. Note that it also failed the
"same body twice in one process" test, so the ordering is not even stable within a single process.

**A changed head means a write, not a read — so the prompt is fingerprinted, not guessed about.**
An anchor keeps the window still, but says nothing about the tools and the system prompt that come
before it, and those are rebuilt every turn from memory, project settings and tool status. One
changed byte there kills the cache for the whole request, however perfectly the window is anchored.
`SentPrefix` records a canonical hash of what actually went out — `headHash` over tools + system
prompt, `prefixHash` over head + the first N messages, plus N itself — and the next turn compares.
N is stored because hashing "this request minus the newest exchange" can never match: the previous
request is always a STRICT PREFIX of the current one, so the two sides would hash different sets
every time and report a change on every turn. With N stored, the next turn hashes exactly the same
slice and compares like with like.

The verdict drives the window: `kept` keeps the wide allowance, `changed(head)` and `changed(msgs)`
force `.exact`, so the turn that is going to be written from scratch carries no more than the
configured window instead of an oversized prompt that costs the same write and more input tokens.
`unknown` (first turn of a process, route without a cache, unreadable stored value) is treated as
"will write" for the *window* decision only through the existing cold-cache path — a corrupt entry
is never a wrong answer, just one honest cut. The fingerprint is re-recorded before EVERY request of
the turn, because it is the last request of a turn that the provider holds in cache; mid-turn steps
carry tool results the window builder never saw. Tools are therefore fetched before the window is
decided, not inside the loop. Covered by `SentPrefixTests` (11 cases on the comparison) and
`ContextWindowPrefixTests` (5 on the window decision, verified to fail with the check disabled).

**What is still not stable, and why that is now harmless.** Editing memory mid-thread still changes
the system prompt, and the next turn is a genuine write — the fingerprint now SAYS so instead of
being surprised by it, and the window is cut back accordingly. The bytes themselves are already
stable across processes (see `.sortedKeys` and `promptDisplayValue` below), which is what makes the
comparison meaningful across a relaunch.

**Request tracing (`Debug/RequestTrace.swift`, `Debug/LogClock.swift`) exists so the next cache
question is answered by looking, not by inference.** Every outgoing request prints one line with a
canonical fingerprint of each part and what changed since the previous request:

```
[RequestTrace] 10:59:57.355 native+cache turn#4 req#2 | sys 65000ch h=92ba9d | tools 24 h=402ab8
  | msgs 33 h=c6791f | body 66919B raw=d01549 | changed: msgs
[RequestTrace] 10:59:57.358 native+cache turn#4 req#3 | … | changed: none
[RequestTrace] 10:59:57.361 RESPONSE anthropic | read 85547 | wrote 1063 | fresh 0 | out 263 | finish end_turn
```

`changed: none` is the line the cache wants. `bytes(encoding order only)` means the content matched
by canonical measure while the wire bytes did not — encoder ordering moved, which is exactly the
defect above. The window line carries the pause against the threshold (`cache warm (2m since last
of 54m)`) and the anchor state, and prints one line whether or not a cut happened, because the
"nothing was cut" case is the one that must show a standing window.

Earlier live measurement on the same gateway, 9 turns, limit 30, ~250-token messages, small slack:
exact window wrote 160026 tokens and read 22602 (43.94 RUB); with a slack of 4 it wrote 4744 and read
188468 (6.53 RUB). Over 15 user turns of three requests each: 3.42 -> 1.87 RUB per turn.
A cut can leave the history starting with an assistant turn; the API accepts that (verified).

---

## 10. AIOrchestrator — Reasoning Loop

Split across 4 files:
- `AIOrchestrator.swift` — core actor, init, `process()` agentic loop
- `AIOrchestrator+Retry.swift` — `streamWithRetry`, adapter over `LLMRetryRunner` (see "LLM request retry")
- `AIOrchestrator+ContextWindow.swift` — `buildContextWindow` (anchor-aware), `estimateTokens`, cache warmth
  (`allowanceMode(isCacheWarm:)`, `isCacheWarm()`, `markRequestSent()`)
- `ContextWindowPolicy.swift` — `slice(history:limit:mode:anchorSignature:)` (the anchor-aware cut) and
  `trim(history:limit:mode:)` (the anchor-free form, kept for its tests), the three allowance modes,
  `PromptCacheProfile`, the pure `cacheIsWarm(lastRequestAt:now:profile:)` threshold
- `ContextWindowStateStore.swift` — where the last-request mark, the window anchor and the sent-prefix
  fingerprint per thread live, plus `WindowAnchor` (FNV-1a signature with a copy number). UserDefaults by
  default, so all three survive a relaunch; see "The allowance alone does not stabilise the prefix" below
- `SentPrefix.swift` — `PrefixFingerprint`: a canonical hash of tools + system prompt (`headHash`) and of the
  head plus the first N messages (`prefixHash`), stored with N so the next turn compares like with like. Verdict
  is `kept` / `changed(head)` / `changed(msgs)` / `unknown`; see "A changed head means a write, not a read" below
- `AIOrchestrator+ToolExecution.swift` — `executeToolCalls`, `parseOutputFilePath`
- `LoopGuard.swift` — repeated-call guard. The 3rd identical call (same tool + arguments) in a row is blocked,
  but only while every previous result was identical (result hash compared); a changed result is progress and
  restarts the count, so polling `git_status` or re-checking a build is fine. A blocked call is not recorded
  (it did not run). The message explains why and what to do. Known gap, accepted: a loop whose result differs
  each time (a timestamp in the output) is not caught — only Stop ends it.

```
process(prompt, history, config, memoryContext)
  → systemPrompt (via ThreadSession)
  → buildContextWindow(history, config)
  → loop (no step cap; ends on final answer, Stop, or a fatal error):
      → streamWithRetry() → aiClient.streamRequestWithTools()
      → if tool_use → toolService.execute() (authorize via ToolPolicy, size-check via OutputGuard)
      → if text → return AIOrchestratorResult
```

---

## 11. SystemPromptBuilder — Injection Order

Pure value transformer — no async, no storage, no side effects.

1. Persona block (identity + rules), then a single `---` separator. No wrapper header such as "Memory Context".
2. `userName` if set
3. Project settings: one `ProjectSettings.formatForSystemPrompt()` block per project
4. Global memory block if not empty
5. Thread memory block (`## Thread Memory`) if not empty
6. Project memory: one block per project, if not empty
7. Tool manifest (injected separately by AIOrchestrator)

Order rule: **stable first, volatile last.** Rules and settings rarely change, memory changes often; providers cache
the request prefix, so a long unchanged prefix keeps the cache valid, and the task-specific memory sits at the end where
a model reads most attentively. Empty sections are omitted — no wasted tokens. Test: `blockOrderAndNoWrapper`.

**Project settings block (`ProjectSettings.formatForSystemPrompt`) carries only facts that no tool status carries:**
absolute path; for an EXECUTOR project also the test-writing permission (writing tests
goes through the shared write tools, so no tool status can express it), and the architecture / comment switches with
their language. Role, git level, compilation and test-run access are NOT repeated: the status line of each tool
states them (`ToolPolicy.status`). The thread's terminal setting is not injected either (the `run_terminal` /
`run_ssh` statuses carry it), and neither is any terminal setting. Behavioural rules (comment
style, how to handle architecture files) live in the persona rules, not in this block. Tests: `ThreadIsolationTests`.

---

## 12. ToolPolicy — one access table

`ToolPolicy.swift` holds one row per tool (`ToolCapability`): alwaysOn, terminal, forbidden, fileRead, fileWrite,
git, curl. **A tool without a row is denied.** `ToolPolicy.decide` is a pure
function `(tool, target project's ProjectSettings, thread terminal level, curl switch) → ToolDecision`.

`ToolAuthorization.swift` connects it to the live thread, for both questions with the same function:
- **Execution** — `authorize()` takes the call's target project ONLY from the explicit `project` argument, which is
  required for every project tool, even when one project is attached (decision 2026-11-12: one strict rule instead of
  behaviour that changes with the number of projects). Missing or empty → refused with the list of attached projects,
  never "the first one". No path-prefix hints and no all-projects mode for `list_files`/`search_in_project`: a path is
  always relative to the project root, because a project may contain a folder with its own name (`Chappie/Chappie/`).
  Rights of OTHER projects never apply. The canonical project name is written back into the arguments.
  A refusal of a project tool ends with `whereItWorks`: the attached projects where THIS tool is allowed ("This tool
  works in: A, B. Pass one of them in the 'project' argument"), or "No attached project allows this tool right now",
  or "No project is attached…". A thread-level refusal (terminal/curl switch off) gets no such tail, since no project helps.
- **Exposure** — `availableTools` offers EVERY classified tool (git_diff as FORBIDDEN). The old filter that hid tools
  nobody could run is gone: the model must know its whole toolbox, why a tool is closed, and what to ask the user to
  switch on. The status line (see below) carries that. The `project` argument of project tools lists all attached
  projects and is ALWAYS in `required` for project tools (curl_*, pdf path form excepted by `uuid`), exactly like `authorize`.

Rules worth knowing: ADVISOR reads only (files, search, json read tools); `git_log` is allowed at the read-only git level;
arguments of project tools must be a flat string map (otherwise refused with an explanation).
`git_diff` is permanently blocked. Tests: `ToolPolicyTests` (completeness check against `availableTools`).

**One wording for refusals and statuses.** The rules (`ToolPolicy+Rules`) answer with a structured `ToolBlock`
(reason, fix, permanent) instead of prose. `decide` renders it as the call-time refusal; `ToolPolicy.status` renders the
same block into the label that opens a tool description (`ToolStatus`): `[ALWAYS AVAILABLE]`, `[AVAILABLE in: A. UNAVAILABLE
in: B, C — reason. To enable: fix]`, `[FORBIDDEN — …]`. Projects with an identical block are merged into one clause. Tests:
`ToolStatusTests`.

**What the model receives (`ToolCatalog`).** Two lists, open tools first, then closed ones; each list goes from the
most harmless to the most dangerous tool (`ToolPolicy.dangerOrder`), so a safe tool is preferred over a risky one
that can do the same job (`write_file` before a shell redirect). An open tool keeps its full definition with the
status line in front of the description. A closed tool is compressed: empty parameters plus status and the first
sentence of its description; closed tools of one group with an identical status (`groupTitle`: Git, Curl-Chappie, …) share one description carried by the first member, the others refer to it.
Full definitions return as soon as the settings open the tool. Tests: `ToolPolicyTests` (exposure, order,
compression, project argument), `ToolStatusTests`.

**Curl-Chappie (`curl`)**: allowed only when the THREAD switch (`ThreadSettings.curlEnabled`, carried in
`ActiveMemoryContext.curlEnabled`) is on AND the targeted project is an EXECUTOR (the project supplies the secrets;
ADVISOR never gets the tools). Host rules (allow-list, per-host readOnly/readAndLogin/full) are the engine's job,
not the policy's: no per-request confirmation, the per-host permission is the user's consent. `curl_request` and
`curl_session` count as mutating for the watchdog (outcome unknown after a cut-off). Console logs carry method and
host only. `CurlSecret.isValidName` accepts letters of any script, digits, `_ - ` and single inner spaces, in step
with the `CurlTemplate` regex.

---

## 12a. LLM request retry — one system

Every failure of a model request goes through `LLMRetryRunner` (the old stall and timeout special cases are
folded into it). Only the model request is repeated; tools run outside the loop.

- **Classifier** (`LLMFailureClassifier`): retry = HTTP 408/425/429/5xx, `URLError` network/timeout codes,
  in-stream `overloaded_error`, `StallError`; fatal = 400/401/402/403/404/422, context overflow, parsing,
  429 about quota/billing; cancellation is never retried or wrapped.
- **Real error text**: streaming clients now read the (bounded, 4 KB / 5 s) error body, so the user sees the
  provider's message instead of "No response body", and a 400 "context length" is recognised as such.
  Context detection only applies to 400/413/422 — a 429 or 500 mentioning "limit" stays retryable.
- **Schedule** (`RetryPolicy`): 5 retries, pauses 1/2/4/8/16 s (cap 30) with ±20 % jitter; `Retry-After`
  raises the pause (ignored above 120 s). The pause is measured from the moment the error ARRIVED, ticking
  in 1 s steps, so a failure after a minute of model "thinking" does not eat the pause.
- **Slow failures** (timeout, stall) each cost the full request timeout, so they have their own cap
  (`AppConfig.maxStallRetries`) and end with an actionable message (context size, new thread).
- **Continuation**: if text had already reached the user (stall, connection reset, in-stream error), the
  retry appends the partial answer plus a "continue exactly where you left off" prompt and joins the texts;
  real progress resets the retry budget. A half-built tool call is never continued — the step restarts.
- **UI**: `onRetry(RetryStatus?)` → `StreamingState.retryLabel` → shown in the agent action bar
  ("Provider error 500 · retry 2 of 5 in 4s"). Cancellation and thread invalidation interrupt a pause.
- Tests: `LLMRetryTests` (classifier, HTTP parsing, schedule, runner with injected sleep).

---

## 12a1. Stream dump — a bad answer must be inspectable after the fact

A gateway can hand back a tool call as plain text instead of a structured delta (seen twice on RouterAI in 24 h,
never on AITunnel with the same model). By the time anyone reads the log, Xcode's console tail has dropped the raw
stream, so the question "who lost the call" cannot be answered. `StreamDump.swift` + `StreamDumpWriter.swift` fix that.

- **Buffered in memory, written only when something looks wrong.** A healthy turn is 100–500 KB of SSE, so writing
  every request would cost a disk write per step. Both stream parsers (`AIClient+Streaming`, `AnthropicClient+Streaming`)
  feed a `StreamDumpRecorder` with each raw line; after the stream ends `StreamDumpRecorder.reason(for:forced:)`
  decides whether the buffer deserves a file.
- **Reasons, in priority order** — `flattened-tool-call` (the `[tool_use id=` marker; triggered by the marker ALONE,
  so a flattening that hides behind other structured calls is still caught), `skipped-chunks`, `malformed-tool-arguments`
  (accumulated arguments are not valid JSON), `no-finish-reason`, `forced`.
- **A dump is a diagnostic, never an execution path.** Nothing is ever parsed out of the text as a tool call: prose
  about tools contains the same characters, and a parser that mistakes an explanation for a call would act on words the
  model only meant to say. The file exists so the raw stream can be read by a person.
- **`CHAPPIE_STREAM_DUMP=1`** saves every request, for capturing healthy samples to compare against.
- **Where**: `Application Support/ChappieAI/StreamDumps/`, name `yyyy-MM-dd_HH-mm-ss_<reason>.log` in UTC, so the
  newest fault can be found by listing the folder. 40 files kept, oldest pruned by name order.
- **Content**: a header (reason, host, protocol, model, upstream model/provider as the gateway reported them, finish
  reason, chunk/skipped counts, per-tool-call argument size and JSON validity), then the assembled text, then the raw
  SSE lines exactly as they arrived. The buffer cap (4 MB) is stated in the file when it truncated.
- **Privacy**: a dump holds the whole conversation that was sent, including tool arguments and results. Files stay
  local, are never uploaded, and old ones are deleted by count.
- **Failures are swallowed**: a dump that cannot be written prints one line and lets the answer through untouched.
- **Empty arguments are valid.** A tool with no parameters gets one empty `partial_json` delta, so the accumulated
  string is `""`; that is `{}`, not "malformed". Before this rule a healthy parameterless call produced a 600 KB dump
  named `malformed-tool-arguments` — a diagnostic that lies in its own file name, which is worse than no dump.
- Tests: `StreamDumpTests` (healthy stream writes nothing, each reason, marker outranking milder reasons, buffer cap,
  file contents, pruning, empty recorder writing no folder, parameterless call silent).

## 12a. ImagePipeline — images sent to a model

> **RULE: every image that enters a request goes through `ImageDownscaler`.** Providers bill an image by pixels,
> not bytes, so the cap is on the long side (2000 px), and the result is re-encoded as JPEG (alpha flattened on
> white, EXIF rotation applied, animated GIF → first frame). Small images (≤ 2000 px and ≤ 1.5 MB) pass untouched.

- Callers: attachment encoding in the app (`ChappieViewModel+Multimodal.imagePart`, used for both the current
  message and history rebuilds), `view_image`, and `fetch_attachment` for images.
- The original file is never modified. For attachments the downscaled copy is cached at
  `Application Support/Chappie/ImageCache/<attachment id>.jpg` (outside the attachment folder, because
  `AttachmentStore.resolve` returns the first file of that folder) and reused while the original is not newer.
- **All images stay in the history** (decision: the model may compare images across the whole window); the downscale
  is the saving. `ImageValve` is only a safety net against provider limits on image count / request size.
- `view_image` and `fetch_attachment` return an image behind `ToolExecutionService.viewImageMarker`; only the tools in
  `imageResultTools` are honoured, so a text file that imitates the marker is judged as ordinary text.
- `fetch_attachment` for any other binary type returns only size and type, never base64 text.
- **Pictures inside Office documents.** `read_document` (and `fetch_attachment` / attached Word, Excel, PowerPoint,
  ODT) gives the model the document text AND its pictures as real images. The helper extracts the media into its own
  temp folder and reports it in separate response fields (`mediaDir`, `media`) — never inside the text, so document
  text cannot name a file for the app to open. `OfficeMediaIntake` accepts only a folder that is a direct child of
  the shared media root and only regular (non-link) files directly inside it, downscales through `ImageDownscaler`,
  and deletes the folder. The result travels as `ToolImageResult` (marker `__CHAPPIE_DOC_IMAGES__:`); only
  `documentImageTools` are honoured. `AIOrchestrator` turns it into a tool message (text) plus a user message
  (labelled images); the ViewModel does the same for attached documents (`multimodalParts(for:)`). `OutputGuard`
  judges the TEXT by the 200 KB limit; the pictures are bounded by the pipeline (≤ 20 per document) and by a 40 MB
  cap on the whole marker form.
- Source files up to 50 MB are read (`FileSystemManager.maxImageBytes`); this only guards memory.

Tests: `ImagePipelineTests`.

## 12a2. ToolWatchdog — the one time gate for tool calls

> **Same rule as OutputGuard:** `ToolExecutionService.execute` wraps every call in `ToolWatchdog.run`. A new tool
> is covered automatically (default 2 minutes); give it a row in `ToolDeadlines.seconds` only if it legitimately
> runs longer.

A tool that never answers must not freeze the model's chain of work. On expiry the watchdog cancels the tool's
task (the existing Stop path: the bridge closes its socket, the helper kills the process tree, the shell session
is killed) and returns a message instead. It does not wait for the tool to finish: a call stuck in an
uncancellable system call is abandoned and its late result is dropped.

| Class | Deadline |
|---|---|
| files, search, documents, memory, attachments, web, json | 2 min |
| git status/log/add/reset/checkout | 3 min |
| run_terminal / run_ssh | 5 min; a longer requested `timeout` is honoured (+30 s grace) up to 30 min |
| git commit / revert / push | 12 min (above the helper's own 10 min cap, which normally fires first) |

The message tells the model the outcome: mutating tools (`ToolDeadlines.isMutating`) are reported as
"RESULT IS UNKNOWN, check state, no automatic retry"; readers as "nothing was changed". The clock starts at real
execution. The UI shows the allowed time as a
pie that fills clockwise in the tint colour in place of the spinner of the agent action bar (`StreamingState.toolBudget`;
no number; a bar under the row was rejected because it made the label jump). Tests: `ToolWatchdogTests`.

## 12a2. PDF tools — a PDF is read only page by page

`pdf_info`, `pdf_page_as_txt`, `pdf_page_as_image` (definitions in `ToolDefinitions+PDFTools`, execution in
`ToolExecution/PDFTools/PDFTools.swift`, reading in the helper with PDFKit). Decisions:

- **Every other reader refuses a PDF** (`read_file`, `read_document`, `search_in_file`, `fetch_attachment`) with
  `PDFGuidance.refusal`, which names the three tools (and the attachment uuid when there is one). Reason: the earlier
  one-blob read depended on Homebrew's pdftotext and fell back to a byte scan that produced ~200 KB of garbage for
  compressed files, which the OutputGuard then refused with a misleading "too large".
- **`page` is mandatory** for `pdf_page_as_txt` (single page or range) and `pdf_page_as_image` (single page), checked
  in the app before the helper round trip. `pdf_info` takes none and lists the text volume per page, so the model
  decides what to read. No automatic rendering, no page cap heuristic.
- **Source:** `path` (+ `project`, resolved like other tools, never guessed) or the `uuid` of an attachment. Classified
  `alwaysOn` in `ToolPolicy` because an attached PDF can exist in a thread without a project; project paths stay inside
  the project through the helper's PathGuard.
- **Page picture** returns as a `ToolImageResult` like an Office picture: `pdf_page_as_image` is in
  `documentImageTools`, so the text is judged by OutputGuard and the picture is shown to the model as an image.
- **A chat attachment of a PDF** is inlined as a reference line with its uuid (`pdfReferenceText`) instead of its
  bytes; the model reads it with the pdf tools.
- Standard deadline (2 min), not mutating. Tests: `PDFToolsRoutingTests` (here) and `PDFToolsTests` (helper).

## 12a3. JSON tools — read big JSON files without reading them

`json_info`, `json_schema`, `json_get`, `json_find` (definitions in `ToolDefinitions+JSONTools`, policy: `fileRead`, ordered
right after `get_file_info`) and `json_edit` (same file, policy: `fileWrite`, ordered after `patch_file`, mutating for the watchdog). They run in the app, not in the helper: bytes come from `FileSystemManager.readData`
(same `PathGuard` as `read_file`, size checked before reading), the engine is pure (`JSONToolEngine.run`).
Decisions:

- **Positions, not values.** The parser records byte ranges only. The same document will let `json_edit` (pass J3)
  splice a fragment and leave every other byte alone.
- **Paths are JSON arrays of segments**, never dotted strings, because keys contain dots. `*`/`?` glob, `**` any depth,
  integers index arrays (negative from the end).
- **Every answer is bounded**: `max_chars` default 8000, clamped 1000..40000, enforced by `JSONOutput.fit` and by the
  collapsed view choosing the deepest level that still fits. Per-level member caps (40/12/5/3) keep a big map readable.
- **Errors teach**: a missing path says where it stops and lists the keys there, closest first.
- **Absence is a first-class question** (`json_find` `missing`), the thing `search_in_file` cannot answer.
- No recursion over document depth anywhere in tool code (small worker stacks): parser and renderer use explicit stacks;
  the schema builder recurses only `depth` levels (max 20).
- Readers: standard deadline, not mutating. Tests: `JSONToolsTests`, `JSONDocumentTests`.

### json_edit (pass J3)

Operations: `set`, `delete`, `insert` (key + `position`: auto/start/end/sorted/{after}/{before}/index), `rename`; each may carry
`expect` (not insert). `dry_run` shows the report and writes nothing.

- **Splices, not a serializer.** Every change is "replace bytes a..<b of the ORIGINAL file with this text". The result is built by
  copying the original between the splices, so bytes outside them are identical by construction. All paths refer to the original
  file, so the order of operations in one call never matters.
- **New fragments copy the file**: `JSONValueRenderer` uses indent unit, key separator, EOL, `\/` and `\uXXXX` habits, the empty
  form (Xcode's `{`, blank line, `}`), and multiline vs inline by what the file mostly does. Key order inside a new object is the
  order the model wrote: the executor takes `edits` from the RAW call text, because the flat argument map re-encodes with sorted keys.
- **Delete** cuts a run of neighbours with ONE comma (not last: up to the next member; reaching the end: from the end of the member
  before). A comment in any touched gap refuses the edit. **Insert** into one place is grouped (one splice, commas right); `auto`
  keeps an alphabetical object alphabetical, otherwise appends; a comment at the insertion point refuses.
- **Proof before writing** (`JSONEditEngine.verify`): bytes outside the splices equal the original; the result parses; no duplicate
  key appeared; each edited path holds exactly the requested value (paths through array positions are not re-checked, other
  operations of the call may shift them). Any failure means nothing is written.
- **Refusals instead of guesses**: path matching 0 or >1 places, two edits on the same place, insert of an existing key, key freed by
  a rename in the same call, `sorted` on an unsorted object, root delete, value nested deeper than 64. All problems of one call are
  listed together. A no-op edit reports "No change" and writes nothing.
- **Write**: `FileSystemManager.replaceData` re-reads the file and refuses when it differs from what the edit was based on.
- Limits: 2000 operations per call, 64 MB file. Tests: `JSONEditTests` (incl. byte-identical remove/restore round trip on a generated
  catalog; on the real 845 KB xcstrings the same round trip was checked once by hand, not kept as a test).

### Argument types in the schema (pass J4)

A tool argument is declared with the type it really is. A string-only declaration for a number, a flag or a list makes the model send
`"true"` and `"[…]"` as text and leaves it guessing what an element looks like.

- **`AIToolProperty` gained `items`** (`AIToolItemShape`): the shape of an array's element. It is a class, not a struct, because an
  element shape may itself contain an array and a value type cannot hold itself. `ToolDefinitions+JSONTools` uses it for
  `json_edit.edits`: an array of operation objects, with the four op forms in the element description.
- **`json_edit`**: `edits` is `array` of `object`, `dry_run` is `boolean`, `max_chars` is `integer`.
- **`json_find`**: `limit` is `integer`, `ignore_case` and `match_any` are `boolean`, the rest stay `string` (they are paths, globs and free text).

### Why json_find grew `same_as`, `not_contains`, `match_any` (pass J5-b) and refuses unknown arguments

The reader of these tools is a model, so the shape was chosen for how a model writes a call, not for a query language:

- **No nested condition groups.** A boolean tree (`any_of: [[…],[…]]`) is a second language inside an argument; models get
  brackets and nesting wrong, and a wrong tree still parses and answers a different question. Flat arguments stay checkable.
- **`match_any` is one flag, not a tree.** AND is the default and OR is the same conditions with the flag. The case that really
  needs a mix (some AND, some OR) is two calls, and each call stays readable.
- **`same_as` takes a path, not a value.** "Translation equals the English text" compares two places of the same subject, so it
  cannot be written as a literal. It follows `ignore_case`; a subject lacking the other path never matches.
- **`not_contains` completes the pair** with `contains`, as `not_equals` does with `equals`. A model that finds half of a pair invents
  the other half's name.
- **Unknown arguments are refused, naming the offender and listing the known ones.** Before this, an invented `equals_path` was
  dropped silently, no condition remained, and the search answered a different question with no sign of it.
  `jsonFindDeclaredEqualsKnown` pins the declared schema to `JSONFindQuery.knownArguments`, so the two cannot drift.
  **`json_schema` / `json_get`**: `depth` is `integer`.
- **The wire carries it**: `AnthropicClient.convertTool` maps `items` recursively into `AnthropicToolProperty`, so an Anthropic request
  keeps the element shape instead of a bare `"array"`. OpenAI-style requests encode `AIToolProperty` directly.
- **Leniency stays.** The declarations changed, not the readers: `ToolArguments` still flattens `true` → `"true"` and a JSON array to
  compact text, and `JSONEditArguments` still takes `edits` from the raw call text (so key order survives). A model that repeats an old
  habit still works; a test pins both.
- Tests: `ToolSchemaTypesTests` (declared types, no array without items, `items` on the Anthropic wire, lenient old shapes).

### Xcode string catalogs via json_* (pass J5-c)

After `loc_*` were removed, the knowledge of the `.xcstrings` format would have gone with them, so `json_edit`'s description
carries a short recipe (built once in `xcstringsRecipe`, shared by the description text): top level
`{"sourceLanguage","strings","version"}`, an entry is `{}` or `{"comment","extractionState","localizations"}`, a localization is
`{"stringUnit":{"state","value"}}` or `{"variations":{"plural":…}}`, `state` ∈ translated / needs_review / new / stale. Two worked
operations (add a language to a key, mark a translation finished), the `json_find` call that lists keys still missing a
translation, and the warning that a whole-file rewrite silently drops `comment`, `extractionState` and `variations`.
This is format documentation, not an environment gate: nothing in the tool behaves differently for that file.

Verified live on a copy of the real `Chappie/Localizable.xcstrings` (785.9 KB, 28 759 lines, 449 keys, 10 languages):
the two-operation call inserted `uk` between `ru` and `zh-Hans` with `position:"sorted"`, changed one `state`, and left
`extractionState` (2 × stale), `comment` (76), the key count and the zero `\/` escaping untouched; `json_find missing`
answered 448 of 449 and `same_as` found the 7 Russian texts copied from English. The catalog is alphabetical (0
out-of-order pairs of 449), which is what makes `"position":"sorted"` usable on it.

## 12b. OutputGuard — the one size gate for tool results

> **RULE FOR ANY NEW TOOL: its result must leave through `ToolExecutionService.execute`.** That method wraps
> the private `executeUnguarded` and passes every result through `OutputGuard.apply`. Never call a tool's
> implementation (or `mcpBridge.execute`) from somewhere else and hand its text to the model — that would
> bypass the size gate. A tool that runs a process and returns its output (output size unknown until it
> has run) must also be added to `OutputGuard.commandTools`; a test checks that this set stays a subset of the
> classified tools. Everything else is covered automatically as a "read" result.

What is measured is the **prepared result** (UTF-8 bytes of the text that would go to the model), not the size
of a source file: a 10 MB Word file with 100 KB of text passes, a 1 MB plain-text novel does not. Images are not
counted here (`view_image` carries a data URI that the orchestrator turns into a real image part; the image
pipeline has its own rules).

| Kind | Tools | Limit |
|---|---|---|
| read | everything not listed as command: files, documents, search, memory, web, attachments | 200 KB |
| command | `run_terminal`, `run_ssh`, `git_*` | 100 KB |

**Over the limit nothing is cut.** No head/tail/middle: the model gets a notice with the real size and the limit
and is told to ask the user for less data (read) or to narrow the command and check state before re-running
(command: it has already executed, so refusing the result is not "undoing" it). `web_fetch` keeps its own
100 000-character truncation (decided separately).

Memory safety: `read_file` asks `fileByteSize` first, so a 50 MB file is refused without being loaded.
Running commands collect output through `OutputCapture` (`ShellSession`, `run_ssh`): storage stops at
`captureCap` (200 KB), only the byte count keeps growing, and a tail window is kept so the exit code and the
end-of-output sentinel are still found. A cut stream appends `[[CHAPPIE_OUTPUT_TRUNCATED:<bytes>]]`; the gate
sums the markers (stdout + stderr) and judges the real size. `MCPToolBridge` refuses a helper response
over 10 MB with the same notice.

Spool (run_terminal and run_ssh): when a command's output passes the command limit, `OutputCapture` opens an
`OutputSpool` file and from then on every byte goes to disk as well. `ShellSession` then returns not a refusal but a
notice (`OutputGuard.spillNotice`): size, line count, the first ~8 KB, the last ~8 KB, the file path and
`grep`/`sed`/`tail` commands for the middle. The hint names terminal commands on purpose: file tools take
project-relative paths only (`PathGuard` rejects absolute ones), and the spool folder is outside every project. The
exit-code line and the sentinel the session appends are cut off the file. A timeout or Stop on a command that already
spooled returns the same notice. If the folder cannot be created, or the output turns out to fit the limit, the old
in-memory behaviour applies.

`run_ssh` spools the same way (stdout and stderr get their own file), but has no trailer of its own to cut.
`SSHResult` shapes its text: `finished` gives the exit code and both streams, `stopped` (timeout or Stop) keeps
whatever the remote host had already printed instead of reporting only the reason. Before this, ssh collected
output without a spool directory: everything past `captureCap` was lost and a result over the limit was refused
outright, so the model saw nothing. Covered by SSHResultTests (8 cases, collectors instead of a live host).

Not yet covered (helper side, ChappieMCP has no test target): `ProcessRunner` still reads build/git output
to the end in memory. Its callers already return a bounded summary (build/test: last lines + errors), and
git output is small in practice; a cap there is a candidate for a later pass. Images are item 10b-2.

Tests: `OutputGuardTests` (thresholds on the byte boundary, UTF-8 counting, notices, capture, real shell
runaway, end-to-end through `execute`).

---

## 13. ShellSession + TerminalTools

`ShellSession` — persistent bash process per thread ID.

**Terminal switch (`ThreadSettings.terminalEnabled`, `ActiveMemoryContext.threadTerminalEnabled`).** A plain on/off
thread setting; there is no confirmation mode. Decision (2026-11-12): the three-level `none / confirm / auto` setting and
everything around it (confirmation sheet, `PendingTerminalCommand` marker, `TerminalDecisionGate`, `executeConfirmedCommand`)
were removed: the confirm path had its own failure modes and the safety net below plus the per-thread switch are the
only barriers. **Migration:** `ThreadSettings.init(from:)` reads the legacy `terminalAccess` key as a plain string with
`try?` (so no stored shape can fail the whole record); only `"auto"` turns the switch on, `none`, `confirm`, garbage, a
non-string or a missing key leave it off. The new key wins when both exist; `encode` writes only `terminalEnabled`.
`ProjectSettings.terminalAccess` was deleted outright (unknown keys never fail decoding, so old project JSON is safe and
the `[ThreadProjectEntry]` list cannot be lost). Tests: `TerminalSwitchMigrationTests`.

**CommandSafety — a net for mistakes, NOT a security boundary.** Decision (backlog 11): the old substring blocklist
is gone. It blocked harmless commands (`rm -rf /tmp/x` contains "rm -rf /"; "reboot" inside a commit message) and was
bypassed by `rm -fr /`, so it gave a false sense of safety. `CommandSafety.violation(in:)` now lexes the line
(`CommandTokenizer`: quotes, `; && || |` newline, subshells, heredoc bodies treated as data), peels wrappers
(`sudo`, `env`, `nohup`, `xargs`, ...), normalizes flags (`-fr`, `-r -f`, `--recursive` are equal) and looks at the real
command: recursive `rm`/`chmod`/`chown` on `/`, `~`, `$HOME`, or a top-level system folder; `mkfs`/`newfs`;
`dd of=/dev/…` and redirects onto raw disks; destructive `diskutil`; `shutdown|reboot|halt|poweroff` as a command
NAME; `curl|wget … | sh`; fork bomb. `bash -c '…'` and `eval` are analysed recursively (depth-limited); a heredoc fed to
a shell is inspected, any other heredoc is data. Indirection (variables, scripts written then run, `$(…)` in quotes)
is NOT caught and the refusal text says so. The real guard is the thread terminal switch; do not grow this list to chase
bypasses. Applies to `run_terminal` and `run_ssh`.


**Cancellation (Stop button).** `cancelCurrentRequest()` cancels the request Task; every long wait honours it:
- `MCPToolBridge.sendRequest` wraps the socket call in `withTaskCancellationHandler`; cancel half-closes the socket (`CancellableCall`), which wakes the blocked `recv` at once. The helper sees the hang-up and kills the tool's processes (see ChappieMCP/architecture-mcp.md). A cancelled call is never recovered/retried.
- `ShellSession.readUntilSentinel` returns immediately on cancel and then `killSession()` stops bash **and its children** (`ProcessTree`); the next command starts a fresh bash (cwd comes from the `cd` prefix).
- `run_ssh` stops its ssh process through a `ProcessCanceller` (the detached polling task does not inherit cancellation).
- `AIOrchestrator.executeToolCalls` calls `Task.checkCancellation()` after each tool, so a cancelled tool's text is never sent back to the model and the rest of the step is skipped.

---

## 14. MessageTimestamp — time labels for user messages

`Services/MessageTimestamp/MessageTimestamp.swift`. The model sees no clock, so each USER message gets a label as the
first line of its text: `[2026-10-27 15:03 +03:00 · 23h since previous message · previous reply took 4m]`.

- **Stamped: user messages only.** Stamped assistant replies would teach the model to open its own replies with an
  invented stamp. The run duration (assistant `createdAt` minus the preceding user `createdAt`) rides on the NEXT
  user label instead. Gaps under 1 minute are omitted; the first message has no gap.
- **Computed by the client**, never by the model (models are bad at date subtraction). English, always on, no toggle.
- **Never stored and never shown in the UI.** Built in `ChappieViewModel+History` when a request is assembled, from
  `ChatMessage.createdAt`, so a message always yields the same label and the provider prompt cache stays valid.
  The system prompt is untouched on purpose.
- **Format is hand-built** (fixed gregorian calendar, system time zone) so Mac locale settings cannot change a
  label that was already sent.
- **Gaps are measured over the messages the model actually receives** (local notices filtered out first).
- **Legacy messages** saved before `createdAt` existed have `nil` and get no label; the first stamped message
  after the update has no gap.

### Dates on memory entries

`MemoryEntry` already stored `createdAt`/`updatedAt` (`saveEntry` keeps the first and bumps the second), so
no migration was needed: existing entries carry real dates. They were just never shown. `formatEntriesForPrompt`
now appends `(created 2026-10-20, updated 2026-10-27)`; the update day is omitted when equal to the creation day.
Day granularity on purpose: a stored day never changes between requests, so the system prompt and the provider
cache stay stable. The date is formatted by `MessageTimestamp.entryDates` (same hand-built, locale-independent rule).
Two code paths render memory: `MemoryManager.formatEntriesForPrompt` (legacy) and `SystemPromptBuilder.memoryBlock`
(the one the app actually uses via `ThreadSession`); both go through `entryDates`, so they cannot drift apart.
The "Unknown" case agreed earlier turned out unnecessary: no entry lacks a date.

Tests: `MessageTimestampTests`, `MemoryDatesTests`.

---

## 📚 Changelog

| Date | Change |
|------|--------|
| 2025-07 | Initial architecture |
| 2026-06 | Storage cleanup: removed DataStoreMigration, V2/V3 schema stubs |
| 2026-07 | Projects refactor: removed ProjectPayload, DataStore.Relation.projects, bookmark logic. Projects now live in ThreadPayload as [ThreadProjectEntry] with absolutePath. ThreadStore owns project CRUD. ProjectStore reduced to downgradeAllProjectsToAdvisor() only. |
| 2026-07 | SwiftData removal: deleted DataStore.swift (ChappieDataStore), MigrationService.swift, AppSettingsMigration.swift. SQLiteStorage (GRDB) is now the sole persistence backend. |
| 2026-07 | Chunk system: messages split into 500-message chunks per row. Lazy loading (last chunk on open). Auto-migration from legacy single-blob on first access. deleteByPrefix + keys(withPrefix:) added to ChappieStorage protocol. |
| 2026-07 | ToolDefinitions.swift split into 6 files: orchestrator + FileTools, MemoryTools, GitTools, BuildTools, LocalizationTools extensions. 825 lines → 143 lines orchestrator. |
| 2026-07 | ThreadStore.swift split into 4 files: core + Chunks, Projects, Settings extensions. 513 lines → ~150 lines core. |
| 2026-10 | PathGuard: single containment check used by FileSystemManager. Rejects `..` and absolute paths, and resolves symlinks of the deepest existing ancestor so a link leading outside the project cannot be followed (read/write/delete/move/patch); listing and search skip escaping symlinks. A byte-identical copy lives in ChappieMCP (separate executable); PathGuardTests fails if the copies drift. |
| 2026-08 | view_image tool: AI can now view images saved inside project folders (not just chat attachments). FileSystemManager+Image.swift reads raw bytes (readFile can't — it decodes UTF-8, corrupting binary data). Tool result is a marker-prefixed data URI; AIOrchestrator+ToolExecution detects the marker and injects a synthetic user-role multimodal message right after the tool-result message — this is required because tool-role messages cannot carry image_url content per OpenAI/Anthropic wire format, only user-role messages can. |
| 2026-08 | Project path editable: ThreadStore.updateProjectPath() lets the user manually fix absolutePath in Settings (e.g. after a machine migration) without re-picking the folder via NSOpenPanel. |
| 2026-08 | BackupService (export/import foundation): ChappieExportBundle carries providers (+ Keychain secrets pulled out explicitly), full ThreadPayload list, all message chunks (opaque Data — ChappieCore stays decoupled from app-layer ChatMessage), and the full MemoryStorage blob. Attachments on disk are intentionally excluded (app already degrades gracefully for missing attachment files — no crash). BackupCrypto encrypts the whole serialized bundle with PBKDF2-HMAC-SHA256 (310k iterations) + AES-256-GCM — one password unlocks everything, including secrets. Export wired end-to-end (BackupService.exportEncrypted → ChappieViewModel.exportBackup). |
| 2026-08 | BackupService import (full restore, no merge — agreed with user): ThreadStore.importAll/AIProviderStore.importAll/MemoryStore.importStorage each destructively wipe existing data before writing the imported set (threads+chunks, providers+Keychain secrets, all memory scopes respectively) — matches the "migration/full restore" scenario, selective merge is an explicit non-goal. BackupService.decryptBundle + applyImport orchestrate the full flow. Project folder paths and attachments are NOT part of the bundle — user reconnects project paths manually after import via the editable absolutePath field (ProjectSettingsSheet). Covered by BackupServiceTests (8 tests: export completeness, provider/thread/memory restore + wipe-before-restore, encrypted end-to-end flow, wrong password). |
| 2026-10 | Fixed silent history loss: saving a lazily loaded window used to delete all chunks and write only the in-memory part. New `ChappieStorage.replaceIndexedRecords` (atomic delete-tail + insert) and `ThreadStore.saveLoadedMessages(fromChunk:)`; the old `saveMessages` was renamed `replaceAllMessages` to make its destructive meaning explicit. ViewModel resets `oldestLoadedChunkIndex` on thread switch. Covered by ThreadStoreWindowSaveTests. |
| 2026-10 | Storage integrity (backlog 2a): unreadable thread list is no longer treated as empty-and-overwritten. `ChappieStorage.preserveCorruptedRecord` backs up damaged bytes; `ThreadStore.loadPayloads` salvages threads one by one and queues `StorageIntegrityIssue`; `SQLiteStorage.load` backs up any undecodable record before returning nil. New `SaveQueue` serializes user-data writes and surfaces failures (Retry/Skip) instead of `try?`. Covered by ThreadStoreIntegrityTests (9) and SaveQueueTests (9). |
| 2026-10 | Thread list recovery (backlog 2b): a damaged list is repaired on read — readable threads kept, threads known only from message chunks rebuilt with their original ids, repaired list written back. Banner mentions how many were rebuilt. Covered by ThreadStoreRecoveryTests (9). |
| 2026-10 | Access control unified (backlog 4): `ToolPolicy` (one table, deny by default, per-target-project rights) + `ToolAuthorization` (target resolution, exposure filter) replace `ToolAccessController` (merged "most permissive" rights, fail-open) and `checkToolAccess`. loc_* are now gated by role and Xcode flag and carry a `project` argument that restricts the helper's path roots. Removed: ToolPermissions, ThreadSession.toolPermissions, v2ToolPermissions, the dead `attach_file` case. |
| 2026-10 | Tool arguments (backlog 8): `ToolArguments.parse` replaces strict `[String:String]` decoding in `authorize()`. Numbers/bools are stringified, null dropped, nested values become JSON text, double-encoded objects unwrapped; unreadable JSON / non-objects are refused with an explanation instead of silently becoming empty arguments (which used to lose `project`). Covered by ToolArgumentsTests (11). |
| 2026-10 | Unified LLM retry (backlog 13): `LLMRetryRunner` + classifier replace the stall/timeout special cases; HTTP 5xx/429 and network drops are retried with backoff measured from error arrival; streaming error bodies are read; mid-stream cuts continue the partial answer; progress shown in the action bar. Removed `RequestLog` and the diagnostic request (hardcoded Russian). Covered by LLMRetryTests (33 cases). |
| 2026-10 | ToolWatchdog (backlog 15): `ToolExecutionService.execute` runs every tool under a per-class deadline (`ToolDeadlines`); a hung tool is cancelled and the model gets an explicit message (outcome unknown for mutating tools). Manual terminal approval is under the same watchdog and bound to Stop. Covered by ToolWatchdogTests. |
| 2026-10 | OutputGuard (backlog 10b-1): one gate in `ToolExecutionService.execute` refuses oversized tool results (200 KB read / 100 KB command, measured on prepared UTF-8 text) with a notice instead of a cut piece; `OutputCapture` caps memory for running commands; `read_file` checks size before loading. Covered by OutputGuardTests (18). |
| 2026-10 | ImagePipeline (backlog 10b-2a): `ImageDownscaler` caps every image sent to a model at 2000 px / JPEG with an on-disk cache for attachments; `view_image` and `fetch_attachment` return real images (marker restricted to `imageResultTools`); `fetch_attachment` no longer returns base64 text; `ImageValve` guards provider image-count limits. Covered by ImagePipelineTests (13). |
| 2026-11 | Computer Use screenshot grid + zoom: `computer_screenshot` draws a labelled grid (default on) and accepts `x/y/width/height` to return a region at native resolution. Grid labels are ALWAYS overview-image pixels (the space computer_click takes), so a zoom is never renumbered and click needs no special case. The bitmap is built with an explicit NSBitmapImageRep so a Retina backing scale cannot silently double the output size. Covered by ComputerUseScreenshotTests (10). |
| 2026-11 | Computer Use by element number (the fix for clicks that missed small targets): `computer_screenshot(marks:true)` reads the accessibility tree of the app the user is working in, boxes and numbers its controls, and returns the numbered list as the tool TEXT plus the annotated picture as a user-message image — a `ToolImageResult`, so `textAndImageTools` (documents + the four computer tools) replaces the document-only routing in AIOrchestrator and OutputGuard. `computer_click(element:N)` and `computer_type(element:N)` take the AX centre as the click point with NO coordinate conversion: AX frames already live in CGEvent space. `MarkedScreenshotStore` keeps the numbers of the last picture and is cleared by every click, scroll and keystroke, so a number can never outlive the layout it described; every action replies with a freshly numbered picture, making the loop one call per action instead of two. `cropPlan` is the single source of the crop for both the renderer and the text list, and `ElementMarks.visible` the single visibility predicate for the boxes and the list. Covered by ComputerUseElementStoreTests (18) plus ComputerUseAccessibilityTests (16), ComputerUseMarksTests (17), ComputerUseScreenshotTests (10). |
| 2026-11 | Element list made cheap and honest (found on the first live run): an `AXTextArea` reports its ENTIRE document through `kAXValueAttribute`, which the title fallback copied straight into the prompt — one open 6000-line markdown file cost ~8000 tokens per screenshot. `AccessibleElement.normalized` now collapses whitespace and cuts every title to 60 chars at the type boundary, so no caller can reintroduce it. Two more rules, both from the same live list: a control whose CENTRE falls outside the window is dropped (a text area taller than its viewport has its centre off-screen, so its number would promise a click somewhere else — this is what removed the 6611pt editor area), and `AXRow`/`AXValueIndicator` left the interactive roles (a row's cell sits at the same centre, a value indicator is a scrollbar thumb). Covered by 7 new tests in ComputerUseAccessibilityTests (9 selection + 3 title + roles). |
| 2026-11 | Computer Use rework, step 1 (aim): new `computer_aim(x, y, monitor)` takes fractions 0...1 of the monitor image, returns a native-resolution square crop (~100 points each side of the point) with a crosshair and remembers the point in `AimStore`. Wired into the executor switch, `ToolPolicy`, tool order, `imageResultTools` and `textAndImageTools`; `imageIntro` has its own caption for it. Additive only: `computer_click` still takes element/x/y, and the AX/marks code stays until the last step of the rework (build before demolish). Covered by ComputerUseAimTests (10). |
| 2026-11 | Computer Use rework, step 2 (click): `computer_click` takes no coordinates. It consumes the point stored by the last `computer_aim` through `AimStore.take()`, which forgets it, so a second click without a new aim is refused ("No aim is set"). Checked live on Xcode: aim, click, repeated click refused. |
| 2026-11 | Computer Use rework, step 3 (screenshot): `computer_screenshot(monitor, grid)` returns one whole monitor as a clean picture, nothing drawn on it, and the text says which monitor it is and how many are connected. `grid:true` adds an optional coarse 10x10 grid labelled 0.1...0.9, the same fractions `computer_aim` takes; it is off by default so the model sees the true screen. New file `ComputerUseOverview.swift`. The tool description no longer mentions zoom or marks; their code (`marks:true`, x/y/width/height, `screen_index`) still answers if called and is removed in step 6 (build before demolish). Covered by ComputerUseOverviewTests (5). |
| 2026-11 | Computer Use rework, step 4 (type): `computer_type(text, submit, delay)` takes no coordinates and no monitor. It consumes the pending aim through `AimStore.take()`, activates the app under the aimed point, clicks it to focus, then pastes the text with Cmd+V. The user's clipboard (all items and types) is saved before and restored 250 ms after the paste, because the target app reads it asynchronously. `submit` presses Return afterwards. The result is a clean overview of the aimed monitor. New file `ComputerUseTypeTool.swift`; `activateApp`, `postMouseEvent` and `postRawKey` lost `private` so it can reuse them. The old `performType` (element/x/y/screen_index, per-character keystrokes) stays unused until step 6 (build before demolish). Covered by AimedTypeArgumentsTests (6). |
| 2026-11 | Computer Use rework, step 5 (scroll): `computer_scroll(x, y, dx, dy, monitor, delay)` takes x/y as fractions 0...1 of the monitor image and an explicit `monitor`; it needs no aim, because scrolling needs no pixel precision and is repeated often. The cursor is moved to the point before the wheel event so the window under it receives it. Positive dy scrolls down. The result is a clean overview of that monitor. New file `ComputerUseScrollTool.swift`; the old `performScroll` (pixel x/y, `screen_index`, numbered picture) stays unused until step 6 (build before demolish). Covered by FractionScrollTests (7). |
| 2026-11 | Computer Use rework, step 6 (demolition): the new aim/click/type/scroll path was built and green first, then the old one was removed. Deleted: the AX reader (`ComputerUseAccessibility.swift`), numbered boxes (`ComputerUseMarks.swift`), the element store (`ComputerUseElementStore.swift`), the numbered screenshot, `resolveElement`, the zoom mode (`region`, `clampRegion`, `cropPlan`, zoom caption, labelled pixel grid), the old `performType`/`performScroll`, `scaleToScreen`, `postKeyEvent`, and the arguments `marks`, `x`, `y`, `width`, `height` of `computer_screenshot`. `renderScreenshot` now only downscales the capture; the only thing ever drawn on a screenshot is the optional 0.1 fraction grid. `computer_click` answers with a clean overview of the aimed monitor instead of a numbered picture. `textAndImageTools` stays: it routes text plus a picture for the document readers and all five computer tools. `screen_index` is still read by `computer_screenshot` as a fallback for `monitor`. Tests: the AX, marks and element-store suites went away, routing tests moved to ComputerUseRoutingTests, the argument, screenshot and overview tests were rewritten for the new signatures. Entries above that mention marks, zoom or numbered pictures describe code that no longer exists. |
| 2026-11 | Computer Use rework, cursor-first (replaces the aim/crop scheme of steps 1-5). Live test on a paint stand showed the aim crop MISLEADS: it showed pixels around the point the model aimed at, not where it would really land, and a crop holding two similar targets made the model click the wrong one. The model now works like a person: it sees the whole screen WITH THE REAL CURSOR drawn by the system (`SCScreenshotManager`, `showsCursor = true`, so the shape is the true one: arrow, crosshair, hand), moves it with `computer_move_to(x, y)` (far) or `computer_move_by(dx, dy)` (fine correction), and clicks with `computer_click`, which takes NO coordinates and clicks wherever the cursor is. Every one of them answers with a fresh screenshot and the cursor position. ALL numbers are in PICTURE pixels, the compressed image the model sees; `MonitorMapping` converts to CGEvent points, so the model never computes a scale, a fraction or a Retina factor, and the monitor's native size is deliberately NOT reported (a second number beside the picture invites the model to convert). The picture size is reported so the model notices if a provider resized it. Long side stays capped at 1440 because providers silently shrink images past 1568 and every pixel count would then be off. Deleted: `computer_aim`, `AimStore`, `AimGeometry`, the crop with crosshair and its 50 px grid, the 0.1 fraction grid and the `grid` argument. `computer_type` now clicks the current cursor. `computer_scroll` still takes fractions (scrolling needs no precision) and is a candidate to move to picture pixels for one consistent unit. KNOWN GAPS, not verified live: `computer_move_by` reads the cursor through `NSEvent.mouseLocation` and has a dead `let current` left in it; `computer_move_to` has a leftover `?? { ... }()` construct that must be cleaned; `overviewScreenshot` waits for the async capture with a `DispatchSemaphore` on the main actor, which can deadlock if SCKit needs the main thread. Covered by MonitorMappingTests, RenderPictureTests, CursorConversionTests, ScreenshotArgumentsTests. |
| 2026-10 | Office pictures (backlog 10b-2b): the helper extracts `word|ppt|xl/media` (and ODT `Pictures/`) pictures into a private temp folder and leaves `<!-- [image N: name] -->` XML comments in the text (valid XML, safe for `write_document`); the app validates, downscales and deletes the folder, and shows the images to the model as separate multimodal parts. `read_build_log` now returns only error/failed lines. Covered by OfficeImagesTests (15). |
| 2026-10 | CommandSafety (backlog 11A): word-level command analysis replaces the substring blocklist (no more false positives on `rm -rf /tmp/x`, no bypass by flag order or `bash -c`); documented as a safety net, not a boundary. Covered by CommandSafetyTests (14 groups, ~190 command cases). |
| 2026-08 | Backup import UI shipped in app layer (Chappie/architecture-app.md): BackupImportSheet two-step confirmation (decrypt/preview, then explicit destructive "Restore Now"), reachable from SettingsView and from OnboardingView welcome step as a "Restore from Backup" shortcut that skips the whole provider setup wizard. |
| 2026-11 | The last all-projects fallback is gone: `list_files` without a `project` returned every attached project merged with `ProjectName/` prefixes, which is exactly what the 2026-11 project-required note said was removed — the tool body still had the branch, unreachable behind `authorize` but there to be re-enabled by a later edit. It now refuses without a project, like every other project tool, and `ToolPathRoutingTests` pins both halves: refusal with one project and with several, and a scoped listing that keeps an inner same-named folder intact. WHY the branch mattered beyond tidiness: a merged dump hands the model paths it cannot pass back to any file tool, because a `ProjectName/` prefix is never interpreted. |
| 2026-11 | `project` is required for every project tool (file, search, document, git, build, loc, curl, pdf by path), with one project or several. Removed: single-project default, `ProjectName/` path-prefix routing (a project with a same-named inner folder, e.g. `Chappie/Chappie/`, silently redirected calls to the root), all-projects mode of `list_files`/`search_in_project`; schemas no longer depend on the number of projects. Covered by ToolPathRoutingTests, ToolAuthorizationTests, ToolExposureTests. |
| 2026-11 | RouterAI preset. `BuiltInProvider.supportsPromptCaching` replaces the hardcoded `catalogId == "aitunnel"` check (AITunnel and RouterAI send top-level `cache_control`); providers added by hand are matched to a preset by host (`BuiltInProviders.find(baseURL:)`). Verified live: without `cache_control` RouterAI caches nothing; with it, call 2 reads the whole prefix (cost 4.0 -> 0.16 RUB per 15k tokens), 5m and 1h TTL both work, tool-result turns hit the cache. RouterAI reports price as `usage.cost` (AITunnel: `cost_rub`) via `AIUsage.effectiveCost`; no `usage.balance`, so `BalanceEndpoint` (`GET /api/v1/credits`, `data.credits`) is fetched after each streamed answer. |
| 2026-11 | Remote providers.json catalog removed (ProvidersRemoteService, RemoteProviderCatalog, startup sync). Replaced by hardcoded BuiltInProviders presets without models; chat path is per preset. `AIProvider.catalogId` keeps its name for stored-data compatibility and now means "preset id". |
| 2026-11 | Localization boundary: ChappieCore holds no catalog-localized strings. Labels of AgentRole/Git/Tests and the "unknown" DevEnvironment moved to the app target (Chappie/Views/Shared/ProjectModels+Display.swift), because Xcode extracts catalog keys only from app sources and marks keys used inside a Swift package as stale. (`DevEnvironment` itself was removed later, see the 2026-11 note below.) |
| 2026-11 | Localization tools removed (pass J5-a): all 15 `loc_*` tools, the helper's LocalizationTools module with its xcstrings data model, `ToolCapability.locRead/locWrite`, `ToolPolicy.localizationTools`, `xcodeBlock` and the dispatcher branch. They dropped `extractionState`, `variations` and `substitutions` on every write, escaped `/` and rewrote the whole file; `json_*` do the same work byte-exactly in any environment. Tests assert the names are no longer classified. |
| 2026-11 | String catalog recipe in `json_edit` (pass J5-c): the knowledge of the `.xcstrings` format moved from the deleted tools into the tool description (structure, four `state` values, two worked operations, the `json_find` call for missing translations, and why a whole-file rewrite loses `comment`/`extractionState`/`variations`). Verified live on a copy of the real 785.9 KB catalog: sorted insert of a new language, one `state` change, every other byte identical. |
| 2026-11 | Native Anthropic route for gateways. `BuiltInProvider.nativeAnthropic` (`NativeAnthropicRoute`, `modelPrefix`) makes `AIClientFactory` pick `AnthropicClient` per model id: RouterAI sends `anthropic/*` over its own `/api/v1/messages`, everything else over the OpenAI-compatible path. Causation, not preference: the OpenAI route of RouterAI flattened a tool call into plain text 4 times in a day (stream had no `tool_calls` key at all, `finish_reason: stop`, marker split across `delta.content` chunks), while the native route never did. Verified live end-to-end on the user's key: tools non-stream and streamed, full `tool_result` turn, two parallel `tool_use` blocks, `max_tokens` 32k/64k, `cache_control` on blocks. Two bugs found and fixed on the way: `mergeConsecutiveSameRole` glued two parallel `tool_result` blocks into text (HTTP 200, wrong answer — the model lost the ids), and the native route had no `cache_control` at all, which would have raised cost ~11x. Cost per turn read from `GET /api/v1/generation?id=<x-generation-id>` (the header arrives in the stream too), balance from `/api/v1/credits`; both after the stream, both swallowing failure. Tests: `NativeAnthropicLiveTests` (3, only run when a real key is present) + `AnthropicMessageConversionTests`. An empty-arguments regression is covered in `StreamDumpTests` (see above). |
| 2026-11 | Stream dump (diagnostics pass 2): `StreamDumpRecorder` buffers the raw SSE lines of one request and `StreamDumpWriter` saves them under `Application Support/ChappieAI/StreamDumps` only when the stream looks wrong (flattened tool call, skipped chunks, invalid tool arguments, missing finish reason) or when `CHAPPIE_STREAM_DUMP=1`. Nothing is ever parsed out of the text as a call — a dump is for reading, not executing. Also fixed `AnthropicDelta.type` being required, which silently dropped `message_delta` events and with them the reported cost. Covered by StreamDumpTests (13). |
| 2026-11 | Exit code of a command without a trailing newline: `ShellSession.parseOutput` split the stream into lines and looked for a line starting with `EXIT_CODE:`, but the session appends that line directly after the command's last bytes, so `printf abc; false` produced the single line `abcEXIT_CODE:1`. The marker had no line start to anchor to: the exit code was read as a coincidental 0 (reported as success) and the marker stayed in the text handed to the model. Both paths now go through one `splitTrailer`, which searches backwards for the marker and cuts it out of the body; the last occurrence is always the injected one, so a command that prints `EXIT_CODE:` itself keeps its own text. The tail-window copy `exitCode(inTail:)` is gone — one implementation for the inline, truncated and spooled cases. Covered by OutputGuardTests (3 new cases). |
| 2026-11 | Unlimited context removed: `ThreadSettings.isUnlimitedContext` and `AppConfig.isUnlimitedContext` are gone, so the window is always a finite message count and cannot be silently unbounded. Safe by construction — the stored key is simply no longer requested, which JSON ignores, so no thread record can fail to decode. The slider stays a message count (pairs were considered and rejected: the setting reads better as messages than as tokens), the settings sheet replaced the toggle and the "everything is shown" box with one line stating that a cache-reading route may send up to 3x the window, and `ensureModelHistoryLoaded` now loads `limit × 3 + 1` instead of `limit + 1` — without that the wide allowance would never be reached after a chunk rollover. `visibleMessages` still keeps ×10 for the scrollback. Covered by `AppConfigTests`, `CurlModelsTests`. |
| 2026-11 | `run_ssh` now spools its output like `run_terminal`: both collectors get `OutputSpool.defaultDirectory`. Before, a remote command printing more than `captureCap` lost everything past it, and a result over the command limit was refused by `OutputGuard` — the model saw only a size notice and no output at all. A timeout or Stop used to discard the output received so far and report only the reason; it now carries both streams (`SSHResult.stopped`), because the lines printed before the hang are usually the explanation. The text shaping moved into its own `SSHResult.swift` (TerminalTools was past 400 lines) and is testable without an ssh host. Covered by SSHResultTests (8 cases). |
| 2026-11 | The sent-prefix fingerprint (`SentPrefix`): the window decision no longer infers "the provider will read" from elapsed time and a standing anchor, it compares a canonical hash of the tools + system prompt + the messages that went out last time. A changed head or a shifted message run forces `.exact`, so a turn that will be written from scratch stops carrying 3x the window. Stored per thread next to the mark and the anchor (`chappie.contextWindow.sentPrefix`), with the message count so the next turn hashes the same slice — comparing "everything except the newest exchange" can never match, since the previous request is always a strict prefix of the current one. Tools are now fetched before the window is built (their hash is part of the check). Covered by `SentPrefixTests` (11) and `ContextWindowPrefixTests` (5), the latter verified red with the check disabled. |
| 2026-11 | The window anchor is kept after a cold turn too. `buildContextWindow` stored `warm ? sliced.anchor : nil`, so a cold turn threw away the start of the window it had just sent — and that request is exactly the prefix the provider now holds. Measured live: a cold turn wrote 78824 tokens (21.43 RUB), and the next turn still re-wrote 47k of the same 79k instead of reading them. Now `sliced.anchor` is stored unconditionally; a stale anchor costs nothing because `slice` discards one that left the history or sits too close to the end. Covered by `ContextWindowAnchorPersistenceTests` (6 cases: a cold turn records its anchor, the next turn keeps the same prefix, a route without a cache is unchanged, a long pause still falls back to the exact window, anchors stay per thread). |

### Build and test tools removed (2026-11)

`build_project`, `run_tests`, `read_build_log`, the `buildEnabled` setting, `TestsAccessLevel`,
`DevEnvironment.specificTools` and the helper's `projectEnvMap` (argv[3]) are gone. WHY: they were per-language
wrappers around commands the terminal already runs, and they hid the real output behind a summary. The agent now
runs `xcodebuild`, `npm test`, `pytest` etc. through `run_terminal`; a long output is spilled to a file (see
OutputSpool) and read with `grep`/`sed`.
### Dev environment selection removed (2026-11)

`DevEnvironment`, `ProjectSettings.devEnvironment`, the "Dev environment: ..." prompt line, the picker and the Detect
button in ProjectSettingsSheet, `ChappieViewModel+DevEnvironment.swift` (local rules plus an AI detection call) and
7 catalog keys are gone. WHY: nothing is tied to a language or stack any more, the agent reads the project itself.
Old stored records keep a `devEnvironment` key that the decoder ignores (unknown keys never fail decoding).
`testsAccess` became `ProjectSettings.testsWriteEnabled` (one switch, only a prompt line states it); a stored legacy
`"testsAccess":"write"` turns it on, every other value (or type) turns it off. Tests: `TerminalSwitchMigrationTests`.
Recipe for Xcode: `xcodebuild -project P.xcodeproj -scheme S -destination 'platform=macOS' test > /tmp/x.log 2>&1`;
for iOS pick a simulator from `xcodebuild -showdestinations`; a cold simulator may fail the first launch, retry once.
