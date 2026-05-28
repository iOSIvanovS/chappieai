<!--
  ChappieMCP/architecture.md

  ARCHITECTURE DOCUMENT — CHAPPIEMCP

  This file replaces the AI_Docs folder (architecture.md + project_map.md + semantic.json).
  Update after every significant change.
  Created: 2026-05-29
-->

# ChappieMCP — Architecture

## 1. Purpose

ChappieMCP is a local helper process launched by `Chappie.app` as a child process.
It provides the Chappie AI agent with tools for working with git and xcodebuild.

**Why a separate process:**
- Chappie.app (without Sandbox) can launch child processes
- Independence: the helper restarts without restarting the app
- Separation of concerns: UI layer has no direct knowledge of git/xcodebuild

**Why embedded in Chappie.app (not a separate package):**
- User just downloads the `.app` — everything is inside
- No terminal, no separate folders
- Xcode builds the helper as a separate target and copies it to `Contents/Helpers/`

---

## 2. File Structure

```
ChappieMCP/                            — Xcode target (Command Line Tool) inside Chappie.xcodeproj
├── architecture.md                    — this file
├── main.swift                         — entry point, reads argv, starts MCPUnixServer
├── MCPHTTPServer.swift                — Unix Domain Socket server + ToolDispatcher
├── GitTools.swift                     — git tools
└── BuildTools.swift                   — xcodebuild/swift test tools

Location inside .app:
Chappie.app/
└── Contents/
    ├── MacOS/
    │   └── Chappie          ← main binary
    └── Helpers/
        └── ChappieMCP       ← this helper (Copy Files Build Phase)
```

---

## 3. Architecture Diagram

```mermaid
graph TD
    subgraph App["Chappie.app"]
        TES["ToolExecutionService\n(ChappieCore actor)"]
        MCP_Bridge["MCPToolBridge\n(ChappieCore actor)"]
        Launcher["MCPHelperLauncher\n(Chappie UI)"]
    end

    subgraph ChappieMCP["ChappieMCP (child process)"]
        Main["main.swift\nentry point, argv parsing"]
        Server["MCPHTTPServer\nUnix Domain Socket server\nToolDispatcher"]
        Git["GitTools\ngit_status, git_add\ngit_commit, git_log, git_reset"]
        Build["BuildTools\nbuild_project, run_tests\nread_build_log"]
    end

    subgraph Transport["Transport"]
        Socket["/tmp/com.chappie.mcp.sock\nUnix Domain Socket\nlength-prefixed JSON frames"]
    end

    subgraph Tools["Git / Build"]
        GitBin["git binary"]
        XCBuild["xcodebuild / swift test"]
        BuildLog[".build_log.txt"]
    end

    TES --> MCP_Bridge
    MCP_Bridge -->|4-byte len + JSON| Socket
    Launcher -->|Process.run argv[1]=path argv[2]=socket| Main

    Socket -->|4-byte len + JSON| Server
    Main --> Server
    Server --> Git
    Server --> Build

    Git --> GitBin
    Build --> XCBuild
    Build --> BuildLog
```

---

## 4. Transport Protocol

**Unix Domain Socket** — `/tmp/com.chappie.mcp.sock`

### Protocol: length-prefixed framing

```
Request:
  [4 bytes: UInt32 big-endian length of JSON] [JSON data]
  JSON: {"tool": "git_status", "args": {}}

Response:
  [4 bytes: UInt32 big-endian length of JSON] [JSON data]
  JSON: {"result": "...", "error": null}
```

**Why Unix Domain Socket instead of TCP:**
- App Sandbox (even disabled) has quirks with TCP servers in child processes
- UDS via `/tmp/` works reliably without additional entitlements
- Faster than TCP for local IPC

### Helper Launch

```
MCPHelperLauncher.shared.launch(workspacePath: url.path)
    ↓
Process.run(
    executableURL: Bundle.main.url(forAuxiliaryExecutable: "ChappieMCP"),
    arguments: [workspacePath, socketPath]
)
```

`argv[1]` = workspace path (working directory for git/xcodebuild)
`argv[2]` = socket path (usually `/tmp/com.chappie.mcp.sock`)

---

## 5. Tools

### Git (GitTools.swift)

| Tool | Command | Arguments |
|------|---------|-----------|
| `git_status` | `git status --short --branch` | — |
| `git_add` | `git add <paths>` | `paths: "."` |
| `git_commit` | `git commit -m <message>` | `message: "..."` |
| `git_log` | `git log --oneline --graph -N` | `count: "10"` |
| `git_reset` | `git reset HEAD` | — |

**FORBIDDEN tools:**
- `git_diff` — BANNED FOREVER. Loads the entire diff into AI context → costs hundreds of rubles.

**Important:** all git commands run with environment variables:
```
GIT_PAGER=cat           — disables pager (less), otherwise headless process hangs
GIT_TERMINAL_PROMPT=0   — prevents password prompts via TTY
GIT_CONFIG_NOSYSTEM=1   — ignores /etc/gitconfig with potentially custom pager
TERM=dumb               — signals that there is no TTY
```

### Build (BuildTools.swift)

| Tool | Command | Arguments |
|------|---------|-----------|
| `build_project` | `xcodebuild -project Chappie.xcodeproj -scheme Chappie build` | — |
| `run_tests` | `xcodebuild test` or `swift test` | `target: "ChappieCoreTests"` |
| `read_build_log` | Reads `.build_log.txt` | — |

**Build log:** saved to `<workspacePath>/.build_log.txt`

---

## 6. Integration with ChappieCore

```
Chappie.app
  └── ToolExecutionService (actor)
        ├── [existing: list_files, read_file, write_file, ...]
        └── MCPToolBridge (actor)         ← service in ChappieCore
              │ Unix Domain Socket
              ▼
        ChappieMCP (child process)
              ├── GitTools
              └── BuildTools
```

**MCPToolBridge** (`ChappieCore/Services/MCPToolBridge.swift`):
- Connects to the socket on each tool call (no persistent connection)
- Timeout for build/test requests: 600 seconds (10 minutes)
- If helper is not running — returns a clear message instead of hanging

---

## 7. Mandatory Change Pipeline

Before every code change Chappie MUST follow this order:

```
1. git_status              → check for uncommitted changes
2. git_add + git_commit    → CHECKPOINT commit (rollback point)
3. write_file              → make changes
4. build_project           → compile (if fails — fix before proceeding)
5. run_tests               → tests (only if build is green)
6. git_add + git_commit    → RESULT commit (only if everything is green)
7. Report to user          → "you can press the triangle in Xcode"
```

**On build or test failure** — offer rollback to the checkpoint commit.

---

## 8. Tech Debt

| # | Description | Priority |
|---|-------------|----------|
| MCP-1 | Add `git_push` tool | 🟡 |
| MCP-2 | Streaming xcodebuild output (currently waits for completion) | 🟡 |
| MCP-3 | Request authentication (currently no auth) | 🟢 |

---

## 📚 Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-07-XX | Added Mermaid architecture diagram (section 3) per new architecture file rules | Chappie AI |
| 2026-07-XX | Architecture files translated to English | Chappie AI |
| 2026-06-XX | Refactoring: AI_Docs/ → single architecture.md | Chappie AI |
| 2026-06-XX | Fixed git hang — GIT_PAGER=cat | Chappie AI |
| 2026-06-XX | Switched from TCP to Unix Domain Socket | Chappie AI |
| 2026-05-29 | Initial creation | Chappie AI |
