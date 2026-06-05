<!--
  ChappieMCP/architecture.md
  ARCHITECTURE DOCUMENT — CHAPPIEMCP
  Update after every significant change.
-->

# ChappieMCP — Architecture

## 1. Purpose

ChappieMCP is a local helper process launched by `Chappie.app` as a child process.
It provides the AI agent with tools for git and xcodebuild.

**Why a separate process:**
- Independence: helper restarts without restarting the app
- Separation of concerns: UI layer has no direct knowledge of git/xcodebuild
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
├── main.swift                         # Entry point, reads argv, starts MCPUnixServer
└── Sources/ChappieMCP/
    ├── Server/
    │   └── MCPHTTPServer.swift        # Unix Domain Socket server + ToolDispatcher
    └── Tools/
        ├── GitTools.swift             # git_status, git_add, git_commit, git_log, git_reset
        ├── BuildTools.swift           # build_project, run_tests, read_build_log
        └── LocalizationTools.swift    # loc_* tools
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
        Main["main.swift"]
        Server["MCPHTTPServer\nUnix Domain Socket + ToolDispatcher"]
        Git["GitTools"]
        Build["BuildTools"]
        Loc["LocalizationTools"]
    end

    subgraph Transport["Transport"]
        Socket["/tmp/com.chappie.mcp.sock\nUnix Domain Socket\nlength-prefixed JSON frames"]
    end

    TES --> Bridge
    Bridge -->|4-byte len + JSON| Socket
    Launcher -->|Process.run argv[1]=path argv[2]=socket| Main
    Socket --> Server
    Main --> Server
    Server --> Git
    Server --> Build
    Server --> Loc
```

---

## 4. Transport Protocol

**Unix Domain Socket** — `/tmp/com.chappie.mcp.sock`

```
Request:  [4 bytes UInt32 BE length] [JSON: {"tool": "git_status", "args": {}}]
Response: [4 bytes UInt32 BE length] [JSON: {"result": "...", "error": null}]
```

`argv[1]` = workspace path (working directory for git/xcodebuild)
`argv[2]` = socket path

**MCPToolBridge** connects per call (no persistent connection). Timeout: 600s.

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

### Build (BuildTools.swift)

| Tool | Command |
|------|---------|
| `build_project` | `xcodebuild -project Chappie.xcodeproj -scheme Chappie build` |
| `run_tests` | `xcodebuild test` or `swift test` |
| `read_build_log` | Reads `.build_log.txt` |

Build log saved to `<workspacePath>/.build_log.txt`.

### Localization (LocalizationTools.swift)

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

---

## 6. xcscheme Rules

### Problem: ⌘+U closed the Chappie window
**Cause:** `ChappieCoreTests.xcscheme` `<LaunchAction>` pointed to `Chappie.app` — Xcode killed it before tests.
**Fix:** `<LaunchAction>` has no `<BuildableProductRunnable>`. Runner uses its own process.

### Problem: `(unknown) 0 Excluded Tests` in Test Navigator
**Cause:** `Chappie.xcscheme` had an empty `<TestAction>`.
**Fix:** `<TestAction>` fully removed from `Chappie.xcscheme`.
