#!/bin/bash
#
# macos-shredder - forensic-trace cleaner for macOS
# Copyright (C) 2026 The macos-shredder authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
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

###############################################################################
# SECTION: Global configuration
###############################################################################

DRY_RUN=0
DEBUG=0
FORCE=0
LIST_ONLY=0
INCLUDE_VOLUMES=0
PURGE_SNAPSHOTS=0
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
)
MODULE_DESCS=(
    "Shell and REPL histories, session data"
    "System logs and crash reports"
    "BSM audit logs"
    "Browser histories, cookies, caches"
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
# These four helpers are the ONLY places where raw rm / truncate / sqlite
# mutations happen. They are DRY_RUN-aware, they emit debug detail when
# DEBUG=1, and they keep the global CLEANED_COUNT / FAILED_COUNT honest.
###############################################################################

# Refuse mutations through symlink components inside user-controlled homes.
# System paths such as /var are symlinks on macOS, so this check is scoped to
# USERS_DIR where an unprivileged user can prepare a path before a root run.
guard_user_target() {
    local target="$1"
    local relative user_home cursor parent
    case "$target" in
        "$USERS_DIR"/*) ;;
        *) return 0 ;;
    esac
    relative="${target#"$USERS_DIR"/}"
    user_home="$USERS_DIR/${relative%%/*}"
    cursor="$target"
    while :; do
        if [ -L "$cursor" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_debug "[DRY RUN] would refuse user path with symlink component: $target"
            else
                log_warn "refusing user path with symlink component: $target"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 1
        fi
        [ "$cursor" = "$user_home" ] && return 0
        parent="${cursor%/*}"
        if [ "$parent" = "$cursor" ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                log_debug "[DRY RUN] would refuse user path outside its home: $target"
            else
                log_warn "refusing user path outside its home: $target"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
            return 1
        fi
        cursor="$parent"
    done
}

# remove_path PATH - recursively delete a file/dir/symlink after an
# existence check. Broken symlinks are handled via the -L test.
remove_path() {
    local target="$1"
    if [ -z "$target" ]; then
        return 0
    fi
    guard_user_target "$target" || return 0
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        log_debug "not present, skipping: $target"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would remove: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if rm -rf -- "$target" 2>/dev/null; then
        log_debug "removed: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
    else
        log_warn "failed to remove: $target"
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
    return 0
}

# truncate_file PATH - empty an existing regular file in place.
truncate_file() {
    local target="$1"
    if [ -z "$target" ]; then
        return 0
    fi
    guard_user_target "$target" || return 0
    if [ ! -f "$target" ]; then
        log_debug "not a regular file, skipping: $target"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would truncate: $target"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if : > "$target" 2>/dev/null; then
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
clear_dir_contents() {
    local dir="$1"
    local p count=0
    if [ -z "$dir" ]; then
        log_debug "directory not present, skipping: <empty>"
        return 0
    fi
    guard_user_target "$dir" || return 0
    if [ ! -d "$dir" ]; then
        log_debug "directory not present, skipping: $dir"
        return 0
    fi
    if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
        log_warn "directory is not readable/searchable: $dir"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 0
    fi
    while IFS= read -r -d '' p; do
        remove_path "$p"
        count=$((count + 1))
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
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
    if [ -z "$db" ]; then
        log_debug "database not present, skipping: <empty>"
        return 0
    fi
    guard_user_target "$db" || return 0
    if [ ! -f "$db" ]; then
        log_debug "database not present, skipping: $db"
        return 0
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_debug "sqlite3 unavailable; removing database instead: $db"
        remove_path "$db"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would execute sqlite statement [$sql] on: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    if sqlite3 "$db" "$sql" >/dev/null 2>&1; then
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

# run_as_user USER UID HOME CMD... - run a per-user command in the REAL user's
# context (fixes sudo-context bugs where defaults/qlmanage acted on root).
run_as_user() {
    local user="$1"
    local uid="$2"
    local home="$3"
    shift 3
    [ $# -gt 0 ] || return 0
    if [ "$TEST_MODE" -eq 1 ]; then
        HOME="$home" "$@"
        return $?
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

# browser_running PROC - true when the given browser process is running.
browser_running() {
    local proc="$1"
    [ "$TEST_MODE" -eq 0 ] || return 1
    command -v pgrep >/dev/null 2>&1 || return 1
    pgrep -x "$proc" >/dev/null 2>&1
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
      --logfile FILE    Append a timestamped operation log to FILE
      --include-volumes Also process mounted volumes under /Volumes
      --purge-snapshots Delete APFS Time Machine local snapshots before modules

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
            --purge-snapshots)
                PURGE_SNAPSHOTS=1
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
    LOGFILE="$LOGFILE_ARG"
    if ! : >> "$LOGFILE" 2>/dev/null; then
        printf '%b\n' "${COLOR_RED}[x]${COLOR_RESET} cannot write logfile: $LOGFILE" >&2
        exit 1
    fi
    exec 3>> "$LOGFILE"
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
        guard_user_target "$safari_dir" || return 1
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
        return 0
    fi
    local snaps snap
    snaps="$(tmutil listlocalsnapshots / 2>/dev/null \
        | grep -E '^com\.apple\.TimeMachine\.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]\.local$' \
        || true)"
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
module_shell() {
    local u h uid hf
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
.viminfo
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
        truncate_file "$h/.ipython/profile_default/history.sqlite"
        truncate_file "$h/.julia/logs/repl_history.jl"
        truncate_file "$h/.ghc/ghci_history"
        if [ -d "$h/.matlab" ]; then
            # MATLAB keeps History.xml one level per version; find instead
            # of a quoted-star glob.
            while IFS= read -r -d '' mf; do
                truncate_file "$mf"
            done < <(find "$h/.matlab" -mindepth 1 -maxdepth 2 -type f -name 'History.xml' -print0 2>/dev/null)
        fi
        truncate_file "$h/.local/share/fish/fish_history"
        truncate_file "$h/.local/share/recently-used.xbel"
        truncate_file "$h/.local/share/mc/history"
        truncate_file "$h/.local/share/nano/search_history"
    done < <(enumerate_users)
    return 0
}

# --- module: systemlogs ------------------------------------------------------
module_systemlogs() {
    local lf u h uid
    for lf in system.log wifi.log install.log accountpolicy.log appfirewall.log; do
        truncate_file "$VAR_LOG/$lf"
    done
    while IFS= read -r -d '' f; do
        truncate_file "$f"
    done < <(find "$VAR_LOG" -maxdepth 1 -type f -name 'fsck*' -print0 2>/dev/null)
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
    local audit_enabled=0
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
        local n
        n="$(find "$VAR_AUDIT" -maxdepth 1 \( -type f -o -type l \) -name '[0-9]*' 2>/dev/null \
            | wc -l | tr -d ' ' || true)"
        [ -n "$n" ] || n=0
        log_debug "[DRY RUN] would remove $n timestamped audit files under $VAR_AUDIT (preserving 'current')"
        CLEANED_COUNT=$((CLEANED_COUNT + n))
        return 0
    fi
    if [ "$TEST_MODE" -eq 0 ] && command -v audit >/dev/null 2>&1 && audit -c >/dev/null 2>&1; then
        audit_enabled=1
        log_debug "closing current audit record (audit -t)"
        audit -t >/dev/null 2>&1 || log_debug "audit -t returned non-zero (continuing)"
    else
        log_debug "BSM audit is unavailable or disabled; deleting existing trail files only"
    fi
    # Delete timestamped trail files by basename pattern; never touch the
    # 'current' symlink.
    local f b
    while IFS= read -r -d '' f; do
        b="${f##*/}"
        [ "$b" = "current" ] && continue
        remove_path "$f"
    done < <(find "$VAR_AUDIT" -maxdepth 1 -name '[0-9]*' -print0 2>/dev/null)
    if [ "$audit_enabled" -eq 1 ]; then
        audit -s >/dev/null 2>&1 || log_debug "audit -s failed (best effort)"
    fi
    return 0
}

