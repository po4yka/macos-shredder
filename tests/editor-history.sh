#!/bin/bash
# Editor history tests use marked temporary roots; no host history is touched.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHREDDER="$SCRIPT_DIR/../shredder.sh"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

setup_case() {
    export SHREDDER_ROOT="$WORK/$1"
    mkdir -p "$SHREDDER_ROOT/Users/User Space"
    : > "$SHREDDER_ROOT/.macos-shredder-test-root"
    # shellcheck source=shredder.sh
    source "$SHREDDER"
    TEST_MODE=1
    SANDBOX="$SHREDDER_ROOT"
    resolve_paths
    EDITOR_HOME="$USERS_DIR/User Space"
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-history-marker}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}

test_cleanup() (
    setup_case cleanup
    local app root keep
    for app in Code 'Code - Insiders' VSCodium Cursor Windsurf 'Windsurf - Next'; do
        root="$EDITOR_HOME/Library/Application Support/$app"
        put "$root/User/History/hash/entries.json"
        put "$root/User/History/hash/file.txt"
        put "$root/User/History/.hidden"
        for keep in User/settings.json User/keybindings.json User/profiles/named/settings.json \
            User/globalStorage/state.vscdb User/workspaceStorage/hash/state.vscdb Backups/unsaved; do
            put "$root/$keep" keep
        done
    done
    for app in IntelliJIdea2026.2 PyCharm2026.2 WebStorm2025.3; do
        root="$EDITOR_HOME/Library/Caches/JetBrains/$app"
        put "$root/LocalHistory/changes.storageData"
        put "$root/LocalHistory/.hidden"
        put "$root/index/keep" keep
        put "$EDITOR_HOME/Library/Application Support/JetBrains/$app/options/settings.xml" keep
    done
    put "$EDITOR_HOME/.viminfo"
    put "$EDITOR_HOME/.local/state/nvim/shada/main.shada"
    put "$EDITOR_HOME/.local/state/nvim/shada/main.shada.tmp.a"
    put "$EDITOR_HOME/.local/share/nvim/shada/main.shada"
    for keep in .vimrc .config/nvim/init.lua .local/state/nvim/undo/saved \
        .local/state/nvim/swap/buffer.swp Projects/source.txt Projects/.git/history \
        .vim/swap/file.swp; do put "$EDITOR_HOME/$keep" keep; done
    cp -R "$SANDBOX" "$WORK/before"
    expect_status 0 --modules editors --dry-run --debug
    diff -r "$WORK/before" "$SANDBOX"
    expect_status 0 --modules editors --force
    if grep -R -a -l history-marker "$EDITOR_HOME"; then exit 1; fi
    # Preserve every seeded non-history file, including unsaved buffers.
    while IFS= read -r -d '' keep; do
        if grep -q '^keep$' "$keep"; then cmp "$keep" "$SANDBOX/${keep#"$WORK/before/"}"; fi
    done < <(find "$WORK/before" -type f -print0)
    expect_status 0 --modules editors --force
)
test_cleanup
printf 'PASS: editor history cleanup, profile settings, unsaved buffers and dry-run\n'

test_links() (
    setup_case links
    local root="$EDITOR_HOME/Library/Application Support/Code/User"
    put "$WORK/outside/History/sentinel" keep
    mkdir -p "$root"
    ln -s "$WORK/outside/History" "$root/History"
    mkdir -p "$EDITOR_HOME/Library/Caches"
    ln -s "$WORK/outside" "$EDITOR_HOME/Library/Caches/JetBrains"
    expect_status 2 --modules editors --force
    grep -q keep "$WORK/outside/History/sentinel"
    [ -L "$root/History" ]
    # Final file links can be unlinked; their targets must not be truncated.
    ln -s "$WORK/outside/History/sentinel" "$EDITOR_HOME/.viminfo"
    remove_path "$EDITOR_HOME/.viminfo"
    [ ! -L "$EDITOR_HOME/.viminfo" ]
    grep -q keep "$WORK/outside/History/sentinel"
    # An ordinary file inside History cannot redirect recursive cleanup.
    rm "$root/History"
    mkdir "$root/History"
    ln -s "$WORK/outside" "$root/History/link"
    clear_dir_contents "$root/History"
    [ ! -L "$root/History/link" ]
    grep -q keep "$WORK/outside/History/sentinel"
)
test_links
printf 'PASS: linked editor roots fail closed and history-entry links cannot escape\n'

test_process_guard() (
    setup_case processes
    put "$EDITOR_HOME/.viminfo"
    TEST_MODE=0
    local executable
    for executable in '/Applications/Visual Studio Code.app/Contents/MacOS/Electron' \
        '/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/Electron' \
        '/Applications/Cursor.app/Contents/MacOS/Cursor' \
        '/Applications/Windsurf Next.app/Contents/MacOS/Electron' \
        '/Applications/PyCharm CE.app/Contents/MacOS/pycharm' \
        '/usr/bin/java -Didea.paths.selector=IntelliJIdea2026.2' \
        '/usr/local/bin/nvim file.txt' '/usr/bin/vim file.txt' \
        '/usr/local/bin/code-insiders' '/usr/bin/vimdiff first second'; do
        # shellcheck disable=SC2329 # controlled process-query response
        ps() { printf '%s\n' "$executable"; }
        if editors_stopped; then exit 1; fi
        FAILED_COUNT=0
        module_editors
        [ "$FAILED_COUNT" -eq 1 ]
        grep -q history-marker "$EDITOR_HOME/.viminfo"
    done
    # shellcheck disable=SC2329
    ps() { return 1; }
    FAILED_COUNT=0
    module_editors
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q history-marker "$EDITOR_HOME/.viminfo"
    # Dry-run remains usable even when the process query fails.
    # shellcheck disable=SC2329
    enumerate_users() { printf 'User Space\t%s\t\n' "$EDITOR_HOME"; }
    DRY_RUN=1
    FAILED_COUNT=0
    module_editors
    [ "$FAILED_COUNT" -eq 0 ]
    [ "$CLEANED_COUNT" -gt 0 ]
    grep -q history-marker "$EDITOR_HOME/.viminfo"
    # shellcheck disable=SC2329
    ps() { printf '/usr/bin/other-editor\n'; }
    editors_stopped
)
test_process_guard
printf 'PASS: active editors and process-query failures refuse cleanup\n'

test_enumeration_failure() (
    setup_case enumeration
    FAILED_COUNT=0
    put "$EDITOR_HOME/Library/Caches/JetBrains/IntelliJIdea2026.2/LocalHistory/history"
    # shellcheck disable=SC2329 # simulate a traversal failure independent of UID
    find() { return 1; }
    clean_editor_history_for_home "$EDITOR_HOME"
    [ "$FAILED_COUNT" -eq 1 ]
    grep -q history-marker "$EDITOR_HOME/Library/Caches/JetBrains/IntelliJIdea2026.2/LocalHistory/history"
)
test_enumeration_failure
printf 'PASS: editor-history enumeration failures are counted\n'
