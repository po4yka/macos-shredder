#!/bin/bash
#
# macos-shredder - forensic-trace cleaner for macOS
# Copyright (c) 2026 Nikita Pochaev
# SPDX-License-Identifier: MIT
# See LICENSE for the full license text.
#
# Purpose:
#   Reduce the forensic footprint of a macOS system by clearing shell and
#   REPL histories, editor history, local AI sessions, system/audit logs,
#   browser site data and tab recovery, the unified log
#   store, quarantine/FSEvents artifacts, usage databases, Spotlight
#   indexes, Quick Look caches, Trash contents, .DS_Store files, Wi-Fi
#   network reminders, package-manager caches and application leftovers.
#   The standard selection contains 16 modules. Another 22 module IDs require
#   explicit selection. These include selected exports, document versions,
#   learned words, local application histories and manual deletion guidance.
#   Manual workflows do not perform cleanup and report incomplete real runs.
#   Flags add mounted-volume targets, shared browser extension data,
#   extended/derived AI data, cmux sessions and local Time Machine snapshots.
#   See README.md for retained stores and incomplete-cleanup behavior.
#
# Testability (sandbox mode):
#   Create .macos-shredder-test-root in a sandbox, then export
#   SHREDDER_ROOT=/path/to/sandbox to root EVERY filesystem target there.
#   In that mode the root-privilege check, Darwin OS check and Full Disk
#   Access probe are skipped. System-wide cleanup commands are skipped or
#   replaced by sandbox operations. Native plist/xattr tools can still act
#   on marked fixture files, including synthetic document versions. The native
#   spelling boundary refuses test mode. Required tools and unsafe data can cause
#   failures; sandbox mode does not imply that every operation will succeed.
#
# Exit codes:
#   0    success (or a dry-run completed)
#   1    fatal initialization error
#   2    one or more operations failed or were refused (also possible in dry-run)
#   64   usage error
#   130  interrupted by user (SIGINT)
#   129/143  stopped by SIGHUP/SIGTERM

SCRIPT_NAME="macos-shredder"
VERSION="1.0.0"
TEST_ROOT_MARKER=".macos-shredder-test-root"

set -eu
if (set -o pipefail 2>/dev/null); then
    set -o pipefail
fi

# Root runs must not resolve commands from a caller-controlled PATH. Sandbox
# tests keep their injected PATH, but their mutations are confined below the
# marked SHREDDER_ROOT.
if [ -z "${SHREDDER_ROOT:-}" ]; then
    PATH="/usr/bin:/bin:/usr/sbin:/sbin"
    export PATH
fi

###############################################################################
# SECTION: Global configuration
###############################################################################

DRY_RUN=0
DEBUG=0
FORCE=0
LIST_ONLY=0
INCLUDE_VOLUMES=0
LOGS_OLDER_THAN=""
INCLUDE_EXTENSION_DATA=0
PURGE_SNAPSHOTS=0
AI_DERIVED=0
AI_EXTENDED=0
TERMINAL_SESSIONS=0
TERMINAL_LOG_FILES=()
CLIPBOARD_INCLUDE_PINNED=0
CLIPBOARD_CURRENT=0
HEADLESS_DAYS=7
SLACK_EXPORT_ROOTS=()
METADATA_FILES=()
VERSION_FILES=()
SPELLING_WORDS=()
AI_ROOTS=()
AI_EXPORTS=()
TEST_RESULTS=()
DEVICE_BACKUPS=()
DIAGNOSTIC_EXPORTS=()
AI_CLAUDE_TMP_BASE=/private/tmp
TEST_MODE=0
MODULE_TIMEOUT=3600
TIMEOUT_GRACE=30

CLEANED_COUNT=0
FAILED_COUNT=0
CLEANUP_PID=""
CLEANUP_STATE_DIR=""
WATCHDOG_PID=""

MODULES_ARG=""
SELECTED_MODULES=""

# Every absolute filesystem target is derived from SANDBOX ("" on a real
# system). Never hardcode absolute paths anywhere else in this script.
SANDBOX=""
USERS_DIR=""
VAR_LOG=""
VAR_AUDIT=""
VAR_DB_DIAG=""
VAR_FOLDERS=""
SYS_PREFS=""
DATA_VOLUME=""
KNOWLEDGE_DB=""

# Canonical module registry. MODULE_IDS and MODULE_DESCS MUST stay aligned;
# every module id appears here, in run_module() dispatch AND in --list output.
MODULE_IDS=(
    shell
    systemlogs
    audit
    browser
    unified
    fileevents
    fsevents
    usage
    spotlight
    quicklook
    trash
    dsstore
    wifi
    brew
    apps
    editors
    ai
    clipboard
    headless
    slackexport
    terminal
    finderhistory
    filemetadata
    documentversions
    spelling
    notifications
    activity
    siri
    diagnosticexports
    devicebackups
    testresults
    aiexports
    mailhistory
    locationhistory
    callhistory
    messagehistory
    photometadata
    alfred
)
MODULE_DESCS=(
    "Shell and REPL histories, session data"
    "System logs and crash reports"
    "BSM audit logs"
    "Browser histories, site data and tab recovery"
    "Unified logging store"
    "Quarantine download event databases"
    "FSEvents per-volume history (explicit selection only)"
    "KnowledgeC usage db and recent items"
    "Spotlight index"
    "Quick Look thumbnail caches"
    "User Trash folders"
    ".DS_Store files"
    "Wi-Fi known networks and logs"
    "Homebrew caches and logs"
    "App caches and logs"
    "Editor local history and Vim/Neovim state"
    "Local AI agent and editor sessions"
    "Maccy clipboard history (explicit selection only)"
    "Old Chrome Headless profiles (explicit selection only)"
    "Selected local Slack exports (explicit selection only)"
    "Terminal saved output and selected logs (explicit selection only)"
    "Finder and Open/Save history keys (explicit selection only)"
    "Selected file origin metadata (explicit selection only)"
    "Previous versions of selected local documents (explicit only)"
    "Selected learned words in the active GUI account (explicit only)"
    "Delivered notification history (explicit selection only)"
    "Known activity stores; reports unsupported stores (explicit only)"
    "Siri and Dictation deletion instructions (manual action required)"
    "Selected completed diagnostic exports"
    "Selected completed unencrypted device backups"
    "Selected Xcode test result bundles"
    "Selected Apple Intelligence JSON reports"
    "Mail recipients and attachments (manual action required)"
    "Maps searches and significant locations (manual action required)"
    "Phone and FaceTime call history (manual action required)"
    "Messages and recently deleted attachments (manual action required)"
    "Photo location metadata (manual action required)"
    "Alfred clipboard deletion instructions (manual action required)"
)

# Color codes; filled by setup_colors(), left empty when colors are disabled.
COLOR_RESET=""
COLOR_BOLD=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""
COLOR_CYAN=""

###############################################################################
# SECTION: Colors and console output
###############################################################################

# Enable colors only for an interactive TTY that is not "dumb" and has not
# opted out via NO_COLOR. All color output goes through printf '%b'.
setup_colors() {
    if [ -t 1 ] && [ "${TERM:-}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
        COLOR_RESET=$'\033[0m'
        COLOR_BOLD=$'\033[1m'
        COLOR_RED=$'\033[1;31m'
        COLOR_GREEN=$'\033[1;32m'
        COLOR_YELLOW=$'\033[1;33m'
        COLOR_BLUE=$'\033[1;34m'
        COLOR_CYAN=$'\033[1;36m'
    fi
}

# Console loggers write to stderr so their output can never pollute the
# TAB-separated records produced by enumerate_users() inside process
# substitutions.
log_info() {
    printf '%b\n' "${COLOR_GREEN}[+]${COLOR_RESET} $*" >&2
}

log_ok() {
    printf '%b\n' "${COLOR_GREEN}[ok]${COLOR_RESET} $*" >&2
}

log_warn() {
    printf '%b\n' "${COLOR_YELLOW}[!]${COLOR_RESET} $*" >&2
}

log_error() {
    printf '%b\n' "${COLOR_RED}[x]${COLOR_RESET} $*" >&2
}

log_debug() {
    [ "$DEBUG" -eq 1 ] || return 0
    printf '%b\n' "${COLOR_BLUE}[dbg]${COLOR_RESET} $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# shellcheck disable=SC2329 # invoked by trap in main()
on_interrupt() {
    on_signal INT 130 "interrupted by user"
}

# cleanup_step_alive PID - succeed while the step process runs. An unreaped
# step is a zombie, which kill -0 still reports, so check its state.
cleanup_step_alive() {
    local state
    state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
    case "$state" in ''|Z*) return 1 ;; esac
    return 0
}

# Forward cancellation to the isolated step before the parent exits. A step
# can ignore the signal, or a command in it can catch the signal and exit
# normally. Wait briefly, then kill the step group, so that no cleanup
# continues after the parent reports that it stopped.
on_signal() {
    local signal="$1" status="$2" reason="$3" tries=0
    if [ -n "$CLEANUP_PID" ]; then
        kill -s "$signal" -- "-$CLEANUP_PID" 2>/dev/null || true
        while [ "$tries" -lt 10 ] && cleanup_step_alive "$CLEANUP_PID"; do
            sleep 0.1 2>/dev/null || break
            tries=$((tries + 1))
        done
        kill -s KILL -- "-$CLEANUP_PID" 2>/dev/null || true
        wait "$CLEANUP_PID" 2>/dev/null || true
    fi
    stop_cleanup_watchdog cancelled
    cleanup_step_state
    printf '%b\n' "${COLOR_YELLOW}[!]${COLOR_RESET} $reason; exiting" >&2 || true
    exit "$status"
}

###############################################################################
# SECTION: Safe operation helpers
#
# These helpers are the ONLY places where raw rm / truncate / sqlite
# mutations happen. They are DRY_RUN-aware, they emit debug detail when
# DEBUG=1, and they keep the global CLEANED_COUNT / FAILED_COUNT honest.
###############################################################################

# Refuse sandbox escapes and mutations through symlink components inside
# user-controlled homes and cache trees. System paths such as /var may be links.
guard_mutation_target() {
    local target="$1"
    local relative boundary cursor parent
    if [ "$TEST_MODE" -eq 1 ]; then
        case "$target" in
            "$SANDBOX"|"$SANDBOX"/*) boundary="$SANDBOX" ;;
            *)
                log_warn "refusing mutation outside sandbox: $target"
                [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
                return 1
                ;;
        esac
    else
        case "$target" in
            "$USERS_DIR"/*)
                relative="${target#"$USERS_DIR"/}"
                boundary="$USERS_DIR/${relative%%/*}"
                ;;
            "$VAR_FOLDERS"/*) boundary="$VAR_FOLDERS" ;;
            /Volumes/*) boundary="/Volumes" ;;
            *) return 0 ;;
        esac
    fi
    cursor="$target"
    while :; do
        if [ -L "$cursor" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_debug "[DRY RUN] would refuse path with symlink component: $target"
            else
                log_warn "refusing path with symlink component: $target"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 1
        fi
        [ "$cursor" = "$boundary" ] && return 0
        parent="${cursor%/*}"
        if [ "$parent" = "$cursor" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_debug "[DRY RUN] would refuse path outside mutation boundary: $target"
            else
                log_warn "refusing path outside mutation boundary: $target"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 1
        fi
        cursor="$parent"
    done
}

# Run home and per-user cache mutations as their owner. The path can change
# after guard_mutation_target() returns, so privilege reduction is the security
# boundary for symlink races; system targets keep the caller's root context.
run_target_command() {
    local target="$1"
    shift
    local relative owner_root bucket owner_uid current_uid stat_bin id_bin sudo_bin
    [ $# -gt 0 ] || return 1
    case "$target" in
        "$USERS_DIR"/*)
            relative="${target#"$USERS_DIR"/}"
            owner_root="$USERS_DIR/${relative%%/*}"
            ;;
        "$VAR_FOLDERS"/*)
            # macOS uses /var/folders/<bucket>/<user>/ for each cache owner.
            relative="${target#"$VAR_FOLDERS"/}"
            case "$relative" in */*/*) ;; *) return 1 ;; esac
            bucket="${relative%%/*}"
            relative="${relative#*/}"
            owner_root="$VAR_FOLDERS/$bucket/${relative%%/*}"
            ;;
        *) "$@"; return $? ;;
    esac
    if [ "$TEST_MODE" -eq 1 ]; then
        stat_bin="$(command -v stat 2>/dev/null || true)"
        id_bin="$(command -v id 2>/dev/null || true)"
        sudo_bin="$(command -v sudo 2>/dev/null || true)"
    else
        stat_bin="/usr/bin/stat"
        id_bin="/usr/bin/id"
        sudo_bin="/usr/bin/sudo"
    fi
    [ -x "$stat_bin" ] && [ -x "$id_bin" ] || return 1
    owner_uid="$("$stat_bin" -f '%u' "$owner_root" 2>/dev/null || true)"
    case "$owner_uid" in
        ''|*[!0-9]*)
            owner_uid="$("$stat_bin" -c '%u' "$owner_root" 2>/dev/null || true)"
            ;;
    esac
    case "$owner_uid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # A root-owned home is unexpected. Root's own /var/folders cache tree is
    # normal; only root can write there, so it keeps the root context.
    if [ "$TEST_MODE" -eq 0 ] && [ "$owner_uid" -eq 0 ]; then
        case "$target" in
            "$VAR_FOLDERS"/*) "$@"; return $? ;;
        esac
        log_warn "refusing root-owned user directory: $owner_root"
        return 1
    fi
    current_uid="$("$id_bin" -u)"
    if [ "$owner_uid" = "$current_uid" ]; then
        "$@"
        return $?
    fi
    [ -x "$sudo_bin" ] || return 1
    "$sudo_bin" -u "#$owner_uid" -- "$@"
}

# Pin the cache or volume parent as the working directory before deletion. A replacement
# with a symlink must fail the physical-path check. Later renames cannot redirect
# the relative rm operand to a different parent. Run this after dropping privileges.
remove_cache_entry() {
    local target="$1"
    local remove_flags="${2:--rf}"
    # shellcheck disable=SC2016 # variables expand in the owner-UID child shell
    run_target_command "$target" /bin/sh -c '
        parent=${1%/*}
        entry=${1##*/}
        cd -P "$parent" || exit 1
        [ "$(pwd -P)" = "$parent" ] || exit 1
        exec /bin/rm "$2" -- "./$entry"
    ' sh "$target" "$remove_flags"
}

# remove_path PATH - recursively delete a file/dir/symlink after an
# existence check. Broken symlinks are handled via the -L test.
remove_path() {
    local target="$1"
    local remove_flags=-rf
    if [ -z "$target" ]; then
        return 0
    fi
    if [ -L "$target" ]; then
        # Unlink the final component without following it. Its parents must
        # still pass the guard; -f also refuses a raced replacement directory.
        guard_mutation_target "${target%/*}" || return 0
        remove_flags=-f
    else
        guard_mutation_target "$target" || return 0
    fi
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        log_debug "not present, skipping: $target"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would remove: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    local result=0
    case "$target" in
        # Shared cache trees and other users' volumes stay writable by others.
        # Pin the physical parent so a raced link cannot redirect deletion.
        "$VAR_FOLDERS"/*|"$SANDBOX"/Volumes/*) remove_cache_entry "$target" "$remove_flags" 2>/dev/null || result=$? ;;
        *) run_target_command "$target" /bin/rm "$remove_flags" -- "$target" 2>/dev/null || result=$? ;;
    esac
    if [ "$result" -eq 0 ]; then
        log_debug "removed: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "failed to remove: $target"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# Remove an explicitly selected export or temporary-profile target. Pin the
# physical parent after dropping privileges and do not enter nested mounts.
selected_remove_path() {
    local target="$1"
    guard_mutation_target "$target" || return 0
    [ -e "$target" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would remove selected data: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    # shellcheck disable=SC2016
    if run_target_command "$target" /bin/sh -c '
        parent=${1%/*}; entry=${1##*/}
        cd -P "$parent" || exit 1
        [ "$(pwd -P)" = "$parent" ] || exit 1
        [ ! -L "./$entry" ] || exit 1
        if [ "$(uname -s)" = Darwin ]; then
            parent_device=$(stat -f %d .) || exit 1
            child_device=$(stat -f %d "./$entry") || exit 1
        else
            parent_device=$(stat -c %d .) || exit 1
            child_device=$(stat -c %d "./$entry") || exit 1
        fi
        [ "$parent_device" = "$child_device" ] || exit 1
        find "./$entry" -xdev -depth -delete
    ' sh "$target" >/dev/null 2>&1; then
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        log_debug "removed selected data: $target"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_warn "failed to remove selected data: $target"
    fi
    return 0
}

# count_failure_since BEFORE - count one failure for a refused operation,
# unless a helper (such as guard_mutation_target) already counted it after
# FAILED_COUNT was BEFORE. Dry-runs report refusals without counting them.
count_failure_since() {
    [ "$DRY_RUN" -eq 0 ] || return 0
    [ "$FAILED_COUNT" -ne "$1" ] || FAILED_COUNT=$((FAILED_COUNT + 1))
}

# remove_sqlite_db DB_FILE - remove a database and its rollback/WAL sidecars.
remove_sqlite_db() {
    local db="$1"
    local suffix
    [ -n "$db" ] || return 0
    for suffix in '' -wal -shm -journal; do
        remove_path "$db$suffix"
    done
}

# truncate_file PATH - empty an existing regular file in place.
truncate_file() {
    local target="$1"
    if [ -z "$target" ]; then
        return 0
    fi
    guard_mutation_target "$target" || return 0
    if [ ! -f "$target" ]; then
        log_debug "not a regular file, skipping: $target"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would truncate: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    # shellcheck disable=SC2016 # $1 expands inside the unprivileged child shell
    if run_target_command "$target" /bin/sh -c ': > "$1"' sh "$target" 2>/dev/null; then
        log_debug "truncated: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "failed to truncate: $target"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# clear_dir_contents DIR - empty a directory WITHOUT touching the directory
# itself. Enumeration uses find -print0 consumed via `read -d ''` inside a
# process substitution (keeps counters in the current shell). Never glob
# based, never quoted "*", and find -mindepth 1 also enumerates dotfiles,
# so hidden entries (.Trash/.foo) are covered correctly.
# A final empty NUL record reports a find failure to the consuming shell.
# Paths cannot be empty. This preserves NUL-safe streaming and parent counters.
find_checked() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if ! find "$@" 2>/dev/null; then
        log_warn "failed to enumerate all entries under: $1"
        printf '\0'
    fi
}

read_find_path() {
    local variable="$1"
    IFS= read -r -d '' "$variable" || return 1
    if [ -z "${!variable}" ]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
    return 0
}

clear_dir_contents() {
    local dir="$1"
    local p count=0
    if [ -z "$dir" ]; then
        log_debug "directory not present, skipping: <empty>"
        return 0
    fi
    guard_mutation_target "$dir" || return 0
    if [ ! -d "$dir" ]; then
        log_debug "directory not present, skipping: $dir"
        return 0
    fi
    if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
        log_warn "directory is not readable/searchable: $dir"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    while read_find_path p; do
        remove_path "$p"
        count=$((count + 1))
    done < <(find_checked "$dir" -mindepth 1 -maxdepth 1 -print0)
    if [ "$count" -eq 0 ]; then
        log_debug "nothing to clean in: $dir"
    fi
    return 0
}

# sqlite_purge DB_FILE SQL - run one SQL statement against an existing
# database file. Guarded by sqlite3 availability; failures are tolerated
# but counted honestly.
sqlite_purge() {
    local db="$1"
    local sql="$2"
    local sqlite_bin
    if [ -z "$db" ]; then
        log_debug "database not present, skipping: <empty>"
        return 0
    fi
    guard_mutation_target "$db" || return 0
    if [ ! -f "$db" ]; then
        log_debug "database not present, skipping: $db"
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    if [ -z "$sqlite_bin" ]; then
        log_warn "sqlite3 unavailable; removing the complete database instead: $db"
        remove_sqlite_db "$db"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would execute sqlite statement [$sql] on: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    # -init /dev/null keeps a user's ~/.sqliterc out of the statement.
    if run_target_command "$db" "$sqlite_bin" -batch -init /dev/null "$db" "$sql" >/dev/null 2>&1; then
        log_debug "sqlite ok [$sql]: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "sqlite failed [$sql]: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

###############################################################################
# SECTION: Environment detection and path resolution
###############################################################################

resolve_paths() {
    USERS_DIR="$SANDBOX/Users"
    VAR_LOG="$SANDBOX/var/log"
    VAR_AUDIT="$SANDBOX/var/audit"
    VAR_DB_DIAG="$SANDBOX/var/db/diagnostics"
    VAR_FOLDERS="$SANDBOX/private/var/folders"
    SYS_PREFS="$SANDBOX/Library/Preferences"
    DATA_VOLUME="$SANDBOX/System/Volumes/Data"
    KNOWLEDGE_DB="$SANDBOX/private/var/db/CoreDuet/Knowledge/knowledgeC.db"
}

detect_environment() {
    SANDBOX="${SHREDDER_ROOT:-}"
    if [ -n "$SANDBOX" ]; then
        case "$SANDBOX" in
            /*) ;;
            *) die "SHREDDER_ROOT must be an absolute path" ;;
        esac
        if [ ! -d "$SANDBOX" ] || [ -L "$SANDBOX" ]; then
            die "SHREDDER_ROOT must be an existing, non-symlink directory"
        fi
        SANDBOX="$(cd "$SANDBOX" && pwd -P)"
        case "$SANDBOX" in
            /|/System|/Library|/Users|/private|/var)
                die "unsafe SHREDDER_ROOT refused: $SANDBOX"
                ;;
        esac
        if [ ! -f "$SANDBOX/$TEST_ROOT_MARKER" ]; then
            die "SHREDDER_ROOT is missing required marker: $TEST_ROOT_MARKER"
        fi
        TEST_MODE=1
        log_debug "test mode active: SHREDDER_ROOT='$SANDBOX'"
        log_debug "test mode: privilege, OS and Full Disk Access checks disabled"
    else
        TEST_MODE=0
        local kernel
        kernel="$(uname -s)"
        if [ "$kernel" != "Darwin" ]; then
            die "unsupported operating system '$kernel': this tool requires macOS"
        fi
        log_debug "real mode: Darwin detected; paths rooted at /"
    fi
    resolve_paths
}

###############################################################################
# SECTION: User enumeration and per-user execution
#
# macOS users live in Directory Services, NOT in /etc/passwd, so real-mode
# enumeration must use dscl. Output format: name<TAB>homedir<TAB>uid.
# Consumers MUST read via `while IFS=$'\t' read -r u h uid`; never iterate
# unquoted variables (usernames may contain spaces).
###############################################################################

# Fallback enumerator: scan the users directory directly. Skips Shared,
# Guest and dot-directories; uid field is empty.
emit_dir_users() {
    local d base
    for d in "$USERS_DIR"/*/; do
        d="${d%/}"
        [ -d "$d" ] || continue
        if [ -L "$d" ]; then
            log_warn "skipping symlinked user home: $d"
            continue
        fi
        base="${d%/}"
        base="${base##*/}"
        case "$base" in
            Shared|Guest) continue ;;
            .*) continue ;;
        esac
        printf '%s\t%s\t%s\n' "$base" "$d" ""
    done
}

enumerate_users() {
    if [ "$TEST_MODE" -eq 1 ]; then
        emit_dir_users
        return 0
    fi
    if command -v dscl >/dev/null 2>&1; then
        local emitted=0 u h uid record
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            case "$u" in _*) continue ;; esac
            record="$(dscl . -read "/Users/$u" NFSHomeDirectory UniqueID 2>/dev/null || true)"
            h="$(printf '%s\n' "$record" | sed -n 's/^NFSHomeDirectory: //p' | head -n 1)"
            uid="$(printf '%s\n' "$record" | sed -n 's/^UniqueID: //p' | head -n 1)"
            case "$h" in /Users/*) ;; *) continue ;; esac
            [ -d "$h" ] && [ ! -L "$h" ] || continue
            printf '%s\t%s\t%s\n' "$u" "$h" "$uid"
            emitted=1
        done < <(dscl . -list /Users 2>/dev/null)
        if [ "$emitted" -eq 1 ]; then
            return 0
        fi
        log_debug "dscl returned no regular users; falling back to directory scan"
    else
        log_debug "dscl unavailable; falling back to directory scan"
    fi
    emit_dir_users
}

# run_as_user USER UID HOME CMD... - run a per-user command in the real user's
# context. Sandbox mode refuses host commands; modules must use fixture-only
# fallbacks there.
run_as_user() {
    local user="$1"
    local uid="$2"
    local home="$3"
    shift 3
    [ $# -gt 0 ] || return 0
    if [ "$TEST_MODE" -eq 1 ]; then
        log_debug "test mode: refusing host command for user '$user': $1"
        return 1
    fi
    if [ -n "$uid" ] && command -v launchctl >/dev/null 2>&1; then
        if launchctl asuser "$uid" sudo -u "$user" env HOME="$home" "$@" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -u "$user" env HOME="$home" "$@" >/dev/null 2>&1
        return $?
    fi
    log_debug "cannot run command as user '$user': launchctl/sudo unavailable"
    return 1
}

# process_list FIELD [UID] - print the process table as command lines
# (FIELD=command) or executable paths (FIELD=comm). Omit this run, its
# subshells and the processes that started it: sudo, plain shells, and any
# wrapper whose command line names this script. Their arguments can name
# modules and paths that look like client processes. With a non-root UID,
# drop other accounts' processes but keep root's: system daemons can also
# write per-account stores. An empty UID or UID 0 keeps every account.
process_list() {
    local field="$1" uid="${2:-}" pid comm command exclude=" " script="${BASH_SOURCE[0]##*/}"
    case "$field" in command|comm) ;; *) return 1 ;; esac
    pid="$(ps -o ppid= -p "$$" 2>/dev/null | tr -d '[:space:]')" || pid=""
    while :; do
        case "$pid" in ''|*[!0-9]*) break ;; esac
        [ "$pid" -gt 1 ] || break
        comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || break
        command="$(ps -o command= -p "$pid" 2>/dev/null)" || command=""
        case "${comm##*/}" in
            bash|sh|sudo) exclude="$exclude$pid " ;;
            *)
                case "$command" in
                    *"$script"*) exclude="$exclude$pid " ;;
                    *) break ;;
                esac
                ;;
        esac
        pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || break
    done
    # One -o option per column: POSIX ps reads the rest of "pid=,..." as a header.
    ps -ax -o pid= -o ppid= -o uid= -o "$field=" 2>/dev/null \
        | SHREDDER_PS_EXCLUDE="$exclude" SHREDDER_PS_UID="$uid" SHREDDER_PS_SELF="$$" awk '
            BEGIN {
                ex = ENVIRON["SHREDDER_PS_EXCLUDE"]
                u = ENVIRON["SHREDDER_PS_UID"]
                self = ENVIRON["SHREDDER_PS_SELF"]
            }
            {
                n++
                if ($1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/) {
                    pid[n] = $1; ppid[$1] = $2; owner[n] = $3; line = $0
                    sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]*/, "", line)
                    text[n] = line
                } else {
                    pid[n] = ""; owner[n] = ""; text[n] = $0
                }
            }
            END {
                for (i = 1; i <= n; i++) {
                    p = pid[i]
                    if (p != "") {
                        if (index(ex, " " p " ")) continue
                        mine = 0; q = p; hops = 0
                        while (q != "" && q + 0 > 1 && hops < 256) {
                            if (q == self) { mine = 1; break }
                            q = ppid[q]; hops++
                        }
                        if (mine) continue
                        if (u != "" && u != "0" && owner[i] != u && owner[i] != "0") continue
                    }
                    print text[i]
                }
            }'
}

