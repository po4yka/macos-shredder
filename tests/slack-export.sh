#!/bin/bash
# Slack export cleanup uses marked temporary sandboxes only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

setup() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1
    SANDBOX="$SHREDDER_ROOT"
    resolve_paths
    STORE_HOME="$USERS_DIR/User Space"
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-keep}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}
seed_standard() {
    put "$1/users.json" '[{"id":"U123","name":"user"}]'
    put "$1/channels.json" '[{"id":"C123","name":"general"}]'
    put "$1/dms.json" '[{"id":"D123"}]'
    put "$1/general/2026-11-01.json" '[{"type":"message","text":"message-marker"}]'
    put "$1/D123/2026-11-02.json" '[{"type":"message","text":"message-marker"}]'
    put "$1/general/notes.json" keep
    put "$1/general/subdir/2026-11-01.json" keep
    put "$1/unlisted/2026-11-01.json" keep
    put "$1/config.json" keep
    put "$1/export.sh" keep
}
seed_dump() {
    mkdir -p "$1/archive/__uploads" "$1/archive/__avatars" "$1/snapshots"
    sqlite3 "$1/archive/slackdump.sqlite" 'CREATE TABLE messages(text TEXT); INSERT INTO messages VALUES("message-marker");'
    sqlite3 "$1/snapshots/slackdump_20261101_123456.sqlite" 'CREATE TABLE messages(text TEXT); INSERT INTO messages VALUES("message-marker");'
    put "$1/archive/slackdump.sqlite-wal" history
    put "$1/archive/slackdump.sqlite-shm" history
    put "$1/snapshots/slackdump_20261101_123456.sqlite-journal" history
    put "$1/archive/__uploads/.hidden/file.bin" history
    put "$1/archive/__avatars/avatar.png" history
    put "$1/users-T123.json" '[{"id":"U123"}]'
    put "$1/channels-T123.txt" history
    put "$1/archive/unknown.sqlite" keep
    put "$1/snapshots/manual-backup.sqlite" keep
    put "$1/users-T123.json.backup" keep
    put "$1/bin/slackdump" keep
    put "$1/.claude/settings.json" keep
    put "$1/.omc/state.json" keep
    put "$1/monitor.sh" keep
    put "$1/.env" keep
}

test_cli_and_standard() (
    setup standard
    local root="$STORE_HOME/Slack's Export" second="$STORE_HOME/second" path
    seed_standard "$root"
    seed_standard "$second"
    cp -R "$SANDBOX" "$WORK/before-standard"
    expect_status 64 --modules slackexport --dry-run
    expect_status 64 --modules shell --slack-export-root "/Users/User Space/Slack's Export" --dry-run
    for path in /Users/User\ Space /Users/User\ Space/Documents /Users/User\ Space/Downloads /Users/User\ Space/Library /Users/Shared/export /Users/Guest/export /tmp/export /Users/User\ Space/a/../export /Users/User\ Space//export; do
        expect_status 64 --modules slackexport --slack-export-root "$path" --dry-run
    done
    module_selected shell
    if module_selected slackexport; then exit 1; fi
    expect_status 0 --modules slackexport --slack-export-root "/Users/User Space/Slack's Export" --slack-export-root '/Users/User Space/second' --dry-run --debug
    diff -r "$WORK/before-standard" "$SANDBOX"
    expect_status 0 --modules slackexport --slack-export-root "/Users/User Space/Slack's Export" --slack-export-root '/Users/User Space/second' --force
    for path in "$root" "$second"; do
        [ ! -e "$path/users.json" ] && [ ! -e "$path/channels.json" ] && [ ! -e "$path/dms.json" ]
        [ ! -e "$path/general/2026-11-01.json" ] && [ ! -e "$path/D123/2026-11-02.json" ]
        grep -q keep "$path/general/notes.json"
        grep -q keep "$path/general/subdir/2026-11-01.json"
        grep -q keep "$path/unlisted/2026-11-01.json"
        grep -q keep "$path/config.json"
        grep -q keep "$path/export.sh"
        [ -d "$path" ]
    done
    cp -R "$SANDBOX" "$WORK/after-standard"
    # After metadata removal this retained mixed directory has no signature.
    # A repeated request refuses the unknown layout and leaves all files intact.
    expect_status 2 --modules slackexport --slack-export-root "/Users/User Space/Slack's Export" --force
    diff -r "$WORK/after-standard" "$SANDBOX"
)
test_cli_and_standard
printf 'PASS: explicit roots, quoted paths, multiple exports, dry-run and selective standard cleanup\n'

test_dump() (
    setup dump
    local root="$STORE_HOME/slack_dump" path
    seed_dump "$root"
    cp -R "$SANDBOX" "$WORK/before-dump"
    expect_status 0 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --dry-run --debug
    diff -r "$WORK/before-dump" "$SANDBOX"
    expect_status 0 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
    for path in archive/slackdump.sqlite archive/slackdump.sqlite-wal archive/slackdump.sqlite-shm snapshots/slackdump_20261101_123456.sqlite snapshots/slackdump_20261101_123456.sqlite-journal users-T123.json channels-T123.txt; do
        [ ! -e "$root/$path" ]
    done
    [ -d "$root/archive/__uploads" ] && [ -d "$root/archive/__avatars" ]
    [ -z "$(find "$root/archive/__uploads" "$root/archive/__avatars" -mindepth 1 -print)" ]
    for path in archive/unknown.sqlite snapshots/manual-backup.sqlite users-T123.json.backup bin/slackdump .claude/settings.json .omc/state.json monitor.sh .env; do grep -q keep "$root/$path"; done
    expect_status 0 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
)
test_dump
printf 'PASS: slackdump archive, snapshots and media removed; tooling/configuration remain; repeat is safe\n'

