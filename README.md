# macOS Shredder

`macos-shredder` is a macOS-only cleanup script for shell and editor histories,
local AI sessions, browser site data and tab recovery, logs, activity databases,
caches, and Trash. Explicit options also cover clipboard history, local Slack
exports, terminal output, Finder history, selected file-origin metadata,
document versions, learned words, diagnostic exports, device backups, Xcode
test results, and Apple Intelligence reports. Modules marked manual only print
instructions; they do not perform the app actions.

> Warning: this program deletes data. Run a dry-run first. Use it only on a
> Mac that you own or administer.

## Contents

- [Quick start and options](#quick-start)
- [Modules and system cleanup](#modules)
- [Additional cleanup scopes](#additional-cleanup-scopes)
- [Browser site data and tab recovery](#browser-site-data-and-tab-recovery)
- [Shell history stores](#shell-history-stores)
- [Editor history](#editor-history)
- [AI sessions and custom locations](#ai-sessions)
- [Results and incomplete cleanup](#results-and-incomplete-cleanup)
- [Tests](#tests)

## Important limits

- This tool does not provide guaranteed secure erase. APFS, SSD wear
  levelling, snapshots, backups, and external copies can retain old data.
- `sudo` does not grant Full Disk Access. Add the terminal or invoking program
  under **System Settings > Privacy & Security > Full Disk Access**.
- System Integrity Protection can block some system locations.
- macOS services can recreate caches, indexes, and databases after cleanup.
- Close browsers and their background processes before the `browser` module.
  The script skips active browser site and session data to avoid corruption.
  A real run with skipped browser data exits `2`. Keep browsers closed until
  cleanup finishes. The `ai`, `editors`, and extended `shell` stores also have
  process checks; their sections below list the clients to close.
- Firefox history cleanup preserves bookmarks and keywords in `places.sqlite`.
  If SQLite is unavailable or cleanup fails, the database is retained and the
  run reports a failure.

## Quick start

```sh
chmod +x shredder.sh

# Inspect the available modules.
./shredder.sh --list

# Preview the standard modules. This does not require root.
./shredder.sh --dry-run --debug

# Run selected modules after you inspect the preview.
sudo ./shredder.sh --modules shell,browser,trash --force
```

There are 38 module IDs: 16 standard modules and 22 that require explicit
selection. Without `--modules`, the script runs the standard modules, including
`ai` and `editors`. Supplying `--modules` replaces that standard selection.
There is no `all` module ID. Modules run in registry order, shown in the table
below, regardless of the order in `--modules`. Without `--force`, a real run
asks for confirmation. `--force` only skips that prompt; it does not bypass process, path, or database checks.

Real cleanup requires macOS, Bash 3.2 or later, root privileges, and access to
the selected files. Mixed database and JSON cleanup requires `sqlite3` with
JSON support. The script uses the system command paths during a real run;
installing a different SQLite on the caller's `PATH` does not replace the
system binary. Dry-run does not require root, but limited read access can
prevent it from discovering all targets. `--help`, `--version`, and `--list`
are available without a cleanup run.

Store-specific operations also use native macOS tools: `defaults` and `plutil`
for Finder preferences, `xattr` for file metadata, `osascript` with CoreServices
for FSEvents, Foundation for document versions, AppKit for learned words,
`xcresulttool` for Xcode results, and `lsof` for open-file checks. No compiler or Python runtime is
required for cleanup. Missing required tools can produce exit `2`; the script
does not install them.

Per-user modules process eligible homes under `/Users`, not just the invoking
user's home. Linked homes are excluded. Directory Services supplies users on
macOS; the fallback directory scan also excludes `Shared`, `Guest`, and hidden
home directories. There is no single-user selection option.

### Options

| Option | Effect |
| --- | --- |
| `-h`, `--help` | Show command-line help |
| `-v`, `--version` | Show the script version |
| `-l`, `--list` | List the module IDs and descriptions |
| `-m`, `--modules IDS` | Select comma-separated module IDs; omitted means the 16 standard modules |
| `-n`, `--dry-run` | Preview without changing cleanup targets |
| `-d`, `--debug` | Show detailed operations and skipped paths |
| `-f`, `--force` | Skip the cleanup confirmation prompt |
| `--module-timeout N` | Limit each module and snapshot-purge step to N seconds; default 3600 |
| `--timeout-grace N` | Allow N seconds after timeout SIGTERM before SIGKILL; default 30 |
| `--include-volumes` | Include mounted-volume targets in the selected `trash`, `fsevents`, and `dsstore` modules |
| `--include-extension-data` | Allow `browser` to remove shared website/extension storage; this can reset extension settings and sign-ins |
| `--logs-older-than N` | Remove eligible closed legacy rotations, diagnostic reports, and BSM trails older than N days; requires `systemlogs` or `audit` and rejects `unified` |
| `--purge-snapshots` | Delete local Time Machine snapshots before the selected modules run |
| `--ai-derived` | Include supported memory, plans, and generated artifacts in `ai` cleanup |
| `--ai-extended` | Include supported Gemini, Antigravity, desktop AI, context-mode, and Serena traces in `ai` cleanup |
| `--terminal-log-file PATH` | Select one terminal log file; repeatable and requires `--modules terminal` |
| `--terminal-sessions` | Include known cmux session and journal files in `shell` cleanup |
| `--clipboard-include-pinned` | Include pinned Maccy items in `clipboard` cleanup |
| `--clipboard-current` | Also clear the verified active GUI user's current clipboard |
| `--headless-days N` | Keep Chrome Headless profiles with changes in the last N days; default 7, range 1–99999 |
| `--slack-export-root PATH` | Select a local Slack export directory; repeatable and required with `--modules slackexport` |
| `--spelling-word WORD` | Unlearn one selected word in the active GUI account; repeatable, requires `spelling` |
| `--version-file PATH` | Select one local document for previous-version removal; repeatable, requires `documentversions` |
| `--metadata-file PATH` | Select one file for origin metadata cleanup; repeatable, requires `filemetadata` |
| `--diagnostic-export PATH` | Select a completed diagnostic export; repeatable, requires `diagnosticexports` |
| `--device-backup PATH` | Select a completed unencrypted MobileSync backup; repeatable, requires `devicebackups` |
| `--test-result PATH` | Select an Xcode test result bundle; repeatable, requires `testresults` |
| `--ai-export PATH` | Select an Apple Intelligence report; repeatable, requires `aiexports` |
| `--ai-root KIND=PATH` | Add a custom AI storage location; repeat for multiple roots |

Module-specific flags do not select their module. For example, use
`--modules shell --terminal-sessions` or `--modules clipboard --clipboard-current`.
`slackexport`, `filemetadata`, `documentversions`, `diagnosticexports`,
`devicebackups`, `testresults`, and `aiexports` require at least one explicit
path. `spelling` requires at least one `--spelling-word`. Their options, and
`--terminal-log-file`, are rejected unless the matching module is selected.
Quote paths that contain spaces. The examples use placeholder `/Users/alice/...`
paths; replace them with actual targets.
Age arguments accept integers from 1 through 99999, without leading zeroes.
Timeout arguments use the same integer range and cannot be disabled with `0`.
For a longer cleanup, use `--module-timeout 7200 --timeout-grace 60`.

The scope-expansion flags are off by default. `--ai-root` is additive;
it does not restrict cleanup to the supplied path. `--purge-snapshots` runs
independently of module selection. See the sections below before enabling
these options.

The script does not create an operation log. Progress, debug details, errors,
and the summary use only standard output and standard error. `--logfile` is
not supported and is rejected before cleanup. The script does not remove
logs from earlier runs unless they are covered by the selected cleanup modules.
The caller can still redirect output to a file. macOS, `sudo`, terminal session
recording, and shell history can independently retain records of a run.

## Modules

| Module | Selection | Scope |
| --- | --- | --- |
| `shell` | Standard | Shell and REPL histories, Atuin history, and directory jump stores |
| `systemlogs` | Standard | Legacy system logs and diagnostic reports |
| `audit` | Standard | Existing BSM audit trail files; BSM is legacy on current macOS |
| `browser` | Standard | Safari, Chrome-family, and Firefox histories, site data, tab recovery, and caches |
| `unified` | Standard | Apple unified logging store |
| `fileevents` | Standard | Quarantine download event databases |
| `fsevents` | Explicit | Per-volume FSEvents history through CoreServices |
| `usage` | Standard | Known KnowledgeC event tables and recent items |
| `spotlight` | Standard | Spotlight erase-and-rebuild operation |
| `quicklook` | Standard | Per-user Quick Look caches |
| `trash` | Standard | Per-user Trash contents, including hidden files; mounted-volume Trash with `--include-volumes` |
| `dsstore` | Standard | `.DS_Store` files in user homes |
| `wifi` | Standard | Remembered Wi-Fi preference files and Wi-Fi logs |
| `brew` | Standard | Homebrew caches and logs |
| `apps` | Standard | Selected editor caches and logs |
| `editors` | Standard | VS Code-family and JetBrains local history; Vim/Neovim persistent history |
| `ai` | Standard | Local sessions for Claude Code, Codex, OpenCode, Cursor, Windsurf, Continue, Cline/Roo, and Aider |
| `clipboard` | Explicit | Known Maccy clipboard history |
| `headless` | Explicit | Old, unlocked Chrome Headless temporary profiles |
| `slackexport` | Explicit | Known data in explicitly selected local Slack exports |
| `terminal` | Explicit | Terminal/iTerm2 saved output and explicitly selected session logs |
| `finderhistory` | Explicit | Known Finder and Open/Save history keys |
| `filemetadata` | Explicit | Origin metadata on explicitly selected files |
| `documentversions` | Explicit | Previous versions of selected local documents; current file stays |
| `spelling` | Explicit | Selected learned words in the active GUI account |
| `notifications` | Explicit | Known delivered Notification Center history |
| `activity` | Explicit | Known KnowledgeC and IntelligencePlatform event/feedback tables; reports unsupported stores |
| `siri` | Explicit; manual | Manual Siri/Dictation deletion instructions; real runs report incomplete |
| `diagnosticexports` | Explicit paths | Completed selected sysdiagnose archives and native-validated log archives |
| `devicebackups` | Explicit paths | Completed selected unencrypted MobileSync backups with validated manifests |
| `testresults` | Explicit paths | Selected Xcode result bundles validated by installed xcresulttool |
| `aiexports` | Explicit paths | Selected Apple Intelligence report JSON with documented array structure |
| `mailhistory` | Explicit; manual | Mail recipients and attachments; instructions only, real runs report incomplete |
| `locationhistory` | Explicit; manual | Maps searches and significant locations; instructions only, real runs report incomplete |
| `callhistory` | Explicit; manual | Phone and FaceTime call history; instructions only, real runs report incomplete |
| `messagehistory` | Explicit; manual | Messages and recently deleted attachments; instructions only, real runs report incomplete |
| `photometadata` | Explicit; manual | Photo location metadata; instructions only, real runs report incomplete |
| `alfred` | Explicit; manual | Alfred clipboard instructions; real runs report incomplete |

Mounted volumes are excluded by default. Use `--include-volumes` to include
their FSEvents, `.DS_Store` data, and per-user Trash in the corresponding
selected modules. Use `--purge-snapshots` only when you also want to delete
local Time Machine snapshots.

### Standard system cleanup

A standard run includes broad system operations. Select only the modules you
need after you inspect their preview:

- `systemlogs` without an age filter truncates the known current legacy logs
  and `fsck*` files, removes numbered rotations, and clears the selected
  launchd, power-management, and diagnostic-report directories.
- `audit` without an age filter can rotate an enabled BSM audit trail before
  removing timestamped files. It retains the current trail target.
- `unified` requests `log erase --all`. It does not stop future logging.
- `fileevents` clears quarantine event records and can restart `lsd` before
  database cleanup. This does not remove quarantine attributes from files.
- `usage` clears supported KnowledgeC event tables, the recent-items domain,
  top-level `*Recent*.sfl*` lists, and known per-application recent-document
  lists. KnowledgeC uses the same offline-store checks as `activity`.
- `spotlight` requests an index erase and rebuild. `quicklook` resets user
  preview caches and removes known thumbnail-cache contents. Both kinds of
  data can be created again.
- `wifi` removes known network preference files and Wi-Fi logs. This can
  affect remembered networks. `brew` clears Homebrew caches and logs; `apps`
  clears selected VS Code caches/logs and JetBrains logs.
- `trash` empties user Trash. `dsstore` removes `.DS_Store` files found under
  eligible homes. Mounted volumes require `--include-volumes`.

### Log retention and FSEvents

```sh
./shredder.sh --modules systemlogs,audit --logs-older-than 30 --dry-run --debug
./shredder.sh --modules fsevents --dry-run --debug
./shredder.sh --modules fsevents --include-volumes --dry-run --debug
```

`--logs-older-than N` accepts 1 through 99999 days. It uses file modification
time, with an exact N × 24-hour cutoff. It removes numeric rotations of the
known legacy system logs and recognized diagnostic report files, including
per-user reports. It retains current logs, unknown files, incomplete audit
trails, the audit `current` target, and files with open handles. An inconclusive
handle check retains the file and reports failure. Age mode does not rotate
or restart audit logging. Close affected applications during cleanup: an
open-handle check cannot prevent a process from opening a file immediately
after the check. These rules apply only to `systemlogs` and `audit`; other
selected modules retain their normal behavior.

Unified logging has no supported age cutoff for `log erase`. Its `--ttl`
option selects the time-to-live store; it is not a retention period. Selecting
`unified` together with `--logs-older-than` fails before any cleanup. Without
an age option, existing `systemlogs`, `audit`, and `unified` behavior remains
unchanged, including their membership in the standard module set.

`fileevents` now clears only quarantine event databases. FSEvents requires
explicit `--modules fsevents`, even without `--include-volumes`. The startup
store is on `/System/Volumes/Data`. Extra volumes must be mounted directly
under `/Volumes`, use APFS or HFS, be writable, and have ownership enabled.
Mount aliases, the startup device under another path, unmounted directories,
and unsupported volumes are refused or skipped. The script calls Apple's
`FSEventsPurgeEventsForDeviceUpToEventId` through the built-in JXA bridge; it
does not delete the live `.fseventsd` files or change security settings. API
failure is reported without a raw-file fallback. Successful API acceptance
does not prove removal of every physical copy; new events can appear at once,
and backup/index clients can need a full rescan. See the installed macOS
`FSEvents.h` API contract and `man log` for the native operation boundaries.

`--purge-snapshots` enumerates local Time Machine snapshots and asks `diskutil`
to delete each recognized snapshot from the Data volume
(`/System/Volumes/Data`), where Time Machine stores them. If `diskutil` is
unavailable, it requests aggressive thinning through `tmutil`. This fallback
is a request to reclaim space, not confirmation that every snapshot was removed. The flag does not
delete Time Machine backup sets on external/network destinations, APFS
snapshots from other tools, or cloud backup history.

### Mounted-volume Trash

```sh
./shredder.sh --modules trash --include-volumes --dry-run --debug
sudo ./shredder.sh --modules trash --include-volumes --force
```

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

## Additional cleanup scopes

These examples only preview operations:

```sh
./shredder.sh --modules clipboard --dry-run --debug
./shredder.sh --modules shell --terminal-sessions --dry-run --debug
./shredder.sh --modules ai --ai-extended --dry-run --debug
./shredder.sh --modules headless --headless-days 7 --dry-run --debug
./shredder.sh --modules slackexport --slack-export-root /Users/alice/slack_dump --dry-run --debug
```

See also [terminal output](#terminal-saved-output-and-log-files),
[Finder history](#finder-and-opensave-history),
[file-origin metadata](#selected-file-origin-metadata),
[notification/activity stores](#notification-and-activity-history), and
[Siri instructions](#siri-and-dictation).

### Print history: automatic cleanup is not supported

The script does not remove CUPS job history or spool files. Apple's
[CUPS scheduler](https://github.com/apple/cups/blob/master/scheduler/ipp.c)
can purge a completed job with `Cancel-Job` and `purge-job=true`, but the same
operation also cancels an active job. It has no required-state precondition.
`Purge-Jobs` has the same limitation. A prior completed-state check is not
sufficient: [CUPS can restart a completed job](https://apple.github.io/cups/doc/man-lp.html)
between that check and the purge request while its document is retained.

Automatic cleanup therefore cannot guarantee that pending or active jobs remain
intact. The script does not use bulk cancellation, remove `/var/spool/cups`, or
change scheduler permissions or retention settings. History in printer hardware
and remote print servers is also outside its scope. This is an unsupported
cleanup target, not a completed cleanup operation.

### Alfred clipboard history

`alfred` prints the supported manual action: open Alfred, type `clear`, and
select **Clear Alfred's entire clipboard history**. This action rebuilds
`clipboard.db` and preserves saved Snippets, as documented in
[Alfred's clipboard troubleshooting guide](https://www.alfredapp.com/help/troubleshooting/clipboard-history/).
The script does not assume an undocumented database schema or delete application
directories. Preferences, workflows, credentials and the current system clipboard
remain unchanged. Run `./shredder.sh --modules alfred --dry-run` to read the
instructions. A real run reports exit `2` and zero cleaned items because a user
must complete the action in Alfred. A dry-run reports exit `0`. This module is
separate from Maccy cleanup and `--clipboard-current`.

### Maccy clipboard history

`clipboard` clears known history rows in Maccy's `Storage.sqlite`, both in
the application container and in the older Application Support location.
It preserves pinned items, preferences, and model metadata. Use
`--clipboard-include-pinned` to include pinned items. Close Maccy first.
Unknown schemas, external binary-object stores, linked databases, and busy
databases are retained and reported. Cleanup also clears related content and
SwiftData transaction history, then compacts SQLite and checkpoints its WAL.

`--clipboard-current` separately clears the current pasteboard of the verified
active console user. It requires that user's GUI session. It does not clear
other users' pasteboards or fall back to a root pasteboard. Failure to find or
enter that GUI session produces exit `2`. This native action is not executed
by the sandbox tests.

Schema references: [Maccy storage](https://github.com/p0deje/Maccy/blob/master/Maccy/Storage.swift),
[history items](https://github.com/p0deje/Maccy/blob/master/Maccy/Models/HistoryItem.swift),
and [history content](https://github.com/p0deje/Maccy/blob/master/Maccy/Models/HistoryItemContent.swift).

### cmux sessions and per-application recent documents

`shell --terminal-sessions` clears the contents of the known `terminal-history`,
`session-history`, and `session-com.cmuxterm.app-scrollback` directories under
cmux Application Support. It also removes `workstream.jsonl`, `events.jsonl`,
`events.jsonl.1`, and `agent-journal-dead-letter.jsonl` from `~/.cmuxterm`.
Settings, CLI shims, credentials, and mixed cmux databases remain. Close cmux
and its background processes first; a failed process query blocks this scope.

`usage` also clears `.sfl2`, `.sfl3`, and `.sfl4` files immediately within
`com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments`.
Within that per-application directory, favorites, unknown formats, and nested
directories remain. The top-level recent-list pattern is broader, as described
in [standard system cleanup](#standard-system-cleanup).

### Extended local AI traces

`ai --ai-extended` adds the following known stores. The regular `ai` scope
still runs. Close Gemini, Antigravity, ChatGPT, Claude Desktop, Serena,
context-mode servers, and the clients required by the regular `ai` module.

- Gemini: project chats, checkpoints, and logs under `~/.gemini/tmp`.
  Its shadow Git history is included only with `--ai-derived`.
- Antigravity, Antigravity CLI, and Antigravity IDE: known conversation
  databases, indexes, UUID-named protobuf conversations, and session logs
  under their `~/.gemini` roots.
- ChatGPT desktop: local `conversations-v*` and `drafts-v*` stores.
- Claude Desktop: recognized local session entries and history fields in
  the supported local-agent-mode layout; virtual machines, runtime binaries,
  scheduled tasks, plugins, and settings remain.
- context-mode: known session and content database tables, plus session
  statistics. Serena: its dedicated log directory.

OAuth credentials, skills, project files, and application configuration
remain. Unknown SQLite schemas and database recovery copies in the checked
conversation/context-mode database directories are retained and reported.
These stores were checked against local schema metadata; future versions can
need new schema support. Cloud conversations and arbitrary exports are not
deleted. Antigravity derived stores (`brain`, `knowledge`, `implicit`, and
artifacts), backup roots, arbitrary database copies, and context-mode root
logs remain outside this scope, even with `--ai-derived`. They can retain
conversation data. See [Gemini session management](https://geminicli.com/docs/cli/session-management/).

### Notification and activity history

`notifications` clears delivered records and the delivered/displayed lists in
known Notification Center `db2/db` databases. It checks both the modern
`Library/Group Containers/group.com.apple.usernoted` location and legacy
`com.apple.notificationcenter` cache locations. Pending request records,
request lists, app registrations, notification categories, and database
settings remain. Unknown files, including corrupt database archives, remain
and cause exit `2`. The default `usage` module no longer removes entire
notification database directories.

`activity` clears known event tables in KnowledgeC and the `events`/`pre_events`
tables in `Library/IntelligencePlatform/eventLog.db`, plus `feedback`/`deferred`
in `feedbackLog.db`. Migration records remain. KnowledgeC cleanup also runs
in `usage`; it clears event objects, structured/custom metadata, event links,
sources, and histograms when present. It retains Core Data metadata, key/value
settings, contextual registrations, and sync state. Retained sync changesets
can contain older event data; this is not a full KnowledgeC or cloud-history
reset.

These operations require closed stores and stopped writer services. The script
checks process metadata and open database/sidecar files. Per-account agents
block only stores owned by their account; root-owned system stores, such as
the system KnowledgeC database, are blocked by a writer in any account. It
does not kill or restart services. Use an offline user session and keep services stopped until
the run finishes. Unknown tables, missing required columns, triggers, views,
linked files, active writers, and SQLite failures stop cleanup. SQLite handles
the transaction, compaction, and WAL checkpoint; there is no database-removal
fallback. An error after commit can mean some rows were cleared before
compaction or checkpoint failed. Dry-run does not open SQLite or validate its
schema.

Biome streams and IntelligencePlatform graph/behavior stores do not have a
verified selective reset in this script. If those stores are present,
`activity` retains them and reports exit `2`, even if known event logs were
cleared. Configuration, graph, model, and sync directories are never deleted
as a fallback. No supported global reset command was found in the macOS 27
utilities or the Apple documentation checked for this implementation. Native
`biomed(8)`, `BiomeAgent(8)`, and `intelligenceplatformd(8)` document services,
not reset commands; `usernoted(8)` explicitly has no options. The public
[notification removal API](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removealldeliverednotifications())
operates on the calling app's notifications only.

```sh
./shredder.sh --modules notifications,activity --dry-run --debug
```

### Siri and Dictation

`siri` gives the supported manual action and never claims automatic cleanup.
A real run returns exit `2` with zero items counted as cleaned by this module.
A dry-run prints the same instructions, counts no cleaned items, and normally
returns `0`. Use `./shredder.sh --modules siri --dry-run` to read the guidance.
Follow [Apple's Siri and Dictation history instructions](https://support.apple.com/en-bn/guide/mac-help/mchlf55961c0/mac):
open **System Settings > Apple Intelligence & Siri** (or **Siri**), select
**Delete Siri & Dictation History**, then confirm **Delete**. Internet access
is required. This does not change the audio-sharing preference.

On macOS 27, [Siri app conversations](https://support.apple.com/en-mide/guide/mac-help/q7ny3g54v9lk/mac)
are separate: Control-click a conversation and choose **Delete**, then confirm.
These conversations can sync between devices. No supported command-line API
was found for these actions. The module does not open settings, click buttons,
change sharing preferences, or remove Siri configuration files.

### Chrome Headless temporary profiles

`headless` checks only `Library/Application Support/Google/Chrome-headless`
inside each eligible home. A candidate must be named `scoped_dir` followed
by letters or digits and contain the known `Default` and `Local State` paths.
The profile and its descendants must have no modification times within
`--headless-days`. Age checks use `find -mtime` day intervals, not creation
time or dates inside browser records.
Profiles with a singleton lock or socket are retained and reported. Close
browsers and browser automation before cleanup and keep them closed until it
finishes. Failed process queries block cleanup. Symlink targets and nested
mount contents are not followed.

### Local Slack exports

`slackexport` requires one or more `--slack-export-root` paths. There is no
automatic home-directory scan and no default export root. Only normalized
directories below eligible `/Users/<user>/` homes are accepted. Home roots,
broad standard folders, linked paths, and unknown formats are refused.

The supported formats are unpacked Slack JSON exports and the Slackdump
archive workspace layout. Standard exports are selected by their metadata;
channel names are validated before any removal. Unrelated files and tools
remain. Slackdump cleanup includes the known archive database and sidecars,
downloaded uploads and avatars, matching database snapshots, and supported
top-level user/channel export files. The selected workspace uses
`archive/slackdump.sqlite`, optional `archive/__uploads` and
`archive/__avatars`, and `snapshots/slackdump_YYYYMMDD_HHMMSS.sqlite`.
SQLite `-wal`, `-shm`, and `-journal` sidecars are included. Top-level export
names are `users-T<workspace ID>.json` and `channels-T<workspace ID>.txt`.
It preserves scripts, programs, settings, locks, and monitoring tools. ZIP/TXT-only exports and arbitrary renamed copies
are outside this scope.

After a standard JSON export's metadata is removed, remaining empty channel
directories or unrelated files no longer identify a complete export. A repeat
run can therefore return `2` without changing those leftovers. Slackdump's
empty archive/media layout is retained for repeated cleanup.

Stop exporters and scheduled sync jobs before cleanup. The script refuses an
active exporter, a failed process query, or a `.lock` entry at the selected
root. A real run also requires `lsof` to confirm that archive databases and
their sidecars are not open. It does not stop jobs, remove locks, revoke credentials, or delete Slack cloud
data. A later export can recreate local data. As with other modules, failures
can leave a partially cleaned export; exit `2` reports incomplete cleanup.

Format references: [Slack JSON exports](https://slack.com/help/articles/220556107-How-to-read-Slack-data-exports)
and [Slackdump](https://github.com/rusq/slackdump).

### Terminal saved output and log files

Select `--modules terminal` to remove Apple Terminal and iTerm2 saved window
state, including iTerm2 `~/Library/Application Support/iTerm2/SavedState`.
This removes persisted scrollback and recovery state. Close Terminal, iTerm2
and their restoration servers first. The check applies to each account
separately: a client running in one account, or a failed process query,
blocks that account's writes only. Run the module from a different account
(for example over SSH) to clean the account you use. It does not terminate
sessions.

Session logs can be stored anywhere selected in the terminal profile. They
are not discovered automatically. Use repeatable `--terminal-log-file` paths
to select exact regular files below an eligible `/Users/<user>/` home.
Directories, links and files that are open are refused. Example:

```bash
./shredder.sh --modules terminal --terminal-log-file /Users/alice/logs/session.txt --dry-run --debug
```

Terminal preferences, profiles, iTerm2 arrangements, session archives, shell
history and unsaved documents are retained. Shell history and cmux history
have separate options. This module does not clear live scrollback or prove
that APFS snapshots, backups or external log copies have been erased.

The scope follows the [iTerm2 restoration implementation](https://github.com/gnachman/iTerm2/blob/master/sources/StateRestoration/iTermRestorableStateController.m),
[session restoration documentation](https://iterm2.com/documentation-restoration.html)
and [session logging settings](https://iterm2.com/documentation-preferences-profiles-session.html).

### Finder and Open/Save history

`--modules finderhistory` clears only these keys in
`~/Library/Preferences/com.apple.finder.plist`: `FXRecentFolders`,
`GoToFieldHistory`, `GoToField`, `FXConnectToLastURL`,
`RecentMoveAndCopyDestinations` and `RecentSearches`. It also clears
`NSNavRecentPlaces` in `.GlobalPreferences.plist` and in the
`com.apple.appkit.xpc.openAndSavePanelService.plist` preferences, including
the service container under `~/Library/Containers/`.

Quit Finder and close Open/Save dialogs before cleanup. A running Finder or
panel service in an account, or a failed process query, blocks writes for
that account. Accounts without these processes are still cleaned. The module does not
quit applications for you. Close other applications that may retain recent
places in memory; they can write history again later.

Only supported string or array values are removed with native macOS
`defaults delete <plist-path> <key>`. Unknown keys, favorites, desktop icon
positions, window settings and unsaved documents remain. A malformed plist,
unexpected history type, link or wrong owner blocks that file. The module
does not remove the whole preferences file or reset system preferences.
A dry-run lists candidate files without validating their contents.

Other application-specific Open/Save histories and renamed or future keys
are outside this allowlist. Use `usage` for shared recent-document lists.
These paths and key meanings are described in the
[JPCERT macOS forensics workshop, page 106](https://jsac.jpcert.or.jp/archive/2022/pdf/JSAC2022_workshop_macOS-forensic_en.pdf).
The Finder key names were also checked against the installed Finder executable.

### Selected file origin metadata

`filemetadata` requires one or more `--metadata-file /Users/<user>/path`
arguments. It clears only `com.apple.metadata:kMDItemWhereFroms`, which can
contain a download URL or sender information. It does not search directories
or delete file content. For example:

```sh
./shredder.sh --modules filemetadata --metadata-file /Users/alice/Downloads/report.pdf --dry-run --debug
```

The file must be a regular file in an eligible home. Linked paths, hard links,
directories and missing targets are refused. The module uses the home owner's
identity and the native `xattr` tool. It reads attribute names, not values.
Other attributes, including quarantine, Finder tags and comments, are retained.
Filesystem metadata change times can change when an attribute is removed.

This is not a universal copy-history reset. File contents, other copies,
Spotlight indexes and backups can still contain origin information. See Apple's
[`kMDItemWhereFroms` reference](https://developer.apple.com/documentation/coreservices/kmditemwherefroms)
and the native `xattr(1)` manual for the attribute and tool behavior.

### Selected diagnostic exports

`diagnosticexports` is opt-in and requires repeatable `--diagnostic-export PATH`.
Select exact paths below an eligible `/Users/<user>/` home. No home-wide search
runs. Completed `sysdiagnose_*.tar.gz` files must have a matching top directory,
`sysdiagnose.log`, and `system_logs.logarchive/Info.plist`. A selected `.logarchive`
bundle must pass the native `log stats --archive` check. Unknown or incomplete
formats, open targets, symlinks, hard-linked files and nested mounts are refused.
Close collectors and applications that use these exports before cleanup.
Loose CFNetwork logs and arbitrary diagnostic archives have no supported
format validator here; inspect and delete selected exports manually.

```bash
sudo ./shredder.sh --dry-run --modules diagnosticexports \
  --diagnostic-export /Users/alice/Downloads/sysdiagnose_DATE.tar.gz
```

Deletion removes the selected local export, including its embedded logs. It does
not remove copies sent to Apple, cloud copies or backups. Diagnostic exports can
contain sensitive data. See [Apple diagnostics guidance](https://developer.apple.com/feedback-assistant/)
and [Apple's log archive example](https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer).

### Selected device backups

`devicebackups --device-backup PATH` deletes one explicitly selected, completed,
unencrypted MobileSync backup. The path must identify a single device backup
under `/Users/<user>/Library/Application Support/MobileSync/Backup/`. Repeat the
option to select more backups. The identifier, required property lists, finished
snapshot state and SQLite `Files` manifest must match the supported format.
Active backup processes, database sidecars, unknown schemas, encrypted backups
and older backup formats are refused. Disconnect devices and close backup or
sync clients first. `--dry-run` performs read-only validation.

The supported layout uses these identity and completion fields:

| File | Required field or layout |
| --- | --- |
| `Info.plist` | `Target Identifier`: a string that matches the backup directory ID |
| `Manifest.plist` | `IsEncrypted`: Boolean `false` |
| `Status.plist` | `SnapshotState`: string `finished` |
| `Manifest.db` | Valid SQLite database; `Files` columns in order: `fileID`, `domain`, `relativePath`, `flags`, `file` |

Directory IDs must use 40 hexadecimal characters or 8 hexadecimal characters,
a hyphen, and 16 hexadecimal characters. An archived backup can add a
`-YYYYMMDD-HHMMSS` suffix. Its `Target Identifier` still identifies the device.
The database must pass `quick_check` and have no WAL, SHM or journal sidecar.

This deletes a restore point, including device data and settings. It does not
remove an iCloud backup. Use Finder's Manage Backups for unsupported formats.
See [Apple's backup locations and management](https://support.apple.com/en-ie/108809)
and the [MobileBackup2 implementation](https://github.com/libimobiledevice/libimobiledevice/blob/master/tools/idevicebackup2.c).

### Selected Xcode test results

`testresults --test-result PATH` selects one `.xcresult` bundle below an eligible
user home. Repeat the option for more bundles. Xcode 16.3 or later must be installed
and selected: `xcresulttool get content-availability` must accept the bundle.
Missing tools and invalid or incomplete bundles cause a refusal. Close Xcode,
`xcodebuild`, `xctest` and result viewers first. Symlinks, hard-linked files, open
files and nested mounts are refused. `--dry-run` validates without deleting.

This removes selected test results, logs and attachments. Source projects and
`.xcarchive` distribution archives are not targets. See
[Apple's xcresulttool command](https://developer.apple.com/documentation/xcode-release-notes/xcode-16_3-release-notes)
and [test attachments](https://developer.apple.com/documentation/xctest/adding-attachments-to-tests-activities-and-issues).

### Selected Apple Intelligence reports

`aiexports --ai-export PATH` selects an exact local `Apple_Intelligence_Report.json`
file below an eligible user home. Repeat the option for more files. The parser
requires a JSON object with the documented `modelRequests` and
`privateCloudComputeRequests` arrays. It does not inspect or print request content.
Close System Settings and apps that use the report. Unknown JSON, symlinks,
hard links and open files are refused. `--dry-run` only validates.

Deleting an exported report does not disable reporting or remove internal or
remote activity. Change reporting in System Settings > Privacy & Security >
Apple Intelligence Report separately. Opaque Raycast `.rayconfig` exports are
not supported: inspect and delete the exact export manually in Finder. The
script does not infer an encrypted file format from its suffix.
See [Apple's report format](https://security.apple.com/documentation/private-cloud-compute/appendix_appleintelligencereport),
[Apple's report export instructions](https://support.apple.com/en-is/guide/mac-help/mchlfc0d4779/mac)
and [Raycast export guidance](https://manual.raycast.com/import-export).

### Selected document versions

`documentversions` requires an explicit `--version-file /Users/<user>/path`
for each existing local regular file. Close the file in all apps first.

```bash
./shredder.sh --modules documentversions --version-file /Users/alice/Documents/report.txt --dry-run --debug
```

The module calls Apple's `NSFileVersion` API inside an `NSFileCoordinator`
write operation as the home owner. It removes previous versions and retains the
current file contents. It does not delete `.DocumentRevisions-V100` directories.
Dry-run reads version metadata only. The module refuses missing files, links,
shared hard links, owner mismatches, open files and iCloud documents. It checks
the file identity again inside the coordinated write. Coordination requires
cooperating applications; do not rename or modify selected files during cleanup.
It does not remove copies, backups, remote versions or snapshots, and does not
guarantee secure erasure. A native API failure is reported, including a partial
removal failure; the operation cannot restore versions already removed.

Apple's [version-removal API](https://developer.apple.com/documentation/foundation/nsfileversion/removeotherversionsofitem(at:))
requires coordinated writes and can create a missing file. The module checks
that the selected file still exists before it calls this API.

### Selected learned words

`spelling --spelling-word WORD` removes only explicitly selected learned words
through Apple's `NSSpellChecker`. Repeat the option for more words.

```bash
./shredder.sh --modules spelling --spelling-word exampleword --dry-run --debug
```

The module requires an eligible active console user and that user's GUI session.
It runs the native API in that session as that user. It checks whether each word
is learned before removal and checks again after removal. Dry-run only checks
learned status. Duplicate words run once. Output does not print the words. The
words still appear in your command line and can be retained by shell history.

This removes selected spell-checker learned words only. It does not clear all
keyboard history, predictive text, text replacements, passwords, third-party
input-method dictionaries or remote copies. It does not delete dictionary
files or reset preferences. Use System Settings to manage text replacements
and the input method's own controls for other learned data.

Apple documents [unlearnWord](https://developer.apple.com/documentation/appkit/nsspellchecker/unlearnword(_:))
and [hasLearnedWord](https://developer.apple.com/documentation/appkit/nsspellchecker/haslearnedword(_:))
as instance methods for selected words. No complete dictionary reset is claimed.

### Mail recipients and attachments

`mailhistory` is an explicit manual workflow. Mail recipient suggestions and attachment copies have different deletion scopes. Previous Recipients can sync through iCloud Contacts; Remove Attachments for IMAP also removes server attachments. The module gives these distinctions and the supported app actions. It does not delete the Mail data root.

```sh
./shredder.sh --modules mailhistory --dry-run
```

A real run reports exit `2` and does not add cleaned items. A dry-run prints
the guidance and normally returns `0`. The script does not open apps, click
buttons, change permissions, or mutate these stores. [Official instructions](https://support.apple.com/guide/mail/remove-obsolete-email-addresses-mlhlp1113/mac).

### Maps searches and significant locations

`locationhistory` is an explicit manual workflow. Maps recent searches and Significant Locations are separate stores. Use the app and Location Services controls; clearing one does not establish that the other was cleared. Saved places and service settings are not changed by this module.

```sh
./shredder.sh --modules locationhistory --dry-run
```

A real run reports exit `2` and does not add cleaned items. A dry-run prints
the guidance and normally returns `0`. The script does not open apps, click
buttons, change permissions, or mutate these stores. [Official instructions](https://support.apple.com/en-gb/guide/mac-help/mh35873/27/mac/27).

### Phone and FaceTime call history

`callhistory` is an explicit manual workflow. The module explains selected-call deletion in Phone and FaceTime. Carrier records and remote participants are outside local cleanup. It retains call databases, contacts and blocked-caller settings.

```sh
./shredder.sh --modules callhistory --dry-run
```

A real run reports exit `2` and does not add cleaned items. A dry-run prints
the guidance and normally returns `0`. The script does not open apps, click
buttons, change permissions, or mutate these stores. [Official instructions](https://support.apple.com/en-asia/guide/phoneapp/phn33a31c85/mac).

### Messages and recently deleted attachments

`messagehistory` is an explicit manual workflow. Message and attachment deletion can propagate through Messages in iCloud. Recently Deleted is a separate stage. The module explains both stages and preserves all databases and settings; it does not claim to remove recipient copies.

```sh
./shredder.sh --modules messagehistory --dry-run
```

A real run reports exit `2` and does not add cleaned items. A dry-run prints
the guidance and normally returns `0`. The script does not open apps, click
buttons, change permissions, or mutate these stores. [Official instructions](https://support.apple.com/en-euro/guide/messages/icht1035/26.0/mac/27).

### Photo location metadata

`photometadata` is an explicit manual workflow. Photos supports Hide Location and Revert to Original Location. This reversible app action is not an irreversible EXIF sanitizer. The module gives the supported action and asks the user to check exported copies; no image rewrite or library edit is attempted.

```sh
./shredder.sh --modules photometadata --dry-run
```

A real run reports exit `2` and does not add cleaned items. A dry-run prints
the guidance and normally returns `0`. The script does not open apps, click
buttons, change permissions, or mutate these stores. [Official instructions](https://support.apple.com/guide/photos/add-titles-captions-and-more-phta4e5a733f/mac).

## Browser site data and tab recovery

The `browser` module removes browsing history, site cookies and local
tab-recovery files. This signs you out of websites and can remove offline site
files and unfinished forms. Browser bookmarks, saved passwords, preferences,
and separate extension settings stores remain. Browser sync and cloud copies
are not cleared.

Chromium browsers keep autofill entries, saved addresses, saved payment
cards, custom search engines and account sign-in tokens in the same `Web Data`
database. The module removes that complete database. Export or sync the data
that you want to keep before you run the module, and expect to sign in to the
browser again. Firefox `formhistory.sqlite` (saved form entries) is also
removed.

| Browser | Additional scope |
| --- | --- |
| Chrome, Chromium, Edge, Brave | `History`, `Top Sites`, `Web Data` (see above), `Cookies` and `Network/Cookies`, device-bound site sessions, `Sessions` and `Sessions_Encrypted`, legacy current/last session and tab files, and HTTP(S)/file origin IndexedDB stores; default, numbered, and guest profiles |
| Firefox | Visits, typed input and unbookmarked URLs in `places.sqlite` (bookmarks stay), `cookies.sqlite`, `formhistory.sqlite`, and HTTP(S)/file origin directories in default, temporary, permanent, and legacy persistent storage; these hold IndexedDB, local storage, cache storage, and related site files. Known legacy SQLite local-storage tables and quota-cache metadata are filtered by origin. Current and legacy session files and recovery backups are removed |
| Safari | `History.db`, `Downloads.plist`, `TopSites.plist`, legacy session and recently closed tab files, saved application state, container cookies, and cookies in named WebKit data stores |

Some stores combine website data with extension data. By default, those stores
remain and the run exits `2` with their paths. Use the following explicit option
if you also want to remove the extension data in these shared stores:

```sh
./shredder.sh --modules browser --include-extension-data --dry-run --debug
sudo ./shredder.sh --modules browser --include-extension-data --force
```

This option can reset extension settings and sign-ins. It includes Chromium's
Local Storage, Session Storage, Service Worker, File System, legacy databases,
Application Cache, WebStorage, and all IndexedDB stores. It also includes
Firefox extension-origin site storage and legacy local-storage databases, plus
Safari's shared WebKit stores under `WebsiteData` and named `WebsiteDataStore`
directories, plus service-worker, cache-storage, and migrated storage under
WebKit cache roots. It does not remove the separate extension settings
directories.

Safari's modern `SafariTabs.db` also holds saved and synced tab groups. The
script retains it and reports exit `2`, even with `--include-extension-data`.
Remove those tabs through Safari if required. Custom browser profile locations,
other browser products, synced copies, and exported session files are outside
this module's automatic scope. Without `--include-extension-data`, unknown
legacy Firefox local-storage SQLite schemas are retained and reported rather
than deleted. Unknown quota-cache schemas are always retained and reported.
A busy SQLite checkpoint also reports exit `2`; close background readers and
repeat cleanup to remove old WAL pages.

Storage layouts are based on [Chromium profile file names](https://github.com/chromium/chromium/blob/main/chrome/common/chrome_constants.h),
[Chromium session storage](https://github.com/chromium/chromium/blob/main/components/sessions/core/session_constants.cc),
[Firefox quota storage](https://github.com/mozilla/gecko-dev/blob/master/dom/quota/ActorsParent.cpp),
[Firefox legacy local storage](https://github.com/mozilla/gecko-dev/blob/master/dom/storage/StorageDBUpdater.cpp),
and [WebKit data-store paths](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebsiteData/Cocoa/WebsiteDataStoreCocoa.mm).

## Shell history stores

The `shell` module truncates the known Bash, Zsh, shell/REPL and client history
files in each eligible home. It clears `.bash_sessions` and `.zsh_sessions`,
plus known Julia, GHCi, MATLAB, recent-file, Midnight Commander, and nano
history files. These base targets do not wait for Bash or Zsh to exit.
Open processes can write history back after cleanup.

The additional stores below have separate process and schema checks:

```sh
./shredder.sh --modules shell --dry-run --debug
```

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
The `editors` module owns `.viminfo`; `--modules shell` no longer clears it.
Use `ai` to clear supported editor chat histories and `apps` for the selected
application caches and logs. Use the explicit `terminal` module for saved
terminal states.
Custom user-data directories, custom `idea.system.path`, `NVIM_APPNAME`, XDG or
ShaDa path overrides, remote editor stores and third-party history extensions
are outside this module's scope. Recent-file and search records in mixed editor
settings databases are also retained.

Storage references: [VS Code local-history path](https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts),
[JetBrains Local History](https://www.jetbrains.com/help/idea/local-history.html),
[Neovim ShaDa](https://neovim.io/doc/user/starting.html#shada-file-name).

## AI sessions

The `ai` module is included in the standard selection. It operates on each
eligible user home. Close the supported agents, their desktop apps, VS Code,
Cursor, Windsurf, JetBrains IDEs, and background servers before a real run.
The module refuses cleanup if it detects a running agent or cannot inspect
processes. It does not stop processes for you. Keep the apps closed until cleanup finishes.

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

The root-kind table below lists the standard locations. Real runs also read
`CLAUDE_CONFIG_DIR`,
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

All supported `--ai-root` kinds use these paths. `~` in the table refers to
the eligible user's home; pass an absolute path to the option.

| Kind | Directory or file to pass |
| --- | --- |
| `claude` | Claude data root, normally `~/.claude` |
| `codex` | Codex data root, normally `~/.codex` |
| `codex-db` | Directory containing supported SQLite databases, normally within the Codex data root |
| `opencode` | OpenCode data root, normally `~/.local/share/opencode` |
| `opencode-state` | OpenCode state root, normally `~/.local/state/opencode` |
| `opencode-db` | One OpenCode SQLite database file |
| `claude-temp` | A dedicated scratchpad directory; its entire contents can be removed |
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

## Results and incomplete cleanup

- Exit `0`: the run or dry-run completed with zero counted failures.
- Exit `2`: one or more requested operations failed or were refused.
- Exit `64`: invalid command-line input.
- Exit `1`: initialization or environment failure.
- Exit `130`: interrupted by the user.
- Exit `129` or `143`: cleanup received SIGHUP or SIGTERM.

Expected operation failures are counted, and cleanup continues with the next
target. Each module and the optional snapshot purge run in a separate strict
shell. An unexpected command, pipeline, variable, or redirection error stops
that step. The remaining selected modules still run. The summary retains the
operation counts from the stopped step and reports exit `2`. A warning names
the stopped step. If its counters cannot be recovered, the warning states
that partial progress cannot be counted.
Private temporary state contains only numeric counters and is removed after
the step or cancellation. If it cannot be created, the step is skipped and
counted as a failure.

Each module and the optional snapshot purge have a wall-clock limit of one
hour by default (`--module-timeout 3600`). This limit covers the entire step,
including all users and external commands. Progress does not reset the timer.
At the deadline, the watchdog sends SIGTERM to the step's process group. It
allows 30 seconds for termination (`--timeout-grace 30`), then sends SIGKILL
to any remaining processes in that group. The next selected module still
runs. A timeout is counted as a failure and the run returns `2`; it is not
treated as user cancellation. SIGKILL can prevent recovery of partial counts.
Successful steps stop and reap their watchdogs without waiting for the limit.
No GNU `timeout` installation is required.

Initialization and safety checks still apply. Ctrl+C, SIGHUP, and SIGTERM stop
the run. Cleanup does not automatically retry destructive operations or undo
completed work. Argument parsing, environment checks, confirmation, and
private-state setup are outside the module time limit.

Cleanup is not atomic across files, databases, users, or modules. An exit `2`
can follow successful deletions. Review the warnings, correct the cause, and
repeat the affected module. `--force` does not change this behavior. Expected
reasons include active clients, mixed stores without opt-in, retained Safari
tab groups, unknown schemas, busy WAL checkpoints, and access or path failures.
Manual Siri deletion and retained Biome/IntelligencePlatform stores also
produce incomplete results. A module can have no matching files and return
success; exit `0` is not proof that all activity traces on the Mac are gone.

Dry-run does not open the mixed SQLite stores or validate their schemas. It
can finish with exit `0` while noting an operation that a real run would refuse.
Directory traversal errors and unmatched custom AI roots can still produce
exit `2` during a dry-run. A successful preview does not guarantee that a real
cleanup will succeed.

The summary counts operations, not individual records, bytes, or recovered
disk space. A directory or database cleanup can count as one operation.
Unsafe paths with user-controlled symlink parents are refused. Some file
removal helpers can unlink a final symlink without following its target;
selected-file, preference, and mixed-database operations instead refuse links.
Filesystem and SQLite mutations inside each home run with that home's owner privileges, not as root.
The same rule applies to per-user caches under `/private/var/folders`.
Cache deletion checks the physical parent path and uses a relative target from
that directory. Root-owned user directories are refused.

## Tests

The integration suite uses temporary sandboxes for cleanup. It covers CLI
behavior, all registered modules, dry-run stability, process and path checks,
AI and editor settings preservation, shell stores, browser origins and tab
recovery, and mounted-volume Trash. Native Finder and metadata checks operate
on temporary files only. Live FSEvents purging, current-pasteboard clearing,
Siri deletion, and post-cleanup application behavior are not established by
these tests. SQLite tests cover transaction rollback, active
readers and writers, WAL cleanup, unknown schemas, and retained credentials.

```sh
./tests/run-tests.sh
```

See [the test guide](tests/README.md) for dependencies, individual suites,
system-SQLite checks, failure artifacts, and the limits of sandbox validation.
The [CI workflow](.github/workflows/tests.yml) runs shell syntax checks and the
suite on macOS and Ubuntu. ShellCheck is a separate local check.

`SHREDDER_ROOT` is an internal test interface. The target must be an absolute,
non-symlink directory that contains `.macos-shredder-test-root`; unmarked
directories are rejected.

## License

This project uses the [MIT License](LICENSE).
