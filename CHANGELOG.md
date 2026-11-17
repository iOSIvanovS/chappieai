# Changelog

Release notes for ChappieAI. Newest first.

Releases before 1.0.30 were never tagged, so these entries were reconstructed
from the git history and the publication dates in the appcast feed. Where a
release was built from work that never reached a commit, the entry says only
"Fixes and improvements" rather than guessing.

Dates are publication dates of the `.dmg` (UTC). Versions 1.0.26 and 1.0.27
were bumped in the project file but never published; they are not listed here.

---

## [1.0.30] — 2026-11-17

### Prompt caching for Anthropic-protocol routes

- The context window keeps a slack so the cached prefix of the prompt survives
  from one turn to the next instead of being rewritten.
- Routes that speak the native Anthropic protocol get a larger window allowance.
- The window is cut back to the limit when the head of the sent prefix changes,
  which is what happens when a message falls out of the window.
- The "cache is warm" mark is persisted, so it survives a relaunch.

### JSON tools

- `json_info`, `json_schema`, `json_get`, `json_find` — inspect and search a
  JSON file of any size without loading it into the context.
- `json_edit` — edit a JSON file in place so that every other byte, including
  formatting, key order and comments, stays exactly as it was.

### Agent memory management

- Settings → Agent memory: global, thread and project memory entries are listed
  with their type, key and the text the agent actually reads.
- Entries can be deleted one by one, with confirmation. Deleting an entry drops
  the cached system prompt, so the change applies on the next message.

### Tools

- `run_terminal` spills long output to a file and returns the head, the tail and
  a hint for reading the rest.
- `run_ssh` keeps its output when the command times out or is stopped.
- Terminal confirmation mode is replaced by a per-thread switch.
- `build_project`, `run_tests` and `read_build_log` are removed; builds and tests
  are run in the terminal.
- `loc_*` tools and the development environment setting are removed.
- Tool denial messages now say where the tool works and what to change.
- A tool call that produces no new output no longer counts as a repeat.

### Providers

- RouterAI preset: prompt caching flag, cost from `usage.cost`, balance from
  `/credits`.
- Claude models reached through a gateway use the native Anthropic protocol.
- Stream diagnostics: a request that ends without a result now reports why.

---

## [1.0.29] — 2026-11-09

- **Curl-Chappie.** An HTTP client for backend work: per-thread host allow-list
  with access levels, secrets kept in Keychain and never shown to the model,
  shared login sessions that re-authenticate on their own, and repeatable
  scenarios with preflight checks and cleanup.
- `curl_request`, `curl_session`, `curl_extract`, and scenario save/info/delete
  tools, with response projection (`pick`), `\uXXXX` decoding, collapsed routine
  headers and redaction before truncation.
- Settings UI for hosts and secrets, with validation, localized into all ten
  languages.
- Licensing removed: no license service, no payment or activation screens, no
  trial or plan modes.
- ChappieAI is now free software under GPL-3.0, with LICENSE, README, TRADEMARK,
  CONTRIBUTING and FUNDING.
- The remote providers catalogue is replaced with built-in provider presets.
- "Support the project" section in settings.
- Screenshots and a Gatekeeper guide added to the public repository.

## [1.0.28] — 2026-10-27

- PDF tools: `pdf_info`, `pdf_page_as_txt` and `pdf_page_as_image`, built on
  PDFKit.
- Sparkle closes modal sheets before relaunching, so the Relaunch button is no
  longer blocked by an open window.
- Release script takes the update build number from `CFBundleVersion`.

## [1.0.25] — 2026-10-27

Fixes and improvements.

## [1.0.24] — 2026-10-27

- Memory entries show their creation and last-update dates in the system prompt,
  so the agent can tell an old rule from a freshly written one.

## [1.0.23] — 2026-10-27

- Message timestamps are sent to the model: the time of the user message, the
  pause before the reply, and how long the previous reply took.

## [1.0.22] — 2026-10-26

This release is mostly hardening.

- **Fixed: messages could be lost on save.** Only the loaded window is written,
  in one transaction; the rest of the thread stays on disk.
- **Fixed: the thread list could be wiped silently.** Saves are queued in order,
  a failed save offers retry or skip, and threads can be recovered from their
  message chunks when the list itself is damaged.
- **Fixed: file tools could reach outside the project.** A single path guard
  confines file, document and localization tools to project roots.
- **Fixed: two different access gates could disagree.** Tool access is one
  deny-by-default table with a completeness test.
- The helper process got a per-instance socket, a parent watchdog, automatic
  restart and self-heal, read/write timeouts and a connection cap.
- Unified retry for LLM requests.
- The stop button now cancels running tools.
- Tool arguments are parsed leniently: numbers, booleans and nested values are
  accepted instead of dropping the whole call.