# --- module: browser ---------------------------------------------------------
clean_safari_for_home() {
    local h="$1"
    local saf="$h/Library/Safari"
    if browser_running "Safari"; then
        log_warn "Safari is running; skipping Safari database deletion (data integrity)"
    else
        remove_path "$saf/History.db"
        remove_path "$saf/History.db-wal"
        remove_path "$saf/History.db-shm"
        remove_path "$saf/History.db-lock"
        remove_path "$saf/Downloads.plist"
        remove_path "$saf/TopSites.plist"
        remove_path "$saf/LastSession.plist"
    fi
    clear_dir_contents "$h/Library/Caches/com.apple.Safari"
    return 0
}

clean_chrome_profile_dbs() {
    local prof="$1"
    remove_path "$prof/History"
    remove_path "$prof/History-wal"
    remove_path "$prof/History-shm"
    remove_path "$prof/Cookies"
    remove_path "$prof/Cookies-wal"
    remove_path "$prof/Cookies-shm"
    remove_path "$prof/Top Sites"
    remove_path "$prof/Web Data"
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
    local label proc rel appdir prof
    while IFS='|' read -r label proc rel; do
        [ -n "$label" ] || continue
        appdir="$h/$rel"
        [ -d "$appdir" ] || continue
        if browser_running "$proc"; then
            log_warn "$label is running; skipping $label database deletion (data integrity)"
        else
            for prof in "$appdir/Default" "$appdir"/Profile\ */; do
                prof="${prof%/}"
                [ -d "$prof" ] || continue
                clean_chrome_profile_dbs "$prof"
            done
        fi
        # Pure cache directories are safe even while the browser runs.
        for prof in "$appdir/Default" "$appdir"/Profile\ */; do
            prof="${prof%/}"
            [ -d "$prof" ] || continue
            clean_chrome_profile_caches "$prof"
        done
    done <<'CHROME_BROWSERS'
Google Chrome|Google Chrome|Library/Application Support/Google/Chrome
Chromium|Chromium|Library/Application Support/Chromium
Microsoft Edge|Microsoft Edge|Library/Application Support/Microsoft Edge
Brave|Brave|Library/Application Support/BraveSoftware/Brave-Browser
CHROME_BROWSERS
    return 0
}