# process_match FLAGS PATTERN TABLE - succeed when a line of TABLE matches.
# Use a pipe, not a here-string: Bash 3.2 backs here-strings with a temporary
# file, and a failure to create it would make the check report no client.
# grep can exit at the first match, so the writer's SIGPIPE is ignored. Any
# grep result other than "no match" counts as a match (fail closed).
process_match() {
    local rc=0
    printf '%s\n' "$3" | grep "$1" -- "$2" >/dev/null 2>&1 || rc="${PIPESTATUS[1]}"
    [ "$rc" -ne 1 ]
}

# home_uid HOME [UID] - print the account UID of HOME. Directory-service UIDs
# win; the fallback enumerator has none, so read the home owner instead.
home_uid() {
    local home="$1" uid="${2:-}" value
    case "$uid" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$uid"; return 0 ;;
    esac
    value="$(stat -f %u "$home" 2>/dev/null || true)"
    case "$value" in ''|*[!0-9]*) value="$(stat -c %u "$home" 2>/dev/null || true)" ;; esac
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

# A failed process query blocks browser mutations just like a running browser.
browser_running() {
    local proc="$1" rc=0
    [ "$TEST_MODE" -eq 0 ] || return 1
    if ! command -v pgrep >/dev/null 2>&1; then
        log_warn "cannot inspect browser processes; cleanup refused"
        return 0
    fi
    pgrep -x "$proc( Helper.*)?" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) log_warn "browser process query failed; cleanup refused"; return 0 ;;
    esac
}

###############################################################################
# SECTION: CLI parsing, usage and module listing
###############################################################################

usage() {
    cat <<EOF
${SCRIPT_NAME} v${VERSION} - macOS forensic-trace cleaner

Usage: ${SCRIPT_NAME} [options]

Options:
  -h, --help            Show this help text and exit
  -v, --version         Print version information and exit
  -n, --dry-run         Preview only: report what would be cleaned, change nothing
  -d, --debug           Enable verbose debug output
  -l, --list            List available modules and exit
  -m, --modules IDS     Comma-separated module ids (default: standard modules).
                        See '--list' for valid ids; unknown ids are rejected.
  -f, --force           Do not ask for confirmation (auto-answer yes)
      --module-timeout N
                        Limit each module/snapshot step to N seconds (default 3600)
      --timeout-grace N Allow N seconds after SIGTERM before SIGKILL (default 30)
      --include-volumes Include mounted-volume Trash, FSEvents and .DS_Store
                        targets when their modules are selected
      --include-extension-data
                        Also delete mixed website/extension storage. This can
                        reset extension settings and extension sign-ins.
      --logs-older-than N
                        Keep active logs and files modified in the last N days;
                        requires systemlogs/audit without unified
      --purge-snapshots Delete local Time Machine snapshots before selected modules
      --ai-derived     Also remove AI memory, plans and generated artifacts
      --ai-extended    Include Gemini, Antigravity, desktop AI and plugin traces
      --terminal-sessions
                        Include cmux session history in the shell module
      --terminal-log-file PATH
                        Select one terminal output log below /Users/<user>/.
                        Requires --modules terminal; repeat for more files.
      --clipboard-include-pinned
                        Also clear pinned Maccy history items
      --clipboard-current
                        Also clear the active console user's current clipboard
      --headless-days N Keep Chrome Headless profiles newer than N days (default 7)
      --slack-export-root PATH
                        Select a local export directory below /Users/<user>/.
                        Requires --modules slackexport; repeat for more roots.
      --metadata-file PATH
                        Clear origin metadata on one file below /Users/<user>/.
                        Requires --modules filemetadata; repeat for more files.
      --diagnostic-export PATH
                        Select one completed sysdiagnose archive or .logarchive.
                        Requires diagnosticexports; repeat for more exports.
      --device-backup PATH
                        Selected completed unencrypted device backups.
                        Requires devicebackups; repeat for more paths.
      --test-result PATH
                        Selected Xcode test result bundles.
                        Requires testresults; repeat for more paths.
      --ai-export PATH
                        Selected Apple Intelligence JSON reports.
                        Requires aiexports; repeat for more paths.
      --version-file PATH
                        Remove previous versions of one local file; retain its contents.
                        Requires --modules documentversions; repeat for more files.
      --spelling-word WORD
                        Unlearn one selected word in the active GUI account.
                        Requires --modules spelling; repeat for more words.
      --ai-root KIND=PATH
                        Add an AI storage location below /Users/<user>/.
                        Kinds: claude, codex, codex-db, opencode,
                        opencode-state, opencode-db, claude-temp.
                        Also: cursor, cursor-editor, windsurf, editor,
                        continue, cline, roo, aider, aider-history.
                        Repeat for multiple locations; defaults are also cleaned.

Scope:
  Per-user modules process eligible homes under /Users, not just the caller.
  Close the clients listed in README.md before cleanup. --force skips only
  confirmation; it does not bypass process, path or database checks.
  A dry-run does not validate mixed SQLite schemas or prove secure erasure.
  notifications/activity require offline stores; siri/alfred print manual steps.
  Unsupported activity stores remain intact and real runs report exit 2.
  Modules labelled manual action required only print guidance and report
  incomplete cleanup on real runs; use --dry-run to read their instructions.

Environment:
  SHREDDER_ROOT         When set, every filesystem target is rooted under this
                        marked test directory. Privilege, OS and Full Disk
                        Access checks are skipped in sandbox mode.

Exit codes:
  0 success   1 fatal error   2 failed operations   64 usage error   130 interrupted
EOF
}

print_module_list() {
    local i=0
    while [ "$i" -lt "${#MODULE_IDS[@]}" ]; do
        printf '  %-12s %s\n' "${MODULE_IDS[$i]}" "${MODULE_DESCS[$i]}"
        i=$((i + 1))
    done
}

usage_error() {
    printf '%b\n' "${COLOR_RED}usage error:${COLOR_RESET} $1" >&2
    printf '%b\n' "Run '${SCRIPT_NAME} --help' for usage." >&2
    exit 64
}

# parse_modules LIST - lowercase via tr, strip whitespace, split on commas
# and EXACT-match every id against the whitelist (no substring matching).
parse_modules() {
    local raw="$1"
    local lowered entry found id
    lowered="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [ -z "$lowered" ]; then
        usage_error "--modules requires a non-empty comma-separated list of module ids"
    fi
    local parts=()
    IFS=',' read -r -a parts <<< "$lowered"
    SELECTED_MODULES=""
    for entry in "${parts[@]}"; do
        if [ -z "$entry" ]; then
            usage_error "empty module id in module list: '$raw'"
        fi
        found=0
        for id in "${MODULE_IDS[@]}"; do
            if [ "$entry" = "$id" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            printf '%b\n' "${COLOR_RED}unknown module:${COLOR_RESET} '$entry'" >&2
            printf '%b\n' "valid module ids:" >&2
            print_module_list >&2
            exit 64
        fi
        case ",$SELECTED_MODULES," in
            *",$entry,"*) : ;;
            *) SELECTED_MODULES="${SELECTED_MODULES:+${SELECTED_MODULES},}${entry}" ;;
        esac
    done
    log_debug "selected modules: ${SELECTED_MODULES:-all}"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"
                exit 0
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -d|--debug)
                DEBUG=1
                shift
                ;;
            -l|--list)
                LIST_ONLY=1
                shift
                ;;
            -f|--force)
                FORCE=1
                shift
                ;;
            --module-timeout)
                [ $# -ge 2 ] || usage_error "--module-timeout requires seconds"
                MODULE_TIMEOUT="$2"; shift 2
                ;;
            --module-timeout=*) MODULE_TIMEOUT="${1#*=}"; shift ;;
            --timeout-grace)
                [ $# -ge 2 ] || usage_error "--timeout-grace requires seconds"
                TIMEOUT_GRACE="$2"; shift 2
                ;;
            --timeout-grace=*) TIMEOUT_GRACE="${1#*=}"; shift ;;
            -m|--modules)
                if [ $# -lt 2 ]; then
                    usage_error "option '$1' requires an argument"
                fi
                if [ -z "$2" ]; then
                    usage_error "option '$1' requires a non-empty argument"
                fi
                MODULES_ARG="$2"
                shift 2
                ;;
            --modules=*)
                MODULES_ARG="${1#*=}"
                if [ -z "$MODULES_ARG" ]; then
                    usage_error "option '--modules' requires a non-empty argument"
                fi
                shift
                ;;
            --logs-older-than)
                [ $# -ge 2 ] || usage_error "--logs-older-than requires days"
                LOGS_OLDER_THAN="$2"; shift 2
                case "$LOGS_OLDER_THAN" in ''|*[!0-9]*|0*|??????*) usage_error "--logs-older-than must be between 1 and 99999" ;; esac
                ;;
            --logs-older-than=*)
                LOGS_OLDER_THAN="${1#*=}"; shift
                case "$LOGS_OLDER_THAN" in ''|*[!0-9]*|0*|??????*) usage_error "--logs-older-than must be between 1 and 99999" ;; esac
                ;;
            --include-volumes)
                INCLUDE_VOLUMES=1
                shift
                ;;
            --include-extension-data)
                INCLUDE_EXTENSION_DATA=1
                shift
                ;;
            --purge-snapshots)
                PURGE_SNAPSHOTS=1
                shift
                ;;
            --ai-derived)
                AI_DERIVED=1
                shift
                ;;
            --ai-extended) AI_EXTENDED=1; shift ;;
            --terminal-sessions) TERMINAL_SESSIONS=1; shift ;;
            --terminal-log-file)
                [ $# -ge 2 ] || usage_error "--terminal-log-file requires a file"
                add_terminal_log_file "$2"; shift 2
                ;;
            --terminal-log-file=*) add_terminal_log_file "${1#*=}"; shift ;;
            --clipboard-include-pinned) CLIPBOARD_INCLUDE_PINNED=1; shift ;;
            --clipboard-current) CLIPBOARD_CURRENT=1; shift ;;
            --headless-days)
                [ $# -ge 2 ] || usage_error "--headless-days requires a positive integer"
                HEADLESS_DAYS="$2"; shift 2
                ;;
            --headless-days=*) HEADLESS_DAYS="${1#*=}"; shift ;;
            --slack-export-root)
                [ $# -ge 2 ] || usage_error "--slack-export-root requires a directory"
                add_slack_export_root "$2"; shift 2
                ;;
            --slack-export-root=*) add_slack_export_root "${1#*=}"; shift ;;
            --metadata-file)
                [ $# -ge 2 ] || usage_error "--metadata-file requires a file"
                add_metadata_file "$2"; shift 2
                ;;
            --metadata-file=*) add_metadata_file "${1#*=}"; shift ;;
            --diagnostic-export)
                [ $# -ge 2 ] || usage_error "--diagnostic-export requires a path"
                add_selected_artifact diagnosticexports "$2"; shift 2 ;;
            --diagnostic-export=*) add_selected_artifact diagnosticexports "${1#*=}"; shift ;;
            --device-backup)
                [ $# -ge 2 ] || usage_error "--device-backup requires a path"
                add_selected_artifact devicebackups "$2"; shift 2 ;;
            --device-backup=*) add_selected_artifact devicebackups "${1#*=}"; shift ;;
            --test-result)
                [ $# -ge 2 ] || usage_error "--test-result requires a path"
                add_selected_artifact testresults "$2"; shift 2 ;;
            --test-result=*) add_selected_artifact testresults "${1#*=}"; shift ;;
            --ai-export)
                [ $# -ge 2 ] || usage_error "--ai-export requires a path"
                add_selected_artifact aiexports "$2"; shift 2 ;;
            --ai-export=*) add_selected_artifact aiexports "${1#*=}"; shift ;;
            --version-file)
                [ $# -ge 2 ] || usage_error "--version-file requires a file"
                add_version_file "$2"; shift 2
                ;;
            --version-file=*) add_version_file "${1#*=}"; shift ;;
            --spelling-word)
                [ $# -ge 2 ] || usage_error "--spelling-word requires a word"
                add_spelling_word "$2"; shift 2
                ;;
            --spelling-word=*) add_spelling_word "${1#*=}"; shift ;;
            --ai-root)
                [ $# -ge 2 ] || usage_error "--ai-root requires KIND=PATH"
                add_ai_root "$2"
                shift 2
                ;;
            --ai-root=*)
                add_ai_root "${1#*=}"
                shift
                ;;
            --)
                shift
                if [ $# -gt 0 ]; then
                    usage_error "unexpected positional arguments: $*"
                fi
                ;;
            *)
                usage_error "unknown option: $1"
                ;;
        esac
    done
    case "$MODULE_TIMEOUT" in ''|*[!0-9]*|0*|??????*) usage_error "--module-timeout must be between 1 and 99999 seconds" ;; esac
    case "$TIMEOUT_GRACE" in ''|*[!0-9]*|0*|??????*) usage_error "--timeout-grace must be between 1 and 99999 seconds" ;; esac
    if [ -n "$MODULES_ARG" ]; then
        parse_modules "$MODULES_ARG"
    fi
    if [ "${#TERMINAL_LOG_FILES[@]}" -gt 0 ] && ! module_selected terminal; then
        usage_error "--terminal-log-file requires explicit --modules terminal"
    fi
    if [ -n "$LOGS_OLDER_THAN" ]; then
        module_selected unified && usage_error "--logs-older-than cannot select unified: log erase has no age filter"
        if ! module_selected systemlogs && ! module_selected audit; then
            usage_error "--logs-older-than requires systemlogs or audit"
        fi
    fi
    if module_selected filemetadata; then
        [ "${#METADATA_FILES[@]}" -gt 0 ] || usage_error "filemetadata requires --metadata-file"
    elif [ "${#METADATA_FILES[@]}" -gt 0 ]; then
        usage_error "--metadata-file requires explicit --modules filemetadata"
    fi
    validate_selected_artifact_options diagnosticexports diagnostic-export "${#DIAGNOSTIC_EXPORTS[@]}"
    validate_selected_artifact_options devicebackups device-backup "${#DEVICE_BACKUPS[@]}"
    validate_selected_artifact_options testresults test-result "${#TEST_RESULTS[@]}"
    validate_selected_artifact_options aiexports ai-export "${#AI_EXPORTS[@]}"
    if module_selected documentversions; then
        [ "${#VERSION_FILES[@]}" -gt 0 ] || usage_error "documentversions requires --version-file"
    elif [ "${#VERSION_FILES[@]}" -gt 0 ]; then
        usage_error "--version-file requires explicit --modules documentversions"
    fi
    if module_selected spelling; then
        [ "${#SPELLING_WORDS[@]}" -gt 0 ] || usage_error "spelling requires --spelling-word"
    elif [ "${#SPELLING_WORDS[@]}" -gt 0 ]; then
        usage_error "--spelling-word requires explicit --modules spelling"
    fi
    case "$HEADLESS_DAYS" in ''|*[!0-9]*|0*|??????*) usage_error "--headless-days must be between 1 and 99999" ;; esac
    if module_selected slackexport; then
        [ "${#SLACK_EXPORT_ROOTS[@]}" -gt 0 ] || usage_error "slackexport requires --slack-export-root"
    elif [ "${#SLACK_EXPORT_ROOTS[@]}" -gt 0 ]; then
        usage_error "--slack-export-root requires explicit --modules slackexport"
    fi
}

###############################################################################
# SECTION: Privilege check, FDA probe and confirmation
###############################################################################

check_privileges() {
    # Skipped for dry-runs and in sandbox/test mode.
    if [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        if [ "$(id -u)" -ne 0 ]; then
            die "root privileges are required for a real cleaning run; re-run with sudo or use --dry-run"
        fi
    fi
}

# probe_full_disk_access - list the first existing user's Library/Safari
# directory. TCC allows stat() and access() checks on the directory itself
# but blocks reading its entries, so only a listing detects missing FDA.
probe_full_disk_access() {
    local u h uid safari_dir
    while IFS=$'\t' read -r u h uid; do
        safari_dir="$h/Library/Safari"
        [ -d "$safari_dir" ] && [ ! -L "$safari_dir" ] || continue
        log_debug "probing Full Disk Access via: $safari_dir"
        if ! ls -a "$safari_dir" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    done < <(enumerate_users)
    log_debug "no candidate home directory for FDA probe; assuming access"
    return 0
}

warn_fda_missing() {
    printf '%b\n' "${COLOR_RED}==================================================================${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}${COLOR_BOLD}  WARNING: Full Disk Access is probably NOT granted.${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}  Protected locations (Safari data, mail, messages, TCC stores...)${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}  will be silently skipped by macOS, so results are incomplete.${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}  Grant access under: System Settings > Privacy & Security >${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}  Full Disk Access (for your terminal or invoking program).${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_RED}==================================================================${COLOR_RESET}" >&2
}

confirm_action() {
    local prompt="$1"
    local answer
    if [ ! -t 0 ]; then
        log_warn "stdin is not a terminal; cannot prompt (use --force to skip prompts)"
        return 1
    fi
    printf '%b' "${COLOR_YELLOW}${prompt}${COLOR_RESET}" >&2
    if ! read -r answer; then
        printf '\n' >&2
        return 1
    fi
    case "$answer" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

###############################################################################
# SECTION: APFS snapshot purge (--purge-snapshots)
###############################################################################

purge_snapshots() {
    if [ "$TEST_MODE" -eq 1 ]; then
        log_debug "test mode: snapshot purge skipped (tmutil/diskutil absent)"
        return 0
    fi
    if ! command -v tmutil >/dev/null 2>&1; then
        log_warn "tmutil unavailable; cannot enumerate local snapshots"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    local snaps snap listing
    if ! listing="$(tmutil listlocalsnapshots / 2>/dev/null)"; then
        log_warn "failed to enumerate local Time Machine snapshots"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    snaps="$(printf '%s\n' "$listing" \
        | grep -E '^com\.apple\.TimeMachine\.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]\.local$' || true)"
    if [ -z "$snaps" ]; then
        log_info "no local Time Machine snapshots found"
        return 0
    fi
    if ! command -v diskutil >/dev/null 2>&1; then
        log_debug "diskutil unavailable; using tmutil thinlocalsnapshots fallback"
        if [ "$DRY_RUN" -eq 1 ]; then
            # The real run issues one thinning request, so count one item.
            log_debug "[DRY RUN] would thin local snapshots: $(printf '%s' "$snaps" | tr '\n' ' ')"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            if tmutil thinlocalsnapshots / 9999999999999 4 >/dev/null 2>&1; then
                log_ok "requested aggressive thinning of local snapshots"
                CLEANED_COUNT=$((CLEANED_COUNT + 1))
            else
                log_warn "tmutil thinlocalsnapshots failed"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        fi
        return 0
    fi
    # Time Machine local snapshots belong to the Data volume. Since macOS 10.15
    # "/" is the sealed System volume, so diskutil must address the Data view.
    local snapshot_volume=/
    if [ -d "$DATA_VOLUME" ]; then
        snapshot_volume="$DATA_VOLUME"
    fi
    while IFS= read -r snap; do
        [ -n "$snap" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            log_debug "[DRY RUN] would delete snapshot from $snapshot_volume: $snap"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            continue
        fi
        if diskutil apfs deleteSnapshot "$snapshot_volume" -name "$snap" >/dev/null 2>&1; then
            log_ok "deleted snapshot: $snap"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            log_warn "failed to delete snapshot: $snap"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done <<< "$snaps"
    return 0
}

###############################################################################
# SECTION: Modules
#
# Fixed execution order = MODULE_IDS order, except that unified runs last. Per-user work always follows the
# pattern: enumerate_users consumed via while-read (process substitution so
# counters stay in the current shell), guarded by [ -d "$h" ].
###############################################################################

# --- module: clipboard -------------------------------------------------------
# Maccy uses Storage.sqlite in its application-support directory. SwiftData and
# older Core Data stores use the same HistoryItem/HistoryItemContent relation.
# Only the known schema is accepted; pins, preferences and metadata survive.
clipboard_maccy_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    processes="$(process_list command)" || return 1
    if process_match -Ei '(^|[ /])Maccy([[:space:]/]|$|\.app/)' "$processes"; then
        return 1
    fi
    return 0
}

clipboard_purge_maccy() {
    local db="$1" suffix sqlite_bin tables table sql result stem version
    guard_mutation_target "$db" || return 1
    if [ ! -e "$db" ]; then
        for suffix in -wal -shm -journal; do
            if [ -e "$db$suffix" ] || [ -L "$db$suffix" ]; then
                log_warn "clipboard: orphan database sidecar retained: $db$suffix"
                return 1
            fi
        done
        return 0
    fi
    # Models with external binary storage need an app-specific object reader.
    # Do not erase rows while leaving unknown external clipboard blobs behind.
    stem="${db##*/}"; stem="${stem%.sqlite}"
    for suffix in "$stem" ".$stem"; do
        if [ -e "${db%/*}/${suffix}_SUPPORT" ] || [ -L "${db%/*}/${suffix}_SUPPORT" ]; then
            log_warn "clipboard: external object store is unsupported; database retained: $db"
            return 1
        fi
    done
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear Maccy history (schema checked on real run): $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || return 1
    result="$(ai_sqlite_command "$db" "$sqlite_bin" "BEGIN; SELECT name FROM sqlite_master WHERE type='table' ORDER BY name; PRAGMA schema_version; COMMIT;" 2>/dev/null)" || return 1
    version="${result##*$'\n'}"
    tables="${result%$'\n'*}"
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    for table in ZHISTORYITEM ZHISTORYITEMCONTENT; do
        case $'\n'"$tables"$'\n' in *$'\n'"$table"$'\n'*) ;; *) return 1 ;; esac
    done
    sql="PRAGMA trusted_schema=OFF;
PRAGMA foreign_keys=OFF;
PRAGMA secure_delete=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE shredder_clipboard_check(ok INTEGER CHECK(ok=1));
INSERT INTO shredder_clipboard_check SELECT schema_version=$version FROM pragma_schema_version;
INSERT INTO shredder_clipboard_check SELECT COUNT(*)=0 FROM sqlite_master
 WHERE type IN ('trigger','view') OR (type='table' AND name NOT IN
 ('ZHISTORYITEM','ZHISTORYITEMCONTENT','Z_METADATA','Z_MODELCACHE','Z_PRIMARYKEY','ACHANGE','ATRANSACTION','ATRANSACTIONSTRING'));
INSERT INTO shredder_clipboard_check SELECT COUNT(*)=0 FROM pragma_table_info('ZHISTORYITEM')
 WHERE name NOT IN ('Z_PK','Z_ENT','Z_OPT','ZNUMBEROFCOPIES','ZFIRSTCOPIEDAT','ZLASTCOPIEDAT','ZAPPLICATION','ZPIN','ZTITLE');
INSERT INTO shredder_clipboard_check SELECT COUNT(*)=0 FROM pragma_table_info('ZHISTORYITEMCONTENT')
 WHERE name NOT IN ('Z_PK','Z_ENT','Z_OPT','ZITEM','ZTYPE','ZVALUE');
INSERT INTO shredder_clipboard_check SELECT COUNT(*)=3 FROM pragma_table_info('ZHISTORYITEM') WHERE name IN ('Z_PK','ZPIN','ZTITLE');
INSERT INTO shredder_clipboard_check SELECT COUNT(*)=4 FROM pragma_table_info('ZHISTORYITEMCONTENT') WHERE name IN ('Z_PK','ZITEM','ZTYPE','ZVALUE');
CREATE TEMP TABLE shredder_clipboard_ids(id INTEGER PRIMARY KEY);
INSERT INTO shredder_clipboard_ids SELECT Z_PK FROM ZHISTORYITEM WHERE ZPIN IS NULL;"
    if [ "${CLIPBOARD_INCLUDE_PINNED:-0}" -eq 1 ]; then
        sql="$sql INSERT OR IGNORE INTO shredder_clipboard_ids SELECT Z_PK FROM ZHISTORYITEM;"
    fi
    sql="$sql
DELETE FROM ZHISTORYITEMCONTENT WHERE ZITEM IN (SELECT id FROM shredder_clipboard_ids)
 OR ZITEM IS NULL OR ZITEM NOT IN (SELECT Z_PK FROM ZHISTORYITEM);
DELETE FROM ZHISTORYITEM WHERE Z_PK IN (SELECT id FROM shredder_clipboard_ids);"
    # SwiftData's persistent change log can retain deleted clipboard values.
    # These are transaction records, not model data or application preferences.
    for table in ACHANGE ATRANSACTION ATRANSACTIONSTRING; do
        case $'\n'"$tables"$'\n' in
            *$'\n'"$table"$'\n'*) sql="$sql DELETE FROM $table;" ;;
        esac
    done
    sql="$sql
DROP TABLE shredder_clipboard_ids;
DROP TABLE shredder_clipboard_check;
COMMIT;
VACUUM;
PRAGMA wal_checkpoint(TRUNCATE);"
    result="$(ai_sqlite_command "$db" "$sqlite_bin" "$sql" 2>/dev/null)" || return 1
    result="${result##*$'\n'}"
    case "$result" in 0\|*) ;; *) return 1 ;; esac
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
    log_debug "cleared Maccy history; preferences and model metadata retained: $db"
    return 0
}

clipboard_clear_current() {
    # The system pasteboard belongs to a GUI session. Never use the invoking
    # root session, a sudo-only fallback, or every user's bootstrap namespace.
    if [ "$TEST_MODE" -eq 1 ]; then
        log_debug "test mode: native pasteboard command skipped"
        return 0
    fi
    local console_uid u h uid found=0
    console_uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null)" || return 1
    case "$console_uid" in ''|0|*[!0-9]*) return 1 ;; esac
    [ -x /bin/launchctl ] && [ -x /usr/bin/sudo ] && [ -x /usr/bin/pbcopy ] || return 1
    /bin/launchctl print "gui/$console_uid" >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r u h uid; do
        [ "$uid" = "$console_uid" ] || continue
        guard_mutation_target "$h" || return 1
        if [ "$DRY_RUN" -eq 1 ]; then
            log_debug "[DRY RUN] would clear the active GUI user's current pasteboard"
        else
            /bin/launchctl asuser "$uid" /usr/bin/sudo -u "#$uid" -- \
                /usr/bin/env HOME="$h" /usr/bin/pbcopy < /dev/null || return 1
        fi
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        found=1
        break
    done < <(enumerate_users)
    [ "$found" -eq 1 ]
}

