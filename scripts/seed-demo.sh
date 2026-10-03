#!/bin/bash
# Recreates a demo database with sample clips from three sessions, for trying Ap.app without real history:
#   scripts/seed-demo.sh /tmp/demo.db
#   open -n build/Ap.app --env AP_DB_PATH=/tmp/demo.db --env AP_CLAUDE_PROJECTS_DIR=/tmp/empty
# The schema is created by `ap doctor` (ApCore's migrations); rows are inserted with sqlite3 so the clipboard is
# never touched. Times are relative to now and stay within the 24h retention.
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${1:?usage: scripts/seed-demo.sh <path to demo.db>}"
AP_BIN="${AP_BIN:-$(swift build --show-bin-path)/ap}"
[ -x "$AP_BIN" ] || swift build --product ap

rm -f "$DB" "$DB-wal" "$DB-shm" "$DB.lock"
AP_DB_PATH="$DB" "$AP_BIN" doctor > /dev/null

sqlite3 "$DB" <<'SQL'
CREATE TEMP TABLE now AS SELECT CAST(strftime('%s', 'now') AS INTEGER) * 1000 AS ms;

INSERT INTO sessions (session_id, agent, title, first_prompt, cwd, repository, git_branch, terminal, first_seen_at, last_seen_at)
SELECT 'b7e4c2d0-1745-4f1a-9c3e-0a1b2c3d4e5f', 'claude-code', 'orders-api issue 1745: duplicate status updates',
  'Look into issue 1745, order statuses are updated twice', '/Users/demo/src/orders-api', 'acme/orders-api',
  'fix/1745', 'zellij:verdant-donkey#71', ms - 3 * 3600000, ms - 25 * 60000 FROM now
UNION ALL
SELECT '5a9d0e61-8c2b-4b7e-a3f4-6d5e4c3b2a19', 'claude-code', 'ap: picker panel design',
  'Design the menu bar picker for ap', '/Users/demo/src/ap', 'sadayuki-matsuno/ap', 'feat/picker', 'ghostty',
  ms - 5 * 3600000, ms - 70 * 60000 FROM now
UNION ALL
SELECT 'e2f3a4b5-c6d7-4e8f-9a0b-1c2d3e4f5a6b', 'claude-code', 'shepherd HUD refresh', 'Refresh the shepherd HUD layout',
  '/Users/demo/src/shepherd', 'sadayuki-matsuno/shepherd', 'main', 'ghostty', ms - 20 * 3600000, ms - 19 * 3600000 FROM now;

INSERT INTO clips (uuid, content, content_hash, content_kind, label, session_id, agent, cwd, git_branch, repository,
  terminal, tool_use_id, prompt_snapshot, context_snapshot, subagent, enrich_state, pinned, concealed, paste_count,
  created_at, last_pasted_at)
SELECT 'demo-0001', 'Hi team, quick update on #1745.

The root cause was the order status batch running twice on staging: the cron entry and the new scheduler both
started it at 14:00, so every order in the window got two status transitions.

Fix: the cron entry is removed in acme/orders-api#1752 and the batch now takes an advisory lock. I re-ran the
affected orders and they are consistent again. No customer-facing impact beyond the duplicate emails.',
  'demo', 'text', 'Slack reply', 'b7e4c2d0-1745-4f1a-9c3e-0a1b2c3d4e5f', 'claude-code', '/Users/demo/src/orders-api',
  'fix/1745', 'acme/orders-api', 'zellij:verdant-donkey#71', 'toolu_demo_1',
  'Draft a reply to this Slack thread. The cause looks like a double launch of the batch.',
  'The thread asks whether customers were affected. Here is a short reply that covers the cause, the fix and the impact.',
  NULL, 'done', 0, 0, 3, ms - 25 * 60000, ms - 20 * 60000 FROM now
UNION ALL
SELECT 'demo-0002', 'SELECT o.id, o.status, COUNT(*) AS transitions
FROM orders o
JOIN order_status_history h ON h.order_id = o.id
WHERE h.created_at BETWEEN ''2026-10-03 14:00'' AND ''2026-10-03 14:10''
GROUP BY o.id, o.status
HAVING COUNT(*) > 1
ORDER BY transitions DESC;',
  'demo', 'code', 'Duplicate transitions query', 'b7e4c2d0-1745-4f1a-9c3e-0a1b2c3d4e5f', 'claude-code',
  '/Users/demo/src/orders-api', 'fix/1745', 'acme/orders-api', 'zellij:verdant-donkey#71', 'toolu_demo_2',
  'Give me a query that lists the orders with duplicate status transitions in that window.', NULL,
  NULL, 'done', 0, 0, 1, ms - 48 * 60000, NULL FROM now
