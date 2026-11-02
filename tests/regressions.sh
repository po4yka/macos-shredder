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
