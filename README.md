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
| `shell` | Shell and REPL histories, Atuin history, and directory jump stores |
| `systemlogs` | Legacy system logs and diagnostic reports |
| `audit` | Existing BSM audit trail files; BSM is legacy on current macOS |
| `browser` | Safari, Chrome-family, and Firefox histories and caches |
| `unified` | Apple unified logging store |
| `fileevents` | Quarantine databases and FSEvents stores |
| `usage` | Per-user KnowledgeC, recent items, and Notification Center data |
| `spotlight` | Spotlight erase-and-rebuild operation |
| `quicklook` | Per-user Quick Look caches |
| `trash` | Per-user Trash contents, including hidden files; mounted-volume Trash with `--include-volumes` |
| `dsstore` | `.DS_Store` files in user homes |
| `wifi` | Remembered Wi-Fi preference files and Wi-Fi logs |
| `brew` | Homebrew caches and logs |
| `apps` | Selected editor caches, logs, and saved terminal states |
| `editors` | VS Code-family and JetBrains local history; Vim/Neovim persistent history |
| `ai` | Local sessions for Claude Code, Codex, OpenCode, Cursor, Windsurf, Continue, Cline/Roo, and Aider |

Mounted volumes are excluded by default. Use `--include-volumes` to include
their FSEvents, `.DS_Store` data, and per-user Trash. Use `--purge-snapshots` only when you also
want to delete local Time Machine snapshots.

