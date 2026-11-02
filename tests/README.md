# macos-shredder test guide

Run the suite from the repository root. Cleanup tests use temporary, marked
sandboxes. They do not remove host histories, sessions, browser data, or Trash.
The runner is configured for macOS and Linux. Native-only checks are identified
below; a Linux pass does not establish macOS API behavior. Tests cover known
fixtures, not every installed application version.

See the [module reference](../README.md#modules) for cleanup scope and the
[result contract](../README.md#results-and-incomplete-cleanup) for CLI exit codes.

## Requirements and commands

- Bash 3.2 or later.
- Standard BSD or GNU command-line tools, including `find`, `stat`, `sort`,
  `sed`, `awk`, `grep`, `cp`, `mv`, `rm`, `mkdir`, `mktemp`, and `mkfifo`.
- `sqlite3` with JSON support. Tests use real databases, transactions, and WAL
  readers and writers.
- `shasum` or `sha256sum`, plus `gzip`, `cmp`, and `diff`.
- Native `plutil`, `defaults`, and `xattr` for macOS fixture checks. Linux does
  not need these tools; platform-specific checks use the boundaries below.
- ShellCheck for the optional lint command below.

No root privileges are required. From the repository root:

```sh
# Check each script separately; bash -n accepts one script at a time.
for script in shredder.sh tests/*.sh; do
  /bin/bash -n "$script" || exit "$?"
done

# Run all phases and feature suites.
./tests/run-tests.sh

# Optional local lint check.
shellcheck shredder.sh tests/*.sh
```

On macOS, also test the system tools that a real host run uses:

```sh
PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash tests/run-tests.sh
```

The SQLite found on a developer's `PATH` can differ from `/usr/bin/sqlite3`.
The AI transaction regression tests both binaries when available. The shared
SQL helper sends statements on separate input lines with `-bail`: a failed
statement must stop execution before a later `DELETE` or `COMMIT`. A separate
browser test holds a WAL reader open and requires a reported failure until
checkpoint truncation can complete.

## Test files

`run-tests.sh` runs phases A–O first, then these 17 feature suites in order:

| File | Role |
| --- | --- |
| [regressions.sh](regressions.sh) | General cleanup, status, absence of operation logs, and fixture checks |
| [ai-sessions.sh](ai-sessions.sh) | Agent sessions, databases, mixed JSON, derived data, and credentials |
| [ai-editors.sh](ai-editors.sh) | Cursor, Windsurf, Continue, Cline/Roo, and Aider sessions |
| [browser-stores.sh](browser-stores.sh) | Website storage, tab recovery, extension opt-in, and WAL handling |
| [shell-stores.sh](shell-stores.sh) | Atuin and alternative shell history stores |
| [editor-history.sh](editor-history.sh) | Editor local history, retained settings, and unsaved buffers |
| [volume-trash.sh](volume-trash.sh) | Opt-in mounted-volume Trash cleanup and owner checks |
| [clipboard.sh](clipboard.sh) | Maccy history, pinned items, and current-pasteboard command guards |
| [terminal-usage.sh](terminal-usage.sh) | cmux sessions and per-application recent-document lists |
| [ai-extended.sh](ai-extended.sh) | Gemini, Antigravity, desktop AI, context-mode, and Serena stores |
| [headless.sh](headless.sh) | Explicit selection and age/lock checks for temporary browser profiles |
| [slack-export.sh](slack-export.sh) | Selected standard JSON and Slackdump exports |
| [terminal-output.sh](terminal-output.sh) | Terminal/iTerm2 saved output and explicitly selected log files |
| [finder-history.sh](finder-history.sh) | Known Finder/Open-Save keys and native preference preservation |
| [system-traces.sh](system-traces.sh) | Log retention and FSEvents command contracts |
| [file-metadata.sh](file-metadata.sh) | Selected origin attributes, retained content, and link refusal |
| [activity-stores.sh](activity-stores.sh) | Notification/activity SQLite stores and manual Siri reporting |
| [alfred.sh](alfred.sh) | Alfred manual instructions, incomplete status, and complete fixture preservation |

Supporting scripts:

| File | Role |
| --- | --- |
| [run-tests.sh](run-tests.sh) | Orchestrates the core phases and feature suites |
| [create-artifacts.sh](create-artifacts.sh) | Builds the core fixture tree and optional manifest |
| [verify-cleanup.sh](verify-cleanup.sh) | Checks core cleanup results or dry-run stability |

Each feature suite can run independently, for example:

```sh
/bin/bash tests/browser-stores.sh
/bin/bash tests/shell-stores.sh
/bin/bash tests/editor-history.sh
/bin/bash tests/volume-trash.sh
/bin/bash tests/finder-history.sh
/bin/bash tests/activity-stores.sh
```

The runner returns `0` when all checks pass, `1` when a core phase fails, and
`77` when `shredder.sh` is missing. A feature-suite failure stops the runner
with a nonzero status. The verifier returns `0` for success and `1` for a failed
check. These are test exit codes; the cleaner's exit codes are documented in
[the project README](../README.md#results-and-incomplete-cleanup).

## Sandbox contract and fixtures

`SHREDDER_ROOT` must name an existing absolute directory that is not a symlink
and contains `.macos-shredder-test-root`. The script resolves its physical path
and redirects cleanup targets under it. Root, Darwin, and Full Disk Access
checks are skipped. The sandbox keeps the test `PATH` for controlled command
substitutions. Host AI environment overrides are ignored; explicit AI roots
under `/Users/...` are mapped below the sandbox. The explicit Slack export,
terminal-log, and metadata-file options use the same path mapping.

Sandbox mode does not automatically simulate every native condition. Tests
inject process results, owner metadata, and selected command failures where
needed. The Spotlight check uses a native dry-run on macOS and performs no
index mutation. No host client is stopped.

The core fixture contains two regular users, `alice` and `User Space`, plus a
linked home and `Shared`, `Guest`, and hidden homes that must remain untouched.
It includes shell histories, logs, audit trails, quarantine and KnowledgeC
SQLite databases, browser profiles, Quick Look and application caches, recent
items, home Trash, Wi-Fi preferences, and `.DS_Store` files. A mounted-volume
sentinel must survive cleanup without `--include-volumes`. Firefox fixtures
include bookmarks and keywords as well as history. Audit fixtures include a
`current` link whose target must remain. The linked Chromium profile points to
an escape sentinel that must remain unchanged.

The core fixture follows the standard module selection. Terminal saved state
and Notification Center data must survive that run because their modules now
require explicit selection. The core fixture is not a complete fixture for
all 26 modules.

Feature suites create their own stores and opt-in arguments. They do not
depend on `create-artifacts.sh` to supply the extended layouts.

To inspect the core fixture manually, use a new disposable directory:

```sh
test_dir="$(mktemp -d)"
./tests/create-artifacts.sh "$test_dir/sandbox" --manifest "$test_dir/manifest.tsv"
SHREDDER_ROOT="$test_dir/sandbox" ./shredder.sh --dry-run --debug
./tests/verify-cleanup.sh "$test_dir/sandbox" --phase dryrun \
  --manifest "$test_dir/manifest.tsv"

# The fixture includes a linked Chromium profile; refusal is expected.
fixture_status=0
SHREDDER_ROOT="$test_dir/sandbox" ./shredder.sh --force --debug || fixture_status=$?
test "$fixture_status" -eq 2
./tests/verify-cleanup.sh "$test_dir/sandbox" --phase force
```

The linked Chromium profile makes this cleanup return `2`. The post-state
verifier must still return `0`: supported targets are cleaned and the linked
profile's escape sentinel is retained. The runner's separate happy-path phase
removes the adversarial links first and expects cleanup to return `0`.

The fixture builder writes test files and creates the sandbox marker. Use it
only in a disposable test directory. Keep that directory for inspection, then
remove it when finished. Never mark a real home or mounted volume as a sandbox.

## Core phases A–O

| Phase | Required behavior |
| --- | --- |
| A — CLI validation | Invalid or empty module selections return `64` and retain data |
| B — module listing | `--list` returns `0` and includes all registered module IDs |
| C — forced cleanup | Selected fixture data is removed for both users; bookmarks, audit `current`, excluded homes, and external-volume sentinels remain; corrupt SQLite makes verification fail |
| D — dry-run | File hashes, directories, and symlink targets match the pre-run manifest; an added file makes verification fail |
| E — sandbox guard | An unmarked root is refused before cleanup |
| F — confirmation | Non-interactive cleanup without `--force` fails without changing the fixture |
| G — host isolation | `usage` and `quicklook` in sandbox mode do not invoke host `defaults` or `qlmanage` commands |
| H — owner privileges | Home and per-user cache mutations use the owner-UID wrapper when the caller UID differs |
| I — symlink refusal | Adversarial browser paths return `2` with the expected failure count; escape sentinels remain |
| J — sandbox boundary | A linked system path cannot redirect cleanup outside the marked root |
| K — trusted PATH | Native mode ignores injected caller commands; sandbox mode permits test command substitution |
| L — SQLite discovery | Failed KnowledgeC inspection returns `2` instead of continuing to compaction |
| M — Spotlight | On macOS, dry-run reports the requested erase-and-rebuild operation; other platforms skip this native check |
| N — cache parent race | A parent replaced with a symlink cannot redirect deletion; the original entry and escape sentinel remain |
| O — Firefox failure safety | Unsupported schema, transaction errors, and absent SQLite retain the Places database and report failure |

## Feature and failure-path coverage

| Suite | Checks |
| --- | --- |
| General regressions | Failed traversal and snapshot listing, Wi-Fi stores, zsh sessions, log rotations, browser caches and sidecars, active browsers, Trash links, absence of operation logs, rejection of the removed logfile option, and three deterministic fixture rebuilds |
| AI sessions | Sessions, archives, indexes, desktop catalogs, mixed configuration/credential tables and JSON, optional derived data, custom roots, multiple users, repeated cleanup, unknown schemas, locks, links, Claude scratchpads, environment overrides, and failed-statement rollback |
| AI editors | Named profiles, workspace databases and backups, binary secrets, approval settings, Cascade settings, extension configuration, Aider source/Git preservation, custom roots, malformed state, and recovery-copy refusal |
| Browser stores | Chromium profiles, mixed-store opt-in, Firefox origin directories and SQLite metadata, retained extension state, Safari saved tab-group refusal, Safari cache-only roots, Brave process naming, process-query failures, symlinks, and a pinned WAL reader followed by successful retry |
| Shell stores | Atuin history and encrypted history records, history pack manifests, retained keys/authentication/KV/scripts, fish, Nushell, Xonsh, histdb, directory jump stores, IPython profiles, unsupported schemas, rollback, and active clients |
| Editor history | VS Code-family shared history, JetBrains LocalHistory, Vim/Neovim state, retained settings and unsaved buffers, process checks, symlink boundaries, and enumeration failures |
| Volume Trash | Default exclusion, explicit opt-in, hidden entries, UID scope, retained Trash directories, links, owner mismatch, deletion failure, and the native mounted-device filter |
| Clipboard | Maccy pinned-item and configuration preservation, known schema cleanup, orphan content, transaction logs, unsupported layouts, linked files, real WAL writer refusal, retry, and dry-run stability; native pasteboard commands are never run |
| Terminal and usage | cmux opt-in, retained settings and tools, process-query failure, multiple users, nested recent-document lists, unknown file preservation, and symlink refusal |
| Extended AI | Known Gemini/Antigravity/desktop/context-mode stores, real FTS databases, credentials and settings preservation, derived-history opt-in, unsupported schemas, links, orphan sidecars, process guards, and a real WAL writer |
| Headless profiles | Explicit selection, age limits, recent descendant files, locked and unknown profiles, process-query failures, dry-run stability, and physical-parent replacement refusal |
| Slack exports | Explicit roots, standard JSON metadata validation, selected Slackdump files, preservation of scripts/configuration, path traversal and link refusal, locks, process checks, malformed exports, and dry-run stability |
| Terminal output | Explicit selection, two homes, saved-state removal, retained settings, custom-file boundaries, dry-run stability, and client/restoration-server guards |
| Finder history | Exact candidate files, preview and process checks; native XML/binary key deletion, retained data/date/settings, repeat runs, and unknown-type/malformed/hardlink refusal |
| System traces | Old/recent/current logs, incomplete audit trails, failed open-file inspection, age/unified CLI rejection, explicit FSEvents selection, and native volume/API command boundaries |
| File metadata | Required paths, selective origin-attribute removal, retained bytes and other attributes, dry-run/repeat runs, and hardlink/symlink/directory/home refusal |
| Activity stores | Delivered/pending notification separation, retained configuration, KnowledgeC related tables, event/feedback logs, schema/trigger/link failures, service guards, real WAL writer refusal/retry, absent SQLite, unknown archives, and Siri/unsupported-store reporting |

Feature suites check dry-run preservation and repeated cleanup where applicable.
Process detection is tested with controlled command listings. Native volume
filtering uses injected metadata; tests do not mount or erase a real disk.
Actual application startup after cleanup, live Full Disk Access/SIP behavior,
cloud synchronization, and all vendor schema versions remain outside automated
acceptance. See the README for supported layouts and retained stores.

## Native behavior and validation limits

| Surface | macOS checks | Linux checks | Not established by these tests |
| --- | --- | --- | --- |
| Finder preferences | Native `plutil` and `defaults` on temporary XML/binary plists | Preview, path, and process checks; native mutation reported unavailable | Live Finder/cfprefsd behavior or restoration from another app |
| File metadata | Native `xattr` on temporary files; content and unrelated attributes retained | File-backed xattr command double | Spotlight refresh or removal of backup copies |
| Maccy and activity stores | Real SQLite fixtures, locks, transactions, and retained rows | Same fixture logic | Every vendor schema, live daemon behavior, or app startup after cleanup |
| Current clipboard | Command guards; host pasteboard is not cleared | Command guards | Clearing a real GUI user's pasteboard |
| FSEvents | Fixture scope and injected mount/API responses | Same command-contract tests | Native purge acceptance or physical removal of events |
| Logs, audit, snapshots | Fixtures and command doubles; no live log erasure or snapshot purge | Same fixture scope | Native permissions or system-service behavior |
| Spotlight | Read-only native dry-run plus result checks | Native check skipped | Index deletion, rebuild completion, or future indexing |
| Siri/Dictation | Manual guidance, real fixture exit `2`, dry-run exit `0`, zero cleaned items | Same CLI contract | Deletion in Settings, Siri app, or cloud services |

The read-only JXA event-ID check performed during FSEvents implementation was
an investigation, not a native purge test in the suite. Do not interpret it
as end-to-end cleanup acceptance. Live Full Disk Access/SIP behavior, mounted
disk erasure, service restart races, and cloud synchronization require separate
authorized validation.

## CI and failure artifacts

The [workflow](../.github/workflows/tests.yml) is configured to run on pushes to
`main`, pull requests, and manual dispatch. It uses `macos-latest` and `ubuntu-latest`, checks
each shell script's syntax, and runs `tests/run-tests.sh`. ShellCheck is not
currently a workflow step.

If a core phase A–O fails, the runner copies its logs, manifests, and sandbox
trees to `tests-last-run/`. CI uploads this directory with
`actions/upload-artifact@v7` as `tests-last-run-<os>`. Missing artifacts are
ignored. Each later feature suite removes its temporary directory on exit;
those failures are visible in command output but do not automatically populate
`tests-last-run/`. Capture output when diagnosing an individual suite:

```sh
/bin/bash tests/browser-stores.sh > /tmp/shredder-browser-tests.log 2>&1
```

The fixture checks do not establish secure erasure on APFS or SSDs. They verify
selected logical removals and preservation rules against the tested layouts.

`diagnostic-exports.sh` checks exact export selection, archive identity, dry-run,
invalid formats, symlinks, hard links and process-query refusal in temporary fixtures.

`device-backups.sh` checks selected backup identity, finished state, encryption,
manifest schema and dry-run with native plist and SQLite tools on macOS fixtures.
Linux uses a plistlib adapter for the unavailable native plutil boundary.

### Document versions

`bash tests/document-versions.sh` verifies explicit selection, path guards,
owner and link checks, failure reporting and dry-run behavior. On macOS it
creates an `NSFileVersion` only for a synthetic document in a marked temporary
fixture, removes that version through the native coordinated API, and checks
that current contents stay unchanged. On other systems it uses a native-boundary
double and reports that the native check is unavailable.

`manual-privacy.sh` checks explicit selection, manual-action notices, zero
cleaned items, real exit `2`, dry-run exit `0`, and fixture preservation for
manual privacy workflows. It never opens apps or performs their actions.


### Selected learned words

`bash tests/spelling.sh` tests explicit options, duplicate words, dry-run,
selected-word removal, absent words, unavailable GUI sessions and native
failures through a file-backed boundary double. The real AppKit mutation
boundary always refuses test mode. On macOS the suite checks native selector
availability without creating a spell checker or changing any learned words.
A temporary HOME does not isolate the user's dictionary service, so the suite
does not claim live dictionary mutation coverage.