module_clipboard() {
    local u h uid root before
    if ! clipboard_maccy_stopped; then
        log_warn "clipboard: close Maccy before cleanup; process-query failures also block cleanup"
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    fi
    while IFS=$'\t' read -r u h uid; do
        for root in "$h/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy" \
                    "$h/Library/Application Support/Maccy"; do
            before="$FAILED_COUNT"
            if ! clipboard_purge_maccy "$root/Storage.sqlite"; then
                log_warn "clipboard: Maccy cleanup refused or incomplete: $root/Storage.sqlite"
                count_failure_since "$before"
            fi
        done
    done < <(enumerate_users)
    if [ "${CLIPBOARD_CURRENT:-0}" -eq 1 ] && ! clipboard_clear_current; then
        log_warn "clipboard: current pasteboard not cleared; no verified active GUI user or command failed"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# --- module: shell -----------------------------------------------------------
# Clear only known shell-history tables. Atuin's record store also contains
# aliases, scripts and KV entries, so it must never be removed as a whole.
# ai_sqlite_command supplies the common owner-UID, physical-parent and link checks.
shell_purge_database() {
    local db="$1" flavor="$2" mode="${3:-clean}" tables table deletes keeps anchor
    local sqlite_bin sql allowed="" version count=0 condition suffix
    guard_mutation_target "$db" || return 1
    if [ ! -e "$db" ]; then
        for suffix in -wal -shm -journal; do
            if [ -e "$db$suffix" ] || [ -L "$db$suffix" ]; then
                log_warn "shell: orphan database sidecar retained: $db$suffix"
                return 1
            fi
        done
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        [ "$mode" != clean ] || CLEANED_COUNT=$((CLEANED_COUNT + 1))
        log_debug "[DRY RUN] would clear known shell history (schema checked on real run): $db"
        return 0
    fi
    case "$flavor" in
        atuin) anchor=history; deletes='history events'; keeps=_sqlx_migrations ;;
        atuin-records) anchor='store records'; deletes='store records'; keeps=_sqlx_migrations ;;
        nushell) anchor=history; deletes=history; keeps=sqlite_sequence ;;
        xonsh) anchor=xonsh_history; deletes=xonsh_history; keeps=sqlite_sequence ;;
        histdb) anchor=history; deletes='history commands places'; keeps=sqlite_sequence ;;
        *) return 1 ;;
    esac
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || { log_warn "shell: sqlite3 required; database retained: $db"; return 1; }
    tables="$(ai_sqlite_command "$db" "$sqlite_bin" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)" || return 1
    deletes="$deletes $(sqlite_stat_tables "$tables")"
    for table in $anchor; do
        case $'\n'"$tables"$'\n' in *$'\n'"$table"$'\n'*) count=$((count + 1)) ;; esac
    done
    [ "$count" -gt 0 ] || return 1
    while IFS= read -r table; do
        case " $deletes $keeps " in *" $table "*) ;; *) return 1 ;; esac
    done <<< "$tables"
    for table in $deletes $keeps; do allowed="${allowed:+$allowed,}'$table'"; done
    version="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA schema_version;' 2>/dev/null)" || return 1
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    sql="PRAGMA trusted_schema=OFF;
PRAGMA foreign_keys=OFF;
PRAGMA secure_delete=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE shredder_check(ok INTEGER CHECK(ok=1));
INSERT INTO shredder_check SELECT schema_version=$version FROM pragma_schema_version;
INSERT INTO shredder_check SELECT COUNT(*)=0 FROM sqlite_master WHERE type='trigger' OR (type='table' AND name NOT IN ($allowed));"
    for table in $deletes; do
        case $'\n'"$tables"$'\n' in *$'\n'"$table"$'\n'*) ;; *) continue ;; esac
        condition=1
        # Statistics tables have no tag column; clear them without the check.
        if [ "$flavor" = atuin-records ] && [ "${table#sqlite_stat}" = "$table" ]; then
            # Version 001 packfile manifests are plaintext JSON with a three-byte
            # prefix. Other tags can contain user configuration and stay intact.
            sql="$sql
INSERT INTO shredder_check SELECT COUNT(*)=0 FROM \"$table\"
 WHERE tag='packfile' AND CASE
 WHEN substr(CAST(data AS TEXT),1,3)='001' AND json_valid(substr(CAST(data AS TEXT),4))
 THEN COALESCE(json_type(substr(CAST(data AS TEXT),4),'$.tag')!='text',1)
 ELSE 1 END;"
            condition="tag='history' OR CASE WHEN tag='packfile' THEN json_extract(substr(CAST(data AS TEXT),4),'$.tag')='history' ELSE 0 END"
        fi
        if [ "$mode" = clean ]; then
            sql="$sql
DELETE FROM \"$table\" WHERE $condition;"
        fi
    done
    if [ "$mode" = clean ]; then
        sql="$sql
DROP TABLE shredder_check;
COMMIT;
VACUUM;
PRAGMA wal_checkpoint(TRUNCATE);"
    else
        sql="$sql
ROLLBACK;"
    fi
    local result
    result="$(ai_sqlite_command "$db" "$sqlite_bin" "$sql" 2>/dev/null)" || return 1
    if [ "$mode" = clean ]; then
        result="${result##*$'\n'}"
        case "$result" in 0\|*) ;; *) return 1 ;; esac
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        log_debug "cleared shell history; configuration preserved: $db"
    fi
    return 0
}

shell_clean_database() {
    local before="$FAILED_COUNT"
    if ! shell_purge_database "$@"; then
        log_warn "shell: unsafe, unsupported or unavailable history database retained: $1"
        count_failure_since "$before"
    fi
}

shell_clean_atuin() {
    local root="$1" failed=0 before="$FAILED_COUNT"
    # Check both files before deleting either representation of the history.
    shell_purge_database "$root/history.db" atuin check || failed=1
    shell_purge_database "$root/records.db" atuin-records check || failed=1
    if [ "$failed" -eq 1 ]; then
        log_warn "shell: Atuin history retained because a database could not be checked: $root"
        count_failure_since "$before"
        return 0
    fi
    shell_clean_database "$root/records.db" atuin-records
    shell_clean_database "$root/history.db" atuin
}

shell_stores_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    processes="$(process_list command)" || return 1
    # Bash/zsh can run this script. They cannot be closed from here; their
    # in-memory history can be written back and is documented separately.
    # Jupyter kernels write the same IPython history database.
    if process_match -Ei '(^|[ /])(atuin|nu|xonsh|fish|ipython|jupyter(-lab|-notebook|-server)?|ipykernel_launcher|ipykernel)([[:space:]/]|$|\.(py|exe)([[:space:]]|$))' "$processes"; then
        return 1
    fi
    return 0
}

terminal_sessions_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    processes="$(process_list command)" || return 1
    # Include the app executable, CLI and helper processes. A failed process
    # query also blocks cleanup; --force must not bypass this check.
    if process_match -Ei '(^|[ /])(cmux|cmuxterm)([[:space:]/.-]|$)' "$processes"; then
        return 1
    fi
    return 0
}

shell_clean_terminal_sessions() {
    local h="$1" root entry
    root="$h/Library/Application Support/cmux"
    if guard_mutation_target "$root"; then
        for entry in terminal-history session-history session-com.cmuxterm.app-scrollback; do
            if [ -e "$root/$entry" ] && [ ! -d "$root/$entry" ]; then
                log_warn "shell: expected a terminal history directory, retaining: $root/$entry"
                [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
                continue
            fi
            clear_dir_contents "$root/$entry"
        done
    fi
    root="$h/.cmuxterm"
    guard_mutation_target "$root" || return 0
    for entry in workstream.jsonl events.jsonl events.jsonl.1 agent-journal-dead-letter.jsonl; do
        shell_remove_history_file "$root/$entry"
    done
    return 0
}

shell_remove_history_file() {
    if [ -e "$1" ] && [ ! -f "$1" ] && [ ! -L "$1" ]; then
        log_warn "shell: expected a history file, retaining: $1"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    remove_path "$1"
}

shell_clean_alternative_stores() {
    local h="$1" root entry
    shell_clean_atuin "$h/.local/share/atuin"
    shell_clean_atuin "$h/.atuin/data"
    for root in "$h/.local/share/fish" "$h/.config/fish"; do
        guard_mutation_target "$root" || continue
        while read_find_path entry; do
            remove_path "$entry"
        done < <(find_checked "$root" -maxdepth 1 \( -type f -o -type l \) -name '*_history' -print0)
    done
    for root in "$h/Library/Application Support/nushell" "$h/.config/nushell"; do
        shell_remove_history_file "$root/history.txt"
        shell_clean_database "$root/history.sqlite3" nushell
    done
    root="$h/.local/share/xonsh"
    for root in "$root" "$root/history_json"; do
        guard_mutation_target "$root" || continue
        while read_find_path entry; do
            remove_path "$entry"
        done < <(find_checked "$root" -maxdepth 1 \( -type f -o -type l \) -name 'xonsh-*.json' -print0)
    done
    shell_clean_database "$h/.local/share/xonsh/xonsh-history.sqlite" xonsh
    shell_clean_database "$h/.histdb/zsh-history.db" histdb
    for root in "$h/Library/Application Support/zoxide" "$h/.local/share/zoxide"; do
        shell_remove_history_file "$root/db.zo"
        shell_remove_history_file "$root/db.txt"
    done
    shell_remove_history_file "$h/.z"
    shell_remove_history_file "$h/.fasd"
    guard_mutation_target "$h/.ipython" || return 0
    for root in "$h"/.ipython/profile_*; do
        [ -d "$root" ] || continue
        remove_sqlite_db "$root/history.sqlite"
    done
}

module_shell() {
    local u h uid hf mf="" extended=1 terminals="${TERMINAL_SESSIONS:-0}"
    if ! shell_stores_stopped; then
        log_warn "shell: close Atuin, fish, Nushell, Xonsh and IPython before extended history cleanup"
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            extended=0
        fi
    fi
    if [ "$terminals" -eq 1 ] && ! terminal_sessions_stopped; then
        log_warn "shell: close cmux and its background processes before terminal session cleanup"
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            terminals=0
        fi
    fi
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        log_debug "shell: processing user '$u' ($h)"
        while IFS= read -r hf; do
            [ -n "$hf" ] || continue
            truncate_file "$h/$hf"
        done <<'SHELL_HISTORIES'
.bash_history
.zsh_history
.zhistory
.sh_history
.python_history
.mysql_history
.psql_history
.sqlite_history
.rediscli_history
.lesshst
.wget-hsts
.node_repl_history
.Rhistory
.gdb_history
.mongo_history
.docker_history
.irb_history
.php_history
.perldb_hist
.erlang_history
.lua_history
.scala_history
.octave_hist
.rsync_history
SHELL_HISTORIES
        clear_dir_contents "$h/.bash_sessions"
        clear_dir_contents "$h/.zsh_sessions"
        if [ "$extended" -eq 1 ]; then shell_clean_alternative_stores "$h"; fi
        if [ "$terminals" -eq 1 ]; then shell_clean_terminal_sessions "$h"; fi
        truncate_file "$h/.julia/logs/repl_history.jl"
        truncate_file "$h/.ghc/ghci_history"
        if [ -d "$h/.matlab" ]; then
            # MATLAB keeps History.xml one level per version; find instead
            # of a quoted-star glob.
            while read_find_path mf; do
                truncate_file "$mf"
            done < <(find_checked "$h/.matlab" -mindepth 1 -maxdepth 2 -type f -name 'History.xml' -print0)
        fi
        truncate_file "$h/.local/share/recently-used.xbel"
        truncate_file "$h/.local/share/mc/history"
        truncate_file "$h/.local/share/nano/search_history"
    done < <(enumerate_users)
    return 0
}

# Age selection uses file modification time, not dates inside log records.
# lsof errors fail closed. There is no lock shared with arbitrary log writers;
# applications must remain closed while their historical reports are removed.
remove_aged_closed_log() {
    local file="$1" modified now open_pids rc=0
    guard_mutation_target "$file" || return 0
    [ ! -L "$file" ] && [ -f "$file" ] || return 0
    modified="$(stat -f %m "$file" 2>/dev/null || true)"
    case "$modified" in ''|*[!0-9]*) modified="$(stat -c %Y "$file" 2>/dev/null || true)" ;; esac
    now="$(date +%s 2>/dev/null || true)"
    case "$modified:$now" in
        *[!0-9:]*|:*|*:)
            log_warn "cannot read the log modification time; retaining: $file"
            [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
            ;;
    esac
    [ "$((now - modified))" -gt "$((LOGS_OLDER_THAN * 86400))" ] || return 0
    if [ "$TEST_MODE" -eq 0 ]; then
        if ! command -v lsof >/dev/null 2>&1; then
            log_warn "cannot check active log handles; retaining: $file"
            FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
        fi
        # lsof can return 1 for both no matches and errors. Diagnostics must
        # therefore be retained, not discarded as an empty result.
        open_pids="$(lsof -t -- "$file" 2>&1)" || rc=$?
        if [ -n "$open_pids" ]; then
            if [ "$rc" -eq 0 ]; then
                log_debug "retaining open or incompletely inspected log: $file"
            else
                log_warn "active log handle query failed; retaining: $file"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 0
        fi
        if [ "$rc" -ne 1 ]; then
            log_warn "active log handle check was inconclusive; retaining: $file"
            FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
        fi
    fi
    remove_path "$file"
}

clean_aged_log_tree() {
    local dir="$1" file
    guard_mutation_target "$dir" || return 0
    [ ! -L "$dir" ] && [ -d "$dir" ] || return 0
    while read_find_path file; do
        case "${file##*/}" in
            *.ips|*.crash|*.hang|*.spin|*.diag|*.log|*.log.gz|*.log.bz2)
                remove_aged_closed_log "$file" ;;
        esac
    done < <(find_checked "$dir" -xdev -type f -print0)
}

clean_aged_system_logs() {
    local lf file suffix u h uid
    # Current logs, fsck outputs and daemon state directories are retained.
    for lf in system.log wifi.log install.log accountpolicy.log appfirewall.log; do
        while read_find_path file; do
            suffix="${file##*/}"; suffix="${suffix#"$lf".}"
            suffix="${suffix%.gz}"; suffix="${suffix%.bz2}"
            case "$suffix" in ''|*[!0-9]*) continue ;; esac
            remove_aged_closed_log "$file"
        done < <(find_checked "$VAR_LOG" -maxdepth 1 -type f -name "$lf.*" -print0)
    done
    clean_aged_log_tree "$SANDBOX/Library/Logs/DiagnosticReports"
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        clean_aged_log_tree "$h/Library/Logs/DiagnosticReports"
    done < <(enumerate_users)
}

clean_aged_audit_logs() {
    local file base current_target
    guard_mutation_target "$VAR_AUDIT" || return 0
    current_target="$(readlink "$VAR_AUDIT/current" 2>/dev/null || true)"
    current_target="${current_target##*/}"
    while read_find_path file; do
        base="${file##*/}"
        [ -n "$current_target" ] && [ "$base" = "$current_target" ] && continue
        # Never remove incomplete audit trails, even with no current symlink.
        case "$base" in *not_terminated*|*crash_recovery*) continue ;; esac
        # Closed BSM trails use numeric start/end timestamps, optionally .gz.
        if [[ "$base" =~ ^[0-9]{14}\.[0-9]{14}(\.gz)?$ ]]; then
            remove_aged_closed_log "$file"
        fi
    done < <(find_checked "$VAR_AUDIT" -maxdepth 1 -type f -name '[0-9]*' -print0)
}

# --- module: systemlogs ------------------------------------------------------
module_systemlogs() {
    if [ -n "$LOGS_OLDER_THAN" ]; then
        clean_aged_system_logs
        return 0
    fi
    local lf u h uid rotated="" suffix
    for lf in system.log wifi.log install.log accountpolicy.log appfirewall.log; do
        truncate_file "$VAR_LOG/$lf"
        while read_find_path rotated; do
            suffix="${rotated##*/}"
            suffix="${suffix#"$lf".}"
            suffix="${suffix%.gz}"
            suffix="${suffix%.bz2}"
            case "$suffix" in ''|*[!0-9]*) continue ;; esac
            remove_path "$rotated"
        done < <(find_checked "$VAR_LOG" -maxdepth 1 -type f -name "$lf.*" -print0)
    done
    while read_find_path f; do
        truncate_file "$f"
    done < <(find_checked "$VAR_LOG" -maxdepth 1 -type f -name 'fsck*' -print0)
    clear_dir_contents "$VAR_LOG/powermanagement"
    clear_dir_contents "$VAR_LOG/com.apple.xpc.launchd"
    # System-level crash reports.
    clear_dir_contents "$SANDBOX/Library/Logs/DiagnosticReports"
    # Per-user crash reports only; top-level ~/Library/*.log cleanup would be
    # far too broad, so it is deliberately not attempted.
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        clear_dir_contents "$h/Library/Logs/DiagnosticReports"
    done < <(enumerate_users)
    return 0
}

# --- module: audit -----------------------------------------------------------
module_audit() {
    local audit_enabled=0 current_target=""
    [ -d "$VAR_AUDIT" ] || {
        log_debug "audit directory not present, skipping: $VAR_AUDIT"
        return 0
    }
    if [ ! -r "$VAR_AUDIT" ] || [ ! -x "$VAR_AUDIT" ]; then
        log_warn "audit directory is not readable/searchable: $VAR_AUDIT"
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        return 0
    fi
    if [ -n "$LOGS_OLDER_THAN" ]; then
        clean_aged_audit_logs
        return 0
    fi
    if [ "$TEST_MODE" -eq 0 ] && command -v audit >/dev/null 2>&1 && audit -c >/dev/null 2>&1; then
        audit_enabled=1
    fi
    current_target="$(readlink "$VAR_AUDIT/current" 2>/dev/null || true)"
    current_target="${current_target##*/}"
    if [ "$audit_enabled" -eq 1 ] && [ -z "$current_target" ]; then
        log_warn "cannot identify the active audit record; refusing trail deletion"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        local n=0 dry_file dry_base
        while read_find_path dry_file; do
            dry_base="${dry_file##*/}"
            # A real run rotates the active record first and then removes it.
            [ "$audit_enabled" -eq 0 ] && [ -n "$current_target" ] \
                && [ "$dry_base" = "$current_target" ] && continue
            n=$((n + 1))
        done < <(find_checked "$VAR_AUDIT" -maxdepth 1 \( -type f -o -type l \) -name '[0-9]*' -print0)
        log_debug "[DRY RUN] would remove $n timestamped audit files under $VAR_AUDIT (preserving 'current')"
        CLEANED_COUNT=$((CLEANED_COUNT + n))
        return 0
    fi
    if [ "$audit_enabled" -eq 1 ]; then
        log_debug "rotating current audit record (audit -n)"
        if ! audit -n >/dev/null 2>&1; then
            log_warn "failed to rotate the active audit record"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
        # auditd can update the current link after audit -n returns. Wait for
        # the new record, so that the new active file is never removed.
        local previous_target="$current_target" tries=0
        while [ "$tries" -lt 50 ]; do
            current_target="$(readlink "$VAR_AUDIT/current" 2>/dev/null || true)"
            current_target="${current_target##*/}"
            [ -z "$current_target" ] || [ "$current_target" = "$previous_target" ] || break
            sleep 0.1 2>/dev/null || break
            tries=$((tries + 1))
        done
        if [ -z "$current_target" ] || [ "$current_target" = "$previous_target" ]; then
            log_warn "the active audit record did not change after rotation; refusing trail deletion"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    else
        log_debug "BSM audit is unavailable or disabled; deleting existing trail files only"
    fi
    # Delete timestamped trail files by basename pattern; never touch the
    # file referenced by the 'current' symlink.
    local f b
    while read_find_path f; do
        b="${f##*/}"
        [ -n "$current_target" ] && [ "$b" = "$current_target" ] && continue
        remove_path "$f"
    done < <(find_checked "$VAR_AUDIT" -maxdepth 1 \( -type f -o -type l \) -name '[0-9]*' -print0)
    return 0
}

# --- module: browser ---------------------------------------------------------
# Shared LevelDB/hashed stores cannot be separated by origin without the
# browser's storage engine. Keep them unless extension data was also selected.
browser_mixed_store() {
    local target="$1"
    [ -e "$target" ] || [ -L "$target" ] || return 0
    if [ "$INCLUDE_EXTENSION_DATA" -eq 1 ]; then
        remove_path "$target"
    else
        log_warn "mixed website/extension data retained (use --include-extension-data): $target"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

clean_safari_data_store() {
    local root="$1" item
    # These exact stores contain website data, but can include extension origins.
    for item in Default Origins LocalStorage IndexedDB WebSQL ServiceWorkers \
        CacheStorage IsolatedSites; do
        browser_mixed_store "$root/$item"
    done
    remove_path "$root/Cookies/Cookies.binarycookies"
    return 0
}

# WebKit keeps persistent service-worker and cache-storage data inside cache
# roots too. Do not erase the WebKit tree as an ordinary disposable cache.
clean_safari_cache_root() {
    local root="$1" entry item
    guard_mutation_target "$root" || return 0
    while read_find_path entry; do
        [ "${entry##*/}" = WebKit ] && continue
        remove_path "$entry"
    done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -print0)
    for item in NetworkCache MediaCache; do
        clear_dir_contents "$root/WebKit/$item"
    done
    for item in CacheStorage ServiceWorkers Storage; do
        browser_mixed_store "$root/WebKit/$item"
    done
    return 0
}

clean_safari_for_home() {
    local h="$1" saf root profile item
    saf="$h/Library/Safari"
    if browser_running "Safari" && { [ -d "$saf" ] \
        || [ -d "$h/Library/Containers/com.apple.Safari" ] \
        || [ -d "$h/Library/Cookies" ] \
        || [ -d "$h/Library/WebKit/com.apple.Safari" ] \
        || [ -d "$h/Library/Caches/com.apple.Safari" ] \
        || [ -d "$h/Library/Saved Application State/com.apple.Safari.savedState" ]; }; then
        log_warn "Safari is running or cannot be checked; skipping Safari site and session data"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    else
        for root in "$saf" "$h/Library/Containers/com.apple.Safari/Data/Library/Safari" \
            "$saf"/Profiles/*/ "$h/Library/Containers/com.apple.Safari/Data/Library/Safari"/Profiles/*/; do
            root="${root%/}"
            # Unmatched profile globs stay literal; named profiles are directories.
            case "$root" in */Profiles/\*) continue ;; esac
            remove_sqlite_db "$root/History.db"
            remove_path "$root/History.db-lock"
            for item in Downloads.plist TopSites.plist LastSession.plist RecentlyClosedTabs.plist; do
                remove_path "$root/$item"
            done
            # SafariTabs also holds saved tab groups. Keep it: deleting the file
            # would exceed tab-recovery cleanup and can affect synced state.
            if [ -e "$root/SafariTabs.db" ]; then
                log_warn "SafariTabs.db retained: mixed saved/synced tab groups require Safari UI cleanup: $root/SafariTabs.db"
                [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            browser_mixed_store "$root/LocalStorage"
            browser_mixed_store "$root/Databases"
            # Icon caches are keyed by the visited site.
            remove_path "$root/Favicon Cache"
            remove_path "$root/Touch Icons Cache"
            remove_path "$root/Template Icons"
        done
        for root in "$h/Library/WebKit/com.apple.Safari" \
            "$h/Library/Containers/com.apple.Safari/Data/Library/WebKit"; do
            clean_safari_data_store "$root/WebsiteData"
            guard_mutation_target "$root/WebsiteDataStore" || continue
            for profile in "$root"/WebsiteDataStore/*/; do
                [ -d "$profile" ] || continue
                clean_safari_data_store "${profile%/}"
            done
        done
        remove_path "$h/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
        remove_path "$h/Library/Cookies/Cookies.binarycookies"
        # HSTS entries name every HTTPS host that sent the header.
        remove_path "$h/Library/Cookies/HSTS.plist"
        remove_path "$h/Library/Containers/com.apple.Safari/Data/Library/Cookies/HSTS.plist"
        clear_dir_contents "$h/Library/Saved Application State/com.apple.Safari.savedState"
        clear_dir_contents "$h/Library/Containers/com.apple.Safari/Data/Library/Saved Application State/com.apple.Safari.savedState"
        clean_safari_cache_root "$h/Library/Caches/com.apple.Safari"
        clean_safari_cache_root "$h/Library/Containers/com.apple.Safari/Data/Library/Caches"
    fi
    return 0
}

clean_chrome_profile_dbs() {
    local prof="$1" item origin
    remove_sqlite_db "$prof/History"
    remove_sqlite_db "$prof/Cookies"
    remove_sqlite_db "$prof/Network/Cookies"
    remove_sqlite_db "$prof/Network/Device Bound Sessions"
    remove_sqlite_db "$prof/Device Bound Sessions"
    remove_sqlite_db "$prof/Top Sites"
    remove_sqlite_db "$prof/Web Data"
    # These stores also record visited pages, typed input or visited hosts.
    remove_sqlite_db "$prof/Favicons"
    remove_sqlite_db "$prof/Shortcuts"
    remove_sqlite_db "$prof/Network Action Predictor"
    remove_sqlite_db "$prof/DIPS"
    remove_path "$prof/Visited Links"
    remove_path "$prof/TransportSecurity"
    remove_path "$prof/Network/TransportSecurity"
    remove_path "$prof/Network Persistent State"
    remove_path "$prof/Network/Network Persistent State"
    for item in Sessions Sessions_Encrypted 'Current Session' 'Current Tabs' 'Last Session' 'Last Tabs'; do
        remove_path "$prof/$item"
    done
    # These stores can also hold extension data, and some use opaque bucket IDs.
    for item in 'Local Storage' 'Session Storage' 'Service Worker' 'File System' \
        databases 'Application Cache' WebStorage; do
        browser_mixed_store "$prof/$item"
    done
    if [ "$INCLUDE_EXTENSION_DATA" -eq 1 ]; then
        remove_path "$prof/IndexedDB"
    elif guard_mutation_target "$prof/IndexedDB"; then
        while read_find_path origin; do
            case "${origin##*/}" in
                http_*|https_*|file_*) remove_path "$origin" ;;
                chrome-extension_*) ;; # Extension settings and credentials stay.
                *) browser_mixed_store "$origin" ;;
            esac
        done < <(find_checked "$prof/IndexedDB" -mindepth 1 -maxdepth 1 -print0)
    fi
    return 0
}

clean_chrome_profile_caches() {
    local prof="$1"
    clear_dir_contents "$prof/Cache"
    clear_dir_contents "$prof/Code Cache"
    clear_dir_contents "$prof/GPUCache"
    return 0
}

clean_chrome_family_for_home() {
    local h="$1"
    local label proc rel appdir prof cache_appdir
    while IFS='|' read -r label proc rel; do
        [ -n "$label" ] || continue
        appdir="$h/$rel"
        cache_appdir="$h/Library/Caches/${rel#Library/Application Support/}"
        [ -d "$appdir" ] || continue
        if browser_running "$proc"; then
            log_warn "$label is running or cannot be checked; skipping $label site and session data"
            [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        else
            for prof in "$appdir/Default" "$appdir/Guest Profile" "$appdir"/Profile\ */; do
                prof="${prof%/}"
                [ -d "$prof" ] || continue
                clean_chrome_profile_dbs "$prof"
            done
        fi
        # Pure cache directories are safe even while the browser runs.
        for prof in "$appdir/Default" "$appdir/Guest Profile" "$appdir"/Profile\ */; do
            prof="${prof%/}"
            [ -d "$prof" ] || continue
            clean_chrome_profile_caches "$prof"
            clean_chrome_profile_caches "$cache_appdir/${prof##*/}"
        done
    done <<'CHROME_BROWSERS'
Google Chrome|Google Chrome|Library/Application Support/Google/Chrome
Chromium|Chromium|Library/Application Support/Chromium
Microsoft Edge|Microsoft Edge|Library/Application Support/Microsoft Edge
Brave|Brave Browser|Library/Application Support/BraveSoftware/Brave-Browser
CHROME_BROWSERS
    return 0
}

# A successful checkpoint command can still report busy (first field = 1).
# Do not claim cleanup succeeded while a reader can retain the old WAL pages.
browser_sqlite_compact() {
    local db="$1" sqlite_bin="$2" checkpoint
    ai_sqlite_command "$db" "$sqlite_bin" 'VACUUM;' >/dev/null 2>&1 || return 1
    checkpoint="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>/dev/null)" || return 1
    case "$checkpoint" in
        0\|*) return 0 ;;
        *) log_warn "browser database checkpoint is busy; close background readers and retry: $db"; return 1 ;;
    esac
}

