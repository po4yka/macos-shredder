#!/bin/bash
# Additional failure-path and cleanup regressions. All writes use a temporary root.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+rwx "$WORK"; rm -rf "$WORK"' EXIT

setup_case() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1
    SANDBOX="$SHREDDER_ROOT"
    resolve_paths
}

test_find_failure() (
    setup_case find-failure
    mkdir -p "$USERS_DIR/alice/Documents/blocked"
    printf 'keep\n' > "$USERS_DIR/alice/Documents/blocked/.DS_Store"
    # Simulate a partial traversal error without depending on the caller UID.
    # shellcheck disable=SC2329 # called by find_checked in the sourced script
    find() { printf '%s\0' "$USERS_DIR/alice/Documents/visible/.DS_Store"; return 1; }
    clean_dsstore_tree "$USERS_DIR/alice"
    [ "$FAILED_COUNT" -eq 1 ]
    [ -s "$USERS_DIR/alice/Documents/blocked/.DS_Store" ]
    unset -f find
    # Exercise an actual access denial when running as an ordinary user.
    if [ "$(id -u)" -ne 0 ]; then
        chmod 000 "$USERS_DIR/alice/Documents/blocked"
        local rc=0
        /bin/bash "$SHREDDER" --force --modules dsstore > "$WORK/denied.log" 2>&1 || rc=$?
        chmod 700 "$USERS_DIR/alice/Documents/blocked"
        [ "$rc" -eq 2 ]
        [ -s "$USERS_DIR/alice/Documents/blocked/.DS_Store" ]
    fi
)

test_find_failure
printf 'PASS: traversal failures are reported\n'

test_snapshot_listing() (
    setup_case snapshot-listing
    TEST_MODE=0
    # shellcheck disable=SC2329 # fault injection for purge_snapshots
    tmutil() { return 1; }
    purge_snapshots
    [ "$FAILED_COUNT" -eq 1 ]
    [ "$CLEANED_COUNT" -eq 0 ]
    FAILED_COUNT=0
    # shellcheck disable=SC2329 # empty, successful listing
    tmutil() { printf 'Snapshots for volume group containing disk /:\n'; }
    purge_snapshots
    [ "$FAILED_COUNT" -eq 0 ]
    [ "$CLEANED_COUNT" -eq 0 ]
    DRY_RUN=1
    # shellcheck disable=SC2329 # a valid listing; dry-run forbids deletion
    tmutil() { printf 'com.apple.TimeMachine.2026-11-02-100000.local\n'; }
    purge_snapshots
    [ "$CLEANED_COUNT" -eq 1 ]
)
test_snapshot_listing
printf 'PASS: snapshot listing errors differ from an empty list\n'

test_wifi_store() (
    setup_case wifi-store
    mkdir -p "$SYS_PREFS"
    printf 'known networks\n' > "$SYS_PREFS/com.apple.wifi.known-networks.plist"
    /bin/bash "$SHREDDER" --dry-run --modules wifi >/dev/null 2>&1
    grep -q '^known networks$' "$SYS_PREFS/com.apple.wifi.known-networks.plist"
    /bin/bash "$SHREDDER" --force --modules wifi >/dev/null 2>&1
    [ ! -e "$SYS_PREFS/com.apple.wifi.known-networks.plist" ]
)
test_wifi_store
printf 'PASS: current Wi-Fi store is removed only in a real run\n'

test_zsh_sessions() (
    setup_case zsh-sessions
    local sessions="$USERS_DIR/User Space/.zsh_sessions" name
    mkdir -p "$sessions"
    for name in session.history session.historynew session.session; do
        printf 'session trace\n' > "$sessions/$name"
    done
    /bin/bash "$SHREDDER" --dry-run --modules shell >/dev/null 2>&1
    for name in session.history session.historynew session.session; do
        grep -q '^session trace$' "$sessions/$name"
    done
    /bin/bash "$SHREDDER" --force --modules shell >/dev/null 2>&1
    [ -d "$sessions" ]
    [ -z "$(find "$sessions" -type f -print)" ]
)
test_zsh_sessions
printf 'PASS: zsh session histories are cleared\n'

