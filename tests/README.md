# macos-shredder — integration test suite

Self-contained integration tests for `shredder.sh`. The suite never touches
the host system: every fixture lives inside a throwaway sandbox redirected
through the `SHREDDER_ROOT` contract, so the same suite runs unchanged on a
developer Mac and on a Linux CI runner.

Files:

| Script                 | Role                                                        |
| ---------------------- | ----------------------------------------------------------- |
| `run-tests.sh`         | orchestrator — runs phases A–I, reports PASS/FAIL per phase |
| `create-artifacts.sh`  | builds the deterministic sandbox fixture tree (+ manifest)  |
| `verify-cleanup.sh`    | asserts post-cleaning state (`force`) or byte-stability (`dryrun`) |
| `README.md`            | this document                                               |

## Sandbox architecture (the SHREDDER_ROOT contract)

`shredder.sh` honours `SHREDDER_ROOT=<dir>` only when the absolute,
non-symlink directory contains `.macos-shredder-test-root`. Every filesystem
target is redirected under that prefix, root/Darwin checks are skipped, and no
special macOS tooling is required. Tests use this to build a miniature macOS
filesystem with two simulated users:

- `Users/alice` and `Users/User Space` — full per-user fixtures. The space in
  `User Space` is deliberate bait for unquoted-enumeration bugs.
- `Users/mallory` is a symlink to an escape sentinel and must never be
  traversed by root cleanup.
- `Users/Shared`, `Users/Guest`, `Users/.hiddenuser` — homes that enumerators
  must **skip**; their history files must survive cleaning untouched.

System-level fixtures:

- `var/log/system.log` containing the legacy `NYXTEST` marker plus the current
  `SHRED-TEST` marker; `var/log/wifi.log`; `Library/Logs/DiagnosticReports/`
  (system-level `crash-1.ips` and one per user).
- `var/audit/2023…` / `2024…` rotation files plus `var/audit/current`, which
  must be preserved.
- `var/db/diagnostics/{Persist,Special,HighVolume}/` — unified log store.
- `private/var/folders/xx/yy/C/com.apple.notificationcenter/db2/db.db` and
  `…/com.apple.QuickLook.thumbnailcache/thumb.jpg`.
- `private/var/db/CoreDuet/Knowledge/knowledgeC.db` — a real SQLite database
  (tables `ZOBJECT` and `ZSTRUCTUREDMETADATA`, each holding a marker row) when
  `sqlite3` is available, otherwise a plain text file carrying the marker.

Per-user fixtures:

- Shell histories: `.zsh_history`, `.bash_history`, `.bash_sessions/`, and
  `.ipython/profile_default/history.sqlite` with WAL/SHM/journal sidecars.
- `Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2` — real
  SQLite (`LSQuarantineEvent` table + marker row) or text stand-in.
- Safari: `History.db` with `-wal` / `-shm` sidecars, plists, cache file.
- Chrome: `Default` and `Profile 1`; an intermediate Chromium profile symlink
  points outside the user home and must be refused.
- Per-user KnowledgeC and Shared File List recent-item stores. Non-recent
  favorites must survive.
- Trash: `.Trash/file.txt` **and** `.Trash/.hidden-leak` (hidden file proves
  correct emptying).
- Homebrew caches/logs; app traces (VS Code, JetBrains, saved states).
- `.DS_Store` files in `Users/<u>/{Desktop,Documents,Downloads}` and mirrored
  under the data-volume tree `System/Volumes/Data/Users/<u>/…`; an external
  volume sentinel at `Volumes/BACKUP/.DS_Store` that must **survive**.
- Wifi system preferences under `Library/Preferences/SystemConfiguration/`.

## Running locally

```sh
./tests/run-tests.sh
```

The orchestrator needs no arguments. Individual pieces can also be used
directly:

```sh
tests/create-artifacts.sh /tmp/sbx [--manifest /tmp/manifest.tsv]
tests/verify-cleanup.sh /tmp/sbx --phase force
tests/verify-cleanup.sh /tmp/sbx --phase dryrun --manifest /tmp/manifest.tsv
```

Exit codes: `run-tests.sh` → `0` all phases passed, `1` any phase failed,
`77` `shredder.sh` not built yet. `verify-cleanup.sh` → `0` all checks passed,
`1` any check failed.

## What each phase proves

- **A — usage validation**: `--modules bogus_definitely_invalid` must exit
  `64` and print valid module ids → strict exact-match CLI validation.
- **B — module listing**: `--list` exits `0` and prints all 14 module ids.
- **C — forced clean**: after `--force --debug` against a fresh sandbox:
  - histories emptied/gone for both users → **space-in-username enumeration
    fix**;
  - `.Trash/.hidden-leak` gone → hidden-file-aware trash emptying;
  - audit rotations gone while `var/audit/current` survives → preservation
    proof;
  - `Volumes/BACKUP/.DS_Store` survives while every in-sandbox `.DS_Store` is
    swept → external-volume pruning proof;
  - quarantine/KnowledgeC marker rows absent → markers really removed;
  - output contains `Total items cleaned:` with a count > 0 and exactly zero
    failed operations;
  - a corrupt SQLite database makes verification fail closed.
- **D — dry-run byte-stability**: `create-artifacts.sh --manifest` captures a
  sha256 manifest before the run; after `shredder.sh -n -f --debug` the
  manifest must recompute byte-identical with an identical file set → proves
  there is **no unguarded destructive operation** behind the dry-run flag
  (the latent-bomb regression class).
- **E — sandbox guard**: an unmarked `SHREDDER_ROOT` must fail before any
  module runs. Fixture roots carry `.macos-shredder-test-root`.
- **F — confirmation guard**: a non-interactive destructive run without
  `--force` must abort without changing the fixture.
- **G — host-command isolation**: sandbox mode must not execute `defaults` or
  `qlmanage`; command stubs turn any attempted invocation into a test failure.
- **H — least-privilege user commands**: user-home mutations must pass through
  the owner-UID command wrapper when the caller UID differs.
- **I — symlink refusal**: the adversarial user-home symlinks are tested
  separately and must produce exit `2` with the exact expected failure count.

## Requirements

- bash 3.2+ (no bash-4-only features used)
- POSIX-ish userland: `find sort sed awk grep wc stat cp mv rm mkdir` — BSD or
  GNU variants both work (file sizes via `stat -c%s` with `stat -f%z`
  fallback)
- `shasum` **or** `sha256sum` for manifests/hashes
- optional `sqlite3`: enables real database fixtures and exact marker-row
  assertions; without it both fixture creation and verification degrade to
  marked text files consistently
- no root privileges anywhere

## CI integration

On any phase failure `run-tests.sh` copies logs, manifests and the full
sandbox trees to `tests-last-run/` at the repo root — upload that directory as
a build artifact to debug failures. Example GitHub Actions step:

```yaml
- run: ./tests/run-tests.sh
- if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: tests-last-run
    path: tests-last-run/
```