# Places also stores bookmarks and keywords. Never remove this database or
# its sidecars, including when SQLite is unavailable or the schema is unknown.
purge_firefox_history() {
    local db="$1" sqlite_bin tables sql
    guard_mutation_target "$db" || return 0
    [ -f "$db" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear Firefox history and preserve bookmarks: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    if [ -z "$sqlite_bin" ]; then
        log_warn "sqlite3 unavailable; preserving Firefox Places database: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    if ! tables="$(ai_sqlite_command "$db" "$sqlite_bin" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('moz_places_metadata','moz_places_metadata_search_queries','moz_origins');" 2>/dev/null)"; then
        log_warn "failed to inspect Firefox Places database: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    # Firefox uses foreign_count for bookmark and keyword references. Check
    # bookmarks directly as well, so a stale counter cannot delete their URLs.
    # Its visit-count triggers are temporary; update those fields explicitly.
    sql="PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;"
    # Search terms do not cascade from moz_places_metadata; clear them first.
    case "$tables" in
        *moz_places_metadata_search_queries*) sql="$sql DELETE FROM moz_places_metadata_search_queries;" ;;
    esac
    if printf '%s\n' "$tables" | grep -qx moz_places_metadata; then
        sql="$sql DELETE FROM moz_places_metadata;"
    fi
    sql="$sql
        DELETE FROM moz_historyvisits;
        DELETE FROM moz_inputhistory;
        DELETE FROM moz_annos WHERE place_id IN (
            SELECT id FROM moz_places WHERE foreign_count = 0
            AND NOT EXISTS (SELECT 1 FROM moz_bookmarks WHERE fk = moz_places.id));
        DELETE FROM moz_places WHERE foreign_count = 0
            AND NOT EXISTS (SELECT 1 FROM moz_bookmarks WHERE fk = moz_places.id);
        UPDATE moz_places SET visit_count = 0, last_visit_date = NULL,
            typed = 0, frecency = -1;"
    case "$tables" in
        *moz_origins*) sql="$sql DELETE FROM moz_origins WHERE NOT EXISTS (
            SELECT 1 FROM moz_places WHERE origin_id = moz_origins.id);" ;;
    esac
    sql="$sql COMMIT;"
    # -bail stops at the first SQL error. Closing an uncommitted transaction
    # rolls it back, rather than leaving only part of the history removed.
    if ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1 \
        && browser_sqlite_compact "$db" "$sqlite_bin"; then
        log_debug "cleared Firefox history; bookmarks preserved: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "failed to clear Firefox history; database retained: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# Firefox legacy local storage can also contain extension origins. Select only
# web/file schemes; keep unknown schemas intact and report incomplete cleanup.
purge_firefox_localstorage() {
    local db="$1" sqlite_bin sql
    [ -e "$db" ] || [ -L "$db" ] || return 0
    if [ "$INCLUDE_EXTENSION_DATA" -eq 1 ]; then
        remove_sqlite_db "$db"
        return 0
    fi
    guard_mutation_target "$db" || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear web origins in Firefox local storage: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    sql="PRAGMA secure_delete=ON; BEGIN IMMEDIATE;
        CREATE TEMP TABLE safe_schema(ok INTEGER CHECK(ok=1));
        INSERT INTO safe_schema SELECT NOT EXISTS (
            SELECT 1 FROM sqlite_master WHERE type='trigger'
            OR (type='table' AND name NOT IN ('webappsstore2','database','sqlite_sequence')));
        DELETE FROM webappsstore2 WHERE originKey GLOB '*:http:*'
            OR originKey GLOB '*:https:*' OR originKey GLOB '*:file:*';
        COMMIT;"
    if [ -n "$sqlite_bin" ] && ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1 \
        && browser_sqlite_compact "$db" "$sqlite_bin"; then
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "Firefox local storage could not be cleared safely; retained: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# Quota cache rows contain origin URLs even after origin directories are gone.
# Preserve version/repository records and extension origins; invalidate the cache
# so Firefox rebuilds usage accounting from the remaining directories.
purge_firefox_storage_cache() {
    local db="$1" sqlite_bin sql extension_sql=""
    [ -e "$db" ] || [ -L "$db" ] || return 0
    guard_mutation_target "$db" || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear website origin metadata in Firefox quota cache: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ "$INCLUDE_EXTENSION_DATA" -eq 0 ] || extension_sql="OR origin GLOB 'moz-extension://*'"
    sql="PRAGMA secure_delete=ON; BEGIN IMMEDIATE;
        CREATE TEMP TABLE safe_schema(ok INTEGER CHECK(ok=1));
        INSERT INTO safe_schema SELECT NOT EXISTS (
            SELECT 1 FROM sqlite_master WHERE type='trigger'
            OR (type='table' AND name NOT IN ('database','cache','repository','origin')));
        DELETE FROM origin WHERE origin GLOB 'http://*' OR origin GLOB 'https://*'
            OR origin GLOB 'file://*' $extension_sql;
        UPDATE cache SET valid=0;
        COMMIT;"
    if [ -n "$sqlite_bin" ] && ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1 \
        && browser_sqlite_compact "$db" "$sqlite_bin"; then
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "Firefox quota metadata could not be cleared safely; retained: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

clean_firefox_site_data() {
    local prof="$1" repository origin
    purge_firefox_storage_cache "$prof/storage.sqlite"
    purge_firefox_localstorage "$prof/webappsstore.sqlite"
    purge_firefox_localstorage "$prof/storage/ls-archive.sqlite"
    for repository in default temporary permanent persistent; do
        guard_mutation_target "$prof/storage/$repository" || continue
        while read_find_path origin; do
            case "${origin##*/}" in
                http+++*|https+++*|file+++*) remove_path "$origin" ;;
                moz-extension+++*)
                    [ "$INCLUDE_EXTENSION_DATA" -eq 0 ] || remove_path "$origin"
                    ;;
                chrome|about+*) ;; # Browser-internal data is not website data.
                *) browser_mixed_store "$origin" ;;
            esac
        done < <(find_checked "$prof/storage/$repository" -mindepth 1 -maxdepth 1 -print0)
    done
    return 0
}

clean_firefox_for_home() {
    local h="$1"
    local profiles="$h/Library/Application Support/Firefox/Profiles"
    [ -d "$profiles" ] || return 0
    local skip_dbs=0 prof
    if browser_running "firefox"; then
        log_warn "Firefox is running or cannot be checked; skipping Firefox site and session data"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        skip_dbs=1
    fi
    for prof in "$profiles"/*/; do
        prof="${prof%/}"
        [ -d "$prof" ] || continue
        if [ "$skip_dbs" -eq 0 ]; then
            purge_firefox_history "$prof/places.sqlite"
            remove_sqlite_db "$prof/cookies.sqlite"
            remove_sqlite_db "$prof/formhistory.sqlite"
            # Favicons map page URLs to icons; Firefox fetches them again.
            remove_sqlite_db "$prof/favicons.sqlite"
            remove_path "$prof/sessionstore.jsonlz4"
            clear_dir_contents "$prof/sessionstore-backups"
            remove_path "$prof/sessionstore.js"
            remove_path "$prof/sessionstore.bak"
            clean_firefox_site_data "$prof"
        fi
        clear_dir_contents "$prof/cache2"
        clear_dir_contents "$prof/thumbnails"
        clear_dir_contents "$h/Library/Caches/Firefox/Profiles/${prof##*/}/cache2"
        clear_dir_contents "$h/Library/Caches/Firefox/Profiles/${prof##*/}/thumbnails"
    done
    return 0
}

module_browser() {
    local u h uid
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        log_debug "browser: processing user '$u' ($h)"
        clean_safari_for_home "$h"
        clean_chrome_family_for_home "$h"
        clean_firefox_for_home "$h"
    done < <(enumerate_users)
    return 0
}

# --- module: unified ---------------------------------------------------------
module_unified() {
    if [ "$TEST_MODE" -eq 1 ]; then
        log_debug "test mode: clearing sandbox unified log store at $VAR_DB_DIAG"
        clear_dir_contents "$VAR_DB_DIAG"
        return 0
    fi
    if ! command -v log >/dev/null 2>&1; then
        log_debug "log(1) unavailable; nothing done (honest zero count)"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would erase the unified logging store (log erase --all)"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if log erase --all >/dev/null 2>&1; then
        log_ok "erased unified logging store"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "failed to erase unified logging store (log erase --all)"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# --- module: fileevents ------------------------------------------------------
module_fileevents() {
    local u h uid qdb sql
    # Restart lsd first so it releases quarantine database handles before the
    # SQLite cleanup attempts to acquire a write lock.
    if [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        if command -v killall >/dev/null 2>&1; then
            killall lsd >/dev/null 2>&1 || log_debug "killall lsd failed (best effort)"
        fi
    fi
    # Launch Services quarantine databases (system + per-user copies).
    # Overwrite deleted rows, rebuild the file and truncate the WAL so that
    # removed events do not stay in free pages or the -wal sidecar. One
    # statement per database also gives one count per database.
    sql="PRAGMA secure_delete=ON; DELETE FROM LSQuarantineEvent; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);"
    qdb="$SYS_PREFS/com.apple.LaunchServices.QuarantineEventsV2"
    sqlite_purge "$qdb" "$sql"
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        qdb="$h/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        sqlite_purge "$qdb" "$sql"
    done < <(enumerate_users)
    return 0
}

# --- module: fsevents (explicit selection only) ------------------------------
# The CoreServices service owns the live database. Never remove .fseventsd
# files directly on the host or restart its daemon.
fsevents_native_purge() {
    local device="$1"
    osascript -l JavaScript - "$device" <<'JXA'
ObjC.import('CoreServices');
function run(argv) {
    var device = Number(argv[0]);
    if (!Number.isSafeInteger(device) || device <= 0) throw Error('Invalid device');
    var eventId = Number($.FSEventsGetCurrentEventId());
    if (!Number.isSafeInteger(eventId) || eventId <= 0) throw Error('Invalid event boundary');
    if (!$.FSEventsPurgeEventsForDeviceUpToEventId(device, eventId)) {
        throw Error('FSEvents service refused purge');
    }
}
JXA
}

fsevents_purge_volume() {
    local volume="$1" external="$2" info mount_point writable permissions fs device startup_device physical
    [ ! -L "$volume" ] && [ -d "$volume" ] || return 0
    guard_mutation_target "$volume" || return 0
    if [ "$TEST_MODE" -eq 1 ]; then
        # Fixture cleanup models scope only, not native API acceptance.
        clear_dir_contents "$volume/.fseventsd"
        return 0
    fi
    physical="$(cd "$volume" && pwd -P)" || return 0
    if [ "$physical" != "$volume" ] || [ "$volume" = / ]; then
        log_warn "refusing FSEvents mount alias: $volume"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    info="$(diskutil info -plist "$volume" 2>/dev/null)" || info=''
    mount_point="$(printf '%s' "$info" | plutil -extract MountPoint raw -o - - 2>/dev/null)" || mount_point=''
    writable="$(printf '%s' "$info" | plutil -extract WritableVolume raw -o - - 2>/dev/null)" || writable=''
    permissions="$(printf '%s' "$info" | plutil -extract GlobalPermissionsEnabled raw -o - - 2>/dev/null)" || permissions=''
    fs="$(printf '%s' "$info" | plutil -extract FilesystemType raw -o - - 2>/dev/null)" || fs=''
    device="$(trash_stat_number %d "$volume")" || device=''
    startup_device="$(trash_stat_number %d "$DATA_VOLUME")" || startup_device=''
    if [ "$mount_point" != "$volume" ] || [ "$writable" != true ] || [ "$permissions" != true ] \
        || { [ "$fs" != apfs ] && [ "$fs" != hfs ]; } \
        || [ -z "$device" ] || [ "$device" = 0 ] \
        || { [ "$external" -eq 1 ] && { [ -z "$startup_device" ] || [ "$device" = "$startup_device" ]; }; }; then
        log_warn "refusing unverified, read-only, ownership-disabled or startup-alias FSEvents volume: $volume"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would ask CoreServices to purge FSEvents on $volume (device $device)"
        CLEANED_COUNT=$((CLEANED_COUNT + 1)); return 0
    fi
    if fsevents_native_purge "$device" >/dev/null 2>&1; then
        log_ok "FSEvents service accepted purge: $volume"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "FSEvents API unavailable or purge refused; cleanup not confirmed: $volume"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

module_fsevents() {
    local volume
    if [ -d "$DATA_VOLUME" ]; then
        fsevents_purge_volume "$DATA_VOLUME" 0
    elif [ "$TEST_MODE" -eq 1 ]; then
        fsevents_purge_volume "$SANDBOX" 0
    else
        log_warn "startup Data volume unavailable; FSEvents purge refused"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    if [ "$INCLUDE_VOLUMES" -eq 1 ]; then
        while read_find_path volume; do
            fsevents_purge_volume "$volume" 1
        done < <(find_checked "$SANDBOX/Volumes" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
}

# --- module: usage -----------------------------------------------------------
purge_knowledge_db() {
    activity_clean_store "$1" knowledge
}

clean_recent_items_for_user() {
    local u="$1"
    local h="$2"
    local uid="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        # A real run counts only an existing recent-items domain.
        if [ -e "$h/Library/Preferences/com.apple.recentitems.plist" ]; then
            log_debug "[DRY RUN] would clear recent items for user '$u'"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
        return 0
    fi
    if ! command -v defaults >/dev/null 2>&1; then
        log_debug "defaults(1) unavailable; removing recentitems plist for '$u' instead"
        remove_path "$h/Library/Preferences/com.apple.recentitems.plist"
        return 0
    fi
    if run_as_user "$u" "$uid" "$h" defaults delete com.apple.recentitems >/dev/null 2>&1; then
        log_debug "cleared recent items for user '$u'"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_debug "defaults delete failed for '$u'; removing recentitems plist instead"
        remove_path "$h/Library/Preferences/com.apple.recentitems.plist"
    fi
    return 0
}

module_usage() {
    local u h uid nc recent_dir recent_file app_recent_dir
    # Keep the legacy system store for older macOS releases, then handle the
    # current per-user Knowledge store.
    purge_knowledge_db "$KNOWLEDGE_DB"
    # Recent items, executed in each user's own context.
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        purge_knowledge_db "$h/Library/Application Support/Knowledge/knowledgeC.db"
        clean_recent_items_for_user "$u" "$h" "$uid"
        recent_dir="$h/Library/Application Support/com.apple.sharedfilelist"
        if [ -d "$recent_dir" ]; then
            guard_mutation_target "$recent_dir" || continue
            while read_find_path recent_file; do
                remove_path "$recent_file"
            done < <(find_checked "$recent_dir" -maxdepth 1 -type f -name '*Recent*.sfl*' -print0)
            # Per-application lists are stored one level below the shared
            # list root. Do not recurse into arbitrary directories or remove
            # favorites and future formats in this mixed parent directory.
            app_recent_dir="$recent_dir/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            guard_mutation_target "$app_recent_dir" || continue
            while read_find_path recent_file; do
                remove_path "$recent_file"
            done < <(find_checked "$app_recent_dir" -maxdepth 1 -type f \
                \( -name '*.sfl2' -o -name '*.sfl3' -o -name '*.sfl4' \) -print0)
        fi
    done < <(enumerate_users)
    return 0
}

# --- module: spotlight -------------------------------------------------------
module_spotlight() {
    if [ "$TEST_MODE" -eq 1 ]; then
        log_debug "test mode: Spotlight erase-and-rebuild skipped"
    elif [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would erase and rebuild the Spotlight index (mdutil -E)"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    elif command -v mdutil >/dev/null 2>&1; then
        if mdutil -E /System/Volumes/Data >/dev/null 2>&1 \
            || mdutil -E / >/dev/null 2>&1; then
            log_debug "requested Spotlight index erase and rebuild"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            log_warn "mdutil -E failed for both the data volume and /"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        log_warn "mdutil unavailable; cannot erase the Spotlight index"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# --- module: quicklook -------------------------------------------------------
module_quicklook() {
    local u h uid qc
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            log_debug "[DRY RUN] would reset Quick Look cache for user '$u' (qlmanage -r cache)"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        elif [ "$TEST_MODE" -eq 1 ]; then
            log_debug "test mode: Quick Look host cache reset skipped for user '$u'"
        elif ! command -v qlmanage >/dev/null 2>&1; then
            log_debug "qlmanage unavailable; skipping Quick Look reset for user '$u'"
        elif run_as_user "$u" "$uid" "$h" qlmanage -r cache >/dev/null 2>&1; then
            log_debug "reset Quick Look cache for user '$u'"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            log_warn "failed to reset Quick Look cache for user '$u'"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done < <(enumerate_users)
    while read_find_path qc; do
        clear_dir_contents "$qc"
    # Caches sit at <bucket>/<user>/C/. Do not walk the rest of the busy
    # temporary tree, where vanishing files would report traversal failures.
    done < <(find_checked "$VAR_FOLDERS" -mindepth 4 -maxdepth 4 -type d \
        -path '*/C/com.apple.QuickLook.thumbnailcache' -print0)
    return 0
}

# --- module: trash -----------------------------------------------------------
# macOS stat is used in real runs. The fallback permits GNU test hosts.
trash_stat_number() {
    local format="$1" target="$2" value
    value="$(stat -f "$format" "$target" 2>/dev/null || true)"
    case "$value" in
        ''|*[!0-9]*) value="$(stat -c "$format" "$target" 2>/dev/null || true)" ;;
    esac
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

# mounted_volume DIR - succeed when DIR is a separate mounted volume. Sandbox
# fixtures share one device, so test mode accepts every real directory.
mounted_volume() {
    local vol="$1" volume_device parent_device
    [ "$TEST_MODE" -eq 0 ] || return 0
    volume_device="$(trash_stat_number %d "$vol")" || volume_device=''
    parent_device="$(trash_stat_number %d "${vol%/*}")" || parent_device=''
    if [ -z "$volume_device" ] || [ -z "$parent_device" ]; then
        log_warn "cannot identify mounted volume: $vol"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
    [ "$volume_device" != "$parent_device" ]
}

clean_volume_trash_for_home() {
    local h="$1" uid="$2" owner vol trash owner_on_volume
    owner="$(trash_stat_number %u "$h")" || {
        log_warn "cannot identify Trash owner: $h"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    }
    if { [ -n "$uid" ] && [ "$owner" != "$uid" ]; } \
        || { [ "$TEST_MODE" -eq 0 ] && [ "$owner" -eq 0 ]; }; then
        log_warn "refusing inconsistent or root Trash owner: $h"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    uid="$owner"
    while read_find_path vol; do
        # /Volumes/Macintosh HD normally links to /. Never follow mount aliases.
        [ ! -L "$vol" ] && [ -d "$vol" ] || continue
        guard_mutation_target "$vol" || continue
        mounted_volume "$vol" || continue
        trash="$vol/.Trashes/$uid"
        guard_mutation_target "$trash" || continue
        [ -d "$trash" ] || continue
        owner_on_volume="$(trash_stat_number %u "$trash")" || owner_on_volume=''
        if [ "$owner_on_volume" != "$uid" ]; then
            log_warn "refusing Trash with a different owner: $trash"
            [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            log_debug "[DRY RUN] would empty mounted-volume Trash as UID $uid: $trash"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            continue
        fi
        # Drop privileges using the known home owner. Pin the physical Trash
        # directory, then delete without following links or crossing mounts.
        # shellcheck disable=SC2016 # evaluated in the owner-UID child shell
        if run_target_command "$h/" /bin/sh -c '
            cd -P "$1" || exit 1
            [ "$(pwd -P)" = "$1" ] || exit 1
            exec /usr/bin/find . -xdev -depth -mindepth 1 -delete
        ' sh "$trash" 2>/dev/null; then
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            log_debug "emptied mounted-volume Trash: $trash"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log_warn "failed to empty mounted-volume Trash: $trash"
        fi
    done < <(find_checked "$SANDBOX/Volumes" -mindepth 1 -maxdepth 1 -print0)
    return 0
}

module_trash() {
    local u h uid
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        if [ -d "$h/.Trash" ]; then
            # clear_dir_contents enumerates dotfiles too, so hidden Trash
            # entries are removed as well.
            clear_dir_contents "$h/.Trash"
        fi
        if [ "$INCLUDE_VOLUMES" -eq 1 ]; then
            clean_volume_trash_for_home "$h" "$uid"
        fi
    done < <(enumerate_users)
    return 0
}

# --- module: dsstore ---------------------------------------------------------
# Stay on the volume of BASE: the startup disk and other mounts are separate
# targets with their own selection rules.
clean_dsstore_tree() {
    local base="$1"
    local f
    [ -d "$base" ] || return 0
    while read_find_path f; do
        remove_path "$f"
    done < <(find_checked "$base" -xdev \( -name ".Spotlight-V100" -o -name ".Trashes" -o -name ".Trash" \) -prune \
             -o -type f -name ".DS_Store" -print0)
}

module_dsstore() {
    local u h uid vol
    # User homes are the useful default scope; Shared, Guest, hidden entries,
    # and linked homes stay excluded by the common enumerator.
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        clean_dsstore_tree "$h"
        if [ "$TEST_MODE" -eq 1 ]; then
            # The sandbox models the APFS Data view as a separate tree.
            clean_dsstore_tree "$DATA_VOLUME/Users/$u"
        fi
    done < <(enumerate_users)
    if [ "$INCLUDE_VOLUMES" -eq 1 ]; then
        while read_find_path vol; do
            # /Volumes/Macintosh HD normally links to /. Never follow mount
            # aliases, and skip directories on the startup device.
            [ ! -L "$vol" ] && [ -d "$vol" ] || continue
            mounted_volume "$vol" || continue
            clean_dsstore_tree "$vol"
        done < <(find_checked "$SANDBOX/Volumes" -mindepth 1 -maxdepth 1 -print0)
    fi
    return 0
}

# --- module: wifi ------------------------------------------------------------
module_wifi() {
    local f
    remove_path "$SYS_PREFS/com.apple.wifi.known-networks.plist"
    remove_path "$SYS_PREFS/SystemConfiguration/com.apple.airport.preferences.plist"
    remove_path "$SYS_PREFS/SystemConfiguration/com.apple.wifi.message-tracer.plist"
    clear_dir_contents "$SYS_PREFS/SystemConfiguration/com.apple.wifi.known-networks"
    while read_find_path f; do
        truncate_file "$f"
    done < <(find_checked "$VAR_LOG" -maxdepth 1 -type f -name 'wifi.log*' -print0)
    return 0
}

# --- module: headless (explicit selection only) -------------------------------
headless_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(process_list command)"; then
        log_warn "headless: cannot inspect browser processes; cleanup refused"
        return 1
    fi
    if process_match -Ei '(^|/)(Google Chrome|Chromium|chrome|chromium|chrome-headless-shell|headless_shell)([ /]|$)|/(Google Chrome|Chromium|Microsoft Edge|Brave Browser)[^/]*\.app/|(^|[ /])(@playwright|playwright(-core)?|puppeteer(-core)?|chrome-devtools-mcp)([ /]|$)' "$processes"; then
        log_warn "headless: close browsers and browser automation first"
        return 1
    fi
    return 0
}

module_headless() {
    local u h uid root profile leaf recent age
    if [ "$DRY_RUN" -eq 0 ] && ! headless_stopped; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    age=$((HEADLESS_DAYS - 1))
    while IFS=$'\t' read -r u h uid; do
        root="$h/Library/Application Support/Google/Chrome-headless"
        guard_mutation_target "$root" || continue
        [ -d "$root" ] || continue
        while read_find_path profile; do
            leaf="${profile##*/}"
            leaf="${leaf#scoped_dir}"
            case "$leaf" in ''|*[!a-zA-Z0-9]*) continue ;; esac
            guard_mutation_target "$profile" || continue
            # A profile must match the known layout. Never remove an arbitrary
            # similarly named directory, a live lock, or a mounted child.
            [ -d "$profile/Default" ] && [ -f "$profile/Local State" ] || continue
            guard_mutation_target "$profile/Default" || continue
            guard_mutation_target "$profile/Local State" || continue
            if [ -e "$profile/SingletonLock" ] || [ -L "$profile/SingletonLock" ] \
                || [ -e "$profile/SingletonSocket" ] || [ -L "$profile/SingletonSocket" ]; then
                log_warn "headless: locked profile retained: $profile"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                continue
            fi
            # Directory age alone does not show recent writes to existing
            # files. Retain any profile with a recently modified descendant.
            if ! recent="$(find "$profile" -xdev -mtime -"$HEADLESS_DAYS" -print -quit 2>/dev/null)"; then
                log_warn "headless: cannot check profile age: $profile"
                FAILED_COUNT=$((FAILED_COUNT + 1))
                continue
            fi
            [ -z "$recent" ] || continue
            selected_remove_path "$profile"
        done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -type d -name 'scoped_dir*' -mtime +"$age" -print0)
    done < <(enumerate_users)
    return 0
}

# --- module: brew ------------------------------------------------------------
module_brew() {
    local u h uid
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        clear_dir_contents "$h/Library/Caches/Homebrew"
        clear_dir_contents "$h/Library/Logs/Homebrew"
    done < <(enumerate_users)
    return 0
}

# --- module: apps ------------------------------------------------------------
module_apps() {
    local u h uid jd code_base
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        log_debug "apps: processing user '$u' ($h)"
        code_base="$h/Library/Application Support/Code"
        clear_dir_contents "$code_base/Cache"
        clear_dir_contents "$code_base/CachedData"
        clear_dir_contents "$code_base/GPUCache"
        clear_dir_contents "$code_base/logs"
        if [ -d "$h/Library/Logs" ]; then
            while read_find_path jd; do
                clear_dir_contents "$jd"
            done < <(find_checked "$h/Library/Logs" -maxdepth 1 -type d -name 'JetBrains*' -print0)
        fi
    done < <(enumerate_users)
    return 0
}

# --- module: editors ---------------------------------------------------------

# Query once before touching editor history. Do not log process arguments:
# they can contain file names or credentials. Keep editors closed until done.
editors_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(process_list command)"; then
        log_warn "editors: cannot inspect running processes; cleanup refused"
        return 1
    fi
    if process_match -Ei '(^|[ /])(vi|vim|view|ex|rvim|rview|vimdiff|gvim|gvimdiff|mvim|nvim|nvim-qt|code|code-insiders|codium|cursor|windsurf)([[:space:]]|$)|/(Visual Studio Code[^/]*|Code - Insiders|VSCodium|Cursor|Windsurf[^/]*|IntelliJ IDEA[^/]*|PyCharm[^/]*|WebStorm[^/]*|GoLand[^/]*|CLion[^/]*|Rider[^/]*|PhpStorm[^/]*|RubyMine[^/]*|RustRover[^/]*|DataGrip[^/]*|DataSpell[^/]*|Aqua[^/]*|Android Studio[^/]*|MacVim)\.app/|(-Didea\.(paths\.selector|home\.path)=|com\.intellij\.idea\.Main)' "$processes"; then
        log_warn "editors: close supported editors and their background processes first"
        return 1
    fi
    return 0
}

clean_editor_history_for_home() {
    local h="$1" app root product
    for app in Code 'Code - Insiders' VSCodium Cursor Windsurf 'Windsurf - Next'; do
        # VS Code stores local history at appSettingsHome/History. This is
        # shared by its profiles, rather than stored in each profile's settings.
        clear_dir_contents "$h/Library/Application Support/$app/User/History"
    done
    root="$h/Library/Caches/JetBrains"
    if guard_mutation_target "$root" && [ -d "$root" ]; then
        while read_find_path product; do
            clear_dir_contents "$product/LocalHistory"
        done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
    # Only persistent command/search/file state. Swap files, undo files,
    # backup buffers, configuration and plugin data remain in place.
    remove_path "$h/.viminfo"
    clear_dir_contents "$h/.local/state/nvim/shada"
    clear_dir_contents "$h/.local/share/nvim/shada"
    return 0
}

module_editors() {
    local u h uid
    if ! editors_stopped; then
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    fi
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        clean_editor_history_for_home "$h"
    done < <(enumerate_users)
    return 0
}

###############################################################################
# --- module: ai ---------------------------------------------------------------

# Explicit roots are additive. Keep custom paths within the existing home-owner
# security boundary; never evaluate shell configuration to discover a path.
# ai_root_problem KIND PATH - print why an AI root is not acceptable, or
# nothing when it is.
ai_root_problem() {
    local kind="$1" path="$2" relative
    case "$kind" in
        claude|codex|codex-db|opencode|opencode-state|opencode-db|claude-temp|cursor|cursor-editor|windsurf|editor|continue|cline|roo|aider|aider-history) ;;
        *) printf 'unknown AI root kind: %s\n' "$kind"; return 0 ;;
    esac
    case "$path" in
        /Users/*/*) ;;
        *) printf 'AI roots must be below /Users/<user>/: %s\n' "$path"; return 0 ;;
    esac
    case "$path/" in
        *'/../'*|*'/./'*|*'//'*) printf 'AI root must be a normalized absolute path\n'; return 0 ;;
    esac
    case "$path" in
        *$'\n'*|*$'\r'*|*$'\t'*) printf 'AI root must not contain control whitespace\n'; return 0 ;;
    esac
    relative="${path#/Users/}"
    [ -n "${relative#*/}" ] || printf 'AI root cannot be a user home\n'
}

