#!/bin/bash
# shellcheck disable=SC2034 # sourced cleanup functions use these globals
# Extended AI cleanup uses marked temporary fixtures only.
set -euo pipefail
# Use system SQLite, as native cleanup does; some user shims omit FTS5.
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH
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
    TEST_MODE=1; SANDBOX="$SHREDDER_ROOT"; resolve_paths
    AI_HOME="$USERS_DIR/User Space"
    AI_EXTENDED=1
}
put() { mkdir -p "${1%/*}"; printf '%s\n' "${2:-session-marker}" > "$1"; }
seed() {
    local h="$1" item root
    for item in '.gemini/tmp/project/chats/session.json' '.gemini/tmp/project/checkpoints/checkpoint.json' \
        '.gemini/tmp/project/logs.json' '.gemini/history/project/.git/objects/object' \
        '.gemini/antigravity-cli/history.jsonl' '.gemini/antigravity-cli/cli.log' \
        '.gemini/antigravity/conversations/11111111-1111-1111-1111-111111111111.pb' \
        '.gemini/antigravity/agyhub_summaries_proto.pb' \
        'Library/Application Support/com.openai.chat/conversations-v3-account/chat.json' \
        'Library/Application Support/com.openai.chat/drafts-v2-account/draft.json' \
        '.claude/context-mode/sessions/stats-pid-123.json' '.serena/logs/date/server.log'; do put "$h/$item"; done
    for item in '.gemini/oauth_creds.json' '.gemini/settings.json' '.gemini/trustedFolders.json' \
        '.gemini/tmp/bin/gemini' '.gemini/tmp/project/.project_root' '.gemini/tmp/project/work/source' \
        '.gemini/antigravity-cli/antigravity-oauth-token' '.gemini/antigravity-cli/bin/agent' \
        '.gemini/antigravity-cli/settings.json' '.gemini/antigravity-cli/skills/custom/SKILL.md' \
        '.gemini/antigravity/conversations/settings.json' '.gemini/antigravity/user_settings.pb' \
        'Library/Application Support/com.openai.chat/project-g-p-one/file' \
        'Library/Application Support/com.openai.chat/automation-repository-user-one/job' \
        'Library/Application Support/com.openai.chat/conversations-invalid/item' \
        'Library/Application Support/Claude/vm_bundles/vm.img' \
        'Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/skill' \
        '.claude/context-mode/no-mcp-sentinels/pid' '.claude/context-mode/sessions/settings.json' \
        '.serena/config.yml'; do put "$h/$item" keep; done
    root="$h/Library/Application Support/Claude/local-agent-mode-sessions/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222"
    put "$root/local_33333333-3333-3333-3333-333333333333/transcript.json"
    put "$root/cowork_settings.json" keep
    put "$root/scheduled-tasks.json" keep
    put "$root/cowork_plugins/plugin" keep
    put "$root/.claude.json" '{"history":["session-marker"],"oauthAccount":{"fixture":"keep"},"projects":{"/project":{"history":["session-marker"],"lastSessionId":"session-marker","allowedTools":["keep"]}}}'
    cp "$root/.claude.json" "$root/.claude.json.backup.123"
    root="$h/.gemini/antigravity-cli"
    mkdir -p "$root/conversations"
    sqlite3 "$root/conversation_summaries.db" <<'SQL'
CREATE TABLE conversation_summaries(conversation_id TEXT, title TEXT);
INSERT INTO conversation_summaries VALUES('id','session-marker');
CREATE VIRTUAL TABLE conversations_fts USING fts5(conversation_id, user_body, agent_body);
INSERT INTO conversations_fts VALUES('id','session-marker','session-marker');
CREATE TABLE search_schema_version(version INTEGER);
INSERT INTO search_schema_version VALUES(1);
SQL
    sqlite3 "$root/conversations/11111111-1111-1111-1111-111111111111.db" <<'SQL'
CREATE TABLE trajectory_meta(trajectory_id TEXT);
CREATE TABLE steps(idx INTEGER,step_payload BLOB);
CREATE TABLE gen_metadata(idx INTEGER,data BLOB,size INTEGER);
INSERT INTO trajectory_meta VALUES('session-marker');
INSERT INTO steps VALUES(1,'session-marker');
INSERT INTO gen_metadata VALUES(1,'session-marker',14);
SQL
    root="$h/.claude/context-mode"
    mkdir -p "$root/content"
    sqlite3 "$root/sessions/01234567__01234567.db" <<'SQL'
CREATE TABLE session_events(id INTEGER PRIMARY KEY AUTOINCREMENT, data TEXT);
CREATE TABLE session_meta(session_id TEXT);
CREATE TABLE session_resume(snapshot TEXT);
CREATE TABLE tool_calls(session_id TEXT,tool TEXT);
INSERT INTO session_events(data) VALUES('session-marker');
INSERT INTO session_meta VALUES('session-marker');
INSERT INTO session_resume VALUES('session-marker');
INSERT INTO tool_calls VALUES('id','session-marker');
SQL
    sqlite3 "$root/content/0123456789abcdef.db" <<'SQL'
CREATE TABLE sources(id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT);
CREATE VIRTUAL TABLE chunks USING fts5(title, content);
CREATE VIRTUAL TABLE chunks_trigram USING fts5(title, content,tokenize='trigram');
CREATE TABLE vocabulary(word TEXT);
INSERT INTO sources(label) VALUES('session-marker');
INSERT INTO chunks VALUES('title','session-marker');
INSERT INTO chunks_trigram VALUES('title','session-marker');
INSERT INTO vocabulary VALUES('session-marker');
SQL
}

