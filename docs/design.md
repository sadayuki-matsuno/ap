# ap design notes

ap records the text that AI agents such as Claude Code put on the clipboard, together with which session and which request produced it, so it can be picked and pasted again later. This document summarizes the design and the decisions made during implementation.

## Principles

- **Leave the user's clipboard alone**: `ap` records into the history only; the user pastes from the Ap.app picker (Control-Command-P). `--clipboard` (`-c`) also writes the clipboard, first, as pbcopy would. A failed record exits non-zero, except with `--clipboard`, where the clipboard was already written and a warning is enough. `ap paste N`, the picker and menu clicks always write the clipboard
- **Record AI copies only**: ordinary human copies are not monitored
- **Attach the origin**: session title, repository, branch, the originating prompt and the preceding assistant text

## Decisions

| Topic | Decision |
|---|---|
| How agents call it | Rewrite the global CLAUDE.md rule "also put it on the clipboard with pbcopy" to `\| ap`. No pbcopy shim on PATH (add one later only if missed copies become noticeable) |
| Command name | `ap`. With piped stdin, plain `ap` records (`ap copy` is an alias). With `--clipboard` it is also a drop-in pbcopy replacement |
| Clipboard by default | No (user decision, 2026-10-04): agent output piling onto the system clipboard was the problem being solved, and the picker makes the clipboard step unnecessary |
| Enter in the picker (Phase 3) | Write the clipboard, return to the previously frontmost app and synthesize Cmd+V. A menu toggle switches Enter to copy-only, and it is copy-only until Accessibility is granted. Needs the Accessibility permission, so no App Sandbox |
| What is recorded | AI copies only (when no agent environment variables are present the clip is still recorded with `agent = human`) |
| Retention | 24 hours; pinned clips are kept. `ap` prunes expired clips as part of each copy |
| Storage | SQLite via GRDB.swift: WAL, file mode 600, FTS5 with the trigram tokenizer over content, label and prompt |
| Enrichment | Not done at copy time; filled in later (below) |
| Distribution | One Homebrew cask, `ap` (`brew install --cask sadayuki-matsuno/tap/ap`), instead of a CLI formula plus an app cask: it installs Ap.app and links the CLI from inside the bundle (`binary "#{appdir}/Ap.app/Contents/MacOS/ap"`), so the CLI and the app always come from the same build. `packaging/ap.rb` is the template for the tap's `Casks/ap.rb`. The release workflow (tag `v*`) builds the app ad hoc (`AP_SIGN_IDENTITY=- make app`, no certificate on the runner), publishes `Ap-<version>.zip` with its sha256, and rewrites the cask's `version` and `sha256` (the url is derived from the version), creating `Casks/ap.rb` from the template on the first release. Hyphenated tags are pre-releases and leave the tap alone. Not notarized, so the first launch needs "Open Anyway" or clearing the quarantine flag |
| Icon | A cream clipboard with a coral clip on a dark squircle, "ap" printed on the paper with the p's descender as the paste arrow (`assets/icon.svg`, bundled as `AppIcon.icns`). The menu bar uses the same parts as a template image at 18 pt: `assets/mark.svg` for @2x, and a pixel-grid redraw (`assets/mark-1x.svg`) for @1x, where the full mark blurs. `scripts/make-icons.sh` renders all of them with `rsvg-convert`; the outputs are committed so building needs no SVG renderer |

## Why enrichment is deferred

Observed on Claude Code 2.1.288: the tool_use row of the Bash command that is currently running is not in the transcript yet; it is written after the command exits. So `ap` can never read its own tool_use, no matter how long it waits. Detaching a child process to wait breaks in two ways: holding the output pipe keeps the Bash tool from finishing, and Claude Code's process cleanup kills the child.

So `ap` inserts a minimal row with `enrich_state='pending'` and returns immediately (it never spawns a background process). `ap list` / `ap enrich` and the resident Ap.app read the transcript later and fill the row in.