add_ai_root() {
    local kind="${1%%=*}" path="${1#*=}" problem
    path="${path%/}"
    problem="$(ai_root_problem "$kind" "$path")"
    [ -z "$problem" ] || usage_error "$problem"
    AI_ROOTS[${#AI_ROOTS[@]}]="$kind=$path"
}

# add_env_ai_root VARIABLE KIND PATH - add a root derived from the caller's
# environment. An unrelated shell setting must not stop the whole run, so an
# unacceptable value is reported, counted as incomplete cleanup and ignored.
add_env_ai_root() {
    local variable="$1" kind="$2" path="${3%/}" problem
    problem="$(ai_root_problem "$kind" "$path")"
    if [ -n "$problem" ]; then
        log_warn "ai: ignoring $variable: $problem"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    AI_ROOTS[${#AI_ROOTS[@]}]="$kind=$path"
}

ai_environment_roots() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    [ -z "${CONTINUE_GLOBAL_DIR:-}" ] || add_env_ai_root CONTINUE_GLOBAL_DIR continue "$CONTINUE_GLOBAL_DIR"
    if [ -n "${CLINE_DATA_DIR:-}" ]; then
        add_env_ai_root CLINE_DATA_DIR cline "$CLINE_DATA_DIR"
    elif [ -n "${CLINE_DIR:-}" ]; then
        add_env_ai_root CLINE_DIR cline "${CLINE_DIR%/}/data"
    fi
    local history_var history_path problem=""
    for history_var in AIDER_CHAT_HISTORY_FILE AIDER_INPUT_HISTORY_FILE AIDER_LLM_HISTORY_FILE; do
        history_path="${!history_var:-}"
        [ -n "$history_path" ] || continue
        case "$history_path" in /*) ;; *) history_path="$(pwd -P)/$history_path" ;; esac
        add_env_ai_root "$history_var" aider-history "$history_path"
    done
    [ -z "${CLAUDE_CONFIG_DIR:-}" ] || add_env_ai_root CLAUDE_CONFIG_DIR claude "$CLAUDE_CONFIG_DIR"
    [ -z "${CODEX_HOME:-}" ] || add_env_ai_root CODEX_HOME codex "$CODEX_HOME"
    [ -z "${CODEX_SQLITE_HOME:-}" ] || add_env_ai_root CODEX_SQLITE_HOME codex-db "$CODEX_SQLITE_HOME"
    [ -z "${XDG_DATA_HOME:-}" ] || add_env_ai_root XDG_DATA_HOME opencode "${XDG_DATA_HOME%/}/opencode"
    [ -z "${XDG_STATE_HOME:-}" ] || add_env_ai_root XDG_STATE_HOME opencode-state "${XDG_STATE_HOME%/}/opencode"
    AI_CLAUDE_TMP_BASE="${CLAUDE_CODE_TMPDIR:-/private/tmp}"
    AI_CLAUDE_TMP_BASE="${AI_CLAUDE_TMP_BASE%/}"
    case "$AI_CLAUDE_TMP_BASE" in
        /tmp|/tmp/*) AI_CLAUDE_TMP_BASE="/private$AI_CLAUDE_TMP_BASE" ;;
    esac
    case "$AI_CLAUDE_TMP_BASE/" in
        *'/../'*|*'/./'*|*'//'*) problem="must be normalized" ;;
    esac
    case "$AI_CLAUDE_TMP_BASE" in
        *$'\n'*|*$'\r'*|*$'\t'*) problem="must not contain control whitespace" ;;
    esac
    if [ -z "$problem" ]; then
        case "$AI_CLAUDE_TMP_BASE" in
            /private/tmp|/private/tmp/*|/private/var/folders/*|/Users/*/*) ;;
            *) problem="is unsupported; use a home or macOS temp directory" ;;
        esac
    fi
    if [ -n "$problem" ]; then
        log_warn "ai: ignoring CLAUDE_CODE_TMPDIR: it $problem; using /private/tmp"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        AI_CLAUDE_TMP_BASE=/private/tmp
    fi
    if [ -n "${OPENCODE_DB:-}" ] && [ "$OPENCODE_DB" != :memory: ]; then
        case "$OPENCODE_DB" in
            /*) add_env_ai_root OPENCODE_DB opencode-db "$OPENCODE_DB" ;;
            *) add_env_ai_root OPENCODE_DB opencode-db "${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/$OPENCODE_DB" ;;
        esac
    fi
}

# Fail closed on a failed process query. Do not print command lines: they may
# contain prompts or tokens. Node CLI launchers and desktop helpers also match.
ai_agents_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(process_list command)"; then
        log_warn "ai: cannot inspect running processes; cleanup refused"
        return 1
    fi
    if process_match -Ei '(^|[ /])(claude|codex|opencode|cursor-agent|cursor|windsurf|cline|roo|cn|aider)([[:space:]/]|$|\.(js|py)([[:space:]]|$))|/(Codex|Claude|OpenCode|Cursor|Windsurf[^/]*|Visual Studio Code[^/]*|Code - Insiders|VSCodium|IntelliJ IDEA[^/]*|PyCharm[^/]*|WebStorm|GoLand|CLion|Rider|PhpStorm|RubyMine|RustRover|Android Studio)\.app/' "$processes"; then
        log_warn "ai: close AI agents, supported editors and their background servers first"
        return 1
    fi
    return 0
}

# SQLite runs as the home owner, from a checked physical parent. Reject links
# and hard links for the database AND sidecars before SQLite can open them.
# sqlite_stat_tables TABLES - print the SQLite statistics tables in TABLES.
# ANALYZE and PRAGMA optimize create them in any database. sqlite_stat4 keeps
# sampled index values from cleared rows, so clear them with the session data
# instead of refusing the whole database as an unknown schema.
sqlite_stat_tables() {
    printf '%s\n' "$1" | grep -E '^sqlite_stat[1-4]$' | tr '\n' ' ' || true
}

ai_sqlite_command() {
    local db="$1" sqlite_bin="$2" sql
    shift 2
    [ "$#" -eq 1 ] || return 1
    # Only internal SQL templates reach this helper. They have no semicolons
    # inside string literals. Apple's CLI can continue after an error in an
    # argv string or one input line, even with -bail. Send one statement per
    # input line so an error closes the connection before COMMIT.
    sql="${1//;/$';\n'}"
    # shellcheck disable=SC2016
    printf '%s\n' "$sql" | run_target_command "$db" /bin/sh -c '
        db=$1; sqlite=$2; shift 2
        cd -P "${db%/*}" || exit 1
        [ "$(pwd -P)" = "${db%/*}" ] || exit 1
        file=./${db##*/}
        [ -f "$file" ] || exit 1
        for suffix in "" -wal -shm -journal; do
            p=$file$suffix
            [ ! -L "$p" ] || exit 1
            [ -e "$p" ] || continue
            [ -f "$p" ] || exit 1
            links=$(stat -f %l "$p" 2>/dev/null) || links=$(stat -c %h "$p") || exit 1
            [ "$links" = 1 ] || exit 1
        done
        exec "$sqlite" -batch -bail -noheader -init /dev/null "$file"
    ' sh "$db" "$sqlite_bin"
}

# Only known tables are accepted. Mixed databases retain configuration and
# credentials. Unknown tables/triggers fail before DELETE. No fallback to rm.
ai_purge_database() {
    local db="$1" flavor="$2" mode="${3:-clean}" deletes keeps anchor
    local tables table sql allowed="" sqlite_bin version count=0 checkpoint
    guard_mutation_target "$db" || return 1
    [ -e "$db" ] || return 0
    case "$flavor" in
        state)
            anchor=threads
            deletes='threads thread_dynamic_tools thread_spawn_edges thread_attachments guardian_review_feedback thread_read_receipts backfill_state rollout_migration_state rollout_migration_skipped_rollouts'
            keeps='_sqlx_migrations projects project_roots project_idempotency_keys thread_sections remote_control_enrollments external_agent_config_imports'
            ;;
        history)
            anchor=thread_items
            deletes='thread_items thread_turns thread_history_projection_state thread_realtime_items'
            keeps=_sqlx_migrations ;;
        logs) anchor=logs; deletes=logs; keeps='_sqlx_migrations sqlite_sequence' ;;
        goals) anchor=thread_goals; deletes='thread_goals thread_goal_continuation_deferrals'; keeps=_sqlx_migrations ;;
        queue) anchor=queued_items; deletes='queued_items queued_thread_revisions'; keeps='_sqlx_migrations sqlite_sequence' ;;
        memory) anchor=stage1_outputs; deletes='stage1_outputs jobs consolidation_progress'; keeps=_sqlx_migrations ;;
        summaries) anchor=thread_turn_summaries; deletes=thread_turn_summaries; keeps='' ;;
        desktop)
            anchor=automation_runs
            deletes='inbox_items automation_runs local_thread_catalog local_thread_catalog_sync_state local_thread_catalog_metadata local_thread_catalog_scan_checkpoints local_thread_catalog_scan_entries thread_timeline_ledger live_visualization_suggestions active_chat_turns'
            keeps='automations local_app_server_feature_enablement local_thread_catalog_hosts codex_schema_migrations'
            ;;
        opencode)
            anchor='session session_v2'
            deletes='session message part todo session_share session_v2 session_message session_part session_inbox instruction_entry instruction_state instruction_blob blob_ref blob job'
            keeps='__drizzle_migrations migration project project_directory worktree workspace account account_state control_account credential permission kv schedule event event_sequence'
            ;;
        editor|cursor)
            anchor=ItemTable
            deletes=''
            keeps='ItemTable cursorDiskKV composerHeaders'
            ;;
        *) log_warn "ai: unsupported database: $db"; return 1 ;;
    esac
    # Opening a WAL database can create SHM files even for a read-only query.
    # Dry-run must not open SQLite at all.
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$mode" = clean ]; then
            log_debug "[DRY RUN] would clear known session tables (schema checked on real run): $db"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    if [ -z "$sqlite_bin" ]; then
        log_warn "ai: sqlite3 required; database retained: $db"
        return 1
    fi
    if ! tables="$(ai_sqlite_command "$db" "$sqlite_bin" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)"; then
        log_warn "ai: cannot read database safely: $db"
        return 1
    fi
    deletes="$deletes $(sqlite_stat_tables "$tables")"
    for table in $anchor; do
        case $'\n'"$tables"$'\n' in *$'\n'"$table"$'\n'*) count=$((count + 1)) ;; esac
    done
    if [ "$count" -eq 0 ]; then
        log_warn "ai: unrecognized database schema: $db"
        return 1
    fi
    while IFS= read -r table; do
        case " $deletes $keeps " in
            *" $table "*) ;;
            *) log_warn "ai: unsupported database table; database retained: $db"; return 1 ;;
        esac
    done <<< "$tables"
    for table in $deletes $keeps; do allowed="${allowed:+$allowed,}'$table'"; done
    version="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA schema_version;' 2>/dev/null)" || return 1
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    # The checks run again under a write lock. Disable cascades so new foreign
    # keys cannot delete preserved settings. All session tables are explicit.
    sql="PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=OFF; PRAGMA secure_delete=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE shredder_check (ok INTEGER CHECK (ok=1));
INSERT INTO shredder_check SELECT schema_version=$version FROM pragma_schema_version;
INSERT INTO shredder_check SELECT COUNT(*)=0 FROM sqlite_master WHERE type='trigger' OR (type='table' AND name NOT IN ($allowed));"
    if [ "$mode" = clean ]; then
        if [ "$flavor" = editor ] || [ "$flavor" = cursor ]; then
            # VS Code Mementos contain both settings and history. Never remove
            # an entire extension record or any secret:// row.
            sql="$sql
INSERT INTO shredder_check SELECT COUNT(*)=0 FROM ItemTable
 WHERE key IN ('saoudrizwan.claude-dev','rooveterinaryinc.roo-cline')
 AND CASE WHEN json_valid(CAST(value AS TEXT)) THEN json_type(CAST(value AS TEXT))!='object' ELSE 1 END;
UPDATE ItemTable SET value=json_remove(CAST(value AS TEXT),'$.taskHistory')
 WHERE key IN ('saoudrizwan.claude-dev','rooveterinaryinc.roo-cline');"
            if [ "$flavor" = cursor ]; then
                sql="$sql DELETE FROM ItemTable WHERE key IN ('aiService.prompts','aiService.generations','workbench.panel.aichat.view.aichat.chatdata','composer.composerData');"
                case $'\n'"$tables"$'\n' in
                    *$'\n'cursorDiskKV$'\n'*)
                        sql="$sql DELETE FROM cursorDiskKV WHERE key GLOB 'composerData:*' OR key GLOB 'bubbleId:*' OR key GLOB 'checkpointId:*' OR key GLOB 'agentKv:*';" ;;
                esac
                case $'\n'"$tables"$'\n' in
                    *$'\n'composerHeaders$'\n'*) sql="$sql DELETE FROM composerHeaders;" ;;
                esac
            fi
        fi
        if [ "$flavor" = opencode ]; then
            sql="$sql CREATE TEMP TABLE shredder_sessions(id TEXT);"
            for table in session session_v2; do
                case $'\n'"$tables"$'\n' in
                    *$'\n'"$table"$'\n'*) sql="$sql INSERT INTO shredder_sessions SELECT id FROM \"$table\";" ;;
                esac
            done
            # The event store can also contain non-session aggregates. Preserve
            # those; include orphan session aggregates left by earlier cleanup.
            for table in event event_sequence; do
                case $'\n'"$tables"$'\n' in
                    *$'\n'"$table"$'\n'*) sql="$sql DELETE FROM \"$table\" WHERE aggregate_id IN (SELECT id FROM shredder_sessions) OR aggregate_id GLOB 'ses_*';" ;;
                esac
            done
            sql="$sql DROP TABLE shredder_sessions;"
        fi
        for table in $deletes; do
            case $'\n'"$tables"$'\n' in
                *$'\n'"$table"$'\n'*) sql="$sql DELETE FROM \"$table\"; INSERT INTO shredder_check SELECT COUNT(*)=0 FROM \"$table\";" ;;
            esac
        done
        # Standalone schedules are user configuration; session schedules would
        # otherwise recreate work for deleted chats.
        if [ "$flavor" = opencode ]; then
            case $'\n'"$tables"$'\n' in
                *$'\n'schedule$'\n'*) sql="$sql DELETE FROM schedule WHERE session_id IS NOT NULL;" ;;
            esac
        fi
    fi
    sql="$sql DROP TABLE shredder_check; COMMIT;"
    if ! ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1; then
        log_warn "ai: database transaction refused or failed: $db"
        return 1
    fi
    [ "$mode" = clean ] || return 0
    # Compact freed pages and drain WAL through SQLite, never unlink a live WAL.
    if ! ai_sqlite_command "$db" "$sqlite_bin" 'VACUUM;' >/dev/null 2>&1; then
        log_warn "ai: database compaction failed: $db"
        return 1
    fi
    checkpoint="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>/dev/null)" || return 1
    case "$checkpoint" in 0\|*) ;; *) log_warn "ai: database checkpoint is busy: $db"; return 1 ;; esac
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
    log_debug "cleared session tables: $db"
}

ai_database_flavor() {
    case "${1##*/}" in
        state_[0-9]*.sqlite) printf state ;;
        thread_history_[0-9]*.sqlite) printf history ;;
        logs_[0-9]*.sqlite) printf logs ;;
        goals_[0-9]*.sqlite) printf goals ;;
        queue_[0-9]*.sqlite) printf queue ;;
        memories_[0-9]*.sqlite|memories_v2_[0-9]*.sqlite) printf memory ;;
        codex-thread-summaries*.db) printf summaries ;;
        codex.db|codex-dev.db) printf desktop ;;
        opencode.db|opencode-*.db) printf opencode ;;
        *) return 1 ;;
    esac
}

ai_databases_in() {
    local root="$1" kind="$2" mode="$3" db flavor before="$FAILED_COUNT" step_before
    guard_mutation_target "$root" || return 1
    [ -d "$root" ] || return 0
    while read_find_path db; do
        case "$db" in
            *-wal|*-shm|*-journal)
                if [ ! -f "${db%-*}" ]; then
                    log_warn "ai: orphan database sidecar retained for recovery: $db"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
                continue ;;
        esac
        if ! flavor="$(ai_database_flavor "$db")"; then
            log_warn "ai: unknown database retained: $db"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi
        if [ "$kind" = opencode ] && [ "$flavor" != opencode ]; then
            log_warn "ai: unexpected database retained: $db"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi
        [ "$flavor" != memory ] || [ "$AI_DERIVED" -eq 1 ] || continue
        step_before="$FAILED_COUNT"
        if ! ai_purge_database "$db" "$flavor" "$mode"; then
            count_failure_since "$step_before"
        fi
    done < <(find_checked "$root" -mindepth 1 -maxdepth 1 \( -name '*.sqlite' -o -name '*.db' \
        -o -name '*.sqlite-wal' -o -name '*.sqlite-shm' -o -name '*.sqlite-journal' \
        -o -name '*.db-wal' -o -name '*.db-shm' -o -name '*.db-journal' \) -print0)
    [ "$FAILED_COUNT" -eq "$before" ]
}

ai_remove_list() {
    local root="$1" item
    shift
    for item in "$@"; do remove_path "$root/$item"; done
}

# Mixed JSON stores contain prompt history beside preferences. Use SQLite JSON
# functions (already required for AI databases), not a new runtime dependency.
ai_clean_json() {
    local file="$1" flavor="$2" hex sqlite_bin sql value_json
    guard_mutation_target "$file" || return 0
    [ -e "$file" ] || return 0
    if [ ! -f "$file" ]; then
        log_warn "ai: expected a JSON state file: $file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would remove session fields from: $file"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || { log_warn "ai: sqlite3 required for JSON cleanup: $file"; FAILED_COUNT=$((FAILED_COUNT + 1)); return 0; }
    hex="$(printf '%s' "${file##*/}" | od -An -v -tx1 | tr -d ' \n')"
    # Rebuild each object once instead of copying the entire document for each
    # thread key. Explicit types preserve booleans, nulls, arrays and strings.
    value_json="json(CASE type WHEN 'text' THEN json_quote(value) WHEN 'true' THEN 'true' WHEN 'false' THEN 'false' WHEN 'null' THEN 'null' ELSE value END)"
    sql="WITH input(doc) AS (SELECT CAST(readfile(CAST(X'$hex' AS TEXT)) AS TEXT)),
original(doc) AS (SELECT CASE WHEN json_type(doc)='object' THEN json(doc) ELSE json('unsupported state shape') END FROM input)"
    case "$flavor" in
        codex)
            sql="$sql, atoms(doc) AS (SELECT CASE WHEN json_type(doc,'$.\"electron-persisted-atom-state\"')='object'
THEN json_set(doc,'$.\"electron-persisted-atom-state\"',json((SELECT json_group_object(key,$value_json) FROM json_each(doc,'$.\"electron-persisted-atom-state\"') WHERE key NOT GLOB 'thread-*' AND key NOT IN ('prompt-history','composer-prompt-drafts-v1','heartbeat-thread-permissions-by-id')))) ELSE doc END FROM original)
SELECT json_group_object(key,$value_json) FROM atoms,json_each(doc) WHERE key NOT GLOB 'thread-*' AND key NOT IN ('prompt-history','composer-prompt-drafts-v1','heartbeat-thread-permissions-by-id');"
            ;;
        claude)
            sql="$sql SELECT CASE WHEN json_type(doc,'$.projects')='object' THEN
json_set(json_remove(doc,'$.history','$.lastSessionId'),'$.projects',json((SELECT json_group_object(key,json_remove($value_json,'$.history','$.lastSessionId')) FROM json_each(doc,'$.projects'))))
ELSE json_remove(doc,'$.history','$.lastSessionId') END FROM original;"
            ;;
        task-state)
            sql="$sql SELECT json_remove(doc,'$.taskHistory') FROM original;"
            ;;
        *) return 1 ;;
    esac
    # shellcheck disable=SC2016
    if run_target_command "$file" /bin/sh -c '
        file=$1; sqlite=$2; sql=$3
        cd -P "${file%/*}" || exit 1
        [ "$(pwd -P)" = "${file%/*}" ] || exit 1
        file=./${file##*/}
        [ -f "$file" ] && [ ! -L "$file" ] || exit 1
        links=$(stat -f %l "$file" 2>/dev/null) || links=$(stat -c %h "$file") || exit 1
        [ "$links" = 1 ] || exit 1
        umask 077
        tmp=$(mktemp ./.shredder-json.XXXXXX) || exit 1
        trap '\''rm -f -- "$tmp"'\'' EXIT HUP INT TERM
        "$sqlite" -batch -bail -init /dev/null :memory: "$sql" > "$tmp" || exit 1
        [ -s "$tmp" ] || exit 1
        # Keep the original permission bits. The atomic rename does not
        # carry extended attributes or ACLs; these state files use neither.
        mode=$(stat -f %Lp "$file" 2>/dev/null) || mode=$(stat -c %a "$file") || exit 1
        chmod "$mode" "$tmp" || exit 1
        mv -f -- "$tmp" "$file"
    ' sh "$file" "$sqlite_bin" "$sql" >/dev/null 2>&1; then
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "ai: JSON cleanup failed; original retained: $file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}
# Only the standard Aider history filenames are discovered automatically. Do
# not traverse Git objects, dependencies, application stores or other volumes.
ai_clean_aider_tree() {
    local root="$1" entry
    guard_mutation_target "$root" || return 0
    [ -d "$root" ] || return 0
    while read_find_path entry; do remove_path "$entry"; done < <(
        find_checked "$root" -xdev \
            \( -type d \( -name .git -o -name node_modules -o -name .venv -o -name Library \
                -o -name .Trash -o -name .cache -o -name .local -o -name .config \
                -o -name .codex -o -name .claude -o -name .cursor -o -name .cline \
                -o -name .continue -o -name .codeium \) \) -prune -o \
            \( -type f -o -type l \) \( -name .aider.chat.history.md -o -name .aider.input.history \
                -o -name .aider.llm.history \) -print0)
}

ai_editor_databases_in() {
    local dir="$1" flavor="$2" mode="$3" db before="$FAILED_COUNT" step_before
    guard_mutation_target "$dir" || return 1
    while read_find_path db; do
        case "${db##*/}" in
            *-wal|*-shm|*-journal)
                if [ ! -f "${db%-*}" ]; then
                    log_warn "ai: orphan editor database sidecar retained: $db"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi
                ;;
            state.vscdb|state.vscdb.backup)
                step_before="$FAILED_COUNT"
                if ! ai_purge_database "$db" "$flavor" "$mode"; then count_failure_since "$step_before"; fi ;;
            *)
                log_warn "ai: unsupported editor database copy retained: $db"
                FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
        esac
    done < <(find_checked "$dir" -mindepth 1 -maxdepth 1 -name 'state.vscdb*' -print0)
    [ "$FAILED_COUNT" -eq "$before" ]
}

# ROOT is an editor's User directory, not all of Application Support. Named
# profiles and workspace stores use the same row-level cleanup as the default.
ai_clean_editor() {
    local root="$1" kind="$2" profile bucket phase before="$FAILED_COUNT" flavor=editor
    local profiles=("$root") buckets=()
    [ "$kind" != cursor-editor ] || flavor=cursor
    guard_mutation_target "$root/profiles" || return 0
    while read_find_path profile; do
        guard_mutation_target "$profile" || continue
        [ -d "$profile" ] || continue
        profiles[${#profiles[@]}]="$profile"
    done < <(find_checked "$root/profiles" -mindepth 1 -maxdepth 1 -print0)
    for profile in "${profiles[@]}"; do
        buckets[${#buckets[@]}]="$profile/globalStorage"
        guard_mutation_target "$profile/workspaceStorage" || continue
        while read_find_path bucket; do
            guard_mutation_target "$bucket" || continue
            [ -d "$bucket" ] || continue
            buckets[${#buckets[@]}]="$bucket"
        done < <(find_checked "$profile/workspaceStorage" -mindepth 1 -maxdepth 1 -print0)
    done
    [ "$FAILED_COUNT" -eq "$before" ] || return 0
    for phase in check clean; do
        for bucket in "${buckets[@]}"; do
            ai_editor_databases_in "$bucket" "$flavor" "$phase" || return 0
        done
    done
    for profile in "${profiles[@]}"; do
        ai_clean_root cline "$profile/globalStorage/saoudrizwan.claude-dev"
        ai_clean_root roo "$profile/globalStorage/rooveterinaryinc.roo-cline"
    done
}

ai_clean_root() {
    local kind="$1" root="$2" project entry phase step_before
    guard_mutation_target "$root" || return 0
    [ -e "$root" ] || return 0
    if [ "$kind" != opencode-db ] && [ "$kind" != aider-history ] && [ ! -d "$root" ]; then
        log_warn "ai: expected a storage directory: $root"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    case "$kind" in
        editor|cursor-editor)
            ai_clean_editor "$root" "$kind"
            return 0 ;;
        aider) ai_clean_aider_tree "$root"; return 0 ;;
        aider-history)
            if [ -f "$root" ]; then remove_path "$root"; else
                log_warn "ai: expected an Aider history file: $root"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 0 ;;
        codex|codex-db|opencode)
            # Preflight all known databases in this root before any data cleanup.
            for phase in check clean; do
                ai_databases_in "$root" "$kind" "$phase" || return 0
                if [ "$kind" = codex ]; then
                    ai_databases_in "$root/sqlite" "$kind" "$phase" || return 0
                fi
            done
            ;;
        opencode-db)
            step_before="$FAILED_COUNT"
            if ! ai_purge_database "$root" opencode; then count_failure_since "$step_before"; fi
            return 0 ;;
    esac
    case "$kind" in
        cursor)
            remove_path "$root/chats"
            guard_mutation_target "$root/projects" || return 0
            while read_find_path project; do
                guard_mutation_target "$project" || continue
                remove_path "$project/agent-transcripts"
            done < <(find_checked "$root/projects" -mindepth 1 -maxdepth 1 -type d -print0)
            ;;
        windsurf)
            # Cascade also holds local settings. Only UUID-named conversation
            # protobufs are removed; configuration and other files survive.
            guard_mutation_target "$root/cascade" || return 0
            while read_find_path entry; do
                if printf '%s\n' "${entry##*/}" | grep -E '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}\.pb$' >/dev/null; then
                    remove_path "$entry"
                fi
            done < <(find_checked "$root/cascade" -mindepth 1 -maxdepth 1 -print0)
            ;;
        continue) remove_path "$root/sessions" ;;
        cline|roo)
            ai_clean_json "$root/globalState.json" task-state
            ai_remove_list "$root" tasks checkpoints
            if [ "$kind" = cline ]; then
                ai_remove_list "$root" sessions logs
                remove_path "$root/state/taskHistory.json"
                remove_sqlite_db "$root/db/sessions.db"
            fi
            ;;
        claude)
            # A refused projects link must not skip the other Claude stores.
            if guard_mutation_target "$root/projects"; then
                while read_find_path project; do
                    guard_mutation_target "$project" || continue
                    [ -d "$project" ] || continue
                    while read_find_path entry; do
                        case "${entry##*/}" in
                            memory) [ "$AI_DERIVED" -eq 1 ] || continue ;;
                            *.jsonl|*.jsonl.*|sessions-index.json|????????-????-????-????-????????????) ;;
                            *) continue ;;
                        esac
                        remove_path "$entry"
                    done < <(find_checked "$project" -mindepth 1 -maxdepth 1 -print0)
                done < <(find_checked "$root/projects" -mindepth 1 -maxdepth 1 -print0)
            fi
            ai_remove_list "$root" history.jsonl file-history debug logs paste-cache image-cache uploads \
                session-env shell-snapshots tasks teams sessions transcripts feedback-bundles stats-cache.json jobs
            ai_clean_json "$root/.claude.json" claude
            while read_find_path entry; do ai_clean_json "$entry" claude; done < <(
                find_checked "$root/backups" -mindepth 1 -maxdepth 1 -name '*.json*' -print0)
            if [ "$AI_DERIVED" -eq 1 ]; then ai_remove_list "$root" plans agent-memory; fi
            ;;
        codex)
            ai_remove_list "$root" sessions archived_sessions history.jsonl session_index.jsonl \
                shell_snapshots log attachments transcription-history.jsonl dictation-history
            while read_find_path entry; do ai_clean_json "$entry" codex; done < <(
                find_checked "$root" -mindepth 1 -maxdepth 1 \( -name '.codex-global-state.json*' -o -name '..codex-global-state.json.tmp-*' \) -print0)
            if [ "$AI_DERIVED" -eq 1 ]; then
                ai_remove_list "$root" memories memories_v2 plans artifacts generated_images visualizations
                while read_find_path entry; do remove_path "$entry"; done < <(
                    find_checked "$root" -maxdepth 1 -type f \( -name 'memories*.tgz' -o -name 'memories*.tar.gz' \) -print0)
            fi
            ;;
        opencode)
            ai_remove_list "$root" log snapshot tool-output
            # Legacy JSON stores share their parent with project configuration.
            ai_remove_list "$root/storage" session message part session_diff todo session_share
            ;;
        opencode-state) ai_remove_list "$root" prompt-history.jsonl session.json ;;
        claude-temp) clear_dir_contents "$root" ;;
    esac
    return 0
}

