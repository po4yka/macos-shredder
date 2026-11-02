#!/bin/bash
# Extension/editor cleanup acceptance tests. All data is synthetic and local
# to a marked temporary sandbox; SQLite executes real transactions.
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
    AI_HOME="$USERS_DIR/User Space"
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-session-marker}" > "$1"; }
expect_status() {
    local expected="$1" rc=0
    shift
    /bin/bash "$SHREDDER" "$@" > "$WORK/last.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then cat "$WORK/last.log"; printf 'expected %s, got %s\n' "$expected" "$rc"; return 1; fi
}
seed_editor_db() {
    mkdir -p "${1%/*}"
    sqlite3 "$1" <<'SQL'
CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value BLOB);
CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value BLOB);
CREATE TABLE composerHeaders(id TEXT PRIMARY KEY, title TEXT);
INSERT INTO ItemTable VALUES('composer.composerData','session-marker');
INSERT INTO ItemTable VALUES('workbench.panel.aichat.view.aichat.chatdata','session-marker');
INSERT INTO ItemTable VALUES('aiService.prompts','session-marker');
INSERT INTO ItemTable VALUES('aiService.generations','session-marker');
INSERT INTO ItemTable VALUES('saoudrizwan.claude-dev','{"taskHistory":[{"task":"session-marker"}],"apiProvider":"keep","autoApprovalSettings":{"enabled":false},"nested":{"taskHistory":"keep"}}');
INSERT INTO ItemTable VALUES('rooveterinaryinc.roo-cline','{"taskHistory":[{"task":"session-marker"}],"taskHistoryRetention":30,"apiProvider":"keep"}');
INSERT INTO ItemTable VALUES('secret://extension-auth',X'000102FF');
INSERT INTO ItemTable VALUES('cursorAuth/accessToken','keep');
INSERT INTO ItemTable VALUES('aiService.prompts.settings','keep');
INSERT INTO ItemTable VALUES('unrelated.extension','{"taskHistory":["keep"]}');
INSERT INTO cursorDiskKV VALUES('composerData:chat','session-marker');
INSERT INTO cursorDiskKV VALUES('bubbleId:chat:bubble','session-marker');
INSERT INTO cursorDiskKV VALUES('checkpointId:chat:checkpoint','session-marker');
INSERT INTO cursorDiskKV VALUES('agentKv:chat:item','session-marker');
INSERT INTO cursorDiskKV VALUES('auth:token','keep');
INSERT INTO composerHeaders VALUES('chat','session-marker');
SQL
}

