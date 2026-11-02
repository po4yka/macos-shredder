#!/bin/bash
# Mounted-volume Trash tests. No host volume is modified.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+rwx "$WORK"; rm -rf "$WORK"' EXIT
setup() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    detect_environment
    USER_HOME="$USERS_DIR/User Space"
    TRASH_UID="$(id -u)"
    VOLUME="$SANDBOX/Volumes/External Disk"
    TRASH_PATH="$VOLUME/.Trashes/$TRASH_UID"
    mkdir -p "$TRASH_PATH/.hidden dir"
    printf 'trash\n' > "$TRASH_PATH/.hidden dir/file"
    printf 'trash\n' > "$TRASH_PATH/ordinary"
}
test_scope() (
    setup scope
    local other_uid=$((TRASH_UID + 1))
    mkdir -p "$VOLUME/.Trashes/$other_uid" "$VOLUME/Documents" "$USER_HOME/.Trash"
    printf 'keep\n' > "$VOLUME/.Trashes/$other_uid/other-user"
    printf 'keep\n' > "$VOLUME/Documents/source"
    printf 'home trash\n' > "$USER_HOME/.Trash/file"
    /bin/bash "$SHREDDER" --modules trash --force > "$WORK/last.log" 2>&1
    [ -s "$TRASH_PATH/ordinary" ]
    [ ! -e "$USER_HOME/.Trash/file" ]
    cp -R "$SANDBOX" "$WORK/before"
    /bin/bash "$SHREDDER" --modules trash --include-volumes --dry-run --debug > "$WORK/last.log" 2>&1
    diff -r "$WORK/before" "$SANDBOX"
    grep -q 'would empty mounted-volume Trash' "$WORK/last.log"
    ln -s "$VOLUME/Documents" "$TRASH_PATH/link"
    /bin/bash "$SHREDDER" --modules trash --include-volumes --force > "$WORK/last.log" 2>&1
    [ -d "$TRASH_PATH" ]
    [ -z "$(find "$TRASH_PATH" -mindepth 1 -print)" ]
    grep -q keep "$VOLUME/.Trashes/$other_uid/other-user"
    grep -q keep "$VOLUME/Documents/source"
    /bin/bash "$SHREDDER" --modules trash --include-volumes --force > "$WORK/last.log" 2>&1
)
test_scope
printf 'PASS: external Trash is opt-in, UID-scoped, repeatable and dry-run safe\n'

test_links() (
    setup links
    mv "$VOLUME/.Trashes" "$VOLUME/keep"
    ln -s "$VOLUME/keep" "$VOLUME/.Trashes"
    local rc=0
    /bin/bash "$SHREDDER" --modules trash --include-volumes --force > "$WORK/last.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    [ -s "$VOLUME/keep/$TRASH_UID/ordinary" ]
    rm "$VOLUME/.Trashes"
    mkdir "$VOLUME/.Trashes"
    ln -s "$VOLUME/keep/$TRASH_UID" "$TRASH_PATH"
    rc=0
    /bin/bash "$SHREDDER" --modules trash --include-volumes --force > "$WORK/last.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ]
    [ -s "$VOLUME/keep/$TRASH_UID/ordinary" ]
    rm "$TRASH_PATH"
    ln -s "$VOLUME" "$SANDBOX/Volumes/Alias"
    # A volume alias is ignored, including the usual startup-volume alias.
    /bin/bash "$SHREDDER" --modules trash --include-volumes --force > "$WORK/last.log" 2>&1
    [ -s "$VOLUME/keep/$TRASH_UID/ordinary" ]
)
test_links
printf 'PASS: Trash parent links and UID links cannot redirect deletion\n'

test_failures() (
    setup failures
    local real_uid="$TRASH_UID"
    # shellcheck disable=SC2329 # deterministic owner mismatch
    trash_stat_number() {
        if [ "$2" = "$TRASH_PATH" ]; then printf '%s\n' "$((real_uid + 1))";
        else printf '%s\n' "$real_uid"; fi
    }
    clean_volume_trash_for_home "$USER_HOME" "$real_uid"
    [ "$FAILED_COUNT" -eq 1 ]
    [ -s "$TRASH_PATH/ordinary" ]
    FAILED_COUNT=0
    # shellcheck disable=SC2329 # deterministic permission/read-only failure
    trash_stat_number() { printf '%s\n' "$real_uid"; }
    # shellcheck disable=SC2329 # verifies target is the known home owner
    run_target_command() { [ "$1" = "$USER_HOME/" ]; return 1; }
    clean_volume_trash_for_home "$USER_HOME" "$real_uid"
    [ "$FAILED_COUNT" -eq 1 ]
    [ -s "$TRASH_PATH/ordinary" ]
)
test_failures
printf 'PASS: owner mismatch and deletion errors are reported without fallback\n'

test_mount_filter() (
    setup mount-filter
    TEST_MODE=0
    # Test the native mount branch with fake metadata and a non-mutating wrapper.
    # No real host path or mount command is used.
    local distinct=0 calls=0
    # shellcheck disable=SC2329 # metadata injection for native branch
    trash_stat_number() {
        if [ "$1" = %u ]; then printf '501\n';
        elif [ "$2" = "$VOLUME" ] && [ "$distinct" -eq 1 ]; then printf '2\n';
        else printf '1\n'; fi
    }
    # shellcheck disable=SC2329 # non-mutating native execution spy
    run_target_command() { [ "$1" = "$USER_HOME/" ]; calls=$((calls + 1)); }
    mkdir -p "$VOLUME/.Trashes/501"
    clean_volume_trash_for_home "$USER_HOME" 501
    [ "$calls" -eq 0 ]
    distinct=1
    clean_volume_trash_for_home "$USER_HOME" 501
    [ "$calls" -eq 1 ]
    [ -s "$TRASH_PATH/ordinary" ]
)
test_mount_filter
printf 'PASS: native mode requires a separate mounted filesystem\n'