test_cleanup() (
    setup cleanup
    seed "$AI_HOME"
    cp -R "$SANDBOX" "$WORK/before"
    DRY_RUN=1
    ai_extended_home "$AI_HOME"
    diff -r "$WORK/before" "$SANDBOX"
    DRY_RUN=0
    ai_extended_home "$AI_HOME"
    [ "$FAILED_COUNT" -eq 0 ]
    [ -s "$AI_HOME/.gemini/history/project/.git/objects/object" ]
    [ ! -e "$AI_HOME/.gemini/tmp/project/chats" ]
    [ ! -e "$AI_HOME/.gemini/tmp/project/checkpoints" ]
    [ ! -e "$AI_HOME/.gemini/antigravity/conversations/11111111-1111-1111-1111-111111111111.pb" ]
    [ ! -e "$AI_HOME/Library/Application Support/com.openai.chat/conversations-v3-account" ]
    [ ! -e "$AI_HOME/Library/Application Support/Claude/local-agent-mode-sessions/11111111-1111-1111-1111-111111111111/22222222-2222-2222-2222-222222222222/local_33333333-3333-3333-3333-333333333333" ]
    local item
    while IFS= read -r -d '' item; do
        case "$item" in *.db|*.json.backup.123|*/.claude.json) continue ;; esac
        if grep -q '^keep$' "$item"; then cmp "$item" "$AI_HOME/${item#"$WORK/before/Users/User Space/"}"; fi
    done < <(find "$WORK/before/Users/User Space" -type f -print0)
    [ "$(sqlite3 "$AI_HOME/.gemini/antigravity-cli/conversation_summaries.db" 'SELECT count(*) FROM conversation_summaries; SELECT count(*) FROM conversations_fts; SELECT version FROM search_schema_version;')" = $'0\n0\n1' ]
    [ "$(sqlite3 "$AI_HOME/.claude/context-mode/content/0123456789abcdef.db" 'SELECT count(*) FROM chunks; SELECT count(*) FROM chunks_trigram; PRAGMA integrity_check;')" = $'0\n0\nok' ]
    AI_DERIVED=1
    ai_extended_home "$AI_HOME"
    [ "$FAILED_COUNT" -eq 0 ]
    [ ! -e "$AI_HOME/.gemini/history" ]
    if grep -R -a -l session-marker "$AI_HOME"; then exit 1; fi
)
test_cleanup
printf 'PASS: extended AI dry-run, sessions, FTS indexes and metadata; credentials/settings/plugins preserved\n'

test_refusal() (
    setup refusal
    local root="$AI_HOME/.gemini/antigravity-cli" db
    put "$root/conversations/settings.json" keep
    put "$root/history.jsonl"
    db="$root/conversation_summaries.db"
    sqlite3 "$db" 'CREATE TABLE conversation_summaries(title TEXT); INSERT INTO conversation_summaries VALUES("session-marker"); CREATE TABLE credentials(secret TEXT); INSERT INTO credentials VALUES("keep");'
    cp "$db" "$WORK/unknown.db"
    ai_extended_antigravity "$root"
    [ "$FAILED_COUNT" -eq 1 ]; cmp "$db" "$WORK/unknown.db"
    [ -s "$root/history.jsonl" ]
    sqlite3 "$db" 'DROP TABLE credentials; CREATE TRIGGER deny AFTER DELETE ON conversation_summaries BEGIN SELECT 1; END;'
    cp "$db" "$WORK/trigger.db"
    FAILED_COUNT=0; ai_extended_antigravity "$root"
    [ "$FAILED_COUNT" -eq 1 ]; cmp "$db" "$WORK/trigger.db"
    sqlite3 "$db" 'DROP TRIGGER deny;'
    ln "$db" "$WORK/hardlink.db"
    FAILED_COUNT=0; ai_extended_antigravity "$root"
    [ "$FAILED_COUNT" -eq 1 ]
    put "$WORK/outside/log" keep
    mkdir -p "$AI_HOME/.serena"
    ln -s "$WORK/outside" "$AI_HOME/.serena/logs"
    FAILED_COUNT=0; ai_extended_home "$AI_HOME"
    [ "$FAILED_COUNT" -ge 2 ]; [ -s "$WORK/outside/log" ]
    mkdir -p "$AI_HOME/.claude/context-mode/content"
    put "$AI_HOME/.claude/context-mode/content/orphan.db-wal" keep
    FAILED_COUNT=0; ai_extended_context "$AI_HOME/.claude/context-mode"
    [ "$FAILED_COUNT" -eq 1 ]; [ -s "$AI_HOME/.claude/context-mode/content/orphan.db-wal" ]
)
test_refusal
printf 'PASS: unknown tables, triggers, hard links, path links and orphan sidecars are retained\n'

