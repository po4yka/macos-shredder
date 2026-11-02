# macos-shredder test guide

Run the suite from the repository root. Cleanup tests use temporary, marked
sandboxes. They do not remove host histories, sessions, browser data, or Trash.
The suite runs on macOS and Linux. It tests the script's behavior against local
fixtures; it does not test every installed application version.

## Requirements and commands

- Bash 3.2 or later.
- Standard BSD or GNU command-line tools, including `find`, `stat`, `sort`,
  `sed`, `awk`, `grep`, `cp`, `mv`, `rm`, `mkdir`, `mktemp`, and `mkfifo`.
- `sqlite3` with JSON support. Tests use real databases, transactions, and WAL
  readers and writers.
- `shasum` or `sha256sum`, plus `gzip`, `cmp`, and `diff`.
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

| File | Role |
| --- | --- |
| `run-tests.sh` | Runs core phases A–O, then the suites below in table order |
| `regressions.sh` | General cleanup, status, logfile, and fixture checks |
| `ai-sessions.sh` | Agent sessions, databases, mixed JSON, derived data, and credentials |
| `ai-editors.sh` | Cursor, Windsurf, Continue, Cline/Roo, and Aider sessions |
| `browser-stores.sh` | Website storage, tab recovery, extension opt-in, and WAL handling |
| `shell-stores.sh` | Atuin and alternative shell history stores |
| `editor-history.sh` | Editor local history, retained settings, and unsaved buffers |
| `volume-trash.sh` | Opt-in mounted-volume Trash cleanup and owner checks |
| `create-artifacts.sh` | Builds the core fixture tree and optional manifest |
| `verify-cleanup.sh` | Checks core cleanup results or dry-run stability |

Each feature suite can run independently, for example:

```sh
/bin/bash tests/browser-stores.sh
/bin/bash tests/shell-stores.sh
/bin/bash tests/editor-history.sh
/bin/bash tests/volume-trash.sh
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
under `/Users/...` are mapped below the sandbox.

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

Feature suites create separate fixtures for agent sessions, editor histories,
site data, alternative shell stores, and volume Trash. They do not depend on
`create-artifacts.sh` to supply those stores.

To inspect the core fixture manually, use a new disposable directory:

```sh
test_dir="$(mktemp -d)"
./tests/create-artifacts.sh "$test_dir/sandbox" --manifest "$test_dir/manifest.tsv"
SHREDDER_ROOT="$test_dir/sandbox" ./shredder.sh --dry-run --debug
./tests/verify-cleanup.sh "$test_dir/sandbox" --phase dryrun \
  --manifest "$test_dir/manifest.tsv"

SHREDDER_ROOT="$test_dir/sandbox" ./shredder.sh --force --debug
./tests/verify-cleanup.sh "$test_dir/sandbox" --phase force
```

The fixture builder writes test files and creates the sandbox marker. Use it
only in a disposable test directory. Keep that directory for inspection, then
remove it when finished. Never mark a real home or mounted volume as a sandbox.

## Core phases A–O

| Phase | Required behavior |
| --- | --- |
| A — CLI validation | Invalid or empty module selections return `64` and retain data |
| B — module listing | `--list` returns `0` and includes all 20 module IDs |
| C — forced cleanup | Selected fixture data is removed for both users; bookmarks, audit `current`, excluded homes, and external-volume sentinels remain; corrupt SQLite makes verification fail |
| D — dry-run | File hashes, directories, and symlink targets match the pre-run manifest; an added file makes verification fail |
| E — sandbox guard | An unmarked root is refused before cleanup |
| F — confirmation | Non-interactive cleanup without `--force` fails without changing the fixture |
| G — host isolation | Sandbox mode does not invoke host `defaults` or `qlmanage` commands |
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
| General regressions | Failed traversal and snapshot listing, Wi-Fi stores, zsh sessions, log rotations, browser caches and sidecars, active browsers, Trash links, private logfiles, and three deterministic fixture rebuilds |
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

Feature suites check dry-run preservation and repeated cleanup where applicable.
Process detection is tested with controlled command listings. Native volume
filtering uses injected metadata; tests do not mount or erase a real disk.
Actual application startup after cleanup, live Full Disk Access/SIP behavior,
cloud synchronization, and all vendor schema versions remain outside automated
acceptance. See the README for supported layouts and retained stores.

## CI and failure artifacts

The [workflow](../.github/workflows/tests.yml) runs on pushes to `main`, pull
requests, and manual dispatch. It uses `macos-latest` and `ubuntu-latest`, checks
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

`terminal-output.sh` checks explicit selection, saved output removal, retained settings, custom file boundaries, dry-run stability and process-query refusal.
