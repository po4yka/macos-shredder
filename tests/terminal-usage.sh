#!/bin/bash
# All deletion targets are synthetic data below marked temporary roots.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

setup() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1
    SANDBOX="$SHREDDER_ROOT"
    resolve_paths
    STORE_HOME="$USERS_DIR/User Space"
    TERMINAL_SESSIONS=0
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-history-marker}" > "$1"; }
seed_terminal() {
    local h="$1" entry
    for entry in terminal-history session-history session-com.cmuxterm.app-scrollback; do
        put "$h/Library/Application Support/cmux/$entry/.hidden-history"
        put "$h/Library/Application Support/cmux/$entry/session/history.json"
    done
    for entry in workstream.jsonl events.jsonl events.jsonl.1 agent-journal-dead-letter.jsonl; do
        put "$h/.cmuxterm/$entry"
    done
    put "$h/.cmuxterm/config.json" keep
    put "$h/.cmuxterm/events.jsonl.seq" keep
    put "$h/.cmuxterm/events.jsonl.notes" keep
    put "$h/.cmuxterm/claude-settings/settings.json" keep
    put "$h/.cmuxterm/cmux-cli-shims/cmux" keep
    put "$h/Library/Application Support/cmux/config.json" keep
    put "$h/Library/Application Support/cmux/sudo/token" keep
}

test_terminal() (
    setup terminal
    local h entry
    mkdir -p "$USERS_DIR/second"
    for h in "$STORE_HOME" "$USERS_DIR/second"; do seed_terminal "$h"; done
    cp -R "$SANDBOX" "$WORK/before-terminal"
    module_shell
    diff -r "$WORK/before-terminal" "$SANDBOX"
    TERMINAL_SESSIONS=1
    DRY_RUN=1
    module_shell
    diff -r "$WORK/before-terminal" "$SANDBOX"
    DRY_RUN=0
    module_shell
    [ "$FAILED_COUNT" -eq 0 ]
    for h in "$STORE_HOME" "$USERS_DIR/second"; do
        for entry in terminal-history session-history session-com.cmuxterm.app-scrollback; do
            [ -d "$h/Library/Application Support/cmux/$entry" ]
            [ -z "$(find "$h/Library/Application Support/cmux/$entry" -mindepth 1 -print)" ]
        done
        for entry in workstream.jsonl events.jsonl events.jsonl.1 agent-journal-dead-letter.jsonl; do
            [ ! -e "$h/.cmuxterm/$entry" ]
        done
        for entry in config.json events.jsonl.seq events.jsonl.notes claude-settings/settings.json cmux-cli-shims/cmux; do
            grep -q keep "$h/.cmuxterm/$entry"
        done
        grep -q keep "$h/Library/Application Support/cmux/config.json"
        grep -q keep "$h/Library/Application Support/cmux/sudo/token"
    done
    module_shell
    [ "$FAILED_COUNT" -eq 0 ]
)
test_terminal
printf 'PASS: cmux histories are opt-in, dry-run stable and repeatable; configuration remains\n'

test_terminal_guards() (
    setup terminal-guards
    seed_terminal "$STORE_HOME"
    TERMINAL_SESSIONS=1
    terminal_sessions_stopped() { return 1; }
    module_shell
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q history-marker "$STORE_HOME/.cmuxterm/workstream.jsonl"
    grep -q history-marker "$STORE_HOME/Library/Application Support/cmux/session-history/.hidden-history"
    # Exercise actual detection with controlled process metadata only.
    unset -f terminal_sessions_stopped
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=0
    ps() { printf '%s\n' "$PROCESS_LINE"; }
    local process
    for process in '/Applications/cmux.app/Contents/MacOS/cmux' '/usr/local/bin/cmux --socket /tmp/test' '/opt/bin/cmuxterm-daemon'; do
        PROCESS_LINE="$process"
        if terminal_sessions_stopped; then exit 1; fi
    done
    PROCESS_LINE='/bin/bash shredder.sh --modules shell --terminal-sessions'
    terminal_sessions_stopped
    ps() { return 1; }
    if terminal_sessions_stopped; then exit 1; fi
)
test_terminal_guards
printf 'PASS: active cmux clients and failed process inspection retain terminal sessions\n'

test_terminal_links() (
    setup terminal-links
    put "$WORK/terminal-outside/keep" keep
    mkdir -p "$STORE_HOME/Library/Application Support/cmux"
    ln -s "$WORK/terminal-outside" "$STORE_HOME/Library/Application Support/cmux/session-history"
    ln -s "$WORK/terminal-outside" "$STORE_HOME/.cmuxterm"
    TERMINAL_SESSIONS=1
    module_shell
    [ "$FAILED_COUNT" -eq 2 ]
    grep -q keep "$WORK/terminal-outside/keep"
    [ -L "$STORE_HOME/.cmuxterm" ]
    [ -L "$STORE_HOME/Library/Application Support/cmux/session-history" ]
)
test_terminal_links
printf 'PASS: cmux linked store directories cannot redirect cleanup\n'

test_recent_documents() (
    setup recent-documents
    local root="$STORE_HOME/Library/Application Support/com.apple.sharedfilelist" nested ext
    nested="$root/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    for ext in sfl2 sfl3 sfl4; do put "$nested/com.example.app.$ext"; done
    put "$root/com.apple.LSSharedFileList.RecentDocuments.sfl3"
    put "$root/com.apple.LSSharedFileList.FavoriteItems.sfl3" keep
    put "$nested/com.example.app.sfl5" keep
    put "$nested/notes.txt" keep
    put "$nested/nested/com.example.app.sfl4" keep
    put "$WORK/recent-outside" keep
    ln -s "$WORK/recent-outside" "$nested/com.example.link.sfl4"
    cp -R "$SANDBOX" "$WORK/before-recent"
    DRY_RUN=1
    module_usage
    diff -r "$WORK/before-recent" "$SANDBOX"
    DRY_RUN=0
    module_usage
    [ "$FAILED_COUNT" -eq 0 ]
    for ext in sfl2 sfl3 sfl4; do [ ! -e "$nested/com.example.app.$ext" ]; done
    [ ! -e "$root/com.apple.LSSharedFileList.RecentDocuments.sfl3" ]
    grep -q keep "$root/com.apple.LSSharedFileList.FavoriteItems.sfl3"
    grep -q keep "$nested/com.example.app.sfl5"
    grep -q keep "$nested/notes.txt"
    grep -q keep "$nested/nested/com.example.app.sfl4"
    grep -q keep "$WORK/recent-outside"
    [ -L "$nested/com.example.link.sfl4" ]
    module_usage
    [ "$FAILED_COUNT" -eq 0 ]
)
test_recent_documents
printf 'PASS: nested application recent lists are cleared; favorites and unknown formats remain\n'

test_recent_links() (
    setup recent-links
    local root="$STORE_HOME/Library/Application Support/com.apple.sharedfilelist"
    put "$WORK/recent-directory-outside/com.example.app.sfl4" keep
    mkdir -p "$root"
    ln -s "$WORK/recent-directory-outside" "$root/com.apple.LSSharedFileList.ApplicationRecentDocuments"
    module_usage
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q keep "$WORK/recent-directory-outside/com.example.app.sfl4"
)
test_recent_links
printf 'PASS: linked recent-document directories are refused\n'
