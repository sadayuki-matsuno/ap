# ap design notes

ap records the text that AI agents such as Claude Code put on the clipboard, together with which session and which request produced it, so it can be picked and pasted again later. This document summarizes the design and the decisions made during implementation.

## Principles

- **Never break the copy**: `ap` writes the regular clipboard (NSPasteboard) first. If recording to the database fails it only prints a warning and still exits 0
- **Record AI copies only**: ordinary human copies are not monitored
- **Attach the origin**: session title, repository, branch, the originating prompt and the preceding assistant text

## Decisions

| Topic | Decision |
|---|---|
| How agents call it | Rewrite the global CLAUDE.md rule "also put it on the clipboard with pbcopy" to `\| ap`. No pbcopy shim on PATH (add one later only if missed copies become noticeable) |
| Command name | `ap`. With piped stdin, plain `ap` copies (`ap copy` is an alias). Works as a drop-in pbcopy replacement |
| Enter in the picker (Phase 3) | Write the clipboard, return to the previously frontmost app and synthesize Cmd+V. A setting switches Enter to copy-only. Needs the Accessibility permission, so no App Sandbox |
| What is recorded | AI copies only (when no agent environment variables are present the clip is still recorded with `agent = human`) |
| Retention | 24 hours; pinned clips are kept. `ap` prunes expired clips as part of each copy |
| Storage | SQLite via GRDB.swift: WAL, file mode 600, FTS5 with the trigram tokenizer over content, label and prompt |
| Enrichment | Not done at copy time; filled in later (below) |

## Why enrichment is deferred

Observed on Claude Code 2.1.288: the tool_use row of the Bash command that is currently running is not in the transcript yet; it is written after the command exits. So `ap` can never read its own tool_use, no matter how long it waits. Detaching a child process to wait breaks in two ways: holding the output pipe keeps the Bash tool from finishing, and Claude Code's process cleanup kills the child.

So `ap` inserts a minimal row with `enrich_state='pending'` and returns immediately (it never spawns a background process). `ap list` / `ap enrich` (and, from Phase 3, the resident app) read the transcript later and fill the row in.

### Enrichment algorithm

1. Find `~/.claude/projects/*/<session_id>.jsonl` (override with `AP_CLAUDE_PROJECTS_DIR`). Lines are streamed, and each session's transcript is parsed once per run
2. Candidates are Bash tool_uses that invoke `ap` in command position (`| ap`, `ap copy`, a path such as `.../ap`, optionally preceded by `env` and/or `NAME=value` assignments such as `AP_DB_PATH=/p ap`; subcommands like `ap list` are excluded), or `pbcopy` as a fallback. `$AP`-style variable invocations are not recognized
3. A candidate must have been generated at or before created_at + 1 s, and either have no tool_result yet or a tool_result at or after created_at (the copying call runs across created_at). This rules out long-finished commands whose heredoc merely mentions `| ap`, which happened in real data
4. A candidate whose command contains the clip's first non-empty line (4+ characters) wins (heredocs, parallel calls). Otherwise the `ap` candidate (else `pbcopy`) generated closest to created_at. With parallel Bash calls or `echo a | ap; echo b | ap`, several clips may map to the same tool_use, which is accepted
5. If the parent transcript has no match, search subagent transcripts `<projects>/*/<session_id>/subagents/agent-<id>.jsonl`. A subagent's Bash inherits the parent's `CLAUDE_CODE_SESSION_ID`, but its tool_use rows are written there (observed 2026-10-03). Files last modified before created_at are skipped. On a match the session stays the parent session; the prompt is the parent session's latest human prompt before created_at; the context is "subagent type and description (from the sibling `.meta.json`: agentType / description) + task (the subagent transcript's first prompt, up to 300 characters) + the assistant text right before the tool_use". `clips.subagent` stores the description (or `agent-<id>`), shown in lists as `<- subagent: ...`
6. Prompt: walk parentUuid back from the tool_use row to the first user row that is a real prompt (a string or text blocks; tool_result rows, isMeta rows and harness-injected text starting with `<` are excluded). The chain also passes through attachment and other rows, so every row with a uuid is indexed. If the chain is broken (e.g. compaction), use the latest prompt by time
7. Context: assistant text walking back from the tool_use until a user row
8. Session title: the last `custom-title` row (the field name is unverified, so `customTitle` / `title` / `name` are tried in order), otherwise the last `ai-title` (`aiTitle`)
9. If nothing matches, the clip stays pending. After 10 minutes it becomes `failed`, with only the latest prompt before created_at filled in
10. Re-enriching never downgrades `done` to `failed` / `pending` and never overwrites existing values with null. Prompts and titles are stored as snapshots in the database, because Claude Code deletes old transcripts after `cleanupPeriodDays`

