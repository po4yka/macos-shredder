# macOS Shredder

`macos-shredder` is a macOS-only cleanup script for shell histories, logs,
browser data, usage databases, caches, Trash, and related activity traces.

> Warning: this program deletes data. Run a dry-run first. Use it only on a
> Mac that you own or administer.

## Important limits

- This tool does not provide guaranteed secure erase. APFS, SSD wear
  levelling, snapshots, backups, and external copies can retain old data.
- `sudo` does not grant Full Disk Access. Add the terminal or invoking program
  under **System Settings > Privacy & Security > Full Disk Access**.
- System Integrity Protection can block some system locations.
- macOS services can recreate caches, indexes, and databases after cleanup.
- Close browsers before the `browser` module. The script skips active browser
  databases to avoid corruption. A real run with skipped browser data exits `2`.
- Firefox history cleanup preserves bookmarks and keywords in `places.sqlite`.
  If SQLite is unavailable or cleanup fails, the database is retained and the
  run reports a failure.

## Quick start

```sh
chmod +x shredder.sh

# Inspect the available modules.
./shredder.sh --list

# Preview all operations. This does not require root.
./shredder.sh --dry-run --debug

# Run selected modules after you inspect the preview.
sudo ./shredder.sh --modules shell,browser,trash --force
```

Without `--modules`, the script runs every module. Without `--force`, a real
run asks for confirmation.

`--logfile FILE` creates a new log with mode `0600` after confirmation. Existing
files and symlink paths are refused. The parent directory must belong to the
caller and must not allow group or other users to write or have a macOS ACL.
With `sudo`, use a root-owned directory, such as `/var/log`.
Dry-run and `--list` do not create logs.

## Modules

| Module | Scope |
| --- | --- |
| `shell` | Shell and REPL histories |
| `systemlogs` | Legacy system logs and diagnostic reports |
| `audit` | Existing BSM audit trail files; BSM is legacy on current macOS |
| `browser` | Safari, Chrome-family, and Firefox histories and caches |
| `unified` | Apple unified logging store |
| `fileevents` | Quarantine databases and FSEvents stores |
| `usage` | Per-user KnowledgeC, recent items, and Notification Center data |
| `spotlight` | Spotlight erase-and-rebuild operation |
| `quicklook` | Per-user Quick Look caches |
| `trash` | Per-user Trash contents, including hidden files |
| `dsstore` | `.DS_Store` files in user homes |
| `wifi` | Remembered Wi-Fi preference files and Wi-Fi logs |
| `brew` | Homebrew caches and logs |
| `apps` | Selected editor caches, logs, and saved terminal states |
| `ai` | Local Claude Code, Codex, and OpenCode sessions and related records |

Mounted volumes are excluded by default. Use `--include-volumes` to include
their FSEvents and `.DS_Store` data. Use `--purge-snapshots` only when you also
want to delete local Time Machine snapshots.

## AI sessions

The `ai` module is included when you run all modules. It operates on each
eligible user home. Close Claude Code, Codex, OpenCode, their desktop apps,
and their background servers before a real run. The module refuses cleanup
if it detects a running agent or cannot inspect processes. It does not stop
processes for you. Keep the apps closed until cleanup finishes.

```sh
# Preview local session cleanup. This also works while an agent is open.
./shredder.sh --modules ai --dry-run --debug

# After you close the agents, remove local sessions.
sudo ./shredder.sh --modules ai --force

# Also remove the supported memory, plan, and generated-artifact stores.
sudo ./shredder.sh --modules ai --ai-derived --force
```

Session cleanup covers:

| Agent | Removed data |
| --- | --- |
| Claude Code | Project transcripts, superseded transcripts, subagent transcripts, tool results, session indexes, prompt history, file checkpoints, pasted content, images, uploads, session environment, shell snapshots, task/team/session records, background jobs, debug logs, feedback bundles, and usage cache |
| Codex | Sessions and archives, input history, session index, shell snapshots, attachments, dictation history, logs, known SQLite session/history/goal/queue tables, desktop session catalogs, automation run history, and session fields in desktop state JSON and its backups |
| OpenCode | Legacy JSON sessions/messages/parts, SQLite v1 and v2 sessions/messages, tool parts, instruction payloads, attachment blobs, session events, jobs, session schedules, snapshots, tool output, logs, and prompt history |

Claude scratchpads and images under `/private/tmp/claude-<uid>` are included.
The cleaner enters this directory as the home owner and checks its physical
path and ownership before deletion. Claude JSON preferences and their known
backups retain configuration but lose `history` and `lastSessionId` fields.

