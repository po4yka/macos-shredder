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

test_firefox_session() (
    setup_case firefox-session
    local h="$USERS_DIR/alice" prof
    prof="$h/Library/Application Support/Firefox/Profiles/custom"
    mkdir -p "$prof/sessionstore-backups"
    printf 'open tabs\n' > "$prof/sessionstore.jsonlz4"
    printf 'recovery tabs\n' > "$prof/sessionstore-backups/recovery.jsonlz4"
    # shellcheck disable=SC2329 # invoked by the sourced browser cleaner
    browser_running() { return 0; }
    clean_firefox_for_home "$h"
    [ -s "$prof/sessionstore.jsonlz4" ]
    [ -s "$prof/sessionstore-backups/recovery.jsonlz4" ]
    /bin/bash "$SHREDDER" --dry-run --modules browser >/dev/null 2>&1
    [ -s "$prof/sessionstore.jsonlz4" ]
    /bin/bash "$SHREDDER" --force --modules browser >/dev/null 2>&1
    [ ! -e "$prof/sessionstore.jsonlz4" ]
    [ ! -e "$prof/sessionstore-backups/recovery.jsonlz4" ]
)
test_firefox_session
printf 'PASS: Firefox sessions are cleared only while the browser is closed\n'

test_running_browser_status() (
    setup_case running-browser
    local h="$USERS_DIR/alice" path rc=0
    for path in 'Safari/History.db' 'Application Support/Google/Chrome/Default/History' \
        'Application Support/Firefox/Profiles/custom/cookies.sqlite'; do
        mkdir -p "${h}/Library/${path%/*}"
        printf 'active data\n' > "$h/Library/$path"
    done
    # shellcheck disable=SC2329 # deterministic running-process check for main
    browser_running() { return 0; }
    (main --force --modules browser) > "$WORK/running-browser.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    grep -q 'Failed operations: 3' "$WORK/running-browser.log"
    [ "$(find "$h" -type f | wc -l | tr -d ' ')" -eq 3 ]
    /bin/bash "$SHREDDER" --force --modules browser >/dev/null 2>&1
    [ -z "$(find "$h" -type f -print)" ]
)
test_running_browser_status
printf 'PASS: skipped active browsers return exit 2 without deleting their data\n'

test_trash_links() (
    setup_case trash-links
    local trash="$USERS_DIR/alice/.Trash" outside="$WORK/trash-outside" rc=0
    mkdir -p "$trash" "$outside/dir"
    printf 'keep\n' > "$outside/file"
    printf 'keep\n' > "$outside/dir/file"
    ln -s "$outside/file" "$trash/file-link"
    ln -s "$outside/dir" "$trash/dir-link"
    ln -s "$outside/missing" "$trash/broken-link"
    /bin/bash "$SHREDDER" --dry-run --modules trash >/dev/null 2>&1
    [ -L "$trash/broken-link" ]
    /bin/bash "$SHREDDER" --force --modules trash >/dev/null 2>&1
    [ -z "$(find "$trash" -mindepth 1 -print)" ]
    grep -q '^keep$' "$outside/file"
    grep -q '^keep$' "$outside/dir/file"
    rmdir "$trash"
    ln -s "$outside" "$trash"
    /bin/bash "$SHREDDER" --force --modules trash > "$WORK/trash-parent.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    grep -q '^keep$' "$outside/file"
)
test_trash_links
printf 'PASS: Trash links are unlinked; targets and linked parents are protected\n'