## Data model

`~/Library/Application Support/ap/ap.db` (override with `AP_DB_PATH`). All times are Unix epoch milliseconds stored as INTEGER.

- `sessions`: session_id, agent, title, first_prompt, cwd, repository (owner/name), git_branch, transcript_path, terminal, first_seen_at, last_seen_at. cwd / repository / branch are one unit describing the session's own directory: the first copy sets them, a later copy from the same cwd may fill a missing value, and a copy from another directory never touches them. Enrichment re-resolves them from the transcript's cwd when it differs or no repository is known, and commits cwd + repository + branch together only when git answered (a timeout keeps the old values and retries next time). The repository is owner/name from the origin remote, or the top-level directory name when there is no origin (for clips too). `ap list` shows them in the session header and shows a clip's own `repository | branch` only when it differs
- `clips`: id (AUTOINCREMENT, so an id is never reused after prune), uuid (also written to the pasteboard as `dev.ap.clip-id`), content, content_hash, content_kind (text/code/markdown/url/json), label, session_id, agent, cwd, git_branch, repository, terminal, tool_use_id, prompt_snapshot, context_snapshot, subagent (for copies made inside a subagent, its description), enrich_state, pinned, concealed, paste_count, created_at, last_pasted_at
- `clips_fts`: FTS5 external-content table (content, label, prompt_snapshot; tokenize='trigram') kept in sync by triggers. Only the first 65,536 characters of content are indexed (trigram indexing is linear in size)

Opening and migrating the database is serialized across processes with an `flock` on `ap.db.lock`, because parallel `| ap` calls on a fresh database otherwise race on `CREATE TABLE`.

## Pasteboard format

Everything is written as one `NSPasteboardItem`. Another process can clear the pasteboard between `clearContents` and `writeObjects` (parallel `| ap` calls do), so the write is retried up to 8 times with a short backoff; AppKit's log lines for failed attempts are kept off stderr.


- `public.utf8-plain-text`: the content
- `dev.ap.clip-id`: the clip uuid (lets the app tell which clip is currently on the clipboard)
- `org.nspasteboard.ConcealedType`: added with `--concealed`, or when a known token format is detected (`ghp_` / `github_pat_` / `sk-` / `AKIA...` / `-----BEGIN ... PRIVATE KEY-----` / `xox[baprs]-`). Lists mask such clips

## Layout

- `ApCore` (library): database, models, capture metadata, transcript parsing, enrichment, secret detection, list formatting. UI-free (does not import AppKit) so the Phase 3 menu bar app can share it
- `ap` (executable): the swift-argument-parser CLI and the NSPasteboard writes
- `ApCoreTests`: swift-testing

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1. Capture | `ap` / `ap copy`, database, `ap list` / `ap paste` / `pin` / `unpin` / `prune` / `doctor` | Done |
| 2. Enrichment | `ap enrich` (Claude Code adapter, including subagent transcripts) and lazy enrichment from `ap list` | Done |
| 3. Picker | Menu bar app (global hotkey panel, Enter pastes with Cmd+V), fzf-based `ap pick`, resident enrichment (FSEvents), hourly prune | Not started |
| 4. Extensions | `ap open` (jump back to the session / zellij pane), adapters for other agents (Codex, Gemini) | Not started (secret detection and retention were pulled into Phase 1) |

## Known limitations and open questions

- The field name of `custom-title` rows is unverified. `agent-name` (`agentName`) rows exist in regular session transcripts too, but their meaning is unverified, so they are not used
- Suppressing consecutive duplicates (content_hash) is not implemented yet (the hash is stored)
- FTS5 trigram works with the system SQLite (3.51.0 on macOS 26); `ap doctor` checks it
- Enrichment cost: on the largest local transcript (29.5 MB) `ap list` took 0.58 s with 88 MB max RSS (measured 2026-10-03). While clips stay pending (up to 10 minutes) every `ap list` re-parses the transcript; the resident app should read only the appended tail
- Copy cost for large input: secret detection runs its regexes only on short windows around literal anchors (`ghp_`, `sk-`, ...) and content-kind looks at the first 64 KB, so a 1 MB copy takes about 0.25-0.3 s (measured 2026-10-04, previously 5.8 s)
- `ap` with empty input leaves the clipboard unchanged (pbcopy would clear it; this avoids wiping the clipboard when invoked with stdin at /dev/null)