### Enrichment algorithm

1. Find `~/.claude/projects/*/<session_id>.jsonl` (override with `AP_CLAUDE_PROJECTS_DIR`). Lines are streamed, and each session's transcript is parsed once per run
2. Candidates are Bash tool_uses that invoke `ap` in command position (`| ap`, `ap copy`, a path such as `.../ap`, optionally preceded by `env` and/or `NAME=value` assignments such as `AP_DB_PATH=/p ap`; subcommands like `ap list` are excluded), or `pbcopy` as a fallback. `$AP`-style variable invocations are not recognized
3. A candidate must have been generated at or before created_at + 1 s, and either have no tool_result yet or a tool_result at or after created_at (the copying call runs across created_at). This rules out long-finished commands whose heredoc merely mentions `| ap`, which happened in real data
4. A candidate whose command contains the clip's first non-empty line (4+ characters) wins (heredocs, parallel calls). Otherwise the `ap` candidate (else `pbcopy`) generated closest to created_at. With parallel Bash calls or `echo a | ap; echo b | ap`, several clips may map to the same tool_use, which is accepted
5. If the parent transcript has no match, search subagent transcripts `<projects>/*/<session_id>/subagents/agent-<id>.jsonl`. A subagent's Bash inherits the parent's `CLAUDE_CODE_SESSION_ID`, but its tool_use rows are written there (observed 2026-10-03). Files last modified before created_at are skipped. On a match the session stays the parent session; the prompt is the parent session's latest human prompt before created_at; the context is "subagent type and description (from the sibling `.meta.json`: agentType / description) + task (the subagent transcript's first prompt, up to 300 characters) + the assistant text right before the tool_use". `clips.subagent` stores the description (or `agent-<id>`), shown in lists as `<- subagent: ...`
6. Prompt: walk parentUuid back from the tool_use row to the first user row that is a real prompt (a string or text blocks; tool_result rows, isMeta rows and harness-injected text starting with `<` are excluded). The chain also passes through attachment and other rows, so every row with a uuid is indexed. If the chain is broken (e.g. compaction), use the latest prompt by time
7. Context: assistant text walking back from the tool_use until a user row
8. Session title: the last `custom-title` row (the field name is unverified, so `customTitle` / `title` / `name` are tried in order), otherwise the last `ai-title` (`aiTitle`) Headless sessions (`claude -p`) get neither, so lists and the app show the first prompt (one line, up to 60 characters) instead (`ClipListing.displayTitle`), and the `session:` filter matches it when there is no title. The transcript records `gitBranch: "HEAD"` outside a git repository; that is treated as no branch (when parsing and when displaying older rows)
9. If nothing matches, the clip stays pending. After 10 minutes it becomes `failed`, with only the latest prompt before created_at filled in
10. Re-enriching never downgrades `done` to `failed` / `pending` and never overwrites existing values with null. Prompts and titles are stored as snapshots in the database, because Claude Code deletes old transcripts after `cleanupPeriodDays`

## Data model

`~/Library/Application Support/ap/ap.db` (override with `AP_DB_PATH`). All times are Unix epoch milliseconds stored as INTEGER.

- `sessions`: session_id, agent, title, first_prompt, cwd, repository (owner/name), git_branch, transcript_path, terminal, first_seen_at, last_seen_at. cwd / repository / branch are one unit describing the session's own directory: the first copy sets them, a later copy from the same cwd may fill a missing value, and a copy from another directory never touches them. Enrichment re-resolves them from the transcript's cwd when it differs or no repository is known, and commits cwd + repository + branch together only when git answered (a timeout keeps the old values and retries next time). The repository is owner/name from the origin remote, or the top-level directory name when there is no origin (for clips too). `ap list` shows them in the session header and shows a clip's own `repository | branch` only when it differs
- `clips`: id (AUTOINCREMENT, so an id is never reused after prune), uuid (also written to the pasteboard as `dev.ap.clip-id`), content, content_hash, content_kind (text/code/markdown/url/json), label, session_id, agent, cwd, git_branch, repository, terminal, tool_use_id, prompt_snapshot, context_snapshot, subagent (for copies made inside a subagent, its description), enrich_state, pinned, concealed, paste_count, created_at, last_pasted_at
- `clips_fts`: FTS5 external-content table (content, label, prompt_snapshot; tokenize='trigram') kept in sync by triggers. Only the first 65,536 characters of content are indexed (trigram indexing is linear in size)