# macOS Claude scratchpads live outside the home. Only enter the exact UID tree
# as that home's owner; a link, wrong owner or renamed parent is refused.
ai_claude_temp() {
    local home="$1" uid="$2" root
    case "$uid" in
        ''|*[!0-9]*)
            uid="$(stat -f %u "$home" 2>/dev/null)" || uid="$(stat -c %u "$home" 2>/dev/null)" || uid=''
            ;;
    esac
    case "$uid" in
        ''|*[!0-9]*) log_warn "ai: cannot determine scratchpad owner: $home"; FAILED_COUNT=$((FAILED_COUNT + 1)); return 0 ;;
    esac
    root="$SANDBOX$AI_CLAUDE_TMP_BASE/claude-$uid"
    [ -e "$root" ] || [ -L "$root" ] || return 0
    guard_mutation_target "$root" || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear Claude scratchpads: $root"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    # shellcheck disable=SC2016
    if run_target_command "$home/.claude" /bin/sh -c '
        [ ! -L "$1" ] || exit 1
        cd -P "$1" || exit 1
        [ "$(pwd -P)" = "$1" ] || exit 1
        owner=$(stat -f %u . 2>/dev/null) || owner=$(stat -c %u .) || exit 1
        [ "$owner" = "$(id -u)" ] || exit 1
        find . -mindepth 1 -maxdepth 1 -exec /bin/rm -rf -- {} +
    ' sh "$root" >/dev/null 2>&1; then
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "ai: scratchpad cleanup refused or failed: $root"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

# Additional desktop and plugin stores are opt-in. Never print process command
# lines: they can contain prompts, account identifiers or authentication data.
ai_extended_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(process_list command)"; then
        log_warn "ai: cannot inspect extended clients; cleanup refused"
        return 1
    fi
    if process_match -Ei '(^|[ /])(gemini|antigravity(-cli|-ide)?|agy|serena|serena-mcp-server|context-mode|mcp-server-context-mode)([[:space:]/.]|$)|/(ChatGPT[^/]*|Antigravity[^/]*|Claude)\.app/|@google/gemini-cli/|/context-mode/|/serena/' "$processes"; then
        log_warn "ai: close Gemini, Antigravity, ChatGPT, Claude Desktop, Serena and context-mode servers first"
        return 1
    fi
    return 0
}

# The schemas below contain session data only. Keep schema/version tables and
# delete through SQLite, including virtual FTS tables and their shadow pages.
# Observed Antigravity/context-mode schemas were inspected without reading rows.
ai_extended_database() {
    local db="$1" flavor="$2" mode="${3:-clean}" anchor deletes keeps='' table tables allowed='' sql sqlite_bin version checkpoint
    if [ ! -e "$db" ] && [ ! -L "$db" ]; then
        for table in -wal -shm -journal; do
            if [ -e "$db$table" ] || [ -L "$db$table" ]; then
                log_warn "ai: orphan extended database sidecar retained: $db$table"
                return 1
            fi
        done
        return 0
    fi
    guard_mutation_target "$db" || return 1
    case "$flavor" in
        antigravity-summary)
            anchor=conversation_summaries
            deletes='conversation_summaries conversations_fts'
            keeps='search_schema_version conversations_fts_config conversations_fts_content conversations_fts_data conversations_fts_docsize conversations_fts_idx'
            ;;
        antigravity-session)
            anchor=trajectory_meta
            deletes='battle_mode_infos executor_metadata gen_metadata parent_references steps trajectory_meta trajectory_metadata_blob'
            ;;
        context-session)
            anchor=session_events
            deletes='session_events session_meta session_resume tool_calls'
            keeps=sqlite_sequence
            ;;
        context-content)
            anchor=sources
            deletes='chunks chunks_trigram sources vocabulary'
            keeps='sqlite_sequence chunks_config chunks_content chunks_data chunks_docsize chunks_idx chunks_trigram_config chunks_trigram_content chunks_trigram_data chunks_trigram_docsize chunks_trigram_idx'
            ;;
        *) return 1 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ "$mode" = clean ]; then
            log_debug "[DRY RUN] would clear extended session database (schema checked on real run): $db"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        fi
        return 0
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || { log_warn "ai: sqlite3 required; database retained: $db"; return 1; }
    tables="$(ai_sqlite_command "$db" "$sqlite_bin" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)" || return 1
    case $'\n'"$tables"$'\n' in *$'\n'"$anchor"$'\n'*) ;; *) return 1 ;; esac
    deletes="$deletes $(sqlite_stat_tables "$tables")"
    while IFS= read -r table; do
        case " $deletes $keeps " in *" $table "*) ;; *) return 1 ;; esac
    done <<< "$tables"
    for table in $deletes $keeps; do allowed="${allowed:+$allowed,}'$table'"; done
    version="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA schema_version;' 2>/dev/null)" || return 1
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    sql="PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=OFF; PRAGMA secure_delete=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE extended_check(ok INTEGER CHECK(ok=1));
INSERT INTO extended_check SELECT schema_version=$version FROM pragma_schema_version;
INSERT INTO extended_check SELECT COUNT(*)=0 FROM sqlite_master WHERE type IN ('trigger','view') OR (type='table' AND name NOT IN ($allowed));"
    if [ "$mode" = clean ]; then
        for table in $deletes; do
            case $'\n'"$tables"$'\n' in
                *$'\n'"$table"$'\n'*) sql="$sql DELETE FROM \"$table\"; INSERT INTO extended_check SELECT COUNT(*)=0 FROM \"$table\";" ;;
            esac
        done
    fi
    sql="$sql DROP TABLE extended_check; COMMIT;"
    ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1 || return 1
    [ "$mode" = clean ] || return 0
    ai_sqlite_command "$db" "$sqlite_bin" 'VACUUM;' >/dev/null 2>&1 || return 1
    checkpoint="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>/dev/null)" || return 1
    case "$checkpoint" in 0\|*) ;; *) return 1 ;; esac
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
    return 0
}

ai_extended_db_directory() {
    local root="$1" flavor="$2" mode="$3" entry before="$FAILED_COUNT" step_before
    guard_mutation_target "$root" || return 1
    while read_find_path entry; do
        case "${entry##*/}" in
            *.db)
                step_before="$FAILED_COUNT"
                if ! ai_extended_database "$entry" "$flavor" "$mode"; then
                    log_warn "ai: unsupported or busy extended session database retained: $entry"
                    count_failure_since "$step_before"
                fi ;;
            *.db-wal|*.db-shm|*.db-journal)
                if [ ! -f "${entry%-*}" ]; then
                    log_warn "ai: orphan extended database sidecar retained: $entry"
                    FAILED_COUNT=$((FAILED_COUNT + 1))
                fi ;;
            *)
                log_warn "ai: unknown extended database recovery copy retained: $entry"
                FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
        esac
    done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -name '*.db*' -print0)
    [ "$before" -eq "$FAILED_COUNT" ]
}

ai_extended_antigravity() {
    local root="$1" phase entry before="$FAILED_COUNT" stem
    guard_mutation_target "$root" || return 0
    [ -d "$root" ] || return 0
    for phase in check clean; do
        if ! ai_extended_database "$root/conversation_summaries.db" antigravity-summary "$phase"; then
            log_warn "ai: unsupported or busy conversation index retained: $root/conversation_summaries.db"
            count_failure_since "$before"
            return 0
        fi
        ai_extended_db_directory "$root/conversations" antigravity-session "$phase" || return 0
    done
    [ "$before" -eq "$FAILED_COUNT" ] || return 0
    # Older releases use one protobuf file per conversation. Never delete
    # arbitrary settings or other files from this directory.
    while read_find_path entry; do
        stem="${entry##*/}"; stem="${stem%.pb}"
        if printf '%s\n' "$stem" | grep -E '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' >/dev/null; then
            remove_path "$entry"
        fi
    done < <(find_checked "$root/conversations" -mindepth 1 -maxdepth 1 -name '*.pb' -print0)
    ai_remove_list "$root" history.jsonl cli.log agyhub_summaries_proto.pb jetbox_summaries_proto.pb
}

ai_extended_context() {
    local root="$1" phase entry
    guard_mutation_target "$root" || return 0
    [ -d "$root" ] || return 0
    for phase in check clean; do
        ai_extended_db_directory "$root/sessions" context-session "$phase" || return 0
        ai_extended_db_directory "$root/content" context-content "$phase" || return 0
    done
    while read_find_path entry; do remove_path "$entry"; done < <(
        find_checked "$root/sessions" -mindepth 1 -maxdepth 1 -type f -name 'stats-pid-[0-9]*.json' -print0)
}

ai_extended_home() {
    local h="$1" root project entry account org name
    # Gemini leaves binaries and project metadata beside its conversation
    # directories. Only known conversation/checkpoint paths are selected.
    # Each store has its own guard: a refused link skips only that store.
    root="$h/.gemini/tmp"
    if guard_mutation_target "$root"; then
        while read_find_path project; do
            guard_mutation_target "$project" || continue
            [ -d "$project" ] || continue
            ai_remove_list "$project" chats checkpoints logs.json
        done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -print0)
    fi
    if [ "$AI_DERIVED" -eq 1 ]; then
        # This is Gemini's dedicated shadow Git store, not project Git data.
        remove_path "$h/.gemini/history"
    fi
    for name in antigravity antigravity-cli antigravity-ide; do
        ai_extended_antigravity "$h/.gemini/$name"
    done
    root="$h/Library/Application Support/com.openai.chat"
    if guard_mutation_target "$root"; then
        while read_find_path entry; do
            name="${entry##*/}"
            if printf '%s\n' "$name" | grep -E '^(conversations|drafts)-v[0-9]+-.+$' >/dev/null; then
                guard_mutation_target "$entry" || continue
                [ ! -d "$entry" ] || remove_path "$entry"
            fi
        done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -print0)
    fi
    # The desktop parent also contains plugins, schedules and preferences.
    # Session directories alone are disposable; account/org directories remain.
    root="$h/Library/Application Support/Claude/local-agent-mode-sessions"
    if guard_mutation_target "$root"; then
        while read_find_path account; do
            name="${account##*/}"
            printf '%s\n' "$name" | grep -E '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' >/dev/null || continue
            guard_mutation_target "$account" || continue
            while read_find_path org; do
                name="${org##*/}"
                printf '%s\n' "$name" | grep -E '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' >/dev/null || continue
                guard_mutation_target "$org" || continue
                while read_find_path entry; do
                    name="${entry##*/}"
                    if printf '%s\n' "$name" | grep -E '^local_[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' >/dev/null; then
                        guard_mutation_target "$entry" || continue
                        remove_path "$entry"
                    fi
                done < <(find_checked "$org" -mindepth 1 -maxdepth 1 -print0)
                ai_clean_json "$org/.claude.json" claude
                while read_find_path entry; do ai_clean_json "$entry" claude; done < <(
                    find_checked "$org" -mindepth 1 -maxdepth 1 -name '.claude.json.backup*' -print0)
            done < <(find_checked "$account" -mindepth 1 -maxdepth 1 -type d -print0)
        done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -type d -print0)
    fi
    ai_extended_context "$h/.claude/context-mode"
    clear_dir_contents "$h/.serena/logs"
}

module_ai() {
    local u h uid item path kind matched processed=''
    if [ "${AI_EXTENDED:-0}" -eq 1 ] && ! ai_extended_stopped; then
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    fi
    if ! ai_agents_stopped; then
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    fi
    log_info "ai: local sessions only; credentials, settings and working trees are preserved"
    [ "$AI_DERIVED" -eq 1 ] || log_info "ai: memory, plans and generated artifacts are preserved (use --ai-derived to include them)"
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        ai_clean_root claude "$h/.claude"
        ai_clean_json "$h/.claude.json" claude
        while read_find_path path; do ai_clean_json "$path" claude; done < <(
            find_checked "$h" -mindepth 1 -maxdepth 1 -name '.claude.json.backup*' -print0)
        ai_clean_root codex "$h/.codex"
        ai_clean_root opencode "$h/.local/share/opencode"
        ai_clean_root opencode-state "$h/.local/state/opencode"
        ai_clean_root cursor "$h/.cursor"
        ai_clean_root windsurf "$h/.codeium/windsurf"
        ai_clean_root continue "$h/.continue"
        ai_clean_root cline "$h/.cline/data"
        ai_clean_aider_tree "$h"
        for kind in Code 'Code - Insiders' VSCodium Cursor Windsurf 'Windsurf - Next'; do
            if [ "$kind" = Cursor ]; then item='cursor-editor'; else item=editor; fi
            ai_clean_root "$item" "$h/Library/Application Support/$kind/User"
        done
        clear_dir_contents "$h/Library/Logs/com.openai.codex"
        ai_claude_temp "$h" "$uid"
        if [ "${AI_EXTENDED:-0}" -eq 1 ]; then ai_extended_home "$h"; fi
        for item in "${AI_ROOTS[@]:-}"; do
            [ -n "$item" ] || continue
            kind="${item%%=*}"; path="$SANDBOX${item#*=}"
            case "$path" in "$h"/*) ;; *) continue ;; esac
            ai_clean_root "$kind" "$path"
            processed="$processed
$item"
        done
    done < <(enumerate_users)
    for item in "${AI_ROOTS[@]:-}"; do
        [ -n "$item" ] || continue
        matched=0
        while IFS= read -r path; do [ "$path" != "$item" ] || matched=1; done <<< "$processed"
        if [ "$matched" -eq 0 ]; then
            log_warn "ai: custom root has no eligible user home: ${item#*=}"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done
    return 0
}

###############################################################################
# SECTION: Dispatch, summary and main flow
###############################################################################

# --- module: slackexport -----------------------------------------------------

# path_listed PATH [ENTRY...] - succeed when PATH is one of the entries. A
# repeated path option would otherwise process the same target twice.
path_listed() {
    local path="$1" entry
    shift
    for entry in "$@"; do
        [ "$entry" != "$path" ] || return 0
    done
    return 1
}

add_slack_export_root() {
    local path="$1" relative user rest
    case "$path" in
        /Users/*/*) ;;
        *) usage_error "Slack export roots must be absolute paths below /Users/<user>/" ;;
    esac
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..|*/|*$'\n'*|*$'\r'*|*$'\t'*)
            usage_error "Slack export roots must be normalized directory paths" ;;
    esac
    relative="${path#/Users/}"
    user="${relative%%/*}"
    rest="${relative#*/}"
    case "$user" in ''|Shared|Guest|.*) usage_error "ineligible Slack export home" ;; esac
    case "$rest" in
        ''|Desktop|Documents|Downloads|Library|Applications|Public|Pictures|Movies|Music)
            usage_error "select a dedicated Slack export directory, not a general user directory" ;;
    esac
    path_listed "$path" ${SLACK_EXPORT_ROOTS[@]+"${SLACK_EXPORT_ROOTS[@]}"} && return 0
    SLACK_EXPORT_ROOTS+=("$path")
}

slack_exporters_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    processes="$(process_list command)" || return 1
    if process_match -Ei '^[[:space:]]*([^[:space:]]*/)?(slackdump([^[:space:]/]*)?|slack[-_](export|sync)[^[:space:]/]*)([[:space:]]|$)|^[[:space:]]*([^[:space:]]*/)?(bash|sh|zsh|python[0-9.]*|node|ruby|perl)([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]]*(slack[-_](export|sync)|slack[_-]dump/[^[:space:]]*(sync|export))[^[:space:]]*([[:space:]]|$)' "$processes"; then
        return 1
    fi
    return 0
}

# Read JSON through an in-memory SQLite database. Export SQLite files are never
# opened, including in dry-run. SQL path literals are escaped, never evaluated.
slack_export_json() {
    local path="$1" kind="$2" escaped sqlite_bin sql quote="'"
    guard_mutation_target "$path" || return 1
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || return 1
    escaped="${path//$quote/$quote$quote}"
    sql="CREATE TEMP TABLE metadata(doc TEXT NOT NULL CHECK(json_valid(doc) AND json_type(doc)='array'));
INSERT INTO metadata VALUES(CAST(readfile('$escaped') AS TEXT));
CREATE TEMP TABLE valid(ok INTEGER CHECK(ok=1));
INSERT INTO valid SELECT COUNT(*)=0 FROM metadata,json_each(doc) WHERE type!='object';"
    if [ "$kind" = channels ]; then
        sql="$sql
CREATE TEMP TABLE names(name TEXT NOT NULL);
INSERT INTO names SELECT CASE WHEN json_type(value,'$.name')='text' THEN json_extract(value,'$.name') WHEN json_type(value,'$.id')='text' THEN json_extract(value,'$.id') END FROM metadata,json_each(doc);
INSERT INTO valid SELECT COUNT(*)=0 FROM names WHERE name='' OR name IN ('.','..') OR substr(name,1,1)='.' OR instr(name,'/')>0 OR instr(name,char(92))>0 OR instr(name,char(0))>0 OR instr(name,char(9))>0 OR instr(name,char(10))>0 OR instr(name,char(13))>0;
SELECT DISTINCT name FROM names;"
    elif [ "$kind" = users ]; then
        sql="$sql
INSERT INTO valid SELECT COUNT(*)=0 FROM metadata,json_each(doc) WHERE json_type(value,'$.id') IS NOT 'text';"
    fi
    # Apple's CLI can run later statements of one argument or input line after
    # an error, even with -bail. Each statement above is on its own line, so
    # a failed check stops before the final SELECT prints any names.
    printf '%s\n' "$sql" | run_target_command "$path" "$sqlite_bin" -batch -bail -init /dev/null :memory: 2>/dev/null
}

slack_export_plan_standard() {
    local root="$1" file name names entry metadata=() channels=() users=0 lists=0 before="$FAILED_COUNT"
    for name in users.json org_users.json; do
        file="$root/$name"
        [ -e "$file" ] || [ -L "$file" ] || continue
        slack_export_json "$file" users >/dev/null || return 1
        metadata+=("$file")
        users=$((users + 1))
    done
    [ "$users" -gt 0 ] || return 1
    for name in channels.json groups.json dms.json mpims.json; do
        file="$root/$name"
        [ -e "$file" ] || [ -L "$file" ] || continue
        names="$(slack_export_json "$file" channels)" || return 1
        metadata+=("$file")
        lists=$((lists + 1))
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            channels+=("$name")
        done <<< "$names"
    done
    [ "$lists" -gt 0 ] || return 1
    # Validate every target before deleting any metadata or message file.
    for name in ${channels[@]+"${channels[@]}"}; do
        guard_mutation_target "$root/$name" || return 1
        if [ -e "$root/$name" ] && [ ! -d "$root/$name" ]; then return 1; fi
        while read_find_path entry; do
            case "${entry##*/}" in
                [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json)
                    slack_export_json "$entry" messages >/dev/null || return 1
                    slack_targets+=("$entry") ;;
            esac
        done < <(find_checked "$root/$name" -mindepth 1 -maxdepth 1 -print0)
    done
    [ "$FAILED_COUNT" -eq "$before" ] || return 1
    slack_targets+=("${metadata[@]}")
    return 0
}

slack_export_sqlite_header() {
    local file="$1" signature
    guard_mutation_target "$file" || return 1
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    signature="$(run_target_command "$file" /usr/bin/od -An -tx1 -N16 "$file" 2>/dev/null | tr -d '[:space:]')" || return 1
    [ "$signature" = 53514c69746520666f726d6174203300 ]
}

slack_export_file_idle() {
    [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] || return 0
    command -v lsof >/dev/null 2>&1 || return 1
    local result rc=0
    result="$(lsof -t -- "$1" 2>&1)" || rc=$?
    # lsof returns 1 with no output when no process has the file open. Errors
    # and partial process visibility are retained as failures, not ignored.
    [ "$rc" -eq 1 ] && [ -z "$result" ]
}

slack_export_plan_dump() {
    local root="$1" file entry suffix name found=0 media=0 before="$FAILED_COUNT" databases=()
    for entry in archive snapshots; do
        guard_mutation_target "$root/$entry" || return 1
        if [ -e "$root/$entry" ] && [ ! -d "$root/$entry" ]; then return 1; fi
    done
    [ -d "$root/archive" ] || return 1
    file="$root/archive/slackdump.sqlite"
    if [ -e "$file" ] || [ -L "$file" ]; then
        slack_export_sqlite_header "$file" || return 1
        databases+=("$file")
        found=1
    fi
    while read_find_path file; do
        name="${file##*/}"
        if printf '%s\n' "$name" | grep -E '^slackdump_[0-9]{8}_[0-9]{6}\.sqlite$' >/dev/null; then
            slack_export_sqlite_header "$file" || return 1
            databases+=("$file")
            found=1
        fi
    done < <(find_checked "$root/snapshots" -mindepth 1 -maxdepth 1 -print0)
    # The media directories are the archive signature and remain after cleanup.
    for name in __uploads __avatars; do
        file="$root/archive/$name"
        guard_mutation_target "$file" || return 1
        [ -e "$file" ] || continue
        [ -d "$file" ] || return 1
        media=$((media + 1))
        while read_find_path entry; do
            [ "$found" -eq 1 ] || return 1
            guard_mutation_target "$entry" || return 1
            slack_targets+=("$entry")
        done < <(find_checked "$file" -mindepth 1 -maxdepth 1 -print0)
    done
    for file in ${databases[@]+"${databases[@]}"}; do
        for suffix in '' -wal -shm -journal; do
            [ -e "$file$suffix" ] || [ -L "$file$suffix" ] || continue
            guard_mutation_target "$file$suffix" || return 1
            [ -f "$file$suffix" ] || return 1
            slack_export_file_idle "$file$suffix" || return 1
            slack_targets+=("$file$suffix")
        done
    done
    # Orphan sidecars must not be deleted or silently treated as a clean export.
    while read_find_path file; do
        case "${file##*/}" in
            slackdump.sqlite-wal|slackdump.sqlite-shm|slackdump.sqlite-journal)
                [ -f "$root/archive/slackdump.sqlite" ] || return 1 ;;
        esac
    done < <(find_checked "$root/archive" -mindepth 1 -maxdepth 1 -print0)
    if [ "$found" -eq 0 ] && [ "$media" -eq 0 ]; then
        # An empty archive remains after a download-free export is cleared.
        # Unknown nonempty archives still have no supported signature.
        while read_find_path entry; do return 1; done < <(find_checked "$root/archive" -mindepth 1 -maxdepth 1 -print0)
    fi
    while read_find_path file; do
        name="${file##*/}"
        if printf '%s\n' "$name" | grep -E '^slackdump_[0-9]{8}_[0-9]{6}\.sqlite-(wal|shm|journal)$' >/dev/null; then
            [ -f "${file%-*}" ] || return 1
        fi
    done < <(find_checked "$root/snapshots" -mindepth 1 -maxdepth 1 -print0)
    while read_find_path file; do
        name="${file##*/}"
        if printf '%s\n' "$name" | grep -E '^(users-T[A-Z0-9]+\.json|channels-T[A-Z0-9]+\.txt)$' >/dev/null; then
            [ "$found" -eq 1 ] || return 1
            guard_mutation_target "$file" || return 1
            [ -f "$file" ] || return 1
            slack_targets+=("$file")
        fi
    done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -print0)
    [ "$FAILED_COUNT" -eq "$before" ]
}

module_slackexport() {
    local requested root u h uid eligible file entry failed before slack_targets=()
    if ! slack_exporters_stopped; then
        log_warn "slackexport: close exporters and sync jobs before cleanup"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    for requested in "${SLACK_EXPORT_ROOTS[@]}"; do
        root="$SANDBOX$requested"
        eligible=0
        while IFS=$'\t' read -r u h uid; do
            case "$root" in "$h"/*) eligible=1; break ;; esac
        done < <(enumerate_users)
        if [ "$eligible" -ne 1 ]; then
            log_warn "slackexport: root is outside an eligible user home: $root"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        guard_mutation_target "$root" || continue
        if [ -e "$root/.lock" ] || [ -L "$root/.lock" ]; then
            log_warn "slackexport: export lock is present; root retained: $root"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        if [ ! -e "$root" ]; then continue; fi
        if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
            log_warn "slackexport: expected a readable export directory: $root"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        slack_targets=()
        failed=0; before="$FAILED_COUNT"
        if [ -e "$root/users.json" ] || [ -e "$root/org_users.json" ] || [ -L "$root/users.json" ] || [ -L "$root/org_users.json" ]; then
            slack_export_plan_standard "$root" || failed=1
        elif [ -d "$root/archive" ]; then
            slack_export_plan_dump "$root" || failed=1
        else
            # Missing or empty roots are repeatable; unknown nonempty layouts
            # remain intact rather than being treated as disposable directories.
            while read_find_path entry; do failed=1; done < <(find_checked "$root" -mindepth 1 -maxdepth 1 -print0)
        fi
        if [ "$failed" -eq 1 ] || [ "$FAILED_COUNT" -ne "$before" ]; then
            log_warn "slackexport: unsupported, malformed or unsafe export retained: $root"
            [ "$FAILED_COUNT" -ne "$before" ] || FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        # Recheck the cooperative lock immediately before applying the plan.
        if [ -e "$root/.lock" ] || [ -L "$root/.lock" ]; then
            log_warn "slackexport: export became locked; root retained: $root"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        for file in ${slack_targets[@]+"${slack_targets[@]}"}; do selected_remove_path "$file"; done
    done
    return 0
}


# Selected artifacts never search a whole home and never accept arbitrary roots.
add_selected_artifact() {
    local kind="$1" path="$2" relative user
    case "$path" in /Users/*/*) ;; *) usage_error "selected artifacts must be below /Users/<user>/" ;; esac
    case "$path" in *//*|*/./*|*/../*|*/.|*/..|*/|*$'\n'*|*$'\r'*|*$'\t'*) usage_error "selected artifacts need normalized paths" ;; esac
    relative="${path#/Users/}"; user="${relative%%/*}"
    case "$user" in ''|Shared|Guest|.*) usage_error "ineligible artifact home" ;; esac
    case "$kind" in
        diagnosticexports)
            path_listed "$path" ${DIAGNOSTIC_EXPORTS[@]+"${DIAGNOSTIC_EXPORTS[@]}"} || DIAGNOSTIC_EXPORTS+=("$path") ;;
        aiexports)
            path_listed "$path" ${AI_EXPORTS[@]+"${AI_EXPORTS[@]}"} || AI_EXPORTS+=("$path") ;;
        testresults)
            path_listed "$path" ${TEST_RESULTS[@]+"${TEST_RESULTS[@]}"} || TEST_RESULTS+=("$path") ;;
        devicebackups)
            path_listed "$path" ${DEVICE_BACKUPS[@]+"${DEVICE_BACKUPS[@]}"} || DEVICE_BACKUPS+=("$path") ;;
    esac
}