`--ai-derived` also removes Claude project/subagent memory and plans, plus
Codex memory stores and databases, memory archives (`memories*.tgz` and
`memories*.tar.gz`), plans, artifacts, generated images, and visualizations.
Without this flag, those stores remain and can contain information from
deleted conversations.

Configuration, credentials, Keychain entries, skills, hooks, plugins,
project settings, permissions, standalone automations/schedules, source
repositories, and worktrees are preserved. An automation that targets a
deleted chat can need manual reconfiguration. The module does not delete
cloud chats, published sessions, remote workspaces, external backups, or
arbitrary exported files. Other agents and third-party plugin stores are not
covered. This is local cleanup, not guaranteed secure erase.

### Custom locations

Default roots are `~/.claude`, `~/.codex`, `~/.local/share/opencode`, and
`~/.local/state/opencode`. Real runs also read `CLAUDE_CONFIG_DIR`,
`CODEX_HOME`, `CODEX_SQLITE_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
`OPENCODE_DB`, and `CLAUDE_CODE_TMPDIR` from the invoking environment.
`sudo` can remove these variables. Shell startup files and agent configuration
files are not executed or parsed to find overrides. For settings stored there,
or for another user's custom locations, pass explicit roots:

```sh
sudo ./shredder.sh --modules ai --force \
  --ai-root 'claude=/Users/alice/Agent Data/claude' \
  --ai-root 'codex=/Users/alice/Agent Data/code' \
  --ai-root 'codex-db=/Users/alice/Agent Data/databases' \
  --ai-root 'opencode=/Users/alice/Agent Data/opencode' \
  --ai-root 'opencode-state=/Users/alice/Agent State/opencode' \
  --ai-root 'opencode-db=/Users/alice/Agent Data/custom.db'
```

Roots are additive: default locations are still cleaned. `opencode-db` names
a database file; the other kinds name directories. `claude-temp` names a
dedicated scratchpad directory whose entire contents can be removed. Explicit
roots must be normalized absolute paths below an eligible `/Users/<user>/`
home, without symlink parents. Storage outside that boundary is refused;
do not work around this check with a symlink. `CLAUDE_CODE_TMPDIR` can also
name a macOS temporary directory; the cleaner appends `claude-<uid>`.
In tests, explicit `/Users/...` paths are mapped below `SHREDDER_ROOT`, and
host environment overrides are ignored.

### Database safety and result

AI cleanup requires `sqlite3` when a database or mixed JSON state file exists.
Known session tables are cleared in transactions; settings and credential
tables remain. The cleaner checks table names, rejects triggers and unknown
schemas, then compacts the database and checkpoints its WAL. It never removes
a mixed database as a fallback. Linked databases and sidecars are refused.
Orphan sidecars are retained for recovery and reported as incomplete cleanup.

An unsupported schema, busy database, unsafe path, or failed operation produces
exit `2`. Cleanup is not atomic across all files and databases: other roots
can already have been cleaned. Fix the reported cause and run the module again.
Dry-run does not open SQLite files, because even a read-only connection can
create WAL sidecars; schema checks run only during real cleanup.

Storage references: [Claude Code application data](https://code.claude.com/docs/en/claude-directory),
[Codex session locations](https://learn.chatgpt.com/docs/reference/troubleshooting),
and [OpenCode storage](https://opencode.ai/docs/troubleshooting/).

## Result contract

- Exit `0`: success, or a completed dry-run.
- Exit `2`: one or more requested operations failed or were refused.
- Exit `64`: invalid command-line input.
- Exit `1`: initialization or environment failure.
- Exit `130`: interrupted by the user.

The summary counts only operations that succeeded or would run. Unsafe paths
with user-controlled symlink parents are refused. A final symlink can be
removed without following its target. Filesystem and SQLite
mutations inside each home run with that home's owner privileges, not as root.
The same rule applies to per-user caches under `/private/var/folders`.
Cache deletion checks the physical parent path and uses a relative target from
that directory. Root-owned user directories are refused.

## Tests

The integration suite redirects every target into a marked temporary sandbox.
It verifies exact module parsing, forced cleanup, dry-run byte stability,
spaces in home paths, symlink escape protection, and sandbox isolation.

```sh
./tests/run-tests.sh
```

`SHREDDER_ROOT` is an internal test interface. The target must be an absolute,
non-symlink directory that contains `.macos-shredder-test-root`; unmarked
directories are rejected.

## License

This project uses the [MIT License](LICENSE).