test_process_guard() (
    setup processes
    TEST_MODE=0
    local process
    for process in '/usr/bin/node /opt/node_modules/@google/gemini-cli/dist/index.js' \
        '/Applications/ChatGPT.app/Contents/MacOS/ChatGPT' \
        '/Applications/Antigravity IDE.app/Contents/MacOS/Electron' \
        '/Users/test/.gemini/antigravity/bin/language_server' \
        '/usr/bin/python /tools/serena/start_mcp_server.py' \
        '/usr/bin/node /plugins/context-mode/dist/server.js' \
        '/usr/local/bin/serena-mcp-server'; do
        ps() { printf '%s\n' "$process"; }
        if ai_extended_stopped; then printf 'process not blocked: %s\n' "$process"; exit 1; fi
    done
    ps() { return 1; }
    if ai_extended_stopped; then exit 1; fi
    ps() { printf '/usr/bin/unrelated\n'; }
    ai_extended_stopped
)
test_process_guard
printf 'PASS: desktop, CLI and plugin process checks fail closed\n'

# Exercise the public flag and its default scope using only the sandbox.
test_cli_scope() (
    setup cli
    put "$AI_HOME/.gemini/tmp/project/chats/session.json"
    put "$AI_HOME/.gemini/oauth_creds.json" keep
    /bin/bash "$SHREDDER" --modules ai --force > "$WORK/cli.log" 2>&1
    [ -s "$AI_HOME/.gemini/tmp/project/chats/session.json" ]
    /bin/bash "$SHREDDER" --modules ai --ai-extended --dry-run > "$WORK/cli.log" 2>&1
    [ -s "$AI_HOME/.gemini/tmp/project/chats/session.json" ]
    /bin/bash "$SHREDDER" --modules ai --ai-extended --force > "$WORK/cli.log" 2>&1
    [ ! -e "$AI_HOME/.gemini/tmp/project/chats" ]
    [ -s "$AI_HOME/.gemini/oauth_creds.json" ]
)
test_cli_scope
printf 'PASS: public extended flag is opt-in and preserves credentials\n'

test_wal() (
    setup wal
    local root="$AI_HOME/.gemini/antigravity-cli" db pid attempt=0
    put "$root/history.jsonl"
    db="$root/conversation_summaries.db"
    mkfifo "$WORK/sql-input"
    sqlite3 "$db" < "$WORK/sql-input" > "$WORK/sql-output" 2>&1 &
    pid=$!
    trap 'exec 3>&-; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
    exec 3> "$WORK/sql-input"
    printf '%s\n' 'PRAGMA journal_mode=WAL;' 'CREATE TABLE conversation_summaries(title TEXT);' \
        'INSERT INTO conversation_summaries VALUES("session-marker");' 'BEGIN IMMEDIATE;' '.print ready' >&3
    until grep -q ready "$WORK/sql-output"; do
        attempt=$((attempt + 1)); [ "$attempt" -lt 200 ] || exit 1; sleep 0.01
    done
    cp -R "$SANDBOX" "$WORK/wal-before"
    DRY_RUN=1; ai_extended_antigravity "$root"
    diff -r "$WORK/wal-before" "$SANDBOX"
    DRY_RUN=0; ai_extended_antigravity "$root"
    [ "$FAILED_COUNT" -eq 1 ]; [ -s "$root/history.jsonl" ]
    [ "$(sqlite3 "$db" 'SELECT title FROM conversation_summaries;')" = session-marker ]
    printf '%s\n' 'COMMIT;' '.quit' >&3
    exec 3>&-; wait "$pid"; trap - EXIT
    FAILED_COUNT=0; ai_extended_antigravity "$root"
    [ "$FAILED_COUNT" -eq 0 ]; [ ! -e "$root/history.jsonl" ]
    [ "$(sqlite3 "$db" 'SELECT count(*) FROM conversation_summaries;')" = 0 ]
    [ ! -s "$db-wal" ]
)
test_wal
printf 'PASS: extended WAL dry-run is stable; live writer is refused; retry clears history\n'