validate_selected_artifact_options() {
    if module_selected "$1"; then
        [ "$3" -gt 0 ] || usage_error "$1 requires --$2"
    elif [ "$3" -gt 0 ]; then
        usage_error "--$2 requires explicit --modules $1"
    fi
}

# eligible_home PATH - succeed when PATH is inside a home that the common
# user enumerator accepts (a directory-service account in real mode).
eligible_home() {
    local path="$1" u h uid found=1
    while IFS=$'\t' read -r u h uid; do
        case "$path" in "$h"/*) found=0 ;; esac
    done < <(enumerate_users)
    return "$found"
}

selected_artifact_safe() {
    local target="$1" relative home
    case "$target" in "$USERS_DIR"/*/*) ;; *) return 1 ;; esac
    relative="${target#"$USERS_DIR"/}"; home="$USERS_DIR/${relative%%/*}"
    case "${relative%%/*}" in ''|Shared|Guest|.*) return 1 ;; esac
    [ -d "$home" ] && [ -e "$target" ] || return 1
    # An orphaned home of a deleted account is not an eligible home.
    eligible_home "$target" || return 1
    guard_mutation_target "$target" || return 1
    # Validate all descendants as the home owner. One find pass rejects links,
    # hard-linked files and special files; a device backup can hold hundreds
    # of thousands of files, so do not run stat for each file. find visits
    # mount points but does not cross them; compare each directory's device
    # to reject those points as well.
    # shellcheck disable=SC2016
    run_target_command "$target" /bin/bash -c '
        set -e; set -o pipefail
        parent=${1%/*}; entry=${1##*/}
        cd -P "$parent"; [ "$(pwd -P)" = "$parent" ]
        if [ "$(uname -s)" = Darwin ]; then stat_mode=-f; else stat_mode=-c; fi
        device=$(stat "$stat_mode" %d .)
        [ "$(stat "$stat_mode" %d "$2")" = "$device" ]
        bad=$(find "./$entry" -xdev \( -type l -o \( -type f -links +1 \) \
            -o \( ! -type f ! -type d \) \) -print -quit)
        [ -z "$bad" ]
        find "./$entry" -xdev -type d -print0 | while IFS= read -r -d "" item; do
            [ "$(stat "$stat_mode" %d "$item")" = "$device" ]
        done
    ' sh "$target" "$home" >/dev/null 2>&1
}

selected_artifact_idle() {
    local target="$1" pattern="$2" processes result rc=0
    [ "$TEST_MODE" -eq 0 ] || return 0
    processes="$(process_list comm)" || return 1
    if process_match -Ei "$pattern" "$processes"; then return 1; fi
    command -v lsof >/dev/null 2>&1 || return 1
    if [ -d "$target" ]; then
        result="$(lsof -t +D "$target" 2>&1)" || rc=$?
    else
        result="$(lsof -t -- "$target" 2>&1)" || rc=$?
    fi
    [ "$rc" -eq 1 ] && [ -z "$result" ]
}

selected_artifact_refuse() {
    log_warn "$1: unknown, incomplete, active or unsafe artifact retained: $2"
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

diagnostic_export_valid() {
    local target="$1" listing entry root expected found_log=0 found_archive=0
    case "${target##*/}" in
        *.logarchive)
            [ -d "$target" ] && [ -f "$target/Info.plist" ] || return 1
            # Native inspection is required: a directory suffix is not proof.
            run_target_command "$target" /usr/bin/log stats --archive "$target" --overview >/dev/null 2>&1
            ;;
        sysdiagnose_*.tar.gz)
            [ -f "$target" ] || return 1
            expected="${target##*/}"; expected="${expected%.tar.gz}"
            listing="$(run_target_command "$target" /usr/bin/tar -tzf "$target" 2>/dev/null)" || return 1
            [ -n "$listing" ] || return 1
            while IFS= read -r entry; do
                entry="${entry#./}"; root="${entry%%/*}"
                [ "$root" = "$expected" ] || return 1
                case "$entry" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
                [ "$entry" != "$expected/sysdiagnose.log" ] || found_log=1
                [ "$entry" != "$expected/system_logs.logarchive/Info.plist" ] || found_archive=1
            done <<< "$listing"
            [ "$found_log" -eq 1 ] && [ "$found_archive" -eq 1 ]
            ;;
        *) return 1 ;;
    esac
}

module_diagnosticexports() {
    local requested target
    for requested in ${DIAGNOSTIC_EXPORTS[@]+"${DIAGNOSTIC_EXPORTS[@]}"}; do
        target="$SANDBOX$requested"
        if selected_artifact_safe "$target" &&
            selected_artifact_idle "$target" '(^|/)(sysdiagnose|log)$' &&
            diagnostic_export_valid "$target" && selected_artifact_safe "$target"; then
            selected_remove_path "$target"
        else
            selected_artifact_refuse diagnosticexports "$target"
        fi
    done
}

# A completed, unencrypted MobileSync backup has three property lists and the
# current SQLite Files manifest. Older/encrypted formats require Finder.
device_backup_valid() {
    local target="$1" relative name identifier state encrypted columns
    relative="${target#"$USERS_DIR"/}"; relative="${relative#*/}"
    case "$relative" in 'Library/Application Support/MobileSync/Backup/'*) ;; *) return 1 ;; esac
    name="${relative#Library/Application Support/MobileSync/Backup/}"
    printf '%s\n' "$name" | grep -E '^([a-fA-F0-9]{40}|[a-fA-F0-9]{8}-[a-fA-F0-9]{16})(-[0-9]{8}-[0-9]{6})?$' >/dev/null || return 1
    [ -d "$target" ] || return 1
    local plist
    for plist in Info Manifest Status; do
        [ -f "$target/$plist.plist" ] || return 1
        run_target_command "$target" /usr/bin/plutil -lint "$target/$plist.plist" >/dev/null 2>&1 || return 1
    done
    identifier="$(run_target_command "$target" /usr/bin/plutil -extract 'Target Identifier' raw -expect string -o - "$target/Info.plist" 2>/dev/null)" || return 1
    [ "$name" = "$identifier" ] || case "$name" in "$identifier"-????????-??????) ;; *) return 1 ;; esac
    state="$(run_target_command "$target" /usr/bin/plutil -extract SnapshotState raw -expect string -o - "$target/Status.plist" 2>/dev/null)" || return 1
    [ "$state" = finished ] || return 1
    encrypted="$(run_target_command "$target" /usr/bin/plutil -extract IsEncrypted raw -expect bool -o - "$target/Manifest.plist" 2>/dev/null)" || return 1
    [ "$encrypted" = false ] || return 1
    slack_export_sqlite_header "$target/Manifest.db" || return 1
    for plist in -wal -shm -journal; do
        [ ! -e "$target/Manifest.db$plist" ] || return 1
    done
    columns="$(run_target_command "$target" /usr/bin/sqlite3 -readonly -batch -bail "$target/Manifest.db" "SELECT group_concat(name, ',') FROM pragma_table_info('Files');" 2>/dev/null)" || return 1
    [ "$columns" = fileID,domain,relativePath,flags,file ] || return 1
    [ "$(run_target_command "$target" /usr/bin/sqlite3 -readonly -batch -bail "$target/Manifest.db" 'PRAGMA quick_check;' 2>/dev/null)" = ok ]
}

module_devicebackups() {
    local requested target
    for requested in ${DEVICE_BACKUPS[@]+"${DEVICE_BACKUPS[@]}"}; do
        target="$SANDBOX$requested"
        if selected_artifact_safe "$target" &&
            selected_artifact_idle "$target" '(^|/)(AppleMobileBackup|mobilebackupd|MobileBackup|idevicebackup2|AMPDevicesAgent)$' &&
            device_backup_valid "$target" && selected_artifact_safe "$target"; then
            selected_remove_path "$target"
        else
            selected_artifact_refuse devicebackups "$target"
        fi
    done
}

test_result_valid() {
    local target="$1"
    case "${target##*/}" in *.xcresult) ;; *) return 1 ;; esac
    [ -d "$target" ] && [ -f "$target/Info.plist" ] && [ -d "$target/Data" ] || return 1
    # Xcode 16.3+ provides this read-only inspection. Unsupported toolchains
    # fail closed; do not infer a result bundle from a directory suffix alone.
    run_target_command "$target" /usr/bin/xcrun xcresulttool get content-availability --path "$target" --compact >/dev/null 2>&1
}

module_testresults() {
    local requested target
    for requested in ${TEST_RESULTS[@]+"${TEST_RESULTS[@]}"}; do
        target="$SANDBOX$requested"
        if selected_artifact_safe "$target" &&
            selected_artifact_idle "$target" '(^|/)(Xcode|xcodebuild|xctest|xcresulttool)$' &&
            test_result_valid "$target" && selected_artifact_safe "$target"; then
            selected_remove_path "$target"
        else
            selected_artifact_refuse testresults "$target"
        fi
    done
}

ai_export_valid() {
    local target="$1" result
    [ "${target##*/}" = Apple_Intelligence_Report.json ] && [ -f "$target" ] || return 1
    # Apple documents these two top-level arrays. SQLite JSON functions parse
    # the selected JSON as data in memory; no report contents enter the output.
    # An opaque Raycast .rayconfig file has no supported public validator here.
    local escaped sql quote="'"
    escaped="${target//$quote/$quote$quote}"
    sql="SELECT CASE WHEN json_valid(readfile('$escaped')) THEN
        json_type(readfile('$escaped')) = 'object' AND
        json_type(readfile('$escaped'), '$.modelRequests') = 'array' AND
        json_type(readfile('$escaped'), '$.privateCloudComputeRequests') = 'array'
        ELSE 0 END;"
    result="$(run_target_command "$target" /usr/bin/sqlite3 -batch -bail :memory: "$sql" 2>/dev/null)" || return 1
    [ "$result" = 1 ]
}

module_aiexports() {
    local requested target
    for requested in ${AI_EXPORTS[@]+"${AI_EXPORTS[@]}"}; do
        target="$SANDBOX$requested"
        if selected_artifact_safe "$target" &&
            selected_artifact_idle "$target" '(^|/)(System Settings|System Preferences)$' &&
            ai_export_valid "$target" && selected_artifact_safe "$target"; then
            selected_remove_path "$target"
        else
            selected_artifact_refuse aiexports "$target"
        fi
    done
}

# --- module: terminal --------------------------------------------------------

add_terminal_log_file() {
    local path="$1" relative user
    case "$path" in /Users/*/*) ;; *) usage_error "terminal logs must be absolute files below /Users/<user>/" ;; esac
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..|*/|*$'\n'*|*$'\r'*|*$'\t'*)
            usage_error "terminal logs must have normalized file paths" ;;
    esac
    relative="${path#/Users/}"; user="${relative%%/*}"
    case "$user" in ''|Shared|Guest|.*) usage_error "ineligible terminal log home" ;; esac
    path_listed "$path" ${TERMINAL_LOG_FILES[@]+"${TERMINAL_LOG_FILES[@]}"} && return 0
    TERMINAL_LOG_FILES+=("$path")
}

# terminal_clients_stopped UID - Terminal and iTerm2 rewrite only their own
# account's saved state, so another user's open terminal does not block.
terminal_clients_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    [ -n "${1:-}" ] || return 1
    processes="$(process_list command "$1")" || return 1
    if process_match -Ei '(^|[ /])(Terminal|iTerm2?|iTermServer[^ /]*)([[:space:]/]|$)' "$processes"; then
        return 1
    fi
    return 0
}

terminal_saved_state() {
    local path="$1"
    guard_mutation_target "$path" || return 0
    [ -e "$path" ] || return 0
    if [ ! -d "$path" ]; then
        log_warn "terminal: expected a saved-state directory, retaining: $path"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    selected_remove_path "$path"
}

module_terminal() {
    local u h uid path item matched owner
    while IFS=$'\t' read -r u h uid; do
        owner="$(home_uid "$h" "$uid")" || owner=""
        if ! terminal_clients_stopped "$owner"; then
            log_warn "terminal: close Terminal, iTerm2 and restoration servers of $u before cleanup"
            if [ "$DRY_RUN" -eq 0 ]; then
                FAILED_COUNT=$((FAILED_COUNT + 1)); continue
            fi
        fi
        terminal_saved_state "$h/Library/Saved Application State/com.apple.Terminal.savedState"
        terminal_saved_state "$h/Library/Saved Application State/com.googlecode.iterm2.savedState"
        terminal_saved_state "$h/Library/Application Support/iTerm2/SavedState"
    done < <(enumerate_users)
    for item in ${TERMINAL_LOG_FILES[@]+"${TERMINAL_LOG_FILES[@]}"}; do
        path="$SANDBOX$item"; matched=0; owner=""
        while IFS=$'\t' read -r u h uid; do
            case "$path" in "$h"/*) matched=1; owner="$(home_uid "$h" "$uid")" || owner="" ;; esac
        done < <(enumerate_users)
        if [ "$matched" -eq 0 ]; then
            log_warn "terminal: log has no eligible user home: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        if ! terminal_clients_stopped "$owner"; then
            log_warn "terminal: close Terminal, iTerm2 and restoration servers before removing: $item"
            if [ "$DRY_RUN" -eq 0 ]; then
                FAILED_COUNT=$((FAILED_COUNT + 1)); continue
            fi
        fi
        guard_mutation_target "$path" || continue
        if [ ! -f "$path" ]; then
            log_warn "terminal: selected log is not a regular file: $path"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        # Explicit log files can also be held by script(1) or another recorder.
        if ! slack_export_file_idle "$path"; then
            log_warn "terminal: selected log is open or cannot be inspected: $path"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        selected_remove_path "$path"
    done
    return 0
}

# --- module: finderhistory ---------------------------------------------------

# finder_history_clients_stopped UID - Finder and Open/Save panels write only
# their own account's preferences.
finder_history_clients_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    [ -n "${1:-}" ] || return 1
    processes="$(process_list command "$1")" || return 1
    if process_match -E '(^|[ /])(Finder|com\.apple\.appkit\.xpc\.openAndSavePanelService)([[:space:]/]|$)' "$processes"; then
        return 1
    fi
    return 0
}

# Retain the mixed preference file and all keys outside this exact allowlist.
# defaults uses the preference API, avoiding direct edits behind cfprefsd.
# The file and known value types are checked again as the home owner before
# the first mutation. A changed/unknown type stops the whole file operation.
finder_history_plist() {
    local file="$1" kind="$2" specs result
    guard_mutation_target "$file" || return 0
    [ -e "$file" ] || return 0
    if [ ! -f "$file" ]; then
        log_warn "finderhistory: expected a preference file, retaining: $file"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    case "$kind" in
        finder) specs='FXRecentFolders:array GoToFieldHistory:array GoToField:string FXConnectToLastURL:string RecentMoveAndCopyDestinations:array RecentSearches:array' ;;
        panels) specs='NSNavRecentPlaces:array' ;;
        *) FAILED_COUNT=$((FAILED_COUNT + 1)); return 0 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear known $kind history keys: $file"
        CLEANED_COUNT=$((CLEANED_COUNT + 1)); return 0
    fi
    if [ ! -x /usr/bin/plutil ] || [ ! -x /usr/bin/defaults ]; then
        log_warn "finderhistory: native plutil and defaults are required; retaining: $file"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    # No preference values are printed.
    # shellcheck disable=SC2016
    if result="$(run_target_command "$file" /bin/sh -c '
        file=$1; specs=$2; parent=${file%/*}; entry=${file##*/}
        cd -P "$parent" || exit 1
        [ "$(pwd -P)" = "$parent" ] || exit 1
        [ -f "./$entry" ] && [ ! -L "./$entry" ] || exit 1
        [ "$(/usr/bin/stat -f %l "./$entry")" = 1 ] || exit 1
        [ "$(/usr/bin/stat -f %u "./$entry")" = "$(/usr/bin/id -u)" ] || exit 1
        /usr/bin/plutil -lint -s "$file" >/dev/null 2>&1 || exit 1
        keys=""
        for spec in $specs; do
            key=${spec%:*}; expected=${spec#*:}
            # Only a missing key is skipped. Any other plutil error, such as a
            # release without -type, stops instead of looking like "absent".
            if ! actual=$(/usr/bin/plutil -type "$key" "$file" 2>&1); then
                case "$actual" in *"No value at that key path"*) continue ;; esac
                exit 1
            fi
            [ "$actual" = "$expected" ] || exit 1
            keys="$keys $key"
        done
        [ -n "$keys" ] || { printf "absent"; exit 0; }
        for key in $keys; do
            /usr/bin/defaults delete "$file" "$key" >/dev/null 2>&1 || exit 1
        done
        /usr/bin/plutil -lint -s "$file" >/dev/null 2>&1 || exit 1
        for key in $keys; do
            if /usr/bin/plutil -type "$key" "$file" >/dev/null 2>&1; then exit 1; fi
        done
        printf "cleaned"
    ' sh "$file" "$specs" 2>/dev/null)"; then
        if [ "$result" = cleaned ]; then
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            log_debug "cleared known $kind history keys: $file"
        fi
    else
        log_warn "finderhistory: cannot safely clear preference history: $file"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

module_finderhistory() {
    local u h uid owner
    while IFS=$'\t' read -r u h uid; do
        owner="$(home_uid "$h" "$uid")" || owner=""
        if ! finder_history_clients_stopped "$owner"; then
            log_warn "finderhistory: quit Finder and close Open/Save dialogs of $u before cleanup"
            if [ "$DRY_RUN" -eq 0 ]; then
                FAILED_COUNT=$((FAILED_COUNT + 1)); continue
            fi
        fi
        finder_history_plist "$h/Library/Preferences/com.apple.finder.plist" finder
        finder_history_plist "$h/Library/Preferences/.GlobalPreferences.plist" panels
        finder_history_plist "$h/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist" panels
        finder_history_plist "$h/Library/Containers/com.apple.appkit.xpc.openAndSavePanelService/Data/Library/Preferences/com.apple.appkit.xpc.openAndSavePanelService.plist" panels
    done < <(enumerate_users)
    return 0
}

# --- module: filemetadata ----------------------------------------------------

add_metadata_file() {
    local path="$1" relative user
    case "$path" in /Users/*/*) ;; *) usage_error "metadata files must be below /Users/<user>/" ;; esac
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..|*/|*$'\n'*|*$'\r'*|*$'\t'*)
            usage_error "metadata files must have normalized absolute paths" ;;
    esac
    relative="${path#/Users/}"; user="${relative%%/*}"
    case "$user" in ''|Shared|Guest|.*) usage_error "ineligible metadata file home" ;; esac
    path_listed "$path" ${METADATA_FILES[@]+"${METADATA_FILES[@]}"} && return 0
    METADATA_FILES+=("$path")
}

# List names only; never print the URL or sender stored in the attribute.
# xattr -s acts on a replaced symlink itself, not the link target.
clear_file_origin() {
    local target="$1" xattr_bin status=0
    guard_mutation_target "$target" || return 0
    if [ ! -f "$target" ]; then
        log_warn "filemetadata: selected target is not a regular file: $target"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    xattr_bin=/usr/bin/xattr
    if [ "$TEST_MODE" -eq 1 ]; then xattr_bin="$(command -v xattr 2>/dev/null || true)"; fi
    if [ ! -x "$xattr_bin" ]; then
        log_warn "filemetadata: xattr is unavailable; file retained: $target"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    fi
    # Pin the parent after privilege reduction and refuse shared file metadata.
    # shellcheck disable=SC2016
    run_target_command "$target" /bin/sh -c '
        parent=${1%/*}; entry=${1##*/}; attr=com.apple.metadata:kMDItemWhereFroms
        cd -P "$parent" || exit 1
        [ "$(pwd -P)" = "$parent" ] || exit 1
        [ -f "./$entry" ] && [ ! -L "./$entry" ] || exit 1
        if [ "$(uname -s)" = Darwin ]; then
            links=$(stat -f %l "./$entry") || exit 1
        else
            links=$(stat -c %h "./$entry") || exit 1
        fi
        [ "$links" = 1 ] || exit 1
        names=$("$2" -s "./$entry") || exit 1
        printf "%s\n" "$names" | grep -Fx "$attr" >/dev/null || exit 3
        [ "$3" = 0 ] || exit 0
        "$2" -s -d "$attr" "./$entry" || exit 1
        names=$("$2" -s "./$entry") || exit 1
        if printf "%s\n" "$names" | grep -Fx "$attr" >/dev/null; then exit 1; fi
    ' sh "$target" "$xattr_bin" "$DRY_RUN" >/dev/null 2>&1 || status=$?
    case "$status" in
        0)
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            if [ "$DRY_RUN" -eq 1 ]; then
                log_debug "[DRY RUN] would clear file origin metadata: $target"
            else
                log_debug "cleared file origin metadata: $target"
            fi ;;
        3) log_debug "filemetadata: no origin attribute: $target" ;;
        *)
            log_warn "filemetadata: cannot clear origin metadata (links/access/tool failure): $target"
            FAILED_COUNT=$((FAILED_COUNT + 1)) ;;
    esac
    return 0
}

module_filemetadata() {
    local item path matched u h uid
    for item in ${METADATA_FILES[@]+"${METADATA_FILES[@]}"}; do
        path="$SANDBOX$item"; matched=0
        while IFS=$'\t' read -r u h uid; do
            case "$path" in "$h"/*) matched=1 ;; esac
        done < <(enumerate_users)
        if [ "$matched" -eq 0 ]; then
            log_warn "filemetadata: no eligible user home for selected file: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        clear_file_origin "$path"
    done
    return 0
}

# --- module: documentversions -----------------------------------------------

add_version_file() {
    local path="$1" relative user existing
    case "$path" in /Users/*/*) ;; *) usage_error "version files must be below /Users/<user>/" ;; esac
    case "$path" in
        *//*|*/./*|*/../*|*/.|*/..|*/|*$'\n'*|*$'\r'*|*$'\t'*)
            usage_error "version files must have normalized absolute paths" ;;
    esac
    relative="${path#/Users/}"; user="${relative%%/*}"
    case "$user" in ''|Shared|Guest|.*) usage_error "ineligible version file home" ;; esac
    for existing in ${VERSION_FILES[@]+"${VERSION_FILES[@]}"}; do
        [ "$existing" != "$path" ] || return 0
    done
    VERSION_FILES+=("$path")
}

# The URL API creates a missing file. Check identity again inside the coordinated
# write, and never call it for a missing/replaced item or an iCloud document.
document_versions_native() {
    local target="$1" dry_run="$2"
    # shellcheck disable=SC2016
    run_target_command "$target" /bin/sh -c '
        parent=${1%/*}; entry=${1##*/}
        cd -P "$parent" || exit 1
        [ "$(pwd -P)" = "$parent" ] || exit 1
        [ -f "./$entry" ] && [ ! -L "./$entry" ] || exit 1
        [ "$(/usr/bin/stat -f %l "./$entry")" = 1 ] || exit 1
        owner=$(/usr/bin/id -u) || exit 1
        [ "$(/usr/bin/stat -f %u "./$entry")" = "$owner" ] || exit 1
        identity=$(/usr/bin/stat -f "%d:%i" "./$entry") || exit 1
        exec /usr/bin/osascript -l JavaScript - "$1" "$2" "$owner" "$identity"
    ' sh "$target" "$dry_run" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
    const path = argv[0], dryRun = argv[1] === '1';
    const owner = Number(argv[2]), identity = argv[3];
    const manager = $.NSFileManager.defaultManager;
    const url = $.NSURL.fileURLWithPath(path);
    function check(candidate) {
        if (ObjC.unwrap(candidate.path) !== path) throw Error('path changed');
        // NSURL can rewrite /private/var to /var even without a symlink in
        // the supplied path. Inspect every component instead of that alias.
        let prefix = '';
        const parts = path.split('/').slice(1);
        for (let i = 0; i < parts.length; i++) {
            prefix += '/' + parts[i];
            const component = manager.attributesOfItemAtPathError(prefix, Ref());
            if (!component || component.isNil() ||
                ObjC.unwrap(component.objectForKey($.NSFileType)) === ObjC.unwrap($.NSFileTypeSymbolicLink))
                throw Error('missing or linked path component');
        }
        const error = Ref();
        const attrs = manager.attributesOfItemAtPathError(path, error);
        if (!attrs || attrs.isNil()) throw Error('file missing');
        function attr(key) { return ObjC.unwrap(attrs.objectForKey(key)); }
        if (attr($.NSFileType) !== ObjC.unwrap($.NSFileTypeRegular) ||
            Number(attr($.NSFileReferenceCount)) !== 1 ||
            Number(attr($.NSFileOwnerAccountID)) !== owner ||
            String(attr($.NSFileSystemNumber)) + ':' + String(attr($.NSFileSystemFileNumber)) !== identity)
            throw Error('file identity changed');
        const cloud = Ref();
        if (!candidate.getResourceValueForKeyError(cloud, $.NSURLIsUbiquitousItemKey, error) ||
            ObjC.unwrap(cloud[0])) throw Error('cloud status unavailable or iCloud file');
    }
    function countVersions(candidate) {
        return Number($.NSFileVersion.otherVersionsOfItemAtURL(candidate).count);
    }
    check(url);
    if (dryRun) return countVersions(url) === 0 ? 'none' : 'planned';
    const coordinator = $.NSFileCoordinator.alloc.initWithFilePresenter($());
    const error = Ref();
    let result = '', failure = '';
    coordinator.coordinateWritingItemAtURLOptionsErrorByAccessor(url, 0, error, function(item) {
        try {
            check(item);
            if (countVersions(item) === 0) { result = 'none'; return; }
            const removalError = Ref();
            if (!$.NSFileVersion.removeOtherVersionsOfItemAtURLError(item, removalError))
                throw Error('version removal failed');
            check(item);
            if (countVersions(item) !== 0) throw Error('versions remain');
            result = 'cleaned';
        } catch (e) { failure = String(e); }
    });
    if (failure || !result) throw Error('coordinated version removal failed');
    return result;
}
JXA
}