test_log_rotations() (
    setup_case log-rotations
    local name
    mkdir -p "$VAR_LOG"
    for name in system.log system.log.0 install.log.2 wifi.log.1 system.log.notes system.log.3.keep; do
        printf 'log trace\n' > "$VAR_LOG/$name"
    done
    printf 'compressed trace\n' | gzip > "$VAR_LOG/system.log.1.gz"
    /bin/bash "$SHREDDER" --dry-run --modules systemlogs >/dev/null 2>&1
    gzip -t "$VAR_LOG/system.log.1.gz"
    [ -s "$VAR_LOG/system.log" ]
    /bin/bash "$SHREDDER" --force --modules systemlogs >/dev/null 2>&1
    [ ! -s "$VAR_LOG/system.log" ]
    for name in system.log.0 system.log.1.gz install.log.2 wifi.log.1; do
        [ ! -e "$VAR_LOG/$name" ]
    done
    [ -s "$VAR_LOG/system.log.notes" ]
    [ -s "$VAR_LOG/system.log.3.keep" ]
)
test_log_rotations
printf 'PASS: numbered log rotations are removed; unrelated files survive\n'

test_browser_cache_paths() (
    setup_case browser-caches
    local h="$USERS_DIR/User Space" product
    for product in Google/Chrome Chromium 'Microsoft Edge' BraveSoftware/Brave-Browser; do
        mkdir -p "$h/Library/Application Support/$product/Profile 1"
        mkdir -p "$h/Library/Caches/$product/Profile 1/Cache"
        printf 'cache trace\n' > "$h/Library/Caches/$product/Profile 1/Cache/entry"
    done
    mkdir -p "$h/Library/Application Support/Firefox/Profiles/custom"
    mkdir -p "$h/Library/Caches/Firefox/Profiles/custom/cache2"
    printf 'cache trace\n' > "$h/Library/Caches/Firefox/Profiles/custom/cache2/entry"
    /bin/bash "$SHREDDER" --dry-run --modules browser >/dev/null 2>&1
    [ "$(find "$h/Library/Caches" -type f | wc -l | tr -d ' ')" -eq 5 ]
    /bin/bash "$SHREDDER" --force --modules browser >/dev/null 2>&1
    [ -z "$(find "$h/Library/Caches" -type f -print)" ]
)
test_browser_cache_paths
printf 'PASS: macOS cache paths for all supported browsers are cleared\n'

test_browser_sidecars() (
    setup_case browser-sidecars
    local h="$USERS_DIR/alice" db suffix
    local chrome="$h/Library/Application Support/Google/Chrome/Default"
    local firefox="$h/Library/Application Support/Firefox/Profiles/custom"
    mkdir -p "$chrome" "$firefox" "$h/Library/Safari"
    for db in "$chrome/History" "$chrome/Cookies" "$chrome/Top Sites" "$chrome/Web Data" \
        "$firefox/cookies.sqlite" "$firefox/formhistory.sqlite" "$h/Library/Safari/History.db"; do
        for suffix in '' -wal -shm -journal; do
            printf 'trace\n' > "$db$suffix"
        done
    done
    printf 'preserve bookmark recovery\n' > "$firefox/places.sqlite-wal"
    /bin/bash "$SHREDDER" --dry-run --modules browser >/dev/null 2>&1
    [ -s "$chrome/Web Data-wal" ]
    /bin/bash "$SHREDDER" --force --modules browser >/dev/null 2>&1
    [ -z "$(find "$h" -type f ! -name places.sqlite-wal -print)" ]
    grep -q '^preserve bookmark recovery$' "$firefox/places.sqlite-wal"
)
test_browser_sidecars
printf 'PASS: browser database sidecars are removed; Places recovery survives\n'