test_no_operation_logs() (
    setup_case no-operation-logs
    local logfile rc=0 mode option
    local h="$USERS_DIR/alice"
    mkdir -p "$h"
    # Each mode must leave no files other than the marker and retained target.
    for mode in dry-run debug list aborted real; do
        printf 'cleanup target\n' > "$h/.DS_Store"
        rc=0
        case "$mode" in
            dry-run) /bin/bash "$SHREDDER" --dry-run --modules dsstore >/dev/null 2>&1 || rc=$? ;;
            debug) /bin/bash "$SHREDDER" --force --debug --modules dsstore >/dev/null 2>&1 || rc=$? ;;
            list) /bin/bash "$SHREDDER" --list >/dev/null 2>&1 || rc=$? ;;
            aborted) /bin/bash "$SHREDDER" --modules dsstore </dev/null >/dev/null 2>&1 || rc=$? ;;
            real) /bin/bash "$SHREDDER" --force --modules dsstore >/dev/null 2>&1 || rc=$? ;;
        esac
        if [ "$mode" = aborted ]; then
            [ "$rc" -eq 1 ]
        else
            [ "$rc" -eq 0 ]
        fi
        case "$mode" in
            debug|real) [ ! -e "$h/.DS_Store" ] ;;
            *) grep -q '^cleanup target$' "$h/.DS_Store" ;;
        esac
        [ "$(find "$SANDBOX" -mindepth 1 ! -path "$USERS_DIR" ! -path "$h" \
            ! -path "$h/.DS_Store" -print)" = "$SANDBOX/.macos-shredder-test-root" ]
    done
    # Both spellings of the removed option must fail before any cleanup,
    # including dry-run and listing. Existing files must remain unchanged.
    printf 'preserve target\n' > "$h/.DS_Store"
    for mode in real dry-run list; do
        for option in --logfile --logfile=; do
            for logfile in "$SANDBOX/new.log" "$SANDBOX/existing.log"; do
                printf 'preserve log\n' > "$SANDBOX/existing.log"
                rc=0
                set -- --force --modules dsstore
                case "$mode" in dry-run) set -- "$@" --dry-run ;; list) set -- "$@" --list ;; esac
                case "$option" in
                    --logfile) set -- "$@" --logfile "$logfile" ;;
                    *) set -- "$@" "--logfile=$logfile" ;;
                esac
                /bin/bash "$SHREDDER" "$@" >/dev/null 2>&1 || rc=$?
                [ "$rc" -eq 64 ]
                [ ! -e "$SANDBOX/new.log" ]
                grep -q '^preserve log$' "$SANDBOX/existing.log"
                grep -q '^preserve target$' "$h/.DS_Store"
            done
        done
    done
    # Console helpers and interrupt handling must not write to an inherited
    # log descriptor, even if a caller exports the old logging variables.
    # shellcheck disable=SC2094 # intentional: the inherited log must stay empty
    (
        export LOGFILE="$WORK/inherited.log" LOGFILE_ARG="$WORK/inherited.log"
        # shellcheck disable=SC1090 # reload with legacy logging variables
        source "$SHREDDER"
        DEBUG=1
        log_info info; log_ok ok; log_warn warn; log_error error; log_debug debug
        warn_fda_missing
        on_interrupt
    ) 3> "$WORK/inherited.log" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 130 ]
    [ ! -s "$WORK/inherited.log" ]
)
test_no_operation_logs
printf 'PASS: no operation logs; removed logfile options fail before cleanup\n'

test_fixture_rebuild() (
    setup_case 'fixture rebuild'
    local pass profile_link="$SANDBOX/Users/alice/Library/Application Support/Chromium/Default"
    for pass in 1 2 3; do
        /bin/bash "$SCRIPT_DIR/create-artifacts.sh" "$SANDBOX" \
            --manifest "$WORK/rebuild-$pass.tsv" > "$WORK/rebuild-$pass.log"
    done
    cmp -s "$WORK/rebuild-1.tsv" "$WORK/rebuild-2.tsv"
    cmp -s "$WORK/rebuild-1.tsv" "$WORK/rebuild-3.tsv"
    [ "$(readlink "$profile_link")" = "$SANDBOX/escape-target/chromium-profile" ]
    [ "$(readlink "$SANDBOX/Users/mallory")" = "$SANDBOX/escape-target/mallory-home" ]
    [ ! -L "$SANDBOX/escape-target/chromium-profile/chromium-profile" ]
    [ ! -L "$SANDBOX/escape-target/mallory-home/mallory-home" ]
)
test_fixture_rebuild
printf 'PASS: three fixture builds produce identical files, directories, and links\n'

test_dsstore_volume_alias() (
    setup_case dsstore-alias
    mkdir -p "$USERS_DIR/alice/Documents" "$SANDBOX/Volumes/BACKUP"
    printf 'trace\n' > "$USERS_DIR/alice/Documents/.DS_Store"
    printf 'trace\n' > "$SANDBOX/Volumes/BACKUP/.DS_Store"
    mkdir -p "$SANDBOX/Library"
    printf 'startup disk\n' > "$SANDBOX/Library/.DS_Store"
    # macOS links /Volumes/Macintosh HD to the startup disk.
    ln -s "$SANDBOX" "$SANDBOX/Volumes/Macintosh HD"
    local rc=0
    /bin/bash "$SHREDDER" --force --include-volumes --modules dsstore \
        > "$WORK/dsstore-alias.log" 2>&1 || rc=$?
    [ "$rc" -eq 0 ]
    if grep -q 'refusing' "$WORK/dsstore-alias.log"; then return 1; fi
    [ ! -e "$USERS_DIR/alice/Documents/.DS_Store" ]
    [ ! -e "$SANDBOX/Volumes/BACKUP/.DS_Store" ]
    [ -s "$SANDBOX/Library/.DS_Store" ]
)
test_dsstore_volume_alias
printf 'PASS: dsstore volume scan skips the startup-disk alias\n'