For external Trash only, use `--modules trash --include-volumes`. The script
empties `/Volumes/<mount>/.Trashes/<uid>` for each eligible local user. It
preserves the Trash directory, other UID directories, and files outside Trash.
It skips mount aliases and ordinary directories under `/Volumes`. It refuses
linked Trash paths and owner mismatches, and runs deletion as the home owner
without crossing nested mounts. Read-only volumes and permission failures
produce exit code 2. Volumes with ownership disabled can fail the owner check;
the script does not change mount permissions. Disconnected volumes, custom
mount points, and Trash for users without an eligible local home are outside
this scope. The per-UID layout is also used by the
[macOS trash utility](https://github.com/morgant/tools-osx/blob/master/src/trash).

## Shell history stores

The `shell` module also clears these default locations in each eligible home:

| Client | Local data cleared |
| --- | --- |
| Atuin | `~/.local/share/atuin/{history,records}.db` and `~/.atuin/data/{history,records}.db`: history rows, events, encrypted history records, and version `001` history pack manifests |
| fish | `*_history` files in `~/.local/share/fish` and the legacy `~/.config/fish` directory |
| Nushell | `history.txt` and history rows in `history.sqlite3`, under `~/Library/Application Support/nushell` and `~/.config/nushell` |
| Xonsh | `xonsh-*.json` under `~/.local/share/xonsh` and its `history_json` directory; history rows in `xonsh-history.sqlite` |
| zsh-histdb | History, command, and directory rows in `~/.histdb/zsh-history.db` |
| zoxide, z, fasd | `db.zo` and `db.txt` under the macOS and XDG default zoxide directories; `~/.z` and `~/.fasd` |
| IPython | `history.sqlite` and sidecars in every `~/.ipython/profile_*` directory |

Close Atuin, including its daemon, fish, Nushell, Xonsh, and IPython first.
A real run skips these additional stores and exits `2` if any of these clients
is running or the process check fails. The script does not stop them. Run it
from a separate Bash or Zsh process with history recording disabled. Other
open shells can write their in-memory history back after cleanup.

Atuin keys, session tokens, host IDs, configuration, aliases, KV entries, and
scripts are preserved. SQLite history cleanup checks the schema and refuses
unknown tables, triggers, unsupported pack manifest formats, or linked database
files. Both Atuin databases are checked before their history is cleared.
Shell configuration files, fish universal variables, and IPython startup files
are preserved.

This is local cleanup. It does not remove history from an Atuin sync server or
other devices. Sync can download the history again. Custom database paths,
custom XDG roots, third-party history backends, captured Atuin command output,
and Atuin AI stores are outside this module's scope. The script does not read
or execute shell startup files to infer custom paths.

Storage references: [Atuin paths](https://github.com/atuinsh/atuin/blob/main/crates/atuin-common/src/dirs.rs),
[Atuin record schema](https://github.com/atuinsh/atuin/blob/main/crates/atuin-client/record-migrations/20231127090831_create-store.sql),
[Atuin pack manifests](https://github.com/atuinsh/atuin/blob/main/crates/atuin-client/src/packfile/record.rs),
[history file locations](https://docs.atuin.sh/main/reference/import/),
[Xonsh history](https://xon.sh/tutorial_hist.html), and
[zoxide storage](https://github.com/ajeetdsouza/zoxide/blob/main/src/db/mod.rs).

## Editor history

Run `--modules editors --dry-run --debug` to inspect the targets. Close VS Code,
VS Code Insiders, VSCodium, Cursor, Windsurf, JetBrains IDEs, Vim and Neovim
before a real run. The module refuses cleanup if a supported editor is running
or the process query fails. It does not stop processes. Keep editors closed
until cleanup finishes.

The module clears these standard locations in each eligible home:

| Editor | Removed history |
| --- | --- |
| VS Code, Insiders, VSCodium, Cursor, Windsurf and Windsurf Next | `Library/Application Support/<app>/User/History`, shared by editor profiles |
| JetBrains IDEs | `Library/Caches/JetBrains/<product><version>/LocalHistory` |
| Vim | `.viminfo` |
| Neovim | `.local/state/nvim/shada` and the legacy `.local/share/nvim/shada` |

Settings, credentials, extensions, project files, Git history, unsaved editor
`Backups`, swap files and persistent undo files remain. Vim/Neovim history
cleanup also removes stored marks, registers and recent-file lists.
Custom user-data directories, custom `idea.system.path`, `NVIM_APPNAME`, XDG or
ShaDa path overrides, remote editor stores and third-party history extensions
are outside this module's scope. Recent-file and search records in mixed editor
settings databases are also retained.

Storage references: [VS Code local-history path](https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts),
[JetBrains Local History](https://www.jetbrains.com/help/idea/local-history.html),
[Neovim ShaDa](https://neovim.io/doc/user/starting.html#shada-file-name).

## AI sessions

The `ai` module is included when you run all modules. It operates on each
eligible user home. Close the supported agents, their desktop apps, VS Code,
Cursor, Windsurf, JetBrains IDEs, and background servers before a real run.
The module refuses cleanup
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
| Cursor | CLI chat stores, project agent transcripts, known chat rows in `ItemTable` and `cursorDiskKV`, and `composerHeaders`; includes workspace stores, named profiles, and `state.vscdb.backup` |
| Windsurf | UUID-named conversation `.pb` files in `~/.codeium/windsurf/cascade`; other files in that directory remain |
| Continue | The `~/.continue/sessions` store, including its session index, used by the extension and CLI |
| Cline / Roo Code | Extension task folders and checkpoints; only `taskHistory` is removed from mixed state records. Cline's file-backed `~/.cline/data` tasks, sessions, session database, history index, and logs are also included |
| Aider | `.aider.chat.history.md`, `.aider.input.history`, and `.aider.llm.history` found below user homes; custom history files can be selected explicitly |

Extension storage is checked in VS Code, Code - Insiders, VSCodium, Cursor,
Windsurf, and Windsurf - Next. Both default and named profiles are included.
Only the Cline and Roo history fields are changed in ordinary editor databases.
Cursor chat rows are cleared only in Cursor stores. Secret-storage rows,
authentication tokens, unrelated extension state, model/provider settings,
approval settings, editor preferences, keybindings, and workspace files remain.
Malformed extension JSON or an unknown database schema produces exit `2`.
Unrecognized `state.vscdb` recovery copies are retained and reported.

Aider discovery does not follow directory symlinks or cross filesystems. It
prunes `.git`, `node_modules`, `.venv`, `Library`, `.Trash`, `.cache`, `.local`,
`.config`, and the supported agents' hidden data roots. It does not remove
`.env`, `.aider.conf.yml`, source files, or Git history. Use an explicit root
for a project outside the automatic scan, or `aider-history` for a custom file.

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
`OPENCODE_DB`, `CLAUDE_CODE_TMPDIR`, `CONTINUE_GLOBAL_DIR`, `CLINE_DATA_DIR`,
`CLINE_DIR`, `AIDER_CHAT_HISTORY_FILE`, `AIDER_INPUT_HISTORY_FILE`, and
`AIDER_LLM_HISTORY_FILE` from the invoking environment. Relative Aider history
overrides are resolved against the invocation directory.
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

Additional root kinds use these paths:

| Kind | Directory or file to pass |
| --- | --- |
| `cursor` | Cursor CLI/project data root, normally `~/.cursor` |
| `cursor-editor` | Cursor's `User` directory, normally `~/Library/Application Support/Cursor/User` |
| `editor` | Another supported editor's `User` directory; cleans Cline/Roo extension history |
| `windsurf` | Windsurf data root containing `cascade`, normally `~/.codeium/windsurf` |
| `continue` | Continue data root containing `sessions`, normally `~/.continue` |
| `cline` | Cline data root, normally `~/.cline/data`, or an extension storage directory |
| `roo` | Roo extension storage directory; use this for `roo-cline.customStoragePath` |
| `aider` | A project directory to scan for the three standard history filenames |
| `aider-history` | One custom history file; directories are refused |

Roots are additive: default locations are still cleaned. `opencode-db` and
`aider-history` name files; the other kinds name directories. `claude-temp` names a
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
Editor references: [Cursor local transcripts](https://forum.cursor.com/t/cant-access-chat-history-since-latest-update/158688/8),
[Cursor database records](https://forum.cursor.com/t/state-vscdb-grows-to-30gb-due-to-bubbleid-agentkv-entries/167641/7),
[Windsurf Cascade storage](https://docs.devin.ai/desktop/troubleshooting/windsurf-common-issues),
[Continue history](https://github.com/continuedev/continue/blob/main/core/util/history.ts),
[Cline storage](https://github.com/cline/cline/blob/main/apps/vscode/src/core/storage/disk.ts),
[Roo task history](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/task-persistence/TaskHistoryStore.ts),
and [Aider history options](https://aider.chat/docs/config/options.html#history-files).

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
