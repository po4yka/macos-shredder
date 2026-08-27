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
  databases to avoid corruption.

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

Mounted volumes are excluded by default. Use `--include-volumes` to include
their FSEvents and `.DS_Store` data. Use `--purge-snapshots` only when you also
want to delete local Time Machine snapshots.

## Result contract

- Exit `0`: success, or a completed dry-run.
- Exit `2`: one or more requested operations failed or were refused.
- Exit `64`: invalid command-line input.
- Exit `1`: initialization or environment failure.
- Exit `130`: interrupted by the user.

The summary counts only operations that succeeded or would run. Unsafe paths
with user-controlled symlink components are refused. Filesystem and SQLite
mutations inside each home run with that home's owner privileges, not as root.

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
