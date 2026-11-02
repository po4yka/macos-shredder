#!/bin/bash
# Isolated scope tests and native command contracts. No live stores are purged.
# shellcheck disable=SC2034
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
setup() {
    # shellcheck source=shredder.sh
    source "$SCRIPT_DIR/../shredder.sh"
    TEST_MODE=1; SANDBOX="$WORK/$1"
    mkdir -p "$SANDBOX/Users/Test" "$SANDBOX/var/log" "$SANDBOX/var/audit"
    : > "$SANDBOX/.macos-shredder-test-root"
    resolve_paths
}
old_file() {
    mkdir -p "${1%/*}"
    printf 'retained-or-removed\n' > "$1"
    touch -t 202001010000 "$1"
}
(
    setup age
    LOGS_OLDER_THAN=7
    for file in system.log system.log.0 system.log.1.gz system.log.notes fsck_apfs.log; do
        old_file "$VAR_LOG/$file"
    done
    printf recent > "$VAR_LOG/system.log.2"
    old_file "$SANDBOX/Library/Logs/DiagnosticReports/old.ips"
    old_file "$SANDBOX/Library/Logs/DiagnosticReports/keep.data"
    old_file "$USERS_DIR/Test/Library/Logs/DiagnosticReports/old.crash"
    old_file "$VAR_AUDIT/20200101000000.20200102000000"
    old_file "$VAR_AUDIT/20200103000000.20200104000000"
    old_file "$VAR_AUDIT/20200105000000.not_terminated"
    old_file "$VAR_AUDIT/20200106000000.crash_recovery"
    old_file "$VAR_AUDIT/2020-not-a-trail"
    ln -s 20200103000000.20200104000000 "$VAR_AUDIT/current"
    cp -R "$SANDBOX" "$WORK/before-age"
    DRY_RUN=1; module_systemlogs; module_audit
    diff -r "$WORK/before-age" "$SANDBOX"
    DRY_RUN=0; module_systemlogs; module_audit
    [ "$FAILED_COUNT" -eq 0 ]
    for file in system.log system.log.notes system.log.2 fsck_apfs.log; do [ -s "$VAR_LOG/$file" ]; done
    [ ! -e "$VAR_LOG/system.log.0" ]; [ ! -e "$VAR_LOG/system.log.1.gz" ]
    [ ! -e "$SANDBOX/Library/Logs/DiagnosticReports/old.ips" ]
    [ -s "$SANDBOX/Library/Logs/DiagnosticReports/keep.data" ]
    [ ! -e "$USERS_DIR/Test/Library/Logs/DiagnosticReports/old.crash" ]
    [ ! -e "$VAR_AUDIT/20200101000000.20200102000000" ]
    [ -s "$VAR_AUDIT/current" ]
    [ -s "$VAR_AUDIT/20200105000000.not_terminated" ]
    [ -s "$VAR_AUDIT/20200106000000.crash_recovery" ]
    [ -s "$VAR_AUDIT/2020-not-a-trail" ]
)
printf 'PASS: log age, current/unknown file preservation and dry-run\n'
(
    setup handles
    old_file "$VAR_LOG/system.log.0"
    LOGS_OLDER_THAN=7; TEST_MODE=0
    removed=0
    remove_path() { removed=$((removed + 1)); }
    lsof() { printf '123\n'; }
    remove_aged_closed_log "$VAR_LOG/system.log.0"
    [ "$removed" -eq 0 ]
    lsof() { return 2; }
    remove_aged_closed_log "$VAR_LOG/system.log.0"
    [ "$removed" -eq 0 ]; [ "$FAILED_COUNT" -eq 1 ]
    lsof() { printf 'permission denied\n' >&2; return 1; }
    remove_aged_closed_log "$VAR_LOG/system.log.0"
    [ "$removed" -eq 0 ]; [ "$FAILED_COUNT" -eq 2 ]
    lsof() { return 1; }
    remove_aged_closed_log "$VAR_LOG/system.log.0"
    [ "$removed" -eq 1 ]
)
printf 'PASS: open log handle and handle-query failure refusal (command mocks)\n'
(
    setup events
    old_file "$DATA_VOLUME/.fseventsd/history"
    old_file "$SANDBOX/.fseventsd/legacy"
    old_file "$SANDBOX/Volumes/External/.fseventsd/history"
    ln -s "$DATA_VOLUME" "$SANDBOX/Volumes/Alias"
    if module_selected fsevents; then exit 1; fi
    module_fileevents
    [ -s "$DATA_VOLUME/.fseventsd/history" ]
    DRY_RUN=1; INCLUDE_VOLUMES=1; module_fsevents
    [ -s "$DATA_VOLUME/.fseventsd/history" ]
    DRY_RUN=0; INCLUDE_VOLUMES=0; module_fsevents
    [ ! -e "$DATA_VOLUME/.fseventsd/history" ]
    [ -s "$SANDBOX/.fseventsd/legacy" ]
    [ -s "$SANDBOX/Volumes/External/.fseventsd/history" ]
    INCLUDE_VOLUMES=1; module_fsevents
    [ ! -e "$SANDBOX/Volumes/External/.fseventsd/history" ]
)
printf 'PASS: quarantine/FSEvents split, Data volume, opt-in external scope and aliases\n'
(
    setup native-events
    mkdir -p "$DATA_VOLUME" "$SANDBOX/Volumes/External"
    volume="$SANDBOX/Volumes/External"
    TEST_MODE=0
    mock_mount="$volume"; mock_writable=true; mock_permissions=true; mock_fs=apfs; mock_device=22; mock_rc=0
    diskutil() { [ "$1" = info ] && [ "$2" = -plist ]; printf metadata; }
    plutil() {
        cat >/dev/null
        case "$2" in
            MountPoint) printf '%s' "$mock_mount" ;;
            WritableVolume) printf '%s' "$mock_writable" ;;
            GlobalPermissionsEnabled) printf '%s' "$mock_permissions" ;;
            FilesystemType) printf '%s' "$mock_fs" ;;
        esac
    }
    trash_stat_number() { if [ "$2" = "$DATA_VOLUME" ]; then printf 11; else printf '%s' "$mock_device"; fi; }
    osascript() { printf '%s\n' "$@" > "$WORK/api-args"; cat > "$WORK/api-source"; return "$mock_rc"; }
    DRY_RUN=1; fsevents_purge_volume "$volume" 1
    [ ! -e "$WORK/api-args" ]
    DRY_RUN=0; fsevents_purge_volume "$volume" 1
    [ "$CLEANED_COUNT" -eq 2 ]
    [ "$(cat "$WORK/api-args")" = $'-l\nJavaScript\n-\n22' ]
    grep -q 'FSEventsPurgeEventsForDeviceUpToEventId(device, eventId)' "$WORK/api-source"
    mock_rc=1; fsevents_purge_volume "$volume" 1
    [ "$FAILED_COUNT" -eq 1 ]; [ "$CLEANED_COUNT" -eq 2 ]
    # Invalid volume metadata must never reach the native purge command.
    # shellcheck disable=SC2329 # Invoked indirectly by the native wrapper.
    osascript() { printf 'unexpected API call\n' >&2; exit 90; }
    mock_writable=false; fsevents_purge_volume "$volume" 1
    mock_writable=true; mock_permissions=false; fsevents_purge_volume "$volume" 1
    mock_permissions=true; mock_mount="$volume/subdir"; fsevents_purge_volume "$volume" 1
    mock_mount="$volume"; mock_device=11; fsevents_purge_volume "$volume" 1
    mock_device=22; mock_fs=nfs; fsevents_purge_volume "$volume" 1
    [ "$FAILED_COUNT" -eq 6 ]
)
printf 'PASS: FSEvents native argument contract, failures and unsafe mount refusal (command mocks)\n'
for args in '--modules systemlogs,unified --logs-older-than 7' '--logs-older-than 7' '--modules systemlogs --logs-older-than 0' '--modules audit --logs-older-than=' '--modules browser --logs-older-than 3'; do
    rc=0
    # shellcheck disable=SC2086 # Intentional test argument splitting.
    bash "$SCRIPT_DIR/../shredder.sh" $args --dry-run --force >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 64 ]
done
printf 'PASS: invalid age scopes rejected before environment setup\n'
