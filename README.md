# ap

A clipboard ledger for AI agents on macOS — agents pipe text into `ap` instead of `pbcopy`, and `ap` remembers *which* [Claude Code](https://claude.com/claude-code) session and *which* request produced each copy. You paste them from a menu bar picker when you need them.

```sh
brew install sadayuki-matsuno/tap/ap
```

When an agent hands you a Slack reply, a SQL query and a PR description in one afternoon, they all end up on the same clipboard and overwrite each other. Pipe them through `ap` instead: every copy is kept for 24 hours with its session title, repository, branch, the prompt that asked for it and the explanation right before it, and your own clipboard is left alone. Press Control-Command-P to pick one and paste it.

## Features

- **History, not clipboard** — `... | ap` records the text without touching the system clipboard, so agent output never overwrites what you copied yourself. `ap --clipboard` (`-c`) also writes the clipboard like `pbcopy` (UTF-8 safe, unlike `/usr/bin/pbcopy` under a non-UTF-8 locale)
- **Knows where a copy came from** — session ID, agent, cwd, git branch, `owner/name` repository and terminal (Ghostty, zellij session and pane) are captured at copy time
- **Context from the transcript** — the originating prompt, the preceding assistant text, the Bash `tool_use_id` and the session title are filled in from the Claude Code transcript, including copies made inside subagents
- **Grouped history** — `ap list` shows clips grouped by session, newest first; `ap list --json` for scripts and fzf
- **Paste again** — `ap paste 2` puts the second newest clip back on the clipboard
- **Menu bar picker** — `Ap.app` opens a search panel with Control-Command-P: clips grouped by session, the full text, the prompt behind it, and Enter pastes it into the app you were in. English and Japanese UI
- **Secrets stay quiet** — known token formats (GitHub, OpenAI/Anthropic-style `sk-`, AWS access keys, private keys, Slack) are detected; lists mask them, and a clipboard item written for them is marked concealed for clipboard managers
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
echo hello | ap                        # record (the clipboard is left alone)
echo hello | ap -c                     # record and write the clipboard (like pbcopy); also --clipboard
ap copy < notes.txt                    # same as plain ap, explicit
printf '%s' "$TOKEN" | ap --concealed  # mark as sensitive

cat <<'EOF' | ap --label "Slack reply"
Thanks, the root cause was a double launch.
EOF

ap list                    # history grouped by session (runs pending enrichment first)
ap list --session ID --limit 20
ap list --json             # machine-readable; concealed content is blanked
ap paste 2                 # put the 2nd newest clip back on the clipboard
ap pin 42                  # keep clip #42 past the retention period (ap unpin 42 to undo)
ap delete 42               # delete clip #42 (pinned or not)
ap enrich --pending        # run enrichment now (ap enrich 42 re-runs one clip)
ap prune --older-than 24h
ap doctor                  # DB path, enrichment counts, SQLite version, FTS5 trigram check
ap --version
```

### Menu bar picker (Ap.app)

```sh
make app                 # builds build/Ap.app (the app plus the ap CLI in Contents/MacOS)
cp -R build/Ap.app /Applications/
open /Applications/Ap.app
```

Ap.app lives in the menu bar (no Dock icon). The menu shows the 10 newest clips (click one to copy it), **Open Picker**, **Enter pastes into the frontmost app**, **Allow Direct Paste...** (until the permission below is granted), **Launch at Login** and Quit.

Press **Control-Command-P** anywhere to open the picker. It floats over the current app without taking it out of the foreground, and the search field is ready for typing. The list shows clips grouped by session (newest first, with the session title, `repository | branch` and last copy time); the right side shows the full text, the prompt that produced it, the subagent / context snapshot and where it came from. The clip currently on the clipboard is marked "on clipboard". Concealed clips stay masked until you click Reveal or press and hold Control on its own (Control still held from the hotkey, or Control used with another key such as Control-A, doesn't count).

| Key | Action |
|---|---|
| Up / Down | Move the selection |
| Tab / Shift-Tab | Jump to the next / previous session |
| Enter | Paste into the app you were in (or copy only, when the menu toggle is off) |
| Command-Enter | Copy only |
| Command-P | Pin / unpin |
| Command-Delete | Delete the clip (with text in the search field, it deletes the text instead) |
| Command-O | Copy `cd <session cwd> && claude --resume <session id>` |
| Esc | Close |

Search matches content, label and prompt (concealed content is never matched). Filters can be combined with text:

```text
repo:genome kind:code          # repository substring, content kind (code, text, url, json, markdown)
session:"api refactor" pinned  # session title substring, pinned clips only
```

**Accessibility permission.** Pasting works by re-activating the previous app and sending Command-V, which needs Ap to be allowed in *System Settings > Privacy & Security > Accessibility*. On first launch, and whenever Enter is pressed without the permission, the picker copies the clip and shows a banner with **Open Accessibility Settings** (adds Ap to the list, shows the system prompt and opens the pane) and **Not now**; the menu's **Allow Direct Paste...** does the same. Ap notices the switch being turned on within a second, without a relaunch, and confirms with "Direct paste is on" the next time the picker opens. macOS ties the grant to the code signature. `make app` signs with a stable identity when it finds one (`$AP_SIGN_IDENTITY`, then a certificate named `ap-dev`, then `shepherd-dev`), so the grant survives rebuilds; for local builds, create a self-signed code signing certificate named `ap-dev` once (Keychain Access > Certificate Assistant > Create a Certificate, Self Signed Root, type Code Signing). Without one it signs ad hoc, each rebuild is a new app to macOS, and the existing "Ap" entry stops working: remove it with the minus button and add it again. If the switch is on but Ap still can't paste, the banner offers **Relaunch Ap**.

**Language.** The UI follows the macOS language (English or Japanese). The menu's **Language** submenu (System / English / Japanese) overrides it; the change applies after **Relaunch Ap**.

While it runs, Ap.app also enriches pending clips (every 5 seconds and when the picker opens) and prunes expired clips (at launch and hourly), so `ap list` rarely has to.

### Let Claude Code use it

Replace the pbcopy rule in your global `~/.claude/CLAUDE.md` with something like:

```md
When you hand me text to paste (a message, a command, a PR description), pipe it to `ap` instead of pbcopy (`... | ap`), and add `--label "<what it is>"` when the purpose is clear. I paste it from the Ap picker (Control-Command-P).
```

`ap` only records what is piped into it, so ordinary copies you make yourself are never captured.

## How it works

1. `ap` reads stdin. Only with `--clipboard` does it write the general pasteboard: the text, a custom `dev.ap.clip-id` type holding the clip's UUID, and `org.nspasteboard.ConcealedType` for sensitive content (if that fails, it exits non-zero). `ap paste`, the picker and the menu write the same item.
2. It records the clip in `~/Library/Application Support/ap/ap.db` with what the environment tells it: `CLAUDE_CODE_SESSION_ID`, `AI_AGENT` / `CLAUDECODE`, the cwd, `git` branch and origin, `TERM_PROGRAM`, `ZELLIJ_SESSION_NAME` / `ZELLIJ_PANE_ID`. Then it prunes expired clips. If recording fails it exits non-zero (with `--clipboard`, the clipboard was still written, so it only warns). It never spawns a background process.
3. Claude Code writes a Bash call's `tool_use` row to the transcript only after the command finishes, so `ap` cannot see its own call at copy time. New clips are stored as `pending`; `ap list` and `ap enrich` later read `~/.claude/projects/*/<session_id>.jsonl` (and the session's `subagents/agent-*.jsonl`), find the Bash call that piped into `ap`, and snapshot the prompt, preceding text and session title into the database — transcripts get cleaned up eventually, the snapshots don't.

See [docs/design.md](docs/design.md) for the matching rules and the data model.

## Environment variables

| Variable | Purpose |
|---|---|
| `AP_DB_PATH` | Database location (default `~/Library/Application Support/ap/ap.db`) |
| `AP_CLAUDE_PROJECTS_DIR` | Transcript root (default `~/.claude/projects`) |

Ap.app reads the same variables from its environment, which makes a throwaway demo easy:

```sh
make app
scripts/seed-demo.sh /tmp/ap-demo.db     # sample clips from three sessions (the clipboard is not touched)
open -n build/Ap.app --env AP_DB_PATH=/tmp/ap-demo.db --env AP_CLAUDE_PROJECTS_DIR=/tmp/ap-empty
```

`AP_OPEN_PICKER_ON_LAUNCH=1` (or `AP_OPEN_MENU_ON_LAUNCH=1`) opens the picker (or the menu) right after launch, for screenshots. Add `--args -AppleLanguages '(ja)'` to try the Japanese UI.

## Development

```sh
make test     # swift test; adds the Testing.framework paths automatically when only the Command Line Tools are installed
make build    # swift build -c release
make app      # build/Ap.app, signed with ap-dev / $AP_SIGN_IDENTITY when available, else ad hoc (AP_SIGN_IDENTITY=- forces ad hoc)
```

## License

[MIT](LICENSE)