Opening and migrating the database is serialized across processes with an `flock` on `ap.db.lock`, because parallel `| ap` calls on a fresh database otherwise race on `CREATE TABLE`.

## Pasteboard format

Written by `ap --clipboard`, `ap paste`, the picker and the menu. Everything is written as one `NSPasteboardItem`. Another process can clear the pasteboard between `clearContents` and `writeObjects` (parallel `| ap` calls do), so the write is retried up to 8 times with a short backoff; AppKit's log lines for failed attempts are kept off stderr.


- `public.utf8-plain-text`: the content
- `dev.ap.clip-id`: the clip uuid (lets the app tell which clip is currently on the clipboard)
- `org.nspasteboard.ConcealedType`: added for clips recorded with `--concealed`, or when a known token format is detected (`ghp_` / `github_pat_` / `sk-` / `AKIA...` / `-----BEGIN ... PRIVATE KEY-----` / `xox[baprs]-`). Lists mask such clips

## Layout

- `ApCore` (library): database, models, capture metadata, transcript parsing, enrichment, secret detection, list formatting, picker search and navigation. UI-free (does not import AppKit) so the CLI and the menu bar app share it
- `ApClipboard` (library): the NSPasteboard write described above (and reading the current `dev.ap.clip-id`), shared by the CLI and the app so both write exactly the same item
- `ap` (executable): the swift-argument-parser CLI
- `ApApp` (executable): the menu bar app, bundled by `scripts/build-app.sh` (`make app`) into `build/Ap.app` together with the `ap` CLI. The bundle executable is `ApApp`, not `Ap`: on a case-insensitive volume `Contents/MacOS/Ap` and `Contents/MacOS/ap` would be the same file
- `ApCoreTests`: swift-testing
- `assets/`: icon sources (SVG) and the generated icon files, plus the README screenshots. `packaging/`: Info.plist template, UI strings (`Resources/*.lproj`) and the cask template

## Picker (Ap.app)