UNION ALL
SELECT 'demo-0003', '*/5 * * * * /opt/orders/bin/status-batch --once   # legacy cron entry (still active)
0 14 * * * scheduler run status-batch                     # new scheduler job',
  'demo', 'code', 'Conflicting batch schedules', 'b7e4c2d0-1745-4f1a-9c3e-0a1b2c3d4e5f', 'claude-code',
  '/Users/demo/src/orders-api', 'fix/1745', 'acme/orders-api', 'zellij:verdant-donkey#71', 'toolu_demo_3',
  'Look into issue 1745, order statuses are updated twice',
  'Subagent (Explore): Investigate batch scheduler

Task: Find every place that starts the order status batch (cron, scheduler, manual scripts) and report how they overlap.

Both the legacy cron entry and the new scheduler job start status-batch. The cron entry was supposed to be removed when the scheduler went live, but it is still installed on the staging host. These two lines are the overlap.',
  'Investigate batch scheduler', 'done', 0, 0, 0, ms - 60 * 60000, NULL FROM now
UNION ALL
SELECT 'demo-0004', 'sk-live-4f9b2c7d1e8a6b3c5d0e9f7a2b4c6d8e', 'demo', 'text', 'Staging API key',
  'b7e4c2d0-1745-4f1a-9c3e-0a1b2c3d4e5f', 'claude-code', '/Users/demo/src/orders-api', 'fix/1745', 'acme/orders-api',
  'zellij:verdant-donkey#71', 'toolu_demo_4', 'Put the staging API key on the clipboard so I can test the endpoint.',
  NULL, NULL, 'done', 0, 1, 0, ms - 95 * 60000, NULL FROM now
UNION ALL
SELECT 'demo-0005', '## Summary

Adds the menu bar picker (`Ap.app`). Press Control-Command-P to open a floating panel that lists recent clips grouped
by Claude Code session, with a preview, the prompt that produced each clip, and where it came from.

## Changes

- `ApClipboard`: pasteboard writes shared by the CLI and the app
- `ApApp`: status item, global hotkey, non-activating picker panel
- `ClipQuery`: search with `repo:`, `session:`, `kind:` and `pinned` filters
- `ap delete ID`

## How to test

1. `make app && open build/Ap.app`
2. Copy something with `echo hello | ap`
3. Press Control-Command-P, pick the clip and press Enter

## Notes

- Enter pastes into the previously frontmost app and needs the Accessibility permission
- Without it, Enter copies only and the footer explains how to grant it
- Ad-hoc signed builds may need the permission granted again after a rebuild

## Screenshots

(see the PR)',
  'demo', 'markdown', 'PR description', '5a9d0e61-8c2b-4b7e-a3f4-6d5e4c3b2a19', 'claude-code', '/Users/demo/src/ap',
  'feat/picker', 'sadayuki-matsuno/ap', 'ghostty', 'toolu_demo_5', 'Write the PR description for the picker branch.',
  'The branch adds four things; the description lists them with a short test plan.', NULL, 'done', 0, 0, 2,
  ms - 70 * 60000 - 30000, ms - 65 * 60000 FROM now
UNION ALL
SELECT 'demo-0006', 'make app && open -n build/Ap.app --env AP_DB_PATH="$PWD/demo.db"', 'demo', 'code',
  'Demo launch command', '5a9d0e61-8c2b-4b7e-a3f4-6d5e4c3b2a19', 'claude-code', '/Users/demo/src/ap', 'feat/picker',
  'sadayuki-matsuno/ap', 'ghostty', 'toolu_demo_6', 'How do I launch the app against a scratch database?', NULL,
  NULL, 'done', 1, 0, 5, ms - 4 * 3600000, ms - 2 * 3600000 FROM now
UNION ALL
SELECT 'demo-0007', 'https://developer.apple.com/documentation/appkit/nspanel', 'demo', 'url', NULL,
  'e2f3a4b5-c6d7-4e8f-9a0b-1c2d3e4f5a6b', 'claude-code', '/Users/demo/src/shepherd', 'main',
  'sadayuki-matsuno/shepherd', 'ghostty', 'toolu_demo_7', 'Link me the docs for floating panels.', NULL, NULL,
  'done', 0, 0, 0, ms - 19 * 3600000, NULL FROM now
UNION ALL
SELECT 'demo-0008', '{"columns": ["status", "agent", "title"], "refreshSeconds": 2, "compact": true}', 'demo', 'json',
  'HUD config', 'e2f3a4b5-c6d7-4e8f-9a0b-1c2d3e4f5a6b', 'claude-code', '/Users/demo/src/shepherd', 'main',
  'sadayuki-matsuno/shepherd', 'ghostty', NULL, 'Make the HUD layout configurable.', NULL, NULL, 'failed', 0, 0, 0,
  ms - 20 * 3600000, NULL FROM now
UNION ALL
SELECT 'demo-0009', 'Thanks for the review! I will follow up on the naming in a separate PR.', 'demo', 'text', NULL,
  NULL, 'human', '/Users/demo', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'done', 0, 0, 0, ms - 150 * 60000, NULL
  FROM now;
SQL

echo "seeded: $DB ($(sqlite3 "$DB" 'SELECT COUNT(*) FROM clips') clips)"
