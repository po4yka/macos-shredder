#!/bin/bash
# Terminal output tests use only marked temporary fixture homes.
# shellcheck disable=SC2034 # Sourced functions consume the globals.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
export SHREDDER_ROOT="$WORK/root"
mkdir -p "$SHREDDER_ROOT/Users/Alice" "$SHREDDER_ROOT/Users/User Space"
: > "$SHREDDER_ROOT/.macos-shredder-test-root"
# shellcheck source=shredder.sh
source "$SHREDDER"
TEST_MODE=1
SANDBOX="$SHREDDER_ROOT"
resolve_paths
if module_selected terminal; then exit 1; fi
parse_args --modules terminal --terminal-log-file '/Users/User Space/logs/session.txt'
for h in "$USERS_DIR/Alice" "$USERS_DIR/User Space"; do
    for state in 'Library/Saved Application State/com.apple.Terminal.savedState' 'Library/Saved Application State/com.googlecode.iterm2.savedState' 'Library/Application Support/iTerm2/SavedState'; do
        mkdir -p "$h/$state"
        printf 'output\n' > "$h/$state/data"
    done
    mkdir -p "$h/Library/Preferences" "$h/Library/Application Support/iTerm2" "$h/logs"
    printf 'keep\n' > "$h/Library/Preferences/com.googlecode.iterm2.plist"
    printf 'keep\n' > "$h/Library/Application Support/iTerm2/Arrangements.plist"
    printf 'keep\n' > "$h/logs/unselected.txt"
done
printf 'output\n' > "$USERS_DIR/User Space/logs/session.txt"
cp -R "$SANDBOX" "$WORK/before"
DRY_RUN=1
module_terminal
[ "$CLEANED_COUNT" -eq 7 ]
diff -r "$WORK/before" "$SANDBOX"
DRY_RUN=0
module_terminal
[ "$FAILED_COUNT" -eq 0 ]
[ ! -e "$USERS_DIR/User Space/logs/session.txt" ]
for h in "$USERS_DIR/Alice" "$USERS_DIR/User Space"; do
    [ ! -e "$h/Library/Application Support/iTerm2/SavedState" ]
    [ ! -e "$h/Library/Saved Application State/com.apple.Terminal.savedState" ]
    [ ! -e "$h/Library/Saved Application State/com.googlecode.iterm2.savedState" ]
    grep -q keep "$h/Library/Preferences/com.googlecode.iterm2.plist"
    grep -q keep "$h/Library/Application Support/iTerm2/Arrangements.plist"
    grep -q keep "$h/logs/unselected.txt"
done
printf 'PASS: terminal selection, multiple homes, saved output, settings and dry-run\n'
# Regular-file-only, final/parent symlink refusal and ineligible home.
printf 'keep\n' > "$WORK/outside"
ln -s "$WORK/outside" "$USERS_DIR/Alice/logs/link"
ln -s "$WORK" "$USERS_DIR/Alice/linked"
TERMINAL_LOG_FILES=(/Users/Alice/logs /Users/Alice/logs/link /Users/Alice/linked/outside /Users/Missing/log.txt)
module_terminal
[ "$FAILED_COUNT" -eq 4 ]
grep -q keep "$WORK/outside"
[ -L "$USERS_DIR/Alice/logs/link" ]
for bad in /etc/passwd /Users/Alice/../Bob/log /Users/Alice/logs/ /Users/Shared/log /Users/Alice//log; do
    if (add_terminal_log_file "$bad") >/dev/null 2>&1; then exit 1; fi
done
if (parse_args --modules shell --terminal-log-file /Users/Alice/log) >/dev/null 2>&1; then exit 1; fi
printf 'PASS: terminal custom log boundaries and usage validation\n'
# Process query failure, active app, helper and clean result.
TEST_MODE=0
ps() { return 2; }
if terminal_clients_stopped; then exit 1; fi
ps() { printf '/Applications/iTerm.app/Contents/MacOS/iTerm2\n'; }
if terminal_clients_stopped; then exit 1; fi
ps() { printf '/Applications/iTerm.app/Contents/MacOS/iTermServer-3.5.0\n'; }
if terminal_clients_stopped; then exit 1; fi
ps() { printf '/bin/bash test\n'; }
terminal_clients_stopped
unset -f ps
printf 'PASS: terminal process and restoration server guards\n'