- **Panel**: an `NSPanel` with `.nonactivatingPanel` that can become key. The frontmost app stays frontmost while the search field (an `NSTextField`, made first responder on every open) takes typing. Keys are intercepted by a local event monitor before they reach the field; while an input method has marked text, keys go to it. Clicking elsewhere (resign key) closes the panel. Every open clears the search and selects the newest clip
- **Hotkey**: Control-Command-P by default, through Carbon `RegisterEventHotKey` (no Accessibility permission needed for the hotkey itself; pressing it again closes the panel). A Carbon hotkey takes its key before any app sees it, so the recorder refuses combinations whose only modifier is Command (with or without Shift), apart from Command-Space and F-keys: they would shadow the picker's own keys (Command-P / O / , / Return / Delete), the synthetic Command-V that Enter sends, and the same shortcut in every other app. If the saved hotkey can't be registered at launch (another app owns it), the default is registered in its place when it is free (in memory only; the saved one is tried again next launch); the menu shows "Open Picker (shortcut unavailable)" when neither registers, and Settings shows a warning in both cases
- **Settings window** (menu "Settings..." / Command-, in the picker; a SwiftUI `Form`): the hotkey recorder, the "Enter pastes" toggle, the Accessibility status, Launch at Login and Language (the menu keeps its quick items). The recorder takes the next key press through the app's local event monitor; `Shortcut.interpret` (ApCore, tested) maps plain Esc to cancel, plain Delete to reset, and rejects combinations without Command / Control / Option or with Command (and Shift) alone, with a message saying why. The Carbon hotkey is unregistered while recording, so the current combination can be recorded again. A new combination is registered before it is saved; if `RegisterEventHotKey` refuses it (taken by another app or macOS) the old one is registered again and the window says so. Stored in UserDefaults `hotKey` as `{keyCode, modifiers}` (Carbon masks); a malformed, out-of-range (key code outside 0-127, modifier bits other than Command / Shift / Option / Control) or no longer valid stored value falls back to the default. The Reset button shows the default in the current layout (⌃⌘L on Dvorak). Keys are shown with the character the current layout types (`UCKeyTranslate`), with fixed labels for F-keys, arrows, Space and similar (`Shortcut.symbols`); the menu's "Open Picker" item shows the current hotkey
- **Search** (`ClipQuery` + `ClipStore.clips(matching:limit:)`): plain text matches content, label and prompt, through the trigram index for 3+ characters and `LIKE` (with `%` / `_` escaped) below that, since trigram cannot match shorter strings. Concealed clips match on label and prompt only, so typing part of a secret never reveals which clip holds it. Filters: `repo:` (clip's or session's repository), `session:` (title substring), `kind:`, `pinned`; double quotes group words. A filter with an empty value is ignored while it is being typed; unknown prefixes stay text
- **Navigation** (`ClipListing.clipId(from:offset:in:)` / `groupJump`): rows are the grouped order of `ClipListing.group`; Tab / Shift-Tab go to the first clip of the next / previous group and stay put at the ends
- **Enter**: write the clip with ApClipboard, `markPasted` (as `ap paste` does), close the panel, re-activate the app that was frontmost when the panel opened (when that is Ap itself, e.g. right after Settings had the focus, the last other app seen through `NSWorkspace.didActivateApplicationNotification`; closing Settings also hands the focus back to the app that had it), wait 80 ms, and post Command-V (key code 9 with `.maskCommand`, down and up) to `.cghidEventTap`. With the "Enter pastes" toggle off, Enter copies only; without the Accessibility permission see the onboarding below. The key code is the one that types "v" in the current keyboard layout (`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate` over key codes 0-127), falling back to the ANSI position 9, so Dvorak and AZERTY work. Command-Delete deletes the selected clip only while the search field is empty; otherwise it keeps its text meaning
- **Accessibility onboarding**: Enter without the permission copies the clip, keeps the panel open and shows an inline banner ("Allow Ap to paste into other apps": Open Accessibility Settings / Not now). The same banner opens once on first launch when "Enter pastes" is on (remembered in UserDefaults). Open Accessibility Settings (also the menu's "Allow Direct Paste...") calls `AXIsProcessTrustedWithOptions` with the prompt option (registers Ap in the list), opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, closes the panel and polls `AXIsProcessTrusted()` every second until it turns true; then "Enter pastes" is switched on and the next open shows "Direct paste is on". macOS gives no way to read whether an "Ap" entry already exists (TCC.db needs Full Disk Access), so once Settings has been opened from Ap (a later Enter, or opening the panel while still waiting for the grant), the banner adds the hints for the two cases that cause it (a stale entry from an older ad-hoc signed build: remove it with the minus button and add it again; a grant that applies only to a new process) and a Relaunch Ap button, which starts a new instance with the same environment (after releasing the hotkey) and quits
- **Command-O** writes `cd <session cwd> && claude --resume <session_id>` as plain text (no `dev.ap.clip-id`, since it is not a clip); the cwd is single-quoted when it has characters outside a safe set
- **Live data**: a GRDB `ValueObservation` over the current query drives the list, but it only sees writes made through the app's own pool. Writes from the `ap` CLI are noticed by checking the size and mtime of `ap.db` / `ap.db-wal` once a second and restarting the observation. The pasteboard's `changeCount` is polled at the same time for the "on clipboard" marker
- **Background work**: enrichment runs on a utility queue every 5 seconds when pending clips exist, and when the panel opens; prune (24 h, pinned kept) runs at launch and hourly. Everything goes through `ClipStore`
- **Preview**: concealed content stays masked until Reveal is clicked or Control is held on its own for 0.2 s (`RevealGate`): only a Control press made while the panel is open arms it, so Control still held from the Control-Command-P hotkey doesn't count; another modifier or any key typed during the hold (Control-A / Control-E in the search field) cancels it until Control is pressed again. Command is not used because every panel shortcut needs it. Reset on selection change. The preview shows the first 20,000 characters (SwiftUI `Text` gets slow on megabytes); the whole clip is still what gets pasted
- **Signing**: TCC keys the Accessibility grant on the designated requirement. An ad-hoc signature's requirement is its cdhash, so every rebuild was a new app and a granted "Ap" entry silently stopped matching. `scripts/build-app.sh` therefore signs (inner `ap` first, then the bundle) with `$AP_SIGN_IDENTITY`, else `ap-dev`, else `shepherd-dev`, trying codesign directly (`security find-identity -v` hides untrusted self-signed certificates that codesign can still use), and falls back to ad hoc with instructions for creating `ap-dev`. A self-signed certificate is enough: the requirement then names the certificate, not the hash. Release builds without a certificate (`AP_SIGN_IDENTITY=-`) stay ad hoc
- **Demo**: `scripts/seed-demo.sh <db>` creates the schema with `ap doctor` and inserts sample rows with sqlite3 (no clipboard writes). The app honors `AP_DB_PATH` / `AP_CLAUDE_PROJECTS_DIR`; `AP_OPEN_PICKER_ON_LAUNCH=1` / `AP_OPEN_MENU_ON_LAUNCH=1` open the panel / menu at launch for screenshots

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1. Capture | `ap` / `ap copy`, database, `ap list` / `ap paste` / `pin` / `unpin` / `prune` / `doctor` | Done |
| 2. Enrichment | `ap enrich` (Claude Code adapter, including subagent transcripts) and lazy enrichment from `ap list` | Done |
| 3. Picker | Menu bar app (global hotkey panel, Enter pastes with Cmd+V), resident enrichment, hourly prune, `ap delete` | Done, except the fzf-based `ap pick` (not started). Deviations: resident enrichment polls every 5 s instead of using FSEvents and still re-parses whole transcripts; the mock's `agent:` filter and date menu, and the menu's "last copy source session" entry, are not implemented |
| 4. Extensions | `ap open` (jump back to the session / zellij pane), adapters for other agents (Codex, Gemini) | Not started (secret detection and retention were pulled into Phase 1) |

## Known limitations and open questions

- The field name of `custom-title` rows is unverified. `agent-name` (`agentName`) rows exist in regular session transcripts too, but their meaning is unverified, so they are not used
- Suppressing consecutive duplicates (content_hash) is not implemented yet (the hash is stored)
- FTS5 trigram works with the system SQLite (3.51.0 on macOS 26); `ap doctor` checks it
- Enrichment cost: on the largest local transcript (29.5 MB) `ap list` took 0.58 s with 88 MB max RSS (measured 2026-10-03). While clips stay pending (up to 10 minutes) every `ap list`, and Ap.app every 5 seconds, re-parses the transcript; reading only the appended tail is still open
- Copy cost for large input: secret detection runs its regexes only on short windows around literal anchors (`ghp_`, `sk-`, ...) and content-kind looks at the first 64 KB, so a 1 MB copy takes about 0.25-0.3 s (measured 2026-10-04, previously 5.8 s)
- `ap` with empty input leaves the clipboard unchanged (pbcopy would clear it; this avoids wiping the clipboard when invoked with stdin at /dev/null)
