#!/bin/bash
#
# macos-shredder - forensic-trace cleaner for macOS
# Copyright (c) 2026 Nikita Pochaev
# SPDX-License-Identifier: MIT
# See LICENSE for the full license text.
#
# Purpose:
#   Reduce the forensic footprint of a macOS system by clearing shell and
#   REPL histories, system/audit logs, browser traces, the unified log
#   store, quarantine/FSEvents artifacts, usage databases, Spotlight
#   indexes, Quick Look caches, Trash contents, .DS_Store files, Wi-Fi
#   network reminders, package-manager caches and application leftovers.
#
# Testability (sandbox mode):
#   Create .macos-shredder-test-root in a sandbox, then export
#   SHREDDER_ROOT=/path/to/sandbox to root EVERY filesystem target there.
#   In that mode the root-privilege check, the
#   Darwin OS check and the Full Disk Access probe are skipped, and any
#   missing system utility degrades gracefully into a debug note with an
#   honest zero count instead of failing.
#
# Exit codes:
#   0    success (or a dry-run completed)
#   1    fatal initialization error
#   2    one or more operations failed during a real run
#   64   usage error
#   130  interrupted by user (SIGINT)

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
INCLUDE_EXTENSION_DATA=0
PURGE_SNAPSHOTS=0
AI_DERIVED=0
AI_ROOTS=()
AI_CLAUDE_TMP_BASE=/private/tmp
TEST_MODE=0

CLEANED_COUNT=0
FAILED_COUNT=0