test_volume_parent_race() (
    setup_case volume-race
    local outside="$WORK/volume-race-outside"
    mkdir -p "$SANDBOX/Volumes/USB/folder" "$outside"
    printf 'trace\n' > "$SANDBOX/Volumes/USB/folder/.DS_Store"
    printf 'keep\n' > "$outside/.DS_Store"
    # Replace the parent with a link after the guard has accepted it.
    # shellcheck disable=SC2329 # called by remove_path in the sourced script
    guard_mutation_target() {
        rm -rf "$SANDBOX/Volumes/USB/folder"
        ln -s "$outside" "$SANDBOX/Volumes/USB/folder"
        return 0
    }
    remove_path "$SANDBOX/Volumes/USB/folder/.DS_Store"
    [ -s "$outside/.DS_Store" ]
    [ "$FAILED_COUNT" -eq 1 ]
)
test_volume_parent_race
printf 'PASS: a replaced volume parent cannot redirect deletion\n'

test_process_checks_ignore_own_run() (
    setup_case own-process
    local bin="$WORK/own-process-bin"
    mkdir -p "$bin"
    # The run's own arguments name the terminal module and a Terminal folder.
    cat > "$bin/ps" <<'STUB'
#!/bin/sh
own='/bin/bash ./shredder.sh --modules terminal --terminal-log-file /Users/a/Terminal/x.log'
case "$*" in
    *'-axo pid=,ppid=,uid=,command='*)
        printf '%s 1 0 %s\n4243 %s 0 %s\n7 1 501 /usr/sbin/cfprefsd agent\n' \
            "$SHREDDER_TEST_SELF" "$own" "$SHREDDER_TEST_SELF" "$own" ;;
    *'-axo command='*) printf '%s\n/usr/sbin/cfprefsd agent\n' "$own" ;;
    *'-o ppid= -p'*) printf '1\n' ;;
esac
STUB
    chmod +x "$bin/ps"
    PATH="$bin:$PATH"
    export SHREDDER_TEST_SELF="$$"
    TEST_MODE=0
    terminal_clients_stopped 0
)
test_process_checks_ignore_own_run
printf 'PASS: process checks ignore the run'"'"'s own command line\n'

test_process_checks_scope_owner() (
    setup_case owner-process
    local bin="$WORK/owner-process-bin"
    mkdir -p "$bin"
    # Terminal and Finder run only in account 501.
    cat > "$bin/ps" <<'STUB'
#!/bin/sh
case "$*" in
    *'-axo pid=,ppid=,uid=,command='*)
        printf '11 1 501 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal\n'
        printf '12 1 501 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder\n' ;;
    *'-o ppid= -p'*) printf '1\n' ;;
esac
STUB
    chmod +x "$bin/ps"
    PATH="$bin:$PATH"
    TEST_MODE=0
    terminal_clients_stopped 502
    finder_history_clients_stopped 502
    if terminal_clients_stopped 501; then return 1; fi
    if finder_history_clients_stopped 501; then return 1; fi
    if terminal_clients_stopped ''; then return 1; fi
)
test_process_checks_scope_owner
printf 'PASS: per-account client checks ignore other accounts\n'

test_browser_history_side_stores() (
    setup_case browser-side-stores
    local h="$USERS_DIR/alice" path
    local chrome="$h/Library/Application Support/Google/Chrome/Default"
    local firefox="$h/Library/Application Support/Firefox/Profiles/custom"
    local safari="$h/Library/Safari"
    mkdir -p "$chrome/Network" "$firefox" "$safari/Favicon Cache" \
        "$safari/Profiles/ABC/Touch Icons Cache" "$h/Library/Cookies"
    for path in "$chrome/Favicons" "$chrome/Shortcuts" "$chrome/Network Action Predictor" \
        "$chrome/DIPS" "$chrome/Visited Links" "$chrome/Network/TransportSecurity" \
        "$chrome/Network/Network Persistent State" "$firefox/favicons.sqlite" \
        "$safari/Favicon Cache/icon" "$safari/Profiles/ABC/History.db" \
        "$safari/Profiles/ABC/Touch Icons Cache/icon" "$h/Library/Cookies/HSTS.plist"; do
        printf 'trace\n' > "$path"
    done
    printf 'keep\n' > "$chrome/Bookmarks"
    /bin/bash "$SHREDDER" --force --modules browser >/dev/null 2>&1
    [ -z "$(find "$h" -type f ! -name Bookmarks -print)" ]
    [ -s "$chrome/Bookmarks" ]
)
test_browser_history_side_stores
printf 'PASS: favicon, shortcut, HSTS and Safari profile history stores are removed\n'

test_fda_probe_lists_directory() (
    setup_case fda-probe
    mkdir -p "$USERS_DIR/alice/Library/Safari"
    # TCC lets stat() succeed but blocks reading entries.
    # shellcheck disable=SC2329 # called by probe_full_disk_access
    ls() { return 1; }
    if probe_full_disk_access; then return 1; fi
    unset -f ls
    probe_full_disk_access
)
test_fda_probe_lists_directory
printf 'PASS: the Full Disk Access probe reads directory entries\n'