clean_firefox_for_home() {
    local h="$1"
    local profiles="$h/Library/Application Support/Firefox/Profiles"
    [ -d "$profiles" ] || return 0
    local skip_dbs=0 prof
    if browser_running "firefox"; then
        log_warn "Firefox is running; skipping Firefox database deletion (data integrity)"
        skip_dbs=1
    fi
    for prof in "$profiles"/*.default*/; do
        [ -d "$prof" ] || continue
        if [ "$skip_dbs" -eq 0 ]; then
            remove_path "$prof/places.sqlite"
            remove_path "$prof/places.sqlite-wal"
            remove_path "$prof/places.sqlite-shm"
            remove_path "$prof/cookies.sqlite"
            remove_path "$prof/cookies.sqlite-wal"
            remove_path "$prof/cookies.sqlite-shm"
            remove_path "$prof/formhistory.sqlite"
        fi
        clear_dir_contents "$prof/cache2"
        clear_dir_contents "$prof/thumbnails"
        clear_dir_contents "$prof/sessionstore-backups"
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
    # Restart lsd so it releases its open handles on the quarantine stores.
    if [ "$TEST_MODE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        if command -v killall >/dev/null 2>&1; then
            killall lsd >/dev/null 2>&1 || log_debug "killall lsd failed (best effort)"
        fi
    fi
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
    local tbl tables
    guard_user_target "$db" || return 0
    [ -f "$db" ] || return 0
    if ! command -v sqlite3 >/dev/null 2>&1; then
        log_debug "sqlite3 unavailable; removing KnowledgeC database instead: $db"
        remove_path "$db"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        log_debug "[DRY RUN] would purge knowledge tables and VACUUM: $db"
        CLEANED_COUNT=$((CLEANED_COUNT + 1))
        return 0
    fi
    tables="$(sqlite3 "$db" \
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('ZOBJECT','ZSTRUCTUREDMETADATA');" \
        2>/dev/null || true)"
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
    local key ri_ok
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
    ri_ok=0
    for key in RecentDocuments RecentApplications RecentServers; do
        if run_as_user "$u" "$uid" "$h" defaults delete com.apple.recentitems "$key" >/dev/null 2>&1; then
            ri_ok=1
        fi
    done
    if [ "$ri_ok" -eq 1 ]; then
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
    while IFS= read -r -d '' nc; do
        if [ -d "$nc/db2" ]; then
            clear_dir_contents "$nc/db2"
        fi
    done < <(find "$VAR_FOLDERS" -type d -name 'com.apple.notificationcenter' -print0 2>/dev/null)
    # Recent items, executed in each user's own context.
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        purge_knowledge_db "$h/Library/Application Support/Knowledge/knowledgeC.db"
        clean_recent_items_for_user "$u" "$h" "$uid"
        recent_dir="$h/Library/Application Support/com.apple.sharedfilelist"
        if [ -d "$recent_dir" ]; then
            while IFS= read -r -d '' recent_file; do
                remove_path "$recent_file"
            done < <(find "$recent_dir" -maxdepth 1 -type f -name '*Recent*.sfl*' -print0 2>/dev/null)
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
    elif command -v mdutil >/dev/null 2>&1; then
        if ! mdutil -E /System/Volumes/Data >/dev/null 2>&1; then
            mdutil -E / >/dev/null 2>&1 || log_warn "mdutil -E failed for both the data volume and /"
        fi
    else
        log_debug "mdutil unavailable; skipping Spotlight index erase"
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
    while IFS= read -r -d '' qc; do
        clear_dir_contents "$qc"
    done < <(find "$VAR_FOLDERS" -type d -name 'com.apple.QuickLook.thumbnailcache' -print0 2>/dev/null)
    return 0
}