test_download_free_dump() (
    setup download-free
    local root="$STORE_HOME/slack_dump"
    mkdir -p "$root/archive"
    sqlite3 "$root/archive/slackdump.sqlite" 'CREATE TABLE messages(text TEXT);'
    expect_status 0 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
    [ ! -e "$root/archive/slackdump.sqlite" ]
    expect_status 0 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
)
test_download_free_dump
printf 'PASS: download-free archives do not require media directories\n'

test_malformed_and_locks() (
    setup malformed
    local root="$STORE_HOME/export"
    seed_standard "$root"
    put "$root/channels.json" '[{"name":"../outside"}]'
    cp -R "$SANDBOX" "$WORK/before-malformed"
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/export' --force
    diff -r "$WORK/before-malformed" "$SANDBOX"
    put "$root/channels.json" 'not-json'
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/export' --force
    [ -s "$root/users.json" ] && [ -s "$root/general/2026-11-01.json" ]
    put "$root/channels.json" '[{"name":"general"}]'
    put "$root/D123/2026-11-02.json" 'bad-message-json'
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/export' --force
    [ -s "$root/users.json" ] && [ -s "$root/general/2026-11-01.json" ]
    put "$root/.lock" keep
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/export' --force
    grep -q keep "$root/.lock"
    mkdir -p "$STORE_HOME/unknown"
    put "$STORE_HOME/unknown/report.json" keep
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/unknown' --force
    grep -q keep "$STORE_HOME/unknown/report.json"
)
test_malformed_and_locks
printf 'PASS: malformed JSON, traversal names, locks and unknown layouts fail before deletion\n'

test_links_and_sidecars() (
    setup links
    local root="$STORE_HOME/export" dump="$STORE_HOME/slack_dump"
    seed_standard "$root"
    put "$WORK/outside/2026-11-01.json" keep
    mv "$root/general" "$root/original-general"
    ln -s "$WORK/outside" "$root/general"
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/export' --force
    grep -q keep "$WORK/outside/2026-11-01.json"
    [ -s "$root/users.json" ]
    ln -s "$root" "$STORE_HOME/linked"
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/linked' --force
    seed_dump "$dump"
    rm "$dump/archive/slackdump.sqlite-shm"
    ln -s "$WORK/outside/2026-11-01.json" "$dump/archive/slackdump.sqlite-shm"
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
    [ -s "$dump/archive/slackdump.sqlite" ]
    [ -s "$dump/archive/__avatars/avatar.png" ]
    grep -q keep "$WORK/outside/2026-11-01.json"
    rm "$dump/archive/slackdump.sqlite-shm"
    put "$dump/snapshots/slackdump_20260101_000000.sqlite-wal" keep
    expect_status 2 --modules slackexport --slack-export-root '/Users/User Space/slack_dump' --force
    [ -s "$dump/archive/slackdump.sqlite" ]
)
test_links_and_sidecars
printf 'PASS: linked roots, channels and database sidecars cannot redirect deletion; orphan WAL remains\n'

test_processes() (
    setup processes
    seed_standard "$STORE_HOME/export"
    # shellcheck disable=SC2034 # consumed by the sourced module function
    SLACK_EXPORT_ROOTS=('/Users/User Space/export')
    slack_exporters_stopped() { return 1; }
    module_slackexport
    [ "$FAILED_COUNT" -eq 1 ]
    [ -s "$STORE_HOME/export/users.json" ]
    unset -f slack_exporters_stopped
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    # shellcheck disable=SC2034 # consumed by the sourced process guards
    TEST_MODE=0
    ps() { printf '%s\n' "$PROCESS_LINE"; }
    local process
    for process in '/opt/bin/slackdump archive' 'python3 /Users/example/slack_dump/sync.py' '/tmp/slack-export --output /tmp/export' 'node /tmp/slack_sync.js'; do
        PROCESS_LINE="$process"
        if slack_exporters_stopped; then exit 1; fi
    done
    PROCESS_LINE='/bin/bash shredder.sh --modules slackexport --slack-export-root /Users/example/export'
    slack_exporters_stopped
    ps() { return 1; }
    if slack_exporters_stopped; then exit 1; fi
    lsof() { return 1; }
    slack_export_file_idle /fixture/database.sqlite
    lsof() { printf '1234\n'; return 0; }
    if slack_export_file_idle /fixture/database.sqlite; then exit 1; fi
    lsof() { printf 'inspection error\n' >&2; return 1; }
    if slack_export_file_idle /fixture/database.sqlite; then exit 1; fi
)
test_processes
printf 'PASS: exporters, sync scripts, open databases and failed process queries block Slack cleanup\n'
