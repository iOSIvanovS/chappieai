<!--
  ChappieMCP/architecture.md
  ARCHITECTURE DOCUMENT — CHAPPIEMCP
  Update after every significant change.
-->

# ChappieMCP — Architecture

## 1. Purpose

ChappieMCP is a local helper process launched by `Chappie.app` as a child process.
It provides the AI agent with tools for git, build/test, localization, and Office document editing.

**Why a separate process:**
- Independence: helper restarts without restarting the app
- Separation of concerns: UI layer has no direct knowledge of git/build tools
- User downloads one `.app` — everything is inside

**Location inside .app:**
```
Chappie.app/Contents/Helpers/ChappieMCP
```

---

## 2. File Structure

```
ChappieMCP/
├── architecture.md
├── main.swift                         # Entry point: reads argv, starts MCPUnixServer
└── Sources/ChappieMCP/
    ├── DevEnvironment.swift           # Mirrors ChappieCore.DevEnvironment (rawValues must stay in sync)
    ├── Server/
    │   ├── MCPHTTPServer.swift        # Unix Domain Socket server + ToolDispatcher; socket I/O on a private GCD queue
    │   └── SocketIO.swift             # poll()-based read/write with one overall deadline per transfer
    └── Tools/
        ├── GitTools.swift             # git_status, git_add, git_commit, git_log, git_reset, git_revert, git_checkout
        ├── BuildTools.swift           # build_project, run_tests, read_build_log (env-aware routing)
        ├── PathGuard.swift            # Byte-identical copy of ChappieCore's PathGuard (parity test) — project containment
        ├── LocalizationTools.swift    # loc_* tools (Xcode / xcstrings only); create/rename/delete accept only .xcstrings
        └── DocumentTools.swift        # read_document, write_document (Office formats via ZIPFoundation)
```

---

## 3. Architecture Diagram

```mermaid
graph TD
    subgraph App["Chappie.app"]
        TES["ToolExecutionService"]
        Bridge["MCPToolBridge"]
        Launcher["MCPHelperLauncher"]
    end

    subgraph MCP["ChappieMCP (child process)"]
        Main["main.swift\nparses argv[1..3]"]
        Server["MCPHTTPServer\nUnix Domain Socket + ToolDispatcher"]
        Git["GitTools"]
        Build["BuildTools\n(env-aware router)"]
        Loc["LocalizationTools"]
        Doc["DocumentTools\n(ZIPFoundation)"]
    end

    subgraph Transport["Transport"]
        Socket["/tmp/com.chappie.mcp.&lt;appPID&gt;.sock\nUnix Domain Socket\nlength-prefixed JSON frames"]
    end

    TES --> Bridge
    Bridge -->|4-byte len + JSON| Socket
    Launcher -->|"argv[1]=path argv[2]=socket argv[3]=envMap"| Main
    Socket --> Server
    Main --> Server
    Server --> Git
    Server --> Build
    Server --> Loc
    Server --> Doc
```

---

## 4. Transport Protocol

**Unix Domain Socket** — `/tmp/com.chappie.mcp.<appPID>.sock` (per app instance, passed as argv[2])

```
Request:  [4 bytes UInt32 BE length] [JSON: {"tool": "git_status", "args": {}}]
Response: [4 bytes UInt32 BE length] [JSON: {"result": "...", "error": null}]
```

| Argument | Value |
|---|---|
| `argv[1]` | Workspace path (working directory for git/build) |
| `argv[2]` | Socket file path |
| `argv[3]` | JSON map `{"ProjectName": "xcode", ...}` — project→env routing |

**MCPHelperLauncher** restarts the helper when workspace or devEnvironment changes.
**MCPToolBridge** connects per call (no persistent connection). Timeout: 600s.

### Helper lifecycle

- **One socket per app instance:** `/tmp/com.chappie.mcp.<appPID>.sock` (`MCPSocket` in ChappieCore). The path is argv[2]; the helper has no default and exits with code 2 without it. Two Chappie instances can no longer delete each other's socket. At launch the app removes sockets of dead PIDs (the legacy fixed name is never touched).
- **Readiness:** the launcher reports `running` only once the socket accepts connections (`MCPSocket.canConnect`), not when the process merely exists.
- **Crash recovery:** an unexpected exit restarts the helper after 1, 2, 4, 8 s (`MCPRestartPolicy`); an uptime of 60 s or more resets the series. After 5 quick failures in a row the launcher stops with `.failed` instead of looping. An explicit launch or a tool call starts a fresh series.
- **Self-heal on call:** when `MCPToolBridge` cannot connect (ENOENT / ECONNREFUSED — the request never reached a helper) it asks the launcher to restart the helper once and retries once. Parallel callers share one recovery.
- **Exit with the app:** the helper polls `getppid()` once a second and exits (removing its socket) when its parent changes — a killed app (Xcode Stop = SIGKILL) leaves no orphan. SIGTERM also cleans up. The socket file is unlinked only if its inode is still the one the helper bound, so a restart on the same path cannot delete the new helper's socket.
- **Not automatic:** helpers left over from before this change are not killed by code.

### Misbehaving clients

A client that connects and goes silent must not starve real calls (24 silent clients used to pin every cooperative-pool thread).
- **Own queue.** Socket reads and writes run on a private concurrent GCD queue, never on Swift's cooperative pool. Only the tool run itself is `async`.
- **One deadline per transfer** (`SocketIO`, `poll()`): 10 s to deliver the whole request, 10 s to take the whole response. A client dripping one byte at a time cannot extend it. The deadline bounds only the transfer, never the tool run (a build may take minutes).
- **Pending cap:** at most 32 connections still delivering their request; extra ones are closed at once.
- **`accept()` errors:** EINTR/ECONNABORTED/EAGAIN/EPROTO retry at once; EMFILE/ENFILE/ENOMEM/ENOBUFS back off 100 ms (logged once); anything else is fatal, so the helper exits and the launcher restarts it.
- A connection that closes without sending a byte is the app's readiness probe and is not logged as an error.

