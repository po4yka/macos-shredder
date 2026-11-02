#!/bin/bash
# Real deadlines and signal escalation run only against marked fixtures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

run_case() {
    local mode="$1" root="$WORK/$1" log="$WORK/$1.log" rc=0 started="$SECONDS" state_dir pid state
    mkdir -p "$root/Users/alice/.Trash"
    : > "$root/.macos-shredder-test-root"
    printf 'history\n' > "$root/Users/alice/.bash_history"
    printf 'trash\n' > "$root/Users/alice/.Trash/entry"
    sqlite3 "$root/Users/alice/transaction.db" 'CREATE TABLE retained(value); INSERT INTO retained VALUES(1);'
    SHREDDER_ROOT="$root" /bin/bash -s -- "$SHREDDER" "$mode" > "$log" 2>&1 <<'DRIVER' || rc=$?
source "$1"
mode="$2"
# shellcheck disable=SC2329 # invoked by run_module
module_shell() {
    truncate_file "$USERS_DIR/alice/.bash_history"
    case "$mode" in
        healthy) printf 'visible stdout\n'; return 0 ;;
        term) sleep 30 ;;
        kill) trap '' TERM; sleep 30 ;;
        descendants)
            /bin/sh -c 'trap "" TERM; echo "$$" > "$1"; exec sleep 30' sh "$SANDBOX/descendant.pid" &
            sleep 30 ;;
        transaction)
            run_target_command "$USERS_DIR/alice/transaction.db" "$(command -v sqlite3)" "$USERS_DIR/alice/transaction.db" <<'SQL'
BEGIN IMMEDIATE;
DELETE FROM retained;
.shell sleep 30
COMMIT;
SQL
            ;;
        cancelled) kill -s TERM "$$"; sleep 30 ;;
    esac
    printf 'unsafe continuation\n' > "$SANDBOX/module-tail"
}
# shellcheck disable=SC2329 # invoked by main
purge_snapshots() {
    truncate_file "$USERS_DIR/alice/.bash_history"
    sleep 30
    printf 'unsafe continuation\n' > "$SANDBOX/snapshot-tail"
}
if [ "$mode" = snapshots ]; then
    main --force --modules trash --purge-snapshots --module-timeout=1 --timeout-grace=1
else
    main --force --modules shell,trash --module-timeout 1 --timeout-grace 1
fi
DRIVER
    local expected=2
    case "$mode" in healthy) expected=0 ;; cancelled) expected=143 ;; esac
    if [ "$rc" -ne "$expected" ]; then
        cat "$log"
        printf 'FAIL: %s returned %s, expected %s\n' "$mode" "$rc" "$expected" >&2
        return 1
    fi
    [ "$((SECONDS - started))" -lt 20 ]
    [ ! -s "$root/Users/alice/.bash_history" ]
    [ ! -e "$root/module-tail" ]
    [ ! -e "$root/snapshot-tail" ]
    for state_dir in "$root"/.shredder-step.*; do [ ! -e "$state_dir" ]; done
    if [ "$mode" = cancelled ]; then
        [ -s "$root/Users/alice/.Trash/entry" ]
        if grep -q 'timed out' "$log"; then return 1; fi
        return 0
    fi
    [ ! -e "$root/Users/alice/.Trash/entry" ]
    if [ "$mode" = healthy ]; then
        grep -q '^visible stdout$' "$log"
        grep -q 'Failed operations: 0$' "$log"
        if grep -q 'timed out' "$log"; then return 1; fi
    else
        grep -q 'timed out after 1s' "$log"
        grep -q 'Failed operations: 1$' "$log"
        if [ "$mode" != kill ]; then grep -q 'Total items cleaned: 2$' "$log"; fi
    fi
    if [ "$mode" = descendants ]; then
        pid="$(cat "$root/descendant.pid")"
        state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
        case "$state" in ''|Z*) ;; *) printf 'FAIL: timed-out descendant is still active\n' >&2; return 1 ;; esac
    fi
    if [ "$mode" = transaction ]; then
        [ "$(sqlite3 "$root/Users/alice/transaction.db" 'SELECT count(*) FROM retained;')" -eq 1 ]
    fi
}

for mode in term kill descendants transaction snapshots healthy cancelled; do
    run_case "$mode"
    printf 'PASS: cleanup timeout (%s)\n' "$mode"
done

test_options() (
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    [ "$MODULE_TIMEOUT" -eq 3600 ]
    [ "$TIMEOUT_GRACE" -eq 30 ]
    parse_args --module-timeout=7200 --timeout-grace 60
    [ "$MODULE_TIMEOUT" -eq 7200 ]
    [ "$TIMEOUT_GRACE" -eq 60 ]
    local option value rc
    for option in --module-timeout --timeout-grace; do
        for value in '' 0 01 -1 1.5 bad 9999999999999999999999999; do
            rc=0
            /bin/bash "$SHREDDER" "$option=$value" --list > /dev/null 2>&1 || rc=$?
            [ "$rc" -eq 64 ]
        done
        rc=0
        /bin/bash "$SHREDDER" "$option" > /dev/null 2>&1 || rc=$?
        [ "$rc" -eq 64 ]
    done
)
test_options
printf 'PASS: high defaults, configurable deadlines and invalid option refusal\n'

test_timer_cleanup() (
    export SHREDDER_ROOT="$WORK/timer-cleanup"
    mkdir -p "$SHREDDER_ROOT"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    detect_environment
    # A completed step must not wait for its one-hour timer or leave jobs.
    local pass started="$SECONDS"
    for pass in 1 2 3; do run_cleanup_step "healthy-$pass" true; done
    [ "$((SECONDS - started))" -lt 10 ]
    [ -z "$WATCHDOG_PID" ]
    [ -z "$CLEANUP_PID" ]
    [ -z "$(jobs -p)" ]
    [ "$FAILED_COUNT" -eq 0 ]
    # A failed watchdog setup must refuse the step before any target mutation.
    # shellcheck disable=SC2329 # invoked by run_cleanup_step
    mkfifo() { return 1; }
    run_cleanup_step no-watchdog touch "$SHREDDER_ROOT/unexpected"
    [ "$FAILED_COUNT" -eq 1 ]
    [ ! -e "$SHREDDER_ROOT/unexpected" ]
    local state_dir
    for state_dir in "$SHREDDER_ROOT"/.shredder-step.*; do [ ! -e "$state_dir" ]; done
)
test_timer_cleanup
printf 'PASS: watchdog cleanup and refusal on setup failure\n'