- One gate for oversized tool results, an image pipeline that downscales to
  2000 px, and embedded images from Word, Excel and PowerPoint delivered to the
  model as images.
- `read_document` returns all Excel sheets with workbook metadata.
- Command safety: a tokenizing check replaces the substring blocklist.
- The loop guard blocks a third identical call only when the results are
  identical too.
- `temperature` is no longer sent to providers.
- Xcode 27 and macOS 27 fixes: build errors, a launch crash in the toolbar,
  window dragging and double-click zoom over the title area.
- **The update signing key was replaced.** Installations older than this release
  cannot verify newer updates and must install 1.0.22 or later manually once.
  Threads, memory and settings are kept.

## [1.0.21] — 2026-10-22

- Full backup: providers, threads, messages and memory are exported to a single
  file and restored from it.

## [1.0.20] — 2026-08-05

- `view_image`: images are shown to the model as an image in a synthetic user
  message, which is the only form providers accept.

## [1.0.19] — 2026-08-04

- Project settings: per-project system prompt additions, agent role and tool
  access rights, with the interface localized.

## [1.0.18] — 2026-08-03

- Build and test timeout raised from 5 minutes to 1 hour: a legitimate clean
  build could be killed with no output.

## [1.0.17] — 2026-07-21

- The persistent terminal session handles long and interactive commands more
  reliably.

## [1.0.16] — 2026-07-20

- Commands that call `find` are capped at 60 seconds, so an unscoped `find /`
  cannot hang the tool for hours.

## [1.0.15] — 2026-07-18

- Live terminal window: a running command's output is shown as it arrives.

## [1.0.14] — 2026-07-07

- `run_ssh` accepts an explicit `identity_file`, for hosts whose key is not a
  default identity and not loaded in the ssh agent.

## [1.0.13] — 2026-06-27

- **Fixed: a crash** when two projects in a thread share the same display name.

## [1.0.12] — 2026-06-22

- Test schemes are detected from `xcodebuild -list`, so projects with a
  non-standard scheme name run their tests correctly.

## [1.0.11] — 2026-06-22

- Build tools locate the `.xcodeproj` in projects where the expected layout does
  not hold.

## [1.0.10] — 2026-06-22

- Document tools accept the project as an argument, so files in a non-default
  project of a multi-project thread resolve to the right path.

## [1.0.9] — 2026-06-22

- Storage moved from SwiftData to SQLite (GRDB), with chunked thread storage and
  tests for the chunk system.
- New file tools: `search_in_file`, `search_in_project`, `get_file_info`,
  `move_file`, `rename_file`, `patch_file`.
- Attachments are stored in UUID folders and passed to the model by reference
  instead of being embedded in every message; `fetch_attachment` and
  `send_attachment` tools.
- The owner license key is generated on request instead of being embedded.
- Internal modularization: the view model, syntax engine, settings sheets and
  chat views are split into focused files.
- Localization coverage restored to 100% across ten languages.

## [1.0.8] — 2026-06-15

- **Fixed: a critical launch failure** when the saved workspace bookmark was
  missing; the agent now starts with the tools it has instead of not starting at
  all.

## [1.0.7] — 2026-06-14

- **Fixed: the greeting in a new thread** no longer disappears when the thread is
  loaded.

## [1.0.6] — 2026-06-14

- A dimmed overlay during thread switching: no flash of an empty chat, and the
  input stays blocked until the thread is ready.
- MCP restarts once per thread assembly instead of twice.

## [1.0.5] — 2026-06-14

- Projects belong to the thread that references them. There is no global project
  registry and no bookmarks to keep in sync.

## [1.0.4] — 2026-06-11

- The cost badge is hidden when the cost is zero.
- The welcome greeting follows the system language.

## [1.0.3] — 2026-06-10

- File tools accept the project as a separate argument, so the agent can pass a
  bare filename. A failed tool marks only the project it touched, not all of
  them.

## [1.0.2] — 2026-06-10

Fixes and improvements.

## [1.0.1] — 2026-06-10

- **Fixed: projects created by the agent** had no bookmark and therefore no file
  access; an existing project is reused instead of being shadowed by a duplicate.
- Tool access is resolved per project on every call, and a tool appears in the
  list when any project in the thread allows it.

## [1.0.0] — 2026-06-10

First public release.

- An agent that works inside your project: reads and writes files, uses git,
  runs builds and tests, fetches web pages.
- Any provider: OpenAI, Anthropic, Gemini, DeepSeek, Ollama or any
  OpenAI-compatible API, with your own keys.
- Three-level memory — global, thread and project — kept between sessions.
- Threads with their own projects, model and settings.
- Streaming chat with Markdown, tables, syntax highlighting and attachments.
- Ten interface languages.
- Automatic updates via Sparkle.
