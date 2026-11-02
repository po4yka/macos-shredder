#!/bin/bash
# Fault injection uses marked sandboxes and the real module dispatcher.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

run_case() {
    local mode="$1" rc=0 expected=2
    local root="$WORK/$mode" log="$WORK/$mode.log" state_dir
    mkdir -p "$root/Users/alice/.Trash"
    : > "$root/.macos-shredder-test-root"
    printf 'history\n' > "$root/Users/alice/.bash_history"
    printf 'trash\n' > "$root/Users/alice/.Trash/entry"
    SHREDDER_ROOT="$root" /bin/bash -s -- "$SHREDDER" "$mode" > "$log" 2>&1 <<'DRIVER' || rc=$?
source "$1"
mode="$2"
if [ "$mode" = state-init ]; then
    # shellcheck disable=SC2329 # invoked by run_cleanup_step
    mktemp() { return 1; }
fi
# shellcheck disable=SC2329 # invoked by run_module
module_shell() {
    truncate_file "$USERS_DIR/alice/.bash_history"
    printf 'module stdout remains visible\n'
    case "$mode" in
        command) false ;;
        pipeline) false | cat ;;
        return) return 7 ;;
        exit) exit 9 ;;
        early-success) exit 0 ;;
        unset) printf '%s\n' "$SHREDDER_UNSET_FOR_TEST" ;;
        redirect) printf 'cannot write\n' > "$SANDBOX/missing/file" ;;
        missing-state) trap - EXIT; exit 9 ;;
        handled) FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
        state) cd "$SANDBOX"; SELECTED_MODULES=shell; DRY_RUN=1 ;;
        interrupt) on_interrupt ;;
        signal-int) /bin/sh -c 'kill -s INT "$PPID"' ;;
        signal-term) /bin/sh -c 'kill -s TERM "$PPID"' ;;
        signal-hup) /bin/sh -c 'kill -s HUP "$PPID"' ;;
        parent-int) kill -s INT "$$"; sleep 0.2 ;;
        parent-term) kill -s TERM "$$"; sleep 0.2 ;;
        parent-hup) kill -s HUP "$$"; sleep 0.2 ;;
        multiple|dryrun) false ;;
        clean|snapshot) : ;;
    esac
    printf 'reached end\n' > "$SANDBOX/module-tail"
}
# shellcheck disable=SC2329 # invoked by run_module
module_systemlogs() {
    truncate_file "$USERS_DIR/alice/.bash_history"
    false
}
# shellcheck disable=SC2329 # invoked by main
purge_snapshots() {
    truncate_file "$USERS_DIR/alice/.bash_history"
    false
    printf 'unsafe continuation\n' > "$SANDBOX/snapshot-tail"
}
if [ "$mode" = snapshot ]; then
    main --force --modules trash --purge-snapshots
elif [ "$mode" = multiple ]; then
    main --force --modules shell,systemlogs,trash
elif [ "$mode" = dryrun ]; then
    main --dry-run --modules shell,trash
else
    main --force --modules shell,trash
fi
DRIVER
    case "$mode" in
        clean|state) expected=0 ;;
        interrupt|signal-int|parent-int) expected=130 ;;
        signal-term|parent-term) expected=143 ;;
        signal-hup|parent-hup) expected=129 ;;
    esac
    if [ "$rc" -ne "$expected" ]; then
        cat "$log"
        printf 'FAIL: %s returned %s, expected %s\n' "$mode" "$rc" "$expected" >&2
        return 1
    fi
    if [ "$mode" = state-init ]; then
        grep -q '^history$' "$root/Users/alice/.bash_history"
        grep -q '^trash$' "$root/Users/alice/.Trash/entry"
        grep -q 'Total items cleaned: 0$' "$log"
        grep -q 'Failed operations: 2$' "$log"
        return 0
    fi
    for state_dir in "$root"/.shredder-step.*; do
        [ ! -e "$state_dir" ]
    done
    if [ "$mode" = dryrun ]; then
        grep -q '^history$' "$root/Users/alice/.bash_history"
        grep -q '^trash$' "$root/Users/alice/.Trash/entry"
        grep -q 'Total items that would be cleaned: 2$' "$log"
        grep -q 'Failed operations: 1$' "$log"
        [ ! -e "$root/module-tail" ]
        return 0
    fi
    [ ! -s "$root/Users/alice/.bash_history" ]
    case "$mode" in
        interrupt|signal-*|parent-*)
            # Allow the child's foreground command to return after cancellation.
            sleep 0.3
            [ -s "$root/Users/alice/.Trash/entry" ]
            [ ! -e "$root/module-tail" ]
            if grep -q ' - summary' "$log"; then return 1; fi
            return 0 ;;
    esac
    [ ! -e "$root/Users/alice/.Trash/entry" ]
    grep -q ' - summary' "$log"
    case "$mode" in
        clean|state|handled) [ -s "$root/module-tail" ] ;;
        *) [ ! -e "$root/module-tail" ] ;;
    esac
    [ ! -e "$root/snapshot-tail" ]
    if [ "$mode" = missing-state ]; then
        grep -q 'Total items cleaned: 1$' "$log"
        grep -q 'counters unavailable' "$log"
    elif [ "$mode" = multiple ]; then
        grep -q 'Total items cleaned: 3$' "$log"
    else
        grep -q 'Total items cleaned: 2$' "$log"
    fi
    case "$mode" in
        clean|state) grep -q 'Failed operations: 0$' "$log" ;;
        multiple) grep -q 'Failed operations: 2$' "$log" ;;
        *) grep -q 'Failed operations: 1$' "$log" ;;
    esac
    if [ "$mode" != snapshot ]; then
        grep -q '^module stdout remains visible$' "$log"
    fi
}

for mode in command pipeline return exit early-success unset redirect missing-state handled state clean snapshot multiple dryrun state-init interrupt signal-int signal-term signal-hup parent-int parent-term parent-hup; do
    run_case "$mode"
    printf 'PASS: cleanup isolation (%s)\n' "$mode"
done