test_editors() (
    setup editors
    local root="$AI_HOME/Library/Application Support/Cursor/User" db name
    for name in globalStorage workspaceStorage/hash profiles/named/globalStorage profiles/named/workspaceStorage/hash; do
        seed_editor_db "$root/$name/state.vscdb"
        cp "$root/$name/state.vscdb" "$root/$name/state.vscdb.backup"
    done
    put "$root/settings.json" keep
    put "$root/keybindings.json" keep
    put "$root/workspaceStorage/hash/workspace.json" keep
    put "$root/profiles/named/globalStorage/rooveterinaryinc.roo-cline/tasks/id/api_conversation_history.json"
    put "$root/profiles/named/globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml" keep
    put "$root/globalStorage/saoudrizwan.claude-dev/tasks/id/ui_messages.json"
    put "$root/globalStorage/saoudrizwan.claude-dev/checkpoints/hash/.git/objects/obj"
    put "$root/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json" keep
    cp -R "$SANDBOX" "$WORK/editor-before"
    expect_status 0 --modules ai --dry-run --debug
    diff -r "$WORK/editor-before" "$SANDBOX"
    expect_status 0 --modules ai --force
    if grep -R -a -l session-marker "$root"; then exit 1; fi
    for name in globalStorage workspaceStorage/hash profiles/named/globalStorage profiles/named/workspaceStorage/hash; do
        for db in "$root/$name/state.vscdb" "$root/$name/state.vscdb.backup"; do
            [ "$(sqlite3 "$db" "SELECT hex(value) FROM ItemTable WHERE key='secret://extension-auth';")" = 000102FF ]
            [ "$(sqlite3 "$db" "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';")" = keep ]
            [ "$(sqlite3 "$db" "SELECT json_extract(CAST(value AS TEXT),'$.autoApprovalSettings.enabled') FROM ItemTable WHERE key='saoudrizwan.claude-dev';")" = 0 ]
            [ "$(sqlite3 "$db" "SELECT json_extract(CAST(value AS TEXT),'$.nested.taskHistory') FROM ItemTable WHERE key='saoudrizwan.claude-dev';")" = keep ]
            [ "$(sqlite3 "$db" "SELECT json_extract(CAST(value AS TEXT),'$.taskHistoryRetention') FROM ItemTable WHERE key='rooveterinaryinc.roo-cline';")" = 30 ]
            [ "$(sqlite3 "$db" "SELECT value FROM cursorDiskKV WHERE key='auth:token';")" = keep ]
            [ "$(sqlite3 "$db" 'PRAGMA integrity_check;')" = ok ]
        done
    done
    grep -q keep "$root/settings.json"
    grep -q keep "$root/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"
    grep -q keep "$root/profiles/named/globalStorage/rooveterinaryinc.roo-cline/settings/custom_modes.yaml"
    # Ordinary VS Code stores lose only the two supported extension histories.
    root="$AI_HOME/Library/Application Support/Code/User"
    seed_editor_db "$root/globalStorage/state.vscdb"
    expect_status 0 --modules ai --force
    [ "$(sqlite3 "$root/globalStorage/state.vscdb" "SELECT count(*) FROM cursorDiskKV;")" = 5 ]
    [ "$(sqlite3 "$root/globalStorage/state.vscdb" "SELECT json_type(CAST(value AS TEXT),'$.taskHistory') IS NULL FROM ItemTable WHERE key='rooveterinaryinc.roo-cline';")" = 1 ]
    expect_status 0 --modules ai --force
)
test_editors
printf 'PASS: Cursor profiles/workspaces/backups and Cline/Roo Mementos preserve settings and secrets\n'

test_file_stores() (
    setup stores
    local item uuid=11111111-1111-1111-1111-111111111111
    for item in ".codeium/windsurf/cascade/$uuid.pb" ".cursor/chats/work/$uuid/meta.json" \
        ".cursor/projects/work/agent-transcripts/$uuid/subagents/agent.jsonl" \
        .continue/sessions/sessions.json .continue/sessions/chat.json \
        .cline/data/tasks/id/api_conversation_history.json .cline/data/sessions/id/messages.json \
        .cline/data/state/taskHistory.json .cline/data/logs/session.log \
        'Projects/Repo Space/.aider.chat.history.md' 'Projects/Repo Space/.aider.input.history' \
        'Projects/Repo Space/.aider.llm.history'; do put "$AI_HOME/$item"; done
    mkdir -p "$AI_HOME/.cline/data/db" "$AI_HOME/.cursor/chats/work/$uuid"
    sqlite3 "$AI_HOME/.cline/data/db/sessions.db" 'CREATE TABLE sessions(id TEXT); INSERT INTO sessions VALUES("session-marker");'
    sqlite3 "$AI_HOME/.cursor/chats/work/$uuid/store.db" 'CREATE TABLE blobs(id TEXT, data BLOB); INSERT INTO blobs VALUES("id","session-marker");'
    for item in .codeium/windsurf/cascade/settings.pb .codeium/windsurf/cascade/settings.json \
        .codeium/windsurf/mcp_config.json .codeium/windsurf/memories/memory.md .codeium/config.json \
        .cursor/cli-config.json .cursor/auth.json .cursor/mcp.json .cursor/rules/rule.mdc \
        .cursor/projects/work/mcp.json .cursor/worktrees/work/source.py \
        .continue/config.yaml .continue/config.json .continue/.env .continue/auth.json \
        .cline/data/secrets.json .cline/data/settings/cline_mcp_settings.json .cline/data/db/cron.db \
        'Projects/Repo Space/.env' 'Projects/Repo Space/.aider.conf.yml' 'Projects/Repo Space/main.py' \
        'Projects/Repo Space/.git/.aider.chat.history.md'; do put "$AI_HOME/$item" keep; done
    put "$AI_HOME/.cline/data/globalState.json" '{"taskHistory":["session-marker"],"apiProvider":"keep","autoApprovalSettings":{"enabled":false}}'
    cp -R "$SANDBOX" "$WORK/stores-before"
    expect_status 0 --modules ai --dry-run
    diff -r "$WORK/stores-before" "$SANDBOX"
    expect_status 0 --modules ai --force
    if grep -R -a -l session-marker "$AI_HOME"; then exit 1; fi
    while IFS= read -r item; do
        cmp "$WORK/stores-before/Users/User Space/$item" "$AI_HOME/$item"
    done < <(cd "$WORK/stores-before/Users/User Space" && grep -R -l '^keep$' . | sed 's|^./||')
    (cd "$AI_HOME/.cline/data" && [ "$(sqlite3 :memory: "SELECT json_extract(CAST(readfile('globalState.json') AS TEXT),'$.apiProvider');")" = keep ])
)
test_file_stores
printf 'PASS: Windsurf, Cursor CLI/transcripts, Continue, Cline and Aider files; configuration intact\n'

test_failures() (
    setup failures
    local root="$AI_HOME/Library/Application Support/Cursor/User" db
    db="$root/globalStorage/state.vscdb"
    seed_editor_db "$db"
    put "$root/globalStorage/rooveterinaryinc.roo-cline/tasks/id/message.json"
    sqlite3 "$db" 'CREATE TABLE unknown(value TEXT);'
    cp "$db" "$WORK/db-before"
    expect_status 2 --modules ai --force
    cmp "$db" "$WORK/db-before"
    [ -s "$root/globalStorage/rooveterinaryinc.roo-cline/tasks/id/message.json" ]
    sqlite3 "$db" "DROP TABLE unknown; UPDATE ItemTable SET value='broken' WHERE key='saoudrizwan.claude-dev';"
    cp "$db" "$WORK/db-before"
    expect_status 2 --modules ai --force
    cmp "$db" "$WORK/db-before"
    [ -s "$root/globalStorage/rooveterinaryinc.roo-cline/tasks/id/message.json" ]
    rm "$db"
    seed_editor_db "$db"
    ln -s "$WORK/db-before" "$db-wal"
    expect_status 2 --modules ai --force
    rm "$db-wal"
    cp "$db" "$root/globalStorage/state.vscdb.corrupted.1"
    expect_status 2 --modules ai --force
    [ -s "$root/globalStorage/state.vscdb.corrupted.1" ]
    put "$WORK/outside/sessions/chat.json" keep
    ln -s "$WORK/outside" "$AI_HOME/.continue"
    expect_status 2 --modules ai --force
    grep -q keep "$WORK/outside/sessions/chat.json"
)
test_failures
printf 'PASS: unknown schemas, malformed extension state, WAL links and recovery copies fail closed\n'

test_custom_and_processes() (
    setup custom
    put "$AI_HOME/custom continue/sessions/chat.json"
    put "$AI_HOME/custom cline/tasks/id/chat.json"
    put "$AI_HOME/custom roo/tasks/id/chat.json"
    put "$AI_HOME/custom history.txt"
    put "$AI_HOME/custom editor/globalStorage/rooveterinaryinc.roo-cline/tasks/id/chat.json"
    expect_status 0 --modules ai --force \
        --ai-root 'continue=/Users/User Space/custom continue' \
        --ai-root 'cline=/Users/User Space/custom cline' \
        --ai-root 'roo=/Users/User Space/custom roo' \
        --ai-root 'editor=/Users/User Space/custom editor' \
        --ai-root 'aider-history=/Users/User Space/custom history.txt'
    if grep -R -a -l session-marker "$AI_HOME"; then exit 1; fi
    mkdir -p "$AI_HOME/not a file"
    expect_status 2 --modules ai --force --ai-root 'aider-history=/Users/User Space/not a file'
    TEST_MODE=0
    local executable
    for executable in '/Applications/Cursor.app/Contents/MacOS/Cursor' \
        '/Applications/Windsurf.app/Contents/MacOS/Electron' \
        '/Applications/Visual Studio Code.app/Contents/MacOS/Electron' \
        '/Applications/PyCharm.app/Contents/MacOS/pycharm' \
        '/bin/cursor-agent chat' '/bin/cline' '/bin/cn' '/bin/python -m aider'; do
        # shellcheck disable=SC2329
        ps() { printf '%s\n' "$executable"; }
        if ai_agents_stopped; then exit 1; fi
    done
)
test_custom_and_processes
printf 'PASS: custom extension/history roots and editor/CLI process guards\n'