---

## 5. Tools

### Git (GitTools.swift)

| Tool | Command |
|------|---------|
| `git_status` | `git status --short --branch` |
| `git_add` | `git add <paths>` |
| `git_commit` | `git commit -m <message>` |
| `git_log` | `git log --oneline --graph -N` |
| `git_reset` | `git reset HEAD` |
| `git_revert` | `git revert <hashes> --no-edit` |
| `git_checkout` | `git checkout <ref> -- <paths>` |

**`git_diff` is BANNED FOREVER** — loads entire diff into AI context, costs money.

All git commands run with: `GIT_PAGER=cat`, `GIT_TERMINAL_PROMPT=0`, `GIT_CONFIG_NOSYSTEM=1`, `TERM=dumb`.

### Build (BuildTools.swift) — env-aware routing

`BuildTools` receives `projectEnvMap` at init and routes each tool to the correct shell command.

| Environment | `build_project` | `run_tests` |
|---|---|---|
| `xcode` | `xcodebuild -scheme <App> build` | `xcodebuild -scheme <App>CoreTests test` |
| `nodejs` | `npm run build` | `npm test [pattern]` |
| `python` | — (not available) | `python -m pytest [pattern]` |
| `go` | `go build ./...` | `go test [pkg]` |
| `rust` | `cargo build` | `cargo test [filter]` |
| `java` | `mvn compile` or `gradle build` | `mvn test` or `gradle test` |
| `kotlin` | `gradlew build` | `gradlew test` |
| `flutter` | `flutter build` | `flutter test [file]` |
| `react_typescript` | — (not available) | `npm test [pattern]` |
| `dotnet` | `dotnet build` | `dotnet test [proj]` |

Build log saved to `<workspacePath>/.build_log.txt`.

### Path safety (PathGuard.swift)

All path-taking tools (`loc_*`, `read_document`, `write_document` incl. `output_path`) resolve paths through `PathGuard`: relative only, no `..`, symlinks leading outside the project root are refused. The single exception is an absolute path inside `~/Library/Application Support/Chappie/Attachments` (the app hands those over for attachments). Git/build tools take no file paths from the model.

**Roots.** `loc_*` and documents check paths against the attached projects' roots (`projectPathMap`), never against the workspace folder alone. A root of `/`, empty or non-existent is unusable (`PathGuard.isUsableRoot`): `main.swift` turns such an `argv[1]` into an empty workspace, and `MCPHelperLauncher` no longer substitutes the launch directory (which is `/` under Xcode and made the guard a no-op). With several projects, `loc_create` needs a path whose folder already exists in exactly one project; `loc_rename` keeps the destination in the source's project; `loc_dead_keys` scans only the project that owns the file.

### Localization (LocalizationTools.swift)

Xcode-specific (`.xcstrings` format). Injected only when `devEnvironment == .xcode`.

| Tool | Purpose |
|------|---------|
| `loc_info` | Coverage stats for all .xcstrings files |
| `loc_create` / `loc_delete` / `loc_rename` | File lifecycle |
| `loc_add_language` / `loc_remove_language` | Language management |
| `loc_add_key` / `loc_remove_key` | Key management |
| `loc_next_batch` | Next untranslated batch (100 / N languages) |
| `loc_submit_batch` | Submit translations |
| `loc_key_check` | Check key status across languages |
| `loc_dead_keys` | Find unused keys |

### Documents (DocumentTools.swift)

Office document read/write via ZIP+XML. Uses **ZIPFoundation** (SPM, no external installs).

| Tool | Purpose |
|------|---------|
| `read_document` | Extract primary XML/text from Office document |
| `write_document` | Replace primary XML entry and save (or save as new file) |

**Supported formats:**

| Format | Read | Write | Primary entry |
|---|---|---|---|
| `.docx` | ✅ | ✅ | `word/document.xml` |
| `.xlsx` | ✅ | ✅ | `xl/worksheets/sheet1.xml` |
| `.pptx` | ✅ | ✅ | `ppt/slides/slide*.xml` |
| `.odt` | ✅ | ✅ | `content.xml` |
| `.rtf` | ✅ | ✅ | plain text (no ZIP) |
| `.csv` | ✅ | ✅ | plain text (no ZIP) |
| `.pdf` | ✅ | ❌ | text extraction only |

**XML normalization (Word):** removes `rsid*` attributes, `w:proofErr`, `w:bookmarkStart/End` — noise added by Word for spell-check / revision tracking.

**Write strategy:** copy original ZIP → replace only primary entry → save. All styles, images, relationships preserved.

---

## 6. xcscheme Rules

### Problem: ⌘+U closed the Chappie window
**Cause:** `ChappieCoreTests.xcscheme` `<LaunchAction>` pointed to `Chappie.app` — Xcode killed it before tests.
**Fix:** `<LaunchAction>` has no `<BuildableProductRunnable>`. Runner uses its own process.

### Problem: `(unknown) 0 Excluded Tests` in Test Navigator
**Cause:** `Chappie.xcscheme` had an empty `<TestAction>`.
**Fix:** `<TestAction>` fully removed from `Chappie.xcscheme`.