module_documentversions() {
    local item target matched u h uid result
    for item in ${VERSION_FILES[@]+"${VERSION_FILES[@]}"}; do
        target="$SANDBOX$item"; matched=0
        while IFS=$'\t' read -r u h uid; do
            case "$target" in "$h"/*) matched=1 ;; esac
        done < <(enumerate_users)
        if [ "$matched" -ne 1 ]; then
            log_warn "documentversions: no eligible user home: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        # Keep the shared guard's dry-run accounting local. This explicit
        # module reports and counts every refused selection exactly once.
        if ! (guard_mutation_target "$target") 2>/dev/null; then
            log_warn "documentversions: unsafe selected path refused: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        if [ ! -f "$target" ] || [ -L "$target" ] || ! slack_export_file_idle "$target"; then
            log_warn "documentversions: selected file missing, unsafe or open: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1)); continue
        fi
        result=''
        if result="$(document_versions_native "$target" "$DRY_RUN" 2>/dev/null)"; then
            case "$result" in
                none) log_debug "documentversions: no other versions: $item" ;;
                planned|cleaned)
                    CLEANED_COUNT=$((CLEANED_COUNT + 1))
                    log_debug "documentversions: $result other versions: $item" ;;
                *) FAILED_COUNT=$((FAILED_COUNT + 1)); log_warn "documentversions: unexpected native result: $item" ;;
            esac
        else
            log_warn "documentversions: native checks or coordination failed; inspect the selected file: $item"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done
    return 0
}

# --- module: spelling -------------------------------------------------------

add_spelling_word() {
    local word="$1" existing
    case "$word" in ''|*[[:space:][:cntrl:]]*) usage_error "--spelling-word requires one nonempty word without whitespace or control characters" ;; esac
    [ "${#word}" -le 256 ] || usage_error "--spelling-word is too long"
    for existing in ${SPELLING_WORDS[@]+"${SPELLING_WORDS[@]}"}; do
        [ "$existing" != "$word" ] || return 0
    done
    SPELLING_WORDS+=("$word")
}

# Only the active console account is selected. Other users' dictionaries are
# not files that can safely be reset or redirected with a substitute HOME.
spelling_console_user() {
    [ "$TEST_MODE" -eq 0 ] || return 1
    local console_uid u h uid
    console_uid="$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null)" || return 1
    case "$console_uid" in ''|0|*[!0-9]*) return 1 ;; esac
    /bin/launchctl print "gui/$console_uid" >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r u h uid; do
        [ "$uid" = "$console_uid" ] || continue
        guard_mutation_target "$h" || return 1
        [ "$(/usr/bin/stat -f '%u' "$h")" = "$uid" ] || return 1
        printf '%s\t%s\t%s\n' "$u" "$h" "$uid"
        return 0
    done < <(enumerate_users)
    return 1
}

spelling_native() {
    local home="$1" uid="$2" word="$3" dry_run="$4"
    # Tests must replace this whole boundary. HOME does not isolate spellcheckd.
    [ "$TEST_MODE" -eq 0 ] || return 1
    [ "$(/usr/bin/stat -f '%u' /dev/console)" = "$uid" ] || return 1
    [ "$(/usr/bin/stat -f '%u' "$home")" = "$uid" ] || return 1
    /bin/launchctl print "gui/$uid" >/dev/null 2>&1 || return 1
    local runner
    # A dry-run does not need root. The console user can query its own
    # session directly; root must enter that session first.
    if [ "$(/usr/bin/id -u)" = "$uid" ]; then
        runner=(/usr/bin/env HOME="$home")
    else
        runner=(/bin/launchctl asuser "$uid" /usr/bin/sudo -u "#$uid" -- /usr/bin/env HOME="$home")
    fi
    "${runner[@]}" /usr/bin/osascript -l JavaScript - "$word" "$dry_run" <<'JXA'
ObjC.import('AppKit');
function run(argv) {
    const checker = $.NSSpellChecker.sharedSpellChecker;
    if (!checker || checker.isNil() ||
        !checker.respondsToSelector('hasLearnedWord:') ||
        !checker.respondsToSelector('unlearnWord:')) throw Error('spell checker unavailable');
    if (!checker.hasLearnedWord(argv[0])) return 'none';
    if (argv[1] === '1') return 'planned';
    checker.unlearnWord(argv[0]);
    if (checker.hasLearnedWord(argv[0])) throw Error('word is still learned');
    return 'cleaned';
}
JXA
}

module_spelling() {
    local account u h uid word result
    account="$(spelling_console_user 2>/dev/null)" || {
        log_warn "spelling: eligible active GUI user unavailable; no words changed"
        FAILED_COUNT=$((FAILED_COUNT + 1)); return 0
    }
    IFS=$'\t' read -r u h uid <<< "$account"
    for word in ${SPELLING_WORDS[@]+"${SPELLING_WORDS[@]}"}; do
        result=''
        if result="$(spelling_native "$h" "$uid" "$word" "$DRY_RUN" 2>/dev/null)"; then
            # Do not print selected words, including in debug output.
            case "$result" in
                none) log_debug "spelling: selected word is not learned" ;;
                planned|cleaned)
                    CLEANED_COUNT=$((CLEANED_COUNT + 1))
                    log_debug "spelling: $result one selected learned word" ;;
                *) FAILED_COUNT=$((FAILED_COUNT + 1)); log_warn "spelling: unexpected native result" ;;
            esac
        else
            log_warn "spelling: cannot verify removal of a selected word"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done
    return 0
}

# --- modules: notifications / activity / siri -------------------------------
# System writers are not killed. An offline store is required: daemon restarts
# can recreate data or hold stale Core Data state after direct SQLite cleanup.
activity_store_idle() {
    local db="$1" flavor="$2" processes pattern suffix owner
    [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ] || return 0
    case "$flavor" in
        notifications) pattern='(usernoted|NotificationCenter)' ;;
        knowledge) pattern='(knowledge-agent|knowledgeconstructiond|coreduetd|duetexpertd)' ;;
        *) pattern='(intelligenceplatformd|knowledgeconstructiond|intelligencetasksd|BiomeAgent|biomed)' ;;
    esac
    # Per-account agents write only their owner's stores. Root-owned system
    # stores keep the check across every account.
    owner="$(trash_stat_number %u "$db")" || return 1
    processes="$(process_list comm "$owner")" || return 1
    if process_match -E "(^|/)${pattern}$" "$processes"; then return 1; fi
    for suffix in '' -wal -shm -journal; do
        [ -e "$db$suffix" ] || continue
        slack_export_file_idle "$db$suffix" || return 1
    done
}

# These stores are mixed. Never remove the database or its sidecars on failure.
# Only known table sets and columns can reach DELETE. Checks repeat while the
# write transaction holds a lock; triggers and views are rejected.
activity_purge_database() {
    local db="$1" flavor="$2" sqlite_bin tables table deletes keeps allowed='' sql version required column
    guard_mutation_target "$db" || return 1
    [ -e "$db" ] || return 0
    [ -f "$db" ] || return 1
    case "$flavor" in
        notifications)
            deletes='record delivered displayed'
            keeps='app categories requests dbinfo'
            required='record:rec_id record:app_id record:delivered_date record:data delivered:app_id delivered:list displayed:app_id displayed:list app:app_id app:identifier requests:app_id requests:list categories:app_id categories:categories dbinfo:key dbinfo:value' ;;
        knowledge)
            deletes='ZOBJECT ZSTRUCTUREDMETADATA ZCUSTOMMETADATA Z_4EVENT ZSOURCE ZHISTOGRAM ZHISTOGRAMVALUE'
            keeps='ZADDITIONCHANGESET ZDELETIONCHANGESET ZCONTEXTUALCHANGEREGISTRATION ZCONTEXTUALKEYPATH ZKEYVALUE ZSYNCPEER Z_PRIMARYKEY Z_METADATA Z_MODELCACHE'
            required='ZOBJECT:Z_PK ZOBJECT:Z_ENT ZSTRUCTUREDMETADATA:Z_PK ZSTRUCTUREDMETADATA:Z_ENT' ;;
        events)
            deletes='events pre_events'; keeps='grdb_migrations'
            required='events:id events:timestamp events:payload pre_events:id pre_events:timestamp pre_events:payload grdb_migrations:identifier' ;;
        feedback)
            deletes='feedback deferred'; keeps='grdb_migrations sqlite_sequence'
            required='feedback:id feedback:timestamp feedback:feedback deferred:feedbackId deferred:processorName grdb_migrations:identifier' ;;
        *) return 1 ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear known $flavor history after offline/schema checks: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1)); return 0
    fi
    if ! activity_store_idle "$db" "$flavor"; then
        log_warn "activity: store is open or its service is running; use an offline user session: $db"
        return 1
    fi
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    [ -n "$sqlite_bin" ] || return 1
    tables="$(ai_sqlite_command "$db" "$sqlite_bin" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>/dev/null)" || return 1
    [ -n "$tables" ] || return 1
    deletes="$deletes $(sqlite_stat_tables "$tables")"
    while IFS= read -r table; do
        case " $deletes $keeps " in *" $table "*) ;; *) return 1 ;; esac
    done <<< "$tables"
    for table in $deletes $keeps; do allowed="${allowed:+$allowed,}'$table'"; done
    version="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA schema_version;' 2>/dev/null)" || return 1
    case "$version" in ''|*[!0-9]*) return 1 ;; esac
    sql="PRAGMA trusted_schema=OFF; PRAGMA foreign_keys=OFF; PRAGMA secure_delete=ON;
BEGIN IMMEDIATE;
CREATE TEMP TABLE shredder_check(ok INTEGER CHECK(ok=1));
INSERT INTO shredder_check SELECT schema_version=$version FROM pragma_schema_version;
INSERT INTO shredder_check SELECT COUNT(*)=0 FROM sqlite_master WHERE type IN ('trigger','view') OR (type='table' AND name NOT IN ($allowed));"
    for column in $required; do
        table="${column%%:*}"; column="${column#*:}"
        sql="$sql INSERT INTO shredder_check SELECT COUNT(*)=1 FROM pragma_table_info('$table') WHERE name='$column';"
    done
    for table in $deletes; do
        case $'\n'"$tables"$'\n' in *$'\n'"$table"$'\n'*)
            if [ "$flavor" = notifications ] && [ "$table" = record ]; then
                # Pending requests share this database; keep their records.
                sql="$sql DELETE FROM record WHERE delivered_date>0;"
            else
                sql="$sql DELETE FROM \"$table\";"
            fi ;;
        esac
    done
    sql="$sql DROP TABLE shredder_check; COMMIT;"
    ai_sqlite_command "$db" "$sqlite_bin" "$sql" >/dev/null 2>&1 || return 1
    ai_sqlite_command "$db" "$sqlite_bin" 'VACUUM;' >/dev/null 2>&1 || return 1
    local checkpoint
    checkpoint="$(ai_sqlite_command "$db" "$sqlite_bin" 'PRAGMA wal_checkpoint(TRUNCATE);' 2>/dev/null)" || return 1
    case "$checkpoint" in 0\|*) ;; *) return 1 ;; esac
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
}

activity_clean_store() {
    local before="$FAILED_COUNT"
    if ! activity_purge_database "$1" "$2"; then
        log_warn "activity: cleanup incomplete; database file retained (some rows may be cleared): $1"
        [ "$FAILED_COUNT" -ne "$before" ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

activity_notification_directory() {
    local dir="$1" file
    guard_mutation_target "$dir" || return 0
    [ -d "$dir" ] || return 0
    activity_clean_store "$dir/db" notifications
    while read_find_path file; do
        case "${file##*/}" in db|db-wal|db-shm|db-journal) continue ;; esac
        log_warn "notifications: unrecognized store or archived data retained: $file"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    done < <(find_checked "$dir" -mindepth 1 -maxdepth 1 -print0)
    return 0
}

module_notifications() {
    local u h uid nc
    while IFS=$'\t' read -r u h uid; do
        activity_notification_directory "$h/Library/Group Containers/group.com.apple.usernoted/db2"
    done < <(enumerate_users)
    while read_find_path nc; do
        activity_notification_directory "$nc/db2"
    done < <(find_checked "$VAR_FOLDERS" -mindepth 4 -maxdepth 4 -type d \
        \( -path '*/0/com.apple.notificationcenter' -o -path '*/C/com.apple.notificationcenter' \) -print0)
}

module_activity() {
    local u h uid path knowledge=1
    # usage runs earlier and already cleans the same KnowledgeC stores.
    if module_selected usage; then knowledge=0; fi
    [ "$knowledge" -eq 0 ] || purge_knowledge_db "$KNOWLEDGE_DB"
    while IFS=$'\t' read -r u h uid; do
        [ "$knowledge" -eq 0 ] || purge_knowledge_db "$h/Library/Application Support/Knowledge/knowledgeC.db"
        activity_clean_store "$h/Library/IntelligencePlatform/eventLog.db" events
        activity_clean_store "$h/Library/IntelligencePlatform/feedbackLog.db" feedback
        for path in "$h/Library/Biome" "$h/Library/IntelligencePlatform/graph.db" "$h/Library/IntelligencePlatform/behaviors.db"; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                log_warn "activity: no verified selective reset for $path; retained (incomplete cleanup)"
                [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        done
    done < <(enumerate_users)
    return 0
}

module_siri() {
    log_warn 'siri: manual action required in System Settings > Apple Intelligence & Siri (or Siri) > Delete Siri & Dictation History > Delete. Internet access is required.'
    log_warn 'siri: on macOS 27, delete Siri app conversations separately: Control-click a conversation > Delete. Conversation deletion can sync to your other devices.'
    log_warn 'siri: no supported command-line deletion API was found; no history was counted as cleaned.'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}

# Explicit guidance: no verified automatic backend for this private store.
module_mailhistory() {
    log_warn 'mailhistory: manual action required; no automatic cleanup was performed.'
    log_warn 'mailhistory: Mail > Window > Previous Recipients: select addresses, then Remove From List. This list can sync through iCloud Contacts.'
    log_warn 'mailhistory: Mail attachments: select messages, then Message > Remove Attachments. For IMAP accounts this also deletes attachments from the mail server.'
    log_warn 'mailhistory: Mail > Settings > General > Remove unedited downloads controls temporary attachment copies; saved attachments remain.'
    log_warn 'mailhistory: No Mail database, message, attachment, address or account was changed.'
    log_info 'mailhistory: official instructions: https://support.apple.com/guide/mail/remove-obsolete-email-addresses-mlhlp1113/mac'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}


# Explicit guidance: no verified automatic backend for this private store.
module_locationhistory() {
    log_warn 'locationhistory: manual action required; no automatic cleanup was performed.'
    log_warn 'locationhistory: Maps > Recents > Clear Recents removes recent searches and directions.'
    log_warn 'locationhistory: System Settings > Privacy & Security > Location Services > System Services > Details > Significant Locations: use Details and Clear History. Labels can vary by macOS version.'
    log_warn 'locationhistory: Location history can span devices signed in to the same Apple Account. Check the account scope in the confirmation dialog.'
    log_warn 'locationhistory: No location database, saved place, account or Location Services setting was changed.'
    log_info 'locationhistory: official instructions: https://support.apple.com/en-gb/guide/mac-help/mh35873/27/mac/27'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}


# Explicit guidance: no verified automatic backend for this private store.
module_callhistory() {
    log_warn 'callhistory: manual action required; no automatic cleanup was performed.'
    log_warn 'callhistory: Phone: show Calls, Missed or Unknown Callers; drag a selected call left and choose Delete.'
    log_warn 'callhistory: FaceTime: Control-click the selected call and choose Delete (Remove from Recents on some macOS versions).'
    log_warn 'callhistory: Deleting local call history does not remove records retained by your carrier or other participants.'
    log_warn 'callhistory: No call-history database, contact, blocked-caller list or account was changed.'
    log_info 'callhistory: official instructions: https://support.apple.com/en-asia/guide/phoneapp/phn33a31c85/mac'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}


# Explicit guidance: no verified automatic backend for this private store.
module_messagehistory() {
    log_warn 'messagehistory: manual action required; no automatic cleanup was performed.'
    log_warn 'messagehistory: Messages: select messages or attachments, press Delete, then confirm. Use View > Recently Deleted to permanently delete selected recently deleted conversations.'
    log_warn 'messagehistory: With Messages in iCloud enabled, deletion applies to your other devices with Messages in iCloud enabled. It does not delete recipients copies.'
    log_warn 'messagehistory: Messages > Settings > General > Keep messages changes future automatic retention; review it separately from one-time deletion.'
    log_warn 'messagehistory: No Messages database, attachment, conversation, sync setting or retention setting was changed.'
    log_info 'messagehistory: official instructions: https://support.apple.com/en-euro/guide/messages/icht1035/26.0/mac/27'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}


# Explicit guidance: no verified automatic backend for this private store.
module_photometadata() {
    log_warn 'photometadata: manual action required; no automatic cleanup was performed.'
    log_warn 'photometadata: Photos: select photos, then Image > Location > Hide Location. Review location metadata on exported copies before sharing.'
    log_warn 'photometadata: Hide Location can be reversed with Revert to Original Location. It is not proof that original GPS metadata or every copy was erased.'
    log_warn 'photometadata: The filemetadata module clears only the WhereFroms attribute; it does not clear embedded EXIF/GPS metadata.'
    log_warn 'photometadata: No photo library, image bytes, GPS metadata, album or iCloud Photos setting was changed.'
    log_info 'photometadata: official instructions: https://support.apple.com/guide/photos/add-titles-captions-and-more-phta4e5a733f/mac'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}

module_alfred() {
    log_warn 'alfred: manual action required. Open Alfred, type clear, then select "Clear Alfred'"'"'s entire clipboard history".'
    log_warn 'alfred: the supported action rebuilds clipboard.db and preserves saved Snippets. No database schema or automatic deletion API is assumed.'
    log_warn 'alfred: no clipboard history was counted as cleaned; preferences, workflows, credentials and the current system clipboard remain unchanged.'
    [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    return 0
}

module_selected() {
    if [ -z "$SELECTED_MODULES" ]; then
        case "$1" in fsevents|clipboard|headless|slackexport|terminal|finderhistory|filemetadata|documentversions|spelling|notifications|activity|siri|mailhistory|locationhistory|callhistory|messagehistory|photometadata|alfred|devicebackups|testresults|aiexports|diagnosticexports) return 1 ;; *) return 0 ;; esac
    fi
    case ",$SELECTED_MODULES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup_step_state() {
    [ -n "$CLEANUP_STATE_DIR" ] || return 0
    if ! rm -f -- "$CLEANUP_STATE_DIR/counts" "$CLEANUP_STATE_DIR/timed-out" "$CLEANUP_STATE_DIR/watchdog" \
        || ! rmdir -- "$CLEANUP_STATE_DIR"; then
        log_warn "cannot remove temporary cleanup state: $CLEANUP_STATE_DIR"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    CLEANUP_STATE_DIR=""
}

# A FIFO stops the deadline read without a long-lived sleep or a signal race.
stop_cleanup_watchdog() {
    [ -n "$WATCHDOG_PID" ] || return 0
    if [ "${1:-}" = cancelled ]; then
        kill -s KILL "$WATCHDOG_PID" 2>/dev/null || true
        kill -s KILL -- "-$WATCHDOG_PID" 2>/dev/null || true
    else
        printf 'stop\n' >&6
    fi
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
    exec 6>&-
}

cleanup_watchdog() {
    local target="$1" state_dir="$2" _stop
    set +m
    trap 'exit 0' INT TERM HUP
    if IFS= read -r -t "$MODULE_TIMEOUT" -u 6 _stop; then return 0; fi
    kill -0 -- "-$target" 2>/dev/null || return 0
    if ! : > "$state_dir/timed-out"; then
        log_warn "cannot record cleanup timeout; forcing the current step to stop"
        kill -s KILL -- "-$target" 2>/dev/null || true
        return 1
    fi
    kill -s TERM -- "-$target" 2>/dev/null || true
    { sleep "$TIMEOUT_GRACE"; } 2>/dev/null || true
    kill -s KILL -- "-$target" 2>/dev/null || true
}

# Run each independent cleanup step in a strict child shell. Do not put this
# function in an if/! or &&/|| condition: Bash would disable errexit in the child.
# A private temporary directory holds only counters, never paths or activity.
# The EXIT trap preserves completed operations even after an unexpected error.
run_cleanup_step() {
    local label="$1" state="" status=1 completed=0 had_monitor=0 timed_out=0
    local counter_pattern='^([0-9]+) ([0-9]+) ([01])$' state_template
    shift
    if [ "$TEST_MODE" -eq 1 ]; then
        state_template="$SANDBOX/.shredder-step.XXXXXX"
    else
        state_template="/private/tmp/macos-shredder.XXXXXX"
    fi
    if ! CLEANUP_STATE_DIR="$(mktemp -d "$state_template" 2>/dev/null)"; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_warn "$label: cannot create private cleanup state; step skipped"
        return 0
    fi
    if ! mkfifo "$CLEANUP_STATE_DIR/watchdog" \
        || ! { exec 6<> "$CLEANUP_STATE_DIR/watchdog"; } 2>/dev/null; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_warn "$label: cannot create cleanup watchdog; step skipped"
        cleanup_step_state
        return 0
    fi
    # Give the step its own process group. Without monitor mode, Bash 3.2
    # makes asynchronous jobs ignore SIGINT before their traps can be set.
    case "$-" in *m*) had_monitor=1 ;; esac
    set -m
    (
        set +m
        set -eu
        set -o pipefail
        umask 077
        exec 5> "$CLEANUP_STATE_DIR/counts"
        exec 6>&-
        CLEANUP_PID=""
        WATCHDOG_PID=""
        # Only the parent removes the shared state directory.
        # shellcheck disable=SC2030
        CLEANUP_STATE_DIR=""
        trap 'printf "%s %s %s\n" "$CLEANED_COUNT" "$FAILED_COUNT" "$completed" >&5' EXIT
        trap on_interrupt INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        "$@"
        completed=1
    ) &
    CLEANUP_PID=$!
    # shellcheck disable=SC2031 # child state reset does not affect this parent
    cleanup_watchdog "$CLEANUP_PID" "$CLEANUP_STATE_DIR" &
    WATCHDOG_PID=$!
    if [ "$had_monitor" -eq 0 ]; then set +m; fi
    # Guard wait, not the child command: Bash must keep errexit active there.
    if wait "$CLEANUP_PID"; then status=0; else status=$?; fi
    stop_cleanup_watchdog
    # shellcheck disable=SC2031 # child state reset does not affect this parent
    [ ! -f "$CLEANUP_STATE_DIR/timed-out" ] || timed_out=1
    CLEANUP_PID=""
    # The child reset does not change the parent's directory reference.
    # shellcheck disable=SC2031
    { IFS= read -r state < "$CLEANUP_STATE_DIR/counts"; } 2>/dev/null || true

    if [[ "$state" =~ $counter_pattern ]]; then
        CLEANED_COUNT="${BASH_REMATCH[1]}"
        FAILED_COUNT="${BASH_REMATCH[2]}"
        completed="${BASH_REMATCH[3]}"
    else
        log_warn "$label: cleanup counters unavailable; partial progress cannot be counted"
        completed=0
    fi
    cleanup_step_state
    if [ "$timed_out" -eq 1 ]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_warn "$label: timed out after ${MODULE_TIMEOUT}s; continuing with remaining cleanup"
        return 0
    fi
    # Cancellation must stop the complete run, not just the current module.
    case "$status" in 129|130|143) exit "$status" ;; esac
    if [ "$status" -ne 0 ] || [ "$completed" -ne 1 ]; then
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_warn "$label: stopped unexpectedly (exit $status); continuing with remaining cleanup"
    fi
    return 0
}

run_module() {
    case "$1" in
        shell)       module_shell ;;
        systemlogs)  module_systemlogs ;;
        audit)       module_audit ;;
        browser)     module_browser ;;
        unified)     module_unified ;;
        fileevents)  module_fileevents ;;
        fsevents)    module_fsevents ;;
        usage)       module_usage ;;
        spotlight)   module_spotlight ;;
        quicklook)   module_quicklook ;;
        trash)       module_trash ;;
        dsstore)     module_dsstore ;;
        wifi)        module_wifi ;;
        brew)        module_brew ;;
        apps)        module_apps ;;
        editors)     module_editors ;;
        ai)          module_ai ;;
        clipboard)   module_clipboard ;;
        headless)    module_headless ;;
        slackexport) module_slackexport ;;
        terminal)    module_terminal ;;
        finderhistory) module_finderhistory ;;
        filemetadata) module_filemetadata ;;
        documentversions) module_documentversions ;;
        spelling) module_spelling ;;
        notifications) module_notifications ;;
        activity)    module_activity ;;
        siri)        module_siri ;;
        diagnosticexports) module_diagnosticexports ;;
        aiexports) module_aiexports ;;
        testresults) module_testresults ;;
        devicebackups) module_devicebackups ;;
        mailhistory) module_mailhistory ;;
        locationhistory) module_locationhistory ;;
        callhistory) module_callhistory ;;
        messagehistory) module_messagehistory ;;
        photometadata) module_photometadata ;;
        alfred)      module_alfred ;;
        *)
            log_warn "unknown module id in dispatch: $1"
            return 1
            ;;
    esac
    return 0
}

run_selected_modules() {
    local id
    if [ -n "$SELECTED_MODULES" ]; then
        log_info "running modules: $(printf '%s' "$SELECTED_MODULES" | tr ',' ' ')"
    else
        log_info "running modules: standard (additional modules require explicit selection; see --list)"
    fi
    # Run unified last: the other modules write log entries of their own (for
    # example, sudo records each owner-UID command with its path).
    for id in "${MODULE_IDS[@]}"; do
        [ "$id" != unified ] || continue
        if module_selected "$id"; then
            log_debug "=== module: $id ==="
            run_cleanup_step "$id" run_module "$id"
        fi
    done
    if module_selected unified; then
        log_debug "=== module: unified ==="
        run_cleanup_step unified run_module unified
    fi
    return 0
}

print_banner() {
    printf '%b\n' "${COLOR_CYAN}==================================================================${COLOR_RESET}"
    printf '%b\n' "${COLOR_BOLD}  ${SCRIPT_NAME} v${VERSION}${COLOR_RESET}"
    printf '%b\n' "  macOS forensic-trace cleaner"
    printf '%b\n' "${COLOR_CYAN}==================================================================${COLOR_RESET}"
}

print_warning_banner() {
    printf '%b\n' "${COLOR_YELLOW}------------------------------------------------------------------${COLOR_RESET}" >&2
    printf '%b\n' "${COLOR_YELLOW}  WARNING: this tool IRREVERSIBLY DELETES user activity traces.${COLOR_RESET}" >&2
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%b\n' "${COLOR_YELLOW}  Running in DRY-RUN mode: nothing will actually be deleted.${COLOR_RESET}" >&2
    fi
    printf '%b\n' "${COLOR_YELLOW}------------------------------------------------------------------${COLOR_RESET}" >&2
}

print_summary() {
    printf '%b\n' "${COLOR_CYAN}==================================================================${COLOR_RESET}"
    printf '%b\n' "  ${SCRIPT_NAME} v${VERSION} - summary"
    printf '%b\n' "${COLOR_CYAN}==================================================================${COLOR_RESET}"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '  Total items that would be cleaned: %s\n' "$CLEANED_COUNT"
    else
        printf '  Total items cleaned: %s\n' "$CLEANED_COUNT"
    fi
    printf '  Failed operations: %s\n' "$FAILED_COUNT"
    printf '%b\n' "${COLOR_CYAN}==================================================================${COLOR_RESET}"
}

main() {
    setup_colors
    trap on_interrupt INT
    trap 'on_signal TERM 143 "terminated by SIGTERM"' TERM
    trap 'on_signal HUP 129 "terminated by SIGHUP"' HUP
    parse_args "$@"

    if [ "$LIST_ONLY" -eq 1 ]; then
        printf '%b\n' "Available modules:"
        print_module_list
        exit 0
    fi

    print_banner
    detect_environment
    if module_selected ai; then ai_environment_roots; fi
    print_warning_banner
    check_privileges

    if [ "$TEST_MODE" -eq 0 ]; then
        if ! probe_full_disk_access; then
            warn_fda_missing
            [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi

    if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        if ! confirm_action "Proceed with irreversible cleanup? [y/N]: "; then
            die "aborted by user"
        fi
    fi

    if [ "$PURGE_SNAPSHOTS" -eq 1 ]; then
        log_info "purging local APFS snapshots (--purge-snapshots)"
        run_cleanup_step snapshots purge_snapshots
    fi

    run_selected_modules
    print_summary

    if [ "$FAILED_COUNT" -gt 0 ]; then
        exit 2
    fi
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