LOGFILE=""
LOGFILE_ARG=""
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
)
MODULE_DESCS=(
    "Shell and REPL histories, session data"
    "System logs and crash reports"
    "BSM audit logs"
    "Browser histories, site data and tab recovery"
    "Unified logging store"
    "Quarantine events and FSEvents"
    "KnowledgeC usage db and recent items"
    "Spotlight index"
    "Quick Look thumbnail caches"
    "User Trash folders"
    ".DS_Store files"
    "Wi-Fi known networks and logs"
    "Homebrew caches and logs"
    "App caches and saved window states"
    "Editor local history and Vim/Neovim state"
    "Local AI agent and editor sessions"
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
# SECTION: Colors and logging
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

# Append one timestamped line to fd 3 when --logfile was given.
log_message() {
    local level="$1"
    shift
    [ -n "$LOGFILE" ] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&3 2>/dev/null || true
}

# Console loggers write to stderr so their output can never pollute the
# TAB-separated records produced by enumerate_users() inside process
# substitutions.
log_info() {
    printf '%b\n' "${COLOR_GREEN}[+]${COLOR_RESET} $*" >&2
    log_message "INFO" "$*"
}

log_ok() {
    printf '%b\n' "${COLOR_GREEN}[ok]${COLOR_RESET} $*" >&2
    log_message "OK" "$*"
}

log_warn() {
    printf '%b\n' "${COLOR_YELLOW}[!]${COLOR_RESET} $*" >&2
    log_message "WARN" "$*"
}

log_error() {
    printf '%b\n' "${COLOR_RED}[x]${COLOR_RESET} $*" >&2
    log_message "ERROR" "$*"
}

log_debug() {
    log_message "DEBUG" "$*"
    [ "$DEBUG" -eq 1 ] || return 0
    printf '%b\n' "${COLOR_BLUE}[dbg]${COLOR_RESET} $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# shellcheck disable=SC2329 # invoked by trap in main()
on_interrupt() {
    printf '%b\n' "${COLOR_YELLOW}[!]${COLOR_RESET} interrupted by user; exiting" >&2
    log_message "WARN" "interrupted by user"
    exit 130
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
    if [ "$TEST_MODE" -eq 0 ] && [ "$owner_uid" -eq 0 ]; then
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

# Pin the cache parent as the working directory before deletion. A replacement
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
        "$VAR_FOLDERS"/*) remove_cache_entry "$target" "$remove_flags" 2>/dev/null || result=$? ;;
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
        log_debug "sqlite3 unavailable; removing database instead: $db"
        remove_sqlite_db "$db"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would execute sqlite statement [$sql] on: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if run_target_command "$db" "$sqlite_bin" "$db" "$sql" >/dev/null 2>&1; then
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
  -m, --modules IDS     Comma-separated module ids to run (default: all).
                        See '--list' for valid ids; unknown ids are rejected.
  -f, --force           Do not ask for confirmation (auto-answer yes)
      --logfile FILE    Create a new private operation log after confirmation
      --include-volumes Also process mounted volumes under /Volumes
      --include-extension-data
                        Also delete mixed website/extension storage. This can
                        reset extension settings and extension sign-ins.
      --purge-snapshots Delete APFS Time Machine local snapshots before modules
      --ai-derived     Also remove AI memory, plans and generated artifacts
      --ai-root KIND=PATH
                        Add an AI storage location below /Users/<user>/.
                        Kinds: claude, codex, codex-db, opencode,
                        opencode-state, opencode-db, claude-temp.
                        Also: cursor, cursor-editor, windsurf, editor,
                        continue, cline, roo, aider, aider-history.
                        Repeat for multiple locations; defaults are also cleaned.

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
            --logfile)
                if [ $# -lt 2 ]; then
                    usage_error "option '--logfile' requires an argument"
                fi
                LOGFILE_ARG="$2"
                shift 2
                ;;
            --logfile=*)
                LOGFILE_ARG="${1#*=}"
                if [ -z "$LOGFILE_ARG" ]; then
                    usage_error "option '--logfile' requires a non-empty argument"
                fi
                shift
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
    if [ -n "$MODULES_ARG" ]; then
        parse_modules "$MODULES_ARG"
    fi
}

setup_logging() {
    [ -n "$LOGFILE_ARG" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] logfile creation skipped: $LOGFILE_ARG"
        return 0
    fi
    local target="$LOGFILE_ARG" part parent cursor previous_dir details owner mode
    local old_umask had_noclobber=0 parts=() kernel acl
    case "$target" in
        *$'\n'*) die "logfile paths cannot contain newlines" ;;
        /*) ;;
        *) target="$(pwd -P)/$target" ;;
    esac
    IFS='/' read -r -a parts <<< "$target"
    target=""
    for part in "${parts[@]}"; do
        case "$part" in
            ''|.) continue ;;
            ..) die "logfile paths cannot contain '..'" ;;
        esac
        target="$target/$part"
    done
    # These are standard, root-controlled macOS aliases. Other symlinks are refused.
    kernel="$(uname -s)"
    if [ "$kernel" = Darwin ]; then
        case "$target" in /var/*|/tmp/*|/etc/*) target="/private$target" ;; esac
    fi
    [ -n "$target" ] || die "logfile must name a new file"
    guard_mutation_target "$target" || die "unsafe logfile path: $target"
    [ ! -e "$target" ] && [ ! -L "$target" ] || die "logfile already exists: $target"
    parent="${target%/*}"
    parent="${parent:-/}"
    cursor="$parent"
    while [ "$cursor" != / ]; do
        [ ! -L "$cursor" ] || die "logfile parent is a symlink: $cursor"
        cursor="${cursor%/*}"
        cursor="${cursor:-/}"
    done
    previous_dir="$(pwd -P)"
    cd -P "$parent" || die "cannot open logfile parent: $parent"
    [ "$(pwd -P)" = "$parent" ] || die "logfile parent changed: $parent"
    # Check the pinned directory, not the pathname. An unprivileged process
    # must not be able to replace the leaf between validation and opening.
    details="$(stat -f '%u %Lp' . 2>/dev/null)" \
        || details="$(stat -c '%u %a' . 2>/dev/null)" \
        || die "cannot inspect logfile parent: $parent"
    read -r owner mode <<< "$details"
    case "$mode" in ''|*[!0-7]*) die "invalid logfile parent permissions" ;; esac
    if [ "$owner" != "$(id -u)" ] || [ "$((8#$mode & 022))" -ne 0 ]; then
        die "logfile parent must belong to the caller and forbid group/other writes: $parent"
    fi
    if [ "$kernel" = Darwin ]; then
        # macOS ACL grants are independent of the POSIX mode bits.
        acl="$(/bin/ls -lde .)" || die "cannot inspect logfile parent ACL"
        case "$acl" in *$'\n'*) die "logfile parent must not have an extended ACL: $parent" ;; esac
    fi
    old_umask="$(umask)"
    case "$-" in *C*) had_noclobber=1 ;; esac
    umask 077
    set -C
    if ! { exec 3> "./${target##*/}"; } 2>/dev/null; then
        die "cannot create new logfile: $target"
    fi
    [ "$had_noclobber" -eq 1 ] || set +C
    umask "$old_umask"
    cd "$previous_dir" || die "cannot restore working directory"
    LOGFILE="$target"
    log_message "INFO" "logging started ($SCRIPT_NAME v$VERSION)"
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

# probe_full_disk_access - stat the first existing user's Library/Safari
# directory; it is TCC-protected, so unreadable means FDA is missing.
probe_full_disk_access() {
    local u h uid safari_dir
    while IFS=$'\t' read -r u h uid; do
        safari_dir="$h/Library/Safari"
        [ -d "$safari_dir" ] || continue
        guard_mutation_target "$safari_dir" || return 1
        log_debug "probing Full Disk Access via: $safari_dir"
        if ! stat "$safari_dir" >/dev/null 2>&1; then
            return 1
        fi
        if ! [ -r "$safari_dir" ] || ! [ -x "$safari_dir" ]; then
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
    log_message "WARN" "Full Disk Access probe failed; protected paths may be skipped"
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
            while IFS= read -r snap; do
                [ -n "$snap" ] || continue
                log_debug "[DRY RUN] would thin local snapshots (covering: $snap)"
                CLEANED_COUNT=$((CLEANED_COUNT + 1))
            done <<< "$snaps"
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
    while IFS= read -r snap; do
        [ -n "$snap" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            log_debug "[DRY RUN] would delete snapshot: $snap"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
            continue
        fi
        if diskutil apfs deleteSnapshot / -name "$snap" >/dev/null 2>&1; then
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
# Fixed execution order = MODULE_IDS order. Per-user work always follows the
# pattern: enumerate_users consumed via while-read (process substitution so
# counters stay in the current shell), guarded by [ -d "$h" ].
###############################################################################

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
        if [ "$flavor" = atuin-records ]; then
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
    if ! shell_purge_database "$@"; then
        log_warn "shell: unsafe, unsupported or unavailable history database retained: $1"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
}

shell_clean_atuin() {
    local root="$1" failed=0
    # Check both files before deleting either representation of the history.
    shell_purge_database "$root/history.db" atuin check || failed=1
    shell_purge_database "$root/records.db" atuin-records check || failed=1
    if [ "$failed" -eq 1 ]; then
        log_warn "shell: Atuin history retained because a database could not be checked: $root"
        [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    shell_clean_database "$root/records.db" atuin-records
    shell_clean_database "$root/history.db" atuin
}

shell_stores_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    processes="$(ps -axo command= 2>/dev/null)" || return 1
    # Bash/zsh can run this script. They cannot be closed from here; their
    # in-memory history can be written back and is documented separately.
    if printf '%s\n' "$processes" | grep -Ei '(^|[ /])(atuin|nu|xonsh|fish|ipython)([[:space:]/]|$|\.(py|exe)([[:space:]]|$))' >/dev/null; then
        return 1
    fi
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
    local u h uid hf mf="" extended=1
    if ! shell_stores_stopped; then
        log_warn "shell: close Atuin, fish, Nushell, Xonsh and IPython before extended history cleanup"
        if [ "$DRY_RUN" -eq 0 ]; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
            extended=0
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

# --- module: systemlogs ------------------------------------------------------
module_systemlogs() {
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
    if [ "$DRY_RUN" -eq 1 ]; then
        local n=0 dry_file dry_base
        current_target="$(readlink "$VAR_AUDIT/current" 2>/dev/null || true)"
        current_target="${current_target##*/}"
        while read_find_path dry_file; do
            dry_base="${dry_file##*/}"
            [ -n "$current_target" ] && [ "$dry_base" = "$current_target" ] && continue
            n=$((n + 1))
        done < <(find_checked "$VAR_AUDIT" -maxdepth 1 \( -type f -o -type l \) -name '[0-9]*' -print0)
        log_debug "[DRY RUN] would remove $n timestamped audit files under $VAR_AUDIT (preserving 'current')"
        CLEANED_COUNT=$((CLEANED_COUNT + n))
        return 0
    fi
    if [ "$TEST_MODE" -eq 0 ] && command -v audit >/dev/null 2>&1 && audit -c >/dev/null 2>&1; then
        audit_enabled=1
        log_debug "rotating current audit record (audit -n)"
        if ! audit -n >/dev/null 2>&1; then
            log_warn "failed to rotate the active audit record"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 0
        fi
    else
        log_debug "BSM audit is unavailable or disabled; deleting existing trail files only"
    fi
    current_target="$(readlink "$VAR_AUDIT/current" 2>/dev/null || true)"
    current_target="${current_target##*/}"
    if [ "$audit_enabled" -eq 1 ] && [ -z "$current_target" ]; then
        log_warn "cannot identify the active audit record; refusing trail deletion"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
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
        for root in "$saf" "$h/Library/Containers/com.apple.Safari/Data/Library/Safari"; do
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
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('moz_places_metadata','moz_origins');" 2>/dev/null)"; then
        log_warn "failed to inspect Firefox Places database: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    # Firefox uses foreign_count for bookmark and keyword references. Check
    # bookmarks directly as well, so a stale counter cannot delete their URLs.
    # Its visit-count triggers are temporary; update those fields explicitly.
    sql="PRAGMA secure_delete=ON; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;"
    case "$tables" in
        *moz_places_metadata*) sql="$sql DELETE FROM moz_places_metadata;" ;;
    esac
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
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would erase the unified logging store (log erase --all)"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if command -v log >/dev/null 2>&1; then
        if log erase --all >/dev/null 2>&1; then
            log_ok "erased unified logging store"
            CLEANED_COUNT=$((CLEANED_COUNT + 1))
        else
            log_warn "failed to erase unified logging store (log erase --all)"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    else
        log_debug "log(1) unavailable; nothing done (honest zero count)"
    fi
    return 0
}

# --- module: fileevents ------------------------------------------------------
module_fileevents() {
    local u h uid qdb vol
    # Restart lsd first so it releases quarantine database handles before the
    # SQLite cleanup attempts to acquire a write lock.
    if [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        if command -v killall >/dev/null 2>&1; then
            killall lsd >/dev/null 2>&1 || log_debug "killall lsd failed (best effort)"
        fi
    fi
    # Launch Services quarantine databases (system + per-user copies).
    qdb="$SYS_PREFS/com.apple.LaunchServices.QuarantineEventsV2"
    sqlite_purge "$qdb" "DELETE FROM LSQuarantineEvent;"
    sqlite_purge "$qdb" "VACUUM;"
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        qdb="$h/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
        sqlite_purge "$qdb" "DELETE FROM LSQuarantineEvent;"
        sqlite_purge "$qdb" "VACUUM;"
    done < <(enumerate_users)
    # FSEvents on the startup volume; SIP commonly blocks this and the
    # failure is counted honestly rather than hidden.
    if [ -d "$SANDBOX/.fseventsd" ]; then
        log_debug "attempting .fseventsd cleanup (may be blocked by SIP)"
        clear_dir_contents "$SANDBOX/.fseventsd"
    fi
    if [ "$INCLUDE_VOLUMES" -eq 1 ]; then
        for vol in "$SANDBOX"/Volumes/*/; do
            vol="${vol%/}"
            [ -d "$vol" ] || continue
            # Skip the startup/root mount itself.
            [ "$vol" = "/" ] && continue
            if [ -d "$vol/.fseventsd" ]; then
                clear_dir_contents "$vol/.fseventsd"
            fi
        done
    fi
    return 0
}

# --- module: usage -----------------------------------------------------------
purge_knowledge_db() {
    local db="$1"
    local tbl tables sqlite_bin
    guard_mutation_target "$db" || return 0
    [ -f "$db" ] || return 0
    sqlite_bin="$(command -v sqlite3 2>/dev/null || true)"
    if [ -z "$sqlite_bin" ]; then
        log_debug "sqlite3 unavailable; removing KnowledgeC database instead: $db"
        remove_sqlite_db "$db"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would purge knowledge tables and VACUUM: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if ! tables="$(run_target_command "$db" "$sqlite_bin" "$db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ZOBJECT','ZSTRUCTUREDMETADATA');" \
        2>/dev/null)"; then
        log_warn "failed to inspect KnowledgeC tables: $db"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    while IFS= read -r tbl; do
        [ -n "$tbl" ] || continue
        sqlite_purge "$db" "DELETE FROM $tbl;"
    done <<< "$tables"
    sqlite_purge "$db" "VACUUM;"
}

clean_recent_items_for_user() {
    local u="$1"
    local h="$2"
    local uid="$3"
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would clear recent items for user '$u'"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
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
    local u h uid nc recent_dir recent_file
    # Keep the legacy system store for older macOS releases, then handle the
    # current per-user Knowledge store.
    purge_knowledge_db "$KNOWLEDGE_DB"
    # Notification Center databases under /private/var/folders.
    while read_find_path nc; do
        if [ -d "$nc/db2" ]; then
            clear_dir_contents "$nc/db2"
        fi
    done < <(find_checked "$VAR_FOLDERS" -type d -name 'com.apple.notificationcenter' -print0)
    # Recent items, executed in each user's own context.
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        purge_knowledge_db "$h/Library/Application Support/Knowledge/knowledgeC.db"
        clean_recent_items_for_user "$u" "$h" "$uid"
        recent_dir="$h/Library/Application Support/com.apple.sharedfilelist"
        if [ -d "$recent_dir" ]; then
            while read_find_path recent_file; do
                remove_path "$recent_file"
            done < <(find_checked "$recent_dir" -maxdepth 1 -type f -name '*Recent*.sfl*' -print0)
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
    done < <(find_checked "$VAR_FOLDERS" -type d -name 'com.apple.QuickLook.thumbnailcache' -print0)
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

clean_volume_trash_for_home() {
    local h="$1" uid="$2" owner vol trash owner_on_volume volume_device parent_device
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
        if [ "$TEST_MODE" -eq 0 ]; then
            volume_device="$(trash_stat_number %d "$vol")" || volume_device=''
            parent_device="$(trash_stat_number %d "${vol%/*}")" || parent_device=''
            if [ -z "$volume_device" ] || [ -z "$parent_device" ]; then
                log_warn "cannot identify mounted volume: $vol"
                [ "$DRY_RUN" -eq 1 ] || FAILED_COUNT=$((FAILED_COUNT + 1))
                continue
            fi
            [ "$volume_device" != "$parent_device" ] || continue
        fi
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
clean_dsstore_tree() {
    local base="$1"
    local f
    [ -d "$base" ] || return 0
    while read_find_path f; do
        remove_path "$f"
    done < <(find_checked "$base" \( -name ".Spotlight-V100" -o -name ".Trashes" -o -name ".Trash" \) -prune \
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
        for vol in "$SANDBOX"/Volumes/*/; do
            [ -d "$vol" ] || continue
            clean_dsstore_tree "$vol"
        done
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
        remove_path "$h/Library/Saved Application State/com.apple.Terminal.savedState"
        remove_path "$h/Library/Saved Application State/com.googlecode.iterm2.savedState"
    done < <(enumerate_users)
    return 0
}

# --- module: editors ---------------------------------------------------------

# Query once before touching editor history. Do not log process arguments:
# they can contain file names or credentials. Keep editors closed until done.
editors_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(ps -axo command= 2>/dev/null)"; then
        log_warn "editors: cannot inspect running processes; cleanup refused"
        return 1
    fi
    if printf '%s\n' "$processes" | grep -Ei '(^|[ /])(vi|vim|view|ex|rvim|rview|vimdiff|gvim|gvimdiff|mvim|nvim|nvim-qt|code|code-insiders|codium|cursor|windsurf)([[:space:]]|$)|/(Visual Studio Code[^/]*|Code - Insiders|VSCodium|Cursor|Windsurf[^/]*|IntelliJ IDEA[^/]*|PyCharm[^/]*|WebStorm[^/]*|GoLand[^/]*|CLion[^/]*|Rider[^/]*|PhpStorm[^/]*|RubyMine[^/]*|RustRover[^/]*|DataGrip[^/]*|DataSpell[^/]*|Aqua[^/]*|Android Studio[^/]*|MacVim)\.app/|(-Didea\.(paths\.selector|home\.path)=|com\.intellij\.idea\.Main)' >/dev/null; then
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
add_ai_root() {
    local kind="${1%%=*}" path="${1#*=}" relative
    case "$kind" in
        claude|codex|codex-db|opencode|opencode-state|opencode-db|claude-temp|cursor|cursor-editor|windsurf|editor|continue|cline|roo|aider|aider-history) ;;
        *) usage_error "unknown AI root kind: $kind" ;;
    esac
    path="${path%/}"
    case "$path" in
        /Users/*/*) ;;
        *) usage_error "AI roots must be below /Users/<user>/: $path" ;;
    esac
    case "$path/" in
        *'/../'*|*'/./'*|*'//'*) usage_error "AI root must be a normalized absolute path" ;;
    esac
    case "$path" in
        *$'\n'*|*$'\r'*|*$'\t'*) usage_error "AI root must not contain control whitespace" ;;
    esac
    relative="${path#/Users/}"
    [ -n "${relative#*/}" ] || usage_error "AI root cannot be a user home"
    AI_ROOTS[${#AI_ROOTS[@]}]="$kind=$path"
}

ai_environment_roots() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    [ -z "${CONTINUE_GLOBAL_DIR:-}" ] || add_ai_root "continue=$CONTINUE_GLOBAL_DIR"
    if [ -n "${CLINE_DATA_DIR:-}" ]; then
        add_ai_root "cline=$CLINE_DATA_DIR"
    elif [ -n "${CLINE_DIR:-}" ]; then
        add_ai_root "cline=${CLINE_DIR%/}/data"
    fi
    local history_var history_path
    for history_var in AIDER_CHAT_HISTORY_FILE AIDER_INPUT_HISTORY_FILE AIDER_LLM_HISTORY_FILE; do
        history_path="${!history_var:-}"
        [ -n "$history_path" ] || continue
        case "$history_path" in /*) ;; *) history_path="$(pwd -P)/$history_path" ;; esac
        add_ai_root "aider-history=$history_path"
    done
    [ -z "${CLAUDE_CONFIG_DIR:-}" ] || add_ai_root "claude=$CLAUDE_CONFIG_DIR"
    [ -z "${CODEX_HOME:-}" ] || add_ai_root "codex=$CODEX_HOME"
    [ -z "${CODEX_SQLITE_HOME:-}" ] || add_ai_root "codex-db=$CODEX_SQLITE_HOME"
    [ -z "${XDG_DATA_HOME:-}" ] || add_ai_root "opencode=${XDG_DATA_HOME%/}/opencode"
    [ -z "${XDG_STATE_HOME:-}" ] || add_ai_root "opencode-state=${XDG_STATE_HOME%/}/opencode"
    AI_CLAUDE_TMP_BASE="${CLAUDE_CODE_TMPDIR:-/private/tmp}"
    AI_CLAUDE_TMP_BASE="${AI_CLAUDE_TMP_BASE%/}"
    case "$AI_CLAUDE_TMP_BASE" in
        /tmp|/tmp/*) AI_CLAUDE_TMP_BASE="/private$AI_CLAUDE_TMP_BASE" ;;
    esac
    case "$AI_CLAUDE_TMP_BASE/" in
        *'/../'*|*'/./'*|*'//'*) usage_error "CLAUDE_CODE_TMPDIR must be normalized" ;;
    esac
    case "$AI_CLAUDE_TMP_BASE" in
        *$'\n'*|*$'\r'*|*$'\t'*) usage_error "CLAUDE_CODE_TMPDIR must not contain control whitespace" ;;
    esac
    case "$AI_CLAUDE_TMP_BASE" in
        /private/tmp|/private/tmp/*|/private/var/folders/*|/Users/*/*) ;;
        *) usage_error "unsupported CLAUDE_CODE_TMPDIR; use a home or macOS temp directory" ;;
    esac
    if [ -n "${OPENCODE_DB:-}" ] && [ "$OPENCODE_DB" != :memory: ]; then
        case "$OPENCODE_DB" in
            /*) add_ai_root "opencode-db=$OPENCODE_DB" ;;
            *) add_ai_root "opencode-db=${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/$OPENCODE_DB" ;;
        esac
    fi
}

# Fail closed on a failed process query. Do not print command lines: they may
# contain prompts or tokens. Node CLI launchers and desktop helpers also match.
ai_agents_stopped() {
    [ "$TEST_MODE" -eq 0 ] || return 0
    local processes
    if ! processes="$(ps -axo command= 2>/dev/null)"; then
        log_warn "ai: cannot inspect running processes; cleanup refused"
        return 1
    fi
    if printf '%s\n' "$processes" | grep -Ei '(^|[ /])(claude|codex|opencode|cursor-agent|cursor|windsurf|cline|roo|cn|aider)([[:space:]/]|$|\.(js|py)([[:space:]]|$))|/(Codex|Claude|OpenCode|Cursor|Windsurf[^/]*|Visual Studio Code[^/]*|Code - Insiders|VSCodium|IntelliJ IDEA[^/]*|PyCharm[^/]*|WebStorm|GoLand|CLion|Rider|PhpStorm|RubyMine|RustRover|Android Studio)\.app/' >/dev/null; then
        log_warn "ai: close AI agents, supported editors and their background servers first"
        return 1
    fi
    return 0
}

# SQLite runs as the home owner, from a checked physical parent. Reject links
# and hard links for the database AND sidecars before SQLite can open them.
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
    local root="$1" kind="$2" mode="$3" db flavor before="$FAILED_COUNT"
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
        if ! ai_purge_database "$db" "$flavor" "$mode"; then
            FAILED_COUNT=$((FAILED_COUNT + 1))
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
    local dir="$1" flavor="$2" mode="$3" db before="$FAILED_COUNT"
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
                if ! ai_purge_database "$db" "$flavor" "$mode"; then FAILED_COUNT=$((FAILED_COUNT + 1)); fi ;;
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
    local kind="$1" root="$2" project entry phase
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
            if ! ai_purge_database "$root" opencode; then FAILED_COUNT=$((FAILED_COUNT + 1)); fi
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
            guard_mutation_target "$root/projects" || return 0
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

module_ai() {
    local u h uid item path kind matched processed=''
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

module_selected() {
    [ -n "$SELECTED_MODULES" ] || return 0
    case ",$SELECTED_MODULES," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

run_module() {
    case "$1" in
        shell)       module_shell ;;
        systemlogs)  module_systemlogs ;;
        audit)       module_audit ;;
        browser)     module_browser ;;
        unified)     module_unified ;;
        fileevents)  module_fileevents ;;
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
        *)
            log_warn "unknown module id in dispatch: $1"
            ;;
    esac
    return 0
}

run_selected_modules() {
    local id
    if [ -n "$SELECTED_MODULES" ]; then
        log_info "running modules: $(printf '%s' "$SELECTED_MODULES" | tr ',' ' ')"
    else
        log_info "running modules: all"
    fi
    for id in "${MODULE_IDS[@]}"; do
        if module_selected "$id"; then
            log_debug "=== module: $id ==="
            run_module "$id"
        fi
    done
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

    setup_logging

    if [ "$PURGE_SNAPSHOTS" -eq 1 ]; then
        log_info "purging local APFS snapshots (--purge-snapshots)"
        purge_snapshots
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