# --- module: trash -----------------------------------------------------------
module_trash() {
    local u h uid
    while IFS=$'\t' read -r u h uid; do
        [ -d "$h" ] || continue
        if [ -d "$h/.Trash" ]; then
            # clear_dir_contents enumerates dotfiles too, so hidden Trash
            # entries are removed as well.
            clear_dir_contents "$h/.Trash"
        fi
    done < <(enumerate_users)
    return 0
}

# --- module: dsstore ---------------------------------------------------------
clean_dsstore_tree() {
    local base="$1"
    local f
    [ -d "$base" ] || return 0
    while IFS= read -r -d '' f; do
        remove_path "$f"
    done < <(find "$base" \( -name ".Spotlight-V100" -o -name ".Trashes" -o -name ".Trash" \) -prune \
             -o -type f -name ".DS_Store" -print0 2>/dev/null)
}

module_dsstore() {
    local vol
    # User homes are the useful default scope. Avoid the previous full-root
    # walk; mounted volumes stay opt-in.
    clean_dsstore_tree "$USERS_DIR"
    if [ "$TEST_MODE" -eq 1 ]; then
        # The sandbox models the APFS Data view as a separate tree.
        clean_dsstore_tree "$DATA_VOLUME/Users"
    fi
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
    remove_path "$SYS_PREFS/SystemConfiguration/com.apple.airport.preferences.plist"
    remove_path "$SYS_PREFS/SystemConfiguration/com.apple.wifi.message-tracer.plist"
    clear_dir_contents "$SYS_PREFS/SystemConfiguration/com.apple.wifi.known-networks"
    while IFS= read -r -d '' f; do
        truncate_file "$f"
    done < <(find "$VAR_LOG" -maxdepth 1 -type f -name 'wifi.log*' -print0 2>/dev/null)
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
            while IFS= read -r -d '' jd; do
                clear_dir_contents "$jd"
            done < <(find "$h/Library/Logs" -maxdepth 1 -type d -name 'JetBrains*' -print0 2>/dev/null)
        fi
        remove_path "$h/Library/Saved Application State/com.apple.Terminal.savedState"
        remove_path "$h/Library/Saved Application State/com.googlecode.iterm2.savedState"
    done < <(enumerate_users)
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
    setup_logging

    if [ "$LIST_ONLY" -eq 1 ]; then
        printf '%b\n' "Available modules:"
        print_module_list
        exit 0
    fi

    print_banner
    detect_environment
    print_warning_banner
    check_privileges

    if [ "$TEST_MODE" -eq 0 ]; then
        if ! probe_full_disk_access; then
            warn_fda_missing
            if [ "$FORCE" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
                if ! confirm_action "Continue anyway? [y/N]: "; then
                    die "aborted by user"
                fi
            fi
        fi
    fi

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

main "$@"
