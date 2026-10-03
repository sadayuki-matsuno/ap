# ap

A clipboard ledger for AI agents on macOS — `ap` is a drop-in `pbcopy` replacement that also remembers *which* [Claude Code](https://claude.com/claude-code) session and *which* request produced each copy.

```sh
brew install sadayuki-matsuno/tap/ap
```

When an agent hands you a Slack reply, a SQL query and a PR description in one afternoon, they all end up on the same clipboard and overwrite each other. Pipe them through `ap` instead and every copy is kept for 24 hours with its session title, repository, branch, the prompt that asked for it and the explanation right before it — ready to be put back on the clipboard.

## Features

- **pbcopy replacement** — `... | ap` writes the regular clipboard first (UTF-8 safe, unlike `/usr/bin/pbcopy` under a non-UTF-8 locale), then records. A database error never breaks the copy
- **Knows where a copy came from** — session ID, agent, cwd, git branch, `owner/name` repository and terminal (Ghostty, zellij session and pane) are captured at copy time
- **Context from the transcript** — the originating prompt, the preceding assistant text, the Bash `tool_use_id` and the session title are filled in from the Claude Code transcript, including copies made inside subagents
- **Grouped history** — `ap list` shows clips grouped by session, newest first; `ap list --json` for scripts and fzf
- **Paste again** — `ap paste 2` puts the second newest clip back on the clipboard
- **Secrets stay quiet** — known token formats (GitHub, OpenAI/Anthropic-style `sk-`, AWS access keys, private keys, Slack) are detected; the clipboard item is marked concealed for clipboard managers and lists mask it
- **24-hour retention** — older clips are pruned as you copy; pinned clips are kept
- **Local only** — one SQLite file (WAL, mode 600, FTS5 trigram search). Nothing is sent anywhere

## Requirements

- macOS 14 (Sonoma) or later, Apple silicon for the prebuilt binary
- To build from source: Swift 6 (Xcode or just the Command Line Tools: `xcode-select --install`)

## Install

### Homebrew

```sh
brew install sadayuki-matsuno/tap/ap
```

### From source

```sh
git clone https://github.com/sadayuki-matsuno/ap.git
cd ap
make test
make install                     # installs ~/.local/bin/ap
make install PREFIX=/usr/local   # or anywhere else
```

A prebuilt arm64 tarball is also attached to each [GitHub Release](https://github.com/sadayuki-matsuno/ap/releases).

## Usage

```sh
echo hello | ap                        # copy and record (pbcopy replacement)
ap copy < notes.txt                    # same thing, explicit
printf '%s' "$TOKEN" | ap --concealed  # mark as sensitive

cat <<'EOF' | ap --label "Slack reply"
Thanks, the root cause was a double launch.
EOF

ap list                    # history grouped by session (runs pending enrichment first)
ap list --session ID --limit 20
ap list --json             # machine-readable; concealed content is blanked
ap paste 2                 # put the 2nd newest clip back on the clipboard
ap pin 42                  # keep clip #42 past the retention period (ap unpin 42 to undo)
ap enrich --pending        # run enrichment now (ap enrich 42 re-runs one clip)
ap prune --older-than 24h
ap doctor                  # DB path, enrichment counts, SQLite version, FTS5 trigram check
ap --version
```

### Let Claude Code use it

Replace the pbcopy rule in your global `~/.claude/CLAUDE.md` with something like:

```md
When you put text on the clipboard, pipe it to `ap` instead of pbcopy (`... | ap`), and add `--label "<what it is>"` when the purpose is clear.
```

`ap` only records what is piped into it, so ordinary copies you make yourself are never captured.

## How it works

1. `ap` reads stdin and writes the general pasteboard: the text, a custom `dev.ap.clip-id` type holding the clip's UUID, and `org.nspasteboard.ConcealedType` for sensitive content. If that fails, it exits non-zero.
2. It records the clip in `~/Library/Application Support/ap/ap.db` with what the environment tells it: `CLAUDE_CODE_SESSION_ID`, `AI_AGENT` / `CLAUDECODE`, the cwd, `git` branch and origin, `TERM_PROGRAM`, `ZELLIJ_SESSION_NAME` / `ZELLIJ_PANE_ID`. Then it prunes expired clips. It never spawns a background process.
3. Claude Code writes a Bash call's `tool_use` row to the transcript only after the command finishes, so `ap` cannot see its own call at copy time. New clips are stored as `pending`; `ap list` and `ap enrich` later read `~/.claude/projects/*/<session_id>.jsonl` (and the session's `subagents/agent-*.jsonl`), find the Bash call that piped into `ap`, and snapshot the prompt, preceding text and session title into the database — transcripts get cleaned up eventually, the snapshots don't.

See [docs/design.md](docs/design.md) for the matching rules and the data model.

## Environment variables

| Variable | Purpose |
|---|---|
| `AP_DB_PATH` | Database location (default `~/Library/Application Support/ap/ap.db`) |
| `AP_CLAUDE_PROJECTS_DIR` | Transcript root (default `~/.claude/projects`) |

## Development

```sh
make test     # swift test; adds the Testing.framework paths automatically when only the Command Line Tools are installed
make build    # swift build -c release
```

## License

[MIT](LICENSE)
